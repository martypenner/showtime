package game

import "core:testing"
import rl "vendor:raylib"

// Golden-style check: the committed controls.rgl must keep producing the same
// visible controls. load_layout is the Adapter Seam (external rGuiLayout format
// -> internal Control list), so asserting its output here pins parser behavior
// without reaching into private parsing helpers. Anchor offsets are folded into
// each rect, matching what the app renders. Enable/disable fields are
// deliberately not asserted: enable/disable semantics are out of scope. The
// group arg is arbitrary here; it just proves load_layout tags every control
// with the group it was given.
@(test)
load_layout_matches_committed_golden :: proc(t: ^testing.T) {
	GROUP :: 7
	controls: Controls
	defer ui_shutdown(&controls)
	layout_load(&controls, "controls.rgl", string(#load("../resources/controls.rgl")), GROUP)
	controls_prepare_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())

	Expected :: struct {
		name: string,
		type: Control_Type,
		text: string,
		rect: rl.Rectangle,
	}
	// scenes anchor is at (24, 48); controls anchored to it have that offset
	// folded into their rect. anchor_id 0 means no anchor (no offset).
	expected := []Expected {
		{"Pre_Show", .Button, "Pre-show", {24, 72, 96, 48}},
		{"Post_Show", .Button, "Post-show", {144, 72, 96, 48}},
		{"To_House", .Button, "To house", {24, 144, 96, 48}},
		{"Scene_Ramp", .Button, "Scene - ramp", {144, 144, 96, 48}},
		{"Scene_Fade", .Button, "Scene - fade", {264, 144, 96, 48}},
		{"Drop_Needle", .Button, "Drop needle", {384, 144, 96, 48}},
		{"Scenes", .GroupBox, "Scenes", {24, 56, 456, 136}},
		{"Cat_Meow", .Button, "Cat meow", {24, 552, 96, 48}},
		{"Volume_Label", .Label, "Volume", {504, 48, 144, 24}},
		{"Use_House_Music", .CheckBox, "Use house music", {264, 72, 24, 24}},
		{"Music_Volume", .SliderBar, "", {504, 72, 144, 24}},
	}

	testing.expect_value(t, len(controls), len(expected))
	if len(controls) != len(expected) {
		return
	}

	for exp, i in expected {
		got := controls[i]
		testing.expect_value(t, got.name, exp.name)
		testing.expect_value(t, got.control_type, exp.type)
		testing.expect_value(t, string(got.text), exp.text)
		testing.expect_value(t, got.rect, exp.rect)
		testing.expect_value(t, got.visibility_group, GROUP)
	}
}

// Malformed layout data must fail at the Adapter Seam with a clear, located
// error rather than an opaque index-out-of-range panic. parse_layout returns
// the error so the failure mode is testable at the Module Interface.
@(test)
parse_layout_reports_malformed_lines :: proc(t: ^testing.T) {
	{
		// Component line missing its rect/anchor/text fields.
		_, err := layout_parse("c 000 5 preshow 0 24 96")
		e, bad := err.?
		testing.expect(t, bad, "expected an error for a truncated component line")
		testing.expect_value(t, e.kind, Layout_Error_Kind.Too_Few_Fields)
		testing.expect_value(t, e.line, 1)
	}
	{
		// Anchor position that is not a number.
		_, err := layout_parse("a 1 scenes x 0 1")
		e, bad := err.?
		testing.expect(t, bad, "expected an error for a non-numeric anchor field")
		testing.expect_value(t, e.kind, Layout_Error_Kind.Invalid_Float)
		testing.expect_value(t, e.line, 1)
	}
}

// Each control kind reads exactly one state variant while rendering, so
// default_control_state must seed that same variant up front. A mismatch would
// surface as a union type-assertion panic the first time the control is drawn.
// This locks the control-type -> state-variant contract at the Module Interface
// without needing Raylib's renderer.
@(test)
default_control_state_matches_each_control_type :: proc(t: ^testing.T) {
	expect_variant :: proc(t: ^testing.T, type: Control_Type, $T: typeid) {
		s := default_control_state(type)
		_, ok := s.(T)
		testing.expectf(t, ok, "%v: expected state variant %v, got %v", type, typeid_of(T), s)
	}

	expect_stateless :: proc(t: ^testing.T, type: Control_Type) {
		s := default_control_state(type)
		testing.expectf(t, s == nil, "%v: expected stateless (nil) state, got %v", type, s)
	}

	expect_variant(t, .CheckBox, bool)
	expect_variant(t, .Toggle, bool)
	expect_variant(t, .ToggleGroup, i32)
	expect_variant(t, .ComboBox, i32)
	expect_variant(t, .Slider, f32)
	expect_variant(t, .SliderBar, f32)
	expect_variant(t, .ProgressBar, f32)
	expect_variant(t, .ColorPicker, rl.Color)
	expect_variant(t, .DropdownBox, Choice_State)
	expect_variant(t, .Spinner, Number_State)
	expect_variant(t, .ValueBox, Number_State)
	expect_variant(t, .TextBox, Text_State)
	expect_variant(t, .ListView, List_State)
	expect_variant(t, .ScrollPanel, Scroll_State)

	expect_stateless(t, .WindowBox)
	expect_stateless(t, .GroupBox)
	expect_stateless(t, .Line)
	expect_stateless(t, .Panel)
	expect_stateless(t, .Label)
	expect_stateless(t, .Button)
	expect_stateless(t, .LabelButton)
	expect_stateless(t, .TextMultiBox)
	expect_stateless(t, .StatusBar)
	expect_stateless(t, .DummyRect)
}

// Tabs are realized by filtering the draw loop: a control renders only when its
// visibility_group matches the active group, except chrome marked
// VISIBLE_ON_ALL_GROUPS which renders everywhere. The ui layer stays
// app-agnostic (it compares integer groups, not tab names), so pinning
// control_visible here locks that contract without Raylib drawing.
@(test)
control_visible_filters_by_active_group :: proc(t: ^testing.T) {
	on_group :: proc(group: int) -> Control {
		return Control{visibility_group = group}
	}

	testing.expect(t, control_is_visible(on_group(0), 0), "group 0 visible on group 0")
	testing.expect(t, !control_is_visible(on_group(0), 1), "group 0 hidden on group 1")
	testing.expect(t, control_is_visible(on_group(1), 1), "group 1 visible on group 1")
	testing.expect(
		t,
		control_is_visible(on_group(VISIBLE_ON_ALL_GROUPS), 0),
		"chrome visible on group 0",
	)
	testing.expect(
		t,
		control_is_visible(on_group(VISIBLE_ON_ALL_GROUPS), 1),
		"chrome visible on group 1",
	)
}

@(test)
status_bars_appear_at_bottom :: proc(t: ^testing.T) {
	controls := [1]Control {
		{
			name = "Status_Bar",
			rect = rl.Rectangle{100, 100, 100, 100},
			state = default_control_state(.StatusBar),
			ui_type = .Default,
			control_type = .StatusBar,
			text = "",
		},
	}
	controls_prepare_for_render(controls[:], 100, 200)
	testing.expect(t, controls[0].rect == rl.Rectangle{0, 100, 100, 100})
}
