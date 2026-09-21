package game

import imgui "../vendor/odin-imgui"
import "core:fmt"
import "core:log"
import "core:strings"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

_ :: imgui
_ :: log
_ :: fmt

UI_Type :: enum u8 {
	SoundAndLighting,
	Destructive,
	Sound,
	Lighting,
	Game,
	Innuendo,
}

Tab :: enum u8 {
	Controls,
	Music,
	All,
}

tab_labels := [Tab]cstring {
	.Controls = "Controls",
	.Music    = "Music editor",
	.All      = "All",
}

Button_Style :: struct {
	base, hovered, active: imgui.Vec4,
}

button_styles := [UI_Type]Button_Style {
	.SoundAndLighting = {{0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}}, // default: no push
	.Destructive      = {{0.40, 0.08, 0.08, 1}, {0.60, 0.15, 0.15, 1}, {0.75, 0.20, 0.20, 1}}, // red
	.Sound            = {{0.08, 0.30, 0.10, 1}, {0.15, 0.45, 0.15, 1}, {0.20, 0.55, 0.20, 1}}, // green
	.Lighting         = {{0.38, 0.32, 0.06, 1}, {0.55, 0.48, 0.08, 1}, {0.70, 0.60, 0.10, 1}}, // yellow
	.Game             = {{0.08, 0.16, 0.40, 1}, {0.15, 0.24, 0.60, 1}, {0.20, 0.30, 0.75, 1}}, // blue
	.Innuendo         = {{0.40, 0.16, 0.40, 1}, {0.60, 0.22, 0.60, 1}, {0.75, 0.30, 0.75, 1}}, // pink
}

lighting_look_labels := [LightingLook]cstring {
	.House             = "House",
	.Scene             = "Scene",
	.SceneWithFullFade = "Scene - fade",
	.CenterFocus       = "Center focus",
}

lighting_fx_labels := [LightingFxKind]cstring {
	.Blackout     = "Blackout",
	.RainbowSting = "Rainbow sting",
	.Rain         = "Rain",
	.Innuendo     = "Innuendo",
	.AveMaria     = "Ave Maria",
}

sounds_like_a_song_playlist_retained: ^Playlist

controls_button :: proc(label: cstring, kind: UI_Type, width: f32) -> bool {
	style := button_styles[kind]
	colored := kind != .SoundAndLighting
	height := imgui.GetFrameHeight() * 2
	if colored do imgui.PushStyleColorImVec4(.Button, style.base)
	if colored do imgui.PushStyleColorImVec4(.ButtonHovered, style.hovered)
	if colored do imgui.PushStyleColorImVec4(.ButtonActive, style.active)
	clicked := imgui.Button(label, {width, height})
	if colored do imgui.PopStyleColor(3)
	return clicked
}

controls_group_begin :: proc(label: cstring) {
	imgui.BeginChild(label, child_flags = {.AutoResizeY, .Borders, .NavFlattened})
	imgui.TextUnformatted(label)
}

controls_group_end :: proc() {
	imgui.EndChild()
}

music_browser_playlist_selected :: proc() -> ^Playlist {
	ensure(
		sound_settings.music_browser_playlist_index >= 0 &&
		sound_settings.music_browser_playlist_index < i32(len(sound_settings.playlists)),
	)
	return &sound_settings.playlists[sound_settings.music_browser_playlist_index]
}

music_browser_track_selected :: proc() -> ^Track {
	playlist := music_browser_playlist_selected()
	ensure(
		sound_settings.music_browser_track_index >= 0 &&
		sound_settings.music_browser_track_index < i32(len(playlist.tracks)),
	)
	return &playlist.tracks[sound_settings.music_browser_track_index]
}

show_pre_show :: proc() {
	playlist := playlist_find_by_name(.Kids_on_Bikes_80s_Explore)
	ensure(playlist != nil, "Couldn't find playlist for Pre_Show")

	track := playlist_pick_random_track(playlist)
	ensure(track != nil, "Couldn't pick track for Pre_Show")

	new_playback := music_playback_start_playlist_track(
		playlist,
		track,
		0.3,
		gm.sound_settings.fade_in_time,
	)
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil || &playback == new_playback do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {gm.sound_settings.fade_out_time, 0}})
	}

	lighting_fx_deactivate_all()
	lighting_look_activate(.House)
}

