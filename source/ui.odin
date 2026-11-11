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
	.Challenge         = "Challenge",
	.FinalShowdown     = "Final Showdown",
}

lighting_fx_labels := [LightingFxKind]cstring {
	.Blackout     = "Blackout",
	.RainbowSting = "Rainbow sting",
	.Pulsing      = "Pulsing",
	.Rain         = "Rain",
	.Innuendo     = "Innuendo",
	.AveMaria     = "Ave Maria",
}

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

controls_group_begin :: proc(
	label: cstring,
	position: imgui.Vec2,
	width: f32,
	height: f32 = 0,
	initial_height: f32 = 0,
) {
	layout := imgui.GetCurrentWindow()
	focus_scope := imgui.GetCurrentFocusScope()
	parent_draw_list := imgui.GetWindowDrawList()
	clip_min := imgui.DrawList_GetClipRectMin(parent_draw_list)
	clip_max := imgui.DrawList_GetClipRectMax(parent_draw_list)
	imgui.PushID(label)
	flags: imgui.WindowFlags = {
		.NoMove,
		.NoCollapse,
		.NoSavedSettings,
		.NoDocking,
		.NoScrollbar,
		.NoScrollWithMouse,
	}
	if !imgui.IsMouseHoveringRect(clip_min, clip_max) do flags += {.NoMouseInputs}
	imgui.SetNextWindowPos(position)
	storage := imgui.GetStateStorage()
	resize_id := imgui.GetID("ResizeHeight")
	content_height := imgui.Storage_GetFloat(storage, imgui.GetID("Height"))
	minimum_height := height > 0 ? f32(200) : max(content_height, imgui.GetFrameHeight())
	maximum_height := height > 0 ? height : f32(1e6)
	window_height := clamp(
		imgui.Storage_GetFloat(
			storage,
			resize_id,
			initial_height > 0 ? initial_height : height > 0 ? height : content_height,
		),
		minimum_height,
		maximum_height,
	)
	// Column widths stay aligned; content and the score reservation bound height resizing.
	imgui.SetNextWindowSizeConstraints({width, minimum_height}, {width, maximum_height})
	imgui.SetNextWindowSize({width, window_height})
	imgui.Begin(label, nil, flags)
	imgui.PushItemWidth(imgui.GetFontSize() * 16)
	if resized_height := imgui.GetWindowHeight(); resized_height != window_height {
		imgui.Storage_SetFloat(storage, resize_id, resized_height)
	}
	// Independent panel windows share the layout's keyboard navigation scope.
	window := imgui.GetCurrentWindow()
	window.ChildFlags += {.NavFlattened}
	imgui.UpdateWindowParentAndRootLinks(window, window.Flags, layout)
	imgui.PushFocusScope(focus_scope)
	if imgui.IsWindowFocused() {
		imgui.SetNavFocusScope(focus_scope)
		if imgui.GetFocusID() == 0 do imgui.NavInitWindow(window, true)
	}
	// Window decorations and widgets share the layout's visible bounds.
	draw_list := imgui.GetWindowDrawList()
	for &command in ([^]imgui.DrawCmd)(draw_list.CmdBuffer.Data)[:draw_list.CmdBuffer.Size] {
		command.ClipRect = {
			max(command.ClipRect.x, clip_min.x),
			max(command.ClipRect.y, clip_min.y),
			min(command.ClipRect.z, clip_max.x),
			min(command.ClipRect.w, clip_max.y),
		}
	}
	imgui.PushClipRect(clip_min, clip_max, true)
}

controls_group_end :: proc() {
	position := imgui.GetWindowPos()
	size := imgui.GetWindowSize()
	content_height :=
		imgui.GetCursorPos().y - imgui.GetStyle().ItemSpacing.y + imgui.GetStyle().WindowPadding.y
	has_content := imgui.GetCursorPos().y > imgui.GetCursorStartPos().y
	focus_id :=
		imgui.IsWindowFocused({.ChildWindows}) && imgui.GetIO().NavVisible ? imgui.GetFocusID() : 0
	imgui.PopClipRect()
	imgui.PopItemWidth()
	imgui.PopFocusScope()
	imgui.End()
	if has_content {
		imgui.Storage_SetFloat(imgui.GetStateStorage(), imgui.GetID("Height"), content_height)
	}
	// Reserve the settled height so reflow does not move a resize grip during a drag.
	if !imgui.IsMouseDown(.Left) {
		imgui.Storage_SetFloat(imgui.GetStateStorage(), imgui.GetID("LayoutHeight"), size.y)
	}
	imgui.PopID()
	if focus_id != 0 {
		storage := imgui.GetStateStorage()
		key := imgui.GetID("FocusID")
		if imgui.Storage_GetInt(storage, key) != i32(focus_id) {
			imgui.Storage_SetInt(storage, key, i32(focus_id))
			imgui.ScrollToRect(
				imgui.GetCurrentWindow(),
				{position, position + size},
				{.KeepVisibleEdgeY},
			)
		}
	}
	imgui.SetCursorScreenPos(position)
	imgui.Dummy(size)
}

