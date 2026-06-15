package sound

import "core:encoding/json"
import "core:testing"

// After a hot reload the freshly-loaded DLL starts with a nil package global,
// so the sound Module must expose an explicit way to re-point itself at the
// persistent settings that live in GameMemory. This guards the hot-reload Seam
// without needing Raylib's audio device.
@(test)
hot_reloaded_restores_settings_pointer :: proc(t: ^testing.T) {
	// Simulate the new DLL: its copy of the package global is uninitialized.
	sound_settings = nil

	settings := SoundSettings {
		volume = 0.5,
	}
	hot_reloaded(&settings)

	testing.expect(t, sound_settings != nil, "sound state left nil after hot reload")
	testing.expect(t, sound_settings == &settings, "settings pointer not restored")
	testing.expect_value(t, sound_settings.volume, f32(0.5))
}

@(test)
partial_settings_keep_default_normalization :: proc(t: ^testing.T) {
	settings := DefaultSoundSettings
	settings_data := string("dummy = 1")
	err := json.unmarshal(transmute([]byte)settings_data, &settings, .Bitsquid, context.temp_allocator)

	testing.expect_value(t, err, nil)
	testing.expect_value(t, settings.normalize_volume, true)
	testing.expect_value(t, settings.target_loudness, f32(-8))
}

@(test)
sound_settings_round_trips_loudness_cache :: proc(t: ^testing.T) {
	settings := SoundSettings {
		volume           = 1,
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
	unmarshal_err := json.unmarshal(settings_json, &round_tripped, .Bitsquid, context.temp_allocator)
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
