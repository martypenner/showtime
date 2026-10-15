#+feature dynamic-literals

package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

video_expect_near :: proc(t: ^testing.T, got, expected, epsilon: f64) {
	testing.expectf(
		t,
		math.abs(got - expected) < epsilon,
		"expected %f +/- %f, got %f",
		expected,
		epsilon,
		got,
	)
}

@(test)
video_frame_rate_parse_handles_fractions :: proc(t: ^testing.T) {
	testing.expect_value(t, video_frame_rate_parse("30/1"), f32(30))
	video_expect_near(t, f64(video_frame_rate_parse("30000/1001")), 29.97003, 0.00001)
	testing.expect_value(t, video_frame_rate_parse("garbage"), f32(0))
	testing.expect_value(t, video_frame_rate_parse("30/0"), f32(0))
	testing.expect_value(t, video_frame_rate_parse("30/zero"), f32(0))
}

@(test)
video_fit_rect_letterboxes :: proc(t: ^testing.T) {
	fit := video_fit_rect(1920, 1080, 1280, 720)
	testing.expect_value(t, fit.x, f32(0))
	testing.expect_value(t, fit.y, f32(0))
	video_expect_near(t, f64(fit.w), 1280, 0.01)
	video_expect_near(t, f64(fit.h), 720, 0.01)

	// Portrait video in a landscape output pillarboxes.
	portrait := video_fit_rect(1080, 1920, 1920, 1080)
	video_expect_near(t, f64(portrait.h), 1080, 0.01)
	video_expect_near(t, f64(portrait.w), 607.5, 0.01)
	video_expect_near(t, f64(portrait.x), (1920 - 607.5) / 2, 0.01)

	testing.expect_value(t, video_fit_rect(0, 1080, 1280, 720), sdl.FRect{0, 0, 0, 0})
}

@(test)
settings_roundtrip_preserves_sound_and_video :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	dir, dir_err := os.make_directory_temp("", "showtime-settings-*", context.temp_allocator)
	ensure(dir_err == nil)
	previous_dir, cwd_err := os.get_working_directory(context.temp_allocator)
	ensure(cwd_err == nil)
	ensure(os.set_working_directory(dir) == nil)
	defer {
		os.remove(SETTINGS_FILENAME)
		os.set_working_directory(previous_dir)
		os.remove(dir)
	}
	sound := sound_settings_load_from_disk()
	testing.expect_value(t, sound.fade_in_time, DefaultSoundSettings.fade_in_time)
	testing.expect_value(t, sound.duck_gain, f32(1))
	sound.use_house_music = true
	sound.fade_in_time = 3.5
	sound.music_track_bounds["music.mp3"] = {
		file_hash  = "hash",
		start_time = 2,
		end_time   = 10,
	}
	append(
		&sound.playlists,
		Playlist{tracks = [dynamic]Track{{path = "music.mp3", played = true}}},
	)
	gm.sound_settings = &sound
	video := entity_must_get(video_entity_ensure())
	video.video.settings.pages = map[string]VideoPlaybackMode {
		"opener"   = .Loop,
		"halftime" = .Once,
		"outro"    = .Still,
	}
	settings_save()

	loaded_sound := sound_settings_load_from_disk()
	loaded_video: VideoSettings
	settings_load(&loaded_video)
	testing.expect_value(t, loaded_sound.use_house_music, true)
	testing.expect_value(t, loaded_sound.fade_in_time, f32(3.5))
	testing.expect_value(t, loaded_sound.music_track_bounds["music.mp3"].file_hash, "hash")
	testing.expect_value(t, loaded_sound.music_track_bounds["music.mp3"].start_time, f32(2))
	testing.expect_value(t, loaded_sound.music_track_bounds["music.mp3"].end_time, f32(10))
	testing.expect_value(t, loaded_sound.played_track_paths["music.mp3"], true)
	testing.expect_value(t, loaded_video.pages["opener"], VideoPlaybackMode.Loop)
	testing.expect_value(t, loaded_video.pages["halftime"], VideoPlaybackMode.Once)
	testing.expect_value(t, loaded_video.pages["outro"], VideoPlaybackMode.Still)

	sound.fade_in_time = 6
	sound.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	video.video.settings.pages["opener"] = .Still
	settings_save()
	loaded_sound = sound_settings_load_from_disk()
	loaded_video = {}
	settings_load(&loaded_video)
	testing.expect_value(t, loaded_sound.fade_in_time, f32(6))
	testing.expect_value(t, loaded_sound.played_track_paths["music.mp3"], true)
	testing.expect_value(t, loaded_video.pages["opener"], VideoPlaybackMode.Still)
	testing.expect_value(t, loaded_video.pages["halftime"], VideoPlaybackMode.Once)
	testing.expect_value(t, loaded_video.pages["outro"], VideoPlaybackMode.Still)
	testing.expect_value(t, sound.settings_save_time_left, f32(0))
}

