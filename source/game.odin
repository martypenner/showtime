#+vet !unused-imports
/*
This file is the starting point of your game.

Some important procedures are:
- game_init_window: Opens the window
- game_init: Sets up the game state
- game_update: Run once per frame
- game_should_close: For stopping your game when close button is pressed
- game_shutdown: Shuts down game and frees memory
- game_shutdown_window: Closes window

The procs above are used regardless if you compile using the `build_release`
script or the `build_hot_reload` script. However, in the hot reload case, the
contents of this file is compiled as part of `build/hot_reload/game.dll` (or
.dylib/.so on mac/linux). In the hot reload cases some other procedures are
also used in order to facilitate the hot reload functionality:

- game_memory: Run just before a hot reload. That way game_hot_reload.exe has a
	pointer to the game's memory that it can hand to the new game DLL.
- game_hot_reloaded: Run after a hot reload so that the `g` global
	variable can be set to whatever pointer it was in the old DLL.

NOTE: When compiled as part of `build_release`, `build_debug` or `build_web`
then this whole package is just treated as a normal Odin package. No DLL is
created.
*/

package game

import "core:fmt"
import "core:log"
import "core:mem"
import "core:thread"
import "core:time"
import "sound"
import "state"
import "ui"
import rl "vendor:raylib"

gm: ^state.GameMemory

// The loader thread starts with a fresh default context, so it does not inherit
// main's allocator/logger. We capture them here before spawning so the loader
// can use the same (mutex-guarded) tracking allocator main uses. Matching
// allocators matters: the loudness-cache map is freed in game_shutdown with
// main's allocator, so it must be allocated with the same one.
loader_allocator: mem.Allocator
loader_logger: log.Logger

// Show-control behaviors the app knows how to perform. Generic UI rendering
// reports interactions by control name; this is the one place that turns those
// names into app behavior.
Show_Action :: enum {
	Unknown,
	// Main controls
	Tab_Bar,
	Master_Volume,
	// Scene changes
	Drop_Needle,
	// Sounds
	Cat_Meow,
	// Later: lighting
}

// The pages the controls are split across, selected by the Tab_Bar. Each tab is
// authored as its own rGuiLayout file and loaded into the matching group in
// build_layout. The order must match the Tab_Bar ToggleGroup options in
// resources/chrome.rgl ("Controls;Music"): the ToggleGroup reports the active
// tab by index, and that index is the control's visibility group.
Tab :: enum int {
	Controls = 0,
	Music    = 1,
}

// Loads the layout files into one control list, returning the combined result.
// The UI is split per file rather than per control name so each screen is
// editable on its own in the layout tool: chrome.rgl holds the persistent
// controls shown on every tab, and one file per Tab holds that tab's controls.
// Add a tab by authoring its file and loading it here against the matching Tab.
build_layout :: proc() -> [dynamic]ui.Control {
	controls := make([dynamic]ui.Control)

	// Per-tab content first, then chrome, so the persistent controls draw on top.
	ui.load_layout(
		&controls,
		"controls.rgl",
		string(#load("../resources/controls.rgl")),
		int(Tab.Controls),
	)
	// ui.load_layout(&controls, "music.rgl", string(#load("../resources/music.rgl")), int(Tab.Music), allocator)

	ui.load_layout(
		&controls,
		"chrome.rgl",
		string(#load("../resources/chrome.rgl")),
		ui.VISIBLE_ON_ALL_GROUPS,
	)

	ui.prepare_controls_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	return controls
}

// Keeps a tab index reported by the Tab_Bar within the defined tabs, so a
// malformed/extra ToggleGroup option can't activate a page that doesn't exist.
clamp_tab :: proc(index: int) -> int {
	switch Tab(index) {
	case .Controls, .Music:
		return index
	case:
		return int(Tab.Controls)
	}
}

// Resolves a layout control name to its presentation style. Destructive styling
// is an app concern (which controls are dangerous to the show), so this mapping
// lives here rather than in generic UI/layout code. Keeping it pure lets the
// styling Seam be verified without Raylib drawing.
resolve_ui_type :: proc(name: string) -> ui.UI_Type {
	switch name {
	case "Drop_Needle":
		return .Destructive
	case:
		return .Default
	}
}

dispatch_ui_events :: proc(events: ^[dynamic]ui.UI_Event) {
	for event in events {
		val, ok := fmt.string_to_enum_value(Show_Action, event.name)
		if !ok do val = .Unknown

		// Only actions that mutate persisted settings save them. Tab switches
		// and one-shot sounds are transient, so they don't touch the file.
		switch val {
		case .Tab_Bar:
			gm.active_tab = clamp_tab(int(event.value))
		case .Master_Volume:
			sound.set_volume(event.value)
			sound.save_settings()
		case .Drop_Needle:
			sound.play_playlist("Needle Droppers")
		case .Cat_Meow:
			sound.play_sound("assets/sounds/fx/cat-meow.mp3")
		case .Unknown:
			log.warnf("No app behavior mapped for UI control %q", event.name)
		}
	}
}

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		gm.should_run = false
	}
	if rl.IsWindowResized() {
		ui.prepare_controls_for_render(
			gm.ui_controls[:],
			rl.GetRenderWidth(),
			rl.GetRenderHeight(),
		)
	}

	sound.update()
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground({16, 16, 16, 255})

	events := ui.draw(gm.ui_controls[:], gm.active_tab)
	dispatch_ui_events(&events)

	rl.EndDrawing()
}

