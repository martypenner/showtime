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
import "core:math"
import "core:net"
import "core:strings"
import sdl "vendor:sdl3"

_ :: log
_ :: fmt

gm: ^GameMemory

DisplayKind :: enum u8 {
	Controls,
	Projection,
}

// One window's handles plus the imgui backend bound to them.
// kind identifies which role this display serves.
Display :: struct {
	kind:          DisplayKind,
	window:        ^sdl.Window,
	renderer:      ^sdl.Renderer,
	imgui_context: ^imgui.Context,
	io:            ^imgui.IO,
}

GameMemory :: struct {
	should_run:            bool,
	sound_settings:        ^SoundSettings,
	lighting:              struct {
		socket:         Maybe(net.UDP_Socket),
		endpoint:       net.Endpoint,
		active_look:    LightingLook,
		fx:             [LightingFxKind]LightingFx,
		fx_osc_address: [LightingFxKind]string,
		// Lighting picker color, edited in the controls window.
		color:          [3]f32,
	},
	active_tab:            Tab,
	timers:                [MAX_TIMERS]Timer,
	timer_marks:           [MAX_TIMER_MARKS]TimerMark,
	timer_marks_count:     int,
	timer_serial_next:     int,
	timer_ui:              struct {
		overflow_hint_seconds:       f32,
		marks_overflow_hint_seconds: f32,
		label_input:                 [64]u8,
		seconds_input:               f32,
	},
	game_mode:             struct {
		sounds_like_a_song_playlist: ^Playlist,
	},
	video:                 ^VideoState,
	scores:                ^ScoreState,
	// Read-only track dataset, loaded once.
	tracks:                map[string]GeneratedTrack,
	tracks_data:           []byte,
	frame:                 struct {
		last_time: u64,
		dt:        f32,
	},
	displays:              [DisplayKind]Display,
	// imgui allocator functions, DLL-global statics that reset to nil when
	// a new DLL loads, so they must be saved on first init and restored here.
	imgui_alloc_func:      imgui.MemAllocFunc,
	imgui_free_func:       imgui.MemFreeFunc,
	imgui_alloc_user_data: rawptr,
}

// Unified envelope: at_seconds plus value. Music gain, lighting weight,
// duck gain, and timer blink alpha all sample through envelope_value_at,
// so the timestamped-lerp lives in one place. Points must be in ascending
// at_seconds order, starting at 0; sampling holds the first value before
// the first point and the last value past the last point.
Envelope_Point :: struct {
	at_seconds: f32,
	value:      f32,
}

ENVELOPE_KEYS_MAX :: 8

envelope_value_at :: proc(keys: []Envelope_Point, elapsed_seconds: f32) -> f32 {
	ensure(len(keys) > 0)
	previous := keys[0]
	if elapsed_seconds <= previous.at_seconds do return previous.value
	for i := 1; i < len(keys); i += 1 {
		point := keys[i]
		if elapsed_seconds <= point.at_seconds {
			span := point.at_seconds - previous.at_seconds
			fraction := f32(1)
			if span > 0 do fraction = math.clamp((elapsed_seconds - previous.at_seconds) / span, 0, 1)
			return previous.value + (point.value - previous.value) * fraction
		}
		previous = point
	}
	return previous.value
}

// Ticks a seconds-remaining countdown toward zero, reporting expiry.
// Sticks at zero once expired, so idle countdowns read expired.
countdown_tick :: proc(remaining: ^f32, dt: f32) -> bool {
	ensure(remaining != nil)
	if remaining^ <= 0 do return true
	remaining^ = max(remaining^ - dt, 0)
	return remaining^ <= 0
}

