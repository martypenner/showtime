package sound

import "../utils"
import hm "core:container/handle_map"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
	playlists:                [dynamic]Playlist `json:"-"`,
	current_playing_playlist: ^Playlist `json:"-"`,
	// The music streams currently producing sound. A cross-fade is pairwise, so
	// at most two are ever active at once: the outgoing track fading to silence
	// and the incoming one fading up. Steady state uses just one slot.
	music_voices:             [MUSIC_VOICE_COUNT]MusicVoice `json:"-"`,
	current_sounds:           [dynamic]rl.Sound `json:"-"`,
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

// Sets the music master volume and applies it to the currently playing track
// (combined with that track's normalization gain). Sound effects are unaffected
// because each effect carries its own volume; this never touches raylib's global
// master volume.
set_music_volume :: proc(volume: f32) {
	sound_settings.music_volume = volume
	// The slider changes the music that is playing right now, so update every
	// live voice's snapshot too (a scene switch, which should only set the
	// incoming track's volume, uses play_playlist instead).
	for &voice in sound_settings.music_voices {
		if !voice.active do continue
		voice.volume = volume
		rl.SetMusicVolume(voice.music, music_voice_volume(voice))
	}
}

// Resolves a voice's live raylib volume from its snapshotted master volume, the
// track's normalization gain, and its current point on the fade curve.
music_voice_volume :: proc(voice: MusicVoice) -> f32 {
	return voice.volume * music_track_gain(voice.path) * music_fade_amplitude(voice.fade)
}

// Looks up a track's normalization gain from the loudness cache (the single
// source of truth), falling back to unity if it was never measured.
music_track_gain :: proc(path: string) -> f32 {
	loudness, ok := sound_settings.track_loudness[PathName(path)]
	if !ok do return MUSIC_MAX_NORMALIZED_GAIN
	return clamp_music_gain(loudness.volume_multiplier)
}

// Picks a voice's fade rate from the configured fade times: a voice heading to
// full (fade_target 1) is fading in, one heading to silence is fading out.
music_voice_fade_speed :: proc(voice: MusicVoice) -> f32 {
	fade_time := voice.fade_target == 1 ? sound_settings.fade_in_time : sound_settings.fade_out_time
	return fade_speed_for(fade_time)
}

// Shapes the linear 0..1 fade position into a volume multiplier. Smoothstep
// gives a gentle ease-in/ease-out so fades start and end softly rather than
// ramping linearly.
music_fade_amplitude :: proc(fade: f32) -> f32 {
	t := clamp(fade, 0, 1)
	return t * t * (3 - 2 * t)
}

// Converts a fade duration (seconds) into a per-second fade speed. A
// non-positive time means "no fade", advancing fast enough to snap to the
// target on the next frame.
fade_speed_for :: proc(fade_time: f32) -> f32 {
	if fade_time <= 0 do return 1e9
	return 1.0 / fade_time
}

// Steps a voice's linear fade toward its target at the given speed (fade units
// per second) without overshooting.
advance_fade :: proc(voice: ^MusicVoice, speed, dt: f32) {
	step := speed * dt
	if voice.fade < voice.fade_target {
		voice.fade = min(voice.fade + step, voice.fade_target)
	} else if voice.fade > voice.fade_target {
		voice.fade = max(voice.fade - step, voice.fade_target)
	}
}

