package game

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

MusicTrackBounds :: struct {
	file_hash:  string,
	start_time: f32,
	end_time:   f32,
}

SoundSettings :: struct {
	mixer:                        ^mixer.Mixer `json:"-"`,
	music_volume:                 f32 `json:"-"`,
	use_house_music:              bool,
	fade_in_time:                 f32,
	fade_out_time:                f32,
	start_next_time:              f32,
	shuffle:                      bool,
	loop:                         bool,
	normalize_volume:             bool,
	target_loudness:              f32,
	music_browser_playlist_index: i32 `json:"-"`,
	music_browser_track_index:    i32 `json:"-"`,
	settings_save_time_left:      f32 `json:"-"`,
	music_playbacks:              [MUSIC_PLAYBACK_COUNT]MusicPlayback `json:"-"`,
	pending_sounds:               PendingSounds `json:"-"`,
	is_sound_playing:             bool `json:"-"`,
	duck_gain:                    f32 `json:"-"`,
	wave_editor_preview:          WaveEditorPreview `json:"-"`,
	wave_editor_start_fraction:   f32 `json:"-"`,
	wave_editor_end_fraction:     f32 `json:"-"`,
}

MUSIC_PLAYBACK_COUNT :: 2

MusicPlayback :: struct {
	mixer_audio:                ^mixer.Audio,
	mixer_track:                ^mixer.Track,
	bounds_start_seconds:       f32,
	bounds_end_seconds:         f32,
	volume_points:              [ENVELOPE_KEYS_MAX]Envelope_Point,
	volume_point_count:         u8,
	volume_point_next:          u8,
	volume_frame_start:         i64,
	stopping:                   bool,
	playlist_successor_started: bool,
	entity:                     Entity_Handle,
}

Playlist :: struct {
	name:   string,
	tracks: [dynamic]Track,
}

Playlists :: [dynamic; 64]Playlist

Track :: struct {
	title: string,
	path:  string,
}

PathName :: string

SOUND_FADE_OUT_DURATION :: f32(2.0)
SOUND_REPLAY_FADE_THRESHOLD :: f32(4.0)
SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION :: f32(0.25)

MUSIC_DUCK_GAIN :: f32(0.2)
MUSIC_DUCK_SECONDS :: f32(0.2)

PendingSound :: struct {
	name:        SoundEffectName,
	volume:      f32,
	remaining_s: f32,
}

PendingSounds :: [dynamic; 8]PendingSound

TrackKeys :: [dynamic; 512]PathName

MUSIC_DIR :: "assets/sound/music"

TRACK_DATA_PATH :: "assets/sound/music.rms"
TRACK_DATA_MAGIC :: "RMST"
TRACK_DATA_VERSION :: 1

GeneratedTrack :: struct {
	file_hash:        string,
	active_rms:       f32,
	duration_seconds: f32,
	waveform_samples: []i8,
}

