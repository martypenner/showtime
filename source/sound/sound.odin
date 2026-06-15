package sound

import "../utils"
import hm "core:container/handle_map"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"

// Sound-owned data lives here, next to the behavior that reads and mutates it.
// The shared GameMemory holds only a pointer to SoundSettings (the hot-reload
// persistence shell), so these definitions stay local to the sound Module.

SoundSettings :: struct {
	volume:                   f32 `json:"-"`,
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
	playlists:                [dynamic]Playlist `json:"-"`,
	current_playing_playlist: ^Playlist `json:"-"`,
	current_music:            rl.Music `json:"-"`,
	current_sounds:           [dynamic]rl.Sound `json:"-"`,
	is_sound_playing:         bool `json:"-"`,
}

Playlist :: struct {
	name:                  string,
	tracks:                hm.Dynamic_Handle_Map(Track, TrackHandle),
	played_track_count:    int,
	current_playing_track: ^Track,
}

TrackHandle :: hm.Handle32

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

sound_settings: ^SoundSettings

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
	volume           = 1.0,
	fade_in_time     = 2.0,
	fade_out_time    = 2.0,
	stop_fade_time   = 2.0,
	start_next_time  = 4.0,
	shuffle          = true,
	loop             = true,
	normalize_volume = true,
	target_loudness  = -8,
}

set_volume :: proc(volume: f32) {
	sound_settings.volume = volume
	rl.SetMasterVolume(volume)
}

load_playlists :: proc(alloc: mem.Allocator) -> [dynamic]Playlist {
	// Track paths are stored relative to the directory the binary is run from so
	// the gain cache in settings stays portable across machines and checkouts.
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	log.ensuref(cwd_err == nil, "Error getting working directory: %v", cwd_err)

	potential_playlists, err := os.read_all_directory_by_path(
		"assets/sounds/music",
		context.temp_allocator,
	)
	log.ensuref(err == nil, "Error reading music dir: %s", err)

	playlists := make([dynamic]Playlist, alloc)
	track_keys := make([dynamic]PathName, context.temp_allocator)
	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		playlist := Playlist{}
		playlist.name = strings.clone(playlist_dir.name, alloc)
		hm.dynamic_init(&playlist.tracks, alloc)
		track_files, tracks_err := os.read_all_directory_by_path(
			playlist_dir.fullpath,
			context.temp_allocator,
		)
		log.ensuref(tracks_err == nil, "Error reading tracks in playlist dir: %s", err)

		for track_file in track_files {
			if track_file.type != .Regular do continue
			name := strings.clone_to_cstring(track_file.name, context.temp_allocator)
			if rl.IsFileExtension(name, ".wav;.mp3;.ogg;.flac") {
				title := strings.clone(os.stem(track_file.name), alloc)
				rel_path, rel_err := filepath.rel(cwd, track_file.fullpath, context.temp_allocator)
				log.ensuref(
					rel_err == .None,
					"Error making track path relative to %q: %q (%v)",
					cwd,
					track_file.fullpath,
					rel_err,
				)
				track_path := strings.clone(rel_path, alloc)

				// It would be ideal to pass an existing file handle here, but I simply
				// don't want to store a handle I only use for this check.
				file_hash, hash_err := utils.hash_file_by_path(track_file.fullpath)
				log.ensuref(hash_err == nil, "Error hashing file: %s", hash_err)

				track_key := PathName(track_path)
				cached, cache_exists := sound_settings.track_loudness[track_key]
				cache_usable :=
					cache_exists &&
					cached.file_hash == file_hash &&
					(!sound_settings.normalize_volume || cached.active_rms > 0)
				if !cache_usable {
					loudness := TrackLoudness {
						file_hash = strings.clone(file_hash, alloc),
					}
					if sound_settings.normalize_volume {
						active_rms, ok := measure_track_loudness(track_path)
						if ok do loudness.active_rms = active_rms
					}
					sound_settings.track_loudness[track_key] = loudness
				}
				append(&track_keys, track_key)

				track := Track {
					title  = title,
					path   = track_path,
					played = false,
				}
				_, err := hm.add(&playlist.tracks, track)
				log.ensuref(
					err == nil,
					"Error adding track `%s` to playlist `%s`: %v",
					track,
					playlist.name,
					err,
				)
			}
		}

		append(&playlists, playlist)
	}
	compute_playback_gains(track_keys[:])

	return playlists
}

