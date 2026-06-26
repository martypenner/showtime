#+vet !unused-imports
/*
This file is the starting point of your game.

Some important procedures are:
- game_init_window: Opens the window
- game_init: Sets up the game state
- game_update: Run once per frame
- game_should_close: For stopping your game when close button is pressed
- game_shutdown: Shuts down game and frees memory
- game_shutdown_window: Closes window

The procs above are used regardless if you compile using the `build_release`
script or the `build_hot_reload` script. However, in the hot reload case, the
contents of this file is compiled as part of `build/hot_reload/game.dll` (or
.dylib/.so on mac/linux). In the hot reload cases some other procedures are
also used in order to facilitate the hot reload functionality:

- game_memory: Run just before a hot reload. That way game_hot_reload.exe has a
	pointer to the game's memory that it can hand to the new game DLL.
- game_hot_reloaded: Run after a hot reload so that the `g` global
	variable can be set to whatever pointer it was in the old DLL.

NOTE: When compiled as part of `build_release`, `build_debug` or `build_web`
then this whole package is just treated as a normal Odin package. No DLL is
created.
*/

package game

import hm "core:container/handle_map"
import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:thread"
import rl "vendor:raylib"

gm: ^GameMemory

GameMemory :: struct {
	should_run:     bool,
	app_state:      AppState,
	active_tab:     int,
	ui_controls:    Controls,
	sound_settings: ^SoundSettings,
	loader:         ^thread.Thread,
}

AppState :: union #no_nil {
	AppInitializing,
	AppReady,
}

AppInitializing :: distinct u8
AppReady :: distinct u8

Show_Action :: enum {
	Unknown,
	// Main controls
	Tab_Bar,
	Music_Volume,
	Use_House_Music,
	// Scene changes
	Pre_Show,
	Post_Show,
	To_House,
	Scene_Ramp,
	Scene_Fade,
	Drop_Needle,
	// Games
	Innuendo,
	Oscar_Moment,
	// Sounds
	Glass_Break,
	Gunshot,
	Scream,
	Lightning,
	Fireworks,
	Train_Horn,
	Tick_Tick_Ding,
	Ding,
	Calming_Rain,
	Cat_Meow,
	Yeeeeaaaaaaaahh,
	// Lighting
	RainbowSting,
}

Tab :: enum int {
	Controls,
	Music,
}

