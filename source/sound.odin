package game

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import norm "path_normalize"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

// Sound-owned data lives here, next to the behavior that reads and mutates it.
// The shared GameMemory holds only a pointer to SoundSettings (the hot-reload
// persistence shell), so these definitions stay local to the sound Module.

MusicTrackBounds :: struct {
	file_hash:  string,
	start_time: f32,
	end_time:   f32,
}

SoundSettings :: struct {
	mixer:                        ^mixer.Mixer `json:"-"`,
	update_ticks:                 u64 `json:"-"`,
	// The endpoint/default volume (0..1) for ordinary playback.
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
	played_track_paths:           map[string]bool,
	playlists:                    Playlists `json:"-"`,
	current_playing_playlist:     ^Playlist `json:"-"`,
	music_playback_primary:       ^MusicPlayback `json:"-"`,
	music_browser_playlist_index: i32 `json:"-"`,
	music_browser_track_index:    i32 `json:"-"`,
	settings_save_time_left:      f32 `json:"-"`,
	music_playbacks:              [MUSIC_PLAYBACK_COUNT]MusicPlayback `json:"-"`,
	current_sounds:               SoundVoices `json:"-"`,
	is_sound_playing:             bool `json:"-"`,
	wave_editor_preview:          WaveEditorPreview `json:"-"`,
	wave_editor_start_fraction:   f32 `json:"-"`,
	wave_editor_end_fraction:     f32 `json:"-"`,
}

// A cross-fade only ever blends the outgoing track into the incoming one, so two
// playbacks is the most we need.
MUSIC_PLAYBACK_COUNT :: 2

MusicVolumePoint :: struct {
	at_seconds: f32,
	volume:     f32,
}

MusicPlayback :: struct {
	mixer_audio:                ^mixer.Audio,
	mixer_track:                ^mixer.Track,
	source_path:                string,
	playlist:                   ^Playlist,
	track:                      ^Track,
	bounds_start_seconds:       f32,
	bounds_end_seconds:         f32,
	volume_points:              [8]MusicVolumePoint,
	volume_point_count:         u8,
	volume_point_next:          u8,
	volume_frame_start:         i64,
	stopping:                   bool,
	playlist_successor_started: bool,
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
	audio:       ^mixer.Audio,
	mixer_track: ^mixer.Track,
	name:        SoundEffectName,
	volume:      f32,
	duration:    f32,
	fading:      bool,
}

SoundVoices :: [dynamic; 32]SoundVoice

TrackKeys :: [dynamic; 512]PathName

sound_settings: ^SoundSettings

// Track paths are stored relative to the directory the binary is run from so
// the gain cache in settings stays portable across machines and checkouts.
// Playlist dirs are usually symlinks; keys/paths go through the symlink
// (assets/sounds/music/<playlist>/<track>) rather than the resolved target,
// so the cache stays portable even when the symlink target moves.
MUSIC_DIR :: "assets/sounds/music"

// Track metadata and waveforms load at runtime from the binary blob that
// source/tools/generate_enums writes to assets/sounds/music.rms. Keeping the
// multi-thousand-track dataset out of compiled Odin source keeps build times
// down. Strings and waveform slices point into the loaded buffer, which lives
// as long as the game memory arena.
TRACK_DATA_PATH :: "assets/sounds/music.rms"
TRACK_DATA_MAGIC :: "RMST"
TRACK_DATA_VERSION :: 1

GeneratedTrack :: struct {
	file_hash:        string,
	active_rms:       f32,
	duration_seconds: f32,
	waveform_samples: []i8,
}

TRACKS: map[string]GeneratedTrack

@(private = "file")
tracks_data: []byte

