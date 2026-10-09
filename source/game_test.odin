package game

import "core:mem"
import "core:testing"

GameTestArena :: struct {
	arena:              mem.Dynamic_Arena,
	allocator_previous: mem.Allocator,
	memory_previous:    ^GameMemory,
}

game_test_arena_init :: proc(arena: ^GameTestArena) -> mem.Allocator {
	arena.allocator_previous = context.allocator
	arena.memory_previous = gm
	mem.dynamic_arena_init(&arena.arena)
	return mem.dynamic_arena_allocator(&arena.arena)
}

game_test_arena_destroy :: proc(arena: ^GameTestArena) -> mem.Allocator {
	gm = arena.memory_previous
	mem.dynamic_arena_destroy(&arena.arena)
	return arena.allocator_previous
}

@(test)
game_memory_arena_owns_memory_and_returns_backing_allocations :: proc(t: ^testing.T) {
	backing_allocator := context.allocator
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, backing_allocator)
	tracking := mem.tracking_allocator(&tracking_allocator)

	game_memory_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&game_memory_arena,
		block_allocator = tracking,
		array_allocator = tracking,
	)
	game_memory_arena_mutex: mem.Mutex_Allocator
	mem.mutex_allocator_init(
		&game_memory_arena_mutex,
		mem.dynamic_arena_allocator(&game_memory_arena),
	)
	context.allocator = mem.mutex_allocator(&game_memory_arena_mutex)
	defer {
		context.allocator = backing_allocator
		mem.dynamic_arena_destroy(&game_memory_arena)
		testing.expect_value(t, len(tracking_allocator.allocation_map), 0)
		testing.expect_value(t, len(tracking_allocator.bad_free_array), 0)
		mem.tracking_allocator_destroy(&tracking_allocator)
	}

	memory := game_memory_make()
	arena_start := uintptr(game_memory_arena.current_block)
	memory_address := uintptr(memory)
	memory_in_arena :=
		arena_start <= memory_address &&
		memory_address < arena_start + uintptr(game_memory_arena.block_size)
	if !memory_in_arena {
		// Larger roots live in dedicated arena blocks.
		for block in game_memory_arena.out_band_allocations {
			block_start := uintptr(block)
			if block_start <= memory_address &&
			   memory_address < block_start + uintptr(size_of(GameMemory)) {
				memory_in_arena = true
				break
			}
		}
	}
	testing.expect(
		t,
		memory_in_arena,
		"GameMemory should be allocated inside the app arena",
	)

	scratch := make(map[LightingFxKind]LightingFx)
	scratch[.Blackout] = LightingFx {
		key_count = 1,
	}
	testing.expect_value(t, scratch[.Blackout].key_count, u8(1))
	testing.expect(t, len(tracking_allocator.allocation_map) > 0)
}

@(test)
envelope_value_at_holds_endpoints_and_lerps :: proc(t: ^testing.T) {
	keys := [4]Envelope_Point{{0, 0.25}, {2, 1}, {3, 1}, {4, 0}}
	testing.expect_value(t, envelope_value_at(keys[:], -1), f32(0.25))
	testing.expect_value(t, envelope_value_at(keys[:], 0), f32(0.25))
	testing.expect_value(t, envelope_value_at(keys[:], 1), f32(0.625))
	testing.expect_value(t, envelope_value_at(keys[:], 2), f32(1))
	testing.expect_value(t, envelope_value_at(keys[:], 2.5), f32(1))
	testing.expect_value(t, envelope_value_at(keys[:], 3), f32(1))
	testing.expect_value(t, envelope_value_at(keys[:], 3.5), f32(0.5))
	testing.expect_value(t, envelope_value_at(keys[:], 4), f32(0))
	testing.expect_value(t, envelope_value_at(keys[:], 99), f32(0))
}

@(test)
envelope_value_at_single_key_holds :: proc(t: ^testing.T) {
	keys := [1]Envelope_Point{{0, 0.7}}
	testing.expect_value(t, envelope_value_at(keys[:], 0), f32(0.7))
	testing.expect_value(t, envelope_value_at(keys[:], 50), f32(0.7))
}

@(test)
countdown_tick_reports_expiry_and_clamps_at_zero :: proc(t: ^testing.T) {
	remaining := f32(1)
	testing.expect(t, !countdown_tick(&remaining, 0.4))
	testing.expect_value(t, remaining, f32(0.6))
	testing.expect(t, countdown_tick(&remaining, 0.6))
	testing.expect_value(t, remaining, f32(0))
	testing.expect(t, countdown_tick(&remaining, 5), "ticking past zero stays expired")
	testing.expect_value(t, remaining, f32(0))
	zero := f32(0)
	testing.expect(t, countdown_tick(&zero, 1), "an idle countdown reads expired")
}
