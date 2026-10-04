#!/usr/bin/env bash
set -eu

# Hot-reload watcher. Monitors source/ continuously and rebuilds the game DLL
# on changes. Assets and settings.sjson are read from disk at runtime, so they
# don't trigger rebuilds. Uses inotifywait on Linux, fswatch on macOS.

. scripts/config.sh

stop_game() {
	pid="$(cat "$PIDFILE" 2>/dev/null)" || pid=
	[ -n "$pid" ] || return
	kill "$pid" 2>/dev/null || true
	# Graceful exit is via SIGTERM (SDL turns it into a quit event). If the
	# game is stuck and ignores it, force-kill after a short grace period.
	for _ in $(seq 1 20); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null || true
	fi
	rm -f "$PIDFILE"
}

shutdown() {
	echo "Stopped game and watch."
	stop_game
	kill "${WATCH_PID:-}" 2>/dev/null || true
	exit 0
}

trap shutdown INT TERM

./scripts/build_hot_reload.sh run

if command -v inotifywait >/dev/null 2>&1; then
	echo "Watching source/ for changes (inotify)..."
	inotifywait -mqr -e modify,create,delete,move ./source |
		while IFS= read -r event; do
			while IFS= read -rt 0.2 next_event; do :; done
			if ! ./scripts/build_hot_reload.sh; then
				echo "Build failed, waiting for changes..."
			fi
		done &
elif command -v fswatch >/dev/null 2>&1; then
	echo "Watching source/ for changes (fswatch)..."
	fswatch -0r --latency 0.2 ./source |
		while IFS= read -r -d '' path; do
			while IFS= read -r -d '' -t 1 next_event; do :; done
			if ! ./scripts/build_hot_reload.sh; then
				echo "Build failed, waiting for changes..."
			fi
		done &
else
	echo "Error: need inotifywait (inotify-tools) or fswatch to watch for changes." >&2
	stop_game
	exit 1
fi
WATCH_PID=$!

while kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; do
	sleep 1
done

echo "Game window closed, stopping watch."
kill "$WATCH_PID" 2>/dev/null || true
stop_game
