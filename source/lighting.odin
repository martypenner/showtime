package game

import "core:fmt"
import "core:log"
import "core:strings"
import "osc"

LightingLook :: enum {
	House,
	Scene,
	SceneWithFullFade,
	CenterFocus,
	Challenge,
	FinalShowdown,
}

LightingFxKind :: enum {
	Blackout,
	RainbowSting,
	Rain,
	Innuendo,
	AveMaria,
}

LightingFx :: struct {
	keys:           [ENVELOPE_KEYS_MAX]Envelope_Point,
	key_count:      u8,
	elapsed:        f32,
	weight_current: f32,
	weight_sent:    f32,
}

lighting_init :: proc() {
	for kind in LightingFxKind {
		kind_str, enum_ok := fmt.enum_value_to_string(kind)
		log.ensuref(enum_ok, "Failed to convert LightingFxKind enum to string: %v", kind)
		gm.lighting.fx_osc_address[kind] = fmt.aprint(
			"/globalEffects/",
			strings.to_camel_case(kind_str, context.temp_allocator),
			"/effects/weight",
			sep = "",
		)
	}
}

lighting_look_activate :: proc(look: LightingLook) {
	socket, ok := gm.lighting.socket.?
	ensure(ok)

	look_str, enum_ok := fmt.enum_value_to_string(look)
	log.ensuref(enum_ok, "Failed to convert LightingLook enum to string: %v", enum_ok)
	look_name := strings.to_camel_case(look_str, context.temp_allocator)
	log.debugf("Activating lighting look: %s", look_name)

	gm.lighting.active_look = look
	osc.float_send(
		socket,
		gm.lighting.endpoint,
		fmt.tprint("/scenes/", look_name, "/load", sep = ""),
		1.0,
	)
}

lighting_fx_run :: proc(kind: LightingFxKind, keys: []Envelope_Point) {
	ensure(len(keys) > 0 && len(keys) <= len(gm.lighting.fx[kind].keys))
	ensure(keys[0].at_seconds == 0)
	for key, key_index in keys {
		ensure(key.at_seconds >= 0 && key.value >= 0)
		if key_index > 0 do ensure(key.at_seconds > keys[key_index - 1].at_seconds)
	}
	fx := &gm.lighting.fx[kind]
	copy(fx.keys[:], keys)
	fx.key_count = u8(len(keys))
	fx.elapsed = 0
	fx.weight_current = keys[0].value
}

lighting_fx_deactivate_all :: proc() {
	for &fx, kind in gm.lighting.fx {
		lighting_fx_run(kind, {{0, fx.weight_current}, {2, 0}})
	}
}

lighting_update :: proc(dt: f32) {
	socket, socket_ok := gm.lighting.socket.?
	ensure(socket_ok)

	for &fx, kind in gm.lighting.fx {
		if fx.key_count == 0 do continue
		fx.elapsed += dt
		weight := envelope_value_at(fx.keys[:fx.key_count], fx.elapsed)
		fx.weight_current = weight

		if weight != fx.weight_sent {
			osc.float_send(socket, gm.lighting.endpoint, gm.lighting.fx_osc_address[kind], weight)
			fx.weight_sent = weight
		}
	}
}
