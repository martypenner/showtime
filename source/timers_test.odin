package game

import "core:testing"
import sdl "vendor:sdl3"

@(test)
timers_add_is_paused_until_started :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("test", 30) != ENTITY_HANDLE_NIL)
	testing.expect(t, !timer_at(0).timer.running, "added timers should not run yet")
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(30))

	timers_update(100)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(30))
	testing.expect(t, !timer_at(0).timer.done)

	timers_start(0)
	testing.expect(t, timer_at(0).timer.running)

	timers_update(29.5)
	testing.expect(t, !timer_at(0).timer.done, "should still be counting")

	timers_update(1)
	testing.expect(t, timer_at(0).timer.done)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(0))
	testing.expect_value(t, timer_at(0).timer.flash_remaining_s, f32(TIMER_BLINK_SECONDS))

	timers_update(0.5)
	testing.expect(
		t,
		timer_at(0).timer.flash_remaining_s < TIMER_BLINK_SECONDS,
		"flash should fade",
	)

	timers_stop_all()
	testing.expect_value(t, timers_active_count(), 0)
}

@(test)
timers_grow_unbounded_and_keep_creation_order :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	for i in 0 ..< 30 {
		testing.expect(t, timers_add("t", 30) != ENTITY_HANDLE_NIL)
		_ = i
	}
	testing.expect_value(t, timers_active_count(), 30)
	testing.expect(t, timers_add("extra", 30) != ENTITY_HANDLE_NIL, "timers are unbounded now")
	testing.expect_value(t, timers_active_count(), 31)

	for i in 0 ..< timers_active_count() do timers_start(i)
	timers_update(31)
	for i in 0 ..< timers_active_count() do testing.expect(t, timer_at(i).timer.done)

	timers_add("new1", 30)
	testing.expect_value(t, timers_active_count(), 32)
	testing.expect_value(t, timer_at(31).label, "new1")

	timers_stop(0)
	testing.expect_value(t, timers_active_count(), 31)
	testing.expect_value(t, timer_at(0).label, "t")
}

@(test)
timers_pause_and_resume :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("p", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	timers_update(10)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(20))

	timer_at(0).timer.running = false
	timers_update(50)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(20))

	timers_start(0)
	timers_update(20)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(0))
	testing.expect(t, timer_at(0).timer.done)
}

@(test)
timers_adjust_clamps :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("a", TIMER_MAX_SECONDS) != ENTITY_HANDLE_NIL)
	timers_adjust(0, +1000)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(TIMER_MAX_SECONDS))

	timers_adjust(0, -100000)
	testing.expect_value(t, timer_at(0).timer.remaining_s, f32(TIMER_MIN_SECONDS))

	timers_adjust(0, -100000)
	testing.expect(t, timer_at(0).timer.remaining_s >= 0, "should refuse to go below 0")
}

@(test)
timers_mark_records_elapsed :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("markme", 60) != ENTITY_HANDLE_NIL)
	timers_start(0)
	timer_at(0).timer.start_tick = sdl.GetTicks() - 5000

	testing.expect(t, timers_mark(0))
	testing.expect_value(t, timers_marks_count(), 1)
	first, first_ok := entity_get(gm.entities.mark[0])
	testing.expect(t, first_ok)
	testing.expect_value(t, first.label, "markme")
	testing.expect(t, first.mark.elapsed_s >= 4.99 && first.mark.elapsed_s <= 5.01)

	timer_at(0).timer.start_tick = sdl.GetTicks() - 1234
	testing.expect(t, timers_mark(0))
	testing.expect_value(t, timers_marks_count(), 2)
	second, second_ok := entity_get(gm.entities.mark[1])
	testing.expect(t, second_ok)
	testing.expect(t, second.mark.elapsed_s >= 1.22 && second.mark.elapsed_s <= 1.25)

	timer_at(0).timer.done = true
	testing.expect(t, !timers_mark(0), "should refuse marks on done timers")
	testing.expect_value(t, timers_marks_count(), 2)
}

@(test)
timers_marks_clear_empties :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("m1", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	timer_at(0).timer.start_tick = sdl.GetTicks() - 1000
	testing.expect(t, timers_mark(0))
	testing.expect(t, timers_add("m2", 30) != ENTITY_HANDLE_NIL)
	timers_start(1)
	timer_at(1).timer.start_tick = sdl.GetTicks() - 2000
	testing.expect(t, timers_mark(1))
	testing.expect_value(t, timers_marks_count(), 2)

	timers_marks_clear()
	testing.expect_value(t, timers_marks_count(), 0)
}

@(test)
timers_marks_grow_unbounded :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("full", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)

	for _ in 0 ..< 200 {
		testing.expect(t, timers_mark(0), "marks are unbounded now")
	}
	testing.expect_value(t, timers_marks_count(), 200)
}

