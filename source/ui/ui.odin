package ui

import "../sound"
import "../state"
import "core:log"
import "core:mem"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

draw :: proc(gm: ^state.GameMemory) {
	for &ui_control in gm.ui_controls {
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
			prev := rl.GuiGetStyle(
				rl.GuiControl.BUTTON,
				i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			)
			if ui_control.ui_type == .Destructive {
				rl.GuiSetStyle(
					rl.GuiControl.BUTTON,
					i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
					i32(rl.ColorToInt(rl.Color{100, 0, 0, 255})),
				)
			}
			button := rl.GuiButton(ui_control.rect, ui_control.text)
			rl.GuiSetStyle(
				rl.GuiControl.BUTTON,
				i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
				prev,
			)

			if button {
				log.debugf("clicked button %s", ui_control.name)
				if ui_control.name == "catmeow" {
					sound.play_sound("assets/sounds/fx/cat-meow.mp3")
				}
				if ui_control.name == "dropneedle" {
					sound.play_playlist("Needle Droppers", &gm.sound_settings)
				}
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

			control := state.Control {
				control_type = control_type,
				ui_type      = name == "dropneedle" ? .Destructive : .Default,
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