controls_layout_begin :: proc(label: cstring, size: imgui.Vec2 = {0, 0}) {
	imgui.BeginChild(label, size, window_flags = {.NoScrollWithMouse})
}

controls_layout_end :: proc(scroll_with_mouse: bool = true) {
	imgui.Storage_SetInt(imgui.GetStateStorage(), imgui.GetID("FocusID"), i32(imgui.GetFocusID()))
	if scroll_with_mouse &&
	   imgui.GetIO().MouseWheel != 0 &&
	   imgui.IsMouseHoveringRect(
		   imgui.GetWindowPos(),
		   imgui.GetWindowPos() + imgui.GetWindowSize(),
	   ) &&
	   !imgui.IsPopupOpen(nil, imgui.PopupFlags_AnyPopup) {
		imgui.SetScrollY(
			imgui.GetScrollY() -
			imgui.GetIO().MouseWheel * imgui.GetTextLineHeightWithSpacing() * 5,
		)
	}
	imgui.EndChild()
}

controls_list_begin :: proc(label: cstring, height: f32) -> bool {
	ensure(height > 0)
	return imgui.BeginChild(label, {0, height}, {.FrameStyle, .NavFlattened})
}

music_browser_playlist_selected :: proc() -> Entity_Handle {
	ensure(
		gm.sound_settings.music_browser_playlist_index >= 0 &&
		gm.sound_settings.music_browser_playlist_index < i32(len(gm.entities.playlist)),
	)
	return gm.entities.playlist[gm.sound_settings.music_browser_playlist_index]
}

music_browser_track_selected :: proc() -> Entity_Handle {
	playlist := entity_must_get(music_browser_playlist_selected())
	ensure(
		gm.sound_settings.music_browser_track_index >= 0 &&
		gm.sound_settings.music_browser_track_index < i32(len(playlist.playlist_tracks)),
	)
	return playlist.playlist_tracks[gm.sound_settings.music_browser_track_index]
}

show_pre_show :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Music, .Has_Lighting},
		triggers          = {.Music, .Lighting},
		playlist          = entity_playlist_handle_for_name(.Kids_on_Bikes_80s_Explore),
		music_volume      = 0.3,
		fade_in_s         = gm.sound_settings.fade_in_time,
		fade_out_s        = gm.sound_settings.fade_out_time,
		look              = .House,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

show_arena_pre_show :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Music, .Has_Lighting},
		triggers          = {.Music, .Lighting},
		playlist          = entity_playlist_handle_for_name(.Arena_Pre_show),
		music_volume      = 0.2,
		fade_in_s         = gm.sound_settings.fade_in_time,
		fade_out_s        = gm.sound_settings.fade_out_time,
		look              = .House,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

show_start :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Music},
		triggers     = {.Music},
		playlist     = entity_playlist_handle_for_name(.Show_Starters),
		music_volume = 0.7,
		fade_in_s    = 0.5,
		fade_out_s   = gm.sound_settings.fade_out_time,
	}
	cue_dispatch(&cue)
}

show_post_show :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Music, .Has_Lighting},
		triggers          = {.Music, .Lighting},
		playlist          = entity_playlist_handle_for_name(.Kids_on_Bikes_80s_Explore),
		music_volume      = 0.7,
		fade_in_s         = gm.sound_settings.fade_in_time,
		fade_out_s        = gm.sound_settings.fade_out_time,
		look              = .House,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

show_to_house :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Lighting},
		triggers          = {.Lighting},
		look              = .House,
		lighting_fx_reset = true,
	}
	if gm.sound_settings.use_house_music {
		cue.caps += {.Has_Music}
		cue.triggers += {.Music}
		cue.playlist = entity_playlist_handle_for_name(.Kids_on_Bikes_80s_Explore)
		cue.music_volume = 0.05
		cue.fade_in_s = gm.sound_settings.fade_in_time
		cue.fade_out_s = gm.sound_settings.fade_out_time
		cue_dispatch(&cue)
	} else {
		music_playbacks_fade_all(gm.sound_settings.fade_out_time)
		cue_dispatch(&cue)
	}
}

