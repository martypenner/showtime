package game

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
	use_house_music:          bool,
	fade_in_time:             f32,
	fade_out_time:            f32,
	start_next_time:          f32,
	shuffle:                  bool,
	loop:                     bool,
	normalize_volume:         bool,
	target_loudness:          f32,
	playlists:                Playlists `json:"-"`,
	current_playing_playlist: ^Playlist `json:"-"`,
	music_voices:             [MUSIC_VOICE_COUNT]MusicVoice `json:"-"`,
	current_effect:           SoundTransitionEffect `json:"-"`,
	current_sounds:           Sounds `json:"-"`,
	is_sound_playing:         bool `json:"-"`,
}

// A cross-fade only ever blends the outgoing track into the incoming one, so two
// voices is the most we need.
MUSIC_VOICE_COUNT :: 2

// One playing music stream and the state needed to fade it in or out.
// current_fade is a linear 0..1 position run through music_amplitude_fade to get the actual
// volume curve, so the same value drives a fade in (toward 1) or out (toward 0)
// simply by moving fade_target. Everything else (the track's gain, the fade
// rate) is derived from the settings on demand rather than copied in here, so
// there is a single source of truth and live setting changes take effect mid
// fade.
MusicVoice :: struct {
	music:               rl.Music,
	// Whether this slot holds a live stream. Empty slots are skipped.
	active:              bool,
	// The track being played, used to look up its normalization gain. Borrowed
	// from the playlist, which outlives every voice.
	path:                string,
	// The master music volume this voice plays at, snapshotted when it started.
	// Held per-voice (rather than read from the live setting) so a volume change
	// cross-fades: the outgoing track keeps its old volume while the incoming
	// one rises to the new one, instead of every voice jumping at once.
	volume:              f32,
	// Current linear fade position and where it is heading (0 = silent, 1 = full).
	// fade_target also encodes direction: 1 is fading in, 0 is fading out.
	current_fade:        f32,
	fade_target:         f32,
	hold_time_remaining: f32,
	// Set once the lead (incoming) voice has kicked off the next track, so the
	// cross-fade is triggered exactly once per track.
	started_next:        bool,
}

Playlist :: struct {
	name:                  string,
	tracks:                hm.Dynamic_Handle_Map(Track, TrackHandle),
	played_track_count:    int,
	current_playing_track: ^Track,
	last_played_track:     ^Track,
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

Sounds :: [dynamic; 32]rl.Sound

TrackKeys :: [dynamic; 512]PathName

SoundTransitionEffect :: union #no_nil {
	VolRampEffect,
	CutEffect,
}
VolRampEffect :: struct {
	target_volume:     f32,
	ramp_up_duration:  f32,
	hold_duration:     f32,
	fade_out_duration: f32,
}
CutEffect :: struct {
	target_volume: f32,
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
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -12
MAX_TARGET_LOUDNESS :: -6
MUSIC_MIN_NORMALIZED_GAIN :: f32(0.05)
// Raylib clamps per-music volume to 1.0, so normalization is attenuation-only:
// tracks louder than target_loudness are reduced toward target, and quieter
// tracks are left unchanged.
MUSIC_MAX_NORMALIZED_GAIN :: f32(1.0)

DefaultSoundSettings := SoundSettings {
	music_volume     = 0.5,
	use_house_music  = false,
	fade_in_time     = 2.0,
	fade_out_time    = 2.0,
	start_next_time  = 4.0,
	shuffle          = true,
	loop             = true,
	normalize_volume = true,
	target_loudness  = -8,
}

playlists_load :: proc() -> Playlists {
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
		// All tasks share one mutex guarding the writes to the shared track_keys
		// list and each playlist's handle map (tracks of the same playlist are
		// added concurrently).
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
					_, generated_track_ok := TRACKS[data.track_relative_path]
					log.ensuref(
						generated_track_ok,
						"Missing generated track metadata for %s",
						data.track_relative_path,
					)

					track_key := PathName(data.track_relative_path)

					sync.guard(data.mutex)

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

	for track_key in track_keys {
		_, generated_track_ok := TRACKS[string(track_key)]
		log.ensuref(generated_track_ok, "Missing generated track metadata for %s", track_key)
	}

	return playlists
}

track_volume_multiplier :: proc(active_rms: f32) -> f32 {
	if !sound_settings.normalize_volume || active_rms <= 0 do return 1

	target_db := math.clamp(
		sound_settings.target_loudness,
		MIN_TARGET_LOUDNESS,
		MAX_TARGET_LOUDNESS,
	)
	target_rms := f32(math.pow_f64(10, f64(target_db) / 20))
	return math.clamp(
		target_rms / active_rms,
		MUSIC_MIN_NORMALIZED_GAIN,
		MUSIC_MAX_NORMALIZED_GAIN,
	)
}

playlists_load_async :: proc() {
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	// Need a new temp allocator since the global one gets freed every frame, and
	// we're doing threaded chunks of work.
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)

	sound_settings.playlists = playlists_load()
}

