package game

import "core:testing"

// The app layer owns the mapping from layout control names to show-control
// actions. Resolving names in one place keeps typos and layout/code mismatches
// easy to detect, and lets us verify the action Seam without invoking Raylib
// drawing.
@(test)
resolve_known_show_actions :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve_show_action("catmeow"), Show_Action.Cat_Meow)
	testing.expect_value(t, resolve_show_action("dropneedle"), Show_Action.Drop_Needle)
	testing.expect_value(t, resolve_show_action("mastervolume"), Show_Action.Master_Volume)
}

// Unknown action names must be handled deliberately rather than failing
// silently, so a layout control with no matching app behavior resolves to a
// single explicit "unknown" outcome.
@(test)
resolve_unknown_show_action_is_deliberate :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve_show_action("not-a-real-control"), Show_Action.Unknown)
	testing.expect_value(t, resolve_show_action(""), Show_Action.Unknown)
}