show_scene_ramp :: proc() {
	primary, primary_ok := music_primary_playback()
	if primary_ok && primary.mixer_track != nil && mixer.TrackPlaying(primary.mixer_track) {
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
	cue := Entity_Cue {
		caps              = {.Has_Music, .Has_Lighting, .Has_Video},
		triggers          = {.Lighting, .Fade_Out},
		fade_out_s        = 2,
		look              = .SceneWithFullFade,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

show_drop_needle :: proc() {
	playlist := playlist_find_by_name(.Needle_Droppers)
	ensure(playlist != ENTITY_HANDLE_NIL, "Couldn't find playlist for Needle_Droppers")

	track := playlist_pick_random_track(playlist)
	ensure(track != ENTITY_HANDLE_NIL, "Couldn't pick track for Needle_Droppers")

	for &playback in gm.sound_settings.music_playbacks {
		music_playback_stop(&playback)
	}
	new_playback := music_playback_start_playlist_track(playlist, track, 1, 0)
	ensure(new_playback != nil)

	lighting_fx_run(.Blackout, {{0, 1}, {5, 1}, {7, 0}})
}

show_ave_maria :: proc() {
	if playlist_is_current(.Ave_Maria) {
		for &playback in gm.sound_settings.music_playbacks {
			music_playback_stop(&playback)
		}
	} else {
		cue := Entity_Cue {
			caps         = {.Has_Music},
			triggers     = {.Music},
			playlist     = entity_playlist_handle_for_name(.Ave_Maria),
			music_volume = 0.8,
			fade_in_s    = gm.sound_settings.fade_in_time,
			fade_out_s   = 0.3,
		}
		cue_dispatch(&cue)
	}

	fx := lighting_state(lighting_entity_ensure()).fx[.Blackout]
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
	music_playbacks_fade_all(gm.sound_settings.fade_out_time)
}

game_innuendo :: proc() {
	if playlist_is_current(.Sex_With_Me) {
		music_playbacks_fade_all(2)
	} else {
		cue := Entity_Cue {
			caps         = {.Has_Music},
			triggers     = {.Music},
			playlist     = entity_playlist_handle_for_name(.Sex_With_Me),
			music_volume = 0.6,
			fade_in_s    = gm.sound_settings.fade_in_time,
			fade_out_s   = gm.sound_settings.fade_out_time,
		}
		cue_dispatch(&cue)
	}

	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := lighting_state(lighting_entity_ensure()).fx[.Innuendo]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].value : 0
	lighting_fx_run(.Innuendo, {{0, fx.weight_current}, {2, 1 - target_prev}})
}

game_oscar_moment :: proc() {
	playlist := playlist_find_by_name(.Mood_Heroic_EPIC)
	ensure(playlist != ENTITY_HANDLE_NIL, "Couldn't find playlist for Oscar_Moment")

	primary, primary_ok := music_primary_playback()
	primary_entity, primary_entity_ok := entity_get(gm.music_primary)
	oscar_moment_playing :=
		primary_ok &&
		primary.mixer_track != nil &&
		primary_entity_ok &&
		primary_entity.music.playlist == playlist &&
		!primary.stopping

	music_playbacks_fade_all(gm.sound_settings.fade_out_time)

	if oscar_moment_playing {
		lighting_look_activate(.Scene)
	} else {
		track := playlist_pick_random_track(playlist)
		ensure(track != ENTITY_HANDLE_NIL, "Couldn't pick track for Oscar_Moment")

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
	primary, primary_ok := music_primary_playback()
	primary_entity, primary_entity_ok := entity_get(gm.music_primary)
	playlist_playing :=
		gm.game_mode.sounds_like_a_song_playlist != ENTITY_HANDLE_NIL &&
		primary_ok &&
		primary.mixer_track != nil &&
		primary_entity_ok &&
		primary_entity.music.playlist == gm.game_mode.sounds_like_a_song_playlist &&
		!primary.stopping

	if playlist_playing {
		music_playbacks_fade_all(gm.sound_settings.fade_out_time)
		gm.game_mode.sounds_like_a_song_playlist = ENTITY_HANDLE_NIL
	} else {
		playlist := playlist_find_by_name(.Sounds_Like_a_Song)
		ensure(playlist != ENTITY_HANDLE_NIL, "Couldn't find playlist for Sounds_Like_a_Song")

		music_playbacks_fade_all(gm.sound_settings.fade_out_time)

		track := playlist_pick_random_track(playlist)
		ensure(track != ENTITY_HANDLE_NIL, "Couldn't pick track for Sounds_Like_a_Song")

		new_playback := music_playback_start_playlist_track(
			playlist,
			track,
			0.6,
			gm.sound_settings.fade_in_time,
		)
		ensure(new_playback != nil, "Couldn't start Sounds_Like_a_Song playback")
		music_playback_volume_set(new_playback, {{0, 0}, {gm.sound_settings.fade_in_time, 0.5}})
		gm.game_mode.sounds_like_a_song_playlist = playlist
	}
}

game_challenge :: proc() {
	sound_play(.Double_Orchestral_Hits_C, 1.0, 1.0)
	lighting_look_activate(.Challenge)
}

game_final_showdown :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound, .Has_Lighting},
		triggers     = {.Sound, .Lighting},
		sound        = ._810166_Long_Brass_Stab,
		sound_volume = 1,
		look         = .FinalShowdown,
	}
	cue_dispatch(&cue)
}

