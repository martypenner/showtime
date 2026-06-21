package game

import hm "core:container/handle_map"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

// Sound-owned data lives here, next to the behavior that reads and mutates it.
// The shared GameMemory holds only a pointer to SoundSettings (the hot-reload
// persistence shell), so these definitions stay local to the sound Module.

SoundSettings :: struct {
	// The music master volume (0..1). Scales every music track on top of its
	// per-track normalization gain. It is deliberately NOT raylib's global
	// master volume, which would also attenuate sound effects.
	music_volume:             f32 `json:"-"`,
	fade_in_time:             f32,
	fade_out_time:            f32,
	stop_fade_time:           f32,
	start_next_time:          f32,
	shuffle:                  bool,
	loop:                     bool,
	normalize_volume:         bool,
	target_loudness:          f32,
	// Cached per-track loudness measurements, keyed by track path, so we don't
	// re-decode unchanged files on every launch.
	track_loudness:           map[PathName]TrackLoudness,
	playlists:                Playlists `json:"-"`,
	current_playing_playlist: ^Playlist `json:"-"`,
	music_voices:             [MUSIC_VOICE_COUNT]MusicVoice `json:"-"`,
	current_sounds:           Sounds `json:"-"`,
	is_sound_playing:         bool `json:"-"`,
}

// A cross-fade only ever blends the outgoing track into the incoming one, so two
// voices is the most we need.
MUSIC_VOICE_COUNT :: 2

// One playing music stream and the state needed to fade it in or out. fade is a
// linear 0..1 position run through music_fade_amplitude to get the actual
// volume curve, so the same value drives a fade in (toward 1) or out (toward 0)
// simply by moving fade_target. Everything else (the track's gain, the fade
// rate) is derived from the settings on demand rather than copied in here, so
// there is a single source of truth and live setting changes take effect mid
// fade.
MusicVoice :: struct {
	music:        rl.Music,
	// Whether this slot holds a live stream. Empty slots are skipped.
	active:       bool,
	// The track being played, used to look up its normalization gain. Borrowed
	// from the playlist, which outlives every voice.
	path:         string,
	// The master music volume this voice plays at, snapshotted when it started.
	// Held per-voice (rather than read from the live setting) so a volume change
	// cross-fades: the outgoing track keeps its old volume while the incoming
	// one rises to the new one, instead of every voice jumping at once.
	volume:       f32,
	// Current linear fade position and where it is heading (0 = silent, 1 = full).
	// fade_target also encodes direction: 1 is fading in, 0 is fading out.
	fade:         f32,
	fade_target:  f32,
	// Set once the lead (incoming) voice has kicked off the next track, so the
	// cross-fade is triggered exactly once per track.
	started_next: bool,
}

Playlist :: struct {
	name:                  string,
	tracks:                hm.Dynamic_Handle_Map(Track, TrackHandle),
	played_track_count:    int,
	current_playing_track: ^Track,
}

Playlists :: [dynamic; 64]Playlist

TrackHandle :: distinct hm.Handle32

Track :: struct {
	handle:        TrackHandle,
	title:         string,
	path:          string,

	// The actual portion of the track to play. If it's been edited, this will be
	// the "slice" to play. If not, this is the full track length.
	slice_to_play: struct {
		start_time: f16,
		end_time:   f16,
	},
	played:        bool,
}

PathName :: string

// A cached loudness measurement for one track. file_hash and active_rms persist
// so we can skip re-decoding unchanged files. volume_multiplier is derived from
// the whole set at load time (see compute_playback_gains) and never persisted.
TrackLoudness :: struct {
	// Used to only re-measure if the hash has changed.
	file_hash:         string,
	active_rms:        f32,
	volume_multiplier: f32 `json:"-"`,
}

Sounds :: [dynamic; 32]rl.Sound

TrackKeys :: [dynamic; 512]PathName

sound_settings: ^SoundSettings

// Track paths are stored relative to the directory the binary is run from so
// the gain cache in settings stays portable across machines and checkouts.
// Playlist dirs are usually symlinks; keys/paths go through the symlink
// (assets/sounds/music/<playlist>/<track>) rather than the resolved target,
// so the cache stays portable even when the symlink target moves.
MUSIC_DIR :: "assets/sounds/music"