@(test)
video_page_mode_owns_filename_and_updates_playback :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "showtime-video-settings-*", context.temp_allocator)
	testing.expect_value(t, dir_err, nil)
	ensure(dir_err == nil)
	previous_dir, cwd_err := os.get_working_directory(context.temp_allocator)
	ensure(cwd_err == nil)
	ensure(os.set_working_directory(dir) == nil)
	defer {
		os.remove(SETTINGS_FILENAME)
		os.set_working_directory(previous_dir)
		os.remove(dir)
	}

	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	gm_previous := gm
	gm = game_memory_make()
	defer {
		gm = gm_previous
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	sound := DefaultSoundSettings
	sound.target_loudness = -10
	gm.sound_settings = &sound
	borrowed := []u8{'o', 'p', 'e', 'n', 'e', 'r'}
	playback := VideoPlayback {
		page_id = string(borrowed),
		mode    = .Loop,
		state   = .Holding,
	}
	entity := entity_must_get(video_entity_ensure())
	entity.video.settings.pages = make(map[string]VideoPlaybackMode)
	entity.video.pages = [dynamic]VideoPage{{page_id = "opener", mode = .Loop}}
	entity.video.active = &playback
	video_page_mode_set(playback.page_id, .Once)
	for &byte in borrowed do byte = '#'
	testing.expect_value(t, entity.video.settings.pages["opener"], VideoPlaybackMode.Once)
	testing.expect_value(t, playback.mode, VideoPlaybackMode.Once)
	loaded: VideoSettings
	settings_load(&loaded)
	testing.expect_value(t, loaded.pages["opener"], VideoPlaybackMode.Once)
	loaded_sound := sound_settings_load_from_disk()
	testing.expect_value(t, loaded_sound.target_loudness, f32(-10))
}

@(test)
video_playing_timer_owns_projection :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	video_init()

	// Nothing selected yet: the projection is blank.
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Blank)

	video_entity_get().video.selected = "opener"
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)

	testing.expect(t, timers_add("test", 30) != ENTITY_HANDLE_NIL, "timer add should succeed")
	timers_start(0)
	testing.expect(t, !video_projection_shown(), "a playing timer should own the projection")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)

	timers_stop_all()
	testing.expect(t, video_projection_shown(), "stopping the timer gives the projection back")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)
}

@(test)
video_show_selects_and_replaces_active :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()

	// Showing a page selects it and takes the single active slot.
	ensure(video_page_show("next"))
	testing.expect_value(t, entity.video.selected, "next")
	testing.expect_value(t, entity.video.active.page_id, "next")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)

	// Showing another page replaces the active slot.
	ensure(video_page_show("missing"))
	testing.expect_value(t, entity.video.selected, "missing")
	testing.expect_value(t, entity.video.active.page_id, "missing")

	// A timer overrides without stopping the playback or moving the selection.
	testing.expect(t, timers_add("test", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)
	testing.expect_value(t, video_entity_get().video.active.page_id, "missing")
	timers_stop_all()
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)
}

