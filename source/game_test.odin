package game

import "core:testing"

// Destructive presentation is an app-owned decision, not something the generic
// UI/layout code special-cases by name. Dropping the needle is destructive (it
// interrupts the show), so it must resolve to the destructive style while
// ordinary controls stay default.
@(test)
resolve_ui_type_marks_destructive_controls :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_resolve_type(.Drop_Needle), UI_Type.Destructive)
	testing.expect_value(t, ui_resolve_type(.Cat_Meow), UI_Type.Sound)
	testing.expect_value(t, ui_resolve_type(.RainbowSting), UI_Type.Lighting)
}

// Tabs are split per layout file: build_layout tags every control with the group
// of the file it loaded from. chrome.rgl loads into VISIBLE_ON_ALL_GROUPS so its
// controls (the tab bar and status bar) show on every tab, and controls.rgl
// loads into the Controls tab. This pins that contract so adding the Music tab is
// just a new file + load call.
@(test)
build_layout_groups_controls_by_tab :: proc(t: ^testing.T) {
	controls := layout_build()
	defer ui_shutdown(&controls)

	chrome_seen, controls_seen: int
	for control in controls {
		switch control.name {
		case "Tab_Bar", "Status_Bar":
			testing.expect_value(t, control.visibility_group, VISIBLE_ON_ALL_GROUPS)
			chrome_seen += 1
		case:
			testing.expect_value(t, control.visibility_group, int(Tab.Controls))
			controls_seen += 1
		}
	}
	testing.expect_value(t, chrome_seen, 2)
	testing.expect(t, controls_seen > 0, "expected controls.rgl controls on the Controls tab")
}
