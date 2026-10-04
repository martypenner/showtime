package game

import "core:testing"

@(test)
score_seeds_three_boards :: proc(t: ^testing.T) {
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
score_playing_timer_hides_presentation :: proc(t: ^testing.T) {
	state := score_test_begin()
	defer score_test_end(state)
	gm = game_memory_make()
	defer free(gm)

	testing.expect(t, timers_add("test", 30), "timer add should succeed")

	state.shown = true
	testing.expect(t, state.shown, "score state should show when set")

	timers_start(0)
	score_update()
	testing.expect(t, !state.shown, "a playing timer should hide the score state")

	// Re-showing while the timer runs is not enough: the projection checks
	// the timer too.
	state.shown = true
	testing.expect(t, state.shown, "score state should show when set again")
	testing.expect(t, !score_projection_shown(), "projection should favor the playing timer")

	timers_stop_all()
	score_update()
	testing.expect(t, score_projection_shown(), "stopping the timer gives the projection back")
}

@(test)
score_values_share_between_game_and_final :: proc(t: ^testing.T) {
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
	return score_init()
}

@(private = "file")
score_test_end :: proc(state: ^ScoreState) {
	score_shutdown()
	free(state)
}
