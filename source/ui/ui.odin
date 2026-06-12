package ui

import "../state"
import "core:log"
import vmem "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

draw :: proc(ui_controls: [dynamic]state.Control) {
	for &ui_control in ui_controls {
		switch ui_control.control_type {
		case .WindowBox:
			rl.GuiWindowBox(ui_control.rect, ui_control.text)
		case .GroupBox:
			rl.GuiGroupBox(ui_control.rect, ui_control.text)
		case .Line:
			rl.GuiLine(ui_control.rect, ui_control.text)
		case .Panel:
			rl.GuiPanel(ui_control.rect, ui_control.text)
		case .Label:
			rl.GuiLabel(ui_control.rect, ui_control.text)
		case .LabelButton:
			if (rl.GuiLabelButton(ui_control.rect, ui_control.text)) {
				log.debugf("clicked label button %s", ui_control.text)
			}
		case .Button:
			if (rl.GuiButton(ui_control.rect, ui_control.text)) {
				log.debugf("clicked button %s", ui_control.text)
			}
		case .CheckBox:
			rl.GuiCheckBox(ui_control.rect, ui_control.text, &ui_control.state.(bool))
		case .Toggle:
			rl.GuiToggle(ui_control.rect, ui_control.text, &ui_control.state.(bool))
		case .ToggleGroup:
			rl.GuiToggleGroup(ui_control.rect, ui_control.text, &ui_control.state.(i32))
		case .ComboBox:
			rl.GuiComboBox(ui_control.rect, ui_control.text, &ui_control.state.(i32))
		case .DropdownBox:
			s := &ui_control.state.(state.Choice_State)
			if (rl.GuiDropdownBox(ui_control.rect, ui_control.text, &s.active, s.edit_mode)) {
				s.edit_mode = !s.edit_mode
			}
		case .TextBox:
			s := &ui_control.state.(state.Text_State)
			if (rl.GuiTextBox(
					   ui_control.rect,
					   cstring(&s.buffer[0]),
					   i32(len(s.buffer)),
					   s.edit_mode,
				   )) {
				s.edit_mode = !s.edit_mode
			}
		case .ValueBox:
			s := &ui_control.state.(state.Number_State)
			if (rl.GuiValueBox(ui_control.rect, ui_control.text, &s.value, 0, 100, s.edit_mode)) >
			   0 {
				s.edit_mode = !s.edit_mode
			}
		case .TextMultiBox:
		case .Spinner:
			s := &ui_control.state.(state.Number_State)
			if (rl.GuiSpinner(ui_control.rect, ui_control.text, &s.value, 0, 100, s.edit_mode)) >
			   0 {
				s.edit_mode = !s.edit_mode
			}
		case .Slider:
			rl.GuiSlider(ui_control.rect, ui_control.text, nil, &ui_control.state.(f32), 0, 100)
		case .SliderBar:
			rl.GuiSliderBar(ui_control.rect, ui_control.text, nil, &ui_control.state.(f32), 0, 100)
		case .ProgressBar:
			rl.GuiProgressBar(ui_control.rect, ui_control.text, nil, &ui_control.state.(f32), 0, 1)
		case .StatusBar:
			rl.GuiStatusBar(ui_control.rect, ui_control.text)
		case .ScrollPanel:
			s := &ui_control.state.(state.Scroll_State)
			rl.GuiScrollPanel(
				ui_control.rect,
				ui_control.text,
				ui_control.rect,
				&s.scroll,
				&s.view,
			)
		case .ListView:
			s := &ui_control.state.(state.List_State)
			rl.GuiListView(ui_control.rect, ui_control.text, &s.scroll_index, &s.active)
		case .ColorPicker:
			rl.GuiColorPicker(ui_control.rect, ui_control.text, &ui_control.state.(rl.Color))
		case .DummyRect:
			rl.GuiDummyRec(ui_control.rect, ui_control.text)
		}
	}
}

build_layout :: proc(gm: ^state.Game_Memory) {
	vmem.arena_free_all(&gm.ui_arena)
	alloc := vmem.arena_allocator(&gm.ui_arena)

	bytes, err := os.read_entire_file("resources/layout.rgl", context.temp_allocator)
	log.ensuref(err == nil, "Error reading layout file")
	lines := string(bytes)

	anchors := make(map[int][2]f32)
	defer delete(anchors)
	ui_controls := make([dynamic]state.Control, alloc)

	for line in strings.split_lines_iterator(&lines) {
		type := str_to_layout_item(line[0])
		#partial switch type {
		case state.Layout_Item.Anchor:
			parts := strings.split(line, " ")
			defer delete(parts)

			id_str, x, y := parts[1], atof32(parts[3]), atof32(parts[4])
			id, ok := strconv.parse_int(id_str)
			log.ensuref(ok, "Error parsing control type: %s", id_str)
			anchors[id] = [2]f32{x, y}
		case state.Layout_Item.Component:
			parts := strings.split_n(line[2:], " ", 9)
			defer delete(parts)

			type_str := parts[1]
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
				"control_type: %s, text: %s, anchor_id: %i, %v",
				control_type,
				text,
				anchor_id,
				rect,
			)

			control := state.Control {
				control_type = control_type,
				text         = strings.clone_to_cstring(text, alloc),
				rect         = rect,
				state        = state.default_control_state(control_type),
			}
			append(&ui_controls, control)
		}
	}
	gm.ui_controls = ui_controls
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
