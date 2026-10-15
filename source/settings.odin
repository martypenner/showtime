package game

import "core:encoding/json"
import "core:log"
import "core:os"
import norm "path_normalize"

SETTINGS_FILENAME :: "settings.sjson"

// Explicit persisted surface. Same keys as the previous inline mix of
// SoundSettings and video pages, so the current settings.sjson carries over
// with no migration step. Runtime state (browser indices, wave fractions,
// live handles, mixer objects, scores, timers, marks, lighting) stays out.
App_Settings :: struct {
	use_house_music:    bool,
	fade_in_time:       f32,
	fade_out_time:      f32,
	start_next_time:    f32,
	shuffle:            bool,
	loop:               bool,
	normalize_volume:   bool,
	target_loudness:    f32,
	music_track_bounds: map[string]MusicTrackBounds,
	played_track_paths: map[string]bool,
	video_pages:        map[string]VideoPlaybackMode,
}

settings_load :: proc(settings: ^$T) {
	if !os.exists(SETTINGS_FILENAME) do return
	data, read_err := os.read_entire_file(SETTINGS_FILENAME, context.temp_allocator)
	log.ensuref(read_err == nil, "Error reading settings file: %v", read_err)
	json_err := json.unmarshal(data, settings, .Bitsquid, context.allocator)
	log.ensuref(json_err == nil, "Error unmarshaling settings file: %v", json_err)
}

// Track bounds persist from the track entities. Paths without an entity
// (synthetic test fixtures) fall back to the runtime map so nothing drops.
// The map travels by pointer because element assignment through a bare map
// parameter is rejected.
entity_track_bounds_write :: proc(out: ^map[string]MusicTrackBounds) {
	ensure(gm != nil)
	for handle in gm.entities.track {
		entity, ok := entity_get(handle)
		ensure(ok)
		track := &entity.track
		if len(track.file_hash) == 0 || track.bounds_end_s <= track.bounds_start_s do continue
		// Full-range bounds are the default and never persist.
		if track.bounds_start_s <= 0 && track.bounds_end_s >= track.duration_s do continue
		out[norm.path_nfc(track.path)] = MusicTrackBounds {
			file_hash  = track.file_hash,
			start_time = track.bounds_start_s,
			end_time   = track.bounds_end_s,
		}
	}
	for path, bound in gm.sound_settings.music_track_bounds {
		if path not_in out do out[path] = bound
	}
}

settings_save :: proc() {
	ensure(gm.sound_settings != nil && video_entity_get() != nil)
	played := make(map[string]bool, context.temp_allocator)
	for &playlist in gm.sound_settings.playlists {
		for &track in playlist.tracks {
			if track.played do played[norm.path_nfc(track.path)] = true
		}
	}
	for handle in gm.entities.track {
		entity, ok := entity_get(handle)
		ensure(ok)
		if entity.track.played do played[norm.path_nfc(entity.track.path)] = true
	}
	bounds := make(map[string]MusicTrackBounds, context.temp_allocator)
	entity_track_bounds_write(&bounds)
	settings := App_Settings {
		use_house_music    = gm.sound_settings.use_house_music,
		fade_in_time       = gm.sound_settings.fade_in_time,
		fade_out_time      = gm.sound_settings.fade_out_time,
		start_next_time    = gm.sound_settings.start_next_time,
		shuffle            = gm.sound_settings.shuffle,
		loop               = gm.sound_settings.loop,
		normalize_volume   = gm.sound_settings.normalize_volume,
		target_loudness    = gm.sound_settings.target_loudness,
		music_track_bounds = bounds,
		played_track_paths = played,
		video_pages        = video_entity_get().video.settings.pages,
	}
	data, json_err := json.marshal(
		settings,
		json.Marshal_Options {
			spec = .Bitsquid,
			pretty = true,
			use_spaces = true,
			spaces = 2,
			mjson_keys_use_equal_sign = true,
			mjson_keys_use_quotes = true,
			sort_maps_by_key = true,
			use_enum_names = true,
		},
		context.temp_allocator,
	)
	log.ensuref(json_err == nil, "Error marshaling settings file: %v", json_err)
	write_err := os.write_entire_file(SETTINGS_FILENAME, data)
	log.ensuref(write_err == nil, "Error writing settings file: %v", write_err)
	gm.sound_settings.settings_save_time_left = 0
}