show_post_show :: proc() {
	playlist := playlist_find_by_name(.Kids_on_Bikes_80s_Explore)
	ensure(playlist != nil, "Couldn't find playlist for Post_Show")

	track := playlist_pick_random_track(playlist)
	ensure(track != nil, "Couldn't pick track for Post_Show")

	new_playback := music_playback_start_playlist_track(
		playlist,
		track,
		0.7,
		gm.sound_settings.fade_in_time,
	)
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil || &playback == new_playback do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {gm.sound_settings.fade_out_time, 0}})
	}

	lighting_fx_deactivate_all()
	lighting_look_activate(.House)
}

show_to_house :: proc() {
	if gm.sound_settings.use_house_music {
		playlist := playlist_find_by_name(.Kids_on_Bikes_80s_Explore)
		ensure(playlist != nil, "Couldn't find playlist for To_House")

		track := playlist_pick_random_track(playlist)
		ensure(track != nil, "Couldn't pick track for To_House")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.05,
			gm.sound_settings.fade_in_time,
		)
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil || &playback == new_playback do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}
	} else {
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}
	}

	lighting_fx_deactivate_all()
	lighting_look_activate(.House)
}

show_scene_ramp :: proc() {
	primary := gm.sound_settings.music_playback_primary
	if primary != nil && primary.mixer_track != nil && mixer.TrackPlaying(primary.mixer_track) {
		primary_volume := music_playback_volume_at(
			primary,
			mixer.GetTrackPlaybackPosition(primary.mixer_track),
		)
		gm.sound_settings.music_volume = 1
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil do continue
			if &playback == primary {
				music_playback_volume_set(
					&playback,
					{{0, primary_volume}, {0.5, 1}, {3.5, 1}, {4.5, 0}},
				)
			} else {
				music_playback_stop(&playback)
			}
		}
	}

	lighting_fx_deactivate_all()
	lighting_look_activate(.SceneWithFullFade)
}

show_scene_fade :: proc() {
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {2, 0}})
	}

	lighting_fx_deactivate_all()
	lighting_look_activate(.SceneWithFullFade)
}

show_drop_needle :: proc() {
	playlist := playlist_find_by_name(.Needle_Droppers)
	ensure(playlist != nil, "Couldn't find playlist for Needle_Droppers")

	track := playlist_pick_random_track(playlist)
	ensure(track != nil, "Couldn't pick track for Needle_Droppers")

	for &playback in gm.sound_settings.music_playbacks {
		music_playback_stop(&playback)
	}
	new_playback := music_playback_start_playlist_track(playlist, track, 1, 0)
	ensure(new_playback != nil)

	lighting_fx_run(.Blackout, {{0, 1}, {5, 1}, {7, 0}})
}

show_ave_maria :: proc() {
	playlist := playlist_find_by_name(.Ave_Maria)
	ensure(playlist != nil)

	if playlist_is_current(.Ave_Maria) {
		for &playback in gm.sound_settings.music_playbacks {
			music_playback_stop(&playback)
		}
	} else {
		track := playlist_pick_random_track(playlist)
		ensure(track != nil, "Couldn't pick track for AveMaria")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.8,
			gm.sound_settings.fade_in_time,
		)
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil || &playback == new_playback do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}
	}

	fx := gm.lighting.fx[.Blackout]
	if fx.weight_current > 0 {
		// Blackout is dark: fade it down.
		lighting_fx_run(.Blackout, {{0, fx.weight_current}, {2, 0}})
		lighting_look_activate(.Scene)
	} else {
		// Full blackout right away, hold while the intro plays,
		// then come partway back up over 4s.
		lighting_fx_run(.Blackout, {{0, fx.weight_current}, {1, 1}, {17, 1}, {21, 0.7}})
		lighting_look_activate(.Scene)
	}
}

music_fade_out :: proc() {
	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {gm.sound_settings.fade_out_time, 0}})
	}
}

