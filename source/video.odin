#+feature dynamic-literals
package game

import imgui "../vendor/odin-imgui"
import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"

// One MP4 per deck page, shown on the projection. ffmpeg decodes the file to
// raw BGRA frames in a child process. A worker drains its pipe continuously;
// the render thread uploads complete frames at the video's frame rate.
//
// Videos live at assets/videos/<id>.mp4; the playback mode is stored in
// video.sjson keyed by the filename, so re-exporting under the same name
// keeps its settings.

video_state: ^VideoState

// GameMemory only holds a pointer to this, so it survives hot reloads.
VideoState :: struct {
	settings: VideoSettings,
	pages:    [dynamic]VideoPage,
	active:   ^VideoPlayback,
	// Last displayed frame, retained while the next playback loads.
	previous: VideoProjectionFrame,
	// Playbacks torn down while their child was still dying. video_update
	// reaps the child and frees the playback.
	retired:  [dynamic]^VideoPlayback,
}

video_init :: proc() -> ^VideoState {
	state := new(VideoState)
	state.pages = make([dynamic]VideoPage, 0, 8)
	state.retired = make([dynamic]^VideoPlayback, 0, 2)

	state.settings = video_settings_load(VIDEO_SETTINGS_FILENAME)

	video_pages_load(state)
	video_state = state
	return state
}

video_hot_reloaded :: proc(state: ^VideoState) {
	video_state = state
}

video_shutdown :: proc() {
	if video_state == nil do return
	video_page_clear()
	// The child was asked to die; give it a moment to be reaped. Anything
	// still alive after this leaks on purpose: the process is exiting.
	deadline := time.time_add(time.now(), time.Second * 3)
	for len(video_state.retired) > 0 && time.diff(time.now(), deadline) > 0 {
		video_update()
		time.sleep(time.Millisecond)
	}
	video_settings_save(VIDEO_SETTINGS_FILENAME, video_state.settings)
	video_state = nil
}

// Runs once per frame on the render thread.
video_update :: proc() {
	state := video_state
	if state == nil do return

	if playback := state.active; playback != nil {
		video_playback_update(playback)
		if playback.state == .Stopped {
			// The watchdog gave up on a child that never finished; show the
			// page as failed.
			playback.state = .Failed
		}
		if playback.frames > 0 && playback.texture != nil && state.previous.texture != nil {
			sdl.DestroyTexture(state.previous.texture)
			state.previous = {}
		}
	}

	for i := 0; i < len(state.retired); {
		playback := state.retired[i]
		video_playback_update(playback)
		if playback.state == .Stopped {
			ordered_remove(&state.retired, i)
			video_playback_destroy(playback)
		} else {
			i += 1
		}
	}
}

video_page_show :: proc(state: ^VideoState, page_id: string) -> bool {
	page, ok := video_page_find(state, page_id)
	if !ok do return false

	if playback := state.active;
	   playback != nil && playback.frames > 0 && playback.texture != nil {
		if state.previous.texture != nil do sdl.DestroyTexture(state.previous.texture)
		state.previous = {
			texture = playback.texture,
			width   = playback.width,
			height  = playback.height,
		}
		playback.texture = nil
	}
	video_playback_stop(state)

	playback := video_playback_make(page^, fmt.tprintf("%s/%s.mp4", VIDEO_DIR, page.page_id))
	state.active = playback
	video_ffprobe_spawn(playback)
	return playback.state != .Failed
}

video_page_clear :: proc() {
	if video_state == nil do return
	video_playback_stop(video_state)
	if video_state.previous.texture != nil {
		sdl.DestroyTexture(video_state.previous.texture)
		video_state.previous = {}
	}
}

video_page_mode_cycle :: proc(state: ^VideoState) {
	if state.active == nil do return
	video_page_mode_set(state.active.page_id, video_page_mode_next(state.active.mode))
}