@(test)
timers_destroy_leaves_marks_alone :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	testing.expect(t, timers_add("doomed", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	timer_at(0).timer.start_tick = sdl.GetTicks() - 1000
	testing.expect(t, timers_mark(0))
	testing.expect_value(t, timers_marks_count(), 1)

	timers_stop(0)
	testing.expect_value(t, timers_active_count(), 0)
	testing.expect_value(t, timers_marks_count(), 1)
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
		{.Has_Sound, .Has_Music, .Has_Lighting},
		{.Sound, .Music, .Lighting, .Video},
	)
	testing.expect(t, fire == Cue_Triggers{.Sound, .Music, .Lighting})
	testing.expect(t, cue_fire_mask(Cue_Caps{}, {.Sound}) == Cue_Triggers{})
	testing.expect(t, cue_fire_mask({.Has_Sound}, Cue_Triggers{}) == Cue_Triggers{})
}

@(test)
timer_expiry_dispatches_several_cues_at_once :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	// Missing subsystems skip side effects; assert the recorded set only.
	gm.sound_settings = nil
	gm.scores = nil

	testing.expect(t, timers_add("multi", 10) != ENTITY_HANDLE_NIL)
	timer_at(0).cue.caps = {.Has_Sound, .Has_Music, .Has_Lighting, .Has_Video, .Has_Score}
	timer_at(0).cue.triggers = {.Sound, .Music, .Lighting, .Video, .Score}
	timers_start(0)
	timers_update(10.5)
	testing.expect(t, timer_at(0).timer.done)
	testing.expect(
		t,
		timer_at(0).cue.fired == Cue_Triggers{.Sound, .Music, .Lighting, .Video, .Score},
		"one expiry should dispatch every armed cue at once",
	)

	testing.expect(t, timers_add("inert", 5) != ENTITY_HANDLE_NIL)
	timer_at(1).cue.triggers = {.Sound}
	timers_start(1)
	timers_update(6)
	testing.expect(t, timer_at(1).timer.done)
	testing.expect(
		t,
		timer_at(1).cue.fired == Cue_Triggers{},
		"a cue without its capability should stay inert",
	)
}

@(test)
timers_cue_arm_helpers_set_caps_cues_and_payload :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	playlist_handle := entity_playlist_create(playlist_name_string(.Show_Starters))
	testing.expect(t, timers_add("armed", 30) != ENTITY_HANDLE_NIL)
	timers_cue_arm_sound(0, .Cat_Meow, 0.7)
	timers_cue_arm_music(0, .Show_Starters, 0.5, 1, 2)
	timers_cue_arm_lighting(0, .Scene)
	timers_cue_arm_projection(0, true, false)
	testing.expect(
		t,
		timer_at(0).cue.caps == Cue_Caps{.Has_Sound, .Has_Music, .Has_Lighting, .Has_Video},
	)
	testing.expect(t, timer_at(0).cue.triggers == Cue_Triggers{.Sound, .Music, .Lighting, .Video})
	testing.expect_value(t, timer_at(0).cue.sound_volume, f32(0.7))
	testing.expect(t, timer_at(0).cue.playlist == playlist_handle)
	testing.expect_value(t, timer_at(0).cue.music_volume, f32(0.5))
	testing.expect(t, timer_at(0).cue.look == .Scene)
	testing.expect(t, !timer_at(0).cue.lighting_fx_reset)
}

@(test)
timer_expiry_applies_video_and_score_payloads :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	video_entity_ensure()
	score_previous := gm.scores
	gm.scores = new(ScoreState)
	score_entities_ensure()
	defer gm.scores = score_previous

	testing.expect(t, timers_add("cued", 5) != ENTITY_HANDLE_NIL)
	timers_cue_arm_projection(0, true, true, "missing-page", 2)
	testing.expect_value(t, timer_at(0).cue.video_page, "missing-page")
	testing.expect_value(t, timer_at(0).cue.scoreboard, 2)
	timers_start(0)
	timers_update(6)
	testing.expect(t, timer_at(0).timer.done)
	testing.expect(t, timer_at(0).cue.fired == Cue_Triggers{.Video, .Score})
	// A cued page that no longer exists leaves the selection alone.
	testing.expect_value(t, video_entity_get().video.selected, "")
	testing.expect(t, gm.scores.active >= 0)
	testing.expect_value(t, gm.scores.active, 2)

	// Hiding keeps the cued board remembered for the next show.
	score_projection_hide()
	testing.expect_value(t, gm.scores_ui.board, 2)

	testing.expect(t, timers_add("plain", 5) != ENTITY_HANDLE_NIL)
	timers_cue_arm_projection(1, true, true)
	timers_start(1)
	timers_update(6)
	testing.expect_value(t, video_entity_get().video.selected, "")
	testing.expect(t, gm.scores.active >= 0)
	testing.expect(t, gm.scores.active == 2, "an uncued score cue shows the remembered board")

	// Arming a projection cue without firing never touches the selection.
	timers_cue_arm_projection(1, false, true, "", 1)
	testing.expect_value(t, gm.scores.active, 2)
	testing.expect_value(t, gm.scores_ui.board, 2)
}
