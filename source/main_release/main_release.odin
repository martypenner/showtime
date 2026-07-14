/*
For making a release exe that does not use hot reload.
*/

package main_release

import game ".."
import "core:log"
import "core:mem"
import "core:os"
import rl "vendor:raylib"

_ :: mem

USE_TRACKING_ALLOCATOR :: #config(USE_TRACKING_ALLOCATOR, false)

main :: proc() {
	// Set working dir to dir of executable so relative asset paths resolve
	// regardless of where the app is launched from.
	rl.ChangeDirectory(rl.GetApplicationDirectory())

	mode := os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}
	logh, logh_err := os.open("log.txt", {.Create, .Trunc, .Read, .Write}, mode)

	if logh_err == os.ERROR_NONE {
		os.stdout = logh
		os.stderr = logh
	}

	log_level := log.Level.Info
	default_allocator := context.allocator
	logger_alloc := default_allocator
	logger :=
		logh_err == os.ERROR_NONE ? log.create_file_logger(logh, log_level, allocator = logger_alloc) : log.create_console_logger(log_level, allocator = logger_alloc)
	context.logger = logger

	when USE_TRACKING_ALLOCATOR {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, default_allocator)
		context.allocator = mem.tracking_allocator(&tracking_allocator)
	}
	game_memory_backing := context.allocator

	game_memory_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&game_memory_arena,
		block_allocator = game_memory_backing,
		array_allocator = game_memory_backing,
	)
	game_memory_arena_mutex: mem.Mutex_Allocator
	mem.mutex_allocator_init(
		&game_memory_arena_mutex,
		mem.dynamic_arena_allocator(&game_memory_arena),
	)
	context.allocator = mem.mutex_allocator(&game_memory_arena_mutex)

	game.game_init_window()
	game.game_init()

	for game.game_should_run() {
		game.game_update()
	}

	free_all(context.temp_allocator)
	game.game_shutdown()
	game.game_shutdown_window()
	context.allocator = game_memory_backing
	mem.dynamic_arena_destroy(&game_memory_arena)

	when USE_TRACKING_ALLOCATOR {
		for _, value in tracking_allocator.allocation_map {
			log.errorf("%v: Leaked %v bytes\n", value.location, value.size)
		}

		context.allocator = default_allocator
		mem.tracking_allocator_destroy(&tracking_allocator)
	}
	context.allocator = default_allocator

	if logh_err == os.ERROR_NONE {
		log.destroy_file_logger(logger, logger_alloc)
	}
}

// make game use good GPU on laptops etc

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
