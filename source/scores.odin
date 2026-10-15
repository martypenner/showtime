package game

import imgui "../vendor/odin-imgui"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

ScoreState :: struct {
	// Selected board index, or -1 when hidden. Hidden is the absence of a
	// reference, not a second flag.
	active: int,
	font:   ^imgui.Font,
}

// Seed table for the three score entities. Values and textures start empty
// on the entities.
Score_Seed :: struct {
	name:                string,
	background_filename: string,
	regions:             [Score_Team]Score_Region,
}

SCORE_SEEDS :: [3]Score_Seed {
	{
		name = "Game",
		background_filename = "assets/images/score_background_1.png",
		regions = {
			.Red = {x = 0.10, y = 0.50, w = 0.30, h = 0.42},
			.Blue = {x = 0.60, y = 0.50, w = 0.30, h = 0.42},
		},
	},
	{
		name = "Final",
		background_filename = "assets/images/score_background_2.png",
		regions = {
			.Red = {x = 0.10, y = 0.50, w = 0.30, h = 0.42},
			.Blue = {x = 0.60, y = 0.50, w = 0.30, h = 0.42},
		},
	},
	{
		name = "Season",
		background_filename = "assets/images/score_background_3.png",
		regions = {
			.Red = {x = 0.05, y = 0.63, w = 0.31, h = 0.30},
			.Blue = {x = 0.63, y = 0.63, w = 0.31, h = 0.30},
		},
	},
}

score_init :: proc() -> ^ScoreState {
	state := new(ScoreState)
	state.active = -1
	score_entities_ensure()
	for handle in gm.entities.score {
		entity, ok := entity_get(handle)
		ensure(ok)
		entity.score.red = 0
		entity.score.blue = 0
	}
	return state
}

score_entities_ensure :: proc() {
	seeds := SCORE_SEEDS
	for i in 0 ..< len(seeds) {
		if i < len(gm.entities.score) {
			if _, ok := entity_get(gm.entities.score[i]); ok do continue
		}
		handle := entity_create({.Score, .Projection}, seeds[i].name)
		entity := entity_must_get(handle)
		entity.score.background_filename = seeds[i].background_filename
		entity.score.regions = seeds[i].regions
	}
}

// Call with the projection imgui context current, before its first NewFrame.
score_font_load :: proc() {
	if gm.scores == nil do return

	font := imgui.FontAtlas_AddFontFromFileTTF(
		imgui.GetIO().Fonts,
		strings.clone_to_cstring(SCORE_FONT_FILENAME, context.temp_allocator),
		SCORE_FONT_SIZE,
	)
	if font == nil {
		log.errorf("Score: no font at %s; scores use the default font", SCORE_FONT_FILENAME)
	}
	gm.scores.font = font
}

score_shutdown :: proc() {
	if gm == nil do return
	for handle in gm.entities.score {
		entity, ok := entity_get(handle)
		ensure(ok)
		if entity.score.background_texture != nil {
			sdl.DestroyTexture(entity.score.background_texture)
			entity.score.background_texture = nil
		}
	}
	entity_domain_clear(&gm.entities.score)
	if gm.scores != nil do gm.scores = nil
}

// Effective visibility: an active timer owns the projection.
score_projection_shown :: proc() -> bool {
	return gm.scores != nil && gm.scores.active >= 0 && !timers_any_running()
}

score_projection_show :: proc() {
	if gm.scores == nil do return
	gm.scores.active = score_board_selected()
	video_page_clear()
}

score_projection_hide :: proc() {
	if gm.scores != nil do gm.scores.active = -1
}

// The board every edit and render targets: the selection while shown, the
// remembered one while hidden.
score_board_selected :: proc() -> int {
	ensure(gm != nil && gm.scores != nil)
	if gm.scores.active >= 0 do return gm.scores.active
	ensure(gm.scores_ui.board < len(gm.entities.score))
	return gm.scores_ui.board
}

score_board_select :: proc(index: int) {
	ensure(gm != nil && gm.scores != nil)
	ensure(index >= 0 && index < len(gm.entities.score))
	gm.scores.active = index
	gm.scores_ui.board = index
}

score_board_active :: proc() -> ^Entity {
	ensure(gm != nil && gm.scores != nil)
	// Edits from the controls land on the remembered board while hidden.
	// Render paths only run when a board is selected.
	return entity_must_get(gm.entities.score[score_board_selected()])
}

score_value_set :: proc(team: Score_Team, value: i64) {
	if gm.scores == nil do return
	board := score_board_active()
	clamped := u16(clamp(value, 0, SCORE_MAX))
	switch team {
	case .Red:
		board.score.red = clamped
	case .Blue:
		board.score.blue = clamped
	}
	// Game and Final show the same scores.
	if score_board_selected() < 2 {
		ensure(len(gm.entities.score) >= 2)
		for i in 0 ..< 2 {
			mirror := entity_must_get(gm.entities.score[i])
			mirror.score.red = board.score.red
			mirror.score.blue = board.score.blue
		}
	}
}

score_value_get :: proc(state: ^ScoreState, team: Score_Team) -> u16 {
	ensure(state != nil)
	active := max(state.active, 0)
	ensure(active < len(gm.entities.score))
	board := entity_must_get(gm.entities.score[active])
	switch team {
	case .Red:
		return board.score.red
	case .Blue:
		return board.score.blue
	}
	return 0
}

