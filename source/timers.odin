package game

import imgui "../vendor/odin-imgui"
import "core:fmt"
import "core:math"
import "core:strings"
import utf8 "core:unicode/utf8"
import sdl "vendor:sdl3"

MAX_TIMERS :: 24
MAX_TIMER_MARKS :: 128
TIMER_PANEL_WIDTH :: 380
TIMER_BLINK_SECONDS :: 4
TIMER_STEP_SECONDS :: 1
TIMER_MIN_SECONDS :: 0
TIMER_MAX_SECONDS :: 3600
DEFAULT_TIMER_SECONDS :: 30
TIMER_BLINK_DIM :: f32(0.35)
TIMER_BLINK_BRIGHT :: f32(0.75)

Timer :: struct {
	label:             string,
	remaining_s:       f32,
	running:           bool,
	done:              bool,
	flash_remaining_s: f32,
	start_tick:        u64,
	// Expiry payload fired when the timer runs out.
	cue:               Cue,
}

// What a cue carries.
Cue_Cap :: enum u8 {
	Has_Sound,
	Has_Music,
	Has_Lighting,
	Has_Video,
	Has_Score,
}

Cue_Caps :: bit_set[Cue_Cap; u8]

// What executes when a cue fires. Several bits may be set at once.
Cue_Trigger :: enum u8 {
	Sound,
	Music,
	Lighting,
	Video,
	Score,
}

Cue_Triggers :: bit_set[Cue_Trigger; u8]

// Sound, music, lighting, video, and score payloads side by side.
// Capability bits describe the payload carried; trigger bits describe what
// executes on dispatch. The two bitsets stay separate so a cue can carry a
// payload without firing it, and one dispatch can run several actions at once.
Cue :: struct {
	caps:              Cue_Caps,
	triggers:          Cue_Triggers,
	// Masked trigger set from the last dispatch.
	fired:             Cue_Triggers,
	sound:             SoundEffectName,
	sound_volume:      f32,
	playlist:          PlaylistName,
	music_volume:      f32,
	fade_in_s:         f32,
	fade_out_s:        f32,
	look:              LightingLook,
	// Reset running lighting effects before applying the look.
	lighting_fx_reset: bool,
	// Projection payload. Empty page shows the current deck state; a negative
	// scoreboard leaves the selection alone.
	video_page:        string,
	scoreboard:        int,
}

TimerMark :: struct {
	timer_label: string,
	elapsed_s:   f32,
}

// Add a timer paused: it sits at its full duration until the row's start
// button is pressed.
timers_add :: proc(label: string, duration_s_in: f32) -> bool {
	duration_s := clamp(duration_s_in, TIMER_MIN_SECONDS, TIMER_MAX_SECONDS)

	for i in 0 ..< MAX_TIMERS {
		if gm.timers[i].label == "" {
			timers_slot_set(i, label, duration_s, running = false)
			return true
		}
	}

	oldest_done_index := -1
	oldest_done_tick: u64 = max(u64)
	for i in 0 ..< MAX_TIMERS {
		timer := &gm.timers[i]
		if !timer.done do continue
		if timer.start_tick < oldest_done_tick {
			oldest_done_index = i
			oldest_done_tick = timer.start_tick
		}
	}
	if oldest_done_index >= 0 {
		timers_slot_set(oldest_done_index, label, duration_s, running = false)
		return true
	}

	gm.timer_ui.overflow_hint_seconds = 2
	return false
}

timers_slot_set :: proc(index: int, label: string, duration_s: f32, running: bool) {
	timer := &gm.timers[index]
	timer^ = Timer {
		label       = strings.clone(label),
		remaining_s = duration_s,
		running     = running,
		start_tick  = running ? sdl.GetTicks() : 0,
	}
}

timers_start :: proc(index: int) {
	timer := &gm.timers[index]
	timer.done = false
	timer.running = true
	timer.cue.fired = Cue_Triggers{}
	timer.start_tick = sdl.GetTicks()
	// A playing timer owns the projection through projection_source_resolve;
	// presentation flags stay armed for when it ends.
}

timers_stop :: proc(index: int) {
	gm.timers[index] = {}
}

timers_stop_all :: proc() {
	for i in 0 ..< MAX_TIMERS {
		if gm.timers[i].label != "" do timers_stop(i)
	}
}

timers_adjust :: proc(index: int, delta_s: f32) {
	timer := &gm.timers[index]
	if delta_s < 0 && timer.remaining_s <= TIMER_MIN_SECONDS do return
	timer.remaining_s = clamp(timer.remaining_s + delta_s, TIMER_MIN_SECONDS, TIMER_MAX_SECONDS)
}

timers_active_count :: proc() -> int {
	count := 0
	for i in 0 ..< MAX_TIMERS {
		if gm.timers[i].label != "" do count += 1
	}
	return count
}

