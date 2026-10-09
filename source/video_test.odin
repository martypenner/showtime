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
	video := VideoState {
		settings = {
			pages = map[string]VideoPlaybackMode {
				"opener" = .Loop,
				"halftime" = .Once,
				"outro" = .Still,
			},
		},
	}
	gm.video = &video
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
	video.settings.pages["opener"] = .Still
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
	state := VideoState {
		settings = {pages = make(map[string]VideoPlaybackMode)},
		pages = [dynamic]VideoPage{{page_id = "opener", mode = .Loop}},
		active = &playback,
	}
	gm.video = &state
	video_page_mode_set(playback.page_id, .Once)
	for &byte in borrowed do byte = '#'
	testing.expect_value(t, state.settings.pages["opener"], VideoPlaybackMode.Once)
	testing.expect_value(t, playback.mode, VideoPlaybackMode.Once)
	loaded: VideoSettings
	settings_load(&loaded)
	testing.expect_value(t, loaded.pages["opener"], VideoPlaybackMode.Once)
	loaded_sound := sound_settings_load_from_disk()
	testing.expect_value(t, loaded_sound.target_loudness, f32(-10))
}

@(test)
video_playing_timer_hides_the_deck :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()

	state := video_init()
	gm.video = state

	testing.expect(t, state.shown, "the deck should start shown")

	testing.expect(t, timers_add("test", 30), "timer add should succeed")
	timers_start(0)
	testing.expect(t, !state.shown, "starting a timer should hide the deck")
	testing.expect(t, !video_projection_shown(), "a playing timer should own the projection")

	// The Show on projection checkbox overrides the running timer.
	state.shown = true
	testing.expect(t, video_projection_shown(), "the checkbox should override the timer")
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
	state := projection.state
	red := [3]u8{255, 0, 0}
	black := [3]u8{}
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	testing.expect_value(t, video_test_projection_pixel(projection, 8), black)

	ensure(video_page_show(state, "missing"))
	pixel := video_test_projection_pixel(projection)
	testing.expect_value(t, pixel, red)
	if pixel != red do return
	deadline := time.time_add(time.now(), time.Second * 3)
	{
		// The missing-file error is expected here.
		logger_previous := context.logger
		context.logger = log.nil_logger()
		defer context.logger = logger_previous
		for state.active.state != .Failed && time.diff(time.now(), deadline) > 0 {
			video_update()
			time.sleep(time.Millisecond * 5)
		}
	}
	testing.expect_value(t, state.active.state, VideoPlaybackState.Failed)
	testing.expect_value(t, video_test_projection_pixel(projection), red)

	ensure(video_page_show(state, "next"))
	deadline = time.time_add(time.now(), time.Second * 3)
	for state.active.texture == nil && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(t, state.active.texture != nil)
	testing.expect_value(t, state.active.frames, u64(0))
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	testing.expect_value(t, video_test_projection_pixel(projection, 8), black)

	// Replace a loading slide before its first frame arrives.
	ensure(video_page_show(state, "next"))
	testing.expect_value(t, video_test_projection_pixel(projection), red)
	deadline = time.time_add(time.now(), time.Second * 3)
	for state.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		if state.active.frames == 0 {
			testing.expect_value(t, video_test_projection_pixel(projection), red)
		}
		time.sleep(time.Millisecond * 5)
	}
	testing.expect_value(t, state.active.frames, u64(1))
	ensure(state.active.frames > 0)
	for y in ([2]i32{8, 32}) {
		offset := (int(y) * 64 + 32) * 4
		frame := state.active.frame
		testing.expect_value(
			t,
			video_test_projection_pixel(projection, y),
			[3]u8{frame[offset + 2], frame[offset + 1], frame[offset]},
		)
	}
	video_page_clear()
	testing.expect_value(t, video_test_projection_pixel(projection), black)

	// Clear during loading also releases the retained image immediately.
	ensure(video_page_show(state, "next"))
	deadline = time.time_add(time.now(), time.Second * 3)
	for state.active.frames == 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	ensure(state.active.frames > 0)
	ensure(video_page_show(state, "next"))
	video_page_clear()
	testing.expect_value(t, video_test_projection_pixel(projection), black)
}

VideoTestProjection :: struct {
	state:              ^VideoState,
	surface:            ^sdl.Surface,
	renderer_previous:  ^sdl.Renderer,
	state_previous:     ^VideoState,
	gm_previous:        ^GameMemory,
	directory:          string,
	directory_previous: string,
}

@(private = "file")
video_test_projection_make :: proc(t: ^testing.T) -> VideoTestProjection {
	projection: VideoTestProjection
	projection.gm_previous = gm
	gm = game_memory_make()
	projection.state_previous = gm.video
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
	state := new(VideoState)
	state.pages = [dynamic]VideoPage {
		{page_id = "next", mode = .Still},
		{page_id = "missing", mode = .Still},
	}
	state.active = video_playback_make({page_id = "previous", mode = .Still}, "previous.mp4")
	state.active.state = .Holding
	state.active.width = 64
	state.active.height = 32
	state.active.frames = 1
	state.active.texture = sdl.CreateTexture(
		gm.displays[.Projection].renderer,
		.BGRA32,
		.STREAMING,
		64,
		32,
	)
	ensure(state.active.texture != nil)
	pixels: [64 * 32 * 4]u8
	for offset := 0; offset < len(pixels); offset += 4 {
		pixels[offset + 2] = 255
		pixels[offset + 3] = 255
	}
	ensure(sdl.UpdateTexture(state.active.texture, nil, &pixels[0], 64 * 4))
	projection.state = state
	gm.video = state
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
	for len(projection.state.retired) > 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect_value(t, len(projection.state.retired), 0)
	sdl.DestroyRenderer(gm.displays[.Projection].renderer)
	sdl.DestroySurface(projection.surface)
	gm.displays[.Projection].renderer = projection.renderer_previous
	gm.video = projection.state_previous
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
	gm.video = new(VideoState)
	gm.video.active = playback
	video_page_clear()

	deadline := time.time_add(time.now(), time.Second * 5)
	for len(gm.video.retired) > 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond * 5)
	}
	testing.expect(t, len(gm.video.retired) == 0, "retired playback should be reaped and freed")
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
