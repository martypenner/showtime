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

odin test source/sound \
	-define:RAYLIB_SHARED=true \
	-extra-linker-flags:"$EXTRA_LINKER_FLAGS" \
	-strict-style -vet