// The projection follows the most recently started running timer, so a timer
// left sitting at 00:00 doesn't mask the next cue's countdown.
timers_projection_text :: proc() -> string {
	active: ^Timer
	for i in 0 ..< MAX_TIMERS {
		timer := &gm.timers[i]
		if timer.label == "" || !timer.running do continue
		if active == nil || timer.start_tick > active.start_tick do active = timer
	}
	if active == nil do return ""

	seconds := i64(math.ceil(active.remaining_s))
	return fmt.tprintf("%02d:%02d", seconds / 60, seconds % 60)
}

timers_marks_count :: proc() -> int {
	return gm.timer_marks_count
}

timers_mark :: proc(index: int) -> bool {
	timer := &gm.timers[index]
	if timer.label == "" || timer.done || timer.start_tick == 0 do return false
	if gm.timer_marks_count >= MAX_TIMER_MARKS {
		gm.timer_ui.marks_overflow_hint_seconds = 2
		return false
	}

	mark := &gm.timer_marks[gm.timer_marks_count]
	mark^ = TimerMark {
		timer_label = strings.clone(timer.label),
		elapsed_s   = f32(sdl.GetTicks() - timer.start_tick) / 1000,
	}
	gm.timer_marks_count += 1
	return true
}

timers_marks_clear :: proc() {
	gm.timer_marks_count = 0
}

timers_submit_input :: proc() {
	label := strings.trim_space(string(cstring(&gm.timer_ui.label_input[0])))
	if len(label) == 0 do label = "Timer"
	gm.timer_serial_next += 1
	if !timers_add(fmt.tprintf("%d. %s", gm.timer_serial_next, label), gm.timer_ui.seconds_input) {
		gm.timer_serial_next -= 1
		return
	}
	gm.timer_ui.label_input[0] = 0
	gm.timer_ui.seconds_input = DEFAULT_TIMER_SECONDS
}

// Any timer currently counting down.
timers_any_running :: proc() -> bool {
	for i in 0 ..< MAX_TIMERS {
		timer := &gm.timers[i]
		if timer.label != "" && timer.running && !timer.done do return true
	}
	return false
}

// Intersection of what a cue wants to fire and what it carries, so one
// dispatch can run several actions at once while a cue without its
// capability stays inert.
cue_fire_mask :: proc(cue_caps: Cue_Caps, cue_triggers: Cue_Triggers) -> Cue_Triggers {
	fire := Cue_Triggers{}
	if .Sound in cue_triggers && .Has_Sound in cue_caps do fire += {.Sound}
	if .Music in cue_triggers && .Has_Music in cue_caps do fire += {.Music}
	if .Lighting in cue_triggers && .Has_Lighting in cue_caps do fire += {.Lighting}
	if .Video in cue_triggers && .Has_Video in cue_caps do fire += {.Video}
	if .Score in cue_triggers && .Has_Score in cue_caps do fire += {.Score}
	return fire
}

// Fire one cue through every armed action at once, recording the masked set.
// Missing subsystems skip their side effect while the record still shows the
// dispatch.
cue_dispatch :: proc(cue: ^Cue) -> Cue_Triggers {
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
	if .Video in fire && gm.video != nil {
		if len(cue.video_page) > 0 {
			// Fall back to the current deck state when the cued page is gone.
			if !video_page_show(gm.video, cue.video_page) {
				gm.video.shown = true
			}
		} else {
			gm.video.shown = true
		}
	}
	if .Score in fire && gm.scores != nil {
		if cue.scoreboard >= 0 && cue.scoreboard < len(gm.scores.scoreboards) {
			gm.scores.active = cue.scoreboard
		}
		gm.scores.shown = true
	}
	return fire
}

// Resolve one random track from the cue's playlist and crossfade into it.
// A missing playlist or an empty pick is a programming error.
cue_music_fire :: proc(cue: ^Cue) {
	playlist := playlist_find_by_name(cue.playlist)
	ensure(playlist != nil)
	track := playlist_pick_random_track(playlist)
	ensure(track != nil)
	music_crossfade(playlist, track, cue.music_volume, cue.fade_in_s, cue.fade_out_s)
}

cue_fire :: proc(index: int) {
	cue_dispatch(&gm.timers[index].cue)
}

timers_cue_arm_sound :: proc(index: int, name: SoundEffectName, volume: f32) {
	timer := &gm.timers[index]
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
	timer := &gm.timers[index]
	timer.cue.caps += {.Has_Music}
	timer.cue.triggers += {.Music}
	timer.cue.playlist = playlist
	timer.cue.music_volume = volume
	timer.cue.fade_in_s = fade_in_s
	timer.cue.fade_out_s = fade_out_s
}

timers_cue_arm_lighting :: proc(index: int, look: LightingLook, fx_reset := false) {
	timer := &gm.timers[index]
	timer.cue.caps += {.Has_Lighting}
	timer.cue.triggers += {.Lighting}
	timer.cue.look = look
	timer.cue.lighting_fx_reset = fx_reset
}

