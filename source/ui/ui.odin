package ui

import "core:log"
import "core:mem"
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
		return 1.0
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

// What a control reported this frame. Generic rendering stays free of
// app-specific behavior: it names the control and the kind of interaction, and
// the app layer decides what (if anything) that means.
UI_Event_Kind :: enum u8 {
	Clicked,
	Value_Changed,
}

UI_Event :: struct {
	name:  string,
	kind:  UI_Event_Kind,
	value: f32,
}

// Renders the controls and returns the interactions observed this frame. Events
// are allocated in the temp allocator, so callers must consume them before the
// end-of-frame temp reset.
//
// This is the thin interaction-collection phase: per-control Raygui drawing and
// Raygui-owned state handling live in render_control, so this loop only gathers
// the events the app layer needs to act on.
draw :: proc(controls: []Control) -> [dynamic]UI_Event {
	events := make([dynamic]UI_Event, context.temp_allocator)

	for &ui_control in controls {
		if event, ok := render_control(&ui_control).?; ok {
			append(&events, event)
		}
	}

	return events
}

// Renders a single control with Raygui and applies any Raygui-owned state
// changes (edit-mode toggles, slider values, ...) back to the control. This is
// where Raygui-specific handling is hidden; it reports an interaction to the app
// layer by returning a UI_Event, or nil when the control did nothing this frame.
render_control :: proc(control: ^Control) -> Maybe(UI_Event) {
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
		rl.GuiToggleGroup(control.rect, control.text, &control.state.(i32))
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
		rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
		return UI_Event{name = control.name, kind = .Value_Changed, value = control.state.(f32)}
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

prepare_controls_for_render :: proc(controls: []Control, render_width: i32, render_height: i32) {
	for &control in controls {
		#partial switch control.control_type {
		case .StatusBar:
			control.rect.x = 0
			control.rect.y = f32(render_height) - control.rect.height
			control.rect.width = f32(render_width)
		}
	}
}

// build_layout is the Adapter Seam: it loads the committed rGuiLayout file and
// turns it into the internal Control list. Malformed layout data is a build-time
// asset bug, so a parse failure aborts loudly here with a located message rather
// than producing a half-built UI.
build_layout :: proc(arena: ^mem.Dynamic_Arena) -> [dynamic]Control {
	bytes := #load("../../resources/layout.rgl")
	controls, err := parse_layout(string(bytes), mem.dynamic_arena_allocator(arena))
	if e, bad := err.?; bad {
		log.panicf("layout.rgl: %v at line %d: %q", e.kind, e.line, e.detail)
	}
	prepare_controls_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	return controls
}

// Field positions within an rGuiLayout record line. Naming the positions keeps
// parsing intent clear instead of relying on bare numeric indices, and the enum
// length doubles as the minimum field count each record needs.
Anchor_Field :: enum {
	Tag, // 'a'
	Id,
	Name,
	Pos_X,
	Pos_Y,
	Enabled, // ignored: enable/disable is out of scope
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

// Parses the rGuiLayout text format into internal controls. Anchor offsets are
// folded into each control's rect so callers receive ready-to-render rects.
// Enable/disable fields (anchor <enabled>) are parsed past but never acted on;
// changing visibility/activation is out of scope. Returns a located error
// instead of panicking so the Adapter's failure mode is testable.
parse_layout :: proc(
	text: string,
	allocator: mem.Allocator,
) -> (
	controls: [dynamic]Control,
	err: Maybe(Layout_Error),
) {
	controls = make([dynamic]Control, allocator)
	anchors := make(map[int][2]f32, context.temp_allocator)

	remaining := text
	line_no := 0
	for line in strings.split_lines_iterator(&remaining) {
		line_no += 1
		if len(line) == 0 {
			continue
		}

		#partial switch str_to_layout_item(line[0]) {
		case .Anchor:
			// a <id> <name> <posx> <posy> <enabled>
			parts := strings.split_n(line, " ", len(Anchor_Field), context.temp_allocator)
			if len(parts) < len(Anchor_Field) {
				return controls, Layout_Error{line_no, .Too_Few_Fields, line}
			}
			id := parse_int(parts[Anchor_Field.Id], line_no) or_return
			x := parse_f32(parts[Anchor_Field.Pos_X], line_no) or_return
			y := parse_f32(parts[Anchor_Field.Pos_Y], line_no) or_return
			anchors[id] = {x, y}

		case .Component:
			// c <id> <type> <name> <x> <y> <w> <h> <anchor_id> <text>
			parts := strings.split_n(line, " ", len(Component_Field), context.temp_allocator)
			if len(parts) < len(Component_Field) {
				return controls, Layout_Error{line_no, .Too_Few_Fields, line}
			}
			type := parse_int(parts[Component_Field.Type], line_no) or_return
			x := parse_f32(parts[Component_Field.Rect_X], line_no) or_return
			y := parse_f32(parts[Component_Field.Rect_Y], line_no) or_return
			w := parse_f32(parts[Component_Field.Rect_W], line_no) or_return
			h := parse_f32(parts[Component_Field.Rect_H], line_no) or_return
			anchor_id := parse_int(parts[Component_Field.Anchor_Id], line_no) or_return

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
					name = strings.clone(parts[Component_Field.Name], allocator),
					text = strings.clone_to_cstring(parts[Component_Field.Text], allocator),
					rect = rect,
					state = default_control_state(control_type),
				},
			)
		}
	}

	return controls, nil
}

@(private)
parse_int :: proc(s: string, line_no: int) -> (int, Maybe(Layout_Error)) {
	value, ok := strconv.parse_int(s)
	if !ok {
		return 0, Layout_Error{line_no, .Invalid_Int, s}
	}
	return value, nil
}

@(private)
parse_f32 :: proc(s: string, line_no: int) -> (f32, Maybe(Layout_Error)) {
	value, ok := strconv.parse_f64(s)
	if !ok {
		return 0, Layout_Error{line_no, .Invalid_Float, s}
	}
	return f32(value), nil
}

str_to_layout_item :: proc(s: u8) -> Layout_Item {
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
