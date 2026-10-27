#!/usr/bin/env bash
set -eu

# Optimized, symbolized build with spall profiling enabled. The game writes
# build/profile/trace.spall when it exits. Pass `run` to launch it.

OUT_DIR="build/profile"
mkdir -p "$OUT_DIR"
. scripts/config.sh
odin build source/main_release -out:$OUT_DIR/showtime_profile -strict-style -vet -debug -o:speed \
	-define:PROFILING=true -extra-linker-flags:"$SDL3_MIXER_LINKER_FLAGS"
# Assets are huge, so link instead of copying (Windows .bat copies instead).
rm -f "$OUT_DIR/assets" "$OUT_DIR/settings.sjson"
ln -s ../../assets "$OUT_DIR/assets"
ln -s ../../settings.sjson "$OUT_DIR/settings.sjson"
echo "Profile build created in $OUT_DIR"

if [ $# -ge 1 ] && [ "$1" == "run" ]; then
	echo "Running $OUT_DIR/showtime_profile"
	./$OUT_DIR/showtime_profile
fi
