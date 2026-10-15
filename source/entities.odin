package game

import "core:strings"
import sdl "vendor:sdl3"
import mixer "vendor:sdl3/mixer"

Entity :: struct {
	handle:          Entity_Handle,
	caps:            Entity_Caps,
	triggers:        Entity_Triggers,
	fired:           Entity_Triggers,
	label:           string,
	fade:            Entity_Fade,
	timer:           Entity_Timer,
	cue:             Entity_Cue,
	mark:            Entity_Mark,
	track:           Entity_Track,
	video:           Entity_Video,
	music:           Entity_Music,
	sound:           Entity_Sound,
	lighting:        Entity_Lighting,
	score:           Entity_Score,
	playlist_tracks: [dynamic]Entity_Handle,
}

Entity_Handle :: distinct u32

ENTITY_HANDLE_NIL :: Entity_Handle(0)

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

Entity_Caps :: bit_set[Entity_Cap; u16]

Entity_Trigger :: enum u8 {
	Sound,
	Music,
	Lighting,
	Video,
	Score,
	Fade_Out,
}

Entity_Triggers :: bit_set[Entity_Trigger; u8]

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
	path:        string,
	title:       string,
	played:      bool,
	duration_s:  f32,
	file_hash:   string,
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
	playlist:        Entity_Handle,
	track:           Entity_Handle,
	volume_endpoint: f32,
	playback:        ^MusicPlayback,
}

Entity_Sound :: struct {
	name:        SoundEffectName,
	volume:      f32,
	duration_s:  f32,
	fading:      bool,
	mixer_track: ^mixer.Track,
	mixer_audio: ^mixer.Audio,
}

Entity_Lighting :: struct {
	look: LightingLook,
	fx:   [LightingFxKind]LightingFx,
}

Entity_Score :: struct {
	shown:               bool,
	active:              bool,
	red:                 u16,
	blue:                u16,
	background_filename: string,
	background_texture:  ^sdl.Texture,
	background_missing:  bool,
	background_width:    int,
	background_height:   int,
	regions:             [Score_Team]Score_Region,
}

// Handle map entry. The handle packs the generation in the top byte and the
// entry index plus one in the lower bits, so a reused slot never aliases a
// destroyed entity.
Entity_Store_Entry :: struct {
	entity:     Entity,
	generation: u32,
	alive:      bool,
}

Entity_Draw_Record :: struct {
	display: DisplayKind,
	handle:  Entity_Handle,
}

Entity_Store :: struct {
	entries:          [dynamic]Entity_Store_Entry,
	free:             [dynamic]u32,
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
	store.entries = make([dynamic]Entity_Store_Entry)
	store.free = make([dynamic]u32)
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

@(private = "file")
entity_handle_make :: proc(index: u32, generation: u32) -> Entity_Handle {
	return Entity_Handle((generation << 24) | (index + 1))
}

@(private = "file")
entity_handle_split :: proc(handle: Entity_Handle) -> (index: u32, generation: u32, ok: bool) {
	raw := u32(handle)
	if raw == 0 do return 0, 0, false
	index = (raw & 0xFFFFFF) - 1
	generation = raw >> 24
	ok = true
	return
}

entity_create :: proc(caps: Entity_Caps, label: string) -> Entity_Handle {
	ensure(gm != nil)
	ensure(caps != {})
	store := &gm.entities
	index: u32
	generation: u32
	if len(store.free) > 0 {
		index = pop(&store.free)
		entry := &store.entries[index]
		ensure(!entry.alive)
		entry.generation += 1
		if entry.generation == 0 || entry.generation > 0xFF do entry.generation = 1
		generation = entry.generation
		entry.entity = {}
		entry.alive = true
	} else {
		index = u32(len(store.entries))
		ensure(index < 0xFFFFFF)
		generation = 1
		append(&store.entries, Entity_Store_Entry{entity = {}, generation = generation, alive = true})
	}
	handle := entity_handle_make(index, generation)
	entry := &store.entries[index]
	entry.entity.handle = handle
	entry.entity.caps = caps
	if len(label) > 0 do entry.entity.label = strings.clone(label)
	if .Sound in caps do append(&store.sound, handle)
	if .Lighting in caps do append(&store.lighting, handle)
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
	index, generation, ok := entity_handle_split(handle)
	if !ok || int(index) >= len(gm.entities.entries) do return nil, false
	entry := &gm.entities.entries[index]
	if !entry.alive || entry.generation != generation do return nil, false
	return &entry.entity, true
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

entity_destroy :: proc(handle: Entity_Handle) {
	entity, ok := entity_get(handle)
	ensure(ok)
	caps := entity.caps
	store := &gm.entities
	if .Sound in caps do entity_domain_remove(&store.sound, handle)
	if .Lighting in caps do entity_domain_remove(&store.lighting, handle)
	if .Timer in caps do entity_domain_remove(&store.timer, handle)
	if .Mark in caps do entity_domain_remove(&store.mark, handle)
	if .Video in caps do entity_domain_remove(&store.video, handle)
	if .Music in caps do entity_domain_remove(&store.music, handle)
	if .Score in caps do entity_domain_remove(&store.score, handle)
	if .Playlist in caps do entity_domain_remove(&store.playlist, handle)
	if .Track in caps do entity_domain_remove(&store.track, handle)
	index, _, _ := entity_handle_split(handle)
	entity^ = {}
	store.entries[index].alive = false
	append(&store.free, index)
}

entity_domain_clear :: proc(array: ^[dynamic]Entity_Handle) {
	for len(array) > 0 do entity_destroy(array[0])
}

entity_fade_start :: proc(entity: ^Entity, duration_s: f32, source_value: f32 = 1, target_value: f32 = 0) {
	ensure(entity != nil)
	if duration_s <= 0 do return
	entity.fade = {duration_s = duration_s, remaining_s = duration_s, source_value = source_value, target_value = target_value}
}

entity_fade_value_at :: proc(entity: ^Entity) -> f32 {
	ensure(entity != nil)
	if entity.fade.remaining_s <= 0 || entity.fade.duration_s <= 0 do return entity.fade.target_value
	elapsed := entity.fade.duration_s - entity.fade.remaining_s
	keys := [2]Envelope_Point{{0, entity.fade.source_value}, {entity.fade.duration_s, entity.fade.target_value}}
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
	key := strings.clone(path)
	if handle, found := gm.entities.track_handles[key]; found {
		_, alive := entity_get(handle)
		ensure(alive)
		return handle
	}
	handle := entity_create({.Track}, title)
	entity := entity_must_get(handle)
	entity.track.path = strings.clone(path)
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
	ensure(gm != nil)
	clear(&gm.entities.draw_records)

	sound_section_update(dt)
	for handle in gm.entities.sound do entity_record_emit(.Controls, handle)

	music_section_update()
	for handle in gm.entities.music do entity_record_emit(.Controls, handle)

	lighting_update(dt)
	lighting_entity_sync()
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

	score_entity_sync()
	for handle in gm.entities.score {
		entity, ok := entity_get(handle)
		ensure(ok)
		entity_record_emit(entity.score.shown ? .Projection : .Controls, handle)
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