score_reset :: proc() {
	score_value_set(.Red, 0)
	score_value_set(.Blue, 0)
}

score_controls_draw :: proc() {
	state := gm.scores
	if state == nil do return

	shown := state.active >= 0
	if imgui.Checkbox("Show on projection", &shown) {
		if shown {
			score_projection_show()
		} else {
			score_projection_hide()
		}
	}

	imgui.Separator()

	for handle, i in gm.entities.score {
		entity, ok := entity_get(handle)
		ensure(ok)
		if imgui.Selectable(
			strings.clone_to_cstring(entity.label, context.temp_allocator),
			i == score_board_selected(),
		) {
			score_board_select(i)
		}
	}

	board := score_board_active()

	red := c.int(board.score.red)
	if imgui.InputInt("Red score", &red) {score_value_set(.Red, i64(red))}
	blue := c.int(board.score.blue)
	if imgui.InputInt("Blue score", &blue) {score_value_set(.Blue, i64(blue))}

	if imgui.Button("Reset scores") {score_reset()}
}

// Letterboxed the same way page videos are; a missing background leaves the
// window black.
score_projection_background_render :: proc(renderer: ^sdl.Renderer) {
	if gm.scores == nil do return
	board := score_board_active()
	if board.score.background_missing do return

	if board.score.background_texture == nil {
		score_background_load(board, renderer)
	}
	if board.score.background_texture == nil do return

	width, height: c.int
	if !sdl.GetCurrentRenderOutputSize(renderer, &width, &height) do return
	dest := video_fit_rect(
		board.score.background_width,
		board.score.background_height,
		int(width),
		int(height),
	)
	sdl.RenderTexture(renderer, board.score.background_texture, nil, &dest)
}

@(private = "file")
score_background_load :: proc(board: ^Entity, renderer: ^sdl.Renderer) {
	ensure(board != nil && .Score in board.caps)
	width, height, channels: c.int
	pixels := stbi.load(
		strings.clone_to_cstring(board.score.background_filename, context.temp_allocator),
		&width,
		&height,
		&channels,
		4,
	)
	if pixels == nil {
		log.errorf(
			"Score: no background at %s; the slide shows scores on black",
			board.score.background_filename,
		)
		board.score.background_missing = true
		return
	}

	texture := sdl.CreateTexture(renderer, sdl.PixelFormat.RGBA32, .STREAMING, width, height)
	if texture != nil {
		dst: rawptr
		pitch: c.int
		if sdl.LockTexture(texture, nil, &dst, &pitch) {
			// stbi rows are tightly packed, texture rows can be padded.
			src := ([^]u8)(pixels)
			dst_rows := ([^]u8)(dst)
			row_bytes := int(width) * 4
			for _ in 0 ..< height {
				mem.copy_non_overlapping(dst_rows, src, row_bytes)
				src = mem.ptr_offset(src, row_bytes)
				dst_rows = mem.ptr_offset(dst_rows, int(pitch))
			}
			sdl.UnlockTexture(texture)
		}
		board.score.background_texture = texture
		board.score.background_width = int(width)
		board.score.background_height = int(height)
	} else {
		log.errorf("Score: cannot create background texture: %v", sdl.GetError())
		board.score.background_missing = true
	}
	stbi.image_free(pixels)
}

score_projection_draw :: proc() {
	state := gm.scores
	if state == nil do return
	board := score_board_active()

	width, height: c.int
	if !sdl.GetCurrentRenderOutputSize(gm.displays[.Projection].renderer, &width, &height) do return

	fit := video_fit_rect(
		board.score.background_width > 0 ? board.score.background_width : int(width),
		board.score.background_height > 0 ? board.score.background_height : int(height),
		int(width),
		int(height),
	)
	dpi := gm.displays[.Projection].io.DisplayFramebufferScale
	ensure(dpi.x > 0 && dpi.y > 0)
	fit.x /= dpi.x
	fit.y /= dpi.y
	fit.w /= dpi.x
	fit.h /= dpi.y
	style := imgui.GetStyle()
	font_scale := style.FontScaleMain * style.FontScaleDpi
	ensure(font_scale > 0)

	for team in Score_Team {
		region := board.score.regions[team]
		region_x := fit.x + region.x * fit.w
		region_y := fit.y + region.y * fit.h
		region_w := region.w * fit.w
		region_h := region.h * fit.h

		text := strings.clone_to_cstring(
			fmt.tprintf("%d", score_value_get(state, team)),
			context.temp_allocator,
		)

		imgui.PushFontFloat(state.font, region_h / font_scale)
		text_size := imgui.CalcTextSize(text)
		imgui.SetCursorPos(
			{region_x + (region_w - text_size.x) / 2, region_y + (region_h - text_size.y) / 2},
		)
		imgui.TextColoredUnformatted({1, 1, 1, 1}, text)
		imgui.PopFont()
	}
}

SCORE_FONT_FILENAME :: "assets/fonts/college.ttf"
SCORE_FONT_SIZE :: f32(280)

SCORE_MAX :: 999

Score_Team :: enum u8 {
	Red,
	Blue,
}

Score_Region :: struct {
	x, y, w, h: f32,
}
