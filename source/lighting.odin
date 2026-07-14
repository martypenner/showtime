package game

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "osc"
import rl "vendor:raylib"

LightingLook :: enum {
	House,
	Scene,
	SceneWithFullFade,
	CenterFocus,
}

LightingFxKind :: enum {
	Blackout,
	RainbowSting,
	Rain,
	Innuendo,
	AveMaria,
}

LIGHTING_FX_KEYS_MAX :: 8

// Keys must be in ascending `at_seconds` order, starting at 0.
LightingFxKey :: struct {
	at_seconds: f32,
	weight:     f32,
}

LightingFx :: struct {
	keys:           [LIGHTING_FX_KEYS_MAX]LightingFxKey,
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

lighting_fx_run :: proc(kind: LightingFxKind, keys: []LightingFxKey) {
	ensure(len(keys) > 0 && len(keys) <= LIGHTING_FX_KEYS_MAX)
	fx := &gm.lighting.fx[kind]
	copy(fx.keys[:], keys)
	fx.key_count = u8(len(keys))
	fx.elapsed = 0
	fx.weight_current = keys[0].weight
}

lighting_fx_deactivate_all :: proc() {
	for &fx, kind in gm.lighting.fx {
		lighting_fx_run(kind, {{0, fx.weight_current}, {2, 0}})
	}
}

lighting_update :: proc() {
	socket, socket_ok := gm.lighting.socket.?
	ensure(socket_ok)

	frame_time := rl.GetFrameTime()
	for &fx, kind in gm.lighting.fx {
		if fx.key_count == 0 do continue
		fx.elapsed += frame_time
		last_key := fx.keys[fx.key_count - 1]
		weight := last_key.weight
		if fx.elapsed < last_key.at_seconds {
			seg := 0
			for fx.keys[seg + 1].at_seconds <= fx.elapsed do seg += 1
			a := fx.keys[seg]
			b := fx.keys[seg + 1]
			weight = math.lerp(
				a.weight,
				b.weight,
				(fx.elapsed - a.at_seconds) / (b.at_seconds - a.at_seconds),
			)
		}
		fx.weight_current = weight

		if weight != fx.weight_sent {
			osc.float_send(socket, gm.lighting.endpoint, gm.lighting.fx_osc_address[kind], weight)
			fx.weight_sent = weight
		}
	}
}
