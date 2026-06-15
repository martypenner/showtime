package sound

import hm "core:container/handle_map"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Sound-owned data lives here, next to the behavior that reads and mutates it.
// The shared GameMemory holds only a pointer to SoundSettings (the hot-reload
// persistence shell), so these definitions stay local to the sound Module.

SoundSettings :: struct {
	volume:                   f32,
	fade_in_time:             f32,
	fade_out_time:            f32,
	stop_fade_time:           f32,
	start_next_time:          f32,
	shuffle:                  bool,
	loop:                     bool,
	normalize_volume:         bool,
	target_loudness:          f32,
	playlists:                [dynamic]Playlist,
	current_playing_playlist: ^Playlist,
	current_music:            rl.Music,
	current_sounds:           [dynamic]rl.Sound,
	is_sound_playing:         bool,
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

sound_settings: ^SoundSettings

MAX_FADE_IN_TIME :: 10
MAX_FADE_OUT_TIME :: 10
MAX_STOP_FADE_TIME :: 10
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -12
MAX_TARGET_LOUDNESS :: -6
MUSIC_ACTIVE_SAMPLE_GATE :: f32(0.02)
MUSIC_MIN_NORMALIZED_GAIN :: f32(0.05)
MUSIC_MAX_NORMALIZED_GAIN :: f32(4.0)

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

init_settings :: proc(alloc: mem.Allocator) -> ^SoundSettings {
	rl.InitAudioDevice()

	sound_settings = new(SoundSettings, alloc)

	sound_settings^ = DefaultSoundSettings
	sound_settings.playlists = load_playlists(alloc)
	sound_settings.current_sounds = make([dynamic]rl.Sound, alloc)
	rl.SetMasterVolume(f32(sound_settings.volume))

	return sound_settings
}

// Re-points the Module at the persistent settings after a hot reload. The
// settings themselves live in GameMemory (the hot-reload persistence shell),
// but this package caches a pointer to them. A freshly loaded DLL starts with
// that pointer nil, so the hot-reload path must call this before any other
// sound proc runs (otherwise update() would dereference nil).
hot_reloaded :: proc(settings: ^SoundSettings) {
	sound_settings = settings
}

set_volume :: proc(volume: f32) {
	sound_settings.volume = volume
	rl.SetMasterVolume(volume)
}

load_playlists :: proc(alloc: mem.Allocator) -> [dynamic]Playlist {
	potential_playlists, err := os.read_all_directory_by_path(
		"assets/sounds/music",
		context.temp_allocator,
	)
	log.ensuref(err == nil, "Error reading music dir: %s", err)

	playlists := make([dynamic]Playlist, alloc)
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
				_, err := hm.add(
					&playlist.tracks,
					Track {
						title = strings.clone(os.stem(track_file.name), alloc),
						path = strings.clone(track_file.fullpath, alloc),
					},
				)
				log.ensuref(err == nil, "Error adding track handle: %v", err)
			}
		}

		append(&playlists, playlist)
	}

	return playlists
}

play_sound :: proc(filepath: string) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
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
		for track, _ in hm.iterate(&it) {
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
	volume := normalize_volume(track)
	log.debugf("Normalizing music %q to gain: %2.2f", track.title, volume)
	rl.SetMusicVolume(music, volume)

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

normalized_music_gain :: proc(active_rms, target_loudness: f32) -> f32 {
	if active_rms <= 0 do return 1

	clamped_target := min(max(target_loudness, f32(MIN_TARGET_LOUDNESS)), f32(MAX_TARGET_LOUDNESS))
	target_rms := dbfs_to_linear(clamped_target)
	return min(max(target_rms / active_rms, MUSIC_MIN_NORMALIZED_GAIN), MUSIC_MAX_NORMALIZED_GAIN)
}

normalize_volume :: proc(track: Track) -> f32 {
	if !sound_settings.normalize_volume do return 1

	wave := rl.LoadWave(strings.clone_to_cstring(track.path, context.temp_allocator))
	if !rl.IsWaveValid(wave) {
		log.warnf("Couldn't analyze music loudness, using unity gain: %s", track.path)
		return 1
	}
	defer rl.UnloadWave(wave)

	samples := rl.LoadWaveSamples(wave)
	if samples == nil {
		log.warnf("Couldn't read music samples, using unity gain: %s", track.path)
		return 1
	}
	defer rl.UnloadWaveSamples(samples)

	sample_count := int(wave.frameCount) * int(wave.channels)
	if sample_count == 0 do return 1

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

	active_rms := f32(math.sqrt(active_sum_squares / f64(active_sample_count)))
	return normalized_music_gain(active_rms, sound_settings.target_loudness)
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

shutdown :: proc() {
	if music_is_loaded(sound_settings.current_music) {
		rl.StopMusicStream(sound_settings.current_music)
		rl.UnloadMusicStream(sound_settings.current_music)
		sound_settings.current_music = {}
	}
	rl.CloseAudioDevice()
}