game_innuendo :: proc() {
	playlist := playlist_find_by_name(.Sex_With_Me)
	ensure(playlist != nil, "Couldn't find playlist for Innuendo")

	if playlist_is_current(.Sex_With_Me) {
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(&playback, {{0, audible}, {2, 0}})
		}
	} else {
		track := playlist_pick_random_track(playlist)
		ensure(track != nil, "Couldn't pick track for Innuendo")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.6,
			gm.sound_settings.fade_in_time,
		)
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil || &playback == new_playback do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}
	}

	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := gm.lighting.fx[.Innuendo]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].weight : 0
	lighting_fx_run(.Innuendo, {{0, fx.weight_current}, {2, 1 - target_prev}})
}

game_oscar_moment :: proc() {
	playlist := playlist_find_by_name(.Mood_Heroic_EPIC)
	ensure(playlist != nil, "Couldn't find playlist for Oscar_Moment")

	current_playback := gm.sound_settings.music_playback_primary
	oscar_moment_playing :=
		current_playback != nil &&
		current_playback.mixer_track != nil &&
		current_playback.playlist == playlist &&
		!current_playback.stopping

	for &playback in gm.sound_settings.music_playbacks {
		if playback.mixer_track == nil do continue
		audible := music_playback_volume_at(
			&playback,
			mixer.GetTrackPlaybackPosition(playback.mixer_track),
		)
		music_playback_volume_set(&playback, {{0, audible}, {gm.sound_settings.fade_out_time, 0}})
	}

	if oscar_moment_playing {
		lighting_look_activate(.Scene)
	} else {
		track := playlist_pick_random_track(playlist)
		ensure(track != nil, "Couldn't pick track for Oscar_Moment")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.3,
			gm.sound_settings.fade_in_time,
		)
		ensure(new_playback != nil, "Couldn't start Oscar_Moment playback")
		music_playback_volume_set(
			new_playback,
			{
				{0, 0},
				{gm.sound_settings.fade_in_time, 0.3},
				{gm.sound_settings.fade_in_time + 20, 0.5},
			},
		)

		lighting_look_activate(.CenterFocus)
	}
}

game_sounds_like_a_song :: proc() {
	current_playback := gm.sound_settings.music_playback_primary
	playlist_playing :=
		sounds_like_a_song_playlist_retained != nil &&
		current_playback != nil &&
		current_playback.mixer_track != nil &&
		current_playback.playlist == sounds_like_a_song_playlist_retained &&
		!current_playback.stopping

	if playlist_playing {
		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}
		sounds_like_a_song_playlist_retained = nil

		lighting_look_activate(.Scene)
	} else {
		playlist := playlist_find_by_name(.Sounds_Like_a_Song)
		ensure(playlist != nil, "Couldn't find playlist for Sounds_Like_a_Song")

		for &playback in gm.sound_settings.music_playbacks {
			if playback.mixer_track == nil do continue
			audible := music_playback_volume_at(
				&playback,
				mixer.GetTrackPlaybackPosition(playback.mixer_track),
			)
			music_playback_volume_set(
				&playback,
				{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
			)
		}

		track := playlist_pick_random_track(playlist)
		ensure(track != nil, "Couldn't pick track for Sounds_Like_a_Song")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.6,
			gm.sound_settings.fade_in_time,
		)
		ensure(new_playback != nil, "Couldn't start Sounds_Like_a_Song playback")
		music_playback_volume_set(new_playback, {{0, 0}, {gm.sound_settings.fade_in_time, 0.5}})
		sounds_like_a_song_playlist_retained = playlist

		lighting_look_activate(.CenterFocus)
	}
}

lighting_house :: proc() {
	lighting_fx_deactivate_all()
	lighting_look_activate(.House)
}

lighting_scene :: proc() {
	lighting_fx_deactivate_all()
	lighting_look_activate(.Scene)
}

lighting_scene_fade :: proc() {
	lighting_fx_deactivate_all()
	lighting_look_activate(.SceneWithFullFade)
}