play_sound :: proc(filepath: string) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
	// Set lower volume to match closer to normalized music tracks (which are
	// brought down to a lower volume).
	rl.SetSoundVolume(sound, 0.6)
	sound_settings.is_sound_playing = true
	append(&sound_settings.current_sounds, sound)
	return sound
}
stop_sound :: proc(sound: rl.Sound) {}

play_playlist :: proc(playlist_name: string) {
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
	track_count := int(hm.len(found_playlist.tracks))
	if track_count == 0 {
		log.warnf("Playlist has no tracks, skipping: %s", playlist_name)
		return
	}

	if found_playlist.played_track_count >= track_count {
		it := hm.iterator_make(&found_playlist.tracks)
		for track, handle in hm.iterate(&it) {
			assert(hm.is_valid(&found_playlist.tracks, handle))
			track.played = false
		}
		found_playlist.played_track_count = 0
	}

	chosen_track: ^Track
	unplayed_seen := 0
	it := hm.iterator_make(&found_playlist.tracks)
	for track, _ in hm.iterate(&it) {
		if track.played do continue

		unplayed_seen += 1
		if rand.int_max(unplayed_seen) == 0 {
			chosen_track = track
		}
	}
	if chosen_track == nil {
		log.warnf("Couldn't choose track from playlist, skipping: %s", playlist_name)
		return
	}

	log.debugf("Chosen random track: %v", chosen_track^)
	sound_settings.current_playing_playlist = found_playlist
	found_playlist.current_playing_track = chosen_track
	chosen_track.played = true
	found_playlist.played_track_count += 1
	play_music(chosen_track^)
}

pause_playlist :: proc() {}
stop_playlist :: proc() {}

play_music :: proc(track: Track) {
	music := rl.LoadMusicStream(strings.clone_to_cstring(track.path, context.temp_allocator))
	music.looping = false
	loudness, loudness_exists := sound_settings.track_loudness[PathName(track.path)]
	log.ensuref(loudness_exists, "Playback gain was not computed for track: %v", track)
	rl.SetMusicVolume(
		music,
		loudness_exists ? clamp_music_gain(loudness.volume_multiplier) : MUSIC_MAX_NORMALIZED_GAIN,
	)

	if music_is_loaded(sound_settings.current_music) {
		rl.StopMusicStream(sound_settings.current_music)
		rl.UnloadMusicStream(sound_settings.current_music)
	}

	sound_settings.current_music = music

	rl.PlayMusicStream(music)
}

music_is_loaded :: proc(music: rl.Music) -> bool {
	return music.stream.buffer != nil
}

clamp_fade_in_time :: proc() {}
clamp_fade_out_time :: proc() {}
clamp_stop_fade_time :: proc() {}
clamp_start_next_time :: proc() {}
clamp_min_target_loudness :: proc() {}
clamp_max_target_loudness :: proc() {}
clamp_track_start_time :: proc() {}
clamp_track_end_time :: proc() {}

dbfs_to_linear :: proc(db: f32) -> f32 {
	return math.pow(f32(10), db / 20)
}

clamp_music_gain :: proc(gain: f32) -> f32 {
	return min(max(gain, MUSIC_MIN_NORMALIZED_GAIN), MUSIC_MAX_NORMALIZED_GAIN)
}

make_track_loudness_cache :: proc() -> map[PathName]TrackLoudness {
	// Odin maps need cache-line-aligned backing storage. Dynamic_Arena does not
	// honor per-allocation alignment, so only the map backing lives on the app
	// allocator; path/hash strings still live in the persistent arena.
	return make(map[PathName]TrackLoudness, context.allocator)
}

