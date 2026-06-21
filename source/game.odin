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
import "core:thread"
import rl "vendor:raylib"

gm: ^GameMemory

GameMemory :: struct {
	should_run:     bool,
	app_state:      AppState,
	active_tab:     int,
	ui_controls:    Controls,
	sound_settings: ^SoundSettings,
	loader:         ^thread.Thread,
}

AppState :: union #no_nil {
	AppInitializing,
	AppReady,
}

AppInitializing :: distinct u8
AppReady :: struct {
	show_state: ShowState,
}

ShowState :: enum {
	Initial,
	PreShow,
	PostShow,
	House,
	Scene,
	DropNeedle,
	ShowTransitioning,
}

ShowTransitioning :: struct {
	target: ^ShowState,
	effect: TransitionEffect,
}
TransitionEffect :: union #no_nil {
	VolRampEffect,
	CutEffect,
}
VolRampEffect :: struct {
	ramp_up_duration:  f32,
	hold_duration:     f32,
	fade_out_duration: f32,
}
CutEffect :: distinct u8

Show_Action :: enum {
	Unknown,
	// Main controls
	Tab_Bar,
	Music_Volume,
	// Scene changes
	Pre_Show,
	Post_Show,
	To_House,
	Drop_Needle,
	// Sounds
	Cat_Meow,
	// Later: lighting
}

Tab :: enum int {
	Controls = 0,
	Music    = 1,
}

layout_build :: proc() -> Controls {
	controls: Controls

	// Per-tab content first, then chrome, so the persistent controls draw on top.
	layout_load(
		&controls,
		"controls.rgl",
		string(#load("../resources/controls.rgl")),
		int(Tab.Controls),
	)
	// ui.load_layout(&controls, "music.rgl", string(#load("../resources/music.rgl")), int(Tab.Music), allocator)

	layout_load(
		&controls,
		"chrome.rgl",
		string(#load("../resources/chrome.rgl")),
		VISIBLE_ON_ALL_GROUPS,
	)

	controls_prepare_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	return controls
}

// Keeps a tab index reported by the Tab_Bar within the defined tabs, so a
// malformed/extra ToggleGroup option can't activate a page that doesn't exist.
tab_clamp :: proc(index: int) -> int {
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
ui_resolve_type :: proc(name: string) -> UI_Type {
	switch name {
	case "Drop_Needle":
		return .Destructive
	case:
		return .Default
	}
}

ui_dispatch_events :: proc(events: ^UI_Events) {
	for event in events {
		val, ok := fmt.string_to_enum_value(Show_Action, event.name)
		if !ok do val = .Unknown

		// Only actions that mutate persisted settings save them. Tab switches
		// and one-shot sounds are transient, so they don't touch the file.
		switch val {
		case .Tab_Bar:
			gm.active_tab = tab_clamp(int(event.value))
		case .Music_Volume:
			//sound_music_volume_set(event.value)
			sound_settings_save()
		case .Pre_Show:
			vol := f32(0.5)
			volume_set_value(vol, gm.ui_controls[:])
			// Pass the volume to play_playlist so it cross-fades in with the new
			// track rather than jumping the outgoing track to it.
			playlist_play("Happy Beats", vol)
		case .Post_Show:
			vol := f32(0.8)
			volume_set_value(vol, gm.ui_controls[:])
			playlist_play("Happy Beats", vol)
		case .To_House:
			vol := f32(0.2)
			volume_set_value(vol, gm.ui_controls[:])
			playlist_play("Easy Listening", vol)
		case .Drop_Needle:
			vol := f32(1.0)
			volume_set_value(vol, gm.ui_controls[:])
			// Drop the needle: hard-cut all music and slam in at full volume,
			// bypassing the cross-fade the other scene switches use.
			playlist_play("Needle Droppers", vol, true)
		case .Cat_Meow:
			// Sound effects carry their own volume, independent of music_volume.
			sound_play("assets/sounds/fx/cat-meow.mp3", 0.6)
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
		controls_prepare_for_render(gm.ui_controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	}

	switch s in gm.app_state {
	case AppInitializing:
		if gm.loader != nil && thread.is_done(gm.loader) {
			thread.destroy(gm.loader)
			gm.loader = nil
			gm.app_state = AppReady {
				show_state = .Initial,
			}
		}
	case AppReady:
		sound_update()
	}
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground({16, 16, 16, 255})

	switch s in gm.app_state {
	case AppInitializing:
		font_size := i32(40)
		x := (rl.GetRenderWidth() - rl.MeasureText("Normalizing audio...", font_size)) / 2
		y := rl.GetRenderHeight() / 2 - font_size / 2

		dots := "..."
		dot_count := int(rl.GetTime() / 0.5) % 3 + 1
		text := fmt.ctprintf("Normalizing audio%s", dots[:dot_count])
		rl.DrawText(text, x, y, font_size, rl.RAYWHITE)

	case AppReady:
		events := ui_draw(gm.ui_controls[:], gm.active_tab)
		ui_dispatch_events(&events)
	}

	rl.EndDrawing()
}

@(export)
game_update :: proc() {
	update()
	draw()

	// Everything on tracking allocator is valid until end-of-frame.
	free_all(context.temp_allocator)
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
	ui_load_style()
}

// GuiLoadStyle only accepts a file path, so write the embedded style next to
// the running executable (resolves regardless of the working directory). Raygui
// style is global module state, so hot reload must apply it again after loading
// a fresh game DLL.
ui_load_style :: proc() {
	style_raw := #load("../resources/cyber.rgs")
	style_path := fmt.ctprint(rl.GetApplicationDirectory(), "cyber.rgs", sep = "")
	rl.SaveFileData(style_path, raw_data(style_raw), i32(len(style_raw)))
	rl.GuiLoadStyle(style_path)
}

@(export)
game_init :: proc() {
	gm = new(GameMemory)
	gm^ = GameMemory {
		should_run = true,
		app_state  = AppInitializing{},
	}

	// build_layout assigns each control's tab (visibility group) from the file it
	// was loaded out of. The remaining app metadata (destructive styling) is
	// neutral after parsing, so it is applied here while the UI-owned data lives
	// on the app allocator.
	gm.ui_controls = layout_build()
	for &control in gm.ui_controls {
		control.ui_type = ui_resolve_type(control.name)
	}

	gm.sound_settings = sound_settings_init()
	gm.loader = thread.create_and_start(playlists_load_async, context)

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
	// If the window closed while still loading, wait for the loader to finish
	// before sound_shutdown frees the settings/playlists it is writing into.
	if gm.loader != nil {
		thread.destroy(gm.loader)
		gm.loader = nil
	}
	sound_shutdown()
	ui_shutdown(&gm.ui_controls)
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
	return size_of(GameMemory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	gm = (^GameMemory)(mem)

	ui_load_style()

	// Restore Module-level pointers that point into `gm`. A freshly loaded DLL
	// starts these globals nil, so they must be re-pointed here before the next
	// frame uses them.
	sound_hot_reloaded(gm.sound_settings)
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
