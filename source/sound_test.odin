package game

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

@(test)
sound_hot_reload_restores_persistent_music_state :: proc(t: ^testing.T) {
	playback := MusicPlayback {
		stopping = true,
	}
	settings := SoundSettings {
		music_volume           = 0.5,
		music_playback_primary = &playback,
	}
	sound_settings = nil
	sound_hot_reloaded(&settings)
	testing.expect(t, sound_settings == &settings)
	testing.expect_value(t, sound_settings.music_volume, f32(0.5))
	testing.expect(t, sound_settings.music_playback_primary == &playback)
	testing.expect(t, sound_settings.music_playback_primary.stopping)
}

@(test)
sound_retrigger_fade_requires_same_playing_long_effect :: proc(t: ^testing.T) {
	testing.expect(t, sound_retrigger_fade_needed(.Cat_Meow, .Cat_Meow, true, 4.01))
	testing.expect(t, !sound_retrigger_fade_needed(.Cat_Meow, .Cat_Meow, true, 4))
	testing.expect(t, !sound_retrigger_fade_needed(.Cat_Meow, .Cat_Meow, false, 5))
	testing.expect(t, !sound_retrigger_fade_needed(.Cat_Meow, .Ding_126626, true, 5))
}

@(test)
music_normalization_is_attenuation_only :: proc(t: ^testing.T) {
	settings := SoundSettings {
		normalize_volume = true,
		target_loudness  = -12,
	}
	sound_settings = &settings
	testing.expect_value(t, track_volume_multiplier(0), f32(1))
	testing.expect_value(t, track_volume_multiplier(0.01), f32(1))
	testing.expect(t, track_volume_multiplier(1) >= MUSIC_MIN_NORMALIZED_GAIN)
	testing.expect(t, track_volume_multiplier(1) < 1)
}

@(test)
sound_music_current_volume_uses_maximum_live_volume :: proc(t: ^testing.T) {
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	playback, mixer_value := music_playback_test_make({{0, 0.4}})
	defer music_playback_test_destroy(&playback, mixer_value)
	path := "test-current-volume"
	path_incoming := "test-current-volume-incoming"
	TRACKS[path] = {}
	defer delete_key(&TRACKS, path)
	TRACKS[path_incoming] = {}
	defer delete_key(&TRACKS, path_incoming)
	playback.source_path = path
	incoming_audio := mixer.CreateSineWaveAudio(mixer_value, 440, 0.1, 30000)
	ensure(incoming_audio != nil)
	defer mixer.DestroyAudio(incoming_audio)
	incoming_track := mixer.CreateTrack(mixer_value)
	ensure(incoming_track != nil)
	defer mixer.DestroyTrack(incoming_track)
	incoming := MusicPlayback {
		mixer_audio        = incoming_audio,
		mixer_track        = incoming_track,
		source_path        = path_incoming,
		volume_point_count = 1,
	}
	incoming.volume_points[0] = {0, 0.2}
	settings := SoundSettings {
		music_volume     = 0.5,
		normalize_volume = false,
	}
	settings.music_playbacks[0] = playback
	settings.music_playbacks[1] = incoming
	settings.music_playback_primary = &settings.music_playbacks[0]
	sound_settings = &settings
	ensure(mixer.SetTrackAudio(playback.mixer_track, playback.mixer_audio))
	ensure(mixer.PlayTrack(playback.mixer_track, 0))
	ensure(mixer.SetTrackAudio(incoming_track, incoming_audio))
	ensure(mixer.PlayTrack(incoming_track, 0))
	testing.expect_value(t, sound_music_current_volume(), f32(0.4))
	settings.music_playbacks[1].volume_points[0].volume = 0.7
	testing.expect_value(t, sound_music_current_volume(), f32(0.7))
	ensure(mixer.StopTrack(incoming_track, 0))
	TRACKS[path] = {
		active_rms = 1,
	}
	settings.normalize_volume = true
	settings.target_loudness = -12
	testing.expect_value(t, sound_music_current_volume(), f32(0.4) * track_volume_multiplier(1))
	ensure(mixer.StopTrack(playback.mixer_track, 0))
	testing.expect_value(t, sound_music_current_volume(), f32(0))
}

