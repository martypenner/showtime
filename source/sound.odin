package game

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

// Sound-owned data lives here, next to the behavior that reads and mutates it.
// The shared GameMemory holds only a pointer to SoundSettings (the hot-reload
// persistence shell), so these definitions stay local to the sound Module.

MusicTrackBounds :: struct {
	file_hash:  string,
	start_time: f32,
	end_time:   f32,
}

SoundSettings :: struct {
	// The music master volume (0..1). Scales every music track on top of its
	// per-track normalization gain. It is deliberately NOT raylib's global
	// master volume, which would also attenuate sound effects.
	music_volume:                 f32 `json:"-"`,
	use_house_music:              bool,
	fade_in_time:                 f32,
	fade_out_time:                f32,
	start_next_time:              f32,
	shuffle:                      bool,
	loop:                         bool,
	normalize_volume:             bool,
	target_loudness:              f32,
	music_track_bounds:           map[string]MusicTrackBounds,
	playlists:                    Playlists `json:"-"`,
	current_playing_playlist:     ^Playlist `json:"-"`,
	music_voice_current:          ^MusicVoice `json:"-"`,
	music_browser_playlist_index: Maybe(i32) `json:"-"`,
	music_browser_track_index:    Maybe(i32) `json:"-"`,
	settings_save_time_left:      f32 `json:"-"`,
	music_voices:                 [MUSIC_VOICE_COUNT]MusicVoice `json:"-"`,
	current_sounds:               SoundVoices `json:"-"`,
	is_sound_playing:             bool `json:"-"`,
}

// A cross-fade only ever blends the outgoing track into the incoming one, so two
// voices is the most we need.
MUSIC_VOICE_COUNT :: 2

// One playing music stream. Fade "motion" is applied where the voice is
// changed: start a voice at the volume it should have now, then move it toward
// its final volume each update.
MusicVoice :: struct {
	music:                  rl.Music,
	// Whether this slot holds a live stream. Empty slots are skipped.
	active:                 bool,
	// The track being played, used to look up its normalization gain. Borrowed
	// from the playlist, which outlives every voice.
	path:                   string,
	playlist:               ^Playlist,
	track:                  ^Track,
	start_time:             f32,
	end_time:               f32,
	// The master music volume this voice plays at, snapshotted when it started.
	// Held per-voice (rather than read from the live setting) so a volume change
	// cross-fades: the outgoing track keeps its old volume while the incoming
	// one rises to the new one, instead of every voice jumping at once.
	volume:                 f32,
	volume_swell_target:    f32,
	volume_swell_duration:  f32,
	volume_swell_time_left: f32,
	fade_phase:             MusicFadePhase,
	fade_in_duration:       f32,
	fade_in_time_left:      f32,
	hold_time_left:         f32,
	fade_out_duration:      f32,
	fade_out_time_left:     f32,
	fade_out_quick:         bool,
	// Set once this playlist voice has kicked off the next track, so auto-next is
	// triggered exactly once per track.
	started_next:           bool,
}

Playlist :: struct {
	name:                  string,
	tracks:                [dynamic]Track,
	played_track_count:    int,
	current_playing_track: ^Track,
	last_played_track:     ^Track,
}

Playlists :: [dynamic; 64]Playlist

Track :: struct {
	title:  string,
	path:   string,
	played: bool,
}

PathName :: string

SOUND_FADE_OUT_DURATION :: f32(2.0)
SOUND_REPLAY_FADE_THRESHOLD :: f32(4.0)
SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION :: f32(0.25)

SoundVoice :: struct {
	sound:        rl.Sound,
	name:         SoundEffectName,
	volume:       f32,
	duration:     f32,
	fading:       bool,
	fade_elapsed: f32,
}

SoundVoices :: [dynamic; 32]SoundVoice

TrackKeys :: [dynamic; 512]PathName

