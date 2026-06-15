package state

import "../sound"
import "../ui"
import "core:mem"
import rl "vendor:raylib"

GameMemory :: struct {
	should_run:     bool,
	arena:          mem.Dynamic_Arena,
	ui_controls:    [dynamic]ui.Control,
	sound_settings: ^sound.SoundSettings,
	playground:     struct {
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