playback_gain_for_track :: proc(active_rms, target_rms: f32) -> f32 {
	if active_rms <= 0 || target_rms <= 0 do return MUSIC_MAX_NORMALIZED_GAIN
	return clamp_music_gain(target_rms / active_rms)
}

playback_target_rms :: proc(target_loudness, quietest_active_rms: f32) -> f32 {
	clamped_target := min(max(target_loudness, f32(MIN_TARGET_LOUDNESS)), f32(MAX_TARGET_LOUDNESS))
	target_rms := dbfs_to_linear(clamped_target)
	if quietest_active_rms > 0 do target_rms = min(target_rms, quietest_active_rms)
	return target_rms
}

measure_track_loudness :: proc(track_path: string) -> (active_rms: f32, ok: bool) {
	wave := rl.LoadWave(strings.clone_to_cstring(track_path, context.temp_allocator))
	if !rl.IsWaveValid(wave) {
		log.warnf("Couldn't analyze music loudness, using unity gain: %s", track_path)
		return 0, false
	}
	defer rl.UnloadWave(wave)

	samples := rl.LoadWaveSamples(wave)
	if samples == nil {
		log.warnf("Couldn't read music samples, using unity gain: %s", track_path)
		return 0, false
	}
	defer rl.UnloadWaveSamples(samples)

	sample_count := int(wave.frameCount) * int(wave.channels)
	if sample_count == 0 do return 0, false

	active_sum_squares: f64
	active_sample_count := 0
	all_sum_squares: f64

	for index := 0; index < sample_count; index += 1 {
		sample := samples[index]
		magnitude := sample
		if magnitude < 0 do magnitude = -magnitude

		sample_f64 := f64(sample)
		all_sum_squares += sample_f64 * sample_f64

		if magnitude >= MUSIC_ACTIVE_SAMPLE_GATE {
			active_sum_squares += sample_f64 * sample_f64
			active_sample_count += 1
		}
	}

	if active_sample_count == 0 {
		active_sum_squares = all_sum_squares
		active_sample_count = sample_count
	}

	return f32(math.sqrt(active_sum_squares / f64(active_sample_count))), true
}

// Derives each track's playback volume multiplier from its cached loudness.
// This is a second pass because the shared target can't be louder than the
// quietest track (raylib clamps volume to 1.0, so we can only attenuate), and
// that quietest value isn't known until every track has been measured.
compute_playback_gains :: proc(track_keys: []PathName) {
	if len(track_keys) == 0 do return

	quietest_active_rms: f32
	for track_key in track_keys {
		loudness, ok := sound_settings.track_loudness[track_key]
		if !ok || loudness.active_rms <= 0 do continue
		if quietest_active_rms == 0 || loudness.active_rms < quietest_active_rms {
			quietest_active_rms = loudness.active_rms
		}
	}

	target_rms := playback_target_rms(sound_settings.target_loudness, quietest_active_rms)
	for track_key in track_keys {
		loudness, ok := sound_settings.track_loudness[track_key]
		if !ok do continue

		if sound_settings.normalize_volume {
			loudness.volume_multiplier = playback_gain_for_track(loudness.active_rms, target_rms)
		} else {
			loudness.volume_multiplier = MUSIC_MAX_NORMALIZED_GAIN
		}
		sound_settings.track_loudness[track_key] = loudness
		log.debugf("Playback gain for %q: %2.2f", string(track_key), loudness.volume_multiplier)
	}
}

settings_filename :: proc() -> string {
	return fmt.tprint("./", "settings.sjson", sep = filepath.SEPARATOR_STRING)
}

