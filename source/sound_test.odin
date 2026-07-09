package game

import hm "core:container/handle_map"
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
sound_retrigger_fade_needed_only_for_same_playing_sound_longer_than_threshold :: proc(
	t: ^testing.T,
) {
	testing.expect_value(
		t,
		sound_retrigger_fade_needed(
			.Cat_Meow,
			.Cat_Meow,
			true,
			SOUND_REPLAY_FADE_THRESHOLD + 0.01,
		),
		true,
	)
	testing.expect_value(
		t,
		sound_retrigger_fade_needed(.Cat_Meow, .Cat_Meow, true, SOUND_REPLAY_FADE_THRESHOLD),
		false,
	)
	testing.expect_value(
		t,
		sound_retrigger_fade_needed(
			.Cat_Meow,
			.Cat_Meow,
			true,
			SOUND_REPLAY_FADE_THRESHOLD - 0.01,
		),
		false,
	)
	testing.expect_value(
		t,
		sound_retrigger_fade_needed(
			.Cat_Meow,
			.Cat_Meow,
			false,
			SOUND_REPLAY_FADE_THRESHOLD + 0.01,
		),
		false,
	)
	testing.expect_value(
		t,
		sound_retrigger_fade_needed(
			.Cat_Meow,
			.Ding_126626,
			true,
			SOUND_REPLAY_FADE_THRESHOLD + 0.01,
		),
		false,
	)
}

@(test)
music_current_volume_reports_audible_voice_volume :: proc(t: ^testing.T) {
	settings := SoundSettings{}
	sound_settings = &settings

	settings.music_voices[0] = MusicVoice {
		active            = true,
		volume            = 0.8,
		fade_phase        = .FadingIn,
		fade_in_duration  = 1,
		fade_in_time_left = 0.5,
	}
	settings.music_voices[1] = MusicVoice {
		active             = true,
		volume             = 0.3,
		fade_phase         = .FadingOut,
		fade_out_duration  = 1,
		fade_out_time_left = 1,
	}

	// Fading in uses the squared fade curve, so 0.8 * 0.5^2 = 0.2. The UI
	// should reflect the loudest currently audible track, not the target 0.8.
	testing.expect_value(t, sound_music_current_volume(), f32(0.3))
}

@(test)
music_volume_applies_track_gain_when_normalized :: proc(t: ^testing.T) {
	settings := SoundSettings {
		normalize_volume = true,
		target_loudness  = -12,
	}
	sound_settings = &settings

	track_path := "assets/sounds/music/Easy Listening/01 - Happy and Fun Pop Background Music For Videos.mp3"
	expected_gain := track_volume_multiplier(TRACKS[track_path].active_rms)

	voice := MusicVoice {
		active     = true,
		path       = track_path,
		volume     = 0.8,
		fade_phase = .Holding,
	}

	testing.expect_value(t, music_voice_volume_current(voice), f32(0.8) * expected_gain)
}

@(test)
music_volume_ignores_track_gain_when_normalization_off :: proc(t: ^testing.T) {
	settings := SoundSettings {
		normalize_volume = false,
	}
	sound_settings = &settings

	voice := MusicVoice {
		active     = true,
		path       = "missing.mp3",
		volume     = 0.8,
		fade_phase = .Holding,
	}

	testing.expect_value(t, music_voice_volume_current(voice), f32(0.8))
}

@(test)
music_amplitude_fade_eases_in_but_fades_out_linearly :: proc(t: ^testing.T) {
	testing.expect_value(t, music_amplitude_fade(0.5, true), f32(0.25))
	testing.expect_value(t, music_amplitude_fade(0.5, false), f32(0.5))
}

@(test)
music_voice_amplitude_comes_from_fade_time_left :: proc(t: ^testing.T) {
	in_voice := MusicVoice {
		fade_phase        = .FadingIn,
		fade_in_duration  = 2,
		fade_in_time_left = 1,
	}
	out_voice := MusicVoice {
		fade_phase         = .FadingOut,
		fade_out_duration  = 2,
		fade_out_time_left = 1,
	}
	holding_voice := MusicVoice {
		fade_phase = .Holding,
	}

	testing.expect_value(t, music_voice_amplitude_fraction(in_voice), f32(0.25))
	testing.expect_value(t, music_voice_amplitude_fraction(out_voice), f32(0.5))
	testing.expect_value(t, music_voice_amplitude_fraction(holding_voice), f32(1))
}

