package game

import "core:testing"
import sdl "vendor:sdl3"

@(test)
timers_add_is_paused_until_started :: proc(t: ^testing.T) {
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
	gm = game_memory_make()

	testing.expect(t, timers_add("full", 30))
	timers_start(0)

	gm.timer_marks_count = MAX_TIMER_MARKS
	testing.expect(t, !timers_mark(0), "should refuse past max")
	testing.expect(t, timers_marks_overflow_hint_seconds > 0, "should set overflow hint")
}