video_page_mode_set :: proc(page_id: string, mode: VideoPlaybackMode) {
	state := video_state
	ensure(state != nil)
	page, ok := video_page_find(state, page_id)
	ensure(ok)
	page.mode = mode
	// Settings borrow the page's arena-owned name, never a playback's heap string.
	state.settings.pages[page.page_id] = mode

	playback := state.active
	if playback != nil && playback.page_id == page_id {
		playback.mode = mode
		#partial switch playback.state {
		case .Holding:
			// A frozen Once/Still restarts when it becomes a Loop.
			if mode == .Loop do video_playback_play(playback)
		case .Failed:
			if mode != .Still {
				if playback.decoder == nil {
					video_ffprobe_spawn(playback)
				} else {
					video_playback_play(playback)
				}
			}
		case:
		// A running playback picks up the mode at its next loop point.
		}
	}
	video_settings_save(VIDEO_SETTINGS_FILENAME, state.settings)
}
video_page_find :: proc(state: ^VideoState, page_id: string) -> (^VideoPage, bool) {
	for i in 0 ..< len(state.pages) {
		if state.pages[i].page_id == page_id do return &state.pages[i], true
	}
	return nil, false
}

video_page_mode_next :: proc(mode: VideoPlaybackMode) -> VideoPlaybackMode {
	switch mode {
	case .Loop:
		return .Once
	case .Once:
		return .Still
	case .Still:
		return .Loop
	}
	return .Loop
}

video_pages_load :: proc(state: ^VideoState) {
	clear(&state.pages)

	dir, dir_err := os.open(VIDEO_DIR)
	if dir_err != nil {
		log.errorf("Video: cannot open %s: %v", VIDEO_DIR, dir_err)
		return
	}
	listing, read_err := os.read_dir(dir, -1, context.temp_allocator)
	os.close(dir)
	if read_err != nil {
		log.errorf("Video: cannot read %s: %v", VIDEO_DIR, read_err)
		return
	}

	entries: [dynamic]string
	defer delete(entries)
	for entry in listing {
		name := entry.name
		if strings.has_prefix(name, ".") || !strings.has_suffix(name, ".mp4") do continue
		append(&entries, strings.clone(strings.trim_suffix(name, ".mp4")))
	}
	slice.sort_by(entries[:], proc(a, b: string) -> bool {
		return strings.compare(a, b) < 0
	})

	for entry in entries {
		page := VideoPage {
			page_id = entry,
			mode    = video_page_mode(state.settings, entry),
		}
		append(&state.pages, page)
	}

}

video_page_mode :: proc(settings: VideoSettings, page_id: string) -> VideoPlaybackMode {
	if mode, ok := settings.pages[page_id]; ok do return mode
	return .Loop
}

video_settings_load :: proc(filename: string) -> VideoSettings {
	settings := VideoSettings {
		pages = make(map[string]VideoPlaybackMode),
	}

	data, err := os.read_entire_file(filename, context.temp_allocator)
	if err != nil {
		log.errorf("Video: cannot read settings from %s: %v", filename, err)
		return settings
	}

	json_err := json.unmarshal(data, &settings, .Bitsquid)
	if json_err != nil {
		log.errorf("Video: invalid settings in %s: %v", filename, json_err)
	}
	return settings
}

video_settings_save :: proc(filename: string, settings: VideoSettings) {
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
			use_enum_names = true,
		},
		context.temp_allocator,
	)
	if json_err != nil {
		log.errorf("Video: cannot encode settings: %v", json_err)
		return
	}

	write_err := os.write_entire_file(filename, settings_json)
	if write_err != nil {
		log.errorf("Video: cannot write settings to %s: %v", filename, write_err)
	}
}

