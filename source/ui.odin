package game

import "core:log"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// UI-owned data lives here, next to the behavior that reads and mutates it. The
// shared GameMemory holds the controls (the hot-reload persistence shell) but
// the definitions are owned by the UI Module, so the dependency runs
// state -> ui and ui imports nothing from state.

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

VISIBLE_ON_ALL_GROUPS :: -1

Control :: struct {
	control_type:     Control_Type,
	ui_type:          UI_Type,
	visibility_group: int,
	name:             string,
	text:             cstring,
	rect:             rl.Rectangle,
	state:            Control_State,
}

Controls :: [dynamic; 512]Control

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
		return 0.5
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

ui_shutdown :: proc(controls: ^Controls) {
	for &control in controls {
		delete(control.name)
		delete(control.text)
		if text_state, ok := control.state.(Text_State); ok {
			delete(text_state.buffer)
		}
	}
}

control_is_visible :: proc(control: Control, active_group: int) -> bool {
	return(
		control.visibility_group == VISIBLE_ON_ALL_GROUPS ||
		control.visibility_group == active_group \
	)
}

controls_prepare_for_render :: proc(controls: []Control, render_width: i32, render_height: i32) {
	for &control in controls {
		#partial switch control.control_type {
		case .StatusBar:
			control.rect.x = 0
			control.rect.y = f32(render_height) - control.rect.height
			control.rect.width = f32(render_width)
		}
	}
}

layout_load :: proc(controls: ^Controls, name: string, source: string, group: int) {
	parsed, err := layout_parse(source)
	defer delete(parsed)
	if e, bad := err.?; bad {
		log.panicf("%s: %v at line %d: %q", name, e.kind, e.line, e.detail)
	}
	for &control in parsed {
		control.visibility_group = group
	}
	append(controls, ..parsed[:])
}

Anchor_Field :: enum {
	Tag, // 'a'
	Id,
	Name,
	Pos_X,
	Pos_Y,
	Enabled, // ignored for now
}

Component_Field :: enum {
	Tag, // 'c'
	Id,
	Type,
	Name,
	Rect_X,
	Rect_Y,
	Rect_W,
	Rect_H,
	Anchor_Id,
	Text,
}

Layout_Error_Kind :: enum {
	Too_Few_Fields,
	Invalid_Int,
	Invalid_Float,
}

Layout_Error :: struct {
	line:   int, // 1-based line number in the layout source
	kind:   Layout_Error_Kind,
	detail: string,
}

layout_parse :: proc(text: string) -> (controls: [dynamic]Control, err: Maybe(Layout_Error)) {
	controls = make([dynamic]Control)
	anchors := make(map[int][2]f32, context.temp_allocator)

	remaining := text
	line_no := 0
	for line in strings.split_lines_iterator(&remaining) {
		line_no += 1
		if len(line) == 0 {
			continue
		}

		#partial switch layout_str_to_item(line[0]) {
		case .Anchor:
			// a <id> <name> <posx> <posy> <enabled>
			parts := strings.split_n(line, " ", len(Anchor_Field), context.temp_allocator)
			if len(parts) < len(Anchor_Field) {
				return controls, Layout_Error{line_no, .Too_Few_Fields, line}
			}
			id := int_parse(parts[Anchor_Field.Id], line_no) or_return
			x := f32_parse(parts[Anchor_Field.Pos_X], line_no) or_return
			y := f32_parse(parts[Anchor_Field.Pos_Y], line_no) or_return
			anchors[id] = {x, y}

		case .Component:
			// c <id> <type> <name> <x> <y> <w> <h> <anchor_id> <text>
			parts := strings.split_n(line, " ", len(Component_Field), context.temp_allocator)
			if len(parts) < len(Component_Field) {
				return controls, Layout_Error{line_no, .Too_Few_Fields, line}
			}
			type := int_parse(parts[Component_Field.Type], line_no) or_return
			x := f32_parse(parts[Component_Field.Rect_X], line_no) or_return
			y := f32_parse(parts[Component_Field.Rect_Y], line_no) or_return
			w := f32_parse(parts[Component_Field.Rect_W], line_no) or_return
			h := f32_parse(parts[Component_Field.Rect_H], line_no) or_return
			anchor_id := int_parse(parts[Component_Field.Anchor_Id], line_no) or_return

			rect := rl.Rectangle{x, y, w, h}
			if anchor, has_anchor := anchors[anchor_id]; has_anchor {
				rect.x += anchor.x
				rect.y += anchor.y
			}
			control_type := Control_Type(type)

			append(
				&controls,
				Control {
					control_type = control_type,
					name = strings.clone(parts[Component_Field.Name]),
					text = strings.clone_to_cstring(parts[Component_Field.Text]),
					rect = rect,
					state = default_control_state(control_type),
				},
			)
		}
	}

	return controls, nil
}

@(private)
int_parse :: proc(s: string, line_no: int) -> (int, Maybe(Layout_Error)) {
	value, ok := strconv.parse_int(s)
	if !ok {
		return 0, Layout_Error{line_no, .Invalid_Int, s}
	}
	return value, nil
}

@(private)
f32_parse :: proc(s: string, line_no: int) -> (f32, Maybe(Layout_Error)) {
	value, ok := strconv.parse_f64(s)
	if !ok {
		return 0, Layout_Error{line_no, .Invalid_Float, s}
	}
	return f32(value), nil
}

@(private)
layout_str_to_item :: proc(s: u8) -> Layout_Item {
	switch s {
	case 'r':
		return Layout_Item.RefWindow
	case 'a':
		return Layout_Item.Anchor
	case 'c':
		return Layout_Item.Component
	case '#':
		return Layout_Item.Unknown
	case:
		log.debugf("Unknown layout item: %s", s)
		return Layout_Item.Unknown
	}
}