@(test)
music_playback_explicit_endpoints_ignore_settings_volume :: proc(t: ^testing.T) {
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	playback, mixer_value := music_playback_test_make({{0, 0}})
	defer music_playback_test_destroy(&playback, mixer_value)
	path := "test-explicit-endpoints"
	TRACKS[path] = {}
	defer delete_key(&TRACKS, path)
	playback.source_path = path
	playback.bounds_end_seconds = 30
	settings := SoundSettings {
		music_volume = 0.9,
	}
	sound_settings = &settings
	ensure(mixer.SetTrackAudio(playback.mixer_track, playback.mixer_audio))
	ensure(mixer.PlayTrack(playback.mixer_track, 0))
	music_playback_volume_set(&playback, {{0, 0}, {2, 0.3}})
	testing.expect_value(t, music_playback_volume_endpoint(&playback), f32(0.3))
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 2)),
		f32(0.3),
	)
	music_playback_volume_set(&playback, {{0, 1}})
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, playback.volume_frame_start),
		f32(1),
	)
	testing.expect_value(t, mixer.GetTrackGain(playback.mixer_track), f32(1))
}

@(test)
music_playback_successor_endpoint_uses_final_nonzero_point :: proc(t: ^testing.T) {
	playback := MusicPlayback {
		volume_point_count = 3,
	}
	playback.volume_points[0] = {0, 0}
	playback.volume_points[1] = {2, 0.4}
	playback.volume_points[2] = {22, 0.6}
	testing.expect_value(t, music_playback_volume_endpoint(&playback), f32(0.6))
	playback.volume_points[0] = {0, 0.7}
	playback.volume_point_count = 1
	testing.expect_value(t, music_playback_volume_endpoint(&playback), f32(0.7))
	playback.volume_points[0] = {0, 0.7}
	playback.volume_points[1] = {2, 0}
	playback.volume_point_count = 2
	testing.expect_value(t, music_playback_volume_endpoint(&playback), f32(0.7))
}

@(test)
music_playback_stopping_gain_tracks_normalization :: proc(t: ^testing.T) {
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	playback, mixer_value := music_playback_test_make({{0, 0.4}, {10, 0}})
	defer music_playback_test_destroy(&playback, mixer_value)
	path := "test-stopping-gain"
	TRACKS[path] = {}
	defer delete_key(&TRACKS, path)
	playback.source_path = path
	playback.volume_point_next = 1
	playback.stopping = true
	ensure(mixer.SetTrackAudio(playback.mixer_track, playback.mixer_audio))
	ensure(mixer.SetTrackGain(playback.mixer_track, 0.4))
	ensure(mixer.PlayTrack(playback.mixer_track, 0))
	settings := SoundSettings {
		music_volume     = 0.5,
		normalize_volume = false,
	}
	sound_settings = &settings
	points := playback.volume_points
	TRACKS[path] = {
		active_rms = 1,
	}
	settings.normalize_volume = true
	settings.target_loudness = -12
	testing.expect(t, !music_playback_update(&playback))
	testing.expect_value(
		t,
		mixer.GetTrackGain(playback.mixer_track),
		f32(0.4) * track_volume_multiplier(1),
	)
	testing.expect(t, playback.stopping)
	testing.expect_value(t, playback.volume_points, points)
}