video_controls_draw :: proc(height: f32) {
	state := video_state
	if state == nil do return

	if controls_list_begin("Videos##ControlList", height) {
		for &page, index in state.pages {
			selected := state.active != nil && state.active.page_id == page.page_id
			label := fmt.tprintf("%s##video_page_%d", page.page_id, index)
			if imgui.Selectable(
				strings.clone_to_cstring(label, context.temp_allocator),
				selected,
			) {
				video_page_show(state, page.page_id)
			}
		}
	}
	imgui.EndChild()

	playback := state.active
	if playback == nil {
		imgui.TextUnformatted("Projection: black")
		return
	}

	if imgui.BeginCombo(
		"##mode",
		strings.clone_to_cstring(video_mode_labels[playback.mode], context.temp_allocator),
	) {
		for mode in VIDEO_PLAYBACK_MODES {
			if imgui.Selectable(
				strings.clone_to_cstring(video_mode_labels[mode], context.temp_allocator),
				mode == playback.mode,
			) {
				video_page_mode_set(playback.page_id, mode)
			}
		}
		imgui.EndCombo()
	}

	if playback.state == .Failed {
		msg := fmt.tprintf("Decode failed: %s", playback.page_id)
		imgui.TextColoredUnformatted({1.0, 0.4, 0.4, 1.0}, strings.clone_to_cstring(msg))
		return
	}
	msg := fmt.tprintf(
		"Projection: %s (%s, %v)",
		playback.page_id,
		video_mode_labels[playback.mode],
		playback.state,
	)
	imgui.TextUnformatted(strings.clone_to_cstring(msg, context.temp_allocator))
}

// A Holding playback keeps drawing its last frame.
video_projection_render :: proc(renderer: ^sdl.Renderer) {
	state := video_state
	if state == nil do return
	frame := state.previous
	if playback := state.active;
	   playback != nil && playback.frames > 0 && playback.texture != nil {
		frame = {
			texture = playback.texture,
			width   = playback.width,
			height  = playback.height,
		}
	}
	if frame.texture == nil do return

	width, height: c.int
	if !sdl.GetCurrentRenderOutputSize(renderer, &width, &height) do return
	dest := video_fit_rect(frame.width, frame.height, int(width), int(height))
	sdl.RenderTexture(renderer, frame.texture, nil, &dest)
}

video_fit_rect :: proc(video_w, video_h, window_w, window_h: int) -> sdl.FRect {
	if video_w <= 0 || video_h <= 0 do return sdl.FRect{}

	scale := f32(window_w) / f32(video_w)
	scale_h := f32(window_h) / f32(video_h)
	if scale_h < scale do scale = scale_h

	draw_width := f32(video_w) * scale
	draw_height := f32(video_h) * scale

	return sdl.FRect {
		x = (f32(window_w) - draw_width) / 2,
		y = (f32(window_h) - draw_height) / 2,
		w = draw_width,
		h = draw_height,
	}
}

// ffmpeg writes raw BGRA frames to stdout.
@(private = "file")
video_playback_play :: proc(playback: ^VideoPlayback) -> bool {
	ensure(playback.decoder != nil && playback.decoder.reader == nil)
	if playback.stdout != nil {
		os.close(playback.stdout)
		playback.stdout = nil
	}
	args := make([dynamic]string, 0, 13, context.temp_allocator)
	defer delete(args)
	append(&args, "ffmpeg", "-v", "error", "-re", "-i", playback.path)
	// Still pages stop after one frame.
	if playback.mode == .Still do append(&args, "-frames:v", "1")
	append(&args, "-f", "rawvideo", "-pix_fmt", "bgra", "pipe:1")

	read_file, write_file, pipe_err := os.pipe()
	if pipe_err != nil {
		log.errorf("Video: cannot create pipe: %v", pipe_err)
		playback.state = .Failed
		return false
	}

	process, start_err := os.process_start({command = args[:], stdout = write_file})
	os.close(write_file)
	if start_err != nil {
		os.close(read_file)
		log.errorf("Video: cannot start ffmpeg for %s: %v", playback.path, start_err)
		playback.state = .Failed
		return false
	}

	playback.process = process
	playback.stdout = read_file
	playback.state = .Playing

	now := time.now()
	playback.last_output = now
	playback.next_frame = {}
	playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
	decoder := playback.decoder
	decoder.stdout = read_file
	decoder.frame_state = .Empty
	decoder.state = .Reading
	decoder.read_error = nil
	decoder.last_output = now
	allocator_previous := context.allocator
	context.allocator = runtime.heap_allocator()
	decoder.reader = thread.create(video_decoder_read, name = "Video reader")
	context.allocator = allocator_previous
	if decoder.reader == nil {
		log.errorf("Video: cannot start reader for %s", playback.page_id)
		video_playback_kill(playback)
		return false
	}
	decoder.reader.data = decoder
	thread.start(decoder.reader)
	return true
}