layout_build :: proc() -> Controls {
	controls: Controls

	// Per-tab content first, then chrome, so the persistent controls draw on top.
	layout_load(
		&controls,
		"controls.rgl",
		string(#load("../resources/controls.rgl")),
		int(Tab.Controls),
	)
	// ui.load_layout(&controls, "music.rgl", string(#load("../resources/music.rgl")), int(Tab.Music), allocator)

	layout_load(
		&controls,
		"chrome.rgl",
		string(#load("../resources/chrome.rgl")),
		VISIBLE_ON_ALL_GROUPS,
	)

	controls_prepare_for_render(controls[:], rl.GetRenderWidth(), rl.GetRenderHeight())
	return controls
}

// Resolves a layout control name to its presentation style. Destructive styling
// is an app concern (which controls are dangerous to the show), so this mapping
// lives here rather than in generic UI/layout code. Keeping it pure lets the
// styling Seam be verified without Raylib drawing.
ui_resolve_type :: proc(action: Show_Action) -> UI_Type {
	#partial switch action {
	case .Drop_Needle:
		return .Destructive
	case .Innuendo:
		return .Innuendo
	case .Oscar_Moment:
		return .Game
	case .Glass_Break,
	     .Gunshot,
	     .Scream,
	     .Lightning,
	     .Yeeeeaaaaaaaahh,
	     .Tick_Tick_Ding,
	     .Ding,
	     .Fireworks,
	     .Train_Horn,
	     .Calming_Rain,
	     .Cat_Meow:
		return .Sound
	case .RainbowSting:
		return .Lighting
	case:
		return .SoundAndLighting
	}
}

controls_draw :: proc() {
	for &control in gm.ui_controls {
		if !control_is_visible(control, gm.active_tab) {
			continue
		}

		action, ok := fmt.string_to_enum_value(Show_Action, control.name)
		if !ok do action = .Unknown

		// Controls draw themselves here and immediately handle their app behavior.
		// Only controls that mutate persisted settings save them; tab switches and
		// one-shot sounds remain transient.
		switch action {
		case .Tab_Bar:
			prev := control.state.(i32)
			rl.GuiToggleGroup(control.rect, control.text, &control.state.(i32))
			if prev != control.state.(i32) {
				index := int(control.state.(i32))
				switch Tab(index) {
				case .Controls, .Music:
					gm.active_tab = index
				case:
					gm.active_tab = int(Tab.Controls)
				}
			}
		case .Music_Volume:
			prev := control.state.(f32)
			rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
			if prev != control.state.(f32) {
				gm.sound_settings.music_volume = control.state.(f32)
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					voice.volume = control.state.(f32)
				}
				sound_settings_save()
			}
		case .Use_House_Music:
			prev := control.state.(bool)
			rl.GuiCheckBox(control.rect, control.text, &control.state.(bool))
			if prev != control.state.(bool) {
				use_house_music := control.state.(bool)
				if use_house_music {
					if gm.sound_settings.current_playing_playlist == nil {
						playlist := playlist_find(.Happy_Beats)
						ensure(playlist != nil, "Couldn't find playlist for Use_House_Music")

						track := playlist_pick_track(playlist)
						ensure(track != nil, "Couldn't pick track for Use_House_Music")

						new_voice := music_start_playlist_track(
							playlist,
							track,
							0.2,
							gm.sound_settings.fade_in_time,
							0,
							gm.sound_settings.fade_out_time,
						)
						if new_voice != nil {
							music_voices_fade_out_except(
								new_voice,
								gm.sound_settings.fade_out_time,
							)
						}
					}
					// TODO: this is buggy: happy beats might be triggered from other buttons.
					// maybe we want the indirection of a state machine here?
				} else if playlist_is_current(.Happy_Beats) {
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
					}
				}
				gm.sound_settings.use_house_music = use_house_music
				sound_settings_save()
			}
		case .Pre_Show:
			if control_button_pressed(&control) {
				vol := f32(0.5)
				playlist := playlist_find(.Happy_Beats)
				ensure(playlist != nil, "Couldn't find playlist for Pre_Show")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Pre_Show")

				new_voice := music_start_playlist_track(
					playlist,
					track,
					vol,
					gm.sound_settings.fade_in_time,
					0,
					gm.sound_settings.fade_out_time,
				)
				if new_voice != nil {
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}
		case .Post_Show:
			if control_button_pressed(&control) {
				vol := f32(0.8)
				playlist := playlist_find(.Happy_Beats)
				ensure(playlist != nil, "Couldn't find playlist for Post_Show")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Post_Show")

				new_voice := music_start_playlist_track(
					playlist,
					track,
					vol,
					gm.sound_settings.fade_in_time,
					0,
					gm.sound_settings.fade_out_time,
				)
				if new_voice != nil {
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}
		case .To_House:
			if control_button_pressed(&control) {
				vol := f32(0.2)
				if gm.sound_settings.use_house_music {
					playlist := playlist_find(.Happy_Beats)
					ensure(playlist != nil, "Couldn't find playlist for To_House")

					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for To_House")

					new_voice := music_start_playlist_track(
						playlist,
						track,
						vol,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					if new_voice != nil {
						music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
					}
				} else {
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
					}
				}
			}
		case .Scene_Ramp:
			if control_button_pressed(&control) {
				primary: ^MusicVoice
				primary_volume: f32
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					voice_volume := music_voice_volume_current(voice)
					if primary == nil || voice_volume > primary_volume {
						primary = &voice
						primary_volume = voice_volume
					}
				}
				if primary != nil {
					ramp_up_duration := f32(0.5)
					hold_duration := f32(3)
					fade_out_duration := f32(1)
					gm.sound_settings.music_volume = 1
					for &voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						if &voice == primary {
							current_audible_volume := music_voice_volume_current(voice)
							voice.volume = 1
							full_volume := music_voice_volume_current(voice)

							progress := f32(0)
							if full_volume > 0 {
								progress = f32(
									math.sqrt(
										f64(
											math.clamp(current_audible_volume / full_volume, 0, 1),
										),
									),
								)
							}
							voice.fade_phase = .FadingIn
							voice.fade_in_duration = ramp_up_duration
							voice.fade_in_time_left = ramp_up_duration * (1 - progress)
							voice.hold_time_left = hold_duration
							voice.fade_out_duration = fade_out_duration
							voice.fade_out_time_left = fade_out_duration
							voice.fade_out_quick = true
							voice.started_next = false
						} else {
							music_voice_stop(&voice)
						}
					}
				}
			}
		case .Scene_Fade:
			if control_button_pressed(&control) {
				for &voice in gm.sound_settings.music_voices {
					if !voice.active do continue
					music_voice_fade_out(&voice, 2)
				}
			}
		case .Drop_Needle:
			if control_button_pressed(&control) {
				vol := f32(1.0)
				playlist := playlist_find(.Needle_Droppers)
				ensure(playlist != nil, "Couldn't find playlist for Needle_Droppers")

				track := playlist_pick_track(playlist)
				ensure(track != nil, "Couldn't pick track for Needle_Droppers")

				for &voice in gm.sound_settings.music_voices {
					music_voice_stop(&voice)
				}
				music_start_playlist_track(playlist, track, vol, 0, 0, 0)
			}

		// Games
		case .Innuendo:
			if control_button_pressed(&control) {
				playlist := playlist_find(.Sex_With_Me)
				ensure(playlist != nil, "Couldn't find playlist for Innuendo")

				if playlist_is_current(.Sex_With_Me) {
					for &voice in gm.sound_settings.music_voices {
						music_voice_fade_out(&voice, 2)
					}
				} else {
					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for Innuendo")

					vol := f32(0.6)
					new_voice := music_start_playlist_track(
						playlist,
						track,
						vol,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					if new_voice != nil {
						music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
					}
				}
			}
		case .Oscar_Moment:
			if control_button_pressed(&control) {
				playlist := playlist_find(.Oscar_Moment)
				ensure(playlist != nil, "Couldn't find playlist for Oscar_Moment")

				oscar_moment_playing := false
				if playlist_is_current(.Oscar_Moment) && playlist.current_playing_track != nil {
					for voice in gm.sound_settings.music_voices {
						if !voice.active do continue
						if voice.fade_phase == .FadingOut do continue
						if voice.path != playlist.current_playing_track.path do continue
						oscar_moment_playing = true
					}
				}

				for &voice in gm.sound_settings.music_voices {
					music_voice_fade_out(&voice, gm.sound_settings.fade_out_time)
				}

				if !oscar_moment_playing {
					track := playlist_pick_track(playlist)
					ensure(track != nil, "Couldn't pick track for Oscar_Moment")

					volume := f32(0.4)
					volume_swell := f32(0.6)
					swell_duration := f32(20)
					new_voice := music_start_playlist_track(
						playlist,
						track,
						volume,
						gm.sound_settings.fade_in_time,
						0,
						gm.sound_settings.fade_out_time,
					)
					ensure(new_voice != nil, "Couldn't start Oscar_Moment voice")

					music_voice_swell_after_fade_in(new_voice, volume_swell, swell_duration)
					music_voices_fade_out_except(new_voice, gm.sound_settings.fade_out_time)
				}
			}

		// Lighting
		case .RainbowSting:
			if control_button_pressed(&control) {
				log.debug("hi")
			}

		// Sounds
		case .Glass_Break:
			if control_button_pressed(&control) do sound_play(.Glass_Breaking_Sound_Effect_HD_Glass_Shattering_Sound_Effect_TcnufvBffcY, 0.8)
		case .Gunshot:
			if control_button_pressed(&control) do sound_play(.Single_Gunshot_54_40780, 0.8)
		case .Scream:
			if control_button_pressed(&control) do sound_play(.Woman_Screaming_Sfx_Screaming_Sound_Effect_320169, 0.8)
		case .Lightning:
			if control_button_pressed(&control) do sound_play(.Lightning_237994, 0.8)
		case .Fireworks:
			if control_button_pressed(&control) do sound_play(.Fireworks_13_419033, 0.4)
		case .Train_Horn:
			if control_button_pressed(&control) do sound_play(.Train_Horn_337875, 0.8)
		case .Tick_Tick_Ding:
			if control_button_pressed(&control) do sound_play(.Ticktickding, 0.8)
		case .Ding:
			if control_button_pressed(&control) do sound_play(.Ding_126626, 0.8)
		case .Calming_Rain:
			if control_button_pressed(&control) do sound_play(.Calming_Rain_257596, 0.8)
		case .Cat_Meow:
			if control_button_pressed(&control) do sound_play(.Cat_Meow, 0.6)
		case .Yeeeeaaaaaaaahh:
			if control_button_pressed(&control) do sound_play(.Yeeeeaaaaaaaahh, 1)
		case .Unknown:
			control_draw_passive(&control)
		}
	}
}