@(export)
game_update :: proc() {
	update()
	draw()

	// Everything on tracking allocator is valid until end-of-frame.
	free_all(context.temp_allocator)
}

// Builds the sound settings and playlists. This hashes and decodes every track,
// so it is slow enough to want a loading screen (see run_loading_screen). When
// run on the loader thread it starts from a fresh default context, so it adopts
// main's allocator/logger; gm.sound_settings is published when it returns.
load_assets :: proc(data: rawptr) {
	g := (^state.GameMemory)(data)
	context.allocator = loader_allocator
	context.logger = loader_logger

	g.sound_settings = sound.init_settings()
}

// Runs the asset load on a background thread while drawing a loading screen on
// this (main) thread until it finishes. Keeping the loop here means the steady
// state game_update has no loading branch to check every frame. The loader uses
// the captured app allocator/logger because new threads start with a default
// context rather than inheriting main's.
run_loading_screen :: proc() {
	loader_allocator = context.allocator
	loader_logger = context.logger
	loader := thread.create_and_start_with_data(gm, load_assets)
	defer thread.destroy(loader) // joins, so the loader is done past this point

	for !thread.is_done(loader) {
		if rl.WindowShouldClose() {
			gm.should_run = false
			break
		}

		rl.BeginDrawing()
		rl.ClearBackground({16, 16, 16, 255})

		// Animate the trailing dots: "." -> ".." -> "..." -> repeat. Position from
		// the full-width text so "Loading" stays put while the dots appear and
		// disappear, rather than the whole line jittering when centered.
		font_size := i32(40)
		x := (rl.GetRenderWidth() - rl.MeasureText("Loading...", font_size)) / 2
		y := rl.GetRenderHeight() / 2 - font_size / 2

		dots := "..."
		dot_count := int(rl.GetTime() / 0.5) % 3 + 1
		text := fmt.ctprintf("Loading%s", dots[:dot_count])
		rl.DrawText(text, x, y, font_size, rl.RAYWHITE)

		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

@(export)
game_init_window :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "Showtime")
	when ODIN_OS != .JS do rl.SetWindowPosition(200, 200)
	// This is an app, not a game. Needs constant updates since some latency will
	// occur between networked devices.
	rl.SetTargetFPS(500)
	rl.SetExitKey(nil)

	// GuiLoadStyle only accepts a file path, so write the embedded style next to
	// the running executable (resolves regardless of the working directory).
	style_raw := #load("../resources/cyber.rgs")
	style_path := fmt.ctprint(rl.GetApplicationDirectory(), "cyber.rgs", sep = "")
	rl.SaveFileData(style_path, raw_data(style_raw), i32(len(style_raw)))
	rl.GuiLoadStyle(style_path)
}

@(export)
game_init :: proc() {
	gm = new(state.GameMemory)
	gm^ = state.GameMemory {
		should_run = true,
	}

	// build_layout assigns each control's tab (visibility group) from the file it
	// was loaded out of. The remaining app metadata (destructive styling) is
	// neutral after parsing, so it is applied here while the UI-owned data lives
	// on the app allocator.
	gm.ui_controls = build_layout()
	for &control in gm.ui_controls {
		control.ui_type = resolve_ui_type(control.name)
	}

	when ODIN_OS == .JS {
		// Web is single-threaded and the browser drives the frame loop, so there
		// is no main thread to draw a loading screen on; load synchronously.
		gm.sound_settings = sound.init_settings()
	} else {
		run_loading_screen()
	}

	game_hot_reloaded(gm)
}

@(export)
game_should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// Never run this proc in browser. It contains a 16 ms sleep on web!
		if rl.WindowShouldClose() {
			return false
		}
	}

	return gm.should_run
}

@(export)
game_shutdown :: proc() {
	sound.shutdown()
	ui.destroy_controls(&gm.ui_controls)
	free(gm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}

@(export)
game_memory :: proc() -> rawptr {
	return gm
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(state.GameMemory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	gm = (^state.GameMemory)(mem)

	// Restore Module-level pointers that point into `gm`. A freshly loaded DLL
	// starts these globals nil, so they must be re-pointed here before the next
	// frame uses them.
	sound.hot_reloaded(gm.sound_settings)
}

@(export)
game_force_reload :: proc() -> bool {
	return rl.IsKeyPressed(.F5)
}

@(export)
game_force_restart :: proc() -> bool {
	return rl.IsKeyPressed(.F6)
}

// In a web build, this is called when browser changes size. Remove the
// `rl.SetWindowSize` call if you don't want a resizable game.
game_parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(i32(w), i32(h))
}