@(private = "file")
video_decoder_read :: proc(reader: ^thread.Thread) {
	decoder := (^VideoDecoder)(reader.data)
	ensure(decoder != nil)
	filled := 0
	for {
		n, read_err := os.read(decoder.stdout, decoder.frame_read[filled:])
		if read_err != nil || n == 0 {
			sync.lock(&decoder.mutex)
			if read_err != io.Error.EOF {
				decoder.read_error = read_err
			} else if filled != 0 {
				decoder.read_error = io.Error.Unexpected_EOF
			}
			sync.unlock(&decoder.mutex)
			return
		}
		filled += n
		if filled == len(decoder.frame_read) {
			sync.lock(&decoder.mutex)
			for decoder.frame_state == .Ready && decoder.state == .Reading {
				sync.cond_wait(&decoder.slot_available, &decoder.mutex)
			}
			if decoder.state == .Stopping {
				sync.unlock(&decoder.mutex)
				return
			}
			decoder.frame_pending, decoder.frame_read = decoder.frame_read, decoder.frame_pending
			decoder.frame_state = .Ready
			decoder.last_output = time.now()
			sync.unlock(&decoder.mutex)
			filled = 0
		}
	}
}

// The playback sits in .Probing until the JSON comes back.
video_ffprobe_spawn :: proc(playback: ^VideoPlayback) -> bool {
	if playback.stdout != nil {
		os.close(playback.stdout)
		playback.stdout = nil
	}
	if playback.output_buf != nil {
		delete(playback.output_buf)
		playback.output_buf = nil
	}
	args: [10]string
	args[0] = "ffprobe"
	args[1] = "-v"
	args[2] = "error"
	args[3] = "-select_streams"
	args[4] = "v:0"
	args[5] = "-show_entries"
	args[6] = "stream=width,height,r_frame_rate"
	args[7] = "-of"
	args[8] = "json"
	args[9] = playback.path

	read_file, write_file, pipe_err := os.pipe()
	if pipe_err != nil {
		log.errorf("Video: cannot create probe pipe: %v", pipe_err)
		playback.state = .Failed
		return false
	}

	process, start_err := os.process_start({command = args[:], stdout = write_file})
	os.close(write_file)
	if start_err != nil {
		os.close(read_file)
		log.errorf("Video: cannot start ffprobe for %s: %v", playback.path, start_err)
		playback.state = .Failed
		return false
	}

	playback.process = process
	playback.stdout = read_file
	playback.output_buf = make([dynamic]u8, 0, 1024, allocator = runtime.heap_allocator())
	playback.state = .Probing

	now := time.now()
	playback.last_output = now
	playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
	return true
}

// Advance the state machine one step on the render thread. Never blocks: a
// state either reads what is already available or waits for the next update.
video_playback_update :: proc(playback: ^VideoPlayback) {
	switch playback.state {
	case .Probing:
		video_playback_update_probing(playback)
	case .Playing:
		video_playback_update_playing(playback)
	case .Draining, .Stopping:
		video_playback_update_reaping(playback)
	case .Holding, .Failed, .Stopped:
	}
}

