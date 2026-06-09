package test

import la "core:math/linalg"
import rl "vendor:raylib"

main :: proc() {
	rl.InitWindow(1280, 720, "My Odin + Raylib game")
	cube := rl.GenMeshCube(1, 1, 1)
	cube_mat := rl.LoadMaterialDefault()
	cube_pos: [3]f32

	for !rl.WindowShouldClose() {
		input: [3]f32

		if rl.IsKeyDown(.UP) {
			input.y += 1
		}
		if rl.IsKeyDown(.DOWN) {
			input.y -= 1
		}
		if rl.IsKeyDown(.LEFT) {
			input.x -= 1
		}
		if rl.IsKeyDown(.RIGHT) {
			input.x += 1
		}

		cube_pos += la.normalize0(input) * 5 * rl.GetFrameTime()

		rl.BeginDrawing()
		rl.ClearBackground({160, 200, 255, 255})
		cam := rl.Camera3D {
			position   = {0, 3, 3},
			target     = {0, 0, 0},
			up         = {0, 1, 0},
			fovy       = 70,
			projection = .PERSPECTIVE,
		}
		rl.BeginMode3D(cam)
		t := f32(rl.GetTime())
		rot := [3]f32{t, t * 2, t * 3}
		transf := rl.MatrixTranslate(cube_pos.x, cube_pos.y, cube_pos.z) * rl.MatrixRotateXYZ(rot)
		rl.DrawMesh(cube, cube_mat, transf)
		rl.EndMode3D()
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}

	rl.CloseWindow()
}