@(test)
music_bounds_restore_and_invalidate_by_hash :: proc(t: ^testing.T) {
	bounds_by_path := make(map[string]MusicTrackBounds)
	defer delete(bounds_by_path)
	bounds_by_path["track.mp3"] = {
		file_hash  = "hash",
		start_time = 12.5,
		end_time   = 45.25,
	}
	bounds, stale := music_track_bounds_resolve(bounds_by_path, "track.mp3", "hash", 120)
	testing.expect(t, !stale)
	testing.expect_value(t, bounds.start_time, f32(12.5))
	testing.expect_value(t, bounds.end_time, f32(45.25))
	bounds, stale = music_track_bounds_resolve(bounds_by_path, "track.mp3", "changed", 120)
	testing.expect(t, stale)
	testing.expect_value(t, bounds.start_time, f32(0))
	testing.expect_value(t, bounds.end_time, f32(120))
}

@(test)
music_time_uses_selected_bounds :: proc(t: ^testing.T) {
	played, length := music_track_time_relative(25, 10, 50)
	testing.expect_value(t, played, f32(25))
	testing.expect_value(t, length, f32(40))
	played, _ = music_track_time_relative(60, 10, 50)
	testing.expect_value(t, played, f32(40))
}

@(test)
music_playback_volume_interpolates_and_holds :: proc(t: ^testing.T) {
	playback, mixer_value := music_playback_test_make({{0, 0.25}, {2, 1}, {3, 1}})
	defer music_playback_test_destroy(&playback, mixer_value)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, -1)),
		f32(0.25),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 0)),
		f32(0.25),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 1)),
		f32(0.625),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 2)),
		f32(1),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 2.5)),
		f32(1),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 3)),
		f32(1),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 4)),
		f32(1),
	)
}

@(test)
music_playback_volume_scene_points :: proc(t: ^testing.T) {
	playback, mixer_value := music_playback_test_make({{0, 0.5}, {0.5, 1}, {3.5, 1}, {4.5, 0}})
	defer music_playback_test_destroy(&playback, mixer_value)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 0)),
		f32(0.5),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 0.25)),
		f32(0.75),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 0.5)),
		f32(1),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 3.5)),
		f32(1),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 4)),
		f32(0.5),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 4.5)),
		f32(0),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 6)),
		f32(0),
	)
}

@(test)
music_playback_volume_set_one_point_is_ongoing :: proc(t: ^testing.T) {
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	volumes := [?]f32{0.4, 0}
	for volume in volumes {
		playback, mixer_value := music_playback_test_make({{0, 0.2}, {10, 0}})
		path := volume == 0 ? "test-constant-zero" : "test-constant-nonzero"
		TRACKS[path] = {}
		playback.source_path = path
		playback.bounds_end_seconds = 30
		ensure(mixer.SetTrackAudio(playback.mixer_track, playback.mixer_audio))
		ensure(mixer.PlayTrack(playback.mixer_track, 0))
		settings := SoundSettings {
			music_volume     = 0.5,
			normalize_volume = false,
		}
		sound_settings = &settings
		music_playback_volume_set(&playback, {{0, volume}})
		testing.expect(t, mixer.TrackPlaying(playback.mixer_track))
		testing.expect(t, !playback.stopping)
		testing.expect_value(t, playback.volume_point_count, u8(1))
		testing.expect_value(t, mixer.GetTrackGain(playback.mixer_track), volume)
		delete_key(&TRACKS, path)
		music_playback_test_destroy(&playback, mixer_value)
	}
}

@(test)
music_playback_volume_oscar_points :: proc(t: ^testing.T) {
	fade := f32(2)
	playback, mixer_value := music_playback_test_make({{0, 0}, {fade, 0.4}, {fade + 20, 0.6}})
	defer music_playback_test_destroy(&playback, mixer_value)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, 0)),
		f32(0),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, fade)),
		f32(0.4),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, fade + 10)),
		f32(0.5),
	)
	testing.expect_value(
		t,
		music_playback_volume_at(&playback, music_playback_test_frame(&playback, fade + 20)),
		f32(0.6),
	)
}

