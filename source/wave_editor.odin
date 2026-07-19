package game

import "core:math"
import "core:strings"
import rl "vendor:raylib"

// This will not get hot reloaded
WaveEditorSettings :: struct {
	points: [dynamic]rl.Vector2,
}
wave_editor_settings: WaveEditorSettings

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

wave_editor :: proc() {
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

	rl.DrawLineStrip(
		raw_data(wave_editor_settings.points),
		i32(len(wave_editor_settings.points)),
		rl.SKYBLUE,
	)

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

	if hovering == .Start || hovering == .End || dragging == .Start || dragging == .End {
		rl.SetMouseCursor(rl.MouseCursor.RESIZE_EW)
	} else {
		rl.SetMouseCursor(rl.MouseCursor.DEFAULT)
	}

	rl.DrawFPS(10, 30)
}

wave_editor_track_load :: proc(track: ^Track) {
	clear(&wave_editor_settings.points)
	ensure(track != nil)

	wave := rl.LoadWave(strings.clone_to_cstring(track.path))
	ensure(rl.IsWaveValid(wave))
	defer rl.UnloadWave(wave)
	ensure(wave.frameCount > 0 && wave.channels > 0)

	samples := rl.LoadWaveSamples(wave)
	ensure(samples != nil)
	defer rl.UnloadWaveSamples(samples)

	sample_count := wave.frameCount * wave.channels
	point_count := min(wave.frameCount, WAVEFORM_WIDTH)
	x_step := f32(WAVEFORM_WIDTH) / f32(point_count)
	for point_index in 0 ..< point_count {
		sample_index := point_index * sample_count / point_count
		sample := samples[sample_index]
		append(
			&wave_editor_settings.points,
			rl.Vector2 {
				f32(WAVEFORM_X) + f32(point_index) * x_step,
				f32(WAVEFORM_Y) + f32(WAVEFORM_HEIGHT) / 2 - sample * f32(WAVEFORM_HEIGHT) / 2,
			},
		)
	}
}
