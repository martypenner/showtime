package game

import imgui "../vendor/odin-imgui"
import imsdlrenderer3 "../vendor/odin-imgui/imgui_impl_sdlrenderer3"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
panel_windows_preserve_navigation_and_resize_constraints :: proc(t: ^testing.T) {
	previous := imgui.GetCurrentContext()
	defer imgui.SetCurrentContext(previous)
	ui := imgui.CreateContext()
	defer imgui.DestroyContext(ui)
	io := imgui.GetIO()
	io.IniFilename = nil
	io.DisplaySize = {600, 320}
	io.DeltaTime = 1.0 / 60.0
	io.ConfigFlags += {.NavEnableKeyboard}
	imgui.IO_AddMousePosEvent(io, 100, 100)
	surface := sdl.CreateSurface(600, 320, .RGBA32)
	ensure(surface != nil)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	ensure(renderer != nil)
	defer sdl.DestroyRenderer(renderer)
	ensure(imsdlrenderer3.Init(renderer))
	defer imsdlrenderer3.Shutdown()

	frame := proc(
		focus_first: bool = false,
		first_rect: ^imgui.Rect = nil,
	) -> (
		focused: int,
		visible: bool,
	) {
		focused = -1
		imsdlrenderer3.NewFrame()
		imgui.NewFrame()
		if focus_first do imgui.SetWindowFocusStr("Show")
		imgui.SetNextWindowPos({0, 0})
		imgui.SetNextWindowSize({600, 320})
		imgui.Begin("Panel navigation test", nil, {.NoSavedSettings, .NoTitleBar})
		controls_layout_begin("Layout")
		imgui.Button("Toolbar")
		if imgui.IsItemFocused() {
			focused = -2
			visible = imgui.IsItemVisible()
		}
		for label, index in ([7]cstring{"Show", "Games", "Lighting", "Sounds", "Music", "Video", "Score slide"}) {
			controls_group_begin(label, imgui.GetCursorScreenPos(), 560)
			if index == 0 && first_rect != nil {
				first_rect^ = {imgui.GetWindowPos(), imgui.GetWindowPos() + imgui.GetWindowSize()}
			}
			list := index == 4 || index == 5
			if list do controls_list_begin("Items", 80)
			imgui.Button("Control")
			if imgui.IsItemFocused() {
				focused = index
				visible = imgui.IsItemVisible()
			}
			if list do imgui.EndChild()
			controls_group_end()
		}
		controls_layout_end()
		imgui.End()
		imgui.Render()
		return
	}

	for _ in 0 ..< 4 do frame()
	frame(true)
	frame()
	for key in ([2]imgui.Key{.Tab, .DownArrow}) {
		frame(true)
		focused_first, _ := frame()
		testing.expect_value(t, focused_first, 0)
		imgui.SetNavCursorVisible(true)
		for index in 1 ..< 7 {
			imgui.IO_AddKeyEvent(io, key, true)
			frame()
			imgui.IO_AddKeyEvent(io, key, false)
			frame()
			focused, visible := frame()
			testing.expect_value(t, focused, index)
			testing.expect(t, visible, "keyboard focus should scroll into view")
		}
		if key == .Tab {
			imgui.IO_AddKeyEvent(io, .Tab, true)
			frame()
			imgui.IO_AddKeyEvent(io, .Tab, false)
			frame()
			focused, visible := frame()
			testing.expect_value(t, focused, -2)
			testing.expect(t, visible, "tabbing past the final panel should return to the toolbar")
			imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, true)
			imgui.IO_AddKeyEvent(io, .Tab, true)
			frame()
			imgui.IO_AddKeyEvent(io, .Tab, false)
			frame()
			focused, visible = frame()
			testing.expect_value(t, focused, 6)
			testing.expect(
				t,
				visible,
				"reverse tabbing from the toolbar should reveal the final panel",
			)
			imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, false)
			frame()
		}
		for index := 5; index >= 0; index -= 1 {
			back := key == .Tab ? imgui.Key.Tab : imgui.Key.UpArrow
			if key == .Tab do imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, true)
			imgui.IO_AddKeyEvent(io, back, true)
			frame()
			imgui.IO_AddKeyEvent(io, back, false)
			frame()
			focused, visible := frame()
			testing.expect_value(t, focused, index)
			testing.expect(t, visible, "reverse keyboard focus should scroll into view")
			if key == .Tab do imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, false)
			frame()
		}
	}

	rect: imgui.Rect
	frame(first_rect = &rect)
	original := rect.Max - rect.Min
	grip := rect.Max - imgui.Vec2{4, 4}
	imgui.IO_AddMousePosEvent(io, grip.x, grip.y)
	frame()
	imgui.IO_AddMouseButtonEvent(io, 0, true)
	frame()
	imgui.IO_AddMousePosEvent(io, grip.x, grip.y + 60)
	frame()
	imgui.IO_AddMouseButtonEvent(io, 0, false)
	frame()
	frame(first_rect = &rect)
	resized := rect.Max - rect.Min
	testing.expect_value(t, resized.x, original.x)
	testing.expect_value(t, resized.y, original.y + 60)

	grip = rect.Max - imgui.Vec2{4, 4}
	imgui.IO_AddMousePosEvent(io, grip.x, grip.y)
	frame()
	imgui.IO_AddMouseButtonEvent(io, 0, true)
	frame()
	imgui.IO_AddMousePosEvent(io, grip.x, grip.y - 200)
	frame()
	imgui.IO_AddMouseButtonEvent(io, 0, false)
	frame()
	frame(first_rect = &rect)
	testing.expect_value(t, rect.Max.y - rect.Min.y, original.y)
}

@(test)
timers_windows_keep_imgui_stacks_balanced_when_clipped :: proc(t: ^testing.T) {
	arena: GameTestArena
	context.allocator = game_test_arena_init(&arena)
	defer context.allocator = game_test_arena_destroy(&arena)
	gm = game_memory_make()
	previous := imgui.GetCurrentContext()
	defer imgui.SetCurrentContext(previous)
	ui := imgui.CreateContext()
	defer imgui.DestroyContext(ui)
	io := imgui.GetIO()
	io.IniFilename = nil
	io.DeltaTime = 1.0 / 60.0

	surface := sdl.CreateSurface(600, 720, .RGBA32)
	ensure(surface != nil)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	ensure(renderer != nil)
	defer sdl.DestroyRenderer(renderer)
	ensure(imsdlrenderer3.Init(renderer))
	defer imsdlrenderer3.Shutdown()

	for height in ([4]f32{720, 250, 100, 720}) {
		io.DisplaySize = {600, height}
		for _ in 0 ..< 4 {
			imsdlrenderer3.NewFrame()
			imgui.NewFrame()
			imgui.SetNextWindowPos({0, 0})
			imgui.SetNextWindowSize(io.DisplaySize)
			imgui.Begin("Clipped timers test", nil, {.NoSavedSettings, .NoTitleBar})
			window := imgui.GetCurrentWindow()
			before, after: imgui.ErrorRecoveryState
			imgui.ErrorRecoveryStoreState(&before)
			timers_draw()
			imgui.ErrorRecoveryStoreState(&after)
			testing.expect(
				t,
				imgui.GetCurrentWindow() == window,
				"drawing timers should restore the caller's window even when lists are clipped",
			)
			testing.expect_value(t, after, before)
			imgui.End()
			imgui.Render()
		}
	}
}
