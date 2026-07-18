package game

import "core:math"
import rl "vendor:raylib"

WAVEFORM_X :: 200
WAVEFORM_Y :: 200
WAVEFORM_WIDTH :: 800
WAVEFORM_HEIGHT :: 400

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
		raw_data(gm.sound_settings.points),
		i32(len(gm.sound_settings.points)),
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
