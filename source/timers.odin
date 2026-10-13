package game

import imgui "../vendor/odin-imgui"
import "core:fmt"
import "core:math"
import "core:strings"
import utf8 "core:unicode/utf8"
import sdl "vendor:sdl3"

TIMER_PANEL_WIDTH :: 380
TIMER_BLINK_SECONDS :: 4
TIMER_STEP_SECONDS :: 1
TIMER_MIN_SECONDS :: 0
TIMER_MAX_SECONDS :: 3600
DEFAULT_TIMER_SECONDS :: 30
TIMER_BLINK_DIM :: f32(0.35)
TIMER_BLINK_BRIGHT :: f32(0.75)

Cue_Cap :: enum u8 {
	Has_Sound,
	Has_Music,
	Has_Lighting,
	Has_Video,
	Has_Score,
}

Cue_Caps :: bit_set[Cue_Cap; u8]

Cue_Trigger :: enum u8 {
	Sound,
	Music,
	Lighting,
	Video,
	Score,
	Fade_Out,
}

Cue_Triggers :: bit_set[Cue_Trigger; u8]

timer_at :: proc(index: int) -> ^Entity {
	ensure(index >= 0 && index < len(gm.entities.timer))
	entity, ok := entity_get(gm.entities.timer[index])
	ensure(ok && .Timer in entity.caps)
	return entity
}

timers_add :: proc(label: string, duration_s_in: f32) -> Entity_Handle {
	duration_s := clamp(duration_s_in, TIMER_MIN_SECONDS, TIMER_MAX_SECONDS)
	handle := entity_create({.Timer, .Projection}, label)
	entity := entity_must_get(handle)
	entity.timer.remaining_s = duration_s
	return handle
}

timers_start :: proc(index: int) {
timer := timer_at(index)
timer.timer.done = false
timer.timer.running = true
timer.cue.fired = Cue_Triggers{}
timer.timer.start_tick = sdl.GetTicks()
}

timers_stop :: proc(index: int) {
	ensure(index >= 0 && index < len(gm.entities.timer))
	entity_destroy(gm.entities.timer[index])
}

timers_stop_all :: proc() {
	entity_domain_clear(&gm.entities.timer)
}

timers_adjust :: proc(index: int, delta_s: f32) {
	timer := timer_at(index)
	if delta_s < 0 && timer.timer.remaining_s <= TIMER_MIN_SECONDS do return
	timer.timer.remaining_s = clamp(timer.timer.remaining_s + delta_s, TIMER_MIN_SECONDS, TIMER_MAX_SECONDS)
}

timers_active_count :: proc() -> int {
	return len(gm.entities.timer)
}

timers_projection_text_from :: proc(handle: Entity_Handle) -> string {
	if entity, ok := entity_get(handle); ok && .Timer in entity.caps {
		seconds := i64(math.ceil(entity.timer.remaining_s))
		return fmt.tprintf("%02d:%02d", seconds / 60, seconds % 60)
	}
	return timers_projection_text()
}

timers_projection_text :: proc() -> string {
	active: ^Entity
	for handle in gm.entities.timer {
		entity, ok := entity_get(handle)
		ensure(ok)
		if !entity.timer.running || entity.timer.done do continue
		if active == nil || entity.timer.start_tick > active.timer.start_tick do active = entity
	}
	if active == nil do return ""

	seconds := i64(math.ceil(active.timer.remaining_s))
	return fmt.tprintf("%02d:%02d", seconds / 60, seconds % 60)
}

timers_marks_count :: proc() -> int {
	return len(gm.entities.mark)
}

timers_mark :: proc(index: int) -> bool {
	timer := timer_at(index)
	if len(timer.label) == 0 || timer.timer.done || timer.timer.start_tick == 0 do return false

	handle := entity_create({.Mark}, timer.label)
	mark := entity_must_get(handle)
	mark.mark.elapsed_s = f32(sdl.GetTicks() - timer.timer.start_tick) / 1000
	return true
}

timers_marks_clear :: proc() {
	entity_domain_clear(&gm.entities.mark)
}

timers_submit_input :: proc() {
	label := strings.trim_space(string(cstring(&gm.timer_ui.label_input[0])))
	if len(label) == 0 do label = "Timer"
	gm.timer_serial_next += 1
	timers_add(fmt.tprintf("%d. %s", gm.timer_serial_next, label), gm.timer_ui.seconds_input)
	gm.timer_ui.label_input[0] = 0
	gm.timer_ui.seconds_input = DEFAULT_TIMER_SECONDS
}

