package game

import "core:encoding/json"
import "core:log"
import "core:os"
import norm "path_normalize"

SETTINGS_FILENAME :: "settings.sjson"

SettingsFile :: struct {
	using _:     SoundSettings,
	video_pages: map[string]VideoPlaybackMode,
}

settings_load :: proc(settings: ^$T) {
	if !os.exists(SETTINGS_FILENAME) do return
	data, read_err := os.read_entire_file(SETTINGS_FILENAME, context.temp_allocator)
	log.ensuref(read_err == nil, "Error reading settings file: %v", read_err)
	json_err := json.unmarshal(data, settings, .Bitsquid, context.allocator)
	log.ensuref(json_err == nil, "Error unmarshaling settings file: %v", json_err)
}

settings_save :: proc() {
	ensure(gm.sound_settings != nil && gm.video != nil)
	sound := gm.sound_settings^
	sound.played_track_paths = make(map[string]bool, context.temp_allocator)
	for &playlist in sound.playlists {
		for &track in playlist.tracks {
			if track.played do sound.played_track_paths[norm.path_nfc(track.path)] = true
		}
	}
	settings := SettingsFile{sound, gm.video.settings.pages}
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