timers_cue_arm_projection :: proc(index: int, video, score: bool, video_page := "", scoreboard := -1) {
	timer := &gm.timers[index]
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
	for i in 0 ..< MAX_TIMERS {
		timer := &gm.timers[i]
		if timer.label == "" do continue

		countdown_tick(&timer.flash_remaining_s, dt)
		if !timer.running || timer.done do continue

		if countdown_tick(&timer.remaining_s, dt) {
			timer.done = true
			timer.flash_remaining_s = TIMER_BLINK_SECONDS
			cue_fire(i)
		}
	}

	countdown_tick(&gm.timer_ui.overflow_hint_seconds, dt)
	countdown_tick(&gm.timer_ui.marks_overflow_hint_seconds, dt)
}

timers_draw :: proc() {
	imgui.PushStyleColorImVec4(.Border, {0.7, 0.15, 0.15, 1})
	imgui.BeginChild("TimersPanel", {TIMER_PANEL_WIDTH, 0}, child_flags = {.Borders})
	imgui.PopStyleColor(1)
	defer imgui.EndChild()

	imgui.AlignTextToFramePadding()
	imgui.TextColored({0.95, 0.25, 0.25, 1}, "Timers")
	imgui.SameLine()
	imgui.Text("%d/%d", timers_active_count(), MAX_TIMERS)

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

		for i in 0 ..< MAX_TIMERS {
			timers_timer_row_draw(i)
		}

		if gm.timer_ui.overflow_hint_seconds > 0 {
			imgui.TextColored({1, 0.2, 0.2, 1}, "Max 24 timers")
		}
	}

	imgui.Separator()

	imgui.AlignTextToFramePadding()
	imgui.TextColored({0.95, 0.25, 0.25, 1}, "Marks")
	imgui.SameLine()
	imgui.Text("%d/%d", timers_marks_count(), MAX_TIMER_MARKS)
	imgui.SameLine()
	if imgui.Button("Clear") do timers_marks_clear()

	if imgui.BeginChild("MarksList", {0, 0}, child_flags = {.FrameStyle}) {
		defer imgui.EndChild()

		for i in 0 ..< gm.timer_marks_count {
			mark := &gm.timer_marks[i]
			line := strings.clone_to_cstring(
				fmt.tprintf("%s  %.2fs", mark.timer_label, mark.elapsed_s),
				context.temp_allocator,
			)
			imgui.TextUnformatted(
				timers_text_clipped(
					string(line),
					imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x,
				),
			)
		}

		if gm.timer_ui.marks_overflow_hint_seconds > 0 {
			imgui.TextColored({1, 0.2, 0.2, 1}, "Max %d marks", MAX_TIMER_MARKS)
		}
	}
}

// Done-row blink alpha. The sine phase maps through the shared envelope,
// so the blink is the same lerp as music gain and lighting weight.
timer_blink_alpha :: proc(flash_remaining_s: f32, tick_ms: u64) -> f32 {
	if !(flash_remaining_s > 0) do return 1
	phase := (math.sin(f64(tick_ms) * 0.012) + 1) / 2
	keys := [2]Envelope_Point{{0, TIMER_BLINK_DIM}, {1, TIMER_BLINK_BRIGHT}}
	return envelope_value_at(keys[:], f32(phase))
}

timers_timer_row_draw :: proc(index: int) {
	timer := &gm.timers[index]
	if timer.label == "" do return

	row_width := imgui.GetContentRegionAvail().x

	if timer.done {
		x_button_width := timers_small_button_width("x")
		label_budget := row_width - x_button_width - imgui.GetStyle().ItemSpacing.x
		done_prefix_width := imgui.CalcTextSize("Done  ").x
		label_cstr := timers_text_clipped(timer.label, label_budget - done_prefix_width)

		blink_alpha := timer_blink_alpha(timer.flash_remaining_s, sdl.GetTicks())
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
		remaining := f32(math.ceil(timer.remaining_s))
		minutes := i64(remaining) / 60
		seconds := i64(remaining) % 60
		time_cstr := strings.clone_to_cstring(
			fmt.tprintf("%02d:%02d", minutes, seconds),
			context.temp_allocator,
		)
		time_width := imgui.CalcTextSize(time_cstr).x

		run_label := timer.running ? "Pause" : "Play"
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
				fmt.tprintf(timer.running ? "Pause##%d" : "Play##%d", index),
				context.temp_allocator,
			),
		) {
			if timer.running {
				timer.running = false
			} else {
				timers_start(index)
			}
		}

		imgui.SameLine()
		imgui.BeginDisabled(timer.remaining_s <= TIMER_MIN_SECONDS)
		if timers_small_button(
			strings.clone_to_cstring(fmt.tprintf("-##%d", index), context.temp_allocator),
		) {
			timers_adjust(index, -TIMER_STEP_SECONDS)
		}
		imgui.EndDisabled()

		imgui.SameLine()
		imgui.BeginDisabled(timer.remaining_s >= TIMER_MAX_SECONDS)
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

// Clip a single line of text to max_px, replacing the tail with an ellipsis,
// cutting only on rune boundaries. Binary-searches the longest fitting prefix
// so the cost is O(log n) allocations, not one per rune.
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