@(test)
music_voice_amplitude_quick_fade_out_uses_squared_fade :: proc(t: ^testing.T) {
	voice := MusicVoice {
		fade_phase         = .FadingOut,
		fade_out_duration  = 2,
		fade_out_time_left = 1,
		fade_out_quick     = true,
	}

	testing.expect_value(t, music_voice_amplitude_fraction(voice), f32(0.25))
}

@(test)
music_voice_holds_after_fade_in_then_targets_fade_out :: proc(t: ^testing.T) {
	voice := MusicVoice {
		active             = true,
		fade_phase         = .FadingIn,
		fade_in_duration   = 1,
		fade_in_time_left  = 1,
		fade_out_duration  = 1.5,
		fade_out_time_left = 1.5,
		hold_time_left     = 3,
	}

	music_voice_fade_update(&voice, 1)
	testing.expect_value(t, voice.fade_phase, MusicFadePhase.Holding)
	testing.expect_value(t, voice.fade_in_time_left, f32(0))

	music_voice_fade_update(&voice, 2)
	testing.expect_value(t, voice.hold_time_left, f32(1))
	testing.expect_value(t, voice.fade_phase, MusicFadePhase.Holding)

	music_voice_fade_update(&voice, 1)
	testing.expect_value(t, voice.hold_time_left, f32(0))
	testing.expect_value(t, voice.fade_phase, MusicFadePhase.FadingOut)

	music_voice_fade_update(&voice, 0.75)
	testing.expect_value(t, voice.fade_out_time_left, f32(0.75))
}

@(test)
track_pick_unplayed_returns_nil_when_exhausted_and_reset_makes_pickable :: proc(t: ^testing.T) {
	settings := SoundSettings {
		shuffle = false,
	}
	sound_settings = &settings

	playlist := Playlist {
		name = "test",
	}
	hm.dynamic_init(&playlist.tracks, context.allocator)
	defer hm.dynamic_destroy(&playlist.tracks)

	_, err := hm.add(&playlist.tracks, Track{title = "played", path = "played.mp3", played = true})
	testing.expect(t, err == nil)

	testing.expect(t, playlist_pick_track_unplayed(&playlist) == nil)
	track := track_pick_unplayed_after_reset_for_test(&playlist)
	testing.expect(t, track != nil, "reset should make exhausted tracks pickable")
}

@(test)
track_pick_unplayed_uses_insertion_order_when_shuffle_off :: proc(t: ^testing.T) {
	settings := SoundSettings {
		shuffle = false,
	}
	sound_settings = &settings

	playlist := sound_test_playlist_make({"first", "second", "third"})
	defer hm.dynamic_destroy(&playlist.tracks)

	track := playlist_pick_track_unplayed(&playlist)
	testing.expect(t, track != nil)
	testing.expect_value(t, track.title, "first")

	track.played = true
	playlist.last_played_track = track
	track = playlist_pick_track_unplayed(&playlist)
	testing.expect(t, track != nil)
	testing.expect_value(t, track.title, "second")
}

@(test)
track_pick_unplayed_avoids_last_track_when_shuffle_off_if_possible :: proc(t: ^testing.T) {
	settings := SoundSettings {
		shuffle = false,
	}
	sound_settings = &settings

	playlist := sound_test_playlist_make({"first", "second"})
	defer hm.dynamic_destroy(&playlist.tracks)

	first := playlist_pick_track_unplayed(&playlist)
	testing.expect(t, first != nil)
	playlist.last_played_track = first

	track := playlist_pick_track_unplayed(&playlist)
	testing.expect(t, track != nil)
	testing.expect_value(t, track.title, "second")
}

track_pick_unplayed_after_reset_for_test :: proc(playlist: ^Playlist) -> ^Track {
	it := hm.iterator_make(&playlist.tracks)
	for track, _ in hm.iterate(&it) {
		track.played = false
	}
	return playlist_pick_track_unplayed(playlist)
}

sound_test_playlist_make :: proc(titles: []string) -> Playlist {
	playlist := Playlist {
		name = "test",
	}
	hm.dynamic_init(&playlist.tracks, context.allocator)
	for title in titles {
		_, err := hm.add(&playlist.tracks, Track{title = title, path = title})
		if err != nil do return playlist
	}
	return playlist
}
