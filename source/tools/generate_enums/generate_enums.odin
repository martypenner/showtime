package generate_enums

import "core:c"
import "core:encoding/json"
import "core:fmt"
import norm "../../path_normalize"
import "core:hash/xxhash"
import "core:io"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

MUSIC_DIR :: "assets/sounds/music"
FX_DIR :: "assets/sounds/fx"
LAYOUT_DIR :: "resources"
WEB_OUT_FILE :: "source/generated_enums_js.odin"
OUT_DATA_FILE :: "assets/sounds/music.rms"
CACHE_FILE :: "source/generated_playlists.rms_cache.sjson"

TRACK_DATA_MAGIC :: string("RMST")
TRACK_DATA_VERSION :: 1

Playlist :: struct {
	ident: string,
	name:  string,
}

SoundEffect :: struct {
	ident: string,
	path:  string,
}

GeneratedTrack :: struct {
	path:             string,
	file_hash:        FileHash,
	active_rms:       f32,
	duration_seconds: f32,
	waveform_samples: [TRACK_WAVEFORM_SAMPLE_COUNT]i8,
}

RMSCache :: struct {
	version:                   int,
	waveform_sample_count:     int,
	active_sample_gate:        f32,
	active_rms_window_seconds: f64,
	min_active_rms_seconds:    f64,
	tracks:                    map[string]RMSCacheEntry,
}

RMSCacheEntry :: struct {
	file_hash:        FileHash,
	active_rms:       f32,
	duration_seconds: f32,
	waveform_samples: [TRACK_WAVEFORM_SAMPLE_COUNT]i8,
}

FileHash :: distinct xxhash.XXH3_128_hash

MUSIC_ACTIVE_SAMPLE_GATE :: f32(0.02)
MUSIC_ACTIVE_RMS_WINDOW_SECONDS :: f64(0.05)
MUSIC_MIN_ACTIVE_RMS_SECONDS :: f64(0.5)
TRACK_WAVEFORM_SAMPLE_COUNT :: 1024
TRACK_ANALYSIS_THREAD_COUNT :: 2

