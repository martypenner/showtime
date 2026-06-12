package sound

import "core:strings"
import rl "vendor:raylib"

MAX_FADE_IN_TIME :: 10
MAX_FADE_OUT_TIME :: 10
MAX_STOP_FADE_TIME :: 10
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -24
MAX_TARGET_LOUDNESS :: -6

DefaultSettings := Settings {
	volume           = 0.1,
	fade_in_time     = 2.0,
	fade_out_time    = 2.0,
	stop_fade_time   = 2.0,
	start_next_time  = 4.0,
	shuffle          = true,
	loop             = true,
	normalize_volume = true,
	target_loudness  = -12,
}

Settings :: struct {
	volume:                   f16,
	fade_in_time:             f16,
	fade_out_time:            f16,
	stop_fade_time:           f16,
	start_next_time:          f16,
	shuffle:                  bool,
	loop:                     bool,
	normalize_volume:         bool,
	target_loudness:          f16,
	playlists:                [dynamic]Playlist,
	current_playing_playlist: ^Playlist,
}

Playlist :: struct {
	name:                  string,
	tracks:                [dynamic]Track,
	played_tracks:         [dynamic]u8, // TODO: this probably needs to be a handle map or something. need it to be cheap
	current_playing_track: ^Track,
}

Track :: struct {
	title:         string,
	duration:      int, // TODO: not sure if we need this. can maybe read it dynamically
	filepath:      string,

	// The actual portion of the track to play. If it's been edited, this will be
	// the "slice" to play. If not, this is the full track length.
	slice_to_play: struct {
		start_time: f16,
		end_time:   f16,
	},
}

play_sound :: proc(filepath: string) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
	return sound
}
stop_sound :: proc(sound: rl.Sound) {
	rl.StopSound(sound)
}

play_music :: proc() {}
pause_music :: proc() {}
stop_music :: proc() {}

play_playlist :: proc() {}
pause_playlist :: proc() {}
stop_playlist :: proc() {}

clamp_fade_in_time :: proc() {}
clamp_fade_out_time :: proc() {}
clamp_stop_fade_time :: proc() {}
clamp_start_next_time :: proc() {}
clamp_min_target_loudness :: proc() {}
clamp_max_target_loudness :: proc() {}
clamp_track_start_time :: proc() {}
clamp_track_end_time :: proc() {}
