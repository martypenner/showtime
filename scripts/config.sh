#!/usr/bin/env bash

# Shared build configuration. Source from scripts, or call with `linker-flags`
# to print the SDL3_mixer linker flags (used by the Makefile).

OUT_DIR_HOT_RELOAD=build/hot_reload
PIDFILE=build/hot_reload/game.pid
EXE=build/game_hot_reload.bin

if [[ "$(uname -s)" == Darwin ]]; then
	HOMEBREW_PREFIX="$(brew --prefix)"
	SDL3_MIXER_PREFIX="$(brew --prefix sdl3_mixer)"
	SDL3_MIXER_LINKER_FLAGS="-L$SDL3_MIXER_PREFIX/lib -L$HOMEBREW_PREFIX/lib -Wl,-rpath,$SDL3_MIXER_PREFIX/lib -Wl,-rpath,$HOMEBREW_PREFIX/lib"
else
	SDL3_MIXER_LINKER_FLAGS="$(pkg-config --libs sdl3 sdl3-mixer)"
fi

case "${1:-}" in
linker-flags)
	echo "$SDL3_MIXER_LINKER_FLAGS"
	;;
pidfile)
	echo "$PIDFILE"
	;;
esac
