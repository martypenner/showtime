package sound

import "core:encoding/json"
import "core:testing"
import rl "vendor:raylib"

// After a hot reload the freshly-loaded DLL starts with a nil package global,
// so the sound Module must expose an explicit way to re-point itself at the
// persistent settings that live in GameMemory. This guards the hot-reload Seam
// without needing Raylib's audio device.
@(test)
hot_reloaded_restores_settings_pointer :: proc(t: ^testing.T) {
	// Simulate the new DLL: its copy of the package global is uninitialized.
	sound_settings = nil

	settings := SoundSettings {
		music_volume = 0.5,
	}
	hot_reloaded(&settings)

	testing.expect(t, sound_settings != nil, "sound state left nil after hot reload")
	testing.expect(t, sound_settings == &settings, "settings pointer not restored")
	testing.expect_value(t, sound_settings.music_volume, f32(0.5))
}

@(test)
partial_settings_keep_default_normalization :: proc(t: ^testing.T) {
	settings := DefaultSoundSettings
	settings_data := string("dummy = 1")
	err := json.unmarshal(
		transmute([]byte)settings_data,
		&settings,
		.Bitsquid,
		context.temp_allocator,
	)

	testing.expect_value(t, err, nil)
	testing.expect_value(t, settings.normalize_volume, true)
	testing.expect_value(t, settings.target_loudness, f32(-8))
}

@(test)
sound_settings_round_trips_loudness_cache :: proc(t: ^testing.T) {
	settings := SoundSettings {
		music_volume     = 1,
		normalize_volume = true,
		target_loudness  = -8,
		track_loudness   = make(map[PathName]TrackLoudness),
	}
	defer delete(settings.track_loudness)
	settings.track_loudness[PathName("song.mp3")] = TrackLoudness {
		file_hash         = "hash",
		active_rms        = 0.25,
		volume_multiplier = 0.5,
	}

	settings_json, marshal_err := json.marshal(
		settings,
		json.Marshal_Options {
			spec = .Bitsquid,
			mjson_keys_use_equal_sign = true,
			mjson_keys_use_quotes = true,
			sort_maps_by_key = true,
		},
	)
	defer delete(settings_json)
	testing.expect_value(t, marshal_err, nil)

	round_tripped: SoundSettings
	unmarshal_err := json.unmarshal(
		settings_json,
		&round_tripped,
		.Bitsquid,
		context.temp_allocator,
	)
	testing.expect_value(t, unmarshal_err, nil)
	loudness, ok := round_tripped.track_loudness[PathName("song.mp3")]
	testing.expect(t, ok, "loudness cache should round trip through settings")
	testing.expect_value(t, loudness.file_hash, "hash")
	testing.expect_value(t, loudness.active_rms, f32(0.25))
}

@(test)
playback_gain_attenuates_loud_tracks_to_target :: proc(t: ^testing.T) {
	gain := playback_gain_for_track(dbfs_to_linear(-6), dbfs_to_linear(-12))
	testing.expect(t, gain > 0.49 && gain < 0.51, "-6 dBFS music should get roughly -6 dB gain")
}

@(test)
playback_target_uses_quietest_track_when_target_would_boost :: proc(t: ^testing.T) {
	quietest_rms := dbfs_to_linear(-18)
	target_rms := playback_target_rms(-8, quietest_rms)
	testing.expect_value(t, target_rms, quietest_rms)
}

@(test)
playback_gain_brings_louder_tracks_down_to_quietest_track :: proc(t: ^testing.T) {
	target_rms := playback_target_rms(-8, dbfs_to_linear(-18))
	gain := playback_gain_for_track(dbfs_to_linear(-6), target_rms)
	testing.expect(
		t,
		gain > 0.25 && gain < 0.252,
		"-6 dBFS music should be attenuated to match -18 dBFS music",
	)
}

@(test)
playback_gain_does_not_exceed_raylib_volume_max :: proc(t: ^testing.T) {
	target_rms := playback_target_rms(-8, dbfs_to_linear(-18))
	gain := playback_gain_for_track(dbfs_to_linear(-18), target_rms)
	testing.expect_value(t, gain, MUSIC_MAX_NORMALIZED_GAIN)
}

@(test)
playback_gain_clamps_extreme_boosts :: proc(t: ^testing.T) {
	target_rms := playback_target_rms(-6, 0.0001)
	gain := playback_gain_for_track(0.0001, target_rms)
	testing.expect_value(t, gain, MUSIC_MAX_NORMALIZED_GAIN)
}

@(test)
playback_gain_clamps_target_loudness :: proc(t: ^testing.T) {
	target_rms := playback_target_rms(-100, dbfs_to_linear(-12))
	gain := playback_gain_for_track(dbfs_to_linear(-12), target_rms)
	testing.expect(
		t,
		gain > 0.99 && gain < 1.01,
		"target loudness should clamp to the configured minimum",
	)
}

