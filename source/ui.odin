package game

import hm "core:container/handle_map"
import "core:log"
import "core:math"
import "core:slice"
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
	SoundAndLighting,
	Destructive,
	Sound,
	Lighting,
	Game,
	Innuendo,
}

VISIBLE_ON_ALL_GROUPS :: -1

Control :: struct {
	control_type:     Control_Type,
	ui_type:          UI_Type,
	visibility_group: int,
	name:             string,
	name_id:          ControlName,
	text:             cstring,
	rect:             rl.Rectangle,
	state:            Control_State,
}

Controls :: [dynamic]Control

CONTROL_INDEX_MISSING :: -1

UIControls :: struct {
	items:  Controls,
	lookup: [ControlName]int,
}

ui_controls_make :: proc(items: Controls) -> UIControls {
	ui := UIControls {
		items = items,
	}
	for &index in ui.lookup do index = CONTROL_INDEX_MISSING
	for control, index in ui.items {
		ui.lookup[control.name_id] = index
	}
	return ui
}

ui_control_get :: proc(ui: ^UIControls, name: ControlName) -> ^Control {
	index := ui.lookup[name]
	if index == CONTROL_INDEX_MISSING do return nil
	return &ui.items[index]
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
ListStateItems :: [dynamic; 512]cstring

List_State :: struct {
	scroll_index: i32,
	active:       i32,
	items:        ListStateItems,
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

			name := parts[Component_Field.Name]
			append(
				&controls,
				Control {
					control_type = control_type,
					name = strings.clone(name),
					name_id = control_name_from_string(name),
					text = strings.clone_to_cstring(parts[Component_Field.Text]),
					rect = rect,
					state = default_control_state(control_type),
				},
			)
		}
	}

	return controls, nil
}

control_button_pressed :: proc(control: ^Control) -> bool {
	color_base_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
	)
	color_focused_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
	)
	text_base_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
	)
	text_focused_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
	)

	switch control.ui_type {
	case .Destructive:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{100, 0, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{120, 0, 0, 255})),
		)
	case .Sound:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{0, 80, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{0, 100, 0, 255})),
		)
	case .Lighting:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{160, 180, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{180, 200, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.DARKGRAY)),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.DARKGRAY)),
		)
	case .SoundAndLighting:
	// default teal
	case .Game:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{0, 69, 129, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{0, 111, 208, 255})),
		)
	case .Innuendo:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{136, 51, 101, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{207, 80, 154, 255})),
		)
	}

	pressed := rl.GuiButton(control.rect, control.text)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
		color_base_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
		color_focused_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
		text_base_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
		text_focused_prev,
	)

	if pressed {
		log.debugf("Clicked button %s", control.name)
	}
	return pressed
}

control_draw_passive :: proc(control: ^Control) {
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
		rl.GuiLabelButton(control.rect, control.text)
	case .Button:
		control_button_pressed(control)
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
	case .ProgressBar:
		rl.GuiProgressBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .StatusBar:
		if control.name_id == .Status_Bar {
			music_progress := music_current_progress()
			music_played, music_length := music_current_time()
			music_time_text := music_time_pair_label(music_played, music_length)
			progress_rect := rl.Rectangle {
				x      = control.rect.x + control.rect.width - 160,
				y      = control.rect.y + 4,
				width  = 150,
				height = control.rect.height - 8,
			}
			TIME_LABEL_WIDTH :: f32(90)
			time_rect := rl.Rectangle {
				x      = progress_rect.x - TIME_LABEL_WIDTH - 8,
				y      = control.rect.y,
				width  = TIME_LABEL_WIDTH,
				height = control.rect.height,
			}
			rl.GuiStatusBar(
				control.rect,
				strings.clone_to_cstring(music_current_label(), context.temp_allocator),
			)
			rl.GuiProgressBar(progress_rect, nil, nil, &music_progress, 0, 1)
			rl.GuiLabel(
				time_rect,
				strings.clone_to_cstring(music_time_text, context.temp_allocator),
			)
		} else {
			rl.GuiStatusBar(control.rect, control.text)
		}
	case .ScrollPanel:
		s := &control.state.(Scroll_State)
		rl.GuiScrollPanel(control.rect, control.text, control.rect, &s.scroll, &s.view)
	case .ListView:
		s := &control.state.(List_State)
		rl.GuiListViewEx(
			control.rect,
			raw_data(s.items[:]),
			i32(len(s.items)),
			&s.scroll_index,
			&s.active,
			nil,
		)
	case .ColorPicker:
		rl.GuiColorPicker(control.rect, control.text, &control.state.(rl.Color))
	case .DummyRect:
		rl.GuiDummyRec(control.rect, control.text)
	}
}

