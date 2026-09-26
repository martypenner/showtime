package game

import imgui "../vendor/odin-imgui"
import "core:log"
import "core:math"
import "core:strings"
import norm "path_normalize"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

WAVEFORM_HEIGHT :: f32(120)
WAVEFORM_HANDLE_RADIUS :: f32(5)

WaveEditorPreview :: struct {
	audio:       ^mixer.Audio,
	mixer_track: ^mixer.Track,
	active:      bool,
}

wave_editor_preview_is_playing :: proc() -> bool {
	if sound_settings.wave_editor_preview.active &&
	   !mixer.TrackPlaying(sound_settings.wave_editor_preview.mixer_track) {
		wave_editor_preview_stop()
	}
	return sound_settings.wave_editor_preview.active
}

wave_editor_preview_stop :: proc() {
	preview := &sound_settings.wave_editor_preview
	if !preview.active do return
	if mixer.TrackPlaying(preview.mixer_track) do ensure(mixer.StopTrack(preview.mixer_track, 0))
	mixer.DestroyTrack(preview.mixer_track)
	mixer.DestroyAudio(preview.audio)
	preview^ = {}
}

wave_editor_preview_start :: proc(track: ^Track) {
	wave_editor_preview_stop()

	generated_track, ok := TRACKS[norm.path_nfc(track.path)]
	ensure(ok)
	bounds, stale := music_track_bounds_resolve(
		sound_settings.music_track_bounds,
		norm.path_nfc(track.path),
		generated_track.file_hash,
		generated_track.duration_seconds,
	)
	ensure(!stale && bounds.start_time < bounds.end_time)

	for &playback in sound_settings.music_playbacks {
		if playback.mixer_track != nil do music_playback_stop(&playback)
	}

	audio := mixer.LoadAudio(
		sound_settings.mixer,
		strings.clone_to_cstring(track.path, context.temp_allocator),
		false,
	)
	ensure(audio != nil)
	mixer_track := mixer.CreateTrack(sound_settings.mixer)
	ensure(mixer_track != nil)
	ensure(mixer.SetTrackAudio(mixer_track, audio))
	ensure(
		mixer.SetTrackGain(
			mixer_track,
			sound_settings.music_volume * track_volume_multiplier(generated_track.active_rms),
		),
	)
	start_frame := mixer.AudioMSToFrames(audio, i64(bounds.start_time * 1000))
	max_frame := min(
		mixer.AudioMSToFrames(audio, i64(bounds.end_time * 1000)),
		mixer.GetAudioDuration(audio),
	)
	ensure(max_frame > start_frame)
	props := sound_play_options(start_frame, max_frame, 0, 1)
	defer sdl.DestroyProperties(props)
	ensure(mixer.PlayTrack(mixer_track, props))
	sound_settings.wave_editor_preview = {
		audio       = audio,
		mixer_track = mixer_track,
		active      = true,
	}
}

wave_editor_track_select :: proc(track: ^Track) {
	wave_editor_preview_stop()
	generated_track, ok := TRACKS[norm.path_nfc(track.path)]
	ensure(ok && generated_track.duration_seconds > 0)
	bounds, stale := music_track_bounds_resolve(
		sound_settings.music_track_bounds,
		norm.path_nfc(track.path),
		generated_track.file_hash,
		generated_track.duration_seconds,
	)
	if stale {
		log.warnf("Ignoring bounds for changed track: %s", track.path)
		delete_key(&sound_settings.music_track_bounds, norm.path_nfc(track.path))
		sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}
	sound_settings.wave_editor_start_fraction =
		bounds.start_time / generated_track.duration_seconds
	sound_settings.wave_editor_end_fraction = bounds.end_time / generated_track.duration_seconds
}

