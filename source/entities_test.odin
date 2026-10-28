package game

import hm "core:container/handle_map"
import "core:testing"

@(test)
entity_handles_reuse_slots_without_aliasing :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	first := timers_add("first", 30)
	second := timers_add("second", 30)
	testing.expect_value(t, timers_active_count(), 2)

	entity_destroy(first)
	testing.expect_value(t, timers_active_count(), 1)
	_, alive := entity_get(first)
	testing.expect(t, !alive, "destroyed handle must not resolve")

	third := timers_add("third", 30)
	testing.expect(t, third != first, "reused slot must bump the generation")
	testing.expect_value(t, timers_active_count(), 2)
	testing.expect_value(t, timer_at(0).label, "second")
	testing.expect_value(t, timer_at(1).label, "third")

	_, still_alive := entity_get(second)
	testing.expect(t, still_alive)
}

@(test)
entity_lighting_state_survives_middle_destroy :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	first := entity_create({.Lighting}, "first")
	middle := entity_create({.Lighting}, "middle")
	last := entity_create({.Lighting}, "last")
	lighting_state(first).look = .Scene
	lighting_state(middle).look = .Challenge
	lighting_state(last).look = .FinalShowdown
	last_state := lighting_state(last)

	entity_destroy(middle)
	_, middle_alive := entity_get(middle)
	testing.expect(t, !middle_alive)
	testing.expect_value(t, hm.len(gm.entities.lighting_states), 2)
	testing.expect_value(t, lighting_state(first).look, LightingLook.Scene)
	testing.expect_value(t, lighting_state(last).look, LightingLook.FinalShowdown)
	testing.expect(t, lighting_state(last) == last_state, "payload must not move")
	testing.expect_value(t, lighting_state(last).owner, last)

	// The freed payload slot is reused with fresh state for the new owner.
	reused := entity_create({.Lighting}, "reused")
	testing.expect_value(t, lighting_state(reused).look, LightingLook.House)
	testing.expect_value(t, lighting_state(reused).owner, reused)
	testing.expect_value(t, lighting_state(last).look, LightingLook.FinalShowdown)
	testing.expect_value(t, lighting_entity_ensure(), first)
}

@(test)
entity_pointers_survive_store_growth :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	handle := entity_create({.Lighting, .Timer}, "anchor")
	entity := entity_must_get(handle)
	state := lighting_state(handle)
	state.look = .CenterFocus
	for _ in 0 ..< 5000 do _ = entity_create({.Lighting, .Mark}, "filler")

	testing.expect(t, entity_must_get(handle) == entity, "entity must not move")
	testing.expect(t, lighting_state(handle) == state, "lighting payload must not move")
	testing.expect_value(t, entity.label, "anchor")
	testing.expect_value(t, state.look, LightingLook.CenterFocus)
}

@(test)
entity_stale_handles_never_resolve_after_slot_reuse :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	stale := entity_create({.Mark}, "stale")
	entity_destroy(stale)
	// Past the 255 reuses that wrapped the previous 8-bit generation.
	for _ in 0 ..< 600 {
		handle := entity_create({.Mark}, "reuse")
		testing.expect_value(t, handle.idx, stale.idx)
		testing.expect(t, handle != stale)
		_, stale_alive := entity_get(stale)
		testing.expect(t, !stale_alive)
		entity_destroy(handle)
	}
	_, nil_alive := entity_get(ENTITY_HANDLE_NIL)
	testing.expect(t, !nil_alive)
}

@(test)
entity_projection_resolve_follows_timer_score_video_blank :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	source, handle := entity_projection_resolve()
	testing.expect_value(t, source, ProjectionSource.Blank)
	testing.expect_value(t, handle, ENTITY_HANDLE_NIL)

	video := entity_create({.Video, .Projection}, "Video")
	entity_record_emit(.Projection, video)
	source, handle = entity_projection_resolve()
	testing.expect_value(t, source, ProjectionSource.Video)
	testing.expect_value(t, handle, video)

	score := entity_create({.Score, .Projection}, "Game")
	entity_record_emit(.Projection, score)
	source, handle = entity_projection_resolve()
	testing.expect_value(t, source, ProjectionSource.Score)
	testing.expect_value(t, handle, score)

	testing.expect(t, timers_add("timer", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	entity_record_emit(.Projection, gm.entities.timer[0])
	source, handle = entity_projection_resolve()
	testing.expect_value(t, source, ProjectionSource.Timer)
	testing.expect_value(t, handle, gm.entities.timer[0])
}

@(test)
entity_fade_samples_single_segment_through_envelope :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	handle := entity_create({.Video, .Projection}, "Video")
	entity := entity_must_get(handle)
	entity_fade_start(entity, 2, 0, 1)
	testing.expect_value(t, entity_fade_value_at(entity), f32(0))
	testing.expect(t, !entity_fade_tick(entity, 1))
	testing.expect_value(t, entity_fade_value_at(entity), f32(0.5))
	testing.expect(t, entity_fade_tick(entity, 1))
	testing.expect_value(t, entity_fade_value_at(entity), f32(1))
	testing.expect(t, !entity_fade_tick(entity, 1), "spent fades stay spent")
}