sound_play :: proc(name: SoundEffectName, volume: f32) -> rl.Sound {
	sound := rl.LoadSound(
		strings.clone_to_cstring(sound_effect_path(name), context.temp_allocator),
	)
	rl.PlaySound(sound)
	rl.SetSoundVolume(sound, volume)
	sound_settings.is_sound_playing = true
	append(&sound_settings.current_sounds, sound)
	return sound
}

playlist_play :: proc(playlist_name: PlaylistName, effect: SoundTransitionEffect) {
	playlist_name_string := playlist_name_string(playlist_name)

	found_playlist: ^Playlist
	for &playlist in sound_settings.playlists {
		if playlist.name == playlist_name_string {
			found_playlist = &playlist
			break
		}
	}
	if found_playlist == nil {
		log.warnf("Couldn't find playlist, skipping: %s", playlist_name_string)
		return
	}

	log.debugf("Playing playlist %s", playlist_name_string)
	sound_settings.current_playing_playlist = found_playlist

	track_play_next(found_playlist, effect)
}

playlist_is_current :: proc(playlist_name: PlaylistName) -> bool {
	playlist := sound_settings.current_playing_playlist
	return playlist != nil && playlist.name == playlist_name_string(playlist_name)
}

music_voices_fade_out :: proc() {
	for &voice in sound_settings.music_voices {
		if !voice.active do continue
		voice.fade_target = 0
		voice.hold_time_remaining = 0
	}
}