MAX_FADE_IN_TIME :: 10
MAX_FADE_OUT_TIME :: 10
MAX_STOP_FADE_TIME :: 10
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -12
MAX_TARGET_LOUDNESS :: -6
MUSIC_ACTIVE_SAMPLE_GATE :: f32(0.02)
MUSIC_MIN_NORMALIZED_GAIN :: f32(0.05)
// Raylib clamps per-music volume to 1.0. Normalization therefore picks a shared
// target loudness no louder than the quietest track, then attenuates louder
// tracks down to it.
MUSIC_MAX_NORMALIZED_GAIN :: f32(1.0)

DefaultSoundSettings := SoundSettings {
	music_volume     = 0.5,
	fade_in_time     = 2.0,
	fade_out_time    = 2.0,
	stop_fade_time   = 2.0,
	start_next_time  = 4.0,
	shuffle          = true,
	loop             = true,
	normalize_volume = true,
	target_loudness  = -8,
}

playlists_load :: proc() -> Playlists {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	defer free_all(alloc)

	potential_playlists, err := os.read_all_directory_by_path(MUSIC_DIR, context.temp_allocator)
	log.ensuref(err == nil, "Error reading music dir: %s", err)

	pool: thread.Pool
	thread.pool_init(&pool, context.temp_allocator, os.get_processor_core_count())
	defer thread.pool_destroy(&pool)

	PoolData :: struct {
		track_relative_path: string,
		track_name:          string,
		track_keys:          ^TrackKeys,
		tracks:              ^hm.Dynamic_Handle_Map(Track, TrackHandle),
		playlist_name:       string,
		// All tasks share one mutex guarding the writes to sound_settings'
		// track_loudness map, the shared track_keys list, and each playlist's
		// handle map (tracks of the same playlist are added concurrently).
		mutex:               ^sync.Mutex,
	}

	playlists: Playlists
	track_keys: TrackKeys
	mutex: sync.Mutex

	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		append(&playlists, Playlist{name = strings.clone(playlist_dir.name)})
		playlist := &playlists[len(playlists) - 1]
		hm.dynamic_init(&playlist.tracks, context.allocator)

		track_files, tracks_err := os.read_all_directory_by_path(
			playlist_dir.fullpath,
			context.temp_allocator,
		)
		log.ensuref(tracks_err == nil, "Error reading tracks in playlist dir: %s", err)

		for track_file in track_files {
			if track_file.type != .Regular do continue
			name := strings.clone_to_cstring(track_file.name, context.temp_allocator)
			if !rl.IsFileExtension(name, ".wav;.mp3;.ogg;.flac") do continue

			rel_path, rel_err := filepath.join(
				{MUSIC_DIR, playlist_dir.name, track_file.name},
				context.temp_allocator,
			)
			log.ensuref(
				rel_err == nil,
				"Error building track path for %q in %q: %v",
				track_file.name,
				playlist_dir.name,
				rel_err,
			)

			data := new(PoolData, context.temp_allocator)
			data^ = PoolData {
				track_relative_path = rel_path,
				track_name          = track_file.name,
				track_keys          = &track_keys,
				tracks              = &playlist.tracks,
				playlist_name       = playlist.name,
				mutex               = &mutex,
			}
			thread.pool_add_task(&pool, context.allocator, proc(t: thread.Task) {
					data := (^PoolData)(t.data)
					file_hash := hash_file_by_path(data.track_relative_path)

					sync.guard(data.mutex)

					track_key := PathName(data.track_relative_path)
					cached, cache_exists := sound_settings.track_loudness[track_key]
					cache_usable :=
						cache_exists &&
						cached.file_hash == file_hash &&
						(!sound_settings.normalize_volume || cached.active_rms > 0)
					if !cache_usable {
						delete(cached.file_hash)
						loudness := TrackLoudness {
							file_hash = strings.clone(file_hash),
						}
						if sound_settings.normalize_volume {}
						if !cache_exists {
							track_key = PathName(strings.clone(data.track_relative_path))
						}
						sound_settings.track_loudness[track_key] = loudness
					}

					append(&data.track_keys^, track_key)

					track := Track {
						title  = strings.clone(os.stem(data.track_name)),
						path   = strings.clone(data.track_relative_path),
						played = false,
					}
					_, err := hm.add(&data.tracks^, track)
					log.ensuref(
						err == nil,
						"Error adding track `%s` to playlist `%s`: %v",
						track,
						data.playlist_name,
						err,
					)
				}, data)
		}
	}

	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	return playlists
}

