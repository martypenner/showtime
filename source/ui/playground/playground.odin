package playground

import "core:fmt"
import rl "vendor:raylib"

// State holds the development-only scaffolding for experimenting with raygui
// controls. It lives in the playground package (not shared state) so disabled
// experiments stay self-contained; the game package only embeds it in
// hot-reloaded memory when the PLAYGROUND config is compiled in.
State :: struct {
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
}

draw :: proc(pg: ^State) {
	if (rl.GuiButton(
			   {25, 255, 125, 30},
			   rl.GuiIconText(rl.GuiIconName.ICON_FILE_SAVE, "Save File"),
		   )) {
		fmt.println("clicked save button")
	}

	if (rl.GuiLabelButton({200, 255, 125, 30}, "Save File")) {
		fmt.println("clicked save label")
	}

	rl.GuiToggle(
		{165, 400, 140, 25},
		pg.toggle_state.current ? "ON" : "OFF",
		&pg.toggle_state.current,
	)
	if pg.toggle_state.current != pg.toggle_state.prev {
		fmt.println("changed toggle")
	}
	pg.toggle_state.prev = pg.toggle_state.current

	rl.GuiToggleGroup(
		{350, 360, 140, 24},
		"#1#ONE\n#3#TWO\n#8#THREE\n#23#",
		&pg.toggle_group_active,
	)

	rl.GuiToggleSlider({165, 480, 140, 30}, "ON;OFF", &pg.toggle_slider_active)

	rl.GuiCheckBox({25, 108, 15, 15}, "FORCE CHECK!", &pg.checked)

	if (rl.GuiTextBox(
			   {25, 215, 125, 30},
			   cstring(&pg.text_box_buffer[0]),
			   i32(len(pg.text_box_buffer)),
			   pg.text_box_editing,
		   )) {
		pg.text_box_editing = !pg.text_box_editing
	}

	if (rl.GuiSpinner(
			   {25, 135, 125, 30},
			   nil,
			   &pg.spinner,
			   0,
			   100,
			   pg.spinner_editing,
		   )) >
	   0 {
		pg.spinner_editing = !pg.spinner_editing
	}

	rl.GuiSlider(
		{555, 400, 165, 20},
		"TEST",
		rl.TextFormat("%2.2f", 100.0),
		&pg.slider_value,
		-50,
		100,
	)

	rl.GuiSliderBar(
		{855, 400, 165, 20},
		"TEST",
		rl.TextFormat("%2.2f", 100.0),
		&pg.slider_value,
		-50,
		100,
	)

	pg.progress_value = 0.4
	rl.GuiProgressBar(
		{320, 560, 200, 20},
		nil,
		rl.TextFormat("%2.0f%%", pg.progress_value * 100.0),
		&pg.progress_value,
		0.0,
		1.0,
	)

	rl.GuiComboBox(
		{25, 480, 125, 30},
		"default;Jungle;Lavanda;Dark;Bluish;Cyber;Terminal;Candy;Cherry;Ashes;Enefete;Sunny;Amber",
		&pg.visual_style,
	)

	if (rl.GuiDropdownBox(
			   {25, 100, 125, 30},
			   "ONE;TWO;THREE",
			   &pg.dropdown_active,
			   pg.dropdown_edit,
		   )) {
		pg.dropdown_edit = !pg.dropdown_edit
	}

	rl.GuiLabel({400, 300, 60, 25}, "File format:")

	rl.GuiStatusBar(
		{0, f32(rl.GetScreenHeight()) - 20, f32(rl.GetScreenWidth()), 20},
		"This is a status bar",
	)

	rl.GuiGrid({560, 100, 100, 120}, nil, 20, 3, &pg.active_cell)
	// fmt.println(pg.active_cell)

	tabs := [?]cstring{"General", "Controls", "Advanced"}
	if (rl.GuiTabBar({20, 20, 300, 30}, raw_data(&tabs), 3, &pg.active_tab) != -1) {
		// A tab was selected to be closed
	}

	rl.GuiListView(
		{765, 25, 140, 124},
		"Charmander;Bulbasaur;#18#Squirtel;Pikachu;Eevee;Pidgey",
		&pg.list_view_scroll_index,
		&pg.list_view_active,
	)

	rl.GuiColorPicker({720, 185, 196, 192}, nil, &pg.color_picker_value)

	// exit_window := false
	// result := rl.GuiMessageBox(
	// 	{f32(rl.GetScreenWidth()) / 2 - 125, f32(rl.GetScreenHeight()) / 2 - 50, 250, 100},
	// 	rl.GuiIconText(rl.GuiIconName.ICON_EXIT, "Close Window"),
	// 	"Do you really want to exit?",
	// 	"Yes;No",
	// )
	// if result == 1 {
	// 	exit_window = true
	// }

	// result := rl.GuiTextInputBox(
	// 	{f32(rl.GetScreenWidth()) / 2 - 120, f32(rl.GetScreenHeight()) / 2 - 60, 240, 140},
	// 	rl.GuiIconText(rl.GuiIconName.ICON_FILE_SAVE, "Save file as..."),
	// 	"Introduce output file name:",
	// 	"Ok;Cancel",
	// 	cstring(&pg.text_input[0]),
	// 	255,
	// 	nil,
	// )
	// if (result == 1) {
	// 	// User clicked OK, textInput contains the entered text
	// 	// Process the input...
	// 	// TextCopy(textInputFileName, textInput);
	// }

	// NOTE: `fmt.ctprintf` uses the temp allocator. The temp allocator is
	// cleared at the end of the frame by the main application, meaning inside
	// `main_hot_reload.odin`, `main_release.odin` or `main_web_entry.odin`.
	// rl.DrawText(
	// 	fmt.ctprintf("some_number: %v\nplayer_pos: %v", g.some_number, g.player_pos),
	// 	5,
	// 	5,
	// 	8,
	// 	rl.WHITE,
	// )
}