load_playlists :: proc() -> [dynamic]Playlist {
	potential_playlists, err := os.read_all_directory_by_path(MUSIC_DIR, context.temp_allocator)
	log.ensuref(err == nil, "Error reading music dir: %s", err)

	playlists := make([dynamic]Playlist)
	track_keys := make([dynamic]PathName, context.temp_allocator)
	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		playlist := Playlist{}
		playlist.name = strings.clone(playlist_dir.name)
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

			title := strings.clone(os.stem(track_file.name))
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
			track_path := strings.clone(rel_path)

			file_hash, hash_err := utils.hash_file_by_path(track_file.fullpath)
			log.ensuref(hash_err == nil, "Error hashing file: %s", hash_err)

			track_key := PathName(track_path)
			cached, cache_exists := sound_settings.track_loudness[track_key]
			cache_usable :=
				cache_exists &&
				cached.file_hash == file_hash &&
				(!sound_settings.normalize_volume || cached.active_rms > 0)
			if !cache_usable {
				if cache_exists {
					delete(cached.file_hash)
				}
				loudness := TrackLoudness {
					file_hash = strings.clone(file_hash),
				}
				if sound_settings.normalize_volume {
					file_type := strings.clone_to_cstring(
						filepath.ext(track_file.name),
						context.temp_allocator,
					)
					file_data, read_err := os.read_entire_file_from_path(
						track_file.fullpath,
						context.allocator,
					)
					log.ensuref(read_err == nil, "Error reading file: %s", read_err)
					active_rms, ok := measure_track_loudness(file_data, file_type)
					delete(file_data)
					if ok do loudness.active_rms = active_rms
				}
				if cache_exists {
					sound_settings.track_loudness[track_key] = loudness
				} else {
					// Cache keys are owned by the cache, not aliased to Track.path,
					// so shutdown/pruning can free each owner exactly once.
					sound_settings.track_loudness[PathName(strings.clone(track_path))] = loudness
				}
			}
			delete(file_hash, context.temp_allocator)
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

		append(&playlists, playlist)
	}
	compute_playback_gains(track_keys[:])

	return playlists
}

// Plays a one-shot sound effect at the given volume (0..1). The volume is per
// effect and independent of the music volume, so callers tune each effect to
// sit well against the (normalized) music.
play_sound :: proc(filepath: string, volume: f32) -> rl.Sound {
	sound := rl.LoadSound(strings.clone_to_cstring(filepath, context.temp_allocator))
	rl.PlaySound(sound)
	rl.SetSoundVolume(sound, volume)
	sound_settings.is_sound_playing = true
	append(&sound_settings.current_sounds, sound)
	return sound
}
stop_sound :: proc(sound: rl.Sound) {}

// Starts a playlist at the given master volume. The volume becomes the target
// for the incoming track (and any tracks that follow it); voices already fading
// out keep the volume they started at, so switching playlists cross-fades the
// volume change instead of jumping the outgoing track to the new level. With cut
// the first track hard-cuts in at full volume instead of cross-fading.
play_playlist :: proc(playlist_name: string, volume: f32, cut := false) {
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
	play_next_track(found_playlist, cut)
}

// Picks the next track to play from a playlist and starts it. By default it
// cross-fades out whatever is currently playing; with cut it stops everything
// instantly and starts the new track at full volume. Tracks are chosen randomly
// from the unplayed set; once every track has played the set resets, so a
// playlist runs forever. This drives both the user starting a playlist and the
// automatic advance at the end of each track.
play_next_track :: proc(playlist: ^Playlist, cut := false) {
	track_count := int(hm.len(playlist.tracks))
	if track_count == 0 {
		log.warnf("Playlist has no tracks, skipping: %s", playlist.name)
		return
	}

	if playlist.played_track_count >= track_count {
		it := hm.iterator_make(&playlist.tracks)
		for track, handle in hm.iterate(&it) {
			assert(hm.is_valid(&playlist.tracks, handle))
			track.played = false
		}
		playlist.played_track_count = 0
	}

	chosen_track: ^Track
	unplayed_seen := 0
	it := hm.iterator_make(&playlist.tracks)
	for track, _ in hm.iterate(&it) {
		if track.played do continue

		unplayed_seen += 1
		if rand.int_max(unplayed_seen) == 0 {
			chosen_track = track
		}
	}
	if chosen_track == nil {
		log.warnf("Couldn't choose track from playlist, skipping: %s", playlist.name)
		return
	}

	log.debugf("Chosen random track: %v", chosen_track^)
	playlist.current_playing_track = chosen_track
	chosen_track.played = true
	playlist.played_track_count += 1
	play_music(chosen_track^, cut)
}

pause_playlist :: proc() {}
stop_playlist :: proc() {}

