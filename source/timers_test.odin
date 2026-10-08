package game

import "core:testing"
import sdl "vendor:sdl3"

@(test)
timers_add_is_paused_until_started :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("test", 30))
	testing.expect(t, !gm.timers[0].running, "added timers should not run yet")
	testing.expect_value(t, gm.timers[0].remaining_s, f32(30))

	timers_update(100)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(30))
	testing.expect(t, !gm.timers[0].done)

	timers_start(0)
	testing.expect(t, gm.timers[0].running)

	timers_update(29.5)
	testing.expect(t, !gm.timers[0].done, "should still be counting")

	timers_update(1)
	testing.expect(t, gm.timers[0].done)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(0))
	testing.expect_value(t, gm.timers[0].flash_remaining_s, f32(TIMER_BLINK_SECONDS))

	timers_update(0.5)
	testing.expect(t, gm.timers[0].flash_remaining_s < TIMER_BLINK_SECONDS, "flash should fade")

	timers_stop_all()
	testing.expect_value(t, timers_active_count(), 0)
}

@(test)
timers_cap_at_max_and_reuse_done :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	for _ in 0 ..< MAX_TIMERS {
		testing.expect(t, timers_add("t", 30))
	}
	testing.expect_value(t, timers_active_count(), MAX_TIMERS)
	testing.expect(t, !timers_add("extra", 30), "should refuse past max")

	for i in 0 ..< MAX_TIMERS do timers_start(i)
	timers_update(31)
	for i in 0 ..< MAX_TIMERS do testing.expect(t, gm.timers[i].done)

	testing.expect(t, timers_add("new1", 30), "should reuse oldest done slot")
	testing.expect_value(t, gm.timers[0].label, "new1")
	testing.expect_value(t, timers_active_count(), MAX_TIMERS)

	timers_stop(0)
	testing.expect_value(t, timers_active_count(), MAX_TIMERS - 1)
}

@(test)
timers_pause_and_resume :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("p", 30))
	timers_start(0)
	timers_update(10)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(20))

	gm.timers[0].running = false
	timers_update(50)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(20))

	timers_start(0)
	timers_update(20)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(0))
	testing.expect(t, gm.timers[0].done)
}

@(test)
timers_adjust_clamps :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("a", TIMER_MAX_SECONDS))
	timers_adjust(0, +1000)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(TIMER_MAX_SECONDS))

	timers_adjust(0, -100000)
	testing.expect_value(t, gm.timers[0].remaining_s, f32(TIMER_MIN_SECONDS))

	timers_adjust(0, -100000)
	testing.expect(t, gm.timers[0].remaining_s >= 0, "should refuse to go below 0")
}

@(test)
timers_mark_records_elapsed :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("markme", 60))
	timers_start(0)
	gm.timers[0].start_tick = sdl.GetTicks() - 5000

	testing.expect(t, timers_mark(0))
	testing.expect_value(t, gm.timer_marks_count, 1)
	testing.expect_value(t, gm.timer_marks[0].timer_label, "markme")
	testing.expect(t, gm.timer_marks[0].elapsed_s >= 4.99 && gm.timer_marks[0].elapsed_s <= 5.01)

	gm.timers[0].start_tick = sdl.GetTicks() - 1234
	testing.expect(t, timers_mark(0))
	testing.expect_value(t, gm.timer_marks_count, 2)
	testing.expect(t, gm.timer_marks[1].elapsed_s >= 1.22 && gm.timer_marks[1].elapsed_s <= 1.25)

	gm.timers[0].done = true
	testing.expect(t, !timers_mark(0), "should refuse marks on done timers")
	testing.expect_value(t, gm.timer_marks_count, 2)
}

@(test)
timers_marks_clear_empties_and_frees :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("m1", 30))
	timers_start(0)
	gm.timers[0].start_tick = sdl.GetTicks() - 1000
	testing.expect(t, timers_mark(0))
	testing.expect(t, timers_add("m2", 30))
	timers_start(1)
	gm.timers[1].start_tick = sdl.GetTicks() - 2000
	testing.expect(t, timers_mark(1))
	testing.expect_value(t, gm.timer_marks_count, 2)

	timers_marks_clear()
	testing.expect_value(t, gm.timer_marks_count, 0)
}

@(test)
timers_marks_cap_at_max :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("full", 30))
	timers_start(0)

	gm.timer_marks_count = MAX_TIMER_MARKS
	testing.expect(t, !timers_mark(0), "should refuse past max")
	testing.expect(t, timers_marks_overflow_hint_seconds > 0, "should set overflow hint")
}

