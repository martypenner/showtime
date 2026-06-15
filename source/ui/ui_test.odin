package ui

import "core:mem"
import "core:testing"
import rl "vendor:raylib"

// Golden-style check: the committed layout.rgl must keep producing the same
// visible controls. build_layout is the Adapter Seam (external rGuiLayout format
// -> internal Control list), so asserting its output here pins parser behavior
// without reaching into private parsing helpers. Anchor offsets are folded into
// each rect, matching what the app renders. Enable/disable fields are
// deliberately not asserted: enable/disable semantics are out of scope.
@(test)
build_layout_matches_committed_golden :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	controls := build_layout(&arena)

	Expected :: struct {
		name: string,
		type: Control_Type,
		text: string,
		rect: rl.Rectangle,
	}
	// scenes anchor is at (24, 0); controls anchored to it have that offset
	// folded into their rect. anchor_id 0 means no anchor (no offset).
	expected := []Expected {
		{"preshow", .Button, "Pre-show", {24, 24, 96, 48}},
		{"postshow", .Button, "Post-show", {144, 24, 96, 48}},
		{"tohouse", .Button, "To house", {24, 96, 96, 48}},
		{"sceneramp", .Button, "Scene - ramp", {144, 96, 96, 48}},
		{"scenefade", .Button, "Scene - fade", {264, 96, 96, 48}},
		{"dropneedle", .Button, "Drop needle", {384, 96, 96, 48}},
		{"scenes", .GroupBox, "Scenes", {24, 8, 456, 136}},
		{"catmeow", .Button, "Cat meow", {24, 600, 96, 48}},
		{"volumelabel", .Label, "Volume", {504, 0, 144, 24}},
		{"statusbar", .StatusBar, "Status", {0, -24, 0, 24}},
		{"usehousemusic", .CheckBox, "Use house music", {264, 24, 24, 24}},
		{"mastervolume", .SliderBar, "", {504, 24, 144, 24}},
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
	}
}

// Malformed layout data must fail at the Adapter Seam with a clear, located
// error rather than an opaque index-out-of-range panic. parse_layout returns
// the error so the failure mode is testable at the Module Interface.
@(test)
parse_layout_reports_malformed_lines :: proc(t: ^testing.T) {
	{
		// Component line missing its rect/anchor/text fields.
		_, err := parse_layout("c 000 5 preshow 0 24 96", context.temp_allocator)
		e, bad := err.?
		testing.expect(t, bad, "expected an error for a truncated component line")
		testing.expect_value(t, e.kind, Layout_Error_Kind.Too_Few_Fields)
		testing.expect_value(t, e.line, 1)
	}
	{
		// Anchor position that is not a number.
		_, err := parse_layout("a 1 scenes x 0 1", context.temp_allocator)
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

@(test)
status_bars_appear_at_bottom :: proc(t: ^testing.T) {
	controls := [1]Control {
		{
			name = "statusbar",
			rect = rl.Rectangle{100, 100, 100, 100},
			state = default_control_state(.StatusBar),
			ui_type = .Default,
			control_type = .StatusBar,
			text = "",
		},
	}
	prepare_controls_for_render(controls[:], 100, 200)
	testing.expect(t, controls[0].rect == rl.Rectangle{0, 100, 100, 100})
}
