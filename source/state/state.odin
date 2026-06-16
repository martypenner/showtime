package state

import "../sound"
import "../ui"
import "core:mem"

GameMemory :: struct {
	should_run:     bool,
	arena:          mem.Dynamic_Arena,
	active_tab:     int,
	ui_controls:    [dynamic]ui.Control,
	sound_settings: ^sound.SoundSettings,
}