@(test)
timer_blink_alpha_maps_sine_phase_through_envelope :: proc(t: ^testing.T) {
	testing.expect_value(t, timer_blink_alpha(0, 0), f32(1))
	testing.expect_value(t, timer_blink_alpha(-1, 1000), f32(1))
	// tick 0: sin(0) = 0, phase 0.5, halfway between dim and bright.
	testing.expect(t, abs(timer_blink_alpha(1, 0) - 0.55) < 1e-6)
	for tick in 0 ..< 10000 {
		alpha := timer_blink_alpha(1, u64(tick))
		testing.expect(
			t,
			alpha >= TIMER_BLINK_DIM && alpha <= TIMER_BLINK_BRIGHT,
			"blink should stay inside the envelope",
		)
	}
}

@(test)
cue_fire_mask_needs_capability_and_fires_several_at_once :: proc(t: ^testing.T) {
	fire := cue_fire_mask(
		{.Has_Sound, .Has_Lighting},
		{.Sound, .Lighting, .Video},
	)
	testing.expect(t, fire == Cue_Triggers{.Sound, .Lighting})
	testing.expect(t, cue_fire_mask(Cue_Caps{}, {.Sound}) == Cue_Triggers{})
	testing.expect(t, cue_fire_mask({.Has_Sound}, Cue_Triggers{}) == Cue_Triggers{})
}

@(test)
timer_expiry_dispatches_several_cues_at_once :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	// Dispatch skips missing subsystems, so clear the globals and assert
	// the recorded cue set only.
	sound_settings = nil
	video_state = nil
	score_state = nil

	testing.expect(t, timers_add("multi", 10))
	gm.timers[0].cue_caps = {.Has_Sound, .Has_Lighting, .Has_Video, .Has_Score}
	gm.timers[0].cue_triggers = {.Sound, .Lighting, .Video, .Score}
	timers_start(0)
	timers_update(10.5)
	testing.expect(t, gm.timers[0].done)
	testing.expect(
		t,
		gm.timers[0].cue_fired == Cue_Triggers{.Sound, .Lighting, .Video, .Score},
		"one expiry should dispatch every armed cue at once",
	)

	testing.expect(t, timers_add("inert", 5))
	gm.timers[1].cue_triggers = {.Sound}
	timers_start(1)
	timers_update(6)
	testing.expect(t, gm.timers[1].done)
	testing.expect(
		t,
		gm.timers[1].cue_fired == Cue_Triggers{},
		"a cue without its capability should stay inert",
	)
}

@(test)
timers_cue_arm_helpers_set_caps_cues_and_payload :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("armed", 30))
	timers_cue_arm_sound(0, .Cat_Meow, 0.7)
	timers_cue_arm_lighting(0, .Scene)
	timers_cue_arm_projection(0, true, false)
	testing.expect(
		t,
		gm.timers[0].cue_caps == Cue_Caps{.Has_Sound, .Has_Lighting, .Has_Video},
	)
	testing.expect(
		t,
		gm.timers[0].cue_triggers == Cue_Triggers{.Sound, .Lighting, .Video},
	)
	testing.expect_value(t, gm.timers[0].cue_sound_volume, f32(0.7))
	testing.expect(t, gm.timers[0].cue_look == .Scene)
}

@(test)
timer_expiry_applies_video_and_score_payloads :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	video_previous := video_state
	video_state = new(VideoState)
	defer video_state = video_previous
	score_previous := score_state
	score_state = new(ScoreState)
	defer score_state = score_previous

	testing.expect(t, timers_add("cued", 5))
	timers_cue_arm_projection(0, true, true, "missing-page", 2)
	testing.expect_value(t, gm.timers[0].cue_video_page, "missing-page")
	testing.expect_value(t, gm.timers[0].cue_scoreboard, 2)
	timers_start(0)
	timers_update(6)
	testing.expect(t, gm.timers[0].done)
	testing.expect(t, gm.timers[0].cue_fired == Cue_Triggers{.Video, .Score})
	// A cued page that no longer exists falls back to the deck state.
	testing.expect(t, video_state.shown)
	testing.expect(t, score_state.shown)
	testing.expect_value(t, score_state.active, 2)

	testing.expect(t, timers_add("plain", 5))
	timers_cue_arm_projection(1, true, true)
	timers_start(1)
	timers_update(6)
	testing.expect(t, video_state.shown)
	testing.expect(t, score_state.shown)
	testing.expect(
		t,
		score_state.active == 2,
		"an uncued score cue leaves the selection alone",
	)
}