lighting_house :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Lighting},
		triggers          = {.Lighting},
		look              = .House,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

lighting_scene :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Lighting},
		triggers          = {.Lighting},
		look              = .Scene,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

lighting_scene_fade :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Lighting, .Has_Video},
		triggers          = {.Lighting, .Fade_Out},
		fade_out_s        = 2,
		look              = .SceneWithFullFade,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

lighting_fade_to_black :: proc() {
	lighting_fx_deactivate_all()
	lighting_fx_run(
		.Blackout,
		{{0, lighting_state(lighting_entity_ensure()).fx[.Blackout].weight_current}, {2, 1}},
	)
	fade := Entity_Cue {
		caps       = {.Has_Video},
		triggers   = {.Fade_Out},
		fade_out_s = 2,
	}
	cue_dispatch(&fade)
}

lighting_cut_to_black :: proc() {
	lighting_fx_deactivate_all()
	lighting_fx_run(.Blackout, {{0, 1}})
	video_page_clear()
}

lighting_center_focus :: proc() {
	cue := Entity_Cue {
		caps              = {.Has_Lighting},
		triggers          = {.Lighting},
		look              = .CenterFocus,
		lighting_fx_reset = true,
	}
	cue_dispatch(&cue)
}

lighting_innuendo_toggle :: proc() {
	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := lighting_state(lighting_entity_ensure()).fx[.Innuendo]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].value : 0
	lighting_fx_run(.Innuendo, {{0, fx.weight_current}, {2, 1 - target_prev}})
	lighting_look_activate(.Scene)
}

lighting_rainbow_sting_toggle :: proc() {
	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := lighting_state(lighting_entity_ensure()).fx[.RainbowSting]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].value : 0
	lighting_fx_run(.RainbowSting, {{0, fx.weight_current}, {2, 1 - target_prev}})
}

lighting_pulsing_toggle :: proc() {
	// Toggle: head for the opposite of wherever the last envelope
	// was going, starting from the current weight.
	fx := lighting_state(lighting_entity_ensure()).fx[.Pulsing]
	target_prev := fx.key_count > 0 ? fx.keys[fx.key_count - 1].value : 0
	lighting_fx_run(.Pulsing, {{0, fx.weight_current}, {2, 1 - target_prev}})
}

sound_play_break_glass :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Glass_Breaking_Sound_Effect_HD_Glass_Shattering_Sound_Effect_TcnufvBffcY,
		sound_volume = 0.9,
	}
	cue_dispatch(&cue)
}

sound_play_gunshot :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Single_Gunshot_54_40780,
		sound_volume = 0.7,
	}
	cue_dispatch(&cue)
}

sound_play_scream_lady :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Woman_Screaming_Sfx_Screaming_Sound_Effect_320169,
		sound_volume = 0.7,
	}
	cue_dispatch(&cue)
}

sound_play_fireworks :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Fireworks_13_419033,
		sound_volume = 0.4,
	}
	cue_dispatch(&cue)
}

sound_play_train_horn :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Train_Horn_337875,
		sound_volume = 0.9,
	}
	cue_dispatch(&cue)
}

sound_play_tick_tick_ding :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Ticktickding,
		sound_volume = 1.0,
	}
	cue_dispatch(&cue)
}

sound_play_ding :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Ding_126626,
		sound_volume = 1.0,
	}
	cue_dispatch(&cue)
}

sound_play_lightning :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Lightning_237994,
		sound_volume = 0.8,
	}
	cue_dispatch(&cue)
}

sound_play_rain :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Calming_Rain_257596,
		sound_volume = 0.3,
	}
	cue_dispatch(&cue)
}

sound_play_meow :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Cat_Meow,
		sound_volume = 0.7,
	}
	cue_dispatch(&cue)
}

sound_play_yeeeaaahhh :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Yeeeeaaaaaaaahh,
		sound_volume = 1,
	}
	cue_dispatch(&cue)
}

sound_play_buzzer :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = ._244932_Kwahmah_02_Short_Buzzer,
		sound_volume = 0.3,
	}
	cue_dispatch(&cue)
}

sound_play_whistle :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = ._495367_Kirkpatricklive_Coach_Whistle_35_Long,
		sound_volume = 0.4,
	}
	cue_dispatch(&cue)
}