@(test)
video_playing_survives_score_show_hide :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()

	// A looping page is playing when a score is shown on top of it.
	entity.video.pages[0].mode = .Loop
	ensure(video_page_show("next"))
	deadline := time.time_add(time.now(), time.Second * 3)
	for entity.video.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	ensure(entity.video.active.frames > 0)

	gm.scores = score_init()
	defer score_shutdown()
	score_projection_show()
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Score)
	testing.expect(t, entity.video.active != nil, "showing a score should not stop the video")
	frames := entity.video.active.frames
	deadline = time.time_add(time.now(), time.Second * 3)
	for entity.video.active.frames == frames && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(t, entity.video.active.frames > frames, "the video should keep playing under the score")

	// Hiding the score hands the projection back to the playing video.
	score_projection_hide()
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)
	testing.expect(t, entity.video.active != nil, "hiding a score should keep the video playing")
}

@(test)
video_recheck_never_renders_stale_slide :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()
	entity.video.selected = ""

	// Show slide A and wait for a real frame.
	ensure(video_page_show("next"))
	deadline := time.time_add(time.now(), time.Second * 3)
	for entity.video.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	ensure(entity.video.active.frames > 0)
	frame_a := video_test_projection_pixel(projection)
	testing.expect(t, frame_a != [3]u8{}, "premise: slide A must render")

	// Releasing the deck stops the playback and drops the retained frame.
	video_page_clear()
	testing.expect(t, entity.video.active == nil, "clearing should stop slide A")
	testing.expect(t, entity.video.previous.texture == nil, "clearing should drop slide A")

	// Showing a page with no file never produces a frame, so every sample
	// must stay blank and A must never reappear.
	ensure(video_page_show("missing"))
	testing.expect_value(t, entity.video.selected, "missing")
	{
		// The missing-file error is expected here.
		logger_previous := context.logger
		context.logger = log.nil_logger()
		defer context.logger = logger_previous
		deadline = time.time_add(time.now(), time.Second * 3)
		for entity.video.active.state != .Failed && time.diff(time.now(), deadline) > 0 {
			video_update()
			pixel := video_test_projection_pixel(projection)
			testing.expect_value(t, pixel, [3]u8{})
			testing.expect(t, pixel != frame_a, "stale slide A must never reappear")
			time.sleep(time.Millisecond * 5)
		}
	}
	testing.expect_value(t, entity.video.active.state, VideoPlaybackState.Failed)
	testing.expect_value(t, entity.video.selected, "missing")
	testing.expect_value(t, video_test_projection_pixel(projection), [3]u8{})
}

@(test)
video_switch_keeps_previous_frame_until_upload :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()
	red := [3]u8{255, 0, 0}
	black := [3]u8{}
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	testing.expect_value(t, video_test_projection_pixel(projection, 8), black)

	ensure(video_page_show("missing"))
	pixel := video_test_projection_pixel(projection)
	testing.expect_value(t, pixel, red)
	if pixel != red do return
	deadline := time.time_add(time.now(), time.Second * 3)
	{
		// The missing-file error is expected here.
		logger_previous := context.logger
		context.logger = log.nil_logger()
		defer context.logger = logger_previous
		for entity.video.active.state != .Failed && time.diff(time.now(), deadline) > 0 {
			video_update()
			time.sleep(time.Millisecond * 5)
		}
	}
	testing.expect_value(t, entity.video.active.state, VideoPlaybackState.Failed)
	testing.expect_value(t, video_test_projection_pixel(projection), red)

	ensure(video_page_show("next"))
	deadline = time.time_add(time.now(), time.Second * 3)
	for entity.video.active.texture == nil && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(t, entity.video.active.texture != nil)
	testing.expect_value(t, entity.video.active.frames, u64(0))
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	testing.expect_value(t, video_test_projection_pixel(projection, 8), black)

	// Replace a loading slide before its first frame arrives.
	ensure(video_page_show("next"))
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	deadline = time.time_add(time.now(), time.Second * 3)
	for entity.video.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		if entity.video.active.frames == 0 {
			testing.expect_value(t, video_test_projection_pixel(projection), red)
		}
		time.sleep(time.Millisecond * 5)
	}
	testing.expect_value(t, entity.video.active.frames, u64(1))
	ensure(entity.video.active.frames > 0)
	for y in ([2]i32{8, 32}) {
		offset := (int(y) * 64 + 32) * 4
		frame := entity.video.active.frame
		testing.expect_value(
			t,
			video_test_projection_pixel(projection, y),
			[3]u8{frame[offset + 2], frame[offset + 1], frame[offset]},
		)
	}
	video_page_clear()
	testing.expect_value(t, video_test_projection_pixel(projection), black)

	// Clear during loading also releases the retained image immediately.
	ensure(video_page_show("next"))
	deadline = time.time_add(time.now(), time.Second * 3)
	for entity.video.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	ensure(entity.video.active.frames > 0)
	ensure(video_page_show("next"))
	video_page_clear()
	testing.expect_value(t, video_test_projection_pixel(projection), black)
}