@(test)
fade_amplitude_is_silent_at_zero_and_full_at_one :: proc(t: ^testing.T) {
	testing.expect_value(t, music_fade_amplitude(0), f32(0))
	testing.expect_value(t, music_fade_amplitude(1), f32(1))
}

@(test)
fade_amplitude_clamps_out_of_range_positions :: proc(t: ^testing.T) {
	testing.expect_value(t, music_fade_amplitude(-0.5), f32(0))
	testing.expect_value(t, music_fade_amplitude(1.5), f32(1))
}

@(test)
fade_amplitude_eases_through_the_midpoint :: proc(t: ^testing.T) {
	// Smoothstep crosses 0.5 at its midpoint, unlike a linear ramp this only
	// matters in that both endpoints stay anchored while the slope eases.
	testing.expect_value(t, music_fade_amplitude(0.5), f32(0.5))
	testing.expect(
		t,
		music_fade_amplitude(0.25) < 0.25,
		"smoothstep should ramp slowly near the start of a fade",
	)
}

@(test)
fade_speed_is_reciprocal_of_duration :: proc(t: ^testing.T) {
	testing.expect_value(t, fade_speed_for(2), f32(0.5))
	testing.expect_value(t, fade_speed_for(4), f32(0.25))
}

@(test)
fade_speed_snaps_when_duration_is_non_positive :: proc(t: ^testing.T) {
	// A zero/negative fade time means "no fade"; the speed must be large enough
	// to reach the target on the next frame even at a tiny dt.
	testing.expect(t, fade_speed_for(0) * (1.0 / 60.0) >= 1, "zero fade time should snap in one frame")
	testing.expect(t, fade_speed_for(-1) > 0, "negative fade time should still snap forward")
}

@(test)
advance_fade_ramps_up_without_overshooting :: proc(t: ^testing.T) {
	voice := MusicVoice {
		fade        = 0,
		fade_target = 1,
	}
	advance_fade(&voice, fade_speed_for(2), 1)
	testing.expect_value(t, voice.fade, f32(0.5))
	// A second-and-a-half step would overshoot 1.0; it must clamp instead.
	advance_fade(&voice, fade_speed_for(2), 1.5)
	testing.expect_value(t, voice.fade, f32(1))
}

@(test)
advance_fade_ramps_down_without_undershooting :: proc(t: ^testing.T) {
	voice := MusicVoice {
		fade        = 1,
		fade_target = 0,
	}
	advance_fade(&voice, fade_speed_for(2), 1)
	testing.expect_value(t, voice.fade, f32(0.5))
	advance_fade(&voice, fade_speed_for(2), 5)
	testing.expect_value(t, voice.fade, f32(0))
}

@(test)
sample_from_wave_matches_raylib_8_bit_normalization :: proc(t: ^testing.T) {
	data := [?]u8{0, 128, 255}
	wave := rl.Wave {
		frameCount = 3,
		sampleSize = 8,
		channels   = 1,
		data       = rawptr(&data[0]),
	}

	low, low_ok := sample_from_wave(wave, 0)
	mid, mid_ok := sample_from_wave(wave, 1)
	high, high_ok := sample_from_wave(wave, 2)

	testing.expect(t, low_ok && mid_ok && high_ok, "8-bit wave samples should be readable")
	testing.expect_value(t, low, f32(-1))
	testing.expect_value(t, mid, f32(0))
	testing.expect_value(t, high, f32(127.0 / 128.0))
}

@(test)
sample_from_wave_matches_raylib_16_bit_normalization :: proc(t: ^testing.T) {
	data := [?]i16{-32768, 0, 32767}
	wave := rl.Wave {
		frameCount = 3,
		sampleSize = 16,
		channels   = 1,
		data       = rawptr(&data[0]),
	}

	low, low_ok := sample_from_wave(wave, 0)
	mid, mid_ok := sample_from_wave(wave, 1)
	high, high_ok := sample_from_wave(wave, 2)

	testing.expect(t, low_ok && mid_ok && high_ok, "16-bit wave samples should be readable")
	testing.expect_value(t, low, f32(-1))
	testing.expect_value(t, mid, f32(0))
	testing.expect_value(t, high, f32(32767.0 / 32768.0))
}

@(test)
sample_from_wave_reads_32_bit_float_samples_directly :: proc(t: ^testing.T) {
	data := [?]f32{-0.25, 0, 0.75}
	wave := rl.Wave {
		frameCount = 3,
		sampleSize = 32,
		channels   = 1,
		data       = rawptr(&data[0]),
	}

	low, low_ok := sample_from_wave(wave, 0)
	mid, mid_ok := sample_from_wave(wave, 1)
	high, high_ok := sample_from_wave(wave, 2)

	testing.expect(t, low_ok && mid_ok && high_ok, "32-bit wave samples should be readable")
	testing.expect_value(t, low, f32(-0.25))
	testing.expect_value(t, mid, f32(0))
	testing.expect_value(t, high, f32(0.75))
}
