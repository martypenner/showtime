package game

import imgui "../vendor/odin-imgui"
import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

// Three fixed scoreboards, Game, Final and Season. Each owns a PNG background
// and the score regions on it, so the digits track the art at any window size
// or display scale. Game and Final show the same scores; Season keeps its own.
// A missing background leaves the projection black.
//
// Triggered by hand from the main controls and shown in place of the deck pages.
// Nothing persists: the scores reset every launch.
//
// A playing timer owns the projection. Starting one hides the slide; the Show
// on projection checkbox brings it back over the timer.

ScoreState :: struct {
	shown:       bool,
	active:      int,
	scoreboards: [3]Scoreboard,
	// Font in the projection imgui atlas. nil when the font file is missing: the
	// default font renders instead.
	font:        ^imgui.Font,
}

Scoreboard :: struct {
	name:       string,
	background: struct {
		filename: string,
		// Projection renderer texture. nil until first shown (the renderer may
		// not exist yet at init) or when the file is missing.
		texture:  ^sdl.Texture,
		missing:  bool,
		width:    int,
		height:   int,
	},
	// Score positions as fractions of the background.
	regions:    [Score_Team]Score_Region,
	red:        u16,
	blue:       u16,
}

SCOREBOARDS :: [3]Scoreboard {
	{
		name = "Game",
		background = {filename = "assets/images/score_background_1.png"},
		regions = {
			.Red = {x = 0.10, y = 0.50, w = 0.30, h = 0.42},
			.Blue = {x = 0.60, y = 0.50, w = 0.30, h = 0.42},
		},
	},
	{
		name = "Final",
		background = {filename = "assets/images/score_background_2.png"},
		regions = {
			.Red = {x = 0.10, y = 0.50, w = 0.30, h = 0.42},
			.Blue = {x = 0.60, y = 0.50, w = 0.30, h = 0.42},
		},
	},
	{
		name = "Season",
		background = {filename = "assets/images/score_background_3.png"},
		regions = {
			.Red = {x = 0.05, y = 0.63, w = 0.31, h = 0.30},
			.Blue = {x = 0.63, y = 0.63, w = 0.31, h = 0.30},
		},
	},
}

score_init :: proc() -> ^ScoreState {
	state := new(ScoreState)
	state.scoreboards = SCOREBOARDS
	return state
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
	if gm == nil || gm.scores == nil do return
	for &board in gm.scores.scoreboards {
		if board.background.texture != nil {
			sdl.DestroyTexture(board.background.texture)
			board.background.texture = nil
		}
	}
	gm.scores = nil
}

// The Show on projection checkbox is a direct override: it wins even while a
// timer is running.
score_projection_shown :: proc() -> bool {
	return gm.scores != nil && gm.scores.shown
}

score_projection_hide :: proc() {
	if gm.scores != nil do gm.scores.shown = false
}

score_active :: proc(state: ^ScoreState) -> ^Scoreboard {
	return &state.scoreboards[state.active]
}

score_value_set :: proc(team: Score_Team, value: i64) {
	if gm.scores == nil do return
	board := score_active(gm.scores)
	clamped := u16(clamp(value, 0, SCORE_MAX))
	switch team {
	case .Red:
		board.red = clamped
	case .Blue:
		board.blue = clamped
	}
	// Game and Final show the same scores.
	if gm.scores.active < 2 {
		game := &gm.scores.scoreboards[0]
		final := &gm.scores.scoreboards[1]
		game.red, game.blue = board.red, board.blue
		final.red, final.blue = board.red, board.blue
	}
}

score_value_get :: proc(state: ^ScoreState, team: Score_Team) -> u16 {
	board := score_active(state)
	switch team {
	case .Red:
		return board.red
	case .Blue:
		return board.blue
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

	if imgui.Checkbox("Show on projection", &state.shown) && state.shown {
		video_projection_hide()
	}

	imgui.Separator()

	for &board, i in state.scoreboards {
		if imgui.Selectable(
			strings.clone_to_cstring(board.name, context.temp_allocator),
			i == state.active,
		) {
			state.active = i
		}
	}

	board := score_active(state)

	red := c.int(board.red)
	if imgui.InputInt("Red score", &red) {score_value_set(.Red, i64(red))}
	blue := c.int(board.blue)
	if imgui.InputInt("Blue score", &blue) {score_value_set(.Blue, i64(blue))}

	if imgui.Button("Reset scores") {score_reset()}
}

// Letterboxed the same way page videos are; a missing background leaves the
// window black.
score_projection_background_render :: proc(renderer: ^sdl.Renderer) {
	state := gm.scores
	if state == nil do return
	board := score_active(state)
	if board.background.missing do return

	if board.background.texture == nil {
		score_background_load(board, renderer)
	}
	if board.background.texture == nil do return

	width, height: c.int
	if !sdl.GetCurrentRenderOutputSize(renderer, &width, &height) do return
	dest := video_fit_rect(
		board.background.width,
		board.background.height,
		int(width),
		int(height),
	)
	sdl.RenderTexture(renderer, board.background.texture, nil, &dest)
}

@(private = "file")
score_background_load :: proc(board: ^Scoreboard, renderer: ^sdl.Renderer) {
	width, height, channels: c.int
	pixels := stbi.load(
		strings.clone_to_cstring(board.background.filename, context.temp_allocator),
		&width,
		&height,
		&channels,
		4,
	)
	if pixels == nil {
		log.errorf(
			"Score: no background at %s; the slide shows scores on black",
			board.background.filename,
		)
		board.background.missing = true
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
		board.background.texture = texture
		board.background.width = int(width)
		board.background.height = int(height)
	} else {
		log.errorf("Score: cannot create background texture: %v", sdl.GetError())
		board.background.missing = true
	}
	stbi.image_free(pixels)
}

// The regions are fractions of the fitted background, so the scores track the
// art at any window size or display scale.
score_projection_draw :: proc() {
	state := gm.scores
	if state == nil do return
	board := score_active(state)

	width, height: c.int
	if !sdl.GetCurrentRenderOutputSize(gm.displays[.Projection].renderer, &width, &height) do return

	// The fit rect is in framebuffer pixels; imgui works in points.
	fit := video_fit_rect(
		board.background.width > 0 ? board.background.width : int(width),
		board.background.height > 0 ? board.background.height : int(height),
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
		region := board.regions[team]
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

// Score positions as fractions of the background.
Score_Region :: struct {
	x, y, w, h: f32,
}