@(test)
video_fade_completes_and_clears_deck :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()

	video_fade_start(0.4)
	testing.expect_value(t, entity.fade.remaining_s, f32(0.4))
	testing.expect_value(t, video_fade_opacity(), f32(1))

	gm.frame.dt = 0.1
	video_update()
	testing.expect_value(t, entity.fade.remaining_s, f32(0.3))
	testing.expect_value(t, video_fade_opacity(), f32(0.75))
	mid := video_test_projection_pixel(projection)
	testing.expect(t, mid[0] > 0 && mid[0] < 255, "a fading slide should dim, not pop")
	testing.expect_value(t, mid[1], u8(0))
	testing.expect_value(t, mid[2], u8(0))

	for _ in 0 ..< 10 {
		if entity.fade.remaining_s <= 0 do break
		video_update()
	}
	testing.expect(t, entity.video.active == nil, "completion should stop the playback")
	testing.expect(
		t,
		entity.video.previous.texture == nil,
		"completion should drop the last frame",
	)
	testing.expect_value(t, entity.fade.remaining_s, f32(0))
	testing.expect_value(t, entity.fade.duration_s, f32(0))
	testing.expect_value(t, video_fade_opacity(), f32(1))
	testing.expect_value(t, video_test_projection_pixel(projection), [3]u8{})
}

@(test)
video_clear_during_fade_stays_blank :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	entity := video_entity_get()

	video_fade_start(2)
	gm.frame.dt = 0.1
	video_update()
	testing.expect(t, video_fade_opacity() < 1, "premise: the fade should be underway")

	// Cutting the deck mid fade stops the playback, drops the last frame,
	// and disarms the fade.
	video_page_clear()
	testing.expect(t, entity.video.active == nil, "clear should stop the playback mid fade")
	testing.expect(
		t,
		entity.video.previous.texture == nil,
		"clear should drop the last frame mid fade",
	)
	testing.expect_value(t, entity.fade.remaining_s, f32(0))
	testing.expect_value(t, video_test_projection_pixel(projection), [3]u8{})

	// Ticking after a clear stays blank: nothing stale can reappear.
	video_update()
	testing.expect_value(t, video_test_projection_pixel(projection), [3]u8{})
}

@(test)
video_fade_keeps_timer_priority :: proc(t: ^testing.T) {
	allocator_previous := context.allocator
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	defer {
		context.allocator = allocator_previous
		mem.dynamic_arena_destroy(&arena)
	}
	projection := video_test_projection_make(t)
	defer video_test_projection_destroy(t, projection)
	video_entity_get().video.selected = "previous"

	testing.expect(t, timers_add("test", 30) != ENTITY_HANDLE_NIL)
	timers_start(0)
	video_fade_start(0.2)
	testing.expect(
		t,
		!video_projection_shown(),
		"a playing timer should own the projection mid fade",
	)
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)

	gm.frame.dt = 0.1
	video_update()
	video_update()
	testing.expect(
		t,
		video_entity_get().video.active == nil,
		"the fade should complete under the timer",
	)
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Timer)

	timers_stop_all()
	testing.expect(
		t,
		video_entity_get().video.selected != "",
		"the fade should not move the selection",
	)
	testing.expect(t, video_projection_shown(), "stopping the timer gives the deck back")
	testing.expect_value(t, projection_source_resolve(), ProjectionSource.Video)
	testing.expect_value(t, video_test_projection_pixel(projection), [3]u8{})
}

