package state

import "../sound"
import "../ui"

GameMemory :: struct {
	should_run:     bool,
	active_tab:     int,
	ui_controls:    [dynamic]ui.Control,
	sound_settings: ^sound.SoundSettings,
}
