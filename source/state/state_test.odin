package state

import "core:testing"

// Gating contract: playground state must contribute to the shared, hot-reloaded
// GameMemory only when the PLAYGROUND experiments are compiled in. Asserting on
// size_of(Playground_Memory) verifies the memory-shape effect at the Module
// boundary without depending on which fields the playground happens to hold.
@(test)
playground_memory_is_gated :: proc(t: ^testing.T) {
	when PLAYGROUND {
		testing.expect(
			t,
			size_of(Playground_Memory) > 0,
			"PLAYGROUND build should embed playground state in GameMemory",
		)
	} else {
		testing.expect(
			t,
			size_of(Playground_Memory) == 0,
			"non-PLAYGROUND build should keep playground state out of GameMemory",
		)
	}
}