@(test)
music_playback_zero_final_volume_suppresses_automatic_next :: proc(t: ^testing.T) {
	playback, mixer_value := music_playback_test_make({{0, 1}, {1, 0}})
	playlist := Playlist {
		name = "test",
	}
	playback.playlist = &playlist
	settings := SoundSettings {
		mixer                  = mixer_value,
		music_playback_primary = &playback,
	}
	settings.music_playbacks[0] = playback
	settings.music_playback_primary = &settings.music_playbacks[0]
	sound_settings = &settings
	sound_update()
	testing.expect(t, !settings.music_playbacks[0].playlist_successor_started)
	mixer.DestroyMixer(mixer_value)
	mixer.Quit()
}

@(test)
music_playback_one_point_zero_starts_silent_automatic_next :: proc(t: ^testing.T) {
	music_playback_test_tone_write()
	defer os.remove(MUSIC_PLAYBACK_TEST_TONE_PATH)
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	TRACKS[MUSIC_PLAYBACK_TEST_TONE_PATH] = {
		file_hash        = "test",
		duration_seconds = 30,
	}
	playback, mixer_value := music_playback_test_make({{0, 0}})
	playback.bounds_end_seconds = 30
	playlist := Playlist {
		name = "test",
	}
	defer delete(playlist.tracks)
	append(&playlist.tracks, Track{title = "successor", path = MUSIC_PLAYBACK_TEST_TONE_PATH})
	playback.playlist = &playlist
	settings := SoundSettings {
		mixer                  = mixer_value,
		music_playback_primary = &playback,
		shuffle                = false,
	}
	settings.music_playbacks[0] = playback
	settings.music_playback_primary = &settings.music_playbacks[0]
	sound_settings = &settings
	sound_update()
	successor := settings.music_playback_primary
	testing.expect(t, successor != &settings.music_playbacks[0])
	testing.expect_value(t, successor.volume_point_count, u8(1))
	testing.expect_value(t, music_playback_volume_endpoint(successor), f32(0))
	testing.expect_value(t, mixer.GetTrackGain(successor.mixer_track), f32(0))
	testing.expect(t, mixer.TrackPlaying(successor.mixer_track))
	music_playback_stop(successor)
	mixer.DestroyMixer(mixer_value)
	mixer.Quit()
}

@(test)
playlist_selection_preserves_order_and_avoids_last :: proc(t: ^testing.T) {
	settings := SoundSettings {
		shuffle = false,
	}
	sound_settings = &settings
	playlist := Playlist {
		name = "test",
	}
	defer delete(playlist.tracks)
	append(&playlist.tracks, Track{title = "first"}, Track{title = "second"})
	first := playlist_pick_track_unplayed(&playlist)
	testing.expect_value(t, first.title, "first")
	first.played = true
	playlist.last_played_track = first
	testing.expect_value(t, playlist_pick_track_unplayed(&playlist).title, "second")
}

@(test)
playlist_reset_avoids_just_started_track :: proc(t: ^testing.T) {
	music_playback_test_tone_write()
	defer os.remove(MUSIC_PLAYBACK_TEST_TONE_PATH)
	TRACKS = make(map[string]GeneratedTrack)
	defer delete(TRACKS)
	TRACKS[MUSIC_PLAYBACK_TEST_TONE_PATH] = {
		file_hash        = "test",
		duration_seconds = 0.5,
	}
	dummy, mixer_value := music_playback_test_make({{0, 0}})
	settings := SoundSettings {
		mixer   = mixer_value,
		shuffle = true,
		loop    = true,
	}
	sound_settings = &settings
	playlist := Playlist {
		name = "test",
	}
	defer delete(playlist.tracks)
	append(
		&playlist.tracks,
		Track{title = "first", path = MUSIC_PLAYBACK_TEST_TONE_PATH},
		Track{title = "second", path = MUSIC_PLAYBACK_TEST_TONE_PATH},
	)

	first := playlist_pick_random_track(&playlist)
	first_playback := music_playback_start_playlist_track(&playlist, first, 1, 0)
	testing.expect(t, playlist.last_played_track == first)

	second := playlist_pick_random_track(&playlist)
	testing.expect(t, second != first)
	second_playback := music_playback_start_playlist_track(&playlist, second, 1, 0)
	testing.expect(t, playlist.last_played_track == second)

	// Both tracks have played, so this pick clears the played flags: it has to
	// land on the other track instead of replaying the one that is playing.
	testing.expect(t, playlist_pick_random_track(&playlist) != second)

	music_playback_stop(second_playback)
	music_playback_stop(first_playback)
	music_playback_test_destroy(&dummy, mixer_value)
}

