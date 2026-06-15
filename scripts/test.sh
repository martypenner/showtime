#!/usr/bin/env bash
set -eu

# Run Odin package tests. Raylib is linked as a shared lib (same as the hot
# reload build) so packages that import it can be test-compiled. The rpath
# points at the linux libs copied in by build_hot_reload.sh.
ROOT=$(odin root)

case $(uname) in
"Darwin")
	EXTRA_LINKER_FLAGS="-Wl,-rpath $ROOT/vendor/raylib/macos"
	;;
*)
	EXTRA_LINKER_FLAGS="'-Wl,-rpath=\$ORIGIN/linux'"
	if [ ! -d "build/hot_reload/linux" ]; then
		mkdir -p build/hot_reload/linux
		cp -rs "$ROOT"/vendor/raylib/linux/libraylib*.so* build/hot_reload/linux
	fi
	;;
esac

# The game package (source) exports procs that reference Raylib, so its test
# binary links libraylib and needs it at runtime. Emit each test binary into
# build/hot_reload/ so the $ORIGIN/linux rpath above resolves to the libs copied
# in there. (The sound package tree-shakes Raylib away, but this is harmless.)
mkdir -p build/hot_reload
for pkg in source/sound source; do
	name=$(basename "$pkg")
	odin test "$pkg" \
		-out:"build/hot_reload/${name}_test.bin" \
		-define:RAYLIB_SHARED=true \
		-extra-linker-flags:"$EXTRA_LINKER_FLAGS" \
		-strict-style -vet
done