lighting_fade_to_black :: proc() {
	lighting_fx_deactivate_all()
	lighting_fx_run(.Blackout, {{0, gm.lighting.fx[.Blackout].weight_current}, {2, 1}})
}

lighting_cut_to_black :: proc() {
	lighting_fx_deactivate_all()
	lighting_fx_run(.Blackout, {{0, 1}})
}

lighting_center_focus :: proc() {
	lighting_fx_deactivate_all()
	lighting_look_activate(.CenterFocus)
}

lighting_innuendo_toggle :: proc() {
	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := gm.lighting.fx[.Innuendo]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].weight : 0
	lighting_fx_run(.Innuendo, {{0, fx.weight_current}, {2, 1 - target_prev}})
	lighting_look_activate(.Scene)
}

lighting_rainbow_sting_toggle :: proc() {
	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := gm.lighting.fx[.RainbowSting]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].weight : 0
	lighting_fx_run(.RainbowSting, {{0, fx.weight_current}, {2, 1 - target_prev}})
}

sound_play_break_glass :: proc() {
	sound_play(.Glass_Breaking_Sound_Effect_HD_Glass_Shattering_Sound_Effect_TcnufvBffcY, 0.9)
}

sound_play_gunshot :: proc() {
	sound_play(.Single_Gunshot_54_40780, 0.7)
}

sound_play_scream_lady :: proc() {
	sound_play(.Woman_Screaming_Sfx_Screaming_Sound_Effect_320169, 0.7)
}

sound_play_fireworks :: proc() {
	sound_play(.Fireworks_13_419033, 0.4)
}

sound_play_train_horn :: proc() {
	sound_play(.Train_Horn_337875, 0.9)
}

sound_play_tick_tick_ding :: proc() {
	sound_play(.Ticktickding, 1.0)
}

sound_play_ding :: proc() {
	sound_play(.Ding_126626, 1.0)
}

sound_play_lightning :: proc() {
	sound_play(.Lightning_237994, 0.8)
}

sound_play_rain :: proc() {
	sound_play(.Calming_Rain_257596, 0.3)
}

sound_play_meow :: proc() {
	sound_play(.Cat_Meow, 0.7)
}

sound_play_yeeeaaahhh :: proc() {
	sound_play(.Yeeeeaaaaaaaahh, 1)
}

hotkeys_handle_key :: proc(key: sdl.Keycode) {
	switch key {
	case sdl.K_PLUS:
		music_volume_adjust(+0.005)
	case sdl.K_MINUS:
		music_volume_adjust(-0.005)
	case sdl.K_A:
		show_pre_show()
	case sdl.K_R:
		show_post_show()
	case sdl.K_S:
		show_to_house()
	case sdl.K_T:
		show_scene_ramp()
	case sdl.K_G:
		show_scene_fade()
	case sdl.K_M:
		show_drop_needle()
	case sdl.K_N:
		show_ave_maria()
	case sdl.K_Q:
		game_innuendo()
	case sdl.K_W:
		game_oscar_moment()
	case sdl.K_F:
		game_sounds_like_a_song()
	case sdl.K_P:
		lighting_house()
	case sdl.K_B:
		lighting_scene()
	case sdl.K_J:
		lighting_scene_fade()
	case sdl.K_L:
		lighting_fade_to_black()
	case sdl.K_U:
		lighting_cut_to_black()
	case sdl.K_Y:
		lighting_center_focus()
	case sdl.K_SEMICOLON:
		lighting_innuendo_toggle()
	case sdl.K_BACKSLASH:
		lighting_rainbow_sting_toggle()
	case sdl.K_Z:
		sound_play_break_glass()
	case sdl.K_X:
		sound_play_gunshot()
	case sdl.K_C:
		sound_play_scream_lady()
	case sdl.K_D:
		sound_play_fireworks()
	case sdl.K_V:
		sound_play_train_horn()
	case sdl.K_K:
		sound_play_tick_tick_ding()
	case sdl.K_H:
		sound_play_ding()
	case sdl.K_COMMA:
		sound_play_lightning()
	case sdl.K_PERIOD:
		sound_play_rain()
	case sdl.K_SLASH:
		sound_play_meow()
	case sdl.K_E:
		music_fade_out()
	case sdl.K_O:
		sound_play_yeeeaaahhh()
	}
}