MUSIC_PLAYBACK_TEST_TONE_PATH :: "build/music_playback_test_tone.wav"

Wav_Header :: struct #packed {
	riff:            [4]byte,
	riff_size:       u32,
	wave:            [4]byte,
	fmt:             [4]byte,
	fmt_size:        u32,
	audio_format:    u16,
	channels:        u16,
	sample_rate:     u32,
	byte_rate:       u32,
	block_align:     u16,
	bits_per_sample: u16,
	data_marker:     [4]byte,
	data_size:       u32,
}

// Writes a half-second square wave WAV so music_playback_start has a real
// decodable file without depending on synced music assets.
music_playback_test_tone_write :: proc() {
	sample_rate := 48000
	channels := 2
	frame_count := 24000
	sample_count := frame_count * channels

	samples := make([]f32, sample_count)
	defer delete(samples)
	for frame in 0 ..< frame_count {
		sample := frame % 2 == 0 ? f32(0.1) : f32(-0.1)
		samples[frame * channels] = sample
		samples[frame * channels + 1] = sample
	}

	header := Wav_Header {
		riff            = "RIFF",
		riff_size       = u32(36 + sample_count * 4),
		wave            = "WAVE",
		fmt             = "fmt ",
		fmt_size        = 16,
		audio_format    = 3, // IEEE float
		channels        = u16(channels),
		sample_rate     = u32(sample_rate),
		byte_rate       = u32(sample_rate * channels * 4),
		block_align     = u16(channels * 4),
		bits_per_sample = 32,
		data_marker     = "data",
		data_size       = u32(sample_count * 4),
	}

	file_data := make([]byte, size_of(Wav_Header) + sample_count * 4)
	defer delete(file_data)
	header_bytes := transmute([size_of(Wav_Header)]byte)header
	copy(file_data, header_bytes[:])
	copy(file_data[size_of(Wav_Header):], transmute([]byte)samples)
	ensure(write_entire_file(MUSIC_PLAYBACK_TEST_TONE_PATH, file_data))
}

music_playback_test_make :: proc(points: []MusicVolumePoint) -> (MusicPlayback, ^mixer.Mixer) {
	ensure(mixer.Init())
	spec := sdl.AudioSpec {
		format   = .F32,
		channels = 2,
		freq     = 48000,
	}
	mixer_value := mixer.CreateMixer(&spec)
	ensure(mixer_value != nil)
	audio := mixer.CreateSineWaveAudio(mixer_value, 440, 0.1, 30000)
	ensure(audio != nil)
	track := mixer.CreateTrack(mixer_value)
	ensure(track != nil)
	playback := MusicPlayback {
		mixer_audio        = audio,
		mixer_track        = track,
		volume_point_count = u8(len(points)),
		volume_frame_start = 100,
	}
	copy(playback.volume_points[:], points)
	return playback, mixer_value
}

music_playback_test_destroy :: proc(playback: ^MusicPlayback, mixer_value: ^mixer.Mixer) {
	mixer.DestroyTrack(playback.mixer_track)
	mixer.DestroyAudio(playback.mixer_audio)
	mixer.DestroyMixer(mixer_value)
	mixer.Quit()
}

music_playback_test_frame :: proc(playback: ^MusicPlayback, seconds: f32) -> i64 {
	return(
		playback.volume_frame_start +
		mixer.AudioMSToFrames(playback.mixer_audio, i64(seconds * 1000)) \
	)
}