@(test)
cue_dispatch_fade_out_flags :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()
	video := entity_must_get(video_entity_ensure())
	video.video.active = new(VideoPlayback)
	sound := DefaultSoundSettings
	gm.sound_settings = &sound

	// Fade_Out with the Video cap fades over the shared fade_out_s.
	fade := Entity_Cue {
		caps       = {.Has_Video},
		triggers   = {.Fade_Out},
		fade_out_s = 0.5,
	}
	fired := cue_dispatch(&fade)
	testing.expect_value(t, fired, Cue_Triggers{.Fade_Out})
	testing.expect_value(t, video.fade.remaining_s, f32(0.5))
	testing.expect_value(t, video.fade.duration_s, f32(0.5))

	// Fade_Out with the Music cap records without touching video.
	video.video.active = nil
	video.fade = {}
	music_fade := Entity_Cue {
		caps       = {.Has_Music},
		triggers   = {.Fade_Out},
		fade_out_s = 0.5,
	}
	fired = cue_dispatch(&music_fade)
	testing.expect_value(t, fired, Cue_Triggers{.Fade_Out})
	testing.expect_value(t, video.fade.remaining_s, f32(0))

	// Fade_Out without a fadeable cap stays inert.
	bare := Entity_Cue {
		triggers   = {.Fade_Out},
		fade_out_s = 0.5,
	}
	fired = cue_dispatch(&bare)
	testing.expect_value(t, fired, Cue_Triggers{})
	testing.expect_value(t, video.fade.remaining_s, f32(0))

	// An unrelated cue leaves a fresh deck alone.
	gm.sound_settings = nil
	plain := Entity_Cue {
		caps     = {.Has_Music},
		triggers = {.Music},
	}
	fired = cue_dispatch(&plain)
	testing.expect_value(t, fired, Cue_Triggers{.Music})
	testing.expect_value(t, video.fade.remaining_s, f32(0))
}

VideoTestProjection :: struct {
	surface:            ^sdl.Surface,
	renderer_previous:  ^sdl.Renderer,
	gm_previous:        ^GameMemory,
	directory:          string,
	directory_previous: string,
}

@(private = "file")
video_test_projection_make :: proc(t: ^testing.T) -> VideoTestProjection {
	projection: VideoTestProjection
	projection.gm_previous = gm
	gm = game_memory_make()
	projection.renderer_previous = gm.displays[.Projection].renderer
	err: os.Error
	projection.directory_previous, err = os.get_working_directory(context.allocator)
	ensure(err == nil)
	projection.directory, err = os.make_directory_temp(
		"",
		"showtime-video-switch-*",
		context.allocator,
	)
	ensure(err == nil)
	ensure(os.set_working_directory(projection.directory) == nil)
	ensure(os.make_directory_all(VIDEO_DIR) == nil)
	path := video_test_video_make(t)
	ensure(os.rename(path, VIDEO_DIR + "/next.mp4") == nil)
	projection.surface = sdl.CreateSurface(64, 64, .RGBA32)
	ensure(projection.surface != nil)
	gm.displays[.Projection].renderer = sdl.CreateSoftwareRenderer(projection.surface)
	ensure(gm.displays[.Projection].renderer != nil)
	entity := entity_must_get(video_entity_ensure())
	entity.video.pages = [dynamic]VideoPage {
		{page_id = "next", mode = .Still},
		{page_id = "missing", mode = .Still},
	}
	entity.video.active = video_playback_make(
		{page_id = "previous", mode = .Still},
		"previous.mp4",
	)
	entity.video.active.state = .Holding
	entity.video.active.width = 64
	entity.video.active.height = 32
	entity.video.active.frames = 1
	entity.video.active.texture = sdl.CreateTexture(
		gm.displays[.Projection].renderer,
		.BGRA32,
		.STREAMING,
		64,
		32,
	)
	ensure(entity.video.active.texture != nil)
	pixels: [64 * 32 * 4]u8
	for offset := 0; offset < len(pixels); offset += 4 {
		pixels[offset + 2] = 255
		pixels[offset + 3] = 255
	}
	ensure(sdl.UpdateTexture(entity.video.active.texture, nil, &pixels[0], 64 * 4))
	return projection
}

