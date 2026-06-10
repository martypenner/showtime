package state

import rl "vendor:raylib"

TEXT_BOX_CAPACITY :: 64

Game_Memory :: struct {
	should_run:             bool,
	toggle_state:           Toggle_State,
	toggle_group_active:    i32,
	toggle_slider_active:   i32,
	checked:                bool,
	text_box_buffer:        [TEXT_BOX_CAPACITY]u8,
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
	text_input:             [TEXT_BOX_CAPACITY]u8,
}

Toggle_State :: struct {
	current: bool,
	prev:    bool,
}