update :: proc() {
	current_time := sdl.GetTicks()
	gm.frame.dt = f32(current_time - gm.frame.last_time) / 1000 // Convert milliseconds to seconds
	gm.frame.last_time = current_time

	event: sdl.Event
	for sdl.PollEvent(&event) {
		// QUIT has no windowID, so it must be handled before the
		// per-window routing below. SDL's default SIGINT/SIGTERM
		// handlers post this event, which is what Ctrl-C and the
		// watch script's kill send. Any window closing should quit.
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			gm.should_run = false
		}

		for kind in DisplayKind {
			display := &gm.displays[kind]
			if event.window.windowID != sdl.GetWindowID(display.window) do continue
			imgui.SetCurrentContext(display.imgui_context)
			imsdl3.ProcessEvent(&event)

			// Only the controls window takes hotkeys.
			if kind != .Controls do continue
			#partial switch event.type {
			case .KEY_DOWN:
				if !event.key.repeat ||
				   event.key.key == sdl.K_PLUS ||
				   event.key.key == sdl.K_EQUALS ||
				   event.key.key == sdl.K_MINUS {
					if gm.active_tab == .Controls && !display.io.WantTextInput {
						hotkeys_handle_key(event.key.key)
					}
				}
			}
		}
	}

	sound_update(gm.frame.dt)
	lighting_update(gm.frame.dt)
	timers_update(gm.frame.dt)
	video_update()
}

draw :: proc() {
	draw_display(.Projection, projection_draw)
	draw_display(.Controls, controls_draw)
}

// Active timers own the projection; score wins over video when idle.
ProjectionSource :: enum u8 {
	Timer,
	Video,
	Score,
}

projection_source_resolve :: proc() -> ProjectionSource {
	if timers_any_running() do return .Timer
	if score_projection_shown() do return .Score
	if video_projection_shown() do return .Video
	return .Timer
}

@(private = "file")
draw_display :: proc(kind: DisplayKind, draw_ui: proc()) {
	display := &gm.displays[kind]
	imgui.SetCurrentContext(display.imgui_context)

	imsdlrenderer3.NewFrame()
	imsdl3.NewFrame()
	imgui.NewFrame()

	draw_ui()
	imgui.Render()

	sdl.SetRenderDrawColor(display.renderer, 16, 16, 16, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(display.renderer)
	if kind == .Projection {
		// Slide art sits under the imgui draw data, at 1:1 pixel scale.
		sdl.SetRenderScale(display.renderer, 1, 1)
		switch projection_source_resolve() {
		case .Score:
			score_projection_background_render(display.renderer)
		case .Video:
			video_projection_render(display.renderer)
		case .Timer:
		}
	}
	sdl.SetRenderScale(
		display.renderer,
		display.io.DisplayFramebufferScale.x,
		display.io.DisplayFramebufferScale.y,
	)
	imsdlrenderer3.RenderDrawData(imgui.GetDrawData(), display.renderer)
	sdl.RenderPresent(display.renderer)
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
	if gm == nil do gm = game_memory_make()

	ensure(sdl.SetAppMetadata("Showtime", "1.0", "showtime"), string(sdl.GetError()))

	ensure(sdl.Init({.VIDEO, .AUDIO}))
	main_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())

	renderer_name := "vulkan"
	when ODIN_OS == .Darwin {
		renderer_name = "metal"
	}

	window_width, window_height := i32(1280), i32(720)
	for kind in DisplayKind {
		display := &gm.displays[kind]
		display.kind = kind
		display.window = sdl.CreateWindow(
			display_titles[kind],
			window_width,
			window_height,
			display_flags(kind),
		)
		ensure(display.window != nil, string(sdl.GetError()))
		display.renderer = sdl.CreateRenderer(
			display.window,
			strings.clone_to_cstring(renderer_name, context.temp_allocator),
		)
		ensure(display.renderer != nil, string(sdl.GetError()))
		// Might need a way to limit this further to 60 fps consistently
		sdl.SetRenderVSync(display.renderer, 1)
		sdl.ShowWindow(display.window)
	}

	sdl.SetWindowPosition(
		gm.displays[.Controls].window,
		sdl.WINDOWPOS_CENTERED,
		sdl.WINDOWPOS_CENTERED,
	)

	// Setup Dear ImGui, one context per window. Each context needs its own
	// platform + renderer backend and font atlas: an SDL_Texture, the font
	// atlas included, can only be used with the renderer that created it.
	imgui.CHECKVERSION()
	for kind in DisplayKind {
		display := &gm.displays[kind]
		display.imgui_context = imgui.CreateContext()
		display.io = imgui_context_init(
			display.imgui_context,
			display.window,
			display.renderer,
			main_scale,
		)
	}

	imgui.SetCurrentContext(gm.displays[.Controls].imgui_context)
}

