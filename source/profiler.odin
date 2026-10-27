// Spall tracing. Build with `-define:PROFILING=true` to record the scopes
// below to trace.spall in the working directory.

#+build !wasm32
#+build !wasm64p32

package game

import "base:runtime"
import "core:prof/spall"
import "core:sync"

PROFILING :: #config(PROFILING, false)

@(private = "file")
spall_context: spall.Context
@(private = "file")
spall_buffer: spall.Buffer
@(private = "file")
spall_active: bool

profiler_start :: proc() {
	when !PROFILING do return

	// A scale of 1 uses the monotonic clock in nanoseconds. The overload that
	// calibrates the TSC sleeps for two seconds first.
	ctx, ok := spall.context_create_with_scale("trace.spall", false, 1)
	ensure(ok, "Failed to create spall context")
	spall_context = ctx

	backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
	buffer, buffer_ok := spall.buffer_create(backing, u32(sync.current_thread_id()))
	ensure(buffer_ok, "Failed to create spall buffer")
	spall_buffer = buffer
	spall_active = true
}

profiler_stop :: proc() {
	when !PROFILING do return
	if !spall_active do return

	// Flushes the tail of the trace before shutdown continues.
	spall.buffer_destroy(&spall_context, &spall_buffer)
	spall.context_destroy(&spall_context)
	spall_active = false
}

profiler_flush :: proc() {
	when !PROFILING do return
	if !spall_active do return
	spall.buffer_flush(&spall_context, &spall_buffer)
}

// The scope ends when the calling scope exits, so put this at the top of a
// procedure or in its own block.
@(deferred_in=profiler_scope_end)
profiler_scope :: proc(name: string, args: string = "", loc := #caller_location) {
	when !PROFILING do return
	if !spall_active do return
	spall._buffer_begin(&spall_context, &spall_buffer, name, args, loc)
}

profiler_scope_end :: proc(name: string, args: string, loc: runtime.Source_Code_Location) {
	when !PROFILING do return
	if !spall_active do return
	spall._buffer_end(&spall_context, &spall_buffer)
}
