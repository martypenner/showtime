package state

import "core:mem"
import rl "vendor:raylib"

Game_Memory :: struct {
	should_run:  bool,
	ui_arena:    mem.Dynamic_Arena,
	ui_controls: [dynamic]Control,
	playground:  struct {
		toggle_state:           struct {
			current: bool,
			prev:    bool,
		},
		toggle_group_active:    i32,
		toggle_slider_active:   i32,
		checked:                bool,
		text_box_buffer:        [dynamic]u8,
		text_box_editing:       bool,
		spinner:                i32,
		spinner_editing:        bool,
		slider_value:           f32,
		progress_value:         f32,
		visual_style:           i32,
		dropdown_active:        i32,
		dropdown_edit:          bool,
		active_cell:            rl.Vector2,
		active_tab:             i32,
		list_view_scroll_index: i32,
		list_view_active:       i32,
		color_picker_value:     rl.Color,
		text_input:             [dynamic]u8,
	},
}

Layout_Item :: enum u8 {
	RefWindow,
	Anchor,
	Component,
	Unknown,
}

Control_Type :: enum u8 {
	WindowBox,
	GroupBox,
	Line,
	Panel,
	Label,
	Button,
	LabelButton,
	CheckBox,
	Toggle,
	ToggleGroup,
	ComboBox,
	DropdownBox,
	TextBox,
	ValueBox,
	TextMultiBox,
	Spinner,
	Slider,
	SliderBar,
	ProgressBar,
	StatusBar,
	ScrollPanel,
	ListView,
	ColorPicker,
	DummyRect,
}

UI_Type :: enum u8 {
	Default,
	Destructive,
}

Control :: struct {
	control_type: Control_Type,
	ui_type:      UI_Type,
	name:         string,
	text:         cstring,
	rect:         rl.Rectangle,
	state:        Control_State,
}

// Mutable per-control state. Each control kind stores only the variant it
// needs; stateless controls (Button, Label, ...) leave this nil.

Choice_State :: struct {
	active:    i32,
	edit_mode: bool,
}
Number_State :: struct {
	value:     i32,
	edit_mode: bool,
}
Text_State :: struct {
	buffer:    [dynamic]u8,
	edit_mode: bool,
}
List_State :: struct {
	scroll_index: i32,
	active:       i32,
}
Scroll_State :: struct {
	scroll: rl.Vector2,
	view:   rl.Rectangle,
}

Control_State :: union {
	bool, // CheckBox, Toggle
	i32, // ToggleGroup, ComboBox
	f32, // Slider, SliderBar, ProgressBar
	rl.Color, // ColorPicker
	Choice_State, // DropdownBox
	Number_State, // Spinner, ValueBox
	Text_State, // TextBox
	List_State, // ListView
	Scroll_State, // ScrollPanel
}

// Returns the initial state variant a control needs, or nil if stateless.
default_control_state :: proc(type: Control_Type) -> Control_State {
	switch type {
	case .CheckBox, .Toggle:
		return false
	case .ToggleGroup, .ComboBox:
		return 0
	case .Slider, .SliderBar, .ProgressBar:
		return 0
	case .ColorPicker:
		return rl.Color{}
	case .DropdownBox:
		return Choice_State{}
	case .Spinner, .ValueBox:
		return Number_State{}
	case .TextBox:
		return Text_State{}
	case .ListView:
		return List_State{}
	case .ScrollPanel:
		return Scroll_State{}
	case .WindowBox,
	     .GroupBox,
	     .Line,
	     .Panel,
	     .Label,
	     .Button,
	     .LabelButton,
	     .TextMultiBox,
	     .StatusBar,
	     .DummyRect:
		return nil
	}
	return nil
}