music_fade_out :: proc(fade_out_duration: f32) {
	sound_settings.current_effect = VolRampEffect {
		fade_out_duration = fade_out_duration,
	}
	music_voices_fade_out()
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

track_play_next :: proc(playlist: ^Playlist, effect: SoundTransitionEffect) {
	if hm.len(playlist.tracks) == 0 {
		log.debug("Playlist has no tracks: %v", playlist.name)
		return
	}

	track := track_pick_unplayed(playlist)
	if track == nil {
		if !sound_settings.loop do return

		// Reset
		it := hm.iterator_make(&playlist.tracks)
		for current_track, _ in hm.iterate(&it) {
			current_track.played = false
		}
		track = track_pick_unplayed(playlist)
	}

	track.played = true
	playlist.last_played_track = playlist.current_playing_track
	playlist.current_playing_track = track

	sound_settings.current_effect = effect

	switch e in effect {
	case VolRampEffect:
		sound_settings.music_volume = e.target_volume
		music_voices_fade_out()
		music_voice_start(track, 0, 1, e.target_volume, e.hold_duration)
	case CutEffect:
		sound_settings.music_volume = e.target_volume
		for &voice in sound_settings.music_voices {
			music_voice_stop(&voice)
		}
		music_voice_start(track, 1, 1, e.target_volume, 0)
	}
}

music_voice_start :: proc(
	track: ^Track,
	current_fade: f32,
	fade_target: f32,
	volume: f32,
	hold_duration: f32,
) {
	voice := music_voice_find_available()
	if voice == nil do return

	music := rl.LoadMusicStream(strings.clone_to_cstring(track.path, context.temp_allocator))
	rl.SetMusicVolume(
		music,
		volume * music_amplitude_fade(current_fade, fade_target > current_fade),
	)
	rl.PlayMusicStream(music)

	voice^ = MusicVoice {
		music               = music,
		active              = true,
		path                = track.path,
		volume              = volume,
		current_fade        = current_fade,
		fade_target         = fade_target,
		hold_time_remaining = hold_duration,
	}
}

music_voice_find_available :: proc() -> ^MusicVoice {
	for &voice in sound_settings.music_voices {
		if !voice.active do return &voice
	}

	quietest_fading_out: ^MusicVoice
	for &voice in sound_settings.music_voices {
		if voice.fade_target != 0 do continue
		if quietest_fading_out == nil || voice.current_fade < quietest_fading_out.current_fade {
			quietest_fading_out = &voice
		}
	}
	if quietest_fading_out != nil {
		music_voice_stop(quietest_fading_out)
		return quietest_fading_out
	}

	return nil
}

music_voice_stop :: proc(voice: ^MusicVoice) {
	if !voice.active do return
	rl.StopMusicStream(voice.music)
	rl.UnloadMusicStream(voice.music)
	voice^ = {}
}

music_amplitude_fade :: proc(fade: f32, fading_in: bool) -> f32 {
	clamped := math.clamp(fade, 0, 1)
	if fading_in {
		return clamped * clamped
	}
	return clamped
}

music_voice_volume_current :: proc(voice: MusicVoice) -> f32 {
	track_gain := f32(1)
	if sound_settings.normalize_volume {
		generated_track, ok := TRACKS[voice.path]
		log.ensuref(ok, "Missing generated track metadata for %s", voice.path)
		track_gain = track_volume_multiplier(generated_track.active_rms)
	}

	return(
		voice.volume *
		track_gain *
		music_amplitude_fade(voice.current_fade, voice.fade_target > voice.current_fade) \
	)
}

sound_music_current_volume :: proc() -> f32 {
	current_volume: f32
	for voice in sound_settings.music_voices {
		if !voice.active do continue
		voice_volume := music_voice_volume_current(voice)
		current_volume = max(current_volume, voice_volume)
	}
	return current_volume
}

music_primary_voice :: proc() -> ^MusicVoice {
	primary: ^MusicVoice
	primary_volume: f32
	for &voice in sound_settings.music_voices {
		if !voice.active do continue
		voice_volume := music_voice_volume_current(voice)
		if primary == nil || voice_volume > primary_volume {
			primary = &voice
			primary_volume = voice_volume
		}
	}
	return primary
}

music_ramp_scene :: proc(effect: VolRampEffect) {
	sound_settings.current_effect = effect
	sound_settings.music_volume = effect.target_volume

	primary := music_primary_voice()
	for &voice in sound_settings.music_voices {
		if !voice.active do continue
		if primary != nil && &voice == primary {
			audible_volume := music_voice_volume_current(voice)
			if effect.target_volume > 0 {
				voice.current_fade = math.sqrt(
					math.clamp(audible_volume / effect.target_volume, 0, 1),
				)
			} else {
				voice.current_fade = 0
			}
			voice.volume = effect.target_volume
			voice.fade_target = 1
			voice.hold_time_remaining = effect.hold_duration
		} else {
			voice.active = false
		}
	}
}

music_voice_duration_fade :: proc(voice: ^MusicVoice) -> f32 {
	effect, ok := sound_settings.current_effect.(VolRampEffect)
	if !ok do return 0
	if voice.fade_target > voice.current_fade do return effect.ramp_up_duration
	return effect.fade_out_duration
}

music_voice_update :: proc(voice: ^MusicVoice, dt: f32) {
	if !voice.active do return

	rl.UpdateMusicStream(voice.music)
	music_voice_fade_update(voice, dt)

	rl.SetMusicVolume(voice.music, music_voice_volume_current(voice^))

	if voice.current_fade <= 0 && voice.fade_target <= 0 {
		music_voice_stop(voice)
		return
	}

	if !rl.IsMusicStreamPlaying(voice.music) {
		music_voice_stop(voice)
	}
}

music_voice_fade_update :: proc(voice: ^MusicVoice, dt: f32) {
	if voice.current_fade != voice.fade_target {
		duration := music_voice_duration_fade(voice)
		if duration <= 0 {
			voice.current_fade = voice.fade_target
		} else {
			step := dt / duration
			if voice.current_fade < voice.fade_target {
				voice.current_fade = min(voice.current_fade + step, voice.fade_target)
			} else {
				voice.current_fade = max(voice.current_fade - step, voice.fade_target)
			}
		}
	}

	if voice.current_fade >= 1 && voice.fade_target >= 1 && voice.hold_time_remaining > 0 {
		voice.hold_time_remaining = max(voice.hold_time_remaining - dt, 0)
		if voice.hold_time_remaining <= 0 {
			voice.fade_target = 0
		}
	}
}

track_pick_unplayed :: proc(playlist: ^Playlist) -> ^Track {
	if !sound_settings.shuffle {
		fallback: ^Track
		it := hm.iterator_make(&playlist.tracks)
		for current_track, _ in hm.iterate(&it) {
			if current_track.played do continue
			if fallback == nil do fallback = current_track
			if playlist.last_played_track == current_track do continue
			return current_track
		}
		return fallback
	}

	track: ^Track
	unplayed_seen := 0
	it := hm.iterator_make(&playlist.tracks)
	for current_track, _ in hm.iterate(&it) {
		if current_track.played do continue
		unplayed_seen += 1
		if rand.int_max(unplayed_seen) == 0 && playlist.last_played_track != current_track {
			track = current_track
		}
	}
	return track
}

sound_settings_filename :: proc() -> string {
	return fmt.tprint("settings.sjson", sep = filepath.SEPARATOR_STRING)
}

sound_settings_save :: proc() {
	settings := SoundSettings {
		use_house_music  = sound_settings.use_house_music,
		fade_in_time     = sound_settings.fade_in_time,
		fade_out_time    = sound_settings.fade_out_time,
		start_next_time  = sound_settings.start_next_time,
		shuffle          = sound_settings.shuffle,
		loop             = sound_settings.loop,
		normalize_volume = sound_settings.normalize_volume,
		target_loudness  = sound_settings.target_loudness,
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

	return sound_settings
}

sound_update :: proc() {
	for sound, index in sound_settings.current_sounds {
		if !rl.IsSoundPlaying(sound) {
			rl.UnloadSound(sound)
			unordered_remove(&sound_settings.current_sounds, index)
		}
	}

	dt := rl.GetFrameTime()
	active_music_count := 0
	for &voice in sound_settings.music_voices {
		if !voice.active do continue

		music_voice_update(&voice, dt)
		if !voice.active do continue
		active_music_count += 1

		if voice.fade_target == 1 &&
		   !voice.started_next &&
		   sound_settings.current_playing_playlist != nil {
			played := rl.GetMusicTimePlayed(voice.music)
			length := rl.GetMusicTimeLength(voice.music)
			if length > 0 && length - played <= sound_settings.start_next_time {
				voice.started_next = true
				track_play_next(
					sound_settings.current_playing_playlist,
					VolRampEffect {
						target_volume = sound_settings.music_volume,
						ramp_up_duration = sound_settings.fade_in_time,
						fade_out_duration = sound_settings.fade_out_time,
					},
				)
			}
		}
	}

	if active_music_count == 0 && sound_settings.current_playing_playlist != nil {
		sound_settings.current_playing_playlist.current_playing_track = nil
		sound_settings.current_playing_playlist = nil
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

		free(sound_settings)
		sound_settings = nil
	}
	rl.CloseAudioDevice()
}
