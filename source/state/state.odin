package state

import "core:mem"
import rl "vendor:raylib"

GameMemory :: struct {
	should_run:     bool,
	arena:          mem.Dynamic_Arena,
	ui_controls:    [dynamic]Control,
	sound_settings: SoundSettings,
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
		return 0
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

SoundSettings :: struct {
	volume:                   f16,
	fade_in_time:             f16,
	fade_out_time:            f16,
	stop_fade_time:           f16,
	start_next_time:          f16,
	shuffle:                  bool,
	loop:                     bool,
	normalize_volume:         bool,
	target_loudness:          f16,
	playlists:                [dynamic]Playlist,
	current_playing_playlist: ^Playlist,
	current_music:            rl.Music,
	is_music_playing:         bool,
}

Playlist :: struct {
	name:                  string,
	// this should probably be hm.Dynamic_Handle_Map(Track, TrackHandle), but
	// then we have to store the handles and pass them around.
	tracks:                [dynamic]Track,
	// indices into tracks. Handle maps are more stable, but I don't want to pass
	// around handles everywhere.
	played_tracks:         [dynamic]int,
	current_playing_track: ^Track,
}

Track :: struct {
	title:         string,
	path:          string,

	// The actual portion of the track to play. If it's been edited, this will be
	// the "slice" to play. If not, this is the full track length.
	slice_to_play: struct {
		start_time: f16,
		end_time:   f16,
	},
}
