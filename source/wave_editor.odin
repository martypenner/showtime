package game

import "core:log"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

WAVEFORM_X :: 240
WAVEFORM_Y :: 552
WAVEFORM_WIDTH :: 744
WAVEFORM_HEIGHT :: 120

start_x: f32 = WAVEFORM_X
end_x := f32(WAVEFORM_X + WAVEFORM_WIDTH)
RADIUS :: 5
THRESHOLD :: RADIUS

End :: enum u8 {
	None,
	Start,
	End,
}
dragging: End
hovering: End

WaveEditorPreview :: struct {
	music:    rl.Music,
	end_time: f32,
	active:   bool,
}
wave_editor_preview: WaveEditorPreview

wave_editor_preview_is_playing :: proc() -> bool {
	return wave_editor_preview.active
}

wave_editor_preview_stop :: proc() {
	if !wave_editor_preview.active do return
	rl.StopMusicStream(wave_editor_preview.music)
	rl.UnloadMusicStream(wave_editor_preview.music)
	wave_editor_preview = {}
}

wave_editor_preview_start :: proc(track: ^Track) {
	wave_editor_preview_stop()

	generated_track, ok := TRACKS[track.path]
	ensure(ok)
	bounds, stale := music_track_bounds_resolve(
		sound_settings.music_track_bounds,
		track.path,
		generated_track.file_hash,
		generated_track.duration_seconds,
	)
	ensure(!stale)

	music := rl.LoadMusicStream(strings.clone_to_cstring(track.path, context.temp_allocator))
	ensure(rl.IsMusicValid(music))
	music.looping = false
	stream_length := rl.GetMusicTimeLength(music)
	ensure(stream_length > 0)
	bounds.end_time = min(bounds.end_time, stream_length)
	ensure(bounds.start_time < bounds.end_time)

	for &voice in sound_settings.music_voices {
		if voice.active do music_voice_stop(&voice)
	}

	rl.SetMusicVolume(
		music,
		sound_settings.music_volume * track_volume_multiplier(generated_track.active_rms),
	)
	rl.SeekMusicStream(music, bounds.start_time)
	rl.PlayMusicStream(music)
	wave_editor_preview = {
		music    = music,
		end_time = bounds.end_time,
		active   = true,
	}
}

wave_editor_track_select :: proc(track: ^Track) {
	wave_editor_preview_stop()
	generated_track, ok := TRACKS[track.path]
	ensure(ok)
	dragging = .None
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
	start_x =
		f32(WAVEFORM_X) +
		bounds.start_time / generated_track.duration_seconds * f32(WAVEFORM_WIDTH)
	end_x =
		f32(WAVEFORM_X) + bounds.end_time / generated_track.duration_seconds * f32(WAVEFORM_WIDTH)
}

