package game

import "core:testing"
import "ui"

// Destructive presentation is an app-owned decision, not something the generic
// UI/layout code special-cases by name. Dropping the needle is destructive (it
// interrupts the show), so it must resolve to the destructive style while
// ordinary controls stay default.
@(test)
resolve_ui_type_marks_destructive_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, resolve_ui_type("Drop_Needle"), ui.UI_Type.Destructive)
	testing.expect_value(t, resolve_ui_type("Cat_Meow"), ui.UI_Type.Default)
	testing.expect_value(t, resolve_ui_type(""), ui.UI_Type.Default)
}
