#!/usr/bin/env bash
set -eu

# OUT_DIR is for the game DLL and friends. The exe goes in build/ too, but must
# be run from the project root so it finds the assets/ and build/hot_reload/
# folders, which it locates via paths relative to the current directory.
OUT_DIR=build/hot_reload
EXE=build/game_hot_reload.bin

mkdir -p $OUT_DIR

# root is a special command of the odin compiler that tells you where the Odin
# compiler is located.
ROOT=$(odin root)

# Figure out which DLL extension to use based on platform. Also copy the Linux
# so libs.
case $(uname) in
"Darwin")
	DLL_EXT=".dylib"
	EXTRA_LINKER_FLAGS="-Wl,-rpath $ROOT/vendor/raylib/macos"
	;;
*)
	DLL_EXT=".so"
	EXTRA_LINKER_FLAGS="'-Wl,-rpath=\$ORIGIN/linux'"

	# Copy the linux libraries into the project automatically.
	if [ ! -d "$OUT_DIR/linux" ]; then
		mkdir -p $OUT_DIR/linux
		cp -rs $ROOT/vendor/raylib/linux/libraylib*.so* $OUT_DIR/linux
	fi
	;;
esac

# Build the game. Note that the game goes into $OUT_DIR while the exe goes into
# build/.
echo "Building game$DLL_EXT"
odin build source -extra-linker-flags:"$EXTRA_LINKER_FLAGS" -define:RAYLIB_SHARED=true -build-mode:dll -out:$OUT_DIR/game_tmp$DLL_EXT -strict-style -vet -debug

# Need to use a temp file on Linux because it first writes an empty `game.so`,
# which the game will load before it is actually fully written.
mv $OUT_DIR/game_tmp$DLL_EXT $OUT_DIR/game$DLL_EXT

# If the executable is already running, then don't try to build and start it.
# -f is there to make sure we match against full name, including .bin
if pgrep -f $EXE >/dev/null; then
	echo "Hot reloading..."
	exit 0
fi

echo "Building $EXE"
odin build source/main_hot_reload -out:$EXE -strict-style -vet -debug

if [ $# -ge 1 ] && [ $1 == "run" ]; then
	echo "Running $EXE"
	./$EXE &
	echo $! >"$OUT_DIR/game.pid"
fi