// Starts a track as a new music voice. By default it fades in while the voices
// already playing fade out, producing a cross-fade (outgoing ramps down over
// fade_out_time, incoming up over fade_in_time). With cut it instead stops every
// playing voice immediately and starts the new track already at full volume, for
// a hard "drop the needle" transition with no fades.
play_music :: proc(track: Track, cut := false) {
	music := rl.LoadMusicStream(strings.clone_to_cstring(track.path, context.temp_allocator))
	music.looping = false
	_, gain_ready := sound_settings.track_loudness[PathName(track.path)]
	log.ensuref(gain_ready, "Playback gain was not computed for track: %v", track)

	if cut {
		// Drop the needle: kill everything instantly so there is nothing left to
		// fade out below.
		for index in 0 ..< len(sound_settings.music_voices) {
			unload_music_voice(index)
		}
	}

	// Claim a slot for the incoming track before touching the others, so the
	// voice we are about to fill is not also told to fade out below.
	slot := acquire_music_voice_slot()

	// Whatever is still playing becomes outgoing: fade it out and stop it from
	// triggering another advance while it winds down. After a cut nothing is
	// active here.
	for &voice in sound_settings.music_voices {
		if !voice.active do continue
		voice.fade_target = 0
		voice.started_next = true
	}

	voice := MusicVoice {
		music       = music,
		active      = true,
		path        = track.path,
		volume      = sound_settings.music_volume,
		fade        = cut ? 1 : 0,
		fade_target = 1,
	}
	rl.SetMusicVolume(music, music_voice_volume(voice))
	sound_settings.music_voices[slot] = voice

	rl.PlayMusicStream(music)
}