sound_play_rimshot :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = ._276687_Comedy_Rimshot,
		sound_volume = 1.2,
	}
	cue_dispatch(&cue)
}

sound_play_orchestral_hits :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Double_Orchestral_Hits_C,
		sound_volume = 1.0,
	}
	cue_dispatch(&cue)
}

sound_play_game_show_sting :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = ._502152_Game_Show_Brass_Intro_Sting,
		sound_volume = 0.4,
	}
	cue_dispatch(&cue)
}

sound_play_dun_dun_dun :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = .Dun_Dun_Dun,
		sound_volume = 1.0,
	}
	cue_dispatch(&cue)
}

sound_play_brass_stab :: proc() {
	cue := Entity_Cue {
		caps         = {.Has_Sound},
		triggers     = {.Sound},
		sound        = ._810166_Long_Brass_Stab,
		sound_volume = 1.0,
	}
	cue_dispatch(&cue)
}

hotkeys_handle_key :: proc(key: sdl.Keycode) {
	switch key {
	case sdl.K_PLUS, sdl.K_EQUALS:
		music_volume_adjust(+0.005)
	case sdl.K_MINUS:
		music_volume_adjust(-0.005)
	case sdl.K_Q:
		show_to_house()
	case sdl.K_W:
		show_scene_ramp()
	case sdl.K_F:
		show_scene_fade()
	case sdl.K_P:
		show_drop_needle()
	case sdl.K_PERIOD:
		music_fade_out()
	case sdl.K_B:
		lighting_house()
	case sdl.K_J:
		lighting_scene()
	case sdl.K_L:
		lighting_scene_fade()
	case sdl.K_U:
		lighting_fade_to_black()
	case sdl.K_Y:
		lighting_cut_to_black()
	case sdl.K_SEMICOLON:
		lighting_center_focus()
	case sdl.K_A:
		lighting_innuendo_toggle()
	case sdl.K_R:
		lighting_rainbow_sting_toggle()
	case sdl.K_S:
		lighting_pulsing_toggle()
	case sdl.K_1:
		sound_play_break_glass()
	case sdl.K_2:
		sound_play_gunshot()
	case sdl.K_3:
		sound_play_scream_lady()
	case sdl.K_4:
		sound_play_fireworks()
	case sdl.K_5:
		sound_play_train_horn()
	case sdl.K_6:
		sound_play_tick_tick_ding()
	case sdl.K_7:
		sound_play_ding()
	case sdl.K_8:
		sound_play_lightning()
	case sdl.K_9:
		sound_play_rain()
	case sdl.K_0:
		sound_play_meow()
	case sdl.K_Z:
		sound_play_yeeeaaahhh()
	case sdl.K_X:
		sound_play_buzzer()
	case sdl.K_C:
		sound_play_whistle()
	case sdl.K_D:
		sound_play_rimshot()
	case sdl.K_V:
		sound_play_game_show_sting()
	case sdl.K_K:
		sound_play_dun_dun_dun()
	case sdl.K_H:
		sound_play_orchestral_hits()
	case sdl.K_COMMA:
		sound_play_brass_stab()
	}
}