main :: proc() {
	ensure(mixer.Init(), string(sdl.GetError()))
	defer mixer.Quit()

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	thread_allocator := mem.dynamic_arena_allocator(&scratch)
	context.allocator = thread_allocator

	rms_cache := load_rms_cache()
	defer delete(rms_cache.tracks)

	mutex: sync.Mutex
	failed := false

	entries, err := os.read_all_directory_by_path(MUSIC_DIR, context.allocator)
	if err != nil {
		fmt.eprintf("Error reading %s: %v\n", MUSIC_DIR, err)
		os.exit(1)
	}

	playlists: [dynamic]Playlist
	sound_effects := load_sound_effects()
	tracks: [dynamic]GeneratedTrack

	pool: thread.Pool
	thread.pool_init(
		&pool,
		thread_allocator,
		min(os.get_processor_core_count(), TRACK_ANALYSIS_THREAD_COUNT),
	)
	defer thread.pool_destroy(&pool)

	PoolData :: struct {
		path:      string,
		rms_cache: RMSCache,
		tracks:    ^[dynamic]GeneratedTrack,
		mutex:     ^sync.Mutex,
		failed:    ^bool,
	}

	for entry in entries {
		if entry.type != .Directory && entry.type != .Symlink do continue
		if len(entry.name) > 0 && entry.name[0] == '.' do continue

		ident := playlist_ident(entry.name, context.allocator)
		ensure(len(ident) > 0)

		base := ident
		suffix := 2
		for playlist_ident_used(playlists[:], ident) {
			ident = strings.clone(fmt.aprintf("%s_%d", base, suffix))
			suffix += 1
		}

		append(&playlists, Playlist{ident = ident, name = strings.clone(entry.name)})

		track_entries, tracks_err := os.read_all_directory_by_path(
			entry.fullpath,
			context.temp_allocator,
		)
		if tracks_err != nil {
			fmt.eprintf("Error reading tracks in %s: %v\n", entry.fullpath, tracks_err)
			os.exit(1)
		}
		for track_entry in track_entries {
			if track_entry.type != .Regular && track_entry.type != .Symlink do continue
			if !track_file_supported(track_entry.name) do continue

			path := fmt.aprintf("%s/%s/%s", MUSIC_DIR, entry.name, track_entry.name)
			data := new(PoolData)
			data^ = PoolData {
				path      = path,
				rms_cache = rms_cache,
				tracks    = &tracks,
				mutex     = &mutex,
				failed    = &failed,
			}
			thread.pool_add_task(&pool, context.allocator, proc(t: thread.Task) {
					data := (^PoolData)(t.data)

					file, open_err := os.open(data.path)
					if open_err != nil {
						fmt.eprintf("Error reading track %s: %v\n", data.path, open_err)
						sync.guard(data.mutex)
						data.failed^ = true
						return
					}

					state: xxhash.XXH3_state
					xxhash.XXH3_128_reset(&state)
					buf: [256]byte
					for {
						n, err := io.read(os.to_stream(file), buf[:])
						if n > 0 {xxhash.XXH3_128_update(&state, buf[:n])}
						if err == .EOF {break}
						if err != .None {
							fmt.eprintf("Error reading track %s: %v\n", data.path, err)
							sync.guard(data.mutex)
							data.failed^ = true
							return
						}
					}
					os.close(file)

					digest := xxhash.XXH3_128_digest(&state)
					cache_entry := track_cache_entry_resolve(
						data.path,
						FileHash(digest),
						data.rms_cache,
					)
					track := GeneratedTrack {
						path             = data.path,
						file_hash        = FileHash(digest),
						active_rms       = cache_entry.active_rms,
						duration_seconds = cache_entry.duration_seconds,
						waveform_samples = cache_entry.waveform_samples,
					}

					sync.guard(data.mutex)
					append(data.tracks, track)

					free_all(context.temp_allocator)
				}, data)
		}
	}

	{
		context.allocator = thread_allocator
		thread.pool_start(&pool)
		thread.pool_finish(&pool)
		if failed do os.exit(1)
	}

	slice.sort_by(playlists[:], proc(a, b: Playlist) -> bool {
		return strings.compare(a.name, b.name) < 0
	})
	slice.sort_by(tracks[:], proc(a, b: GeneratedTrack) -> bool {
		return strings.compare(a.path, b.path) < 0
	})

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "#+feature dynamic-literals")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "package game")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "// Generated from assets/sounds/music and assets/sounds/fx by")
	fmt.sbprintln(&builder, "// source/tools/generate_enums. Do not edit by hand.")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "PlaylistName :: enum {")
	for playlist in playlists {
		fmt.sbprintf(&builder, "\t%s,\n", playlist.ident)
	}
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "SoundEffectName :: enum {")
	for sound_effect in sound_effects {
		fmt.sbprintf(&builder, "\t%s,\n", sound_effect.ident)
	}
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "playlist_name_string :: proc(name: PlaylistName) -> string {")
	fmt.sbprintln(&builder, "\tswitch name {")
	for playlist in playlists {
		fmt.sbprintf(&builder, "\tcase .%s: return %q\n", playlist.ident, playlist.name)
	}
	fmt.sbprintln(&builder, "\tcase: return \"\"")
	fmt.sbprintln(&builder, "\t}")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "sound_effect_path :: proc(name: SoundEffectName) -> string {")
	fmt.sbprintln(&builder, "\tswitch name {")
	for sound_effect in sound_effects {
		fmt.sbprintf(
			&builder,
			"\tcase .%s:\n\t\treturn %q\n",
			sound_effect.ident,
			sound_effect.path,
		)
	}
	fmt.sbprintln(&builder, "\tcase: return \"\"")
	fmt.sbprintln(&builder, "\t}")
	fmt.sbprintln(&builder, "}")

	enum_file_write(enum_file_name(ODIN_OS_STRING), strings.to_string(builder))
	if ODIN_OS_STRING != "js" {
		enum_file_write(WEB_OUT_FILE, strings.to_string(builder))
	}

	track_data_write(tracks[:])

	save_rms_cache(tracks[:])
}

enum_file_name :: proc(os_name: string) -> string {
	return fmt.aprintf("source/generated_enums_%s.odin", os_name)
}

enum_file_write :: proc(path: string, contents: string) {
	write_err := os.write_entire_file(path, contents)
	if write_err != nil {
		fmt.eprintf("Error writing %s: %v\n", path, write_err)
		os.exit(1)
	}
}

