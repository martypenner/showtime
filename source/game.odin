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

import "core:mem"
import "state"
import "ui"
import "ui/playground"
import rl "vendor:raylib"

PLAYGROUND :: #config(PLAYGROUND, false)

gm: ^state.Game_Memory

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		gm.should_run = false
	}
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground({16, 16, 16, 255})

	when PLAYGROUND {
		playground.draw(gm)
	}
	ui.draw(gm.ui_controls)

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

	style_raw := #load("../resources/cyber.rgs")
	rl.SaveFileData("cyber.rgs", raw_data(style_raw), i32(len(style_raw)))
	rl.GuiLoadStyle("cyber.rgs")

	font_raw := #load("../resources/quantico-regular.ttf")
	rl.SaveFileData("quantico-regular.ttf", raw_data(font_raw), i32(len(font_raw)))
	font := rl.LoadFontEx("quantico-regular.ttf", 18, nil, 0)
	rl.SetTextureFilter(font.texture, .BILINEAR)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 18)
	rl.GuiSetFont(font)
}

@(export)
game_init :: proc() {
	gm = new(state.Game_Memory)
	gm^ = state.Game_Memory {
		should_run = true,
	}

	rl.InitAudioDevice()

	mem.dynamic_arena_init(&gm.ui_arena)
	ui.build_layout(gm)
	when PLAYGROUND {
		copy(gm.playground.text_box_buffer[:], "starting text")
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
	mem.dynamic_arena_destroy(&gm.ui_arena)
	free(gm)
	rl.CloseAudioDevice()
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
	return size_of(state.Game_Memory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	gm = (^state.Game_Memory)(mem)

	// Here you can also set your own global variables. A good idea is to make
	// your global variables into pointers that point to something inside `gm`.
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
