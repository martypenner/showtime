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

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:thread"
import rl "vendor:raylib"

_ :: log
_ :: fmt

gm: ^GameMemory

GameMemory :: struct {
	permanent_arena: mem.Dynamic_Arena,
	should_run:      bool,
	app_state:       AppState,
	active_tab:      int,
	ui:              UIControls,
	sound_settings:  ^SoundSettings,
	loader:          ^thread.Thread,
	lighting:        struct {
		socket:      Maybe(net.UDP_Socket),
		endpoint:    net.Endpoint,
		active_look: LightingLook,
		active_fx:   [LightingFxKind]LightingFx,
	},
}

AppState :: union #no_nil {
	AppInitializing,
	AppReady,
}

AppInitializing :: distinct u8
AppReady :: distinct u8

LightingLook :: enum {
	House,
	Scene,
	CenterFocus,
}
LightingFx :: struct {
	kind:          LightingFxKind,
	fade_start:    f32,
	fade_target:   f32,
	fade_duration: f32,
	fade_elapsed:  f32,
	fade_current:  f32,
}
LightingFxKind :: enum {
	Blackout,
	RainbowSting,
	Rain,
	Innuendo,
}

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		gm.should_run = false
	}

	switch s in gm.app_state {
	case AppInitializing:
		if gm.loader != nil && thread.is_done(gm.loader) {
			thread.destroy(gm.loader)
			gm.loader = nil
			gm.app_state = AppReady{}
		}
	case AppReady:
		if rl.IsWindowResized() {
			controls_prepare_for_render(gm.ui.items[:], rl.GetRenderWidth(), rl.GetRenderHeight())
		}
		sound_update()
		ui_control_set_value(&gm.ui, .Music_Volume, sound_music_current_volume())
		lighting_update()
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
		controls_draw()
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
	// I'd like this to be higher - e.g. 500 for latency purposes - but it eats
	// more CPU (obviously) on older machines.
	rl.SetTargetFPS(60)
	rl.SetExitKey(nil)
}

// GuiLoadStyle only accepts a file path, so write the embedded style next to
// the running executable (resolves regardless of the working directory). Raygui
// style is global module state, so hot reload must apply it again after loading
// a fresh game DLL.
ui_load_style :: proc() {
	style_raw := #load("../resources/cyber.rgs")
	style_path := fmt.ctprint(rl.GetApplicationDirectory(), "cyber.rgs", sep = "")
	ensure(rl.SaveFileData(style_path, raw_data(style_raw), i32(len(style_raw))))
	rl.GuiLoadStyle(style_path)
	os.remove(string(style_path))
}

game_memory_make :: proc() -> ^GameMemory {
	memory := new(GameMemory, runtime.default_allocator())
	memory^ = GameMemory {
		should_run = true,
		app_state  = AppInitializing{},
	}

	mem.dynamic_arena_init(&memory.permanent_arena)
	return memory
}

game_memory_allocator :: proc(memory: ^GameMemory) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&memory.permanent_arena)
}

game_memory_destroy :: proc(memory: ^GameMemory) {
	mem.dynamic_arena_destroy(&memory.permanent_arena)
	free(memory, runtime.default_allocator())
}

@(export)
game_init :: proc() {
	gm = game_memory_make()
	context.allocator = game_memory_allocator(gm)

	gm.sound_settings = sound_settings_init()
	gm.loader = thread.create_and_start(playlists_load_async, context)

	gm.ui = ui_controls_make(layout_build())
	ui_control_set_value(&gm.ui, .Use_House_Music, gm.sound_settings.use_house_music)

	for &control in gm.ui.items {
		control.ui_type = ui_resolve_type(control.name_id)
	}

	thread.join(gm.loader)
	music_browser_playlists_refresh()
	music_browser_tracks_refresh()

	endpoint, endpoint_ok := net.parse_endpoint("127.0.0.1:42000")
	log.ensuref(endpoint_ok, "Error parsing endpoint", endpoint)
	socket, socket_err := net.make_unbound_udp_socket(.IP4)
	log.ensuref(socket_err == nil, "Error making udp socket: %v", socket_err)
	gm.lighting.socket = socket
	gm.lighting.endpoint = endpoint

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
	// If the window closed while still loading, wait for the loader to finish.
	if gm.loader != nil {
		thread.destroy(gm.loader)
		gm.loader = nil
	}
	sound_shutdown()

	if socket, ok := gm.lighting.socket.?; ok {
		net.close(socket)
		gm.lighting.socket = nil
	}

	game_memory_destroy(gm)
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