tracks_data_load :: proc() {
	if tracks_data != nil do return

	ok: bool
	tracks_data, ok = read_entire_file(TRACK_DATA_PATH)
	log.ensuref(ok, "Missing %s; run scripts/generate_enums.sh", TRACK_DATA_PATH)

	offset := 0
	read_bytes :: proc(offset: ^int, byte_count: int) -> []byte {
		ensure(len(tracks_data) - offset^ >= byte_count)
		bytes := tracks_data[offset^:offset^ + byte_count]
		offset^ += byte_count
		return bytes
	}
	read_u32 :: proc(offset: ^int) -> u32 {
		return (cast(^u32)&read_bytes(offset, 4)[0])^
	}
	read_f32 :: proc(offset: ^int) -> f32 {
		return (cast(^f32)&read_bytes(offset, 4)[0])^
	}
	read_string :: proc(offset: ^int) -> string {
		return string(read_bytes(offset, int(read_u32(offset))))
	}

	ensure(string(read_bytes(&offset, 4)) == TRACK_DATA_MAGIC)
	version := read_u32(&offset)
	log.ensuref(
		version == TRACK_DATA_VERSION,
		"Unsupported %s version %d; run scripts/generate_enums.sh",
		TRACK_DATA_PATH,
		version,
	)
	track_count := int(read_u32(&offset))
	sample_count := int(read_u32(&offset))
	ensure(track_count > 0 && sample_count > 0)

	TRACKS = make(map[string]GeneratedTrack, track_count)
	for _ in 0 ..< track_count {
		path := read_string(&offset)
		file_hash := read_string(&offset)
		active_rms := read_f32(&offset)
		duration_seconds := read_f32(&offset)
		waveform := transmute([]i8)read_bytes(&offset, sample_count)
		TRACKS[path] = GeneratedTrack {
			file_hash        = file_hash,
			active_rms       = active_rms,
			duration_seconds = duration_seconds,
			waveform_samples = waveform,
		}
	}
	ensure(offset == len(tracks_data))
}

MAX_FADE_IN_TIME :: 10
MAX_FADE_OUT_TIME :: 10
MAX_START_NEXT_TIME :: 10
MIN_TARGET_LOUDNESS :: -12
MAX_TARGET_LOUDNESS :: -6
MUSIC_MIN_NORMALIZED_GAIN :: f32(0.05)
// Normalization is attenuation-only.
MUSIC_MAX_NORMALIZED_GAIN :: f32(1.0)