playlist_find :: proc(playlist_name: PlaylistName) -> ^Playlist {
	name := playlist_name_string(playlist_name)
	for &playlist in gm.sound_settings.playlists {
		if playlist.name == name do return &playlist
	}
	log.warnf("Couldn't find playlist, skipping: %s", name)
	return nil
}

playlist_pick_track :: proc(playlist: ^Playlist) -> ^Track {
	track := track_pick_unplayed(playlist)
	if track != nil || !gm.sound_settings.loop do return track

	it := hm.iterator_make(&playlist.tracks)
	for current_track, _ in hm.iterate(&it) {
		current_track.played = false
	}
	return track_pick_unplayed(playlist)
}

music_start_playlist_track :: proc(
	playlist: ^Playlist,
	track: ^Track,
	volume: f32,
	fade_in_duration: f32,
	hold_time_left: f32,
	fade_out_duration: f32,
) -> ^MusicVoice {
	voice := music_voice_start(
		track,
		volume,
		fade_in_duration,
		fade_in_duration,
		hold_time_left,
		fade_out_duration,
		fade_out_duration,
	)
	if voice == nil do return nil

	gm.sound_settings.current_playing_playlist = playlist
	gm.sound_settings.music_volume = volume
	track.played = true
	playlist.last_played_track = playlist.current_playing_track
	playlist.current_playing_track = track
	return voice
}

