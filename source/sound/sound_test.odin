package sound

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
normalized_music_gain_pushes_active_rms_to_target :: proc(t: ^testing.T) {
	gain := normalized_music_gain(dbfs_to_linear(-18), -8)
	testing.expect(t, gain > 3.15 && gain < 3.17, "-18 dBFS music should get roughly +10 dB gain")
}

@(test)
normalized_music_gain_clamps_extreme_boosts :: proc(t: ^testing.T) {
	gain := normalized_music_gain(0.0001, -6)
	testing.expect_value(t, gain, MUSIC_MAX_NORMALIZED_GAIN)
}

@(test)
normalized_music_gain_clamps_target_loudness :: proc(t: ^testing.T) {
	gain := normalized_music_gain(dbfs_to_linear(-12), -100)
	testing.expect(
		t,
		gain > 0.99 && gain < 1.01,
		"target loudness should clamp to the configured minimum",
	)
}
