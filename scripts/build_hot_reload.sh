#!/usr/bin/env bash
set -eu

# OUT_DIR_HOT_RELOAD is for the game DLL and friends. The exe goes in build/ too, but must
# be run from the project root so it finds the assets/ and build/hot_reload/
# folders, which it locates via paths relative to the current directory.
. scripts/config.sh

# PID-suffixed temp name so overlapping builds don't share game_tmp-*.o link objects.
GAME_TMP=$OUT_DIR_HOT_RELOAD/game_tmp.$$
trap 'rm -rf "$GAME_TMP"*' EXIT

mkdir -p $OUT_DIR_HOT_RELOAD

# Figure out which DLL extension to use based on platform.
case $(uname) in
"Darwin")
	DLL_EXT=".dylib"
	;;
*)
	DLL_EXT=".so"
	;;
esac

# Build the game. Note that the game goes into $OUT_DIR_HOT_RELOAD while the exe goes into
# build/.
echo "Building game$DLL_EXT"
odin build source -build-mode:dll -out:$GAME_TMP$DLL_EXT -strict-style -vet -debug \
	-extra-linker-flags:"$SDL3_MIXER_LINKER_FLAGS"

# Need to use a temp file on Linux because it first writes an empty `game.so`,
# which the game will load before it is actually fully written.
mv $GAME_TMP$DLL_EXT $OUT_DIR_HOT_RELOAD/game$DLL_EXT

# If the executable is already running, then don't try to build and start it.
# -f is there to make sure we match against full name, including .bin
if pgrep -f $EXE >/dev/null; then
	echo "Hot reloading..."
	# Always record the running exe's PID so scripts/watch.sh tracks it even
	# when it attached to an already-running game.
	pgrep -f $EXE | head -1 >"$PIDFILE"
	exit 0
fi

echo "Building $EXE"
odin build source/main_hot_reload -out:$EXE -strict-style -vet -debug \
	-extra-linker-flags:"$SDL3_MIXER_LINKER_FLAGS"

if [ $# -ge 1 ] && [ $1 == "run" ]; then
	echo "Running $EXE"
	./$EXE &
	echo $! >"$OUT_DIR_HOT_RELOAD/game.pid"
fi