control_button_pressed :: proc(control: ^Control) -> bool {
	color_base_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
	)
	color_focused_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
	)
	text_base_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
	)
	text_focused_prev := rl.GuiGetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
	)

	switch control.ui_type {
	case .Destructive:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{100, 0, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{120, 0, 0, 255})),
		)
	case .Sound:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{0, 80, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{0, 100, 0, 255})),
		)
	case .Lighting:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{160, 180, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{180, 200, 0, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.DARKGRAY)),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.DARKGRAY)),
		)
	case .SoundAndLighting:
	// default teal
	case .Game:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{0, 69, 129, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{0, 111, 208, 255})),
		)
	case .Innuendo:
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
			i32(rl.ColorToInt(rl.Color{136, 51, 101, 255})),
		)
		rl.GuiSetStyle(
			rl.GuiControl.BUTTON,
			i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
			i32(rl.ColorToInt(rl.Color{207, 80, 154, 255})),
		)
	}

	pressed := rl.GuiButton(control.rect, control.text)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_NORMAL),
		color_base_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.BASE_COLOR_FOCUSED),
		color_focused_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL),
		text_base_prev,
	)
	rl.GuiSetStyle(
		rl.GuiControl.BUTTON,
		i32(rl.GuiControlProperty.TEXT_COLOR_FOCUSED),
		text_focused_prev,
	)

	if pressed {
		log.debugf("Clicked button %s", control.name)
	}
	return pressed
}

