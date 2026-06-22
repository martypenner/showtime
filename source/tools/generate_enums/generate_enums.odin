package generate_enums

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

MUSIC_DIR :: "assets/sounds/music"
FX_DIR :: "assets/sounds/fx"
OUT_FILE :: "source/generated_enums.odin"
CACHE_FILE :: "source/generated_playlists.rms_cache.sjson"

Playlist :: struct {
	ident: string,
	name:  string,
}

SoundEffect :: struct {
	ident: string,
	path:  string,
}

GeneratedTrack :: struct {
	path:       string,
	file_hash:  string,
	active_rms: f32,
}

RMSCache :: struct {
	version:                   int,
	active_sample_gate:        f32,
	active_rms_window_seconds: f64,
	min_active_rms_seconds:    f64,
	tracks:                    map[string]RMSCacheEntry,
}

RMSCacheEntry :: struct {
	file_hash:  string,
	active_rms: f32,
}

MUSIC_ACTIVE_SAMPLE_GATE :: f32(0.02)
MUSIC_ACTIVE_RMS_WINDOW_SECONDS :: f64(0.05)
MUSIC_MIN_ACTIVE_RMS_SECONDS :: f64(0.5)

main :: proc() {
	rms_cache := load_rms_cache()
	defer delete(rms_cache.tracks)

	entries, err := os.read_all_directory_by_path(MUSIC_DIR, context.temp_allocator)
	if err != nil {
		fmt.eprintf("Error reading %s: %v\n", MUSIC_DIR, err)
		os.exit(1)
	}

	playlists: [dynamic]Playlist
	defer delete(playlists)
	sound_effects := load_sound_effects()
	defer delete(sound_effects)
	tracks: [dynamic]GeneratedTrack
	defer delete(tracks)

	pool: thread.Pool
	thread.pool_init(&pool, context.temp_allocator, os.get_processor_core_count())
	defer thread.pool_destroy(&pool)

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	thread_allocator := mem.dynamic_arena_allocator(&scratch)

	mutex: sync.Mutex
	failed := false

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
		if len(ident) == 0 do continue

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
			data := new(PoolData, context.temp_allocator)
			data^ = PoolData {
				path      = path,
				rms_cache = rms_cache,
				tracks    = &tracks,
				mutex     = &mutex,
				failed    = &failed,
			}
			thread.pool_add_task(&pool, context.allocator, proc(t: thread.Task) {
					data := (^PoolData)(t.data)
					track_bytes, read_err := os.read_entire_file(data.path, context.allocator)
					if read_err != nil {
						fmt.eprintf("Error reading track %s: %v\n", data.path, read_err)
						sync.guard(data.mutex)
						data.failed^ = true
						return
					}

					file_hash := fmt.tprint(hash.murmur64a(track_bytes))
					track := GeneratedTrack {
						path       = strings.clone(data.path),
						file_hash  = strings.clone(file_hash),
						active_rms = active_rms_for_track(data.path, file_hash, data.rms_cache),
					}

					sync.guard(data.mutex)
					append(data.tracks, track)
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
	fmt.sbprintln(
		&builder,
		"// Generated from assets/sounds/music by source/tools/generate_playlists.",
	)
	fmt.sbprintln(&builder, "// Do not edit by hand.")
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
	fmt.sbprintln(&builder, "GeneratedTrack :: struct {")
	fmt.sbprintln(&builder, "\tfile_hash: string,")
	fmt.sbprintln(&builder, "\tactive_rms: f32,")
	fmt.sbprintln(&builder, "}")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "TRACKS := map[string]GeneratedTrack {")
	for track in tracks {
		fmt.sbprintf(
			&builder,
			"\t%q = {{file_hash = %q, active_rms = %.8f}},\n",
			track.path,
			track.file_hash,
			track.active_rms,
		)
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

	write_err := os.write_entire_file(OUT_FILE, strings.to_string(builder))
	if write_err != nil {
		fmt.eprintf("Error writing %s: %v\n", OUT_FILE, write_err)
		os.exit(1)
	}

	save_rms_cache(tracks[:])
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

active_rms_for_track :: proc(path: string, file_hash: string, cache: RMSCache) -> f32 {
	entry, ok := cache.tracks[path]
	if ok && entry.file_hash == file_hash do return entry.active_rms
	return music_active_rms_for_file(path)
}

load_rms_cache :: proc() -> RMSCache {
	cache := default_rms_cache()

	contents, read_err := os.read_entire_file(CACHE_FILE, context.temp_allocator)
	if read_err != nil do return cache

	loaded: RMSCache
	unmarshal_err := json.unmarshal(contents, &loaded, .Bitsquid, context.allocator)
	if unmarshal_err != nil do return cache

	if loaded.version != cache.version ||
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
		cache.tracks[track.path] = RMSCacheEntry {
			file_hash  = track.file_hash,
			active_rms = track.active_rms,
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
		version = 1,
		active_sample_gate = MUSIC_ACTIVE_SAMPLE_GATE,
		active_rms_window_seconds = MUSIC_ACTIVE_RMS_WINDOW_SECONDS,
		min_active_rms_seconds = MUSIC_MIN_ACTIVE_RMS_SECONDS,
		tracks = make(map[string]RMSCacheEntry),
	}
}

music_active_rms_for_file :: proc(path: string) -> f32 {
	wave := rl.LoadWave(strings.clone_to_cstring(path, context.temp_allocator))
	if !rl.IsWaveValid(wave) do return 0
	defer rl.UnloadWave(wave)

	samples := rl.LoadWaveSamples(wave)
	if samples == nil do return 0
	defer rl.UnloadWaveSamples(samples)

	channels := int(wave.channels)
	frames := int(wave.frameCount)
	if channels <= 0 || frames <= 0 do return 0

	window_frames := max(int(f64(wave.sampleRate) * MUSIC_ACTIVE_RMS_WINDOW_SECONDS), 1)
	active_min_frames := int(f64(wave.sampleRate) * MUSIC_MIN_ACTIVE_RMS_SECONDS)
	active_power_sum: f64
	active_frame_count: int
	window_power_sum: f64
	window_frame_count: int

	for frame in 0 ..< frames {
		frame_power: f64
		for channel in 0 ..< channels {
			sample := f64(samples[frame * channels + channel])
			frame_power += sample * sample
		}
		window_power_sum += frame_power / f64(channels)
		window_frame_count += 1

		if window_frame_count >= window_frames || frame == frames - 1 {
			window_rms := math.sqrt(window_power_sum / f64(window_frame_count))
			if window_rms >= f64(MUSIC_ACTIVE_SAMPLE_GATE) {
				active_power_sum += window_power_sum
				active_frame_count += window_frame_count
			}
			window_power_sum = 0
			window_frame_count = 0
		}
	}

	if active_frame_count < active_min_frames do return 0
	return f32(math.sqrt(active_power_sum / f64(active_frame_count)))
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
