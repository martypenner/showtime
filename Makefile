.PHONY: all build build-web run test

PIDFILE=build/hot_reload/game.pid

all: build

build: clean
	./scripts/build_release.sh

build-web:
	./scripts/build_web.sh

run:
	@./scripts/build_hot_reload.sh run
	@echo "Watching for changes (Ctrl-C or exit the game window to stop)..."
	@trap 'kill $$(cat $(PIDFILE) 2>/dev/null) 2>/dev/null; rm -f $(PIDFILE); echo; echo "Stopped game and watch."; exit 0' INT TERM; \
	while kill -0 $$(cat $(PIDFILE) 2>/dev/null) 2>/dev/null; do \
		if inotifywait -qr -t 1 -e modify,create,delete,move ./source ./assets >/dev/null 2>&1; then \
			./scripts/build_hot_reload.sh; \
		fi; \
	done; \
	echo "Game window closed, stopping watch."; \
	rm -f $(PIDFILE)

test:
	./scripts/test.sh

clean:
	@rm -rf build
