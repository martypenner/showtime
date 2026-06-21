package game

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
		music_volume = 0.5,
	}
	sound_hot_reloaded(&settings)

	testing.expect(t, sound_settings != nil, "sound state left nil after hot reload")
	testing.expect(t, sound_settings == &settings, "settings pointer not restored")
	testing.expect_value(t, sound_settings.music_volume, f32(0.5))
}

@(test)
music_current_volume_reports_audible_voice_volume :: proc(t: ^testing.T) {
	settings := SoundSettings{}
	sound_settings = &settings

	settings.music_voices[0] = MusicVoice {
		active       = true,
		volume       = 0.8,
		current_fade = 0.5,
		fade_target  = 1,
	}
	settings.music_voices[1] = MusicVoice {
		active       = true,
		volume       = 0.3,
		current_fade = 1,
		fade_target  = 0,
	}

	// Fading in uses the squared fade curve, so 0.8 * 0.5^2 = 0.2. The UI
	// should reflect the loudest currently audible track, not the target 0.8.
	testing.expect_value(t, sound_music_current_volume(), f32(0.3))
}