@(private = "file")
video_playback_update_probing :: proc(playback: ^VideoPlayback) {
	now := time.now()
	if time.diff(playback.quit_at, now) > 0 {
		log.errorf("Video: ffprobe timed out for page %s", playback.page_id)
		video_playback_kill(playback)
		return
	}

	for {
		has_data, data_err := os.pipe_has_data(playback.stdout)
		if data_err != nil {
			// Child closed its end; treat it like EOF and reap.
			playback.state = .Draining
			break
		}
		if !has_data do return

		scratch: [4096]u8
		n, read_err := os.read(playback.stdout, scratch[:])
		if read_err != nil {
			if read_err.(io.Error) == .EOF {
				playback.state = .Draining
				break
			}
			log.errorf(
				"Video: ffprobe pipe read failed for page %s: %v",
				playback.page_id,
				read_err,
			)
			video_playback_kill(playback)
			return
		}
		append(&playback.output_buf, ..scratch[:n])
		playback.last_output = now
		if len(playback.output_buf) > VIDEO_PROBE_OUTPUT_MAX {
			log.errorf(
				"Video: ffprobe output for page %s went over %d bytes",
				playback.page_id,
				VIDEO_PROBE_OUTPUT_MAX,
			)
			video_playback_kill(playback)
			return
		}
		if n < len(scratch) do break // pipe drained for now
	}

	if playback.state == .Draining {
		playback.kill_at = time.time_add(now, VIDEO_KILL_AFTER)
		playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
		video_playback_update_reaping(playback)
	}
}

@(private = "file")
video_playback_update_playing :: proc(playback: ^VideoPlayback) {
	now := time.now()
	decoder := playback.decoder
	ensure(decoder != nil && decoder.reader != nil)
	reader_done := thread.is_done(decoder.reader)
	sync.lock(&decoder.mutex)
	frame_due :=
		decoder.frame_state == .Ready &&
		(playback.next_frame == time.Time{} || time.diff(now, playback.next_frame) <= 0)
	if frame_due {
		playback.frame, decoder.frame_pending = decoder.frame_pending, playback.frame
		decoder.frame_state = .Empty
		sync.cond_signal(&decoder.slot_available)
	}
	frame_state := decoder.frame_state
	playback.last_output = decoder.last_output
	read_error := decoder.read_error
	sync.unlock(&decoder.mutex)
	if frame_due && !video_playback_publish(playback) {
		video_playback_kill(playback)
		return
	}
	if reader_done && frame_state == .Empty {
		if read_error != nil {
			log.errorf("Video: pipe read failed for page %s: %v", playback.page_id, read_error)
			video_playback_kill(playback)
			return
		}
		playback.state = .Draining
		playback.kill_at = time.time_add(now, VIDEO_KILL_AFTER)
		playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
		return
	}
	if !frame_due &&
	   frame_state == .Empty &&
	   time.diff(playback.last_output, now) > VIDEO_GIVE_UP_AFTER {
		log.errorf("Video: ffmpeg stalled for page %s", playback.page_id)
		video_playback_kill(playback)
	}
}

// The child has exited or been asked to die. Reap it without blocking, then
// use the exit code to pick the next state.
@(private = "file")
video_playback_update_reaping :: proc(playback: ^VideoPlayback) {
	now := time.now()

	reader_done :=
		playback.decoder == nil ||
		playback.decoder.reader == nil ||
		thread.is_done(playback.decoder.reader)
	wait_state: os.Process_State
	wait_err: os.Error
	if reader_done {
		if playback.state == .Stopping && playback.stdout != nil {
			os.close(playback.stdout)
			playback.stdout = nil
		}
		wait_state, wait_err = os.process_wait(playback.process, 0)
	}
	if wait_state.exited {
		if playback.decoder != nil && playback.decoder.reader != nil {
			thread.destroy(playback.decoder.reader)
			playback.decoder.reader = nil
		}
		if playback.state == .Stopping {
			playback.state = .Stopped
			return
		}
		// Draining: a clean exit means the child finished. Probe results
		// still pending means the probe finished, not the decode.
		if wait_err != nil || wait_state.exit_code != 0 {
			log.errorf(
				"Video: ffmpeg exited abnormally for page %s: code %d, err %v",
				playback.page_id,
				wait_state.exit_code,
				wait_err,
			)
			playback.state = .Failed
			return
		}
		if playback.output_buf != nil {
			if !video_playback_probe_parse(playback) {
				playback.state = .Failed
				return
			}
			video_playback_play(playback)
			return
		}
		if playback.mode == .Loop {
			video_playback_play(playback)
		} else {
			playback.state = .Holding
		}
		return
	}

	if time.diff(playback.kill_at, now) > 0 {
		if kill_err := os.process_kill(playback.process); kill_err != nil {
			log.errorf("Video: failed to kill ffmpeg for page %s: %v", playback.page_id, kill_err)
		}
		playback.kill_at = time.time_add(now, VIDEO_KILL_AFTER)
	}
	if time.diff(playback.quit_at, now) > 0 {
		log.errorf("Video: child for page %s would not die", playback.page_id)
		if reader_done {
			playback.state = .Stopped
		} else {
			playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
		}
	}
}