MusicFadePhase :: enum {
	FadingIn,
	Swelling,
	Holding,
	FadingOut,
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
		playlists:           ^Playlists,
		playlist_index:      int,
		track_index:         int,
		// All tasks share one mutex guarding writes to the shared track_keys list
		// and the reserved slots in each playlist's track array.
		mutex:               ^sync.Mutex,
	}

	playlists: Playlists
	track_keys: TrackKeys
	mutex: sync.Mutex

	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		append(&playlists, Playlist{name = strings.clone(playlist_dir.name)})
		playlist_index := len(playlists) - 1

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
			track_index := len(playlists[playlist_index].tracks)
			append(&playlists[playlist_index].tracks, Track{})

			data := new(PoolData, context.temp_allocator)
			data^ = PoolData {
				track_relative_path = rel_path,
				track_name          = track_file.name,
				track_keys          = &track_keys,
				playlists           = &playlists,
				playlist_index      = playlist_index,
				track_index         = track_index,
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
					data.playlists^[data.playlist_index].tracks[data.track_index] = track
				}, data)
		}
	}

	thread.pool_start(&pool)
	thread.pool_finish(&pool)

	slice.sort_by(playlists[:], proc(a, b: Playlist) -> bool {
		return strings.compare(a.name, b.name) < 0
	})

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
	for _, playlist_index in sound_settings.playlists {
		sound_settings.music_browser_playlist_index = i32(playlist_index)
		sound_settings.music_browser_track_index = i32(0)
		break
	}
	_, playlist_selected := sound_settings.music_browser_playlist_index.?
	ensure(playlist_selected, "No music tracks found")
}

sound_retrigger_fade_needed :: proc(
	voice_name: SoundEffectName,
	trigger_name: SoundEffectName,
	is_playing: bool,
	duration: f32,
) -> bool {
	return voice_name == trigger_name && is_playing && duration > SOUND_REPLAY_FADE_THRESHOLD
}

sound_play :: proc(name: SoundEffectName, volume: f32) -> rl.Sound {
	start_new_sound := true
	faded_sound: rl.Sound
	sound_index := 0
	for sound_index < len(sound_settings.current_sounds) {
		voice := &sound_settings.current_sounds[sound_index]
		fade_needed := sound_retrigger_fade_needed(
			voice.name,
			name,
			rl.IsSoundPlaying(voice.sound),
			voice.duration,
		)
		if !fade_needed {
			sound_index += 1
			continue
		}

		start_new_sound = false
		if faded_sound.frameCount == 0 do faded_sound = voice.sound
		if !voice.fading {
			voice.fading = true
			voice.fade_elapsed = 0
			sound_index += 1
		}
	}
	if !start_new_sound do return faded_sound

	sound := rl.LoadSound(
		strings.clone_to_cstring(sound_effect_path(name), context.temp_allocator),
	)
	if !rl.IsSoundValid(sound) do return sound

	duration := f32(sound.frameCount) / f32(sound.sampleRate)

	rl.SetSoundVolume(sound, volume)
	rl.PlaySound(sound)
	sound_settings.is_sound_playing = true
	append(
		&sound_settings.current_sounds,
		SoundVoice{sound = sound, name = name, volume = volume, duration = duration},
	)
	return sound
}

playlist_is_current :: proc(playlist_name: PlaylistName) -> bool {
	voice := sound_settings.music_voice_current
	return voice != nil && voice.playlist.name == playlist_name_string(playlist_name)
}

track_is_current :: proc(track_name: ControlName) -> bool {
	name, _ := fmt.enum_value_to_string(track_name)
	voice := sound_settings.music_voice_current
	return voice != nil && voice.track.title == name
}

sound_settings_load :: proc() -> SoundSettings {
	filename := sound_settings_filename()
	settings := DefaultSoundSettings
	if os.exists(filename) {
		settings_data, err := os.read_entire_file(filename, context.temp_allocator)
		log.ensuref(err == nil, "Error reading settings file: %v", err)

		json_err := json.unmarshal(settings_data, &settings, .Bitsquid, context.allocator)
		log.ensuref(json_err == nil, "Error unmarshaling json from settings file: %v", json_err)
	}
	if settings.music_track_bounds == nil {
		settings.music_track_bounds = make(map[string]MusicTrackBounds)
	}
	return settings
}