wave_editor :: proc() {
	if wave_editor_preview.active {
		rl.UpdateMusicStream(wave_editor_preview.music)
		if rl.GetMusicTimePlayed(wave_editor_preview.music) >= wave_editor_preview.end_time ||
		   !rl.IsMusicStreamPlaying(wave_editor_preview.music) {
			wave_editor_preview_stop()
		}
	}

	track := music_browser_track_selected()
	generated_track, ok := TRACKS[track.path]
	ensure(ok)

	// Middle colored play space
	rl.DrawRectangleRec({start_x, WAVEFORM_Y, end_x - start_x, WAVEFORM_HEIGHT}, rl.DARKBLUE)
	// Start grayed out section
	rl.DrawRectangleRec(
		{WAVEFORM_X, WAVEFORM_Y, start_x - WAVEFORM_X, WAVEFORM_HEIGHT},
		{32, 32, 32, 255},
	)
	// End grayed out section
	rl.DrawRectangleRec(
		{end_x, WAVEFORM_Y, WAVEFORM_X + WAVEFORM_WIDTH - end_x, WAVEFORM_HEIGHT},
		{32, 32, 32, 255},
	)

	waveform_points: [TRACK_WAVEFORM_SAMPLE_COUNT]rl.Vector2
	waveform_center_y := f32(WAVEFORM_Y + WAVEFORM_HEIGHT / 2)
	for sample, index in generated_track.waveform_samples {
		x :=
			f32(WAVEFORM_X) +
			f32(index) * f32(WAVEFORM_WIDTH) / f32(TRACK_WAVEFORM_SAMPLE_COUNT - 1)
		y := waveform_center_y - f32(sample) / 127 * f32(WAVEFORM_HEIGHT) / 2
		waveform_points[index] = {x, y}
	}
	rl.DrawLineStrip(raw_data(waveform_points[:]), TRACK_WAVEFORM_SAMPLE_COUNT, rl.SKYBLUE)

	start_line: [2]rl.Vector2 = {{start_x, WAVEFORM_Y}, {start_x, WAVEFORM_Y + WAVEFORM_HEIGHT}}
	end_line: [2]rl.Vector2 = {{end_x, WAVEFORM_Y}, {end_x, WAVEFORM_Y + WAVEFORM_HEIGHT}}

	// Start selection lines and drag handles
	rl.DrawCircleV(start_line[0], RADIUS, rl.RAYWHITE)
	rl.DrawLineEx(start_line[0], start_line[1], 3, rl.RAYWHITE)
	rl.DrawCircleV(start_line[1], RADIUS, rl.RAYWHITE)

	// End selection lines and drag handles
	rl.DrawCircleV(end_line[0], RADIUS, rl.RAYWHITE)
	rl.DrawLineEx(end_line[0], end_line[1], 3, rl.RAYWHITE)
	rl.DrawCircleV(end_line[1], RADIUS, rl.RAYWHITE)

	mouse_x := f32(rl.GetMouseX())

	// Mouse drag handles. This is a fun little section where we can drag the
	// mouse faster than the framerate of raylib can keep up, so we have to do
	// extra checks to ensure we keep cursor as resize until dragging is done.
	// Start handle
	if rl.CheckCollisionPointLine(
		   rl.GetMousePosition(),
		   start_line[0],
		   start_line[1],
		   THRESHOLD,
	   ) ||
	   rl.CheckCollisionPointCircle(rl.GetMousePosition(), start_line[0], RADIUS) ||
	   rl.CheckCollisionPointCircle(rl.GetMousePosition(), start_line[1], RADIUS) {
		hovering = .Start
		if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
			dragging = .Start
		}
		// End handle
	} else if rl.CheckCollisionPointLine(
		   rl.GetMousePosition(),
		   end_line[0],
		   end_line[1],
		   THRESHOLD,
	   ) ||
	   rl.CheckCollisionPointCircle(rl.GetMousePosition(), end_line[0], RADIUS) ||
	   rl.CheckCollisionPointCircle(rl.GetMousePosition(), end_line[1], RADIUS) {
		hovering = .End
		if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
			dragging = .End
		}
	} else {
		hovering = .None
	}

	if rl.IsMouseButtonReleased(rl.MouseButton.LEFT) do dragging = .None

	previous_start_x := start_x
	previous_end_x := end_x
	if dragging == .Start {
		start_x = math.clamp(
			mouse_x,
			WAVEFORM_X,
			min(end_x - THRESHOLD, WAVEFORM_X + WAVEFORM_WIDTH),
		)
	} else if dragging == .End {
		end_x = math.clamp(
			mouse_x,
			max(start_x + THRESHOLD, WAVEFORM_X),
			WAVEFORM_X + WAVEFORM_WIDTH,
		)
	}
	if start_x != previous_start_x || end_x != previous_end_x {
		if start_x == WAVEFORM_X && end_x == WAVEFORM_X + WAVEFORM_WIDTH {
			delete_key(&sound_settings.music_track_bounds, track.path)
		} else {
			sound_settings.music_track_bounds[track.path] = MusicTrackBounds {
				file_hash  = generated_track.file_hash,
				start_time = (start_x -
					WAVEFORM_X) / f32(WAVEFORM_WIDTH) * generated_track.duration_seconds,
				end_time   = (end_x -
					WAVEFORM_X) / f32(WAVEFORM_WIDTH) * generated_track.duration_seconds,
			}
		}
		sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}

	if hovering == .Start || hovering == .End || dragging == .Start || dragging == .End {
		rl.SetMouseCursor(rl.MouseCursor.RESIZE_EW)
	} else {
		rl.SetMouseCursor(rl.MouseCursor.DEFAULT)
	}

	rl.DrawFPS(10, 30)
}