controls_draw :: proc() {
	profiler_scope(#procedure)
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

			layout_width := max(
				imgui.GetContentRegionAvail().x -
				TIMER_PANEL_WIDTH -
				imgui.GetStyle().ItemSpacing.x,
				100,
			)
			controls_layout_begin("ControlsLayout", {layout_width, 0})
			left_width := imgui.GetContentRegionAvail().x

			{
				if imgui.Checkbox("Use house music", &gm.sound_settings.use_house_music) {
					if !gm.sound_settings.use_house_music && playlist_is_house() {
						music_playbacks_fade_all(gm.sound_settings.fade_out_time)
					}
					settings_save()
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
					primary, primary_ok := music_primary_playback()
					if primary_ok && primary.mixer_track != nil {
						music_playback_volume_set(primary, {{0, gm.sound_settings.music_volume}})
					}
					settings_save()
				}
				imgui.PopItemWidth()
			}

			origin := imgui.GetCursorScreenPos()
			spacing := imgui.GetStyle().ItemSpacing

			{
				controls_group_begin("Show", imgui.GetCursorScreenPos(), left_width)

				if controls_button("Pre-show", .SoundAndLighting, button_width) {
					show_pre_show()
				}
				imgui.SameLine()

				if controls_button("Arena pre-show", .SoundAndLighting, button_width) {
					show_arena_pre_show()
				}
				imgui.SameLine()

				if controls_button("Show start", .Sound, button_width) {
					show_start()
				}
				imgui.SameLine()

				if controls_button("Post-show", .SoundAndLighting, button_width) {
					show_post_show()
				}
				imgui.SameLine()

				if controls_button("Ave Maria", .SoundAndLighting, button_width) {
					show_ave_maria()
				}

				if controls_button("To house (q)", .SoundAndLighting, button_width) {
					show_to_house()
				}
				imgui.SameLine()

				if controls_button("Scene - ramp (w)", .SoundAndLighting, button_width) {
					show_scene_ramp()
				}
				imgui.SameLine()

				if controls_button("Scene - fade (f)", .SoundAndLighting, button_width) {
					show_scene_fade()
				}
				imgui.SameLine()

				if controls_button("Drop needle (p)", .Destructive, button_width) {
					show_drop_needle()
				}

				controls_group_end()
			}

			{
				controls_group_begin("Games", imgui.GetCursorScreenPos(), left_width)

				if controls_button("Innuendo", .Innuendo, button_width) {
					game_innuendo()
				}
				imgui.SameLine()

				if controls_button("Oscar Moment", .Game, button_width) {
					game_oscar_moment()
				}
				imgui.SameLine()

				if controls_button("Sounds Like\n  a Song", .Game, button_width) {
					game_sounds_like_a_song()
				}
				imgui.SameLine()

				if controls_button("Challenge", .Game, button_width) {
					game_challenge()
				}
				imgui.SameLine()

				if controls_button("Final Showdown", .Game, button_width) {
					game_final_showdown()
				}

				controls_group_end()
			}

			{
				controls_group_begin("Lighting", imgui.GetCursorScreenPos(), left_width)

				if controls_button("House (b)##Lighting", .Lighting, button_width) {
					lighting_house()
				}
				imgui.SameLine()
				if controls_button("Scene (j)##Lighting", .Lighting, button_width) {
					lighting_scene()
				}
				imgui.SameLine()
				if controls_button("Scene - fade (l)##Lighting", .Lighting, button_width) {
					lighting_scene_fade()
				}
				imgui.SameLine()
				if controls_button("Fade to black (u)##Lighting", .Lighting, button_width) {
					lighting_fade_to_black()
				}
				imgui.SameLine()
				if controls_button("Cut to black (y)##Lighting", .Lighting, button_width) {
					lighting_cut_to_black()
				}
				if controls_button("Center focus (;)##Lighting", .Lighting, button_width) {
					lighting_center_focus()
				}
				imgui.SameLine()
				{
					fx := lighting_state(lighting_entity_ensure()).fx[.Innuendo]
					text := "Innuendo"
					target_prev: f32
					if fx.weight_current > 0 {
						text = "Cancel Innuendo"
						target_prev = fx.keys[fx.key_count - 1].value
					}
					if controls_button(
						strings.clone_to_cstring(
							fmt.tprint(text, "(a)##Lighting"),
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
					fx := lighting_state(lighting_entity_ensure()).fx[.RainbowSting]
					text := " Rainbow sting"
					target_prev: f32
					if fx.weight_current > 0 {
						text = "    Cancel\n rainbow sting"
						target_prev = fx.keys[fx.key_count - 1].value
					}
					if controls_button(
						strings.clone_to_cstring(
							fmt.tprint(text, " (r)##Lighting"),
							context.temp_allocator,
						),
						.Lighting,
						button_width,
					) {
						lighting_rainbow_sting_toggle()
					}
				}

				imgui.SameLine()
				{
					fx := lighting_state(lighting_entity_ensure()).fx[.Pulsing]
					text := "Pulsing"
					target_prev: f32
					if fx.weight_current > 0 {
						text = "Cancel Pulsing"
						target_prev = fx.keys[fx.key_count - 1].value
					}
					if controls_button(
						strings.clone_to_cstring(
							fmt.tprint(text, " (s)##Lighting"),
							context.temp_allocator,
						),
						.Lighting,
						button_width,
					) {
						lighting_pulsing_toggle()
					}
				}

				controls_group_end()
			}

			{
				controls_group_begin("Sounds", imgui.GetCursorScreenPos(), left_width)

				if controls_button("Break glass (1)", .Sound, button_width) {
					sound_play_break_glass()
				}
				imgui.SameLine()
				if controls_button("Gunshot (2)", .Sound, button_width) {sound_play_gunshot()}
				imgui.SameLine()
				if controls_button(
					"Scream, lady! (3)",
					.Sound,
					button_width,
				) {sound_play_scream_lady()}
				imgui.SameLine()
				if controls_button("Fireworks (4)", .Sound, button_width) {sound_play_fireworks()}
				imgui.SameLine()
				if controls_button(
					"Train horn (5)",
					.Sound,
					button_width,
				) {sound_play_train_horn()}
				if controls_button(
					"Tick tick ding (6)",
					.Sound,
					button_width,
				) {sound_play_tick_tick_ding()}
				imgui.SameLine()
				if controls_button("Ding (7)", .Sound, button_width) {sound_play_ding()}
				imgui.SameLine()
				if controls_button("Lightning (8)", .Sound, button_width) {sound_play_lightning()}
				imgui.SameLine()
				if controls_button("Rain (9)", .Sound, button_width) {sound_play_rain()}
				imgui.SameLine()
				if controls_button("Meow (0)", .Sound, button_width) {sound_play_meow()}
				if controls_button(
					"Yeeeaaahhh (z)",
					.Sound,
					button_width,
				) {sound_play_yeeeaaahhh()}
				imgui.SameLine()
				if controls_button("Buzzer (x)", .Sound, button_width) {sound_play_buzzer()}
				imgui.SameLine()
				if controls_button("Whistle (c)", .Sound, button_width) {sound_play_whistle()}
				imgui.SameLine()
				if controls_button("Rimshot (d)", .Sound, button_width) {sound_play_rimshot()}
				if controls_button(
					"Game show sting (v)",
					.Sound,
					button_width,
				) {sound_play_game_show_sting()}
				imgui.SameLine()
				if controls_button(
					"Dun dun dun (k)",
					.Sound,
					button_width,
				) {sound_play_dun_dun_dun()}
				imgui.SameLine()
				if controls_button(
					"Orchestral hits (h)",
					.Sound,
					button_width,
				) {sound_play_orchestral_hits()}
				imgui.SameLine()
				if controls_button(
					"Brass stab (,)",
					.Sound,
					button_width,
				) {sound_play_brass_stab()}

				controls_group_end()
			}

			ensure(video_entity_get() != nil && gm.scores != nil)
			list_row_height := imgui.GetTextLineHeightWithSpacing()
			list_padding := imgui.GetStyle().FramePadding.y * 2
			video_list_height :=
				f32(max(1, len(video_entity_get().video.pages))) * list_row_height + list_padding
			media_origin := imgui.GetCursorScreenPos()
			media_width := (left_width - spacing.x) * 0.5
			imgui.PushID("Score slide")
			score_height := imgui.Storage_GetFloat(
				imgui.GetStateStorage(),
				imgui.GetID("Height"),
				imgui.GetFrameHeightWithSpacing() * 4 +
				list_row_height * f32(len(gm.entities.score)) +
				imgui.GetStyle().WindowPadding.y * 2 +
				imgui.GetFrameHeight(),
			)
			score_height = max(
				score_height,
				imgui.Storage_GetFloat(imgui.GetStateStorage(), imgui.GetID("LayoutHeight")),
			)
			imgui.PopID()
			media_height := max(200, imgui.GetContentRegionAvail().y - score_height - spacing.y)
			media_list_hovered := false

			{
				controls_group_begin("Music", media_origin, media_width, media_height)

				{
					if _, primary_ok := music_primary_playback(); primary_ok {
						style := button_styles[.Sound]
						imgui.PushStyleVarX(.FramePadding, 16)
						imgui.PushStyleColorImVec4(.Button, style.base)
						imgui.PushStyleColorImVec4(.ButtonHovered, style.hovered)
						imgui.PushStyleColorImVec4(.ButtonActive, style.active)
						if imgui.Button("Fade out (.)", {0, 0}) {
							music_playbacks_fade_all(2)
						}
						imgui.PopStyleColor(3)
						imgui.PopStyleVar(1)
					}
				}

				if controls_list_begin(
					"Playlists##ControlList",
					max(list_row_height, imgui.GetContentRegionAvail().y),
				) {
					for playlist_handle, index in gm.entities.playlist {
						playlist := entity_must_get(playlist_handle)
						_, primary_ok := music_primary_playback()
						primary_entity, primary_entity_ok := entity_get(gm.music_primary)
						is_current :=
							primary_ok &&
							primary_entity_ok &&
							primary_entity.music.playlist == playlist_handle
						if imgui.Selectable(
							strings.clone_to_cstring(playlist.label, context.temp_allocator),
							is_current,
						) {
							ensure(len(playlist.playlist_tracks) > 0)
							gm.sound_settings.music_browser_playlist_index = i32(index)
							gm.sound_settings.music_browser_track_index = 0
							wave_editor_track_select(playlist.playlist_tracks[0])

							if is_current {
								music_playbacks_fade_all(2)
							} else {
								track := playlist_pick_random_track(playlist_handle)
								ensure(
									track != ENTITY_HANDLE_NIL,
									"Couldn't pick track for playlist",
								)

								music_crossfade(
									playlist_handle,
									track,
									0.3,
									gm.sound_settings.fade_in_time,
									gm.sound_settings.fade_out_time,
								)
							}
						}
					}
				}
				media_list_hovered = imgui.IsWindowHovered() && imgui.GetScrollMaxY() > 0
				imgui.EndChild()

				controls_group_end()
			}
			music_bottom := imgui.GetCursorScreenPos().y

			{
				controls_group_begin(
					"Video",
					{media_origin.x + media_width + spacing.x, media_origin.y},
					media_width,
					media_height,
				)

				status_height := imgui.GetTextLineHeightWithSpacing()
				if video_entity_get().video.active != nil {
					status_height += imgui.GetFrameHeightWithSpacing()
				}
				video_list_available := max(
					list_row_height,
					imgui.GetContentRegionAvail().y - status_height,
				)
				video_controls_draw(video_list_available)
				media_list_hovered ||=
					video_list_height > video_list_available &&
					imgui.IsWindowHovered(imgui.HoveredFlags_ChildWindows) &&
					!imgui.IsWindowHovered()

				controls_group_end()
			}
			imgui.SetCursorScreenPos({origin.x, max(music_bottom, imgui.GetCursorScreenPos().y)})

			{
				controls_group_begin("Score slide", imgui.GetCursorScreenPos(), left_width)
				score_controls_draw()
				controls_group_end()
			}

			controls_layout_end(!media_list_hovered)
			imgui.SameLine()
			timers_draw()

			imgui.EndTabItem()
		}

		if imgui.BeginTabItem(tab_labels[.Music]) {
			music_tab_selected = true
			gm.active_tab = .Music

			controls_layout_begin("MusicEditorLayout")
			origin := imgui.GetCursorScreenPos()
			size := imgui.GetContentRegionAvail()
			playlist_width: f32 = 300
			spacing := imgui.GetStyle().ItemSpacing.x
			controls_group_begin("Playlist", origin, playlist_width)
			if imgui.BeginChild(
				"Playlist##List",
				{0, 0},
				{.FrameStyle, .AutoResizeY, .AlwaysAutoResize, .NavFlattened},
			) {
				for playlist_handle, index in gm.entities.playlist {
					playlist := entity_must_get(playlist_handle)
					if imgui.Selectable(
						strings.clone_to_cstring(playlist.label, context.temp_allocator),
						i32(index) == gm.sound_settings.music_browser_playlist_index,
					) {
						ensure(len(playlist.playlist_tracks) > 0)
						gm.sound_settings.music_browser_playlist_index = i32(index)
						gm.sound_settings.music_browser_track_index = 0
						wave_editor_track_select(playlist.playlist_tracks[0])
					}
				}
			}
			imgui.EndChild()
			controls_group_end()

			controls_group_begin(
				"Track",
				{origin.x + playlist_width + spacing, origin.y},
				size.x - playlist_width - spacing,
			)
			playlist := entity_must_get(music_browser_playlist_selected())
			if imgui.BeginChild(
				"Track##List",
				{0, 0},
				child_flags = {.FrameStyle, .AutoResizeY, .AlwaysAutoResize, .NavFlattened},
			) {
				for track_handle, index in playlist.playlist_tracks {
					track := entity_must_get(track_handle)
					if imgui.Selectable(
						strings.clone_to_cstring(track.track.title, context.temp_allocator),
						i32(index) == gm.sound_settings.music_browser_track_index,
					) {
						gm.sound_settings.music_browser_track_index = i32(index)
						wave_editor_track_select(track_handle)
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

			controls_group_end()
			controls_layout_end()

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
			imgui.Text(
				"| Lighting: %s",
				lighting_look_labels[lighting_state(lighting_entity_ensure()).look],
			)

			lighting_fx_count := 0
			for &fx, kind in lighting_state(lighting_entity_ensure()).fx {
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

projection_draw :: proc() {
	profiler_scope(#procedure)
	vp := imgui.GetMainViewport()
	imgui.SetNextWindowPos(vp.WorkPos)
	imgui.SetNextWindowSize(vp.WorkSize)

	imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
	imgui.PushStyleVar(.WindowRounding, 0)
	imgui.PushStyleVar(.WindowBorderSize, 0)

	imgui.Begin(
		"ProjectionRoot",
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

	switch gm.projection_source {
	case .Score:
		score_projection_draw()
	case .Timer:
		imgui.PushFontFloat(nil, 500)
		text := strings.clone_to_cstring(
			timers_projection_text_from(gm.projection_handle),
			context.temp_allocator,
		)
		text_size := imgui.CalcTextSize(text)
		imgui.SetCursorPos(
			{(vp.WorkSize.x - text_size.x) * 0.5, (vp.WorkSize.y - text_size.y) * 0.5},
		)
		imgui.TextColored({0.85, 0.25, 0.25, 1}, text)
		imgui.PopFont()
	case .Video, .Blank:
	// The video texture is the background; blank leaves it black.
	}

	imgui.End()
}
