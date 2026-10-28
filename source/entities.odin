package game

import hm "core:container/handle_map"
import "core:strings"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

Entity :: struct {
	handle:               Entity_Handle,
	caps:                 Entity_Caps,
	label:                string,
	fade:                 Entity_Fade,
	timer:                Entity_Timer,
	cue:                  Entity_Cue,
	mark:                 Entity_Mark,
	track:                Entity_Track,
	video:                Entity_Video,
	music:                Entity_Music,
	sound:                Entity_Sound,
	score:                Entity_Score,
	lighting:             Lighting_Handle,
	playlist_tracks:      [dynamic]Entity_Handle,
	playlist_last_played: Entity_Handle,
}

Entity_Handle :: distinct hm.Handle64

ENTITY_HANDLE_NIL :: Entity_Handle{}

Lighting_Handle :: distinct hm.Handle64

Entity_Cap :: enum u8 {
	Timer,
	Mark,
	Track,
	Playlist,
	Video,
	Music,
	Sound,
	Lighting,
	Score,
	Projection,
}

Entity_Caps :: bit_set[Entity_Cap;u16]

Entity_Fade :: struct {
	duration_s:   f32,
	remaining_s:  f32,
	source_value: f32,
	target_value: f32,
}

Entity_Timer :: struct {
	remaining_s:       f32,
	running:           bool,
	done:              bool,
	flash_remaining_s: f32,
	start_tick:        u64,
}

Entity_Cue :: struct {
	caps:              Cue_Caps,
	triggers:          Cue_Triggers,
	fired:             Cue_Triggers,
	sound:             SoundEffectName,
	sound_volume:      f32,
	playlist:          Entity_Handle,
	music_volume:      f32,
	fade_in_s:         f32,
	fade_out_s:        f32,
	look:              LightingLook,
	lighting_fx_reset: bool,
	video_page:        string,
	scoreboard:        int,
}

Entity_Mark :: struct {
	elapsed_s: f32,
}

Entity_Track :: struct {
	path:           string,
	title:          string,
	played:         bool,
	duration_s:     f32,
	file_hash:      string,
	bounds_start_s: f32,
	bounds_end_s:   f32,
}

// The video deck itself. The sole {.Video, .Projection} entity owns the
// pages, persistence, and playback references; no separate state mirrors it.
// The selected page is always the default projection source; nothing hides
// the deck.
Entity_Video :: struct {
	pages:    [dynamic]VideoPage,
	settings: VideoSettings,
	selected: string,
	active:   ^VideoPlayback,
	retired:  [dynamic]^VideoPlayback,
	previous: VideoProjectionFrame,
}

Entity_Music :: struct {
	playlist: Entity_Handle,
	track:    Entity_Handle,
	playback: ^MusicPlayback,
}

Entity_Sound :: struct {
	name:        SoundEffectName,
	volume:      f32,
	duration_s:  f32,
	fading:      bool,
	mixer_track: ^mixer.Track,
	mixer_audio: ^mixer.Audio,
}

// Sparse payload of a .Lighting entity. Entity.lighting and owner link the
// two records in both directions.
Entity_Lighting :: struct {
	handle: Lighting_Handle,
	owner:  Entity_Handle,
	look:   LightingLook,
	fx:     [LightingFxKind]LightingFx,
}

Entity_Score :: struct {
	red:                 u16,
	blue:                u16,
	background_filename: string,
	background_texture:  ^sdl.Texture,
	background_missing:  bool,
	background_width:    int,
	background_height:   int,
	regions:             [Score_Team]Score_Region,
}

Entity_Draw_Record :: struct {
	display: DisplayKind,
	handle:  Entity_Handle,
}

Entity_Store :: struct {
	// Chunked storage: addresses stay stable as the maps grow, and a reused
	// slot bumps its generation so stale handles stop resolving.
	entities:         hm.Dynamic_Handle_Map(Entity, Entity_Handle),
	lighting_states:  hm.Dynamic_Handle_Map(Entity_Lighting, Lighting_Handle),
	sound:            [dynamic]Entity_Handle,
	lighting:         [dynamic]Entity_Handle,
	timer:            [dynamic]Entity_Handle,
	mark:             [dynamic]Entity_Handle,
	video:            [dynamic]Entity_Handle,
	music:            [dynamic]Entity_Handle,
	score:            [dynamic]Entity_Handle,
	playlist:         [dynamic]Entity_Handle,
	track:            [dynamic]Entity_Handle,
	playlist_handles: map[string]Entity_Handle,
	track_handles:    map[string]Entity_Handle,
	draw_records:     [dynamic]Entity_Draw_Record,
}