// Writes track metadata + waveforms as a binary blob consumed by
// tracks_data_load in source/sound.odin. Keeping this data out of compiled Odin
// source keeps build times down.
track_data_write :: proc(tracks: []GeneratedTrack) {
	file, open_err := os.open(OUT_DATA_FILE, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if open_err != os.ERROR_NONE {
		fmt.eprintf("Error opening %s: %v\n", OUT_DATA_FILE, open_err)
		os.exit(1)
	}
	defer os.close(file)
	w := os.to_stream(file)

	// Scalar fields and length prefixes go through the caller-owned writer;
	// strings and waveforms are written as zero-copy views.
	value_write :: proc(w: io.Writer, value: u32) {
		value_bytes := transmute([4]byte)value
		_, write_err := io.write_full(w, value_bytes[:])
		if write_err != nil {
			fmt.eprintf("Error writing %s: %v\n", OUT_DATA_FILE, write_err)
			os.exit(1)
		}
	}
	string_write :: proc(w: io.Writer, value: string) {
		value_write(w, u32(len(value)))
		_, write_err := io.write_full(w, transmute([]byte)value)
		if write_err != nil {
			fmt.eprintf("Error writing %s: %v\n", OUT_DATA_FILE, write_err)
			os.exit(1)
		}
	}

	_, write_err := io.write_full(w, transmute([]byte)TRACK_DATA_MAGIC)
	if write_err != nil {
		fmt.eprintf("Error writing %s: %v\n", OUT_DATA_FILE, write_err)
		os.exit(1)
	}
	value_write(w, TRACK_DATA_VERSION)
	value_write(w, u32(len(tracks)))
	value_write(w, TRACK_WAVEFORM_SAMPLE_COUNT)
	for &track in tracks {
		// Blob keys are NFC so lookups match on any platform (see path_nfc).
		string_write(w, norm.path_nfc(track.path))
		string_write(w, fmt.aprintf("%v", u128(track.file_hash)))
		value_write(w, transmute(u32)track.active_rms)
		value_write(w, transmute(u32)track.duration_seconds)
		_, write_err := io.write_full(w, transmute([]byte)track.waveform_samples[:])
		if write_err != nil {
			fmt.eprintf("Error writing %s: %v\n", OUT_DATA_FILE, write_err)
			os.exit(1)
		}
	}
}

load_sound_effects :: proc() -> [dynamic]SoundEffect {
	entries, err := os.read_all_directory_by_path(FX_DIR, context.temp_allocator)
	if err != nil do return nil

	sound_effects: [dynamic]SoundEffect
	for entry in entries {
		if entry.type != .Regular && entry.type != .Symlink do continue
		if !track_file_supported(entry.name) do continue

		ident := sound_effect_ident(entry.name, context.allocator)
		if len(ident) == 0 do continue

		base := ident
		suffix := 2
		for sound_effect_ident_used(sound_effects[:], ident) {
			ident = strings.clone(fmt.aprintf("%s_%d", base, suffix))
			suffix += 1
		}

		append(
			&sound_effects,
			SoundEffect {
				ident = ident,
				path = strings.clone(fmt.aprintf("%s/%s", FX_DIR, entry.name)),
			},
		)
	}

	slice.sort_by(sound_effects[:], proc(a, b: SoundEffect) -> bool {
		return strings.compare(a.path, b.path) < 0
	})
	return sound_effects
}

track_cache_key :: proc(file_hash: FileHash) -> string {
	return fmt.aprintf("%v", u128(file_hash))
}

track_cache_entry_resolve :: proc(
	path: string,
	file_hash: FileHash,
	cache: RMSCache,
) -> RMSCacheEntry {
	entry, ok := cache.tracks[track_cache_key(file_hash)]
	if ok && entry.file_hash == file_hash do return entry
	return track_cache_entry_generate(path, file_hash)
}

load_rms_cache :: proc() -> RMSCache {
	cache := default_rms_cache()

	contents, read_err := os.read_entire_file(CACHE_FILE, context.temp_allocator)
	if read_err != nil do return cache

	loaded: RMSCache
	unmarshal_err := json.unmarshal(contents, &loaded, .Bitsquid, context.allocator)
	if unmarshal_err != nil do return cache

	if loaded.version != cache.version ||
	   loaded.waveform_sample_count != cache.waveform_sample_count ||
	   loaded.active_sample_gate != cache.active_sample_gate ||
	   loaded.active_rms_window_seconds != cache.active_rms_window_seconds ||
	   loaded.min_active_rms_seconds != cache.min_active_rms_seconds ||
	   loaded.tracks == nil {
		delete(loaded.tracks)
		return cache
	}

	delete(cache.tracks)
	return loaded
}

save_rms_cache :: proc(tracks: []GeneratedTrack) {
	cache := default_rms_cache()
	defer delete(cache.tracks)

	for track in tracks {
		cache.tracks[track_cache_key(track.file_hash)] = RMSCacheEntry {
			file_hash        = track.file_hash,
			active_rms       = track.active_rms,
			duration_seconds = track.duration_seconds,
			waveform_samples = track.waveform_samples,
		}
	}

	data, marshal_err := json.marshal(
		cache,
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
	if marshal_err != nil {
		fmt.eprintf("Error marshaling %s: %v\n", CACHE_FILE, marshal_err)
		os.exit(1)
	}

	write_err := os.write_entire_file(CACHE_FILE, data)
	if write_err != nil {
		fmt.eprintf("Error writing %s: %v\n", CACHE_FILE, write_err)
		os.exit(1)
	}
}

default_rms_cache :: proc() -> RMSCache {
	return RMSCache {
		version = 6,
		waveform_sample_count = TRACK_WAVEFORM_SAMPLE_COUNT,
		active_sample_gate = MUSIC_ACTIVE_SAMPLE_GATE,
		active_rms_window_seconds = MUSIC_ACTIVE_RMS_WINDOW_SECONDS,
		min_active_rms_seconds = MUSIC_MIN_ACTIVE_RMS_SECONDS,
		tracks = make(map[string]RMSCacheEntry),
	}
}

track_cache_entry_generate :: proc(path: string, file_hash: FileHash) -> RMSCacheEntry {
	path_cstring := strings.clone_to_cstring(path, context.temp_allocator)
	spec: sdl.AudioSpec

	// Pass 1: count total frames without buffering.
	decoder := mixer.CreateAudioDecoder(path_cstring, 0)
	ensure(decoder != nil, fmt.tprintf("Invalid music track %s: %s", path, sdl.GetError()))
	ensure(mixer.GetAudioDecoderFormat(decoder, &spec), string(sdl.GetError()))
	spec.format = .F32
	channels := int(spec.channels)
	sample_rate := int(spec.freq)
	ensure(channels > 0 && sample_rate > 0, fmt.tprintf("Invalid music format: %s", path))

	total_samples := 0
	count_buffer: [4096]f32
	for {
		byte_count := mixer.DecodeAudio(
			decoder,
			&count_buffer[0],
			c.int(size_of(count_buffer)),
			spec,
		)
		ensure(
			byte_count >= 0,
			fmt.tprintf("Couldn't decode music samples %s: %s", path, sdl.GetError()),
		)
		if byte_count == 0 do break
		total_samples += int(byte_count) / size_of(f32)
	}
	mixer.DestroyAudioDecoder(decoder)
	total_frames := total_samples / channels
	ensure(total_frames > 0, fmt.tprintf("Empty music track: %s", path))

	// Pass 2: streaming RMS and waveform extraction.
	decoder = mixer.CreateAudioDecoder(path_cstring, 0)
	ensure(decoder != nil, fmt.tprintf("Invalid music track %s: %s", path, sdl.GetError()))
	ensure(mixer.GetAudioDecoderFormat(decoder, &spec), string(sdl.GetError()))
	spec.format = .F32
	defer mixer.DestroyAudioDecoder(decoder)

	window_frames := max(int(f64(sample_rate) * MUSIC_ACTIVE_RMS_WINDOW_SECONDS), 1)
	active_min_frames := int(f64(sample_rate) * MUSIC_MIN_ACTIVE_RMS_SECONDS)
	active_power_sum: f64
	active_frame_count: int
	window_power_sum: f64
	window_frame_count: int

	waveform_targets: [TRACK_WAVEFORM_SAMPLE_COUNT]int
	for i in 0 ..< TRACK_WAVEFORM_SAMPLE_COUNT {
		waveform_targets[i] = i * total_frames / TRACK_WAVEFORM_SAMPLE_COUNT
	}

	entry := RMSCacheEntry {
		file_hash        = file_hash,
		duration_seconds = f32(total_frames) / f32(sample_rate),
	}

	current_frame := 0
	next_waveform_bucket := 0
	decode_buffer: [4096]f32
	for {
		byte_count := mixer.DecodeAudio(
			decoder,
			&decode_buffer[0],
			c.int(size_of(decode_buffer)),
			spec,
		)
		ensure(
			byte_count >= 0,
			fmt.tprintf("Couldn't decode music samples %s: %s", path, sdl.GetError()),
		)
		if byte_count == 0 do break
		chunk_frames := int(byte_count) / size_of(f32) / channels

		for f in 0 ..< chunk_frames {
			abs_frame := current_frame + f
			base := f * channels

			frame_power: f64
			for c in 0 ..< channels {
				sample := f64(decode_buffer[base + c])
				frame_power += sample * sample
			}
			frame_power /= f64(channels)
			window_power_sum += frame_power
			window_frame_count += 1

			if window_frame_count >= window_frames || abs_frame == total_frames - 1 {
				window_rms := math.sqrt(window_power_sum / f64(window_frame_count))
				if window_rms >= f64(MUSIC_ACTIVE_SAMPLE_GATE) {
					active_power_sum += window_power_sum
					active_frame_count += window_frame_count
				}
				window_power_sum = 0
				window_frame_count = 0
			}

			for next_waveform_bucket < TRACK_WAVEFORM_SAMPLE_COUNT &&
			    abs_frame >= waveform_targets[next_waveform_bucket] {
				entry.waveform_samples[next_waveform_bucket] = i8(
					math.clamp(decode_buffer[base] * 127, -127, 127),
				)
				next_waveform_bucket += 1
			}
		}
		current_frame += chunk_frames
	}

	ensure(
		current_frame == total_frames,
		fmt.tprintf(
			"Music frame count changed between decode passes %s: %d != %d",
			path,
			current_frame,
			total_frames,
		),
	)

	if active_frame_count >= active_min_frames {
		entry.active_rms = f32(math.sqrt(active_power_sum / f64(active_frame_count)))
	}
	return entry
}

// Convert folder names into Odin enum identifiers:
// "Pirates - Combat!" -> "Pirates_Combat".
playlist_ident :: proc(name: string, allocator := context.allocator) -> string {
	parts, err := strings.fields_proc(name, enum_ident_separator, context.temp_allocator)
	log.ensuref(err == nil, "Error splitting enum identifier %q: %v", name, err)
	log.ensuref(len(parts) > 0, "No valid enum identifier parts in %q", name)

	ident, join_err := strings.join(parts, "_", allocator)
	log.ensuref(join_err == nil, "Error joining enum identifier %q: %v", name, join_err)
	if len(ident) > 0 && '0' <= ident[0] && ident[0] <= '9' {
		ident = fmt.aprintf("_%s", ident)
	}
	return ident
}

enum_ident_separator :: proc(r: rune) -> bool {
	return !(('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z') || ('0' <= r && r <= '9'))
}

playlist_ident_used :: proc(playlists: []Playlist, ident: string) -> bool {
	for playlist in playlists {
		if playlist.ident == ident do return true
	}
	return false
}

sound_effect_ident :: proc(name: string, allocator := context.allocator) -> string {
	ident := playlist_ident(os.stem(name), allocator)
	parts, err := strings.split(ident, "_", context.temp_allocator)
	log.ensuref(err == nil, "Error splitting sound effect identifier %q: %v", ident, err)

	for &part in parts {
		if len(part) > 0 && 'a' <= part[0] && part[0] <= 'z' {
			part = fmt.aprintf("%c%s", part[0] - 'a' + 'A', part[1:])
		}
	}

	final_ident, join_err := strings.join(parts, "_", allocator)
	log.ensuref(join_err == nil, "Error joining sound effect identifier %q: %v", ident, join_err)
	return final_ident
}

sound_effect_ident_used :: proc(sound_effects: []SoundEffect, ident: string) -> bool {
	for sound_effect in sound_effects {
		if sound_effect.ident == ident do return true
	}
	return false
}

track_file_supported :: proc(name: string) -> bool {
	return(
		strings.has_suffix(name, ".wav") ||
		strings.has_suffix(name, ".mp3") ||
		strings.has_suffix(name, ".ogg") ||
		strings.has_suffix(name, ".flac") \
	)
}
