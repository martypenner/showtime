package game

import "core:strings"

Cue_Cap :: enum u8 {
	Has_Sound,
	Has_Music,
	Has_Lighting,
	Has_Video,
	Has_Score,
}

Cue_Caps :: bit_set[Cue_Cap;u8]

// What executes when a cue fires. Several bits may be set at once. Fade_Out
// fades the capped entities over fade_out_s instead of starting anything new.
Cue_Trigger :: enum u8 {
	Sound,
	Music,
	Lighting,
	Video,
	Score,
	Fade_Out,
}

Cue_Triggers :: bit_set[Cue_Trigger;u8]

cue_fire_mask :: proc(cue_caps: Cue_Caps, cue_triggers: Cue_Triggers) -> Cue_Triggers {
	fire := Cue_Triggers{}
	if .Sound in cue_triggers && .Has_Sound in cue_caps do fire += {.Sound}
	if .Music in cue_triggers && .Has_Music in cue_caps do fire += {.Music}
	if .Lighting in cue_triggers && .Has_Lighting in cue_caps do fire += {.Lighting}
	if .Video in cue_triggers && .Has_Video in cue_caps do fire += {.Video}
	if .Score in cue_triggers && .Has_Score in cue_caps do fire += {.Score}
	fadeable := Cue_Caps{.Has_Music, .Has_Video}
	if .Fade_Out in cue_triggers && cue_caps & fadeable != {} do fire += {.Fade_Out}
	return fire
}

// Fire one cue through every armed action at once, recording the masked set.
// Missing subsystems skip their side effect while the record still shows the
// dispatch.
cue_dispatch :: proc(cue: ^Entity_Cue) -> Cue_Triggers {
	ensure(cue != nil)
	fire := cue_fire_mask(cue.caps, cue.triggers)
	cue.fired += fire
	if .Sound in fire && gm.sound_settings != nil {
		sound_play(cue.sound, cue.sound_volume)
	}
	if .Music in fire && gm.sound_settings != nil {
		cue_music_fire(cue)
	}
	if .Lighting in fire && gm.lighting.socket != nil {
		if cue.lighting_fx_reset do lighting_fx_deactivate_all()
		lighting_look_activate(cue.look)
	}
	if .Video in fire {
		// The selected video is already the default source, so a cue only
		// needs to switch pages. A page the deck no longer has leaves the
		// selection alone.
		if video_entity_get() != nil && len(cue.video_page) > 0 {
			video_page_show(cue.video_page)
		}
	}
	if .Score in fire && gm.scores != nil {
		if cue.scoreboard >= 0 && cue.scoreboard < len(gm.entities.score) {
			score_board_select(cue.scoreboard)
			gm.scores.active = cue.scoreboard
		} else if gm.scores.active < 0 {
			gm.scores.active = score_board_selected()
		}
	}
	if .Fade_Out in fire {
		if .Has_Music in cue.caps && gm.sound_settings != nil {
			music_playbacks_fade_all(cue.fade_out_s)
		}
		if .Has_Video in cue.caps && video_entity_get() != nil {
			video_fade_start(cue.fade_out_s)
		}
	}
	return fire
}

// Resolve one random track from the cue's playlist entity and crossfade into
// it. A missing playlist or an empty pick is a programming error.
cue_music_fire :: proc(cue: ^Entity_Cue) {
	playlist_entity := entity_must_get(cue.playlist)
	ensure(.Playlist in playlist_entity.caps)
	playlist := playlist_find_by_label(playlist_entity.label)
	ensure(playlist != nil)
	track := playlist_pick_random_track(playlist)
	ensure(track != nil)
	music_crossfade(playlist, track, cue.music_volume, cue.fade_in_s, cue.fade_out_s)
}

cue_fire :: proc(index: int) {
	timer := timer_at(index)
	fire := cue_dispatch(&timer.cue)
	timer.triggers = transmute(Entity_Triggers)timer.cue.triggers
	timer.fired = transmute(Entity_Triggers)fire
}

timers_cue_arm_sound :: proc(index: int, name: SoundEffectName, volume: f32) {
	timer := timer_at(index)
	timer.cue.caps += {.Has_Sound}
	timer.cue.triggers += {.Sound}
	timer.cue.sound = name
	timer.cue.sound_volume = volume
}

timers_cue_arm_music :: proc(
	index: int,
	playlist: PlaylistName,
	volume, fade_in_s, fade_out_s: f32,
) {
	timer := timer_at(index)
	timer.cue.caps += {.Has_Music}
	timer.cue.triggers += {.Music}
	timer.cue.playlist = entity_playlist_handle_for_name(playlist)
	timer.cue.music_volume = volume
	timer.cue.fade_in_s = fade_in_s
	timer.cue.fade_out_s = fade_out_s
}

timers_cue_arm_lighting :: proc(index: int, look: LightingLook, fx_reset := false) {
	timer := timer_at(index)
	timer.cue.caps += {.Has_Lighting}
	timer.cue.triggers += {.Lighting}
	timer.cue.look = look
	timer.cue.lighting_fx_reset = fx_reset
}

timers_cue_arm_projection :: proc(
	index: int,
	video, score: bool,
	video_page := "",
	scoreboard := -1,
) {
	timer := timer_at(index)
	if video {
		timer.cue.caps += {.Has_Video}
		timer.cue.triggers += {.Video}
		timer.cue.video_page = strings.clone(video_page)
	}
	if score {
		timer.cue.caps += {.Has_Score}
		timer.cue.triggers += {.Score}
		timer.cue.scoreboard = scoreboard
	}
}