entity_store_init :: proc(store: ^Entity_Store) {
	ensure(store != nil)
	hm.dynamic_init(&store.entities, context.allocator)
	hm.dynamic_init(&store.lighting_states, context.allocator)
	store.sound = make([dynamic]Entity_Handle)
	store.lighting = make([dynamic]Entity_Handle)
	store.timer = make([dynamic]Entity_Handle)
	store.mark = make([dynamic]Entity_Handle)
	store.video = make([dynamic]Entity_Handle)
	store.music = make([dynamic]Entity_Handle)
	store.score = make([dynamic]Entity_Handle)
	store.playlist = make([dynamic]Entity_Handle)
	store.track = make([dynamic]Entity_Handle)
	store.playlist_handles = make(map[string]Entity_Handle)
	store.track_handles = make(map[string]Entity_Handle)
	store.draw_records = make([dynamic]Entity_Draw_Record)
}

entity_create :: proc(caps: Entity_Caps, label: string) -> Entity_Handle {
	ensure(gm != nil)
	ensure(caps != {})
	store := &gm.entities
	handle, err := hm.add(&store.entities, Entity{caps = caps})
	ensure(err == nil)
	entity := entity_must_get(handle)
	if len(label) > 0 do entity.label = strings.clone(label)
	if .Sound in caps do append(&store.sound, handle)
	if .Lighting in caps {
		lighting, lighting_err := hm.add(&store.lighting_states, Entity_Lighting{owner = handle})
		ensure(lighting_err == nil)
		entity.lighting = lighting
		append(&store.lighting, handle)
	}
	if .Timer in caps do append(&store.timer, handle)
	if .Mark in caps do append(&store.mark, handle)
	if .Video in caps do append(&store.video, handle)
	if .Music in caps do append(&store.music, handle)
	if .Score in caps do append(&store.score, handle)
	if .Playlist in caps do append(&store.playlist, handle)
	if .Track in caps do append(&store.track, handle)
	return handle
}

entity_get :: proc(handle: Entity_Handle) -> (^Entity, bool) {
	if gm == nil do return nil, false
	return hm.get(&gm.entities.entities, handle)
}

entity_must_get :: proc(handle: Entity_Handle) -> ^Entity {
	entity, ok := entity_get(handle)
	ensure(ok)
	return entity
}

@(private = "file")
entity_domain_remove :: proc(array: ^[dynamic]Entity_Handle, handle: Entity_Handle) {
	for candidate, i in array {
		if candidate == handle {
			ordered_remove(array, i)
			return
		}
	}
}

// Destruction releases everything the entity owns: domain membership, the
// lighting payload, and a music entity's live playback.
entity_destroy :: proc(handle: Entity_Handle) {
	entity, ok := entity_get(handle)
	ensure(ok)
	caps := entity.caps
	store := &gm.entities
	if .Sound in caps do entity_domain_remove(&store.sound, handle)
	if .Lighting in caps {
		entity_domain_remove(&store.lighting, handle)
		state, state_ok := hm.get(&store.lighting_states, entity.lighting)
		ensure(state_ok && state.owner == handle)
		found, err := hm.remove(&store.lighting_states, entity.lighting)
		ensure(found && err == nil)
	}
	if .Timer in caps do entity_domain_remove(&store.timer, handle)
	if .Mark in caps do entity_domain_remove(&store.mark, handle)
	if .Video in caps do entity_domain_remove(&store.video, handle)
	if .Music in caps {
		if playback := entity.music.playback; playback != nil {
			ensure(playback.entity == handle && playback.mixer_track != nil)
			voice_track_teardown(playback.mixer_track, playback.mixer_audio)
			playback^ = {}
		}
		if gm.music_primary == handle do gm.music_primary = ENTITY_HANDLE_NIL
		entity_domain_remove(&store.music, handle)
	}
	if .Score in caps do entity_domain_remove(&store.score, handle)
	if .Playlist in caps {
		entity_domain_remove(&store.playlist, handle)
		if store.playlist_handles[entity.label] == handle do delete_key(&store.playlist_handles, entity.label)
	}
	if .Track in caps {
		entity_domain_remove(&store.track, handle)
		if store.track_handles[entity.track.path] == handle do delete_key(&store.track_handles, entity.track.path)
	}
	found, err := hm.remove(&store.entities, handle)
	ensure(found && err == nil)
}

entity_domain_clear :: proc(array: ^[dynamic]Entity_Handle) {
	for len(array) > 0 do entity_destroy(array[0])
}

entity_fade_start :: proc(
	entity: ^Entity,
	duration_s: f32,
	source_value: f32 = 1,
	target_value: f32 = 0,
) {
	ensure(entity != nil)
	if duration_s <= 0 do return
	entity.fade = {
		duration_s   = duration_s,
		remaining_s  = duration_s,
		source_value = source_value,
		target_value = target_value,
	}
}