DefaultSoundSettings := SoundSettings {
	music_volume             = 0.5,
	use_house_music          = false,
	fade_in_time             = 2.0,
	fade_out_time            = 2.0,
	start_next_time          = 4.0,
	shuffle                  = true,
	loop                     = true,
	normalize_volume         = true,
	target_loudness          = -8,
	wave_editor_end_fraction = 1,
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
			ext := filepath.ext(track_file.name)
			if ext != ".wav" && ext != ".mp3" && ext != ".ogg" && ext != ".flac" do continue

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
					_, generated_track_ok := TRACKS[norm.path_nfc(data.track_relative_path)]
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
		_, generated_track_ok := TRACKS[norm.path_nfc(string(track_key))]
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

sound_retrigger_fade_needed :: proc(
	voice_name: SoundEffectName,
	trigger_name: SoundEffectName,
	is_playing: bool,
	duration: f32,
) -> bool {
	return voice_name == trigger_name && is_playing && duration > SOUND_REPLAY_FADE_THRESHOLD
}

sound_play_options :: proc(
	start_frame, max_frame, fade_frames: i64,
	start_gain: f32,
) -> sdl.PropertiesID {
	props := sdl.CreateProperties()
	ensure(props != 0)
	ensure(sdl.SetNumberProperty(props, mixer.PROP_PLAY_START_FRAME_NUMBER, start_frame))
	ensure(sdl.SetNumberProperty(props, mixer.PROP_PLAY_MAX_FRAME_NUMBER, max_frame))
	ensure(sdl.SetNumberProperty(props, mixer.PROP_PLAY_FADE_IN_FRAMES_NUMBER, fade_frames))
	ensure(sdl.SetFloatProperty(props, mixer.PROP_PLAY_FADE_IN_START_GAIN_FLOAT, start_gain))
	return props
}

sound_play :: proc(name: SoundEffectName, volume: f32) -> ^mixer.Track {
	for &voice in sound_settings.current_sounds {
		if !sound_retrigger_fade_needed(voice.name, name, mixer.TrackPlaying(voice.mixer_track), voice.duration) do continue
		if !voice.fading {
			voice.fading = true
			ensure(
				mixer.StopTrack(
					voice.mixer_track,
					mixer.TrackMSToFrames(voice.mixer_track, i64(SOUND_FADE_OUT_DURATION * 1000)),
				),
			)
		}
		return voice.mixer_track
	}

	path := strings.clone_to_cstring(sound_effect_path(name), context.temp_allocator)
	audio := mixer.LoadAudio(sound_settings.mixer, path, true)
	ensure(audio != nil, fmt.tprintf("Couldn't load sound: %s", path))
	track := mixer.CreateTrack(sound_settings.mixer)
	ensure(track != nil)
	ensure(mixer.SetTrackAudio(track, audio))
	ensure(mixer.SetTrackGain(track, volume))
	ensure(mixer.PlayTrack(track, 0))
	duration_frames := mixer.GetAudioDuration(audio)
	ensure(duration_frames > 0)
	append(
		&sound_settings.current_sounds,
		SoundVoice {
			audio = audio,
			mixer_track = track,
			name = name,
			volume = volume,
			duration = f32(mixer.AudioFramesToMS(audio, duration_frames)) / 1000,
		},
	)
	sound_settings.is_sound_playing = true
	return track
}

playlist_is_current :: proc(playlist_name: PlaylistName) -> bool {
	playback := sound_settings.music_playback_primary
	return playback != nil && playback.playlist.name == playlist_name_string(playlist_name)
}

track_is_current :: proc(track_name: cstring) -> bool {
	playback := sound_settings.music_playback_primary
	return playback != nil && playback.track.title == string(track_name)
}

sound_settings_load_from_disk :: proc() -> SoundSettings {
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
	if settings.played_track_paths == nil {
		settings.played_track_paths = make(map[string]bool)
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

music_track_time_relative :: proc(
	elapsed_time, start_time, end_time: f32,
) -> (
	played, length: f32,
) {
	length = end_time - start_time
	ensure(length > 0)
	played = math.clamp(elapsed_time, 0, length)
	return
}

music_playback_volume_at :: proc(playback: ^MusicPlayback, frame: i64) -> f32 {
	ensure(playback != nil && playback.mixer_track != nil)
	ensure(playback.volume_point_count > 0)
	elapsed_seconds :=
		f32(
			mixer.AudioFramesToMS(
				playback.mixer_audio,
				max(frame - playback.volume_frame_start, 0),
			),
		) /
		1000
	previous := playback.volume_points[0]
	for point_index := 1; point_index < int(playback.volume_point_count); point_index += 1 {
		point := playback.volume_points[point_index]
		if elapsed_seconds <= point.at_seconds {
			fraction := math.clamp(
				(elapsed_seconds - previous.at_seconds) / (point.at_seconds - previous.at_seconds),
				0,
				1,
			)
			return previous.volume + (point.volume - previous.volume) * fraction
		}
		previous = point
	}
	return previous.volume
}

music_playback_volume_endpoint :: proc(playback: ^MusicPlayback) -> f32 {
	ensure(playback != nil && playback.volume_point_count > 0)
	for point_index := int(playback.volume_point_count) - 1; point_index >= 0; point_index -= 1 {
		if playback.volume_points[point_index].volume != 0 {
			return playback.volume_points[point_index].volume
		}
	}
	return 0
}

music_playback_volume_set :: proc(playback: ^MusicPlayback, points: []MusicVolumePoint) {
	ensure(playback != nil && playback.mixer_track != nil)
	ensure(len(points) > 0 && len(points) <= len(playback.volume_points))
	ensure(points[0].at_seconds == 0)
	for point, point_index in points {
		ensure(point.at_seconds >= 0 && point.volume >= 0)
		if point.volume == 0 do ensure(point_index == 0 || point_index == len(points) - 1)
		if point_index > 0 {
			previous := points[point_index - 1]
			ensure(point.at_seconds > previous.at_seconds)
			if point.volume != 0 do ensure(point.volume >= previous.volume)
		}
	}

	frame := mixer.GetTrackPlaybackPosition(playback.mixer_track)
	ensure(frame >= 0)
	audible_volume := f32(0)
	if playback.volume_point_count > 0 do audible_volume = music_playback_volume_at(playback, frame)
	copy(playback.volume_points[:], points)
	playback.volume_point_count = u8(len(points))
	playback.volume_point_next = len(points) > 1 ? 1 : 0
	playback.volume_frame_start = frame
	playback.stopping = false

	generated_track, ok := TRACKS[norm.path_nfc(playback.source_path)]
	log.ensuref(ok, "Missing generated track metadata for %s", playback.source_path)
	gain_multiplier := track_volume_multiplier(generated_track.active_rms)

	first := points[0]
	if len(points) == 1 {
		ensure(mixer.SetTrackGain(playback.mixer_track, first.volume * gain_multiplier))
		return
	}

	second := points[1]
	if second.volume > first.volume {
		destination_gain := second.volume * gain_multiplier
		start_fraction := f32(0)
		if destination_gain > 0 do start_fraction = math.clamp(audible_volume * gain_multiplier / destination_gain, 0, 1)
		ensure(mixer.SetTrackGain(playback.mixer_track, destination_gain))
		props := sound_play_options(
			frame,
			mixer.AudioMSToFrames(playback.mixer_audio, i64(playback.bounds_end_seconds * 1000)),
			mixer.AudioMSToFrames(playback.mixer_audio, i64(second.at_seconds * 1000)),
			start_fraction,
		)
		defer sdl.DestroyProperties(props)
		ensure(mixer.PlayTrack(playback.mixer_track, props))
	} else if second.volume == 0 {
		ensure(mixer.SetTrackGain(playback.mixer_track, audible_volume * gain_multiplier))
		ensure(
			mixer.StopTrack(
				playback.mixer_track,
				mixer.AudioMSToFrames(playback.mixer_audio, i64(second.at_seconds * 1000)),
			),
		)
		playback.stopping = true
	} else {
		ensure(second.volume == first.volume)
	}
}

music_playback_start :: proc(
	playlist: ^Playlist,
	track: ^Track,
	volume_endpoint: f32,
	fade_seconds: f32,
) -> ^MusicPlayback {
	playback: ^MusicPlayback
	for &candidate in sound_settings.music_playbacks {
		if candidate.mixer_track == nil {
			playback = &candidate
			break
		}
	}
	if playback == nil {
		for &candidate in sound_settings.music_playbacks {
			if candidate.stopping {
				music_playback_stop(&candidate)
				playback = &candidate
				break
			}
		}
	}
	ensure(playback != nil, "Must find available music playback")
	audio := mixer.LoadAudio(
		sound_settings.mixer,
		strings.clone_to_cstring(track.path, context.temp_allocator),
		false,
	)
	ensure(audio != nil, fmt.tprintf("Couldn't load music: %s", track.path))
	mixer_track := mixer.CreateTrack(sound_settings.mixer)
	ensure(mixer_track != nil)
	ensure(mixer.SetTrackAudio(mixer_track, audio))

	generated_track, generated_track_ok := TRACKS[norm.path_nfc(track.path)]
	ensure(generated_track_ok, fmt.tprintf("Missing generated track metadata: %s", track.path))
	bounds, stale := music_track_bounds_resolve(
		sound_settings.music_track_bounds,
		norm.path_nfc(track.path),
		generated_track.file_hash,
		generated_track.duration_seconds,
	)
	if stale {
		log.warnf("Ignoring bounds for changed track: %s", track.path)
		delete_key(&sound_settings.music_track_bounds, norm.path_nfc(track.path))
		sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}
	stream_length := f32(mixer.AudioFramesToMS(audio, mixer.GetAudioDuration(audio))) / 1000
	ensure(stream_length > 0)
	bounds.end_time = min(bounds.end_time, stream_length)
	ensure(bounds.start_time < bounds.end_time)

	playback^ = MusicPlayback {
		mixer_audio          = audio,
		mixer_track          = mixer_track,
		source_path          = track.path,
		playlist             = playlist,
		track                = track,
		bounds_start_seconds = bounds.start_time,
		bounds_end_seconds   = bounds.end_time,
	}
	ensure(mixer.SetTrackGain(mixer_track, 0))
	props := sound_play_options(
		mixer.AudioMSToFrames(audio, i64(bounds.start_time * 1000)),
		mixer.AudioMSToFrames(audio, i64(bounds.end_time * 1000)),
		0,
		1,
	)
	defer sdl.DestroyProperties(props)
	ensure(mixer.PlayTrack(mixer_track, props))
	if fade_seconds > 0 {
		music_playback_volume_set(playback, {{0, 0}, {fade_seconds, volume_endpoint}})
	} else {
		music_playback_volume_set(playback, {{0, volume_endpoint}})
	}
	return playback
}

music_playback_stop :: proc(playback: ^MusicPlayback) {
	if playback.mixer_track == nil do return
	if sound_settings.music_playback_primary == playback {
		if playback.playlist.current_playing_track == playback.track {
			playback.playlist.current_playing_track = nil
		}
		if sound_settings.current_playing_playlist == playback.playlist {
			sound_settings.current_playing_playlist = nil
		}
		sound_settings.music_playback_primary = nil
	}
	if mixer.TrackPlaying(playback.mixer_track) do ensure(mixer.StopTrack(playback.mixer_track, 0))
	mixer.DestroyTrack(playback.mixer_track)
	mixer.DestroyAudio(playback.mixer_audio)
	playback^ = {}
}

sound_music_current_volume :: proc() -> f32 {
	volume_current := f32(0)
	for &playback in sound_settings.music_playbacks {
		if playback.mixer_track == nil || !mixer.TrackPlaying(playback.mixer_track) do continue
		generated_track, ok := TRACKS[norm.path_nfc(playback.source_path)]
		log.ensuref(ok, "Missing generated track metadata for %s", playback.source_path)
		volume_current = max(
			volume_current,
			music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			) *
			track_volume_multiplier(generated_track.active_rms),
		)
	}
	return volume_current
}

music_volume_adjust :: proc(delta: f32) {
	primary := sound_settings.music_playback_primary
	if primary == nil || primary.mixer_track == nil do return
	generated_track, ok := TRACKS[norm.path_nfc(primary.source_path)]
	log.ensuref(ok, "Missing generated track metadata for %s", primary.source_path)
	current :=
		music_playback_volume_at(primary, mixer.GetTrackPlaybackPosition(primary.mixer_track)) *
		track_volume_multiplier(generated_track.active_rms)
	sound_settings.music_volume = math.clamp(current + delta, 0, 1)
	music_playback_volume_set(primary, {{0, sound_settings.music_volume}})
}

music_current_label :: proc() -> string {
	playback := sound_settings.music_playback_primary
	if playback == nil do return "No music playing"
	return fmt.tprintf("%s - %s", playback.playlist.name, playback.track.title)
}

music_current_progress :: proc() -> f32 {
	played, length := music_current_time()
	if length <= 0 do return 0
	return math.clamp(played / length, 0, 1)
}

music_current_time :: proc() -> (played, length: f32) {
	playback := sound_settings.music_playback_primary
	if playback == nil do return 0, 0
	return music_track_time_relative(
		f32(
			mixer.AudioFramesToMS(
				playback.mixer_audio,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			),
		) /
			1000 -
		playback.bounds_start_seconds,
		playback.bounds_start_seconds,
		playback.bounds_end_seconds,
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

music_playback_start_playlist_track :: proc(
	playlist: ^Playlist,
	track: ^Track,
	volume_endpoint: f32,
	fade_seconds: f32,
) -> ^MusicPlayback {
	playback := music_playback_start(playlist, track, volume_endpoint, fade_seconds)
	ensure(playback != nil)

	sound_settings.current_playing_playlist = playlist
	sound_settings.music_playback_primary = playback
	track.played = true
	sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	playlist.last_played_track = playlist.current_playing_track
	playlist.current_playing_track = track
	return playback
}

music_playback_update :: proc(playback: ^MusicPlayback) -> bool {
	ensure(playback.mixer_track != nil)
	playing := mixer.TrackPlaying(playback.mixer_track)
	if !playing do return true
	frame := mixer.GetTrackPlaybackPosition(playback.mixer_track)
	ensure(frame >= 0)
	elapsed_seconds :=
		f32(
			mixer.AudioFramesToMS(
				playback.mixer_audio,
				max(frame - playback.volume_frame_start, 0),
			),
		) /
		1000
	for playback.volume_point_next > 0 &&
	    int(playback.volume_point_next) < int(playback.volume_point_count) &&
	    elapsed_seconds >= playback.volume_points[playback.volume_point_next].at_seconds {
		playback.volume_point_next += 1
		if int(playback.volume_point_next) >= int(playback.volume_point_count) do break
		previous := playback.volume_points[playback.volume_point_next - 1]
		next := playback.volume_points[playback.volume_point_next]
		if next.volume > previous.volume && mixer.TrackPlaying(playback.mixer_track) {
			generated_track, ok := TRACKS[norm.path_nfc(playback.source_path)]
			log.ensuref(ok, "Missing generated track metadata for %s", playback.source_path)
			gain_multiplier := track_volume_multiplier(generated_track.active_rms)
			destination_gain := next.volume * gain_multiplier
			ensure(mixer.SetTrackGain(playback.mixer_track, destination_gain))
			props := sound_play_options(
				frame,
				mixer.AudioMSToFrames(
					playback.mixer_audio,
					i64(playback.bounds_end_seconds * 1000),
				),
				mixer.AudioMSToFrames(
					playback.mixer_audio,
					i64(max(next.at_seconds - elapsed_seconds, 0) * 1000),
				),
				math.clamp(previous.volume * gain_multiplier / destination_gain, 0, 1),
			)
			defer sdl.DestroyProperties(props)
			ensure(mixer.PlayTrack(playback.mixer_track, props))
		} else if next.volume == 0 && mixer.TrackPlaying(playback.mixer_track) {
			generated_track, ok := TRACKS[norm.path_nfc(playback.source_path)]
			log.ensuref(ok, "Missing generated track metadata for %s", playback.source_path)
			gain_multiplier := track_volume_multiplier(generated_track.active_rms)
			audible_volume := music_playback_volume_at(playback, frame)
			ensure(mixer.SetTrackGain(playback.mixer_track, audible_volume * gain_multiplier))
			ensure(
				mixer.StopTrack(
					playback.mixer_track,
					mixer.AudioMSToFrames(
						playback.mixer_audio,
						i64(max(next.at_seconds - elapsed_seconds, 0) * 1000),
					),
				),
			)
			playback.stopping = true
		}
	}
	ensure(playback.volume_point_count > 0)
	generated_track, ok := TRACKS[norm.path_nfc(playback.source_path)]
	log.ensuref(ok, "Missing generated track metadata for %s", playback.source_path)
	if playback.stopping {
		ensure(playback.volume_point_count >= 2)
		terminal_index := int(playback.volume_point_count) - 1
		ensure(playback.volume_points[terminal_index].volume == 0)
		gain :=
			playback.volume_points[terminal_index - 1].volume *
			track_volume_multiplier(generated_track.active_rms)
		if mixer.GetTrackGain(playback.mixer_track) != gain {
			ensure(mixer.SetTrackGain(playback.mixer_track, gain))
		}
	} else {
		destination_index := min(
			int(playback.volume_point_next),
			int(playback.volume_point_count) - 1,
		)
		gain :=
			playback.volume_points[destination_index].volume *
			track_volume_multiplier(generated_track.active_rms)
		if mixer.GetTrackGain(playback.mixer_track) != gain {
			ensure(mixer.SetTrackGain(playback.mixer_track, gain))
		}
	}
	return !mixer.TrackPlaying(playback.mixer_track)
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
	if track != nil do return track

	// Playlist exhausted: clear played flags so it can be replayed next time.
	for &current_track in playlist.tracks {
		current_track.played = false
	}
	sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	if !sound_settings.loop do return nil
	return playlist_pick_track_unplayed(playlist)
}

playlist_pick_specific_track :: proc(playlist: ^Playlist, track_name: cstring) -> ^Track {
	for &current_track in playlist.tracks {
		if current_track.title == string(track_name) {
			return &current_track
		}
	}

	panic(fmt.tprintf("Couldn't find track by name: %v", track_name))
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
		if current_track.played do continue
		fallback = &current_track
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
	played_track_paths := make(map[string]bool, context.temp_allocator)
	for &playlist in sound_settings.playlists {
		for &track in playlist.tracks {
			if track.played do played_track_paths[norm.path_nfc(track.path)] = true
		}
	}

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
		played_track_paths = played_track_paths,
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
	tracks_data_load()
	sound_settings = new(SoundSettings)
	sound_settings^ = sound_settings_load_from_disk()
	ensure(mixer.Init())
	sound_settings.mixer = mixer.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	ensure(sound_settings.mixer != nil)
	sound_settings.update_ticks = sdl.GetTicks()
	sound_settings.playlists = playlists_load()
	for &playlist in sound_settings.playlists {
		for &track in playlist.tracks {
			if _, ok := sound_settings.played_track_paths[norm.path_nfc(track.path)]; ok {
				track.played = true
			}
		}
	}
	for _, playlist_index in sound_settings.playlists {
		sound_settings.music_browser_playlist_index = i32(playlist_index)
		sound_settings.music_browser_track_index = i32(0)
		break
	}
	ensure(sound_settings.music_browser_playlist_index < i32(len(sound_settings.playlists)))
	return sound_settings
}

sound_update :: proc() {
	ticks := sdl.GetTicks()
	dt := f32(ticks - sound_settings.update_ticks) / 1000
	sound_settings.update_ticks = ticks

	sound_index := 0
	for sound_index < len(sound_settings.current_sounds) {
		voice := &sound_settings.current_sounds[sound_index]
		if !mixer.TrackPlaying(voice.mixer_track) {
			mixer.DestroyTrack(voice.mixer_track)
			mixer.DestroyAudio(voice.audio)
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

	music_playback_ended: [MUSIC_PLAYBACK_COUNT]bool
	primary := sound_settings.music_playback_primary
	for &playback, playback_index in sound_settings.music_playbacks {
		if playback.mixer_track == nil do continue
		music_playback_ended[playback_index] = music_playback_update(&playback)
	}

	successor_started := false
	if primary != nil &&
	   primary.mixer_track != nil &&
	   !primary.playlist_successor_started &&
	   !primary.stopping &&
	   (primary.volume_point_count == 1 ||
			   primary.volume_points[primary.volume_point_count - 1].volume != 0) {
		primary_ended := false
		for &playback, playback_index in sound_settings.music_playbacks {
			if &playback == primary {
				primary_ended = music_playback_ended[playback_index]
				break
			}
		}
		played :=
			f32(
				mixer.AudioFramesToMS(
					primary.mixer_audio,
					mixer.GetTrackPlaybackPosition(primary.mixer_track),
				),
			) /
			1000
		duration := primary.bounds_end_seconds - primary.bounds_start_seconds
		ensure(duration > 0)
		transition_needed := primary_ended
		if !transition_needed && duration > sound_settings.start_next_time {
			transition_needed =
				primary.bounds_end_seconds - played <= sound_settings.start_next_time
		}
		if transition_needed {
			primary.playlist_successor_started = true
			track := playlist_pick_random_track(primary.playlist)
			if track != nil {
				volume_endpoint := music_playback_volume_endpoint(primary)
				new_playback := music_playback_start_playlist_track(
					primary.playlist,
					track,
					volume_endpoint,
					sound_settings.fade_in_time,
				)
				for &playback, playback_index in sound_settings.music_playbacks {
					if &playback == new_playback {
						music_playback_ended[playback_index] = false
						break
					}
				}
				for &playback in sound_settings.music_playbacks {
					if playback.mixer_track == nil || &playback == new_playback do continue
					audible := music_playback_volume_at(
						&playback,
						mixer.GetTrackPlaybackPosition(playback.mixer_track),
					)
					if sound_settings.fade_out_time > 0 {
						music_playback_volume_set(
							&playback,
							{{0, audible}, {sound_settings.fade_out_time, 0}},
						)
					} else {
						ensure(mixer.StopTrack(playback.mixer_track, 0))
						playback.stopping = true
					}
				}
				successor_started = true
			}
		}
	}

	for &playback, playback_index in sound_settings.music_playbacks {
		if playback.mixer_track == nil || !music_playback_ended[playback_index] do continue
		if &playback == primary && successor_started {
			ensure(sound_settings.music_playback_primary != primary)
		}
		music_playback_stop(&playback)
	}
}

sound_hot_reloaded :: proc(settings: ^SoundSettings) {
	sound_settings = settings
}

sound_shutdown :: proc() {
	if sound_settings.settings_save_time_left > 0 do sound_settings_save()
	wave_editor_preview_stop()
	for &voice in sound_settings.current_sounds {
		if mixer.TrackPlaying(voice.mixer_track) do ensure(mixer.StopTrack(voice.mixer_track, 0))
		mixer.DestroyTrack(voice.mixer_track)
		mixer.DestroyAudio(voice.audio)
	}
	for &playback in sound_settings.music_playbacks do music_playback_stop(&playback)
	mixer.DestroyMixer(sound_settings.mixer)
	sound_settings.mixer = nil
	mixer.Quit()
}