@(private = "file")
video_playback_publish :: proc(playback: ^VideoPlayback) -> bool {
	if playback.texture != nil {
		pixels: rawptr
		pitch: c.int
		if !sdl.LockTexture(playback.texture, nil, &pixels, &pitch) {
			log.errorf("Video: cannot upload frame for %s: %v", playback.page_id, sdl.GetError())
			return false
		}
		// Texture rows can be padded past width*4.
		src := ([^]u8)(&playback.frame[0])
		dst := ([^]u8)(pixels)
		row_bytes := playback.width * 4
		for _ in 0 ..< playback.height {
			mem.copy_non_overlapping(dst, src, row_bytes)
			src = mem.ptr_offset(src, row_bytes)
			dst = mem.ptr_offset(dst, int(pitch))
		}
		sdl.UnlockTexture(playback.texture)
	}
	playback.frames += 1
	now := time.now()
	if (playback.next_frame == time.Time{}) ||
	   time.diff(playback.next_frame, now) > playback.frame_time * 5 {
		playback.next_frame = time.time_add(now, playback.frame_time)
	} else {
		playback.next_frame = time.time_add(playback.next_frame, playback.frame_time)
	}
	return true
}

video_playback_probe_parse :: proc(playback: ^VideoPlayback) -> bool {
	// The probe data is transient, so it parses into the temp allocator.
	probe: video_ffprobe_out
	json_err := json.unmarshal(playback.output_buf[:], &probe, nil, context.temp_allocator)
	if json_err != nil {
		log.errorf(
			"Video: cannot parse ffprobe output for page %s: %v",
			playback.page_id,
			json_err,
		)
		return false
	}

	if len(probe.streams) < 1 {
		log.errorf("Video: ffprobe found no video stream in %s", playback.path)
		return false
	}
	stream := probe.streams[0]

	if stream.width > 0 do playback.width = int(stream.width)
	if stream.height > 0 do playback.height = int(stream.height)
	if rate := stream.r_frame_rate; rate != "" {
		if fps := video_frame_rate_parse(rate); fps > 0 do playback.fps = fps
	}
	if playback.width <= 0 || playback.height <= 0 {
		log.errorf("Video: ffprobe reported no dimensions for %s", playback.path)
		return false
	}
	if playback.fps <= 0 || playback.fps > 240 {
		log.errorf("Video: unknown frame rate for %s, assuming 30", playback.path)
		playback.fps = 30
	}
	heap := runtime.heap_allocator()
	playback.frame_bytes = int(playback.width) * int(playback.height) * 4
	playback.frame_time = time.Duration(f64(time.Second) / f64(playback.fps))
	playback.frame = make([]byte, playback.frame_bytes, allocator = heap)
	playback.decoder = new(VideoDecoder, allocator = heap)
	playback.decoder.frame_read = make([]byte, playback.frame_bytes, allocator = heap)
	playback.decoder.frame_pending = make([]byte, playback.frame_bytes, allocator = heap)
	delete(playback.output_buf)
	playback.output_buf = nil

	if projection_renderer != nil {
		texture := sdl.CreateTexture(
			projection_renderer,
			sdl.PixelFormat.BGRA32,
			.STREAMING,
			c.int(playback.width),
			c.int(playback.height),
		)
		if texture == nil {
			log.errorf("Video: cannot create texture: %v", sdl.GetError())
			return false
		}
		playback.texture = texture
	}
	return true
}

