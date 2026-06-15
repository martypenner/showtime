package state

import "core:testing"
import rl "vendor:raylib"

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
