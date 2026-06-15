package game

import "core:testing"
import "ui"

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

// Destructive presentation is an app-owned decision, not something the generic
// UI/layout code special-cases by name. Dropping the needle is destructive (it
// interrupts the show), so it must resolve to the destructive style while
// ordinary controls stay default.
@(test)
resolve_ui_type_marks_destructive_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve_ui_type("dropneedle"), ui.UI_Type.Destructive)
	testing.expect_value(t, resolve_ui_type("catmeow"), ui.UI_Type.Default)
	testing.expect_value(t, resolve_ui_type(""), ui.UI_Type.Default)
}