tracks_data_load :: proc() {
	if gm.tracks_data != nil do return

	ok: bool
	gm.tracks_data, ok = read_entire_file(TRACK_DATA_PATH)
	log.ensuref(ok, "Missing %s; run scripts/generate_enums.sh", TRACK_DATA_PATH)

	offset := 0
	read_bytes :: proc(offset: ^int, byte_count: int) -> []byte {
		ensure(len(gm.tracks_data) - offset^ >= byte_count)
		bytes := gm.tracks_data[offset^:offset^ + byte_count]
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

	gm.tracks = make(map[string]GeneratedTrack, track_count)
	for _ in 0 ..< track_count {
		path := read_string(&offset)
		file_hash := read_string(&offset)
		active_rms := read_f32(&offset)
		duration_seconds := read_f32(&offset)
		waveform := transmute([]i8)read_bytes(&offset, sample_count)
		gm.tracks[path] = GeneratedTrack {
			file_hash        = file_hash,
			active_rms       = active_rms,
			duration_seconds = duration_seconds,
			waveform_samples = waveform,
		}
	}
	ensure(offset == len(gm.tracks_data))
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
	duck_gain                = 1,
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
		mutex:               ^sync.Mutex,
	}

	playlists: Playlists
	track_keys: TrackKeys
	mutex: sync.Mutex

	for playlist_dir in potential_playlists {
		if playlist_dir.type != .Directory && playlist_dir.type != .Symlink do continue

		append(
			&playlists,
			Playlist {
				name = playlist_dir.name,
				tracks = make([dynamic]Track, context.temp_allocator),
			},
		)
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
					_, generated_track_ok := gm.tracks[norm.path_nfc(data.track_relative_path)]
					log.ensuref(
						generated_track_ok,
						"Missing generated track metadata for %s",
						data.track_relative_path,
					)

					track_key := PathName(data.track_relative_path)

					sync.guard(data.mutex)

					append(&data.track_keys^, track_key)

					track := Track {
						title = os.stem(data.track_name),
						path  = data.track_relative_path,
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
		_, generated_track_ok := gm.tracks[norm.path_nfc(string(track_key))]
		log.ensuref(generated_track_ok, "Missing generated track metadata for %s", track_key)
	}

	sound_playlist_entities_create(&playlists)

	return playlists
}

sound_playlist_entities_create :: proc(playlists: ^Playlists) {
	ensure(playlists != nil)
	for &playlist in playlists {
		playlist_handle := entity_playlist_create(playlist.name)
		for &track in playlist.tracks {
			track_handle := entity_track_create(track.path, track.title)
			track_entity := entity_must_get(track_handle)
			generated, ok := gm.tracks[norm.path_nfc(track.path)]
			log.ensuref(ok, "Missing generated track metadata for %s", track.path)
			track_entity.track.duration_s = generated.duration_seconds
			track_entity.track.file_hash = generated.file_hash
			track_entity.track.bounds_start_s = 0
			track_entity.track.bounds_end_s = generated.duration_seconds
			playlist_entity := entity_must_get(playlist_handle)
			append(&playlist_entity.playlist_tracks, track_handle)
		}
	}
}

track_bounds_set :: proc(path: string, bounds: MusicTrackBounds) {
	if handle := entity_track_handle_for_path(path); handle != ENTITY_HANDLE_NIL {
		entity := entity_must_get(handle)
		entity.track.file_hash = bounds.file_hash
		entity.track.bounds_start_s = bounds.start_time
		entity.track.bounds_end_s = bounds.end_time
	}
}

track_bounds_delete :: proc(path: string) {
	if handle := entity_track_handle_for_path(path); handle != ENTITY_HANDLE_NIL {
		entity := entity_must_get(handle)
		entity.track.file_hash = ""
		entity.track.bounds_start_s = 0
		entity.track.bounds_end_s = entity.track.duration_s
	}
}

music_entity_alloc :: proc() -> ^Entity {
	for handle in gm.entities.music {
		entity, ok := entity_get(handle)
		if ok && entity.music.playback == nil do return entity
	}
	return entity_must_get(entity_create({.Music}, ""))
}

music_playback_track :: proc(playback: ^MusicPlayback) -> ^Entity_Track {
	entity, ok := entity_get(playback.entity)
	ensure(ok)
	track_entity := entity_must_get(entity.music.track)
	return &track_entity.track
}

music_primary_playback :: proc() -> (^MusicPlayback, bool) {
	entity, ok := entity_get(gm.music_primary)
	if !ok || entity.music.playback == nil do return nil, false
	return entity.music.playback, true
}

track_volume_multiplier :: proc(active_rms: f32) -> f32 {
	if !gm.sound_settings.normalize_volume || active_rms <= 0 do return 1

	target_db := math.clamp(
		gm.sound_settings.target_loudness,
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

voice_track_teardown :: proc(track: ^mixer.Track, audio: ^mixer.Audio) {
	if mixer.TrackPlaying(track) do ensure(mixer.StopTrack(track, 0))
	mixer.DestroyTrack(track)
	mixer.DestroyAudio(audio)
}

sound_play :: proc(name: SoundEffectName, volume: f32, delay_s: f32 = 0) -> ^mixer.Track {
	if delay_s > 0 {
		append(
			&gm.sound_settings.pending_sounds,
			PendingSound{name = name, volume = volume, remaining_s = delay_s},
		)
		return nil
	}

	for handle in gm.entities.sound {
		voice, ok := entity_get(handle)
		ensure(ok)
		if !sound_retrigger_fade_needed(voice.sound.name, name, mixer.TrackPlaying(voice.sound.mixer_track), voice.sound.duration_s) do continue
		if !voice.sound.fading {
			voice.sound.fading = true
			ensure(
				mixer.StopTrack(
					voice.sound.mixer_track,
					mixer.TrackMSToFrames(
						voice.sound.mixer_track,
						i64(SOUND_FADE_OUT_DURATION * 1000),
					),
				),
			)
		}
		return voice.sound.mixer_track
	}

	path := strings.clone_to_cstring(sound_effect_path(name), context.temp_allocator)
	audio := mixer.LoadAudio(gm.sound_settings.mixer, path, true)
	ensure(audio != nil, fmt.tprintf("Couldn't load sound: %s", path))
	track := mixer.CreateTrack(gm.sound_settings.mixer)
	ensure(track != nil)
	ensure(mixer.SetTrackAudio(track, audio))
	duration_frames := mixer.GetAudioDuration(audio)
	ensure(duration_frames > 0)

	handle := entity_create({.Sound}, "")
	voice := entity_must_get(handle)
	voice.sound = {
		mixer_audio = audio,
		mixer_track = track,
		name        = name,
		volume      = volume,
		duration_s  = f32(mixer.AudioFramesToMS(audio, duration_frames)) / 1000,
	}
	ensure(mixer.SetTrackGain(track, voice.sound.volume))
	ensure(mixer.PlayTrack(track, 0))
	gm.sound_settings.is_sound_playing = true

	return track
}

playlist_is_current :: proc(playlist_name: PlaylistName) -> bool {
	entity, ok := entity_get(gm.music_primary)
	if !ok || entity.music.playlist == ENTITY_HANDLE_NIL do return false
	return entity_must_get(entity.music.playlist).label == playlist_name_string(playlist_name)
}

playlist_is_house :: proc() -> bool {
	entity, ok := entity_get(gm.music_primary)
	if !ok || entity.music.playlist == ENTITY_HANDLE_NIL do return false
	return strings.has_prefix(entity_must_get(entity.music.playlist).label, "Kids on Bikes (80s)")
}

track_is_current :: proc(track_name: cstring) -> bool {
	entity, ok := entity_get(gm.music_primary)
	if !ok || entity.music.track == ENTITY_HANDLE_NIL do return false
	return entity_must_get(entity.music.track).track.title == string(track_name)
}

sound_settings_load_from_disk :: proc() -> SoundSettings {
	settings := DefaultSoundSettings
	settings_load(&settings)
	return settings
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
	return envelope_value_at(
		playback.volume_points[:int(playback.volume_point_count)],
		elapsed_seconds,
	)
}

music_playback_volume_endpoint :: proc(playback: ^MusicPlayback) -> f32 {
	ensure(playback != nil && playback.volume_point_count > 0)
	for point_index := int(playback.volume_point_count) - 1; point_index >= 0; point_index -= 1 {
		if playback.volume_points[point_index].value != 0 {
			return playback.volume_points[point_index].value
		}
	}
	return 0
}

music_playback_volume_set :: proc(playback: ^MusicPlayback, points: []Envelope_Point) {
	ensure(playback != nil && playback.mixer_track != nil)
	ensure(len(points) > 0 && len(points) <= len(playback.volume_points))
	ensure(points[0].at_seconds == 0)
	for point, point_index in points {
		ensure(point.at_seconds >= 0 && point.value >= 0)
		if point.value == 0 do ensure(point_index == 0 || point_index == len(points) - 1)
		if point_index > 0 {
			previous := points[point_index - 1]
			ensure(point.at_seconds > previous.at_seconds)
			if point.value != 0 do ensure(point.value >= previous.value)
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

	generated_track, ok := gm.tracks[norm.path_nfc(music_playback_track(playback).path)]
	log.ensuref(ok, "Missing generated track metadata for %s", music_playback_track(playback).path)
	gain_multiplier := track_volume_multiplier(generated_track.active_rms)

	first := points[0]
	if len(points) == 1 {
		ensure(
			mixer.SetTrackGain(
				playback.mixer_track,
				first.value * gain_multiplier * gm.sound_settings.duck_gain,
			),
		)
		return
	}

	second := points[1]
	if second.value > first.value {
		destination_volume := second.value * gain_multiplier
		start_fraction := f32(0)
		if destination_volume > 0 do start_fraction = math.clamp(audible_volume * gain_multiplier / destination_volume, 0, 1)
		ensure(
			mixer.SetTrackGain(
				playback.mixer_track,
				destination_volume * gm.sound_settings.duck_gain,
			),
		)
		props := sound_play_options(
			frame,
			mixer.AudioMSToFrames(playback.mixer_audio, i64(playback.bounds_end_seconds * 1000)),
			mixer.AudioMSToFrames(playback.mixer_audio, i64(second.at_seconds * 1000)),
			start_fraction,
		)
		defer sdl.DestroyProperties(props)
		ensure(mixer.PlayTrack(playback.mixer_track, props))
	} else if second.value == 0 {
		ensure(
			mixer.SetTrackGain(
				playback.mixer_track,
				audible_volume * gain_multiplier * gm.sound_settings.duck_gain,
			),
		)
		ensure(
			mixer.StopTrack(
				playback.mixer_track,
				mixer.AudioMSToFrames(playback.mixer_audio, i64(second.at_seconds * 1000)),
			),
		)
		playback.stopping = true
	} else {
		ensure(second.value == first.value)
	}
}

music_playback_alloc :: proc() -> ^MusicPlayback {
	for &candidate in gm.sound_settings.music_playbacks {
		if candidate.mixer_track == nil do return &candidate
	}
	for &candidate in gm.sound_settings.music_playbacks {
		if candidate.stopping {
			music_playback_stop(&candidate)
			return &candidate
		}
	}
	ensure(false, "Must find available music playback")
	return nil
}

// Validates the track's bounds against its generated metadata and stores the
// canonical result on the entity. Bounds without a hash are the full range; a
// changed hash resets to the full range and reports stale.
music_track_bounds_resolve_entity :: proc(
	track: ^Entity_Track,
	generated: GeneratedTrack,
) -> (
	bounds: MusicTrackBounds,
	stale: bool,
) {
	duration := generated.duration_seconds
	ensure(duration > 0 && !math.is_nan(duration) && !math.is_inf(duration, 0))
	stale = track.file_hash != "" && track.file_hash != generated.file_hash
	if track.file_hash == "" || stale {
		track.file_hash = ""
		track.bounds_start_s = 0
		track.bounds_end_s = duration
		return MusicTrackBounds {
				file_hash = generated.file_hash,
				start_time = 0,
				end_time = duration,
			},
			stale
	}
	ensure(!math.is_nan(track.bounds_start_s) && !math.is_inf(track.bounds_start_s, 0))
	ensure(!math.is_nan(track.bounds_end_s) && !math.is_inf(track.bounds_end_s, 0))
	ensure(track.bounds_end_s <= duration + 0.1)
	bounds_end := min(track.bounds_end_s, duration)
	ensure(track.bounds_start_s >= 0 && track.bounds_start_s < bounds_end)
	track.bounds_end_s = bounds_end
	return MusicTrackBounds {
			file_hash = track.file_hash,
			start_time = track.bounds_start_s,
			end_time = track.bounds_end_s,
		},
		false
}

music_playback_start :: proc(
	music: ^Entity,
	volume_endpoint: f32,
	fade_seconds: f32,
) -> ^MusicPlayback {
	track := &entity_must_get(music.music.track).track
	playback := music_playback_alloc()
	audio := mixer.LoadAudio(
		gm.sound_settings.mixer,
		strings.clone_to_cstring(track.path, context.temp_allocator),
		false,
	)
	ensure(audio != nil, fmt.tprintf("Couldn't load music: %s", track.path))
	mixer_track := mixer.CreateTrack(gm.sound_settings.mixer)
	ensure(mixer_track != nil)
	ensure(mixer.SetTrackAudio(mixer_track, audio))

	generated_track, generated_track_ok := gm.tracks[norm.path_nfc(track.path)]
	ensure(generated_track_ok, fmt.tprintf("Missing generated track metadata: %s", track.path))
	bounds, stale := music_track_bounds_resolve_entity(track, generated_track)
	if stale {
		log.warnf("Ignoring bounds for changed track: %s", track.path)
		gm.sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}
	stream_length := f32(mixer.AudioFramesToMS(audio, mixer.GetAudioDuration(audio))) / 1000
	ensure(stream_length > 0)
	bounds.end_time = min(bounds.end_time, stream_length)
	ensure(bounds.start_time < bounds.end_time)

	playback^ = MusicPlayback {
		mixer_audio          = audio,
		mixer_track          = mixer_track,
		bounds_start_seconds = bounds.start_time,
		bounds_end_seconds   = bounds.end_time,
		entity               = music.handle,
	}
	music.music.playback = playback
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

// Destroying the owning .Music entity tears the playback down.
music_playback_stop :: proc(playback: ^MusicPlayback) {
	if playback.mixer_track == nil do return
	entity_destroy(playback.entity)
	ensure(playback.mixer_track == nil)
}

sound_music_current_volume :: proc() -> f32 {
	volume_current := f32(0)
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil || !mixer.TrackPlaying(playback.mixer_track) do continue
		track := music_playback_track(&playback)
		generated_track, ok := gm.tracks[norm.path_nfc(track.path)]
		log.ensuref(ok, "Missing generated track metadata for %s", track.path)
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
	primary, ok := music_primary_playback()
	if !ok do return
	track := music_playback_track(primary)
	generated_track, generated_ok := gm.tracks[norm.path_nfc(track.path)]
	log.ensuref(generated_ok, "Missing generated track metadata for %s", track.path)
	current :=
		music_playback_volume_at(primary, mixer.GetTrackPlaybackPosition(primary.mixer_track)) *
		track_volume_multiplier(generated_track.active_rms)
	gm.sound_settings.music_volume = math.clamp(current + delta, 0, 1)
	music_playback_volume_set(primary, {{0, gm.sound_settings.music_volume}})
}

music_current_label :: proc() -> string {
	entity, ok := entity_get(gm.music_primary)
	if !ok do return "No music playing"
	playlist := entity_must_get(entity.music.playlist)
	track := entity_must_get(entity.music.track)
	return fmt.tprintf("%s - %s", playlist.label, track.track.title)
}

music_current_progress :: proc() -> f32 {
	played, length := music_current_time()
	if length <= 0 do return 0
	return math.clamp(played / length, 0, 1)
}

music_current_time :: proc() -> (played, length: f32) {
	playback, ok := music_primary_playback()
	if !ok do return 0, 0
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
	playlist: Entity_Handle,
	track: Entity_Handle,
	volume_endpoint: f32,
	fade_seconds: f32,
) -> ^MusicPlayback {
	music := music_entity_alloc()
	music.music.playlist = playlist
	music.music.track = track
	playback := music_playback_start(music, volume_endpoint, fade_seconds)
	ensure(playback != nil)

	gm.music_primary = music.handle
	entity_must_get(track).track.played = true
	gm.sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	entity_must_get(playlist).playlist_last_played = track
	return playback
}

// Fade every playback except one from its audible level to silence. A nil
// exception fades everything.
music_playbacks_fade_others :: proc(except: ^MusicPlayback, fade_out_s: f32) {
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil || &playback == except do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {fade_out_s, 0}})
	}
}

music_playbacks_fade_all :: proc(fade_out_s: f32) {
	music_playbacks_fade_others(nil, fade_out_s)
}

// Start a track and fade everything else out. Callers pass the outgoing
// fade explicitly because show cues use fixed stings (2s, 0.3s) while
// ordinary transitions use the fade_out_time setting.
music_crossfade :: proc(
	playlist: Entity_Handle,
	track: Entity_Handle,
	volume_endpoint, fade_in_s, fade_out_s: f32,
) -> ^MusicPlayback {
	new_playback := music_playback_start_playlist_track(
		playlist,
		track,
		volume_endpoint,
		fade_in_s,
	)
	music_playbacks_fade_others(new_playback, fade_out_s)
	return new_playback
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
		if next.value > previous.value && mixer.TrackPlaying(playback.mixer_track) {
			generated_track, ok := gm.tracks[norm.path_nfc(music_playback_track(playback).path)]
			log.ensuref(
				ok,
				"Missing generated track metadata for %s",
				music_playback_track(playback).path,
			)
			gain_multiplier := track_volume_multiplier(generated_track.active_rms)
			destination_volume := next.value * gain_multiplier
			destination_gain := destination_volume * gm.sound_settings.duck_gain
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
				math.clamp(previous.value * gain_multiplier / destination_volume, 0, 1),
			)
			defer sdl.DestroyProperties(props)
			ensure(mixer.PlayTrack(playback.mixer_track, props))
		} else if next.value == 0 && mixer.TrackPlaying(playback.mixer_track) {
			generated_track, ok := gm.tracks[norm.path_nfc(music_playback_track(playback).path)]
			log.ensuref(
				ok,
				"Missing generated track metadata for %s",
				music_playback_track(playback).path,
			)
			gain_multiplier := track_volume_multiplier(generated_track.active_rms)
			audible_volume := music_playback_volume_at(playback, frame)
			ensure(
				mixer.SetTrackGain(
					playback.mixer_track,
					audible_volume * gain_multiplier * gm.sound_settings.duck_gain,
				),
			)
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
	generated_track, ok := gm.tracks[norm.path_nfc(music_playback_track(playback).path)]
	log.ensuref(ok, "Missing generated track metadata for %s", music_playback_track(playback).path)
	if playback.stopping {
		ensure(playback.volume_point_count >= 2)
		terminal_index := int(playback.volume_point_count) - 1
		ensure(playback.volume_points[terminal_index].value == 0)
		gain :=
			playback.volume_points[terminal_index - 1].value *
			track_volume_multiplier(generated_track.active_rms) *
			gm.sound_settings.duck_gain
		if mixer.GetTrackGain(playback.mixer_track) != gain {
			ensure(mixer.SetTrackGain(playback.mixer_track, gain))
		}
	} else {
		destination_index := min(
			int(playback.volume_point_next),
			int(playback.volume_point_count) - 1,
		)
		gain :=
			playback.volume_points[destination_index].value *
			track_volume_multiplier(generated_track.active_rms) *
			gm.sound_settings.duck_gain
		if mixer.GetTrackGain(playback.mixer_track) != gain {
			ensure(mixer.SetTrackGain(playback.mixer_track, gain))
		}
	}
	return !mixer.TrackPlaying(playback.mixer_track)
}

playlist_find_by_name :: proc(playlist_name: PlaylistName) -> Entity_Handle {
	return playlist_find_by_label(playlist_name_string(playlist_name))
}

playlist_find_by_label :: proc(label: string) -> Entity_Handle {
	handle := entity_playlist_handle_for_label(label)
	if handle == ENTITY_HANDLE_NIL do log.warnf("Couldn't find playlist, skipping: %s", label)
	return handle
}

playlist_pick_random_track :: proc(playlist: Entity_Handle) -> Entity_Handle {
	track := playlist_pick_track_unplayed(playlist)
	if track != ENTITY_HANDLE_NIL do return track

	// Playlist exhausted: clear played flags so it can be replayed next time.
	playlist_entity := entity_must_get(playlist)
	for track_handle in playlist_entity.playlist_tracks {
		entity_must_get(track_handle).track.played = false
	}
	gm.sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	if !gm.sound_settings.loop do return ENTITY_HANDLE_NIL
	return playlist_pick_track_unplayed(playlist)
}

playlist_pick_specific_track :: proc(
	playlist: Entity_Handle,
	track_name: cstring,
) -> Entity_Handle {
	playlist_entity := entity_must_get(playlist)
	for track_handle in playlist_entity.playlist_tracks {
		if entity_must_get(track_handle).track.title == string(track_name) {
			return track_handle
		}
	}

	panic(fmt.tprintf("Couldn't find track by name: %v", track_name))
}

playlist_pick_track_unplayed :: proc(playlist: Entity_Handle) -> Entity_Handle {
	playlist_entity := entity_must_get(playlist)
	if !gm.sound_settings.shuffle {
		fallback := ENTITY_HANDLE_NIL
		for track_handle in playlist_entity.playlist_tracks {
			if entity_must_get(track_handle).track.played do continue
			if fallback == ENTITY_HANDLE_NIL do fallback = track_handle
			if playlist_entity.playlist_last_played == track_handle do continue
			return track_handle
		}
		return fallback
	}

	track := ENTITY_HANDLE_NIL
	fallback := ENTITY_HANDLE_NIL
	unplayed_seen := 0
	for track_handle in playlist_entity.playlist_tracks {
		if entity_must_get(track_handle).track.played do continue
		fallback = track_handle
		unplayed_seen += 1
		if rand.int_max(unplayed_seen) == 0 &&
		   playlist_entity.playlist_last_played != track_handle {
			track = track_handle
		}
	}
	if track == ENTITY_HANDLE_NIL do track = fallback
	return track
}

sound_settings_init :: proc() -> ^SoundSettings {
	tracks_data_load()
	settings := new(SoundSettings)
	settings^ = sound_settings_load_from_disk()
	ensure(mixer.Init())
	settings.mixer = mixer.CreateMixerDevice(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
	ensure(settings.mixer != nil)
	playlists := playlists_load()
	track_settings_load(settings)
	if len(playlists) > 0 {
		settings.music_browser_playlist_index = 0
		settings.music_browser_track_index = 0
	}
	ensure(settings.music_browser_playlist_index < i32(len(gm.entities.playlist)))
	return settings
}

// Hydrates track entities from the persisted played paths and bounds. Loaded
// data stays in temp memory; entities clone what they keep.
track_settings_load :: proc(settings: ^SoundSettings) {
	persisted: App_Settings
	settings_load(&persisted, context.temp_allocator)
	for handle in gm.entities.track {
		entity := entity_must_get(handle)
		path := norm.path_nfc(entity.track.path)
		if persisted.played_track_paths[path] {
			entity.track.played = true
		}
		bounds, ok := persisted.music_track_bounds[path]
		if !ok do continue
		delete_key(&persisted.music_track_bounds, path)
		entity.track.file_hash = strings.clone(bounds.file_hash)
		entity.track.bounds_start_s = bounds.start_time
		entity.track.bounds_end_s = bounds.end_time
		generated, generated_ok := gm.tracks[path]
		log.ensuref(generated_ok, "Missing generated track metadata for %s", path)
		if _, stale := music_track_bounds_resolve_entity(&entity.track, generated); stale {
			log.warnf("Ignoring bounds for changed track: %s", path)
			settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
		}
	}
	// Bounds of tracks missing from disk stay on dormant track entities, outside
	// every playlist, so saving keeps them until the file returns.
	for path, bounds in persisted.music_track_bounds {
		entity := entity_must_get(entity_track_create(path, os.stem(path)))
		entity.track.file_hash = strings.clone(bounds.file_hash)
		entity.track.bounds_start_s = bounds.start_time
		entity.track.bounds_end_s = bounds.end_time
	}
}

// Next duck gain multiplier for the given soonest-ending sound effect.
// While a sound effect plays, music ducks to MUSIC_DUCK_GAIN, ramping down
// over MUSIC_DUCK_SECONDS; the return starts in the last MUSIC_DUCK_SECONDS
// of the effect. The return ramp samples the shared envelope, so duck
// gain stays the same lerp as music gain and lighting weight.
sound_duck_gain_next :: proc(current_gain, remaining_min_s, dt: f32) -> f32 {
	if remaining_min_s > MUSIC_DUCK_SECONDS {
		return max(MUSIC_DUCK_GAIN, current_gain - dt * (1 - MUSIC_DUCK_GAIN) / MUSIC_DUCK_SECONDS)
	} else if remaining_min_s > 0 {
		keys := [2]Envelope_Point{{0, 1}, {MUSIC_DUCK_SECONDS, MUSIC_DUCK_GAIN}}
		return min(1, envelope_value_at(keys[:], remaining_min_s))
	}
	return 1
}

sound_update :: proc(dt: f32) {
	sound_section_update(dt)
	music_section_update()
}

// Sound voices tick here, inside the frame traversal's sound section.
// Finished voices tear down their mixer objects and leave the store.
sound_section_update :: proc(dt: f32) {
	profiler_scope(#procedure)
	pending_index := 0
	for pending_index < len(gm.sound_settings.pending_sounds) {
		pending := &gm.sound_settings.pending_sounds[pending_index]
		if !countdown_tick(&pending.remaining_s, dt) {
			pending_index += 1
			continue
		}
		sound_play(pending.name, pending.volume)
		unordered_remove(&gm.sound_settings.pending_sounds, pending_index)
	}

	sound_index := 0
	for sound_index < len(gm.entities.sound) {
		handle := gm.entities.sound[sound_index]
		voice, ok := entity_get(handle)
		ensure(ok)
		if !mixer.TrackPlaying(voice.sound.mixer_track) {
			voice_track_teardown(voice.sound.mixer_track, voice.sound.mixer_audio)
			entity_destroy(handle)
			continue
		}
		sound_index += 1
	}
	gm.sound_settings.is_sound_playing = len(gm.entities.sound) > 0

	remaining_min := f32(0)
	for handle in gm.entities.sound {
		voice, ok := entity_get(handle)
		ensure(ok)
		if voice.sound.fading do continue
		elapsed :=
			f32(
				mixer.AudioFramesToMS(
					voice.sound.mixer_audio,
					mixer.GetTrackPlaybackPosition(voice.sound.mixer_track),
				),
			) /
			1000
		remaining := max(voice.sound.duration_s - elapsed, 0)
		if remaining_min == 0 || remaining < remaining_min do remaining_min = remaining
	}
	gm.sound_settings.duck_gain = sound_duck_gain_next(
		gm.sound_settings.duck_gain,
		remaining_min,
		dt,
	)

	if gm.sound_settings.settings_save_time_left > 0 &&
	   countdown_tick(&gm.sound_settings.settings_save_time_left, dt) {
		settings_save()
	}
}

// The music crossfade engine runs here, inside the frame traversal's music
// section. Each .Music entity owns its selection and points at a playback.
music_section_update :: proc() {
	profiler_scope(#procedure)
	music_playback_ended: [MUSIC_PLAYBACK_COUNT]bool
	primary, primary_ok := music_primary_playback()
	for &playback, playback_index in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil do continue
		music_playback_ended[playback_index] = music_playback_update(&playback)
	}

	if primary_ok &&
	   primary.mixer_track != nil &&
	   !primary.playlist_successor_started &&
	   !primary.stopping &&
	   (primary.volume_point_count == 1 ||
			   primary.volume_points[primary.volume_point_count - 1].value != 0) {
		primary_ended := false
		for &playback, playback_index in gm.sound_settings.music_playbacks {
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
		if !transition_needed && duration > gm.sound_settings.start_next_time {
			transition_needed =
				primary.bounds_end_seconds - played <= gm.sound_settings.start_next_time
		}
		if transition_needed {
			primary.playlist_successor_started = true
			primary_entity, ok := entity_get(primary.entity)
			ensure(ok)
			track := playlist_pick_random_track(primary_entity.music.playlist)
			if track != ENTITY_HANDLE_NIL {
				volume_endpoint := music_playback_volume_endpoint(primary)
				new_playback := music_playback_start_playlist_track(
					primary_entity.music.playlist,
					track,
					volume_endpoint,
					gm.sound_settings.fade_in_time,
				)
				for &playback, playback_index in gm.sound_settings.music_playbacks {
					if &playback == new_playback {
						music_playback_ended[playback_index] = false
						break
					}
				}
				if gm.sound_settings.fade_out_time > 0 {
					music_playbacks_fade_others(new_playback, gm.sound_settings.fade_out_time)
				} else {
					for &playback in gm.sound_settings.music_playbacks {
						if playback.mixer_track == nil || &playback == new_playback do continue
						ensure(mixer.StopTrack(playback.mixer_track, 0))
						playback.stopping = true
					}
				}
			}
		}
	}

	for &playback, playback_index in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil || !music_playback_ended[playback_index] do continue
		music_playback_stop(&playback)
	}
}

sound_shutdown :: proc() {
	if gm.sound_settings.settings_save_time_left > 0 do settings_save()
	wave_editor_preview_stop()
	for handle in gm.entities.sound {
		voice, ok := entity_get(handle)
		ensure(ok)
		voice_track_teardown(voice.sound.mixer_track, voice.sound.mixer_audio)
	}
	entity_domain_clear(&gm.entities.sound)
	for &playback in gm.sound_settings.music_playbacks do music_playback_stop(&playback)
	mixer.DestroyMixer(gm.sound_settings.mixer)
	gm.sound_settings.mixer = nil
	mixer.Quit()
}