// Returns the index of a voice slot ready for a new track. Prefers an empty
// slot; if a cross-fade is still in flight and both are busy, it reuses (and
// cuts) the quietest voice, which is the one already closest to silent.
acquire_music_voice_slot :: proc() -> int {
	for &voice, index in sound_settings.music_voices {
		if !voice.active do return index
	}

	quietest := 0
	for &voice, index in sound_settings.music_voices {
		if voice.fade < sound_settings.music_voices[quietest].fade do quietest = index
	}
	unload_music_voice(quietest)
	return quietest
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

sample_from_wave :: proc(wave: rl.Wave, index: int) -> (sample: f32, ok: bool) {
	switch wave.sampleSize {
	case 8:
		samples := ([^]u8)(wave.data)
		return (f32(samples[index]) - 128) / 128, true
	case 16:
		samples := ([^]i16)(wave.data)
		return f32(samples[index]) / 32768, true
	case 32:
		samples := ([^]f32)(wave.data)
		return samples[index], true
	}

	return 0, false
}

make_track_loudness_cache :: proc() -> map[PathName]TrackLoudness {
	return make(map[PathName]TrackLoudness)
}

destroy_track_loudness_cache :: proc(cache: ^map[PathName]TrackLoudness) {
	if cache^ == nil do return

	for track_key, loudness in cache^ {
		delete(string(track_key))
		delete(loudness.file_hash)
	}
	delete(cache^)
	cache^ = nil
}

destroy_playlist :: proc(playlist: ^Playlist) {
	delete(playlist.name)

	it := hm.iterator_make(&playlist.tracks)
	for track, _ in hm.iterate(&it) {
		delete(track.title)
		delete(track.path)
	}
	hm.dynamic_destroy(&playlist.tracks)
	playlist^ = {}
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

measure_track_loudness :: proc(
	file_data: []byte,
	file_type: cstring,
) -> (
	active_rms: f32,
	ok: bool,
) {
	wave := rl.LoadWaveFromMemory(file_type, raw_data(file_data), i32(len(file_data)))
	if !rl.IsWaveValid(wave) {
		log.warnf("Couldn't analyze music loudness, using unity gain: %s", file_type)
		return 0, false
	}
	defer rl.UnloadWave(wave)

	sample_count := int(wave.frameCount) * int(wave.channels)
	if sample_count == 0 do return 0, false

	active_sum_squares: f64
	active_sample_count := 0
	all_sum_squares: f64

	for index := 0; index < sample_count; index += 1 {
		sample, sample_ok := sample_from_wave(wave, index)
		if !sample_ok {
			log.warnf(
				"Couldn't analyze music loudness for unsupported %d-bit samples, using unity gain: %s",
				wave.sampleSize,
				file_type,
			)
			return 0, false
		}

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
		// log.debugf("Playback gain for %q: %2.2f", string(track_key), loudness.volume_multiplier)
	}
}

settings_filename :: proc() -> string {
	return fmt.tprint("./", "settings.sjson", sep = filepath.SEPARATOR_STRING)
}

load_settings :: proc() -> SoundSettings {
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
			cloned.file_hash = strings.clone(loudness.file_hash)
			settings.track_loudness[PathName(strings.clone(string(track_key)))] = cloned
		}
	}

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
		loudness := sound_settings.track_loudness[track_key]
		delete_key(&sound_settings.track_loudness, track_key)
		delete(string(track_key))
		delete(loudness.file_hash)
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

init_settings :: proc() -> ^SoundSettings {
	rl.InitAudioDevice()

	sound_settings = new(SoundSettings)
	sound_settings^ = load_settings()
	if sound_settings.track_loudness == nil do sound_settings.track_loudness = make_track_loudness_cache()
	sound_settings.playlists = load_playlists()
	sound_settings.current_sounds = make([dynamic]rl.Sound)

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

	dt := rl.GetFrameTime()
	should_advance := false
	any_active := false

	for index in 0 ..< len(sound_settings.music_voices) {
		voice := &sound_settings.music_voices[index]
		if !voice.active do continue

		advance_fade(voice, music_voice_fade_speed(voice^), dt)
		rl.SetMusicVolume(voice.music, music_voice_volume(voice^))

		if !rl.IsMusicStreamPlaying(voice.music) {
			// Stream ran out before the cross-fade window (e.g. a very short
			// track, or start_next_time of 0); advance if it was the lead.
			if voice.fade_target == 1 do should_advance = true
			unload_music_voice(index)
			continue
		}
		rl.UpdateMusicStream(voice.music)

		// Outgoing voice has fully faded out: its part of the cross-fade is done.
		if voice.fade_target == 0 && voice.fade <= 0 {
			unload_music_voice(index)
			continue
		}

		// Lead voice reaching its tail starts the cross-fade into the next track.
		if voice.fade_target == 1 && !voice.started_next && music_voice_near_end(voice^) {
			voice.started_next = true
			should_advance = true
		}
		any_active = true
	}

	if should_advance && sound_settings.current_playing_playlist != nil {
		play_next_track(sound_settings.current_playing_playlist)
	} else if !any_active {
		sound_settings.current_playing_playlist = nil
	}
}

// Reports whether the lead voice is within start_next_time of its end, i.e. it
// is time to begin cross-fading into the next track.
music_voice_near_end :: proc(voice: MusicVoice) -> bool {
	length := rl.GetMusicTimeLength(voice.music)
	if length <= 0 do return false
	remaining := length - rl.GetMusicTimePlayed(voice.music)
	return remaining <= sound_settings.start_next_time
}

// Stops, unloads, and clears the voice in the given slot, leaving it free for a
// future track.
unload_music_voice :: proc(index: int) {
	voice := &sound_settings.music_voices[index]
	if !voice.active do return
	rl.StopMusicStream(voice.music)
	rl.UnloadMusicStream(voice.music)
	voice^ = {}
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
	if sound_settings != nil {
		for voice in sound_settings.music_voices {
			if !voice.active do continue
			rl.StopMusicStream(voice.music)
			rl.UnloadMusicStream(voice.music)
		}
		for sound in sound_settings.current_sounds {
			rl.UnloadSound(sound)
		}
		delete(sound_settings.current_sounds)

		destroy_track_loudness_cache(&sound_settings.track_loudness)
		for &playlist in sound_settings.playlists {
			destroy_playlist(&playlist)
		}
		delete(sound_settings.playlists)

		free(sound_settings)
		sound_settings = nil
	}
	rl.CloseAudioDevice()
}