sound_play :: proc(filepath: string, volume: f32) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
	rl.SetSoundVolume(sound, volume)
	sound_settings.is_sound_playing = true
	append(&sound_settings.current_sounds, sound)
	return sound
}

playlist_play :: proc(playlist_name: string, volume: f32, cut := false) {
	found_playlist: ^Playlist
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
	sound_settings.music_volume = volume
	sound_settings.current_playing_playlist = found_playlist
	// play_next_track(found_playlist, cut)
}

playlist_free :: proc(playlist: ^Playlist) {
	delete(playlist.name)

	it := hm.iterator_make(&playlist.tracks)
	for track, _ in hm.iterate(&it) {
		delete(track.title)
		delete(track.path)
	}
	hm.dynamic_destroy(&playlist.tracks)
	playlist^ = {}
}

sound_settings_load :: proc() -> SoundSettings {
	filename := sound_settings_filename()
	if !os.exists(filename) {
		return DefaultSoundSettings
	}

	settings := DefaultSoundSettings
	settings_data, err := os.read_entire_file(filename, context.temp_allocator)
	log.ensuref(err == nil, "Error reading settings file: %v", err)

	json_err := json.unmarshal(settings_data, &settings, .Bitsquid, context.allocator)
	log.ensuref(json_err == nil, "Error unmarshaling json from settings file: %v", json_err)

	return settings
}

sound_settings_filename :: proc() -> string {
	return fmt.tprint("./", "settings.sjson", sep = filepath.SEPARATOR_STRING)
}

sound_settings_save :: proc() {
	settings := SoundSettings {
		fade_in_time     = sound_settings.fade_in_time,
		fade_out_time    = sound_settings.fade_out_time,
		stop_fade_time   = sound_settings.stop_fade_time,
		start_next_time  = sound_settings.start_next_time,
		shuffle          = sound_settings.shuffle,
		loop             = sound_settings.loop,
		normalize_volume = sound_settings.normalize_volume,
		target_loudness  = sound_settings.target_loudness,
		track_loudness   = sound_settings.track_loudness,
	}

	settings_json, json_err := json.marshal(
		settings,
		json.Marshal_Options {
			spec = .Bitsquid,
			pretty = true,
			use_spaces = true,
			spaces = 2,
			mjson_keys_use_equal_sign = true,
			mjson_keys_use_quotes = true,
			sort_maps_by_key = true,
		},
		context.temp_allocator,
	)
	// In the future, we may want to gracefully fail here to keep the show running.
	log.ensuref(json_err == nil, "Error unmarshaling json from settings file: %v", json_err)

	filename := sound_settings_filename()
	write_err := os.write_entire_file(filename, settings_json)
	log.ensuref(write_err == nil, "Error writing settings file: %v", write_err)
}

sound_settings_init :: proc() -> ^SoundSettings {
	rl.InitAudioDevice()

	sound_settings = new(SoundSettings)
	sound_settings^ = sound_settings_load()
	if sound_settings.track_loudness == nil {
		sound_settings.track_loudness = make(map[PathName]TrackLoudness)
	}
	sound_settings.playlists = playlists_load()

	// Save immediately since we may have just calculated gains.
	sound_settings_save()

	return sound_settings
}

sound_update :: proc() {
	for sound, index in sound_settings.current_sounds {
		if !rl.IsSoundPlaying(sound) {
			rl.UnloadSound(sound)
			unordered_remove(&sound_settings.current_sounds, index)
		}

	}
}

sound_hot_reloaded :: proc(settings: ^SoundSettings) {
	sound_settings = settings
}

sound_shutdown :: proc() {
	if sound_settings != nil {
		for voice in sound_settings.music_voices {
			if !voice.active do continue
			rl.StopMusicStream(voice.music)
			rl.UnloadMusicStream(voice.music)
		}
		for sound in sound_settings.current_sounds {
			rl.UnloadSound(sound)
		}

		for &playlist in sound_settings.playlists {
			playlist_free(&playlist)
		}

		for key, loudness in sound_settings.track_loudness {
			delete(key)
			delete(loudness.file_hash)
		}
		delete(sound_settings.track_loudness)

		free(sound_settings)
		sound_settings = nil
	}
	rl.CloseAudioDevice()
}