// The playback is either in .Probing or .Failed when this returns.
video_playback_make :: proc(page: VideoPage, path: string) -> ^VideoPlayback {
	heap := runtime.heap_allocator()
	playback := new(VideoPlayback, allocator = heap)
	playback.state = .Failed // nothing running yet; the spawn procs set the real state
	playback.page_id = strings.clone(page.page_id, allocator = heap)
	playback.path = strings.clone(path, allocator = heap)
	playback.mode = page.mode
	return playback
}

// Ask the child to die; updates reap it from .Stopping.
@(private = "file")
video_playback_kill :: proc(playback: ^VideoPlayback) {
	if decoder := playback.decoder; decoder != nil {
		sync.lock(&decoder.mutex)
		decoder.state = .Stopping
		sync.cond_broadcast(&decoder.slot_available)
		sync.unlock(&decoder.mutex)
	}
	if term_err := os.process_terminate(playback.process); term_err != nil {
		log.errorf("Video: failed to terminate ffmpeg: %v", term_err)
	}
	playback.state = .Stopping
	now := time.now()
	playback.kill_at = time.time_add(now, VIDEO_KILL_AFTER)
	playback.quit_at = time.time_add(now, VIDEO_GIVE_UP_AFTER)
}

// Ask the child to die, release the texture and buffers, then free the
// playback or retire it for reaping.
@(private = "file")
video_playback_stop :: proc(state: ^VideoState) {
	playback := state.active
	state.active = nil
	if playback == nil do return

	switch playback.state {
	case .Probing, .Playing, .Draining:
		video_playback_kill(playback)
	case .Stopping:
	case .Stopped, .Holding, .Failed:
		playback.state = .Stopped
	}

	if playback.texture != nil {
		sdl.DestroyTexture(playback.texture)
		playback.texture = nil
	}

	if playback.state == .Stopped {
		video_playback_destroy(playback)
	} else {
		append(&state.retired, playback)
	}
}

// Only called once the child is reaped.
@(private = "file")
video_playback_destroy :: proc(playback: ^VideoPlayback) {
	heap := runtime.heap_allocator()
	// Frees what video_playback_make allocated from the heap. The game's
	// arena allocator ignores free, so freeing through context.allocator
	// would leak ~24 MB of frame buffer per 1080p page.
	if decoder := playback.decoder; decoder != nil {
		if decoder.reader != nil {
			ensure(thread.is_done(decoder.reader))
			thread.destroy(decoder.reader)
		}
		delete(decoder.frame_read, allocator = heap)
		delete(decoder.frame_pending, allocator = heap)
		free(decoder, allocator = heap)
	}
	if playback.stdout != nil {
		os.close(playback.stdout)
		playback.stdout = nil
	}
	if playback.frame != nil do delete(playback.frame, allocator = heap)
	if playback.output_buf != nil do delete(playback.output_buf)
	delete(playback.path, allocator = heap)
	delete(playback.page_id, allocator = heap)
	free(playback, allocator = heap)
}

// "30000/1001" style fractions, or a plain integer. Returns 0 when the rate
// makes no sense; the caller falls back to a default.
video_frame_rate_parse :: proc(text: string) -> f32 {
	num, den, ok := video_fraction_parse(text)
	if !ok || den == 0 do return 0
	return f32(num) / f32(den)
}

video_fraction_parse :: proc(text: string) -> (num, den: i64, ok: bool) {
	parts, parts_err := strings.split(text, "/")
	if parts_err != nil do return 0, 0, false
	defer delete(parts)

	den_text := "1"
	if len(parts) > 2 do return 0, 0, false
	if len(parts) == 2 do den_text = parts[1]

	num_value, num_ok := strconv.parse_i64(parts[0])
	if !num_ok do return 0, 0, false
	den_value, den_ok := strconv.parse_i64(den_text)
	if !den_ok do return 0, 0, false
	num, den = num_value, den_value
	return num, den, true
}

