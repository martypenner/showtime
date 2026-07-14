package game

import "core:mem"
import "core:testing"

// Destructive presentation is an app-owned decision, not something the generic
// UI/layout code special-cases by name. Dropping the needle is destructive (it
// interrupts the show), so it must resolve to the destructive style while
// ordinary controls stay default.
@(test)
resolve_ui_type_marks_destructive_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_resolve_type(.Drop_Needle), UI_Type.Destructive)
	testing.expect_value(t, ui_resolve_type(.Cat_Meow), UI_Type.Sound)
	testing.expect_value(t, ui_resolve_type(.RainbowSting), UI_Type.Lighting)
}

// The process host puts tracking beneath the app arena. GameMemory and maps must
// use that arena, and destroying it must return every tracked backing allocation.
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
	testing.expect(
		t,
		arena_start <= memory_address &&
		memory_address < arena_start + uintptr(game_memory_arena.block_size),
		"GameMemory should be allocated inside the app arena",
	)

	scratch := make(map[LightingFxKind]LightingFx)
	scratch[.Blackout] = LightingFx {
		key_count = 1,
	}
	testing.expect_value(t, scratch[.Blackout].key_count, u8(1))
	testing.expect(t, len(tracking_allocator.allocation_map) > 0)
}

// Tabs are split per layout file: build_layout tags every control with the group
// of the file it loaded from. chrome.rgl loads into VISIBLE_ON_ALL_GROUPS so its
// controls (the tab bar and status bar) show on every tab, and controls.rgl
// loads into the Controls tab. This pins that contract so adding the Music tab is
// just a new file + load call.
@(test)
build_layout_groups_controls_by_tab :: proc(t: ^testing.T) {
	backing_allocator := context.allocator
	game_memory_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&game_memory_arena)
	context.allocator = mem.dynamic_arena_allocator(&game_memory_arena)
	defer {
		context.allocator = backing_allocator
		mem.dynamic_arena_destroy(&game_memory_arena)
	}

	ui := ui_controls_make(layout_build())

	chrome_seen, controls_seen, music_seen: int
	for control in ui.items {
		#partial switch control.name_id {
		case .Tab_Bar, .Status_Bar:
			testing.expect_value(t, control.visibility_group, VISIBLE_ON_ALL_GROUPS)
			chrome_seen += 1
		case .ChangePlaylist, .ChangeTrack:
			testing.expect_value(t, control.visibility_group, int(Tab.Music))
			music_seen += 1
		case:
			testing.expect_value(t, control.visibility_group, int(Tab.Controls))
			controls_seen += 1
		}
	}
	testing.expect_value(t, chrome_seen, 2)
	testing.expect_value(t, music_seen, 2)
	testing.expect(t, controls_seen > 0, "expected controls.rgl controls on the Controls tab")
}
