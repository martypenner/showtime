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