timers_any_running :: proc() -> bool {
	for handle in gm.entities.timer {
		entity, ok := entity_get(handle)
		ensure(ok)
		if entity.timer.running && !entity.timer.done do return true
	}
	return false
}

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
		if entity := video_entity_get(); entity != nil {
			if len(cue.video_page) > 0 {
				if !video_page_show(cue.video_page) {
					entity.video.shown = true
				}
			} else {
				entity.video.shown = true
			}
		}
	}
	if .Score in fire && gm.scores != nil {
		if cue.scoreboard >= 0 && cue.scoreboard < len(gm.scores.scoreboards) {
			gm.scores.active = cue.scoreboard
		}
		gm.scores.shown = true
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

timers_cue_arm_projection :: proc(index: int, video, score: bool, video_page := "", scoreboard := -1) {
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

timers_update :: proc(dt: f32) {
	for handle in gm.entities.timer {
		entity, ok := entity_get(handle)
		ensure(ok)

		countdown_tick(&entity.timer.flash_remaining_s, dt)
		if entity.timer.running && !entity.timer.done {
			if countdown_tick(&entity.timer.remaining_s, dt) {
				entity.timer.done = true
				entity.timer.flash_remaining_s = TIMER_BLINK_SECONDS
				fire := cue_dispatch(&entity.cue)
				entity = entity_must_get(handle)
				entity.triggers = transmute(Entity_Triggers)entity.cue.triggers
				entity.fired = transmute(Entity_Triggers)fire
			}
		}

		entity = entity_must_get(handle)
		projected := (entity.timer.running && !entity.timer.done) || entity.timer.flash_remaining_s > 0
		entity_record_emit(projected ? .Projection : .Controls, handle)
	}
}

timers_draw :: proc() {
	imgui.PushStyleColorImVec4(.Border, {0.7, 0.15, 0.15, 1})
	imgui.BeginChild("TimersPanel", {TIMER_PANEL_WIDTH, 0}, child_flags = {.Borders})
	imgui.PopStyleColor(1)
	defer imgui.EndChild()

	imgui.AlignTextToFramePadding()
	imgui.TextColored({0.95, 0.25, 0.25, 1}, "Timers")
	imgui.SameLine()
	imgui.Text("%d", timers_active_count())

	imgui.SameLine()
	imgui.PushStyleColorImVec4(.Button, {0.55, 0.1, 0.1, 1})
	imgui.PushStyleColorImVec4(.ButtonHovered, {0.75, 0.15, 0.15, 1})
	imgui.PushStyleColorImVec4(.ButtonActive, {0.9, 0.2, 0.2, 1})
	if imgui.Button("Stop all") do timers_stop_all()
	imgui.PopStyleColor(3)

	imgui.SetNextItemWidth(-1)
	submitted := false
	if imgui.InputText(
		"##TimerLabelInput",
		cstring(&gm.timer_ui.label_input[0]),
		uint(len(gm.timer_ui.label_input)),
		{.EnterReturnsTrue},
	) {
		submitted = true
	}

	imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x - imgui.GetFrameHeight() * 4.5)
	imgui.InputFloat("##TimerSecondsInput", &gm.timer_ui.seconds_input, 5, 60, "%.0f s")
	gm.timer_ui.seconds_input = max(gm.timer_ui.seconds_input, 0)
	imgui.SameLine()
	if imgui.Button("+ Add") do submitted = true
	if submitted do timers_submit_input()

	imgui.Separator()

	if imgui.BeginChild(
		"TimerList",
		{0, imgui.GetContentRegionAvail().y * 0.55},
		child_flags = {.FrameStyle},
	) {
		defer imgui.EndChild()

		for _, i in gm.entities.timer {
			timers_timer_row_draw(i)
		}
	}

	imgui.Separator()

	imgui.AlignTextToFramePadding()
	imgui.TextColored({0.95, 0.25, 0.25, 1}, "Marks")
	imgui.SameLine()
	imgui.Text("%d", timers_marks_count())
	imgui.SameLine()
	if imgui.Button("Clear") do timers_marks_clear()

	if imgui.BeginChild("MarksList", {0, 0}, child_flags = {.FrameStyle}) {
		defer imgui.EndChild()

		for handle in gm.entities.mark {
			mark, ok := entity_get(handle)
			ensure(ok)
			line := strings.clone_to_cstring(
				fmt.tprintf("%s  %.2fs", mark.label, mark.mark.elapsed_s),
				context.temp_allocator,
			)
			imgui.TextUnformatted(
				timers_text_clipped(
					string(line),
					imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x,
				),
			)
		}
	}
}

timer_blink_alpha :: proc(flash_remaining_s: f32, tick_ms: u64) -> f32 {
	if !(flash_remaining_s > 0) do return 1
	phase := (math.sin(f64(tick_ms) * 0.012) + 1) / 2
	keys := [2]Envelope_Point{{0, TIMER_BLINK_DIM}, {1, TIMER_BLINK_BRIGHT}}
	return envelope_value_at(keys[:], f32(phase))
}

timers_timer_row_draw :: proc(index: int) {
	timer := timer_at(index)

	row_width := imgui.GetContentRegionAvail().x

	if timer.timer.done {
		x_button_width := timers_small_button_width("x")
		label_budget := row_width - x_button_width - imgui.GetStyle().ItemSpacing.x
		done_prefix_width := imgui.CalcTextSize("Done  ").x
		label_cstr := timers_text_clipped(timer.label, label_budget - done_prefix_width)

		blink_alpha := timer_blink_alpha(timer.timer.flash_remaining_s, sdl.GetTicks())
		blink_color := imgui.Vec4{0.85, 0.08, 0.08, blink_alpha}
		imgui.PushStyleColorImVec4(.Button, blink_color)
		imgui.PushStyleColorImVec4(.ButtonHovered, blink_color)
		imgui.PushStyleColorImVec4(.ButtonActive, blink_color)
		imgui.PushStyleColorImVec4(.Text, {1, 0.9, 0.9, blink_alpha})
		imgui.Button(
			strings.clone_to_cstring(fmt.tprintf("Done  %s", label_cstr), context.temp_allocator),
			{0, 0},
		)
		imgui.PopStyleColor(4)
	} else {
		remaining := f32(math.ceil(timer.timer.remaining_s))
		minutes := i64(remaining) / 60
		seconds := i64(remaining) % 60
		time_cstr := strings.clone_to_cstring(
			fmt.tprintf("%02d:%02d", minutes, seconds),
			context.temp_allocator,
		)
		time_width := imgui.CalcTextSize(time_cstr).x

		run_label := timer.timer.running ? "Pause" : "Play"
		reserved :=
			timers_small_button_width(
				strings.clone_to_cstring(run_label, context.temp_allocator),
			) +
			timers_small_button_width("-") +
			timers_small_button_width("+") +
			timers_small_button_width("Mark") +
			timers_small_button_width("x") +
			imgui.GetStyle().ItemSpacing.x * 2
		label_budget := row_width - time_width - imgui.GetStyle().ItemSpacing.x - reserved
		label_cstr := timers_text_clipped(timer.label, label_budget)

		imgui.TextUnformatted(time_cstr)
		imgui.SameLine()
		imgui.TextUnformatted(label_cstr)

		imgui.SameLine()
		if timers_small_button(
			strings.clone_to_cstring(
				fmt.tprintf(timer.timer.running ? "Pause##%d" : "Play##%d", index),
				context.temp_allocator,
			),
		) {
			if timer.timer.running {
				timer.timer.running = false
			} else {
				timers_start(index)
			}
		}

		imgui.SameLine()
		imgui.BeginDisabled(timer.timer.remaining_s <= TIMER_MIN_SECONDS)
		if timers_small_button(
			strings.clone_to_cstring(fmt.tprintf("-##%d", index), context.temp_allocator),
		) {
			timers_adjust(index, -TIMER_STEP_SECONDS)
		}
		imgui.EndDisabled()

		imgui.SameLine()
		imgui.BeginDisabled(timer.timer.remaining_s >= TIMER_MAX_SECONDS)
		if timers_small_button(
			strings.clone_to_cstring(fmt.tprintf("+##%d", index), context.temp_allocator),
		) {
			timers_adjust(index, +TIMER_STEP_SECONDS)
		}
		imgui.EndDisabled()

		imgui.SameLine()
		if timers_small_button(
			strings.clone_to_cstring(fmt.tprintf("Mark##%d", index), context.temp_allocator),
		) {
			timers_mark(index)
		}
	}

	imgui.SameLine()
	if timers_small_button(
		strings.clone_to_cstring(fmt.tprintf("x##%d", index), context.temp_allocator),
	) {
		timers_stop(index)
	}
}

timers_small_button :: proc(label: cstring) -> bool {
	imgui.PushStyleVarX(.FramePadding, 3)
	defer imgui.PopStyleVar(1)
	return imgui.Button(label, {0, 0})
}

timers_small_button_width :: proc(label: cstring) -> f32 {
	return imgui.CalcTextSize(label).x + 3 * 2 + imgui.GetStyle().ItemSpacing.x
}

timers_text_clipped :: proc(text: string, max_px: f32) -> cstring {
	full := strings.clone_to_cstring(text, context.temp_allocator)
	if max_px <= 0 || imgui.CalcTextSize(full).x <= max_px do return full

	runes := utf8.string_to_runes(text, context.temp_allocator)
	lo := 0
	hi := len(runes) - 1
	for _ in 0 ..< 8 {
		if !(lo < hi) do continue
		mid := lo + (hi - lo + 1) / 2
		candidate := strings.clone_to_cstring(
			fmt.tprintf("%s...", utf8.runes_to_string(runes[:mid], context.temp_allocator)),
			context.temp_allocator,
		)
		if imgui.CalcTextSize(candidate).x <= max_px {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	if lo == 0 do return strings.clone_to_cstring("...", context.temp_allocator)
	return strings.clone_to_cstring(
		fmt.tprintf("%s...", utf8.runes_to_string(runes[:lo], context.temp_allocator)),
		context.temp_allocator,
	)
}