wave_editor :: proc() {
	track := music_browser_track_selected()
	generated_track, ok := TRACKS[norm.path_nfc(track.path)]
	ensure(ok && generated_track.duration_seconds > 0)

	origin := imgui.GetCursorScreenPos()
	width := imgui.GetContentRegionAvail().x
	ensure(width > WAVEFORM_HANDLE_RADIUS * 2)
	draw_list := imgui.GetWindowDrawList()
	start_x := origin.x + sound_settings.wave_editor_start_fraction * width
	end_x := origin.x + sound_settings.wave_editor_end_fraction * width
	bottom_y := origin.y + WAVEFORM_HEIGHT

	imgui.DrawList_AddRectFilled(
		draw_list,
		origin,
		{start_x, bottom_y},
		imgui.GetColorU32ImVec4({0.12, 0.12, 0.12, 1}),
	)
	imgui.DrawList_AddRectFilled(
		draw_list,
		{start_x, origin.y},
		{end_x, bottom_y},
		imgui.GetColorU32ImVec4({0.05, 0.18, 0.35, 1}),
	)
	imgui.DrawList_AddRectFilled(
		draw_list,
		{end_x, origin.y},
		{origin.x + width, bottom_y},
		imgui.GetColorU32ImVec4({0.12, 0.12, 0.12, 1}),
	)

	center_y := origin.y + WAVEFORM_HEIGHT / 2
	waveform_samples := generated_track.waveform_samples
	for sample, index in waveform_samples {
		if index == 0 do continue
		x0 := origin.x + f32(index - 1) * width / f32(len(waveform_samples) - 1)
		x1 := origin.x + f32(index) * width / f32(len(waveform_samples) - 1)
		y0 := center_y - f32(waveform_samples[index - 1]) / 127 * WAVEFORM_HEIGHT / 2
		y1 := center_y - f32(sample) / 127 * WAVEFORM_HEIGHT / 2
		imgui.DrawList_AddLine(
			draw_list,
			{x0, y0},
			{x1, y1},
			imgui.GetColorU32ImVec4({0.3, 0.7, 1, 1}),
		)
	}

	handle_color := imgui.GetColorU32ImVec4({0.9, 0.9, 0.9, 1})
	handle_positions := [2]f32{start_x, end_x}
	for x in handle_positions {
		imgui.DrawList_AddLine(draw_list, {x, origin.y}, {x, bottom_y}, handle_color, 3)
		imgui.DrawList_AddCircleFilled(
			draw_list,
			{x, origin.y},
			WAVEFORM_HANDLE_RADIUS,
			handle_color,
		)
		imgui.DrawList_AddCircleFilled(
			draw_list,
			{x, bottom_y},
			WAVEFORM_HANDLE_RADIUS,
			handle_color,
		)
	}

	changed := false
	imgui.SetCursorScreenPos({start_x - WAVEFORM_HANDLE_RADIUS, origin.y})
	imgui.InvisibleButton("##wave-start", {WAVEFORM_HANDLE_RADIUS * 2, WAVEFORM_HEIGHT})
	if imgui.IsItemHovered() || imgui.IsItemActive() do imgui.SetMouseCursor(.ResizeEW)
	if imgui.IsItemActive() {
		sound_settings.wave_editor_start_fraction = math.clamp(
			(imgui.GetMousePos().x - origin.x) / width,
			0,
			sound_settings.wave_editor_end_fraction - WAVEFORM_HANDLE_RADIUS / width,
		)
		changed = true
	}

	imgui.SetCursorScreenPos({end_x - WAVEFORM_HANDLE_RADIUS, origin.y})
	imgui.InvisibleButton("##wave-end", {WAVEFORM_HANDLE_RADIUS * 2, WAVEFORM_HEIGHT})
	if imgui.IsItemHovered() || imgui.IsItemActive() do imgui.SetMouseCursor(.ResizeEW)
	if imgui.IsItemActive() {
		sound_settings.wave_editor_end_fraction = math.clamp(
			(imgui.GetMousePos().x - origin.x) / width,
			sound_settings.wave_editor_start_fraction + WAVEFORM_HANDLE_RADIUS / width,
			1,
		)
		changed = true
	}
	imgui.SetCursorScreenPos({origin.x, bottom_y + WAVEFORM_HANDLE_RADIUS})

	imgui.Dummy({0, 0})

	if changed {
		if sound_settings.wave_editor_start_fraction == 0 &&
		   sound_settings.wave_editor_end_fraction == 1 {
			delete_key(&sound_settings.music_track_bounds, norm.path_nfc(track.path))
		} else {
			sound_settings.music_track_bounds[norm.path_nfc(track.path)] = {
				file_hash  = generated_track.file_hash,
				start_time = sound_settings.wave_editor_start_fraction * generated_track.duration_seconds,
				end_time   = sound_settings.wave_editor_end_fraction * generated_track.duration_seconds,
			}
		}
		sound_settings.settings_save_time_left = SOUND_SETTINGS_SAVE_DEBOUNCE_DURATION
	}
}