@(private = "file")
display_titles := [DisplayKind]cstring {
	.Controls   = "Showtime Control",
	.Projection = "Showtime Projection",
}

// Window flags differ per role: the projection always starts maximized,
// the controls window only outside debug builds.
@(private = "file")
display_flags :: proc(kind: DisplayKind) -> sdl.WindowFlags {
	switch kind {
	case .Controls:
		flags := sdl.WindowFlags{.RESIZABLE, .HIDDEN, .HIGH_PIXEL_DENSITY}
		when !ODIN_DEBUG {
			flags += {.MAXIMIZED}
		}
		return flags
	case .Projection:
		return {.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN, .MAXIMIZED}
	}
	unreachable()
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
		timer_ui = {seconds_input = DEFAULT_TIMER_SECONDS},
		lighting = {color = {1, 1, 1}},
	}
	return memory
}

@(export)
game_init :: proc() {
	// Reuse the existing root instead of allocating a second one.
	if gm == nil do gm = game_memory_make()

	gm.sound_settings = sound_settings_init()

	gm.video = video_init()

	gm.scores = score_init()
	imgui.SetCurrentContext(gm.displays[.Projection].imgui_context)
	score_font_load()
	imgui.SetCurrentContext(gm.displays[.Controls].imgui_context)

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

	video_shutdown()

	score_shutdown()

	if socket, ok := gm.lighting.socket.?; ok {
		net.close(socket)
		gm.lighting.socket = nil
	}

	gm = nil
}

@(export)
game_shutdown_window :: proc() {
	for kind in DisplayKind {
		display := &gm.displays[kind]
		imgui.SetCurrentContext(display.imgui_context)
		imsdlrenderer3.Shutdown()
		imsdl3.Shutdown()
		imgui.DestroyContext(display.imgui_context)
		sdl.DestroyRenderer(display.renderer)
		sdl.DestroyWindow(display.window)
	}
	sdl.Quit()
}

@(export)
game_memory :: proc() -> rawptr {
	return gm
}

@(export)
game_memory_size :: proc() -> int {
	// Nested video layouts also require a restart when they change.
	return(
		size_of(GameMemory) +
		size_of(VideoState) +
		size_of(VideoPlayback) +
		size_of(VideoDecoder) \
	)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	gm = (^GameMemory)(mem)

	if gm.imgui_alloc_func == nil {
		// First load: save the imgui allocator functions, DLL-global
		// statics that reset to nil when a new DLL loads.
		imgui.GetAllocatorFunctions(
			&gm.imgui_alloc_func,
			&gm.imgui_free_func,
			&gm.imgui_alloc_user_data,
		)
	} else {
		// Hot reload: restore the allocator functions into the new DLL,
		// then refresh the per-context IO pointers.
		imgui.SetCurrentContext(gm.displays[.Controls].imgui_context)
		imgui.SetAllocatorFunctions(
			gm.imgui_alloc_func,
			gm.imgui_free_func,
			&gm.imgui_alloc_user_data,
		)
		for kind in DisplayKind {
			display := &gm.displays[kind]
			imgui.SetCurrentContext(display.imgui_context)
			display.io = imgui.GetIO()
		}

		imgui.SetCurrentContext(gm.displays[.Controls].imgui_context)
	}

	// No-op once loaded.
	tracks_data_load()
}

@(export)
game_force_reload :: proc() -> bool {
	return false
}

@(export)
game_force_restart :: proc() -> bool {
	return false
}

// In a web build, this is called when browser changes size. Window sizes
// are queried per frame where needed, so there is nothing to store here.
game_parent_window_size_changed :: proc(w, h: int) {
}