@(private = "file")
video_test_projection_pixel :: proc(projection: VideoTestProjection, y: i32 = 32) -> [3]u8 {
	ensure(sdl.SetRenderDrawColor(gm.displays[.Projection].renderer, 0, 0, 0, 255))
	ensure(sdl.RenderClear(gm.displays[.Projection].renderer))
	video_projection_render(gm.displays[.Projection].renderer)
	ensure(sdl.RenderPresent(gm.displays[.Projection].renderer))
	color: [3]u8
	alpha: u8
	ensure(
		sdl.ReadSurfacePixel(projection.surface, 32, y, &color[0], &color[1], &color[2], &alpha),
	)
	return color
}

@(private = "file")
video_test_projection_destroy :: proc(t: ^testing.T, projection: VideoTestProjection) {
	video_page_clear()
	deadline := time.time_add(time.now(), time.Second * 5)
	for len(video_entity_get().video.retired) > 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect_value(t, len(video_entity_get().video.retired), 0)
	sdl.DestroyRenderer(gm.displays[.Projection].renderer)
	sdl.DestroySurface(projection.surface)
	gm.displays[.Projection].renderer = projection.renderer_previous
	gm = projection.gm_previous
	ensure(os.set_working_directory(projection.directory_previous) == nil)
	ensure(os.remove_all(projection.directory) == nil)
}

@(test)
video_decode_pipeline_1080p_keeps_real_time :: proc(t: ^testing.T) {
	path := video_test_video_make(t, "1920x1080", "2")
	playback := video_playback_make({page_id = "test", mode = .Once}, path)
	defer video_test_playback_stop(t, playback)
	ensure(video_ffprobe_spawn(playback))
	began := time.now()
	deadline := time.time_add(began, time.Second * 3)
	for playback.state != .Holding && time.diff(time.now(), deadline) > 0 {
		video_playback_update(playback)
		time.sleep(time.Second / 60)
	}
	testing.expect_value(t, playback.state, VideoPlaybackState.Holding)
	testing.expect_value(t, playback.frames, u64(60))
	testing.expect(
		t,
		time.diff(began, time.now()) >= time.Second * 19 / 10,
		"retain 30 fps pacing",
	)
}

// Runs the real ffmpeg against a generated clip, without SDL: the state
// machine and modes are exercised end to end.
@(test)
video_decode_pipeline_plays_once_and_holds :: proc(t: ^testing.T) {
	playback := video_test_playback_start(t, .Once)
	if playback == nil do return
	defer video_test_playback_stop(t, playback)

	state := video_test_run(playback, time.Second * 10, []VideoPlaybackState{.Holding})
	testing.expect_value(t, state, VideoPlaybackState.Holding)
	testing.expect_value(t, playback.frames, u64(30))
	testing.expect_value(t, playback.width, 64)
	testing.expect_value(t, playback.height, 64)
	video_expect_near(t, f64(playback.fps), 30, 0.01)

	// Holding is terminal: no more frames arrive.
	time.sleep(time.Millisecond * 100)
	final_frames := playback.frames
	video_test_pump(playback, 20)
	testing.expect_value(t, playback.frames, final_frames)
}

@(test)
video_decode_pipeline_loop_restarts :: proc(t: ^testing.T) {
	playback := video_test_playback_start(t, .Loop)
	if playback == nil do return
	defer video_test_playback_stop(t, playback)

	// One pass is ~1s of frames; a restart publishes past the first EOF.
	deadline := time.time_add(time.now(), time.Second * 10)
	for playback.frames < 40 && time.diff(time.now(), deadline) > 0 {
		video_playback_update(playback)
		time.sleep(time.Millisecond * 5)
	}
	testing.expectf(
		t,
		playback.frames >= 40,
		"expected the second pass to start, got %d",
		playback.frames,
	)
	testing.expect_value(t, playback.state, VideoPlaybackState.Playing)
}