VIDEO_DIR :: "assets/videos"
VIDEO_SETTINGS_FILENAME :: "video.sjson"

VIDEO_PLAYBACK_MODES :: []VideoPlaybackMode{.Loop, .Once, .Still}
video_mode_labels := [VideoPlaybackMode]string {
	.Loop  = "Loop",
	.Once  = "Play Once",
	.Still = "Still",
}

VideoPlaybackMode :: enum u8 {
	// Restart from the first frame when it ends.
	Loop,
	// Play to the end and freeze the last frame.
	Once,
	// Never animate: decode a single frame and keep it.
	Still,
}

VideoSettings :: struct {
	pages: map[string]VideoPlaybackMode,
}

VideoPage :: struct {
	page_id: string,
	mode:    VideoPlaybackMode,
}

VideoProjectionFrame :: struct {
	texture: ^sdl.Texture,
	width:   int,
	height:  int,
}

// One video on the projection. Lives on the heap because the render thread
// owns it directly.
VideoPlayback :: struct {
	// What the playback is doing: Probing and Playing have a live child,
	// Draining and Stopping are reaping one, Holding/Failed/Stopped are done.
	state:       VideoPlaybackState,
	page_id:     string,
	path:        string,
	mode:        VideoPlaybackMode,
	width:       int,
	height:      int,
	fps:         f32,
	// Width * height * 4: one BGRA frame, exactly what ffmpeg writes.
	frame_bytes: int,
	frame_time:  time.Duration,
	// The render thread owns this buffer; the decoder swaps complete frames in.
	frame:       []byte,
	decoder:     ^VideoDecoder,
	texture:     ^sdl.Texture,
	frames:      u64,

	// Child's stdout. Closed in video_playback_destroy.
	stdout:      ^os.File,
	process:     os.Process,
	// ffprobe's JSON collects here.
	output_buf:  [dynamic]u8,

	// last_output/quit_at watch the child; kill_at escalates a teardown.
	next_frame:  time.Time,
	last_output: time.Time,
	quit_at:     time.Time,
	kill_at:     time.Time,
}

VideoDecoder :: struct {
	reader:         ^thread.Thread,
	mutex:          sync.Mutex,
	slot_available: sync.Cond,
	stdout:         ^os.File,
	frame_read:     []byte,
	frame_pending:  []byte,
	frame_state:    VideoFrameState,
	state:          VideoDecoderState,
	last_output:    time.Time,
	read_error:     os.Error,
}

VideoFrameState :: enum u8 {
	Empty,
	Ready,
}

VideoDecoderState :: enum u8 {
	Reading,
	Stopping,
}

VideoPlaybackState :: enum u8 {
	// ffprobe is running: getting dimensions and frame rate.
	Probing,
	// ffmpeg is running: decoding frames.
	Playing,
	// The pipe closed cleanly; the child is being reaped. The exit code
	// decides between Holding (finished) and Failed (crashed).
	Draining,
	// The child was killed and is being reaped. Becomes Stopped.
	Stopping,
	// Finished playing: the texture keeps its last frame.
	Holding,
	// Something went wrong; nothing is running.
	Failed,
	// Fully torn down, pending free.
	Stopped,
}

// Ask a child to die politely, then escalate in
// video_playback_update_reaping, which never blocks.
VIDEO_KILL_AFTER :: 2 * time.Second
VIDEO_GIVE_UP_AFTER :: 10 * time.Second
VIDEO_PROBE_OUTPUT_MAX :: 1 << 20

// ffprobe's "-show_entries stream=..." JSON shape. Fields default to zero
// when missing, which the dimension and frame rate guards handle.
video_ffprobe_stream :: struct {
	width:        int,
	height:       int,
	r_frame_rate: string,
}

video_ffprobe_out :: struct {
	streams: [dynamic]video_ffprobe_stream,
}