Tab :: enum int {
	Controls,
	Music,
}

layout_build :: proc() -> Controls {
	controls: Controls

	// Per-tab content first, then chrome, so the persistent controls draw on top.
	layout_load(
		&controls,
		"controls.rgl",
		string(#load("../resources/controls.rgl")),
		int(Tab.Controls),
	)
	layout_load(&controls, "music.rgl", string(#load("../resources/music.rgl")), int(Tab.Music))
	layout_load(
		&controls,
		"chrome.rgl",
		string(#load("../resources/chrome.rgl")),
		VISIBLE_ON_ALL_GROUPS,
	)

	controls_prepare_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	return controls
}

// Resolves a layout control name to its presentation style. Destructive styling
// is an app concern (which controls are dangerous to the show), so this mapping
// lives here rather than in generic UI/layout code. Keeping it pure lets the
// styling Seam be verified without Raylib drawing.
ui_resolve_type :: proc(action: ControlName) -> UI_Type {
	#partial switch action {
	case .Drop_Needle:
		return .Destructive
	case .Innuendo:
		return .Innuendo
	case .Oscar_Moment:
		return .Game
	case .Glass_Break,
	     .Gunshot,
	     .Scream,
	     .Lightning,
	     .Yeeeeaaaaaaaahh,
	     .Tick_Tick_Ding,
	     .Ding,
	     .Fireworks,
	     .Train_Horn,
	     .Calming_Rain,
	     .Cat_Meow:
		return .Sound
	case .RainbowSting:
		return .Lighting
	case:
		return .SoundAndLighting
	}
}

controls_draw :: proc() {
	for &control in gm.ui.items {
		if !control_is_visible(control, gm.active_tab) {
			continue
		}

		action := control.name_id

		// Controls draw themselves here and immediately handle their app behavior.
		// Only controls that mutate persisted settings save them; tab switches and
		// one-shot sounds remain transient.
		#partial switch action {
		case .Tab_Bar:
			prev := control.state.(i32)
			rl.GuiToggleGroup(control.rect, control.text, &control.state.(i32))
			if prev != control.state.(i32) {
				index := int(control.state.(i32))
				switch Tab(index) {
				case .Controls, .Music:
					gm.active_tab = index
				case:
					gm.active_tab = int(Tab.Controls)
				}
			}
		case .Music_Volume:
			prev := control.state.(f32)
			rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
			if prev != control.state.(f32) {
				gm.sound_settings.music_volume = control.state.(f32)
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					voice.volume = control.state.(f32)
				}
				sound_settings_save()
			}
		case .Use_House_Music:
			prev := control.state.(bool)
			rl.GuiCheckBox(control.rect, control.text, &control.state.(bool))
			if prev != control.state.(bool) {
				use_house_music := control.state.(bool)
				if use_house_music {
					if gm.sound_settings.current_playing_playlist == nil {
						playlist := playlist_find_by_name(.Easy_Listening)
						ensure(playlist != nil, "Couldn't find playlist for Use_House_Music")

						track := playlist_pick_track(playlist)
						ensure(track != nil, "Couldn't pick track for Use_House_Music")

						new_voice := music_start_playlist_track(
							playlist,
							track,
							0.2,
							gm.sound_settings.fade_in_time,
							0,
							gm.sound_settings.fade_out_time,
						)
						if new_voice != nil {
							music_voices_fade_out_except(
								new_voice,
								gm.sound_settings.fade_out_time,
							)
						}
					}
					// TODO: this is buggy: same playlist might be triggered from other buttons.
					// maybe we want the indirection of a state machine here?
				} else if playlist_is_current(.Easy_Listening) {
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
					}
				}
				gm.sound_settings.use_house_music = use_house_music
				sound_settings_save()
			}
		case .Pre_Show:
			if control_button_pressed(&control) {
				vol := f32(0.5)
				playlist := playlist_find_by_name(.Happy_Beats)
				ensure(playlist != nil, "Couldn't find playlist for Pre_Show")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Pre_Show")

				new_voice := music_start_playlist_track(
					playlist,
					track,
					vol,
					gm.sound_settings.fade_in_time,
					0,
					gm.sound_settings.fade_out_time,
				)
				if new_voice != nil {
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}
		case .Post_Show:
			if control_button_pressed(&control) {
				vol := f32(0.8)
				playlist := playlist_find_by_name(.Happy_Beats)
				ensure(playlist != nil, "Couldn't find playlist for Post_Show")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Post_Show")

				new_voice := music_start_playlist_track(
					playlist,
					track,
					vol,
					gm.sound_settings.fade_in_time,
					0,
					gm.sound_settings.fade_out_time,
				)
				if new_voice != nil {
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}
		case .To_House:
			if control_button_pressed(&control) {
				vol := f32(0.2)
				if gm.sound_settings.use_house_music {
					playlist := playlist_find_by_name(.Easy_Listening)
					ensure(playlist != nil, "Couldn't find playlist for To_House")

					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for To_House")

					new_voice := music_start_playlist_track(
						playlist,
						track,
						vol,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					if new_voice != nil {
						music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
					}
				} else {
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
					}
				}
			}
		case .Scene_Ramp:
			if control_button_pressed(&control) {
				primary: ^MusicVoice
				primary_volume: f32
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					voice_volume := music_voice_volume_current(voice)
					if primary == nil || voice_volume > primary_volume {
						primary = &voice
						primary_volume = voice_volume
					}
				}
				if primary != nil {
					ramp_up_duration := f32(0.5)
					hold_duration := f32(3)
					fade_out_duration := f32(1)
					gm.sound_settings.music_volume = 1
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						if &voice == primary {
							current_audible_volume := music_voice_volume_current(voice)
							voice.volume = 1
							full_volume := music_voice_volume_current(voice)

							progress := f32(0)
							if full_volume > 0 {
								progress = f32(
									math.sqrt(
										f64(
											math.clamp(current_audible_volume / full_volume, 0, 1),
										),
									),
								)
							}
							voice.fade_phase = .FadingIn
							voice.fade_in_duration = ramp_up_duration
							voice.fade_in_time_left = ramp_up_duration * (1 - progress)
							voice.hold_time_left = hold_duration
							voice.fade_out_duration = fade_out_duration
							voice.fade_out_time_left = fade_out_duration
							voice.fade_out_quick = true
							voice.started_next = false
						} else {
							music_voice_stop(&voice)
						}
					}
				}
			}
		case .Scene_Fade:
			if control_button_pressed(&control) {
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					music_voice_fade_out(&voice, 2)
				}
			}
		case .Drop_Needle:
			if control_button_pressed(&control) {
				vol := f32(1.0)
				playlist := playlist_find_by_name(.Needle_Droppers)
				ensure(playlist != nil, "Couldn't find playlist for Needle_Droppers")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Needle_Droppers")

				for &voice in gm.sound_settings.music_voices {
					music_voice_stop(&voice)
				}
				music_start_playlist_track(playlist, track, vol, 0, 0, 0)
			}

		// Games
		case .Innuendo:
			if control_button_pressed(&control) {
				playlist := playlist_find_by_name(.Sex_With_Me)
				ensure(playlist != nil, "Couldn't find playlist for Innuendo")

				if playlist_is_current(.Sex_With_Me) {
					for &voice in gm.sound_settings.music_voices {
						music_voice_fade_out(&voice, 2)
					}
				} else {
					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for Innuendo")

					vol := f32(0.6)
					new_voice := music_start_playlist_track(
						playlist,
						track,
						vol,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					if new_voice != nil {
						music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
					}
				}
			}
		case .Oscar_Moment:
			if control_button_pressed(&control) {
				playlist := playlist_find_by_name(.Oscar_Moment)
				ensure(playlist != nil, "Couldn't find playlist for Oscar_Moment")

				oscar_moment_playing := false
				if playlist_is_current(.Oscar_Moment) && playlist.current_playing_track != nil {
					for voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						if voice.fade_phase == .FadingOut do continue
						if voice.path != playlist.current_playing_track.path do continue
						oscar_moment_playing = true
					}
				}

				for &voice in gm.sound_settings.music_voices {
					music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
				}

				if !oscar_moment_playing {
					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for Oscar_Moment")

					volume := f32(0.4)
					volume_swell := f32(0.6)
					swell_duration := f32(20)
					new_voice := music_start_playlist_track(
						playlist,
						track,
						volume,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					ensure(new_voice != nil, "Couldn't start Oscar_Moment voice")

					music_voice_swell_after_fade_in(new_voice, volume_swell, swell_duration)
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}

		// Lighting
		case .RainbowSting:
			if control_button_pressed(&control) {
				log.debug("hi")
			}

		// Sounds
		case .Glass_Break:
			if control_button_pressed(&control) do sound_play(.Glass_Breaking_Sound_Effect_HD_Glass_Shattering_Sound_Effect_TcnufvBffcY, 0.8)
		case .Gunshot:
			if control_button_pressed(&control) do sound_play(.Single_Gunshot_54_40780, 0.8)
		case .Scream:
			if control_button_pressed(&control) do sound_play(.Woman_Screaming_Sfx_Screaming_Sound_Effect_320169, 0.8)
		case .Lightning:
			if control_button_pressed(&control) do sound_play(.Lightning_237994, 0.8)
		case .Fireworks:
			if control_button_pressed(&control) do sound_play(.Fireworks_13_419033, 0.4)
		case .Train_Horn:
			if control_button_pressed(&control) do sound_play(.Train_Horn_337875, 0.8)
		case .Tick_Tick_Ding:
			if control_button_pressed(&control) do sound_play(.Ticktickding, 0.8)
		case .Ding:
			if control_button_pressed(&control) do sound_play(.Ding_126626, 0.8)
		case .Calming_Rain:
			if control_button_pressed(&control) do sound_play(.Calming_Rain_257596, 0.8)
		case .Cat_Meow:
			if control_button_pressed(&control) do sound_play(.Cat_Meow, 0.6)
		case .Yeeeeaaaaaaaahh:
			if control_button_pressed(&control) do sound_play(.Yeeeeaaaaaaaahh, 1)

		// Music tab
		case .ChangePlaylist:
			s := &control.state.(List_State)
			prev := s.active
			rl.GuiListViewEx(
				control.rect,
				raw_data(s.items[:]),
				i32(len(s.items)),
				&s.scroll_index,
				&s.active,
				nil,
			)
			if prev != s.active do music_browser_tracks_refresh()
		case .ChangeTrack:
			control_draw_passive(&control)

		case:
			control_draw_passive(&control)
		}
	}
}

control_text_replace :: proc(control: ^Control, text: string) {
	delete(control.text)
	control.text = strings.clone_to_cstring(text)
}

list_control_items_replace :: proc(control: ^Control, names: []string) {
	if list_state, ok := control.state.(List_State); ok {
		for item in list_state.items do delete(item)
		clear(&list_state.items)
		for name in names do append(&list_state.items, strings.clone_to_cstring(name))
		control.state = list_state
	}

	text, err := strings.join(names, ";", context.temp_allocator)
	log.ensuref(err == nil, "Error joining list names: %v", err)
	control_text_replace(control, text)
}

ui_control_set_value :: proc(ui: ^UIControls, name: ControlName, value: $Val) {
	control := ui_control_get(ui, name)
	if control == nil do return
	control.state = value
}

music_browser_playlists_refresh :: proc() {
	control := ui_control_get(&gm.ui, .ChangePlaylist)
	if control == nil do return

	names := make([]string, len(gm.sound_settings.playlists), context.temp_allocator)
	for playlist, i in gm.sound_settings.playlists do names[i] = playlist.name
	list_control_items_replace(control, names)
	s := &control.state.(List_State)
	s.active = 0
	s.scroll_index = 0
}

music_browser_playlist_selected :: proc() -> ^Playlist {
	control := ui_control_get(&gm.ui, .ChangePlaylist)
	if control == nil do return nil

	s := control.state.(List_State)
	index := int(s.active)
	if index < 0 || index >= len(gm.sound_settings.playlists) do return nil
	return &gm.sound_settings.playlists[index]
}

music_browser_tracks_refresh :: proc() {
	control := ui_control_get(&gm.ui, .ChangeTrack)
	if control == nil do return

	playlist := music_browser_playlist_selected()
	if playlist == nil {
		control_text_replace(control, "")
		return
	}

	names: [dynamic]string
	defer delete(names)

	it := hm.iterator_make(&playlist.tracks)
	for track, _ in hm.iterate(&it) {
		append(&names, track.title)
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {
		return strings.compare(a, b) < 0
	})

	list_control_items_replace(control, names[:])
	s := &control.state.(List_State)
	s.active = 0
	s.scroll_index = 0
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
