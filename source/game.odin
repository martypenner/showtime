/*
This file is the starting point of your game.

Some important procedures are:
- game_init_window: Opens the window
- game_init: Sets up the game state
- game_update: Run once per frame
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

import imgui "../vendor/odin-imgui"
import imsdl3 "../vendor/odin-imgui/imgui_impl_sdl3"
import imsdlrenderer3 "../vendor/odin-imgui/imgui_impl_sdlrenderer3"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import sdl "vendor:sdl3"

_ :: log
_ :: fmt

gm: ^GameMemory

GameMemory :: struct {
	should_run:            bool,
	sound_settings:        ^SoundSettings,
	lighting:              struct {
		socket:         Maybe(net.UDP_Socket),
		endpoint:       net.Endpoint,
		active_look:    LightingLook,
		fx:             [LightingFxKind]LightingFx,
		fx_osc_address: [LightingFxKind]string,
	},
	active_tab:            Tab,
	timers:                [MAX_TIMERS]Timer,
	timer_marks:           [MAX_TIMER_MARKS]TimerMark,
	timer_marks_count:     int,
	timer_serial_next:     int,
	// imgui state preserved across hot reloads. imgui's contexts, allocator
	// functions, and SDL handles are DLL-global statics that reset to nil when
	// a new DLL loads, so they must be saved on first init and restored here.
	imgui_contexts:        struct {
		controls:   ^imgui.Context,
		projection: ^imgui.Context,
	},
	imgui_alloc_func:      imgui.MemAllocFunc,
	imgui_free_func:       imgui.MemFreeFunc,
	imgui_alloc_user_data: rawptr,
	windows:               struct {
		controls:   ^sdl.Window,
		projection: ^sdl.Window,
	},
	renderers:             struct {
		controls:   ^sdl.Renderer,
		projection: ^sdl.Renderer,
	},
}

controls_window: ^sdl.Window
controls_renderer: ^sdl.Renderer
projection_window: ^sdl.Window
projection_renderer: ^sdl.Renderer
controls_context: ^imgui.Context
projection_context: ^imgui.Context
io: ^imgui.IO
projection_io: ^imgui.IO
window_width: i32 = 1280
window_height: i32 = 720

@(private = "file")
last_time: u64
dt: f32

update :: proc() {
	current_time := sdl.GetTicks()
	dt = f32(current_time - last_time) / 1000 // Convert milliseconds to seconds
	last_time = current_time

	event: sdl.Event
	for sdl.PollEvent(&event) {
		if event.window.windowID == sdl.GetWindowID(projection_window) {
			imgui.SetCurrentContext(projection_context)
			imsdl3.ProcessEvent(&event)
		} else if event.window.windowID == sdl.GetWindowID(controls_window) {
			imgui.SetCurrentContext(controls_context)
			imsdl3.ProcessEvent(&event)

			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				gm.should_run = false
			case .KEY_DOWN:
				if !event.key.repeat ||
				   event.key.key == sdl.K_PLUS ||
				   event.key.key == sdl.K_MINUS {
					if gm.active_tab == .Controls && !io.WantTextInput {
						hotkeys_handle_key(event.key.key)
					}
				}
			case .WINDOW_RESIZED:
				sdl.GetWindowSizeInPixels(controls_window, &window_width, &window_height)
			}
		}
	}

	sound_update()
	lighting_update()
	timers_update(dt)
}

draw :: proc() {
	draw_window(projection_context, projection_renderer, projection_io, projection_draw)
	draw_window(controls_context, controls_renderer, io, controls_draw)
}

@(private = "file")
draw_window :: proc(
	imgui_context: ^imgui.Context,
	renderer: ^sdl.Renderer,
	io: ^imgui.IO,
	draw_ui: proc(),
) {
	imgui.SetCurrentContext(imgui_context)

	imsdlrenderer3.NewFrame()
	imsdl3.NewFrame()
	imgui.NewFrame()

	draw_ui()
	imgui.Render()

	sdl.SetRenderScale(renderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y)
	sdl.SetRenderDrawColor(renderer, 16, 16, 16, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(renderer)
	imsdlrenderer3.RenderDrawData(imgui.GetDrawData(), renderer)
	sdl.RenderPresent(renderer)
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
	ensure(sdl.SetAppMetadata("Showtime", "1.0", "showtime"), string(sdl.GetError()))

	ensure(sdl.Init({.VIDEO, .AUDIO}))
	main_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())
	window_flags := sdl.WindowFlags{.RESIZABLE, .HIDDEN, .HIGH_PIXEL_DENSITY}
	when !ODIN_DEBUG {
		window_flags += {.MAXIMIZED}
	}
	controls_window = sdl.CreateWindow(
		"Showtime Control",
		window_width,
		window_height,
		window_flags,
	)
	ensure(controls_window != nil, string(sdl.GetError()))
	projection_window = sdl.CreateWindow(
		"Showtime Projection",
		window_width,
		window_height,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN, .MAXIMIZED, .FULLSCREEN},
	)
	ensure(projection_window != nil, string(sdl.GetError()))

	renderer_name := "vulkan"
	when ODIN_OS == .Darwin {
		renderer_name = "metal"
	}
	controls_renderer = sdl.CreateRenderer(
		controls_window,
		strings.clone_to_cstring(renderer_name, context.temp_allocator),
	)
	ensure(controls_renderer != nil, string(sdl.GetError()))
	projection_renderer = sdl.CreateRenderer(
		projection_window,
		strings.clone_to_cstring(renderer_name, context.temp_allocator),
	)
	ensure(projection_renderer != nil, string(sdl.GetError()))
	// Might need a way to limit this further to 60 fps consistently
	sdl.SetRenderVSync(controls_renderer, 1)
	sdl.SetRenderVSync(projection_renderer, 1)
	sdl.SetWindowPosition(controls_window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
	sdl.ShowWindow(controls_window)
	sdl.ShowWindow(projection_window)

	// Setup Dear ImGui, one context per window. Each context needs its own
	// platform + renderer backend and font atlas: an SDL_Texture, the font
	// atlas included, can only be used with the renderer that created it.
	imgui.CHECKVERSION()
	controls_context = imgui.CreateContext()
	projection_context = imgui.CreateContext()

	io = imgui_context_init(controls_context, controls_window, controls_renderer, main_scale)
	projection_io = imgui_context_init(
		projection_context,
		projection_window,
		projection_renderer,
		main_scale,
	)

	imgui.SetCurrentContext(controls_context)
}

@(private = "file")
imgui_context_init :: proc(
	imgui_context: ^imgui.Context,
	window: ^sdl.Window,
	renderer: ^sdl.Renderer,
	main_scale: f32,
) -> ^imgui.IO {
	imgui.SetCurrentContext(imgui_context)

	imgui_io := imgui.GetIO()
	imgui_io.ConfigFlags += {.NavEnableKeyboard}
	imgui.FontAtlas_AddFontDefaultVector(imgui_io.Fonts)

	// No imgui.ini: all layout is defined in code, so there is nothing to persist.
	imgui_io.IniFilename = nil

	imgui.StyleColorsDark()
	style := imgui.GetStyle()
	imgui.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale
	style.FontSizeBase = 14

	imsdl3.InitForSDLRenderer(window, renderer)
	imsdlrenderer3.Init(renderer)

	return imgui_io
}

game_memory_make :: proc() -> ^GameMemory {
	memory := new(GameMemory)
	memory^ = GameMemory {
		should_run = true,
	}
	return memory
}

@(export)
game_init :: proc() {
	gm = game_memory_make()

	gm.sound_settings = sound_settings_init()

	endpoint, endpoint_ok := net.parse_endpoint("127.0.0.1:42000")
	log.ensuref(endpoint_ok, "Error parsing endpoint", endpoint)
	socket, socket_err := net.make_unbound_udp_socket(.IP4)
	log.ensuref(socket_err == nil, "Error making udp socket: %v", socket_err)
	gm.lighting.socket = socket
	gm.lighting.endpoint = endpoint

	lighting_init()

	game_hot_reloaded(gm)
}

@(export)
game_should_run :: proc() -> bool {
	return gm.should_run
}

@(export)
game_shutdown :: proc() {
	sound_shutdown()

	if socket, ok := gm.lighting.socket.?; ok {
		net.close(socket)
		gm.lighting.socket = nil
	}

	gm = nil
}

@(export)
game_shutdown_window :: proc() {
	imgui.SetCurrentContext(controls_context)
	imsdlrenderer3.Shutdown()
	imsdl3.Shutdown()

	imgui.SetCurrentContext(projection_context)
	imsdlrenderer3.Shutdown()
	imsdl3.Shutdown()

	imgui.DestroyContext(controls_context)
	imgui.DestroyContext(projection_context)

	sdl.DestroyRenderer(controls_renderer)
	sdl.DestroyRenderer(projection_renderer)
	sdl.DestroyWindow(controls_window)
	sdl.DestroyWindow(projection_window)
	sdl.Quit()
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

	if gm.imgui_contexts.controls == nil {
		// First load: imgui contexts and SDL handles exist in this DLL's
		// globals. Save them into GameMemory so future reloads can restore
		// them into the new DLL's fresh globals.
		gm.imgui_contexts.controls = controls_context
		gm.imgui_contexts.projection = projection_context
		imgui.GetAllocatorFunctions(
			&gm.imgui_alloc_func,
			&gm.imgui_free_func,
			&gm.imgui_alloc_user_data,
		)
		gm.windows.controls = controls_window
		gm.windows.projection = projection_window
		gm.renderers.controls = controls_renderer
		gm.renderers.projection = projection_renderer
	} else {
		// Hot reload: the new DLL's globals are nil. Restore imgui contexts
		// and allocator functions (both are DLL-global statics in imgui, not
		// per-context), plus the SDL handles that game_init_window set up
		// once and never re-runs.
		controls_window = gm.windows.controls
		projection_window = gm.windows.projection
		controls_renderer = gm.renderers.controls
		projection_renderer = gm.renderers.projection
		controls_context = gm.imgui_contexts.controls
		projection_context = gm.imgui_contexts.projection
		imgui.SetCurrentContext(controls_context)
		imgui.SetAllocatorFunctions(
			gm.imgui_alloc_func,
			gm.imgui_free_func,
			&gm.imgui_alloc_user_data,
		)
		io = imgui.GetIO()

		imgui.SetCurrentContext(projection_context)
		projection_io = imgui.GetIO()

		imgui.SetCurrentContext(controls_context)
	}

	// Track data globals reset on every DLL reload, so they must reload here
	// too. The file-level guard in tracks_data_load makes this a no-op on the
	// initial load, where sound_settings_init already loaded them.
	tracks_data_load()

	sound_hot_reloaded(gm.sound_settings)
}

@(export)
game_force_reload :: proc() -> bool {
	return false
}

@(export)
game_force_restart :: proc() -> bool {
	return false
}

// In a web build, this is called when browser changes size.
game_parent_window_size_changed :: proc(w, h: int) {
	sdl.GetWindowSizeInPixels(controls_window, &window_width, &window_height)
}