color := [3]f32{1, 1, 1}
controls_draw :: proc() {
	// imgui.ShowDemoWindow()

	vp := imgui.GetMainViewport()
	imgui.SetNextWindowPos(vp.WorkPos)
	imgui.SetNextWindowSize(vp.WorkSize)

	imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
	imgui.PushStyleVar(.WindowRounding, 0)
	imgui.PushStyleVar(.WindowBorderSize, 0)

	imgui.Begin(
		"Root",
		nil,
		{
			.NoTitleBar,
			.NoResize,
			.NoMove,
			.NoCollapse,
			.NoBackground,
			.NoSavedSettings,
			.NoBringToFrontOnFocus,
			.NoNavFocus,
		},
	)
	imgui.PopStyleVar(3)

	if imgui.BeginTabBar("TopTabs") {
		music_tab_selected := false
		if imgui.BeginTabItem(tab_labels[.Controls]) {
			gm.active_tab = .Controls
			xs := strings.clone_to_cstring(
				strings.repeat("X", 19, context.temp_allocator),
				context.temp_allocator,
			)
			button_width := imgui.CalcTextSize(xs).x + imgui.GetStyle().FramePadding.x * 2

			left_width := max(
				imgui.GetContentRegionAvail().x -
				TIMER_PANEL_WIDTH -
				imgui.GetStyle().ItemSpacing.x,
				100,
			)
			imgui.BeginChild("ControlsMain", {left_width, 0})

			{
				if imgui.Checkbox("Use house music", &gm.sound_settings.use_house_music) {
					if gm.sound_settings.use_house_music {
						if gm.sound_settings.current_playing_playlist == nil {
							playlist := playlist_find_by_name(.Kids_on_Bikes_80s_Chill)
							ensure(playlist != nil, "Couldn't find playlist for Use_House_Music")

							track := playlist_pick_random_track(playlist)
							ensure(track != nil, "Couldn't pick track for Use_House_Music")

							new_playback := music_playback_start_playlist_track(
								playlist,
								track,
								0.2,
								gm.sound_settings.fade_in_time,
							)
							for &playback in gm.sound_settings.music_playbacks {
								if playback.mixer_track == nil || &playback == new_playback do continue
								audible := music_playback_volume_at(
									&playback,
									mixer.GetTrackPlaybackPosition(playback.mixer_track),
								)
								music_playback_volume_set(
									&playback,
									{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
								)
							}
						}
					}
					sound_settings_save()
				}
				imgui.SameLine(spacing = 16)

				imgui.PushItemWidth(460)
				music_vol := sound_music_current_volume() * 100
				if imgui.SliderFloat(
					"Volume",
					&music_vol,
					0,
					100,
					"%.1f%%",
					imgui.SliderFlags_AlwaysClamp,
				) {
					gm.sound_settings.music_volume = music_vol / 100
					primary := gm.sound_settings.music_playback_primary
					if primary != nil && primary.mixer_track != nil {
						music_playback_volume_set(primary, {{0, gm.sound_settings.music_volume}})
					}
					sound_settings_save()
				}
				imgui.PopItemWidth()
			}

			{
				controls_group_begin("Show")

				if controls_button("Pre-show (a)", .SoundAndLighting, button_width) {
					show_pre_show()
				}
				imgui.SameLine()

				if controls_button("Post-show (r)", .SoundAndLighting, button_width) {
					show_post_show()
				}
				imgui.SameLine()

				if controls_button("Ave Maria (n)", .SoundAndLighting, button_width) {
					show_ave_maria()
				}

				if controls_button("To house (s)", .SoundAndLighting, button_width) {
					show_to_house()
				}
				imgui.SameLine()

				if controls_button("Scene - ramp (t)", .SoundAndLighting, button_width) {
					show_scene_ramp()
				}
				imgui.SameLine()

				if controls_button("Scene - fade (g)", .SoundAndLighting, button_width) {
					show_scene_fade()
				}
				imgui.SameLine()

				if controls_button("Drop needle (m)", .Destructive, button_width) {
					show_drop_needle()
				}

				controls_group_end()
			}

			{
				controls_group_begin("Games")

				if controls_button("Innuendo (q)", .Innuendo, button_width) {
					game_innuendo()
				}
				imgui.SameLine()

				if controls_button("Oscar Moment (w)", .Game, button_width) {
					game_oscar_moment()
				}
				imgui.SameLine()

				if controls_button("Sounds Like\n a Song (f)", .Game, button_width) {
					game_sounds_like_a_song()
				}

				controls_group_end()
			}

			{
				controls_group_begin("Lighting")

				if controls_button("House (p)##Lighting", .Lighting, button_width) {
					lighting_house()
				}
				imgui.SameLine()
				if controls_button("Scene (b)##Lighting", .Lighting, button_width) {
					lighting_scene()
				}
				imgui.SameLine()
				if controls_button("Scene - fade (j)##Lighting", .Lighting, button_width) {
					lighting_scene_fade()
				}
				imgui.SameLine()
				if controls_button("Fade to black (l)##Lighting", .Lighting, button_width) {
					lighting_fade_to_black()
				}
				imgui.SameLine()
				if controls_button("Cut to black (u)##Lighting", .Lighting, button_width) {
					lighting_cut_to_black()
				}
				if controls_button("Center focus (y)##Lighting", .Lighting, button_width) {
					lighting_center_focus()
				}
				imgui.SameLine()
				{
					fx := gm.lighting.fx[.Innuendo]
					text := "Innuendo"
					target_prev: f32
					if fx.weight_current > 0 {
						text = "Cancel Innuendo"
						target_prev = fx.keys[fx.key_count - 1].weight
					}
					if controls_button(
						strings.clone_to_cstring(
							fmt.tprint(text, "(;)##Lighting"),
							context.temp_allocator,
						),
						.Lighting,
						button_width,
					) {
						lighting_innuendo_toggle()
					}
				}
				imgui.SameLine()
				{
					fx := gm.lighting.fx[.RainbowSting]
					text := " Rainbow Sting"
					target_prev: f32
					if fx.weight_current > 0 {
						text = "    Cancel\n Rainbow Sting"
						target_prev = fx.keys[fx.key_count - 1].weight
					}
					if controls_button(
						strings.clone_to_cstring(
							fmt.tprint(text, " (\\)##Lighting"),
							context.temp_allocator,
						),
						.Lighting,
						button_width,
					) {
						lighting_rainbow_sting_toggle()
					}
				}

				{
					origin := imgui.GetCursorScreenPos()
					w := imgui.GetFrameHeight() * 4
					imgui.SetNextItemAllowOverlap()
					imgui.InvisibleButton("##lights-start", {w, w})
					imgui.SameLine()

					draw_list := imgui.GetWindowDrawList()
					r := w / 3

					imgui.DrawList_AddRectFilled(
						draw_list,
						origin,
						{origin.x + w, origin.y + w},
						imgui.GetColorU32ImVec4({0.3, 0.3, 0.3, 1}),
					)

					imgui.DrawList_AddCircleFilled(
						draw_list,
						{origin.x + w / 2, origin.y + w / 2},
						r,
						imgui.GetColorU32ImVec4({color[0], color[1], color[2], 1}),
					)

					picker_button_w: f32 = 20
					imgui.SetCursorScreenPos({origin.x + w - picker_button_w, origin.y})
					if imgui.ColorButton(
						"colorpicker",
						{color[0], color[1], color[2], 1},
						size = {picker_button_w, picker_button_w},
					) {
						imgui.OpenPopup("##lights-color")
					}

					if imgui.BeginPopup("##lights-color") {
						imgui.PushItemWidth(imgui.GetFrameHeight() * 8)
						imgui.ColorPicker3(
							"##lights-color-value",
							&color,
							{.NoSidePreview, .PickerHueWheel},
						)
						imgui.PopItemWidth()
						imgui.EndPopup()
					}
				}

				controls_group_end()
			}

			{
				controls_group_begin("Sounds")

				if controls_button(
					"Break glass (z)",
					.Sound,
					button_width,
				) {sound_play_break_glass()}
				imgui.SameLine()
				if controls_button("Gunshot (x)", .Sound, button_width) {sound_play_gunshot()}
				imgui.SameLine()
				if controls_button(
					"Scream, lady! (c)",
					.Sound,
					button_width,
				) {sound_play_scream_lady()}
				imgui.SameLine()
				if controls_button("Fireworks (d)", .Sound, button_width) {sound_play_fireworks()}
				if controls_button(
					"Train horn (v)",
					.Sound,
					button_width,
				) {sound_play_train_horn()}
				imgui.SameLine()
				if controls_button(
					"Tick tick ding (k)",
					.Sound,
					button_width,
				) {sound_play_tick_tick_ding()}
				imgui.SameLine()
				if controls_button("Ding (h)", .Sound, button_width) {sound_play_ding()}
				imgui.SameLine()
				if controls_button("Lightning (,)", .Sound, button_width) {sound_play_lightning()}
				imgui.SameLine()
				if controls_button("Rain (.)", .Sound, button_width) {sound_play_rain()}
				imgui.SameLine()
				if controls_button("Meow (/)", .Sound, button_width) {sound_play_meow()}
				imgui.SameLine()
				if controls_button(
					"Yeeeaaahhh (o)",
					.Sound,
					button_width,
				) {sound_play_yeeeaaahhh()}

				controls_group_end()
			}

			{
				imgui.BeginChild(
					"Music",
					{0, imgui.GetContentRegionAvail().y},
					child_flags = {.AutoResizeY, .Borders},
				)

				imgui.AlignTextToFramePadding()
				imgui.TextUnformatted("Music")

				{
					primary := gm.sound_settings.music_playback_primary
					if primary != nil {
						imgui.SameLine()

						style := button_styles[.Sound]
						imgui.PushStyleVarX(.FramePadding, 16)
						imgui.PushStyleColorImVec4(.Button, style.base)
						imgui.PushStyleColorImVec4(.ButtonHovered, style.hovered)
						imgui.PushStyleColorImVec4(.ButtonActive, style.active)
						if imgui.Button("Fade out (e)", {0, 0}) {
							for &playback in gm.sound_settings.music_playbacks {
								if playback.mixer_track == nil do continue
								audible := music_playback_volume_at(
									&playback,
									mixer.GetTrackPlaybackPosition(playback.mixer_track),
								)
								music_playback_volume_set(&playback, {{0, audible}, {2, 0}})
							}
						}
						imgui.PopStyleColor(3)
						imgui.PopStyleVar(1)
					}
				}

				if imgui.BeginChild("Playlists##ControlList", {0, 0}, {.FrameStyle}) {
					for &playlist, index in sound_settings.playlists {
						if imgui.Selectable(
							strings.clone_to_cstring(playlist.name, context.temp_allocator),
							sound_settings.music_playback_primary != nil &&
							sound_settings.music_playback_primary.playlist == &playlist,
						) {
							ensure(len(playlist.tracks) > 0)
							sound_settings.music_browser_playlist_index = i32(index)
							sound_settings.music_browser_track_index = 0
							wave_editor_track_select(&playlist.tracks[0])

							primary := gm.sound_settings.music_playback_primary
							if primary != nil && primary.playlist == &playlist {
								for &playback in gm.sound_settings.music_playbacks {
									if playback.mixer_track == nil do continue
									audible := music_playback_volume_at(
										&playback,
										mixer.GetTrackPlaybackPosition(playback.mixer_track),
									)
									music_playback_volume_set(&playback, {{0, audible}, {2, 0}})
								}
							} else {
								track := playlist_pick_random_track(&playlist)
								ensure(track != nil, "Couldn't pick track for playlist")

								new_playback := music_playback_start_playlist_track(
									&playlist,
									track,
									0.3,
									gm.sound_settings.fade_in_time,
								)
								for &playback in gm.sound_settings.music_playbacks {
									if playback.mixer_track == nil || &playback == new_playback do continue
									audible := music_playback_volume_at(
										&playback,
										mixer.GetTrackPlaybackPosition(playback.mixer_track),
									)
									music_playback_volume_set(
										&playback,
										{{0, audible}, {gm.sound_settings.fade_out_time, 0}},
									)
								}
							}
						}
					}
				}
				imgui.EndChild()

				controls_group_end()
			}

			imgui.EndChild()
			imgui.SameLine()
			timers_draw()

			imgui.EndTabItem()
		}

		if imgui.BeginTabItem(tab_labels[.Music]) {
			music_tab_selected = true
			gm.active_tab = .Music

			imgui.BeginGroup()
			imgui.Text("Playlist")
			if imgui.BeginChild("Playlist##List", {300, 0}, {.FrameStyle}) {
				for &candidate, index in sound_settings.playlists {
					if imgui.Selectable(
						strings.clone_to_cstring(candidate.name, context.temp_allocator),
						i32(index) == sound_settings.music_browser_playlist_index,
					) {
						ensure(len(candidate.tracks) > 0)
						sound_settings.music_browser_playlist_index = i32(index)
						sound_settings.music_browser_track_index = 0
						wave_editor_track_select(&candidate.tracks[0])
					}
				}
			}
			imgui.EndChild()
			imgui.EndGroup()

			imgui.SameLine()

			imgui.BeginGroup()
			imgui.Text("Track")
			playlist := music_browser_playlist_selected()
			if imgui.BeginChild(
				"Track##List",
				{
					0,
					-(WAVEFORM_HEIGHT +
						imgui.GetFrameHeightWithSpacing() +
						WAVEFORM_HANDLE_RADIUS +
						imgui.GetStyle().ItemSpacing.y),
				},
				child_flags = {.FrameStyle},
			) {
				for &candidate, index in playlist.tracks {
					if imgui.Selectable(
						strings.clone_to_cstring(candidate.title, context.temp_allocator),
						i32(index) == sound_settings.music_browser_track_index,
					) {
						sound_settings.music_browser_track_index = i32(index)
						wave_editor_track_select(&candidate)
					}
				}
			}
			imgui.EndChild()

			if wave_editor_preview_is_playing() {
				if imgui.Button("Stop preview") do wave_editor_preview_stop()
			} else if imgui.Button("Preview bounds") {
				wave_editor_preview_start(music_browser_track_selected())
			}
			wave_editor()

			imgui.EndGroup()

			imgui.EndTabItem()
		}

		if imgui.BeginViewportSideBar(
			"StatusBar",
			vp,
			.Down,
			imgui.GetFrameHeight() * 2,
			{.NoScrollbar, .NoSavedSettings},
		) {
			imgui.AlignTextToFramePadding()
			imgui.Text(strings.clone_to_cstring(music_current_label(), context.temp_allocator))

			imgui.SameLine()
			imgui.Text("| Lighting: %s", lighting_look_labels[gm.lighting.active_look])

			lighting_fx_count := 0
			for &fx, kind in gm.lighting.fx {
				if fx.weight_current <= 0 do continue

				imgui.SameLine(0, 0)
				if lighting_fx_count == 0 {
					imgui.TextUnformatted(" | FX: ")
				} else {
					imgui.TextUnformatted(", ")
				}

				imgui.SameLine(0, 0)
				imgui.Text("%s %.0f%%", lighting_fx_labels[kind], f64(fx.weight_current * 100))
				lighting_fx_count += 1
			}

			progress_bar_width: f32 = 150
			imgui.SameLine(imgui.GetContentRegionAvail().x - progress_bar_width)

			music_progress := music_current_progress()
			music_played, music_length := music_current_time()
			music_time_text := music_time_pair_label(music_played, music_length)
			imgui.ProgressBar(
				music_progress,
				{progress_bar_width, 0},
				strings.clone_to_cstring(music_time_text, context.temp_allocator),
			)
		}
		imgui.End()

		if !music_tab_selected do wave_editor_preview_stop()

		imgui.EndTabBar()
	}

	imgui.End()
}