entity_fade_value_at :: proc(entity: ^Entity) -> f32 {
	ensure(entity != nil)
	if entity.fade.remaining_s <= 0 || entity.fade.duration_s <= 0 do return entity.fade.target_value
	elapsed := entity.fade.duration_s - entity.fade.remaining_s
	keys := [2]Envelope_Point {
		{0, entity.fade.source_value},
		{entity.fade.duration_s, entity.fade.target_value},
	}
	return envelope_value_at(keys[:], elapsed)
}

entity_fade_tick :: proc(entity: ^Entity, dt: f32) -> bool {
	ensure(entity != nil)
	if entity.fade.remaining_s <= 0 do return false
	entity.fade.remaining_s = max(entity.fade.remaining_s - dt, 0)
	return entity.fade.remaining_s <= 0
}

entity_record_emit :: proc(display: DisplayKind, handle: Entity_Handle) {
	ensure(gm != nil)
	append(&gm.entities.draw_records, Entity_Draw_Record{display = display, handle = handle})
}

entity_playlist_create :: proc(name: string) -> Entity_Handle {
	ensure(gm != nil)
	if handle, found := gm.entities.playlist_handles[name]; found {
		_, alive := entity_get(handle)
		ensure(alive)
		return handle
	}
	handle := entity_create({.Playlist}, name)
	entity := entity_must_get(handle)
	entity.playlist_tracks = make([dynamic]Entity_Handle)
	gm.entities.playlist_handles[entity.label] = handle
	return handle
}

entity_track_create :: proc(path: string, title: string) -> Entity_Handle {
	ensure(gm != nil)
	if handle, found := gm.entities.track_handles[path]; found {
		_, alive := entity_get(handle)
		ensure(alive)
		return handle
	}
	handle := entity_create({.Track}, "")
	entity := entity_must_get(handle)
	entity.track.path = strings.clone(path)
	entity.track.title = strings.clone(title)
	gm.entities.track_handles[entity.track.path] = handle
	return handle
}

entity_playlist_handle_for_label :: proc(label: string) -> Entity_Handle {
	if gm == nil do return ENTITY_HANDLE_NIL
	if handle, ok := gm.entities.playlist_handles[label]; ok {
		if _, alive := entity_get(handle); alive do return handle
	}
	return ENTITY_HANDLE_NIL
}

entity_playlist_handle_for_name :: proc(name: PlaylistName) -> Entity_Handle {
	return entity_playlist_handle_for_label(playlist_name_string(name))
}

entity_track_handle_for_path :: proc(path: string) -> Entity_Handle {
	if gm == nil do return ENTITY_HANDLE_NIL
	if handle, ok := gm.entities.track_handles[path]; ok {
		if _, alive := entity_get(handle); alive do return handle
	}
	return ENTITY_HANDLE_NIL
}

entities_frame_update :: proc(dt: f32) {
	profiler_scope(#procedure)
	ensure(gm != nil)
	clear(&gm.entities.draw_records)

	sound_section_update(dt)
	for handle in gm.entities.sound do entity_record_emit(.Controls, handle)

	music_section_update()
	for handle in gm.entities.music do entity_record_emit(.Controls, handle)

	lighting_update(dt)
	for handle in gm.entities.lighting do entity_record_emit(.Controls, handle)

	timers_update(dt)

	for handle in gm.entities.mark do entity_record_emit(.Controls, handle)

	video_update()
	for handle in gm.entities.video {
		entity, ok := entity_get(handle)
		ensure(ok)
		entity_record_emit(entity.video.selected != "" ? .Projection : .Controls, handle)
	}

	for handle in gm.entities.playlist do entity_record_emit(.Controls, handle)
	for handle in gm.entities.track do entity_record_emit(.Controls, handle)

	for handle in gm.entities.score {
		_, ok := entity_get(handle)
		ensure(ok)
		// Visibility is the selection reference. No per-entity check.
		shown := gm.scores != nil && gm.scores.active >= 0
		entity_record_emit(shown ? .Projection : .Controls, handle)
	}

	gm.projection_source, gm.projection_handle = entity_projection_resolve()
}

entity_projection_resolve :: proc() -> (ProjectionSource, Entity_Handle) {
	ensure(gm != nil)
	score_handle := ENTITY_HANDLE_NIL
	video_handle := ENTITY_HANDLE_NIL
	for record in gm.entities.draw_records {
		if record.display != .Projection do continue
		entity, ok := entity_get(record.handle)
		if !ok do continue
		if .Timer in entity.caps && entity.timer.running && !entity.timer.done {
			return .Timer, record.handle
		}
		if .Score in entity.caps && score_handle == ENTITY_HANDLE_NIL do score_handle = record.handle
		if .Video in entity.caps && video_handle == ENTITY_HANDLE_NIL do video_handle = record.handle
	}
	if score_handle != ENTITY_HANDLE_NIL do return .Score, score_handle
	if video_handle != ENTITY_HANDLE_NIL do return .Video, video_handle
	return .Blank, ENTITY_HANDLE_NIL
}