music_track_bounds_resolve :: proc(
	bounds_by_path: map[string]MusicTrackBounds,
	path: string,
	file_hash: string,
	duration: f32,
) -> (
	bounds: MusicTrackBounds,
	stale: bool,
) {
	ensure(duration > 0 && !math.is_nan(duration) && !math.is_inf(duration, 0))
	stored_bounds, ok := bounds_by_path[path]
	if !ok {
		return MusicTrackBounds{file_hash = file_hash, start_time = 0, end_time = duration}, false
	}
	if stored_bounds.file_hash != file_hash {
		return MusicTrackBounds{file_hash = file_hash, start_time = 0, end_time = duration}, true
	}
	ensure(!math.is_nan(stored_bounds.start_time) && !math.is_inf(stored_bounds.start_time, 0))
	ensure(!math.is_nan(stored_bounds.end_time) && !math.is_inf(stored_bounds.end_time, 0))
	ensure(stored_bounds.start_time >= 0 && stored_bounds.start_time < stored_bounds.end_time)
	ensure(stored_bounds.end_time <= duration + 0.1)
	stored_bounds.end_time = min(stored_bounds.end_time, duration)
	return stored_bounds, false
}

music_track_time_relative :: proc(file_time, start_time, end_time: f32) -> (played, length: f32) {
	length = end_time - start_time
	ensure(length > 0)
	played = math.clamp(file_time - start_time, 0, length)
	return
}

music_voice_transition_needed :: proc(
	played: f32,
	start_time: f32,
	end_time: f32,
	start_next_time: f32,
	ended: bool,
) -> bool {
	if ended do return true
	duration := end_time - start_time
	ensure(duration > 0)
	if duration <= start_next_time do return false
	return end_time - played <= start_next_time
}

music_voice_fade_out :: proc(voice: ^MusicVoice, fade_out_duration: f32) {
	amp := music_voice_amplitude_fraction(voice^)
	voice.fade_phase = .FadingOut
	voice.fade_out_duration = fade_out_duration
	voice.fade_out_time_left = fade_out_duration * amp
	voice.hold_time_left = 0
}

music_voices_fade_out_except :: proc(voice_keep: ^MusicVoice, fade_out_duration: f32) {
	for &voice in sound_settings.music_voices {
		if !voice.active || &voice == voice_keep do continue
		music_voice_fade_out(&voice, fade_out_duration)
	}
}

music_voice_swell_after_fade_in :: proc(voice: ^MusicVoice, volume_target: f32, duration: f32) {
	ensure(voice != nil, "Tried to swell nil music voice")
	ensure(voice.active, "Tried to swell inactive music voice")

	voice.volume_swell_target = volume_target
	voice.volume_swell_duration = duration
	voice.volume_swell_time_left = duration

	if voice.fade_phase != .FadingIn {
		voice.fade_phase = .Swelling
	}
}

music_voice_start :: proc(
	playlist: ^Playlist,
	track: ^Track,
	volume: f32,
	fade_in_duration: f32,
	fade_in_time_left: f32,
	hold_time_left: f32,
	fade_out_duration: f32,
	fade_out_time_left: f32,
) -> ^MusicVoice {
	voice := music_voice_find_available()
	music := rl.LoadMusicStream(strings.clone_to_cstring(track.path, context.temp_allocator))
	ensure(rl.IsMusicValid(music), fmt.tprintf("Couldn't load music stream: %s", track.path))
	music.looping = false

	generated_track, generated_track_ok := TRACKS[track.path]
	ensure(generated_track_ok, fmt.tprintf("Missing generated track metadata: %s", track.path))
	bounds, stale := music_track_bounds_resolve(
		sound_settings.music_track_bounds,
		track.path,
		generated_track.file_hash,
		generated_track.duration_seconds,
	)
	if stale {
		log.warnf("Ignoring bounds for changed track: %s", track.path)
		delete_key(&sound_settings.music_track_bounds, track.path)
		sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}
	stream_length := rl.GetMusicTimeLength(music)
	ensure(stream_length > 0)
	bounds.end_time = min(bounds.end_time, stream_length)
	ensure(bounds.start_time < bounds.end_time)

	fade_phase := MusicFadePhase.Holding
	if fade_in_time_left > 0 {
		fade_phase = .FadingIn
	} else if hold_time_left > 0 {
		fade_phase = .Holding
	} else if fade_out_time_left > 0 {
		fade_phase = .FadingOut
	}

	voice^ = MusicVoice {
		music              = music,
		active             = true,
		path               = track.path,
		playlist           = playlist,
		track              = track,
		start_time         = bounds.start_time,
		end_time           = bounds.end_time,
		volume             = volume,
		fade_phase         = fade_phase,
		fade_in_duration   = fade_in_duration,
		fade_in_time_left  = fade_in_time_left,
		hold_time_left     = hold_time_left,
		fade_out_duration  = fade_out_duration,
		fade_out_time_left = fade_out_time_left,
	}

	rl.SetMusicVolume(music, music_voice_volume_current(voice^))
	rl.SeekMusicStream(music, bounds.start_time)
	rl.PlayMusicStream(music)
	return voice
}

