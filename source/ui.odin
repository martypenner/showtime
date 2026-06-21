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

UI_Event_Kind :: enum u8 {
	Clicked,
	Value_Changed,
}

UI_Event :: struct {
	name:  string,
	kind:  UI_Event_Kind,
	value: f32,
}

UI_Events :: [dynamic; 64]UI_Event

ui_draw :: proc(controls: []Control, active_group: int) -> UI_Events {
	events: UI_Events

	for &ui_control in controls {
		if !control_is_visible(ui_control, active_group) {
			continue
		}
		if event, ok := control_render(&ui_control).?; ok {
			append(&events, event)
		}
	}

	return events
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

control_render :: proc(control: ^Control) -> Maybe(UI_Event) {
	switch control.control_type {
	case .WindowBox:
		rl.GuiWindowBox(control.rect, control.text)
	case .GroupBox:
		rl.GuiGroupBox(control.rect, control.text)
	case .Line:
		rl.GuiLine(control.rect, control.text)
	case .Panel:
		rl.GuiPanel(control.rect, control.text)
	case .Label:
		rl.GuiLabel(control.rect, control.text)
	case .LabelButton:
		if (rl.GuiLabelButton(control.rect, control.text)) {
			log.debugf("Clicked label button %s", control.text)
		}
	case .Button:
		prev := rl.GuiGetStyle(rl.GuiControl.BUTTON, i32(rl.GuiControlProperty.BASE_COLOR_NORMAL))
		if control.ui_type == .Destructive {
			rl.GuiSetStyle(
				rl.GuiControl.BUTTON,
				i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
				i32(rl.ColorToInt(rl.Color{100, 0, 0, 255})),
			)
		}
		button := rl.GuiButton(control.rect, control.text)
		rl.GuiSetStyle(rl.GuiControl.BUTTON, i32(rl.GuiControlProperty.BASE_COLOR_NORMAL), prev)

		if button {
			log.debugf("Clicked button %s", control.name)
			return UI_Event{name = control.name, kind = .Clicked}
		}
	case .CheckBox:
		rl.GuiCheckBox(control.rect, control.text, &control.state.(bool))
	case .Toggle:
		rl.GuiToggle(control.rect, control.text, &control.state.(bool))
	case .ToggleGroup:
		prev_state := control.state.(i32)
		rl.GuiToggleGroup(control.rect, control.text, &control.state.(i32))
		if prev_state != control.state.(i32) {
			return UI_Event {
				name = control.name,
				kind = .Value_Changed,
				value = f32(control.state.(i32)),
			}
		}
	case .ComboBox:
		rl.GuiComboBox(control.rect, control.text, &control.state.(i32))
	case .DropdownBox:
		s := &control.state.(Choice_State)
		if (rl.GuiDropdownBox(control.rect, control.text, &s.active, s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .TextBox:
		s := &control.state.(Text_State)
		if (rl.GuiTextBox(control.rect, cstring(&s.buffer[0]), i32(len(s.buffer)), s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .ValueBox:
		s := &control.state.(Number_State)
		if (rl.GuiValueBox(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .TextMultiBox:
	case .Spinner:
		s := &control.state.(Number_State)
		if (rl.GuiSpinner(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .Slider:
		rl.GuiSlider(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .SliderBar:
		prev_state := control.state.(f32)
		rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
		if prev_state != control.state.(f32) {
			return UI_Event {
				name = control.name,
				kind = .Value_Changed,
				value = control.state.(f32),
			}
		}
	case .ProgressBar:
		rl.GuiProgressBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .StatusBar:
		rl.GuiStatusBar(control.rect, control.text)
	case .ScrollPanel:
		s := &control.state.(Scroll_State)
		rl.GuiScrollPanel(control.rect, control.text, control.rect, &s.scroll, &s.view)
	case .ListView:
		s := &control.state.(List_State)
		rl.GuiListView(control.rect, control.text, &s.scroll_index, &s.active)
	case .ColorPicker:
		rl.GuiColorPicker(control.rect, control.text, &control.state.(rl.Color))
	case .DummyRect:
		rl.GuiDummyRec(control.rect, control.text)
	}

	return nil
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

ui_volume_set_value :: proc(value: f32, controls: []Control) {
	for &control in controls {
		if control.name != "Music_Volume" do continue
		control.state = value
		return
	}
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
