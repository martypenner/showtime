package sound

import "../state"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

MAX_FADE_IN_TIME :: 10
MAX_FADE_OUT_TIME :: 10
MAX_STOP_FADE_TIME :: 10
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -24
MAX_TARGET_LOUDNESS :: -6


DefaultSoundSettings := state.SoundSettings {
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

init_settings :: proc(sound_settings: ^state.SoundSettings, arena: ^mem.Dynamic_Arena) {
	rl.InitAudioDevice()
	sound_settings^ = DefaultSoundSettings
	sound_settings.playlists = load_playlists(arena)
}

load_playlists :: proc(arena: ^mem.Dynamic_Arena) -> [dynamic]state.Playlist {
	potential_playlists, err := os.read_all_directory_by_path(
		"assets/sounds/music",
		context.temp_allocator,
	)
	log.ensuref(err == nil, "Error reading music dir: %s", err)

	alloc := mem.dynamic_arena_allocator(arena)
	playlists := make([dynamic]state.Playlist, alloc)

	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		playlist := state.Playlist{}
		playlist.name = strings.clone(playlist_dir.name, alloc)
		playlist.tracks = make([dynamic]state.Track, alloc)
		track_files, tracks_err := os.read_all_directory_by_path(
			playlist_dir.fullpath,
			context.temp_allocator,
		)
		log.ensuref(tracks_err == nil, "Error reading tracks in playlist dir: %s", err)

		for track_file in track_files {
			if track_file.type != .Regular do continue
			name := strings.clone_to_cstring(track_file.name, context.temp_allocator)
			if rl.IsFileExtension(name, ".wav;.mp3;.ogg;.flac") {
				track := state.Track {
					title = strings.clone(os.stem(track_file.name), alloc),
					path  = strings.clone(track_file.fullpath, alloc),
				}
				append(&playlist.tracks, track)
			}
		}

		append(&playlists, playlist)
	}

	return playlists
}

play_sound :: proc(filepath: string) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
	return sound
}
stop_sound :: proc(sound: rl.Sound) {
	rl.StopSound(sound)
}

play_playlist :: proc(playlist_name: string, sound_settings: ^state.SoundSettings) {
	found_playlist: ^state.Playlist
	for &playlist in sound_settings.playlists {
		if playlist.name == playlist_name {
			found_playlist = &playlist
			break
		}
	}
	if found_playlist == nil {
		log.warnf("Couldn't find playlist, skipping: %s", playlist_name)
		return
	}

	log.debugf("Playing playlist %s", playlist_name)
	sound_settings.current_playing_playlist = found_playlist
	music := rl.LoadMusicStream(
		strings.clone_to_cstring(found_playlist.tracks[0].path, context.temp_allocator),
	)
	volume := normalize_volume(music)
	rl.SetMusicVolume(music, volume)
	rl.PlayMusicStream(music)
	sound_settings.current_music = music
	sound_settings.is_music_playing = true
	// TODO: track when playlist + track are done and set current playlist + track back to nil
}

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

// TODO: implement
normalize_volume :: proc(music: rl.Music) -> f32 {
	return 1.0
}

// Must be called every frame. It keeps raylib's music stream buffers filled,
// but only actually refills at most every MUSIC_UPDATE_INTERVAL seconds. Without
// this, a Music stream produces no sound.
update :: proc(gm: ^state.GameMemory) {
	if !gm.sound_settings.is_music_playing do return
	rl.UpdateMusicStream(gm.sound_settings.current_music)
}

shutdown :: proc(sound_settings: ^state.SoundSettings) {
	rl.StopMusicStream(sound_settings.current_music)
	rl.UnloadMusicStream(sound_settings.current_music)
	rl.CloseAudioDevice()
}