@(test)
video_decode_pipeline_still_holds_first_frame :: proc(t: ^testing.T) {
	playback := video_test_playback_start(t, .Still)
	if playback == nil do return
	defer video_test_playback_stop(t, playback)

	state := video_test_run(playback, time.Second * 10, []VideoPlaybackState{.Holding})
	testing.expect_value(t, state, VideoPlaybackState.Holding)
	testing.expect_value(t, playback.frames, u64(1))
}

@(test)
video_decode_pipeline_stops_with_full_buffer :: proc(t: ^testing.T) {
	playback := video_test_playback_start(t, .Loop)
	ensure(playback != nil)
	deadline := time.time_add(time.now(), time.Second * 3)
	for playback.state == .Probing && time.diff(time.now(), deadline) > 0 {
		video_playback_update(playback)
		time.sleep(time.Millisecond * 5)
	}
	ensure(playback.decoder != nil)
	frame_state := VideoFrameState.Empty
	for frame_state == .Empty && time.diff(time.now(), deadline) > 0 {
		sync.lock(&playback.decoder.mutex)
		frame_state = playback.decoder.frame_state
		sync.unlock(&playback.decoder.mutex)
		time.sleep(time.Millisecond * 5)
	}
	testing.expect_value(t, frame_state, VideoFrameState.Ready)
	time.sleep(time.Millisecond * 150)
	video_test_playback_stop(t, playback)
}

@(private = "file")
video_test_video_make :: proc(t: ^testing.T, size := "64x64", duration := "1") -> string {
	dir := "build/test-video"
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/test.mp4", dir)

	args := [dynamic]string {
		"ffmpeg",
		"-v",
		"error",
		"-y",
		"-f",
		"lavfi",
		"-i",
		fmt.tprintf("testsrc=size=%s:rate=30:duration=%s", size, duration),
		"-pix_fmt",
		"yuv420p",
		path,
	}
	defer delete(args)

	desc := os.Process_Desc {
		command = args[:],
	}
	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)
	testing.expectf(
		t,
		err == nil && state.exit_code == 0,
		"ffmpeg test clip generation failed: %v %s %s",
		err,
		stdout,
		stderr,
	)
	return path
}

@(private = "file")
video_test_playback_start :: proc(t: ^testing.T, mode: VideoPlaybackMode) -> ^VideoPlayback {
	path := video_test_video_make(t)
	page := VideoPage {
		page_id = "test",
		mode    = mode,
	}
	playback := video_playback_make(page, path)
	testing.expect(t, playback != nil, "playback should allocate")
	if !video_ffprobe_spawn(playback) {
		testing.expect(t, false, "ffprobe should spawn")
	}
	return playback
}

// Tear down through the public path, the way game_shutdown does: retire the
// playback, reap its child, then free it.
@(private = "file")
video_test_playback_stop :: proc(t: ^testing.T, playback: ^VideoPlayback) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()
	entity_must_get(video_entity_ensure()).video.active = playback
	video_page_clear()

	deadline := time.time_add(time.now(), time.Second * 5)
	for len(video_entity_get().video.retired) > 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(
		t,
		len(video_entity_get().video.retired) == 0,
		"retired playback should be reaped and freed",
	)
}

// Pump the state machine until one of the wanted states is reached or the
// timeout expires.
@(private = "file")
video_test_run :: proc(
	playback: ^VideoPlayback,
	timeout: time.Duration,
	want: []VideoPlaybackState,
) -> VideoPlaybackState {
	deadline := time.time_add(time.now(), timeout)
	for {
		video_playback_update(playback)
		for want_state in want {
			if playback.state == want_state do return playback.state
		}
		if time.diff(time.now(), deadline) <= 0 do return playback.state
		time.sleep(time.Millisecond * 5)
	}
}

@(private = "file")
video_test_pump :: proc(playback: ^VideoPlayback, times: int) {
	for _ in 0 ..< times {
		video_playback_update(playback)
		time.sleep(time.Millisecond * 5)
	}
}
