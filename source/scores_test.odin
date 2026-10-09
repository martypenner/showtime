package game

import imgui "../vendor/odin-imgui"
import imsdlrenderer3 "../vendor/odin-imgui/imgui_impl_sdlrenderer3"
import "core:math"
import "core:mem"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
score_projection_centers_text_at_display_scales :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	gm_fixture_previous := gm
	gm = game_memory_make()
	context_previous := imgui.GetCurrentContext()
	defer {
		gm = gm_fixture_previous
		imgui.SetCurrentContext(context_previous)
	}

	surface := sdl.CreateSurface(960, 640, .RGBA32)
	ensure(surface != nil)
	defer sdl.DestroySurface(surface)
	gm.displays[.Projection].renderer = sdl.CreateSoftwareRenderer(surface)
	ensure(gm.displays[.Projection].renderer != nil)
	defer sdl.DestroyRenderer(gm.displays[.Projection].renderer)
	imgui_context := imgui.CreateContext()
	defer imgui.DestroyContext(imgui_context)
	gm.displays[.Projection].io = imgui.GetIO()
	gm.displays[.Projection].io.IniFilename = nil
	gm.displays[.Projection].io.DeltaTime = 1.0 / 60.0
	ensure(imsdlrenderer3.Init(gm.displays[.Projection].renderer))
	defer imsdlrenderer3.Shutdown()
	state := score_init()
	gm.scores = state
	defer score_shutdown()
	score_font_load()
	ensure(state.font != nil)
	state.scoreboards[0].background.width = 1920
	state.scoreboards[0].background.height = 1080
	score_value_set(.Red, 2)
	score_value_set(.Blue, 22)

	for scale in ([3]imgui.Vec2{{1, 1}, {2, 2}, {2, 1.5}}) {
		gm.displays[.Projection].io.DisplaySize = {960 / scale.x, 640 / scale.y}
		gm.displays[.Projection].io.DisplayFramebufferScale = scale
		for font_scale in ([2]f32{1, 1.5}) {
			imgui.GetStyle().FontScaleDpi = font_scale
			imsdlrenderer3.NewFrame()
			imgui.NewFrame()
			imgui.SetNextWindowPos({0, 0})
			imgui.SetNextWindowSize(gm.displays[.Projection].io.DisplaySize)
			imgui.Begin("Score test", nil, {.NoTitleBar, .NoSavedSettings, .NoScrollbar})
			score_projection_draw()
			// Letterboxing adds 50 pixels above the 960x540 background.
			// The last item is Blue's score, centered at (720, 433.4) in pixels.
			minimum := imgui.GetItemRectMin()
			maximum := imgui.GetItemRectMax()
			center := (minimum + maximum) * 0.5
			testing.expectf(
				t,
				math.abs(center.x * scale.x - 720) < 2,
				"blue score x at scale %v, font scale %f: %f",
				scale,
				font_scale,
				center.x * scale.x,
			)
			testing.expectf(
				t,
				math.abs(center.y * scale.y - 433.4) < 2,
				"blue score y at scale %v, font scale %f: %f",
				scale,
				font_scale,
				center.y * scale.y,
			)
			testing.expectf(
				t,
				math.abs((maximum.y - minimum.y) * scale.y - 226.8) < 2,
				"score height at scale %v, font scale %f: %f",
				scale,
				font_scale,
				(maximum.y - minimum.y) * scale.y,
			)
			imgui.End()
			imgui.Render()
		}
	}
}

@(test)
score_seeds_three_boards :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	state := score_test_begin()
	defer score_test_end(state)

	testing.expect(t, !state.shown, "score state should start hidden")
	testing.expect(t, state.font == nil, "font should start nil until loaded")
	testing.expect_value(t, state.active, 0)

	names := [3]string{"Game", "Final", "Season"}
	for board, i in state.scoreboards {
		testing.expect_value(t, board.name, names[i])
		testing.expect(t, board.background.texture == nil, "background should start unloaded")
		testing.expect_value(t, board.red, u16(0))
		testing.expect_value(t, board.blue, u16(0))
	}
}

@(test)
score_playing_timer_owns_projection :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()
	state := score_init()
	gm.scores = state
	defer score_shutdown()

	state.shown = true
	testing.expect(t, timers_add("test", 30), "timer add should succeed")

	timers_start(0)
	testing.expect(t, state.shown, "starting a timer should leave the slide armed")
	testing.expect(t, !score_projection_shown(), "a playing timer should own the projection")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)

	// The Show flag stays armed but never overrides a running timer.
	state.shown = true
	testing.expect(t, !score_projection_shown(), "the flag should not override the timer")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)

	timers_stop_all()
	testing.expect(t, score_projection_shown(), "stopping the timer gives the projection back")
}

@(test)
score_values_share_between_game_and_final :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	state := score_test_begin()
	defer score_test_end(state)

	score_value_set(.Red, 21)
	score_value_set(.Blue, 14)
	testing.expect_value(t, score_value_get(state, .Red), u16(21))
	testing.expect_value(t, score_value_get(state, .Blue), u16(14))

	// Final shows the same numbers.
	state.active = 1
	testing.expect_value(t, score_value_get(state, .Red), u16(21))
	testing.expect_value(t, score_value_get(state, .Blue), u16(14))

	// Season keeps its own.
	state.active = 2
	testing.expect_value(t, score_value_get(state, .Red), u16(0))
	score_value_set(.Red, 7)
	testing.expect_value(t, score_value_get(state, .Red), u16(7))

	// Editing the shared set from Final lands on Game too, clamped.
	state.active = 1
	score_value_set(.Red, -5)
	testing.expect_value(t, score_value_get(state, .Red), u16(0))
	score_value_set(.Red, 10_000)
	testing.expect_value(t, score_value_get(state, .Red), u16(SCORE_MAX))
	state.active = 0
	testing.expect_value(t, score_value_get(state, .Red), u16(SCORE_MAX))

	score_reset()
	testing.expect(
		t,
		score_value_get(state, .Red) == 0 && score_value_get(state, .Blue) == 0,
		"reset should zero the shared scores",
	)
	state.active = 2
	testing.expect_value(t, score_value_get(state, .Red), u16(7))
}

@(private = "file")
score_test_begin :: proc() -> ^ScoreState {
	state := score_init()
	if gm != nil do gm.scores = state
	return state
}

@(private = "file")
score_test_end :: proc(state: ^ScoreState) {
	score_shutdown()
	free(state)
}