music_voice_find_available :: proc() -> ^MusicVoice {
	for &voice in sound_settings.music_voices {
		if !voice.active do return &voice
	}

	quietest_fading_out: ^MusicVoice
	for &voice in sound_settings.music_voices {
		if voice.fade_phase != .FadingOut do continue
		if quietest_fading_out == nil ||
		   music_voice_amplitude_fraction(voice) <
			   music_voice_amplitude_fraction(quietest_fading_out^) {
			quietest_fading_out = &voice
		}
	}
	if quietest_fading_out != nil {
		music_voice_stop(quietest_fading_out)
		return quietest_fading_out
	}

	panic("Must find available music voice")
}

music_voice_stop :: proc(voice: ^MusicVoice) {
	if !voice.active do return
	if sound_settings.music_voice_current == voice {
		if voice.playlist.current_playing_track == voice.track {
			voice.playlist.current_playing_track = nil
		}
		if sound_settings.current_playing_playlist == voice.playlist {
			sound_settings.current_playing_playlist = nil
		}
		sound_settings.music_voice_current = nil
	}
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

music_voice_amplitude_fraction :: proc(voice: MusicVoice) -> f32 {
	switch voice.fade_phase {
	case .FadingIn:
		if voice.fade_in_duration <= 0 do return 1
		progress := 1 - math.clamp(voice.fade_in_time_left / voice.fade_in_duration, 0, 1)
		return music_amplitude_fade(progress, true)
	case .FadingOut:
		if voice.fade_out_duration <= 0 do return 0
		progress := math.clamp(voice.fade_out_time_left / voice.fade_out_duration, 0, 1)
		if voice.fade_out_quick do return music_amplitude_fade(progress, true)
		return progress
	case .Swelling, .Holding:
		return 1
	}
	return 1
}

music_voice_volume_current :: proc(voice: MusicVoice) -> f32 {
	track_gain := f32(1)
	if sound_settings.normalize_volume {
		generated_track, ok := TRACKS[voice.path]
		log.ensuref(ok, "Missing generated track metadata for %s", voice.path)
		track_gain = track_volume_multiplier(generated_track.active_rms)
	}

	return voice.volume * track_gain * music_voice_amplitude_fraction(voice)
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

music_current_label :: proc() -> string {
	voice := sound_settings.music_voice_current
	if voice == nil do return "No music playing"
	return fmt.tprintf("%s - %s", voice.playlist.name, voice.track.title)
}

music_current_progress :: proc() -> f32 {
	played, length := music_current_time()
	if length <= 0 do return 0
	return math.clamp(played / length, 0, 1)
}

music_current_time :: proc() -> (played, length: f32) {
	voice := sound_settings.music_voice_current
	if voice == nil do return 0, 0
	return music_track_time_relative(
		rl.GetMusicTimePlayed(voice.music),
		voice.start_time,
		voice.end_time,
	)
}

music_time_pair_label :: proc(played, length: f32) -> string {
	played_total := max(int(played), 0)
	played_minutes := played_total / 60
	played_seconds := played_total % 60

	length_total := max(int(length), 0)
	length_minutes := length_total / 60
	length_seconds := length_total % 60

	played_zero := ""
	if played_seconds < 10 do played_zero = "0"
	length_zero := ""
	if length_seconds < 10 do length_zero = "0"

	return fmt.tprintf(
		"%d:%s%d / %d:%s%d",
		played_minutes,
		played_zero,
		played_seconds,
		length_minutes,
		length_zero,
		length_seconds,
	)
}

music_start_playlist_track :: proc(
	playlist: ^Playlist,
	track: ^Track,
	volume: f32,
	fade_in_duration: f32,
	hold_time_left: f32,
	fade_out_duration: f32,
) -> ^MusicVoice {
	voice := music_voice_start(
		playlist,
		track,
		volume,
		fade_in_duration,
		fade_in_duration,
		hold_time_left,
		fade_out_duration,
		fade_out_duration,
	)
	ensure(voice != nil)

	sound_settings.current_playing_playlist = playlist
	sound_settings.music_voice_current = voice
	sound_settings.music_volume = volume
	track.played = true
	playlist.last_played_track = playlist.current_playing_track
	playlist.current_playing_track = track
	return voice
}

music_voice_update :: proc(voice: ^MusicVoice, dt: f32) -> bool {
	ensure(voice.active)

	rl.UpdateMusicStream(voice.music)
	music_voice_fade_update(voice, dt)

	rl.SetMusicVolume(voice.music, music_voice_volume_current(voice^))

	if voice.fade_phase == .FadingOut && voice.fade_out_time_left <= 0 do return true
	if rl.GetMusicTimePlayed(voice.music) >= voice.end_time do return true
	return !rl.IsMusicStreamPlaying(voice.music)
}

music_voice_fade_update :: proc(voice: ^MusicVoice, dt: f32) {
	switch voice.fade_phase {
	case .FadingIn:
		voice.fade_in_time_left = max(voice.fade_in_time_left - dt, 0)
		if voice.fade_in_time_left <= 0 {
			if voice.volume_swell_time_left > 0 {
				voice.fade_phase = .Swelling
			} else {
				voice.fade_phase = .Holding
			}
		}
	case .Swelling:
		if voice.volume_swell_duration <= 0 {
			voice.volume = voice.volume_swell_target
			voice.fade_phase = .Holding
			return
		}

		progress_before :=
			1 - math.clamp(voice.volume_swell_time_left / voice.volume_swell_duration, 0, 1)
		voice.volume_swell_time_left = max(voice.volume_swell_time_left - dt, 0)
		progress_after :=
			1 - math.clamp(voice.volume_swell_time_left / voice.volume_swell_duration, 0, 1)

		if progress_after > progress_before {
			amount := (progress_after - progress_before) / (1 - progress_before)
			voice.volume += (voice.volume_swell_target - voice.volume) * amount
		}

		if voice.volume_swell_time_left <= 0 {
			voice.volume = voice.volume_swell_target
			voice.fade_phase = .Holding
		}
	case .Holding:
		if voice.hold_time_left > 0 {
			voice.hold_time_left = max(voice.hold_time_left - dt, 0)
			if voice.hold_time_left <= 0 do voice.fade_phase = .FadingOut
		}
	case .FadingOut:
		voice.fade_out_time_left = max(voice.fade_out_time_left - dt, 0)
	}
}

playlist_find_by_name :: proc(playlist_name: PlaylistName) -> ^Playlist {
	name := playlist_name_string(playlist_name)
	for &playlist in sound_settings.playlists {
		if playlist.name == name do return &playlist
	}
	log.warnf("Couldn't find playlist, skipping: %s", name)
	return nil
}

playlist_pick_random_track :: proc(playlist: ^Playlist) -> ^Track {
	track := playlist_pick_track_unplayed(playlist)
	if track != nil || !sound_settings.loop do return track

	for &current_track in playlist.tracks {
		current_track.played = false
	}
	return playlist_pick_track_unplayed(playlist)
}

playlist_pick_specific_track :: proc(playlist: ^Playlist, control_name: ControlName) -> ^Track {
	for &current_track in playlist.tracks {
		track_name, ok := fmt.enum_value_to_string(control_name)
		ensure(ok)
		if current_track.title == track_name {
			return &current_track
		}
	}

	panic(fmt.tprintf("Couldn't find track by name: %v", control_name))
}

playlist_pick_track_unplayed :: proc(playlist: ^Playlist) -> ^Track {
	if !sound_settings.shuffle {
		fallback: ^Track
		for &current_track in playlist.tracks {
			if current_track.played do continue
			if fallback == nil do fallback = &current_track
			if playlist.last_played_track == &current_track do continue
			return &current_track
		}
		return fallback
	}

	track: ^Track
	fallback: ^Track
	unplayed_seen := 0
	for &current_track in playlist.tracks {
		fallback = &current_track
		if current_track.played do continue
		unplayed_seen += 1
		if rand.int_max(unplayed_seen) == 0 && playlist.last_played_track != &current_track {
			track = &current_track
		}
	}
	if track == nil do track = fallback
	return track
}

sound_settings_filename :: proc() -> string {
	return fmt.tprint("settings.sjson", sep = filepath.SEPARATOR_STRING)
}

sound_settings_save :: proc() {
	settings := SoundSettings {
		use_house_music    = sound_settings.use_house_music,
		fade_in_time       = sound_settings.fade_in_time,
		fade_out_time      = sound_settings.fade_out_time,
		start_next_time    = sound_settings.start_next_time,
		shuffle            = sound_settings.shuffle,
		loop               = sound_settings.loop,
		normalize_volume   = sound_settings.normalize_volume,
		target_loudness    = sound_settings.target_loudness,
		music_track_bounds = sound_settings.music_track_bounds,
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
	sound_settings.settings_save_time_left = 0
}

sound_settings_init :: proc() -> ^SoundSettings {
	rl.InitAudioDevice()

	sound_settings = new(SoundSettings)
	sound_settings^ = sound_settings_load()

	return sound_settings
}

sound_update :: proc() {
	dt := rl.GetFrameTime()

	sound_index := 0
	for sound_index < len(sound_settings.current_sounds) {
		voice := &sound_settings.current_sounds[sound_index]
		if voice.fading {
			voice.fade_elapsed = min(voice.fade_elapsed + dt, SOUND_FADE_OUT_DURATION)
			rl.SetSoundVolume(
				voice.sound,
				voice.volume * (1 - voice.fade_elapsed / SOUND_FADE_OUT_DURATION),
			)
			if voice.fade_elapsed >= SOUND_FADE_OUT_DURATION {
				rl.StopSound(voice.sound)
			}
		}

		if !rl.IsSoundPlaying(voice.sound) {
			rl.UnloadSound(voice.sound)
			unordered_remove(&sound_settings.current_sounds, sound_index)
			continue
		}

		sound_index += 1
	}
	sound_settings.is_sound_playing = len(sound_settings.current_sounds) > 0

	if sound_settings.settings_save_time_left > 0 {
		sound_settings.settings_save_time_left = max(
			sound_settings.settings_save_time_left - dt,
			0,
		)
		if sound_settings.settings_save_time_left == 0 do sound_settings_save()
	}

	music_voice_ended: [MUSIC_VOICE_COUNT]bool
	current_voice := sound_settings.music_voice_current
	for &voice, voice_index in sound_settings.music_voices {
		if !voice.active do continue
		music_voice_ended[voice_index] = music_voice_update(&voice, dt)
	}

	successor_started := false
	if current_voice != nil &&
	   current_voice.active &&
	   !current_voice.started_next &&
	   current_voice.fade_phase != .FadingOut {
		current_voice_ended := false
		for &voice, voice_index in sound_settings.music_voices {
			if &voice == current_voice {
				current_voice_ended = music_voice_ended[voice_index]
				break
			}
		}
		played := rl.GetMusicTimePlayed(current_voice.music)
		if music_voice_transition_needed(
			played,
			current_voice.start_time,
			current_voice.end_time,
			sound_settings.start_next_time,
			current_voice_ended,
		) {
			current_voice.started_next = true
			track := playlist_pick_random_track(current_voice.playlist)
			if track != nil {
				new_voice := music_start_playlist_track(
					current_voice.playlist,
					track,
					sound_settings.music_volume,
					sound_settings.fade_in_time,
					0,
					sound_settings.fade_out_time,
				)
				for &voice, voice_index in sound_settings.music_voices {
					if &voice == new_voice {
						music_voice_ended[voice_index] = false
						break
					}
				}
				music_voices_fade_out_except(new_voice, sound_settings.fade_out_time)
				successor_started = true
			}
		}
	}

	for &voice, voice_index in sound_settings.music_voices {
		if !voice.active || !music_voice_ended[voice_index] do continue
		if &voice == current_voice && successor_started {
			// The successor is already current, so stopping this voice must not clear it.
			ensure(sound_settings.music_voice_current != current_voice)
		}
		music_voice_stop(&voice)
	}
}

sound_hot_reloaded :: proc(settings: ^SoundSettings) {
	sound_settings = settings
}

sound_shutdown :: proc() {
	if sound_settings.settings_save_time_left > 0 do sound_settings_save()
	rl.CloseAudioDevice()
}
