package ui

import "../state"
import "core:log"
import "core:mem"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

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
draw :: proc(gm: ^state.GameMemory) -> [dynamic]UI_Event {
	events := make([dynamic]UI_Event, context.temp_allocator)

	for &ui_control in gm.ui_controls {
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
render_control :: proc(control: ^state.Control) -> Maybe(UI_Event) {
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
			log.debugf("clicked label button %s", control.text)
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
			log.debugf("clicked button %s", control.name)
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
		s := &control.state.(state.Choice_State)
		if (rl.GuiDropdownBox(control.rect, control.text, &s.active, s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .TextBox:
		s := &control.state.(state.Text_State)
		if (rl.GuiTextBox(control.rect, cstring(&s.buffer[0]), i32(len(s.buffer)), s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .ValueBox:
		s := &control.state.(state.Number_State)
		if (rl.GuiValueBox(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .TextMultiBox:
	case .Spinner:
		s := &control.state.(state.Number_State)
		if (rl.GuiSpinner(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .Slider:
		rl.GuiSlider(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .SliderBar:
		rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
		return UI_Event {
			name = control.name,
			kind = .Value_Changed,
			value = control.state.(f32),
		}
	case .ProgressBar:
		rl.GuiProgressBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .StatusBar:
		rl.GuiStatusBar(control.rect, control.text)
	case .ScrollPanel:
		s := &control.state.(state.Scroll_State)
		rl.GuiScrollPanel(control.rect, control.text, control.rect, &s.scroll, &s.view)
	case .ListView:
		s := &control.state.(state.List_State)
		rl.GuiListView(control.rect, control.text, &s.scroll_index, &s.active)
	case .ColorPicker:
		rl.GuiColorPicker(control.rect, control.text, &control.state.(rl.Color))
	case .DummyRect:
		rl.GuiDummyRec(control.rect, control.text)
	}

	return nil
}

build_layout :: proc(arena: ^mem.Dynamic_Arena) -> [dynamic]state.Control {
	alloc := mem.dynamic_arena_allocator(arena)

	bytes := #load("../../resources/layout.rgl")
	lines := string(bytes)

	anchors := make(map[int][2]f32)
	defer delete(anchors)
	ui_controls := make([dynamic]state.Control, alloc)

	for line in strings.split_lines_iterator(&lines) {
		type := str_to_layout_item(line[0])
		#partial switch type {
		case state.Layout_Item.Anchor:
			parts := strings.split(line, " ", context.temp_allocator)
			id_str, x, y := parts[1], atof32(parts[3]), atof32(parts[4])
			id, ok := strconv.parse_int(id_str)
			log.ensuref(ok, "Error parsing control type: %s", id_str)
			anchors[id] = [2]f32{x, y}
		case state.Layout_Item.Component:
			parts := strings.split_n(line[2:], " ", 9, context.temp_allocator)
			type_str, name := parts[1], parts[2]
			type, ok := strconv.parse_int(type_str)
			log.ensuref(ok, "Error parsing control type: %s", type_str)
			control_type := state.Control_Type(type)

			x, y, w, h := atof32(parts[3]), atof32(parts[4]), atof32(parts[5]), atof32(parts[6])
			rect := rl.Rectangle{x, y, w, h}
			anchor_id_str, text := parts[7], parts[8]
			anchor_id, anchor_id_ok := strconv.parse_int(anchor_id_str)
			log.ensuref(anchor_id_ok, "Error parsing anchor id: %s", anchor_id_str)
			anchor, has_anchor := anchors[anchor_id]
			if has_anchor {
				rect.x += anchor.x
				rect.y += anchor.y
			}
			log.debugf(
				"control_type: %s, name: %s, text: %s, anchor_id: %i, %v",
				control_type,
				name,
				text,
				anchor_id,
				rect,
			)

			// Presentation style (e.g. destructive) is an app-owned decision
			// applied after parsing; generic layout parsing stays neutral.
			control := state.Control {
				control_type = control_type,
				name         = strings.clone(name, alloc),
				text         = strings.clone_to_cstring(text, alloc),
				rect         = rect,
				state        = state.default_control_state(control_type),
			}
			append(&ui_controls, control)
		}
	}

	return ui_controls
}

str_to_layout_item :: proc(s: u8) -> state.Layout_Item {
	switch s {
	case 'r':
		return state.Layout_Item.RefWindow
	case 'a':
		return state.Layout_Item.Anchor
	case 'c':
		return state.Layout_Item.Component
	case '#':
		return state.Layout_Item.Unknown
	case:
		log.debugf("Unknown layout item: %s", s)
		return state.Layout_Item.Unknown
	}
}

atof32 :: proc(s: string) -> f32 {
	res, ok := strconv.parse_f64(s)
	log.ensuref(ok, "Error parsing float: %s", s)
	return f32(res)
}