control_draw_passive :: proc(control: ^Control) {
	switch control.control_type {
	case .WindowBox:
		rl.GuiWindowBox(control.rect, control.text)
	case .GroupBox:
		rl.GuiGroupBox(control.rect, control.text)
	case .Line:
		rl.GuiLine(control.rect, control.text)
	case .Panel:
		rl.GuiPanel(control.rect, control.text)
	case .Label:
		rl.GuiLabel(control.rect, control.text)
	case .LabelButton:
		rl.GuiLabelButton(control.rect, control.text)
	case .Button:
		control_button_pressed(control)
	case .CheckBox:
		rl.GuiCheckBox(control.rect, control.text, &control.state.(bool))
	case .Toggle:
		rl.GuiToggle(control.rect, control.text, &control.state.(bool))
	case .ToggleGroup:
		rl.GuiToggleGroup(control.rect, control.text, &control.state.(i32))
	case .ComboBox:
		rl.GuiComboBox(control.rect, control.text, &control.state.(i32))
	case .DropdownBox:
		s := &control.state.(Choice_State)
		if (rl.GuiDropdownBox(control.rect, control.text, &s.active, s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .TextBox:
		s := &control.state.(Text_State)
		if (rl.GuiTextBox(control.rect, cstring(&s.buffer[0]), i32(len(s.buffer)), s.edit_mode)) {
			s.edit_mode = !s.edit_mode
		}
	case .ValueBox:
		s := &control.state.(Number_State)
		if (rl.GuiValueBox(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .TextMultiBox:
	case .Spinner:
		s := &control.state.(Number_State)
		if (rl.GuiSpinner(control.rect, control.text, &s.value, 0, 100, s.edit_mode)) > 0 {
			s.edit_mode = !s.edit_mode
		}
	case .Slider:
		rl.GuiSlider(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .SliderBar:
		rl.GuiSliderBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .ProgressBar:
		rl.GuiProgressBar(control.rect, nil, nil, &control.state.(f32), 0, 1)
	case .StatusBar:
		if control.name == "Status_Bar" {
			music_progress := music_current_progress()
			music_played, music_length := music_current_time()
			music_time_text := music_time_pair_label(music_played, music_length)
			progress_rect := rl.Rectangle {
				x      = control.rect.x + control.rect.width - 160,
				y      = control.rect.y + 4,
				width  = 150,
				height = control.rect.height - 8,
			}
			TIME_LABEL_WIDTH :: f32(90)
			time_rect := rl.Rectangle {
				x      = progress_rect.x - TIME_LABEL_WIDTH - 8,
				y      = control.rect.y,
				width  = TIME_LABEL_WIDTH,
				height = control.rect.height,
			}
			rl.GuiStatusBar(
				control.rect,
				strings.clone_to_cstring(music_current_label(), context.temp_allocator),
			)
			rl.GuiProgressBar(progress_rect, nil, nil, &music_progress, 0, 1)
			rl.GuiLabel(
				time_rect,
				strings.clone_to_cstring(music_time_text, context.temp_allocator),
			)
		} else {
			rl.GuiStatusBar(control.rect, control.text)
		}
	case .ScrollPanel:
		s := &control.state.(Scroll_State)
		rl.GuiScrollPanel(control.rect, control.text, control.rect, &s.scroll, &s.view)
	case .ListView:
		s := &control.state.(List_State)
		rl.GuiListView(control.rect, control.text, &s.scroll_index, &s.active)
	case .ColorPicker:
		rl.GuiColorPicker(control.rect, control.text, &control.state.(rl.Color))
	case .DummyRect:
		rl.GuiDummyRec(control.rect, control.text)
	}
}

update :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		gm.should_run = false
	}

	switch s in gm.app_state {
	case AppInitializing:
		if gm.loader != nil && thread.is_done(gm.loader) {
			thread.destroy(gm.loader)
			gm.loader = nil
			gm.app_state = AppReady{}
		}
	case AppReady:
		if rl.IsWindowResized() {
			controls_prepare_for_render(
				gm.ui_controls[:],
				rl.GetRenderWidth(),
				rl.GetRenderHeight(),
			)
		}
		sound_update()
		ui_control_set_value("Music_Volume", sound_music_current_volume(), gm.ui_controls[:])
	}
}

draw :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground({16, 16, 16, 255})

	switch s in gm.app_state {
	case AppInitializing:
		font_size := i32(40)
		x := (rl.GetRenderWidth() - rl.MeasureText("Normalizing audio...", font_size)) / 2
		y := rl.GetRenderHeight() / 2 - font_size / 2

		dots := "..."
		dot_count := int(rl.GetTime() / 0.5) % 3 + 1
		text := fmt.ctprintf("Normalizing audio%s", dots[:dot_count])
		rl.DrawText(text, x, y, font_size, rl.RAYWHITE)
	case AppReady:
		controls_draw()
	}

	rl.EndDrawing()
}

music_time_pair_label :: proc(played, length: f32) -> string {
	played_total := max(int(played), 0)
	played_minutes := played_total / 60
	played_seconds := played_total % 60

	length_total := max(int(length), 0)
	length_minutes := length_total / 60
	length_seconds := length_total % 60

	played_zero := ""
	if played_seconds < 10 do played_zero = "0"
	length_zero := ""
	if length_seconds < 10 do length_zero = "0"

	return fmt.tprintf(
		"%d:%s%d / %d:%s%d",
		played_minutes,
		played_zero,
		played_seconds,
		length_minutes,
		length_zero,
		length_seconds,
	)
}

ui_control_set_value :: proc(name: string, value: $Val, controls: []Control) {
	for &control in controls {
		if control.name != name do continue
		control.state = value
		return
	}
}

@(export)
game_update :: proc() {
	update()
	draw()

	// Everything on tracking allocator is valid until end-of-frame.
	free_all(context.temp_allocator)
}

@(export)
game_init_window :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 720, "Showtime")
	when ODIN_OS != .JS do rl.SetWindowPosition(200, 200)
	// This is an app, not a game. Needs constant updates since some latency will
	// occur between networked devices.
	rl.SetTargetFPS(500)
	rl.SetExitKey(nil)
}