load_settings :: proc(alloc: mem.Allocator) -> SoundSettings {
	filename := settings_filename()
	if !os.exists(filename) {
		return DefaultSoundSettings
	}

	settings := DefaultSoundSettings
	settings_data, err := os.read_entire_file(filename, context.temp_allocator)
	log.ensuref(err == nil, "Error reading settings file: %v", err)

	json_err := json.unmarshal(settings_data, &settings, .Bitsquid, context.temp_allocator)
	log.ensuref(json_err == nil, "Error unmarshaling json from settings file: %v", json_err)
	if settings.track_loudness != nil {
		loaded := settings.track_loudness
		settings.track_loudness = make_track_loudness_cache()
		for track_key, loudness in loaded {
			cloned := loudness
			cloned.file_hash = strings.clone(loudness.file_hash, alloc)
			settings.track_loudness[PathName(strings.clone(string(track_key), alloc))] = cloned
		}
	}

	log.debug(settings)

	return settings
}

// Removes cached loudness entries whose tracks no longer exist on disk. Loaded
// entries outlive their tracks when files are renamed or deleted, so prune them
// against the currently loaded playlists before persisting.
prune_orphaned_track_loudness :: proc() {
	live_paths := make(map[PathName]struct{}, context.temp_allocator)
	for &playlist in sound_settings.playlists {
		it := hm.iterator_make(&playlist.tracks)
		for track, _ in hm.iterate(&it) {
			live_paths[PathName(track.path)] = {}
		}
	}

	orphaned_keys := make([dynamic]PathName, context.temp_allocator)
	for track_key in sound_settings.track_loudness {
		if track_key not_in live_paths {
			append(&orphaned_keys, track_key)
		}
	}
	for track_key in orphaned_keys {
		delete_key(&sound_settings.track_loudness, track_key)
	}
}

save_settings :: proc() {
	prune_orphaned_track_loudness()

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

	filename := settings_filename()
	write_err := os.write_entire_file(filename, settings_json)
	log.ensuref(write_err == nil, "Error writing settings file: %v", write_err)
}

init_settings :: proc(alloc: mem.Allocator) -> ^SoundSettings {
	rl.InitAudioDevice()

	sound_settings = new(SoundSettings, alloc)
	sound_settings^ = load_settings(alloc)
	if sound_settings.track_loudness == nil do sound_settings.track_loudness = make_track_loudness_cache()
	sound_settings.playlists = load_playlists(alloc)
	sound_settings.current_sounds = make([dynamic]rl.Sound, alloc)
	rl.SetMasterVolume(sound_settings.volume)

	// Save immediately since we may have just calculated gains.
	save_settings()

	return sound_settings
}

// Must be called every frame. It keeps raylib's music stream buffers filled.
// Without this, a Music stream produces no sound.
update :: proc() {
	for sound, index in sound_settings.current_sounds {
		if !rl.IsSoundPlaying(sound) {
			rl.UnloadSound(sound)
			unordered_remove(&sound_settings.current_sounds, index)
		}

	}

	if music_is_loaded(sound_settings.current_music) {
		if rl.IsMusicStreamPlaying(sound_settings.current_music) {
			rl.UpdateMusicStream(sound_settings.current_music)
		} else {
			rl.StopMusicStream(sound_settings.current_music)
			rl.UnloadMusicStream(sound_settings.current_music)
			sound_settings.current_music = {}
			sound_settings.current_playing_playlist = nil
		}
	}
}

// Re-points the Module at the persistent settings after a hot reload. The
// settings themselves live in GameMemory (the hot-reload persistence shell),
// but this package caches a pointer to them. A freshly loaded DLL starts with
// that pointer nil, so the hot-reload path must call this before any other
// sound proc runs (otherwise update() would dereference nil).
hot_reloaded :: proc(settings: ^SoundSettings) {
	sound_settings = settings
}

shutdown :: proc() {
	if music_is_loaded(sound_settings.current_music) {
		rl.StopMusicStream(sound_settings.current_music)
		rl.UnloadMusicStream(sound_settings.current_music)
		sound_settings.current_music = {}
	}
	if sound_settings.track_loudness != nil {
		delete(sound_settings.track_loudness)
		sound_settings.track_loudness = nil
	}
	rl.CloseAudioDevice()
}
