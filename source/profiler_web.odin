// core:prof/spall writes through core:os, which is unavailable on js/wasm.

#+build wasm32, wasm64p32

package game

profiler_start :: proc() {}

profiler_stop :: proc() {}

profiler_flush :: proc() {}

profiler_scope :: proc(name: string, args: string = "", loc := #caller_location) {}