// GuiLoadStyle only accepts a file path, so write the embedded style next to
// the running executable (resolves regardless of the working directory). Raygui
// style is global module state, so hot reload must apply it again after loading
// a fresh game DLL.
ui_load_style :: proc() {
	style_raw := #load("../resources/cyber.rgs")
	style_path := fmt.ctprint(rl.GetApplicationDirectory(), "cyber.rgs", sep = "")
	rl.SaveFileData(style_path, raw_data(style_raw), i32(len(style_raw)))
	rl.GuiLoadStyle(style_path)
}

@(export)
game_init :: proc() {
	gm = new(GameMemory)
	gm^ = GameMemory {
		should_run = true,
		app_state  = AppInitializing{},
	}

	ui_load_style()
	// build_layout assigns each control's tab (visibility group) from the file it
	// was loaded out of. The remaining app metadata (destructive styling) is
	// neutral after parsing, so it is applied here while the UI-owned data lives
	// on the app allocator.
	gm.ui_controls = layout_build()
	for &control in gm.ui_controls {
		action, ok := fmt.string_to_enum_value(Show_Action, control.name)
		if !ok do continue
		control.ui_type = ui_resolve_type(action)
	}

	gm.sound_settings = sound_settings_init()
	ui_control_set_value("Use_House_Music", gm.sound_settings.use_house_music, gm.ui_controls[:])
	gm.loader = thread.create_and_start(playlists_load_async, context)

	game_hot_reloaded(gm)
}

@(export)
game_should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// Never run this proc in browser. It contains a 16 ms sleep on web!
		if rl.WindowShouldClose() {
			return false
		}
	}

	return gm.should_run
}

@(export)
game_shutdown :: proc() {
	// If the window closed while still loading, wait for the loader to finish
	// before sound_shutdown frees the settings/playlists it is writing into.
	if gm.loader != nil {
		thread.destroy(gm.loader)
		gm.loader = nil
	}
	sound_shutdown()
	ui_shutdown(&gm.ui_controls)
	free(gm)
}

@(export)
game_shutdown_window :: proc() {
	rl.CloseWindow()
}

@(export)
game_memory :: proc() -> rawptr {
	return gm
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(GameMemory)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	gm = (^GameMemory)(mem)

	ui_load_style()

	// Restore Module-level pointers that point into `gm`. A freshly loaded DLL
	// starts these globals nil, so they must be re-pointed here before the next
	// frame uses them.
	sound_hot_reloaded(gm.sound_settings)
}

@(export)
game_force_reload :: proc() -> bool {
	return rl.IsKeyPressed(.F5)
}

@(export)
game_force_restart :: proc() -> bool {
	return rl.IsKeyPressed(.F6)
}

// In a web build, this is called when browser changes size. Remove the
// `rl.SetWindowSize` call if you don't want a resizable game.
game_parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(i32(w), i32(h))
}
