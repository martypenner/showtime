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
# binary links libraylib and needs it at runtime. Emit the test binary into
# build/hot_reload/ so the $ORIGIN/linux rpath above resolves to the libs copied
# in there.
mkdir -p build/hot_reload
odin test source \
	-all-packages \
	-out:build/hot_reload/source_test.bin \
	-define:ODIN_TEST_THREADS=1 \
	-define:RAYLIB_SHARED=true \
	-extra-linker-flags:"$EXTRA_LINKER_FLAGS" \
	-strict-style -vet
