package state

import "../sound"
import "../ui"
// Only referenced from the PLAYGROUND branch below; @(require) keeps the import
// valid when playground state is gated out.
@(require) import "../ui/playground"
import "core:mem"

// PLAYGROUND mirrors the game package's compile-time flag so playground-only
// state can be gated out of shared game memory when the experiments are not
// compiled in.
PLAYGROUND :: #config(PLAYGROUND, false)

// Playground_Memory gates the development-only playground state out of the
// shared, hot-reloaded GameMemory. Odin has no `when` inside a struct body, so
// the gating lives in this config-selected wrapper that GameMemory embeds: with
// PLAYGROUND enabled it carries the playground state, otherwise it is empty and
// the release memory shape contains only genuinely shared state.
when PLAYGROUND {
	Playground_Memory :: struct {
		playground: playground.State,
	}
} else {
	Playground_Memory :: struct {}
}

GameMemory :: struct {
	should_run:     bool,
	arena:          mem.Dynamic_Arena,
	ui_controls:    [dynamic]ui.Control,
	sound_settings: ^sound.SoundSettings,
	using _:        Playground_Memory,
}
