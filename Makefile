.PHONY: all container build build-web generate-enums run run-inner test format clean

PIDFILE=build/hot_reload/game.pid
CONTAINER := odin-build

all: build

build: clean generate-enums
	@distrobox enter $(CONTAINER) -- ./scripts/build_release.sh

build-web: generate-enums
	@distrobox enter $(CONTAINER) -- ./scripts/build_web.sh

generate-enums: container
	@echo "Generating enums and hashes..."
	@distrobox enter $(CONTAINER) -- odin run source/tools/generate_enums >/dev/null
	@$(MAKE) format

run: generate-enums
	@distrobox enter $(CONTAINER) -- $(MAKE) run-inner

run-inner:
	@./scripts/build_hot_reload.sh run
	@echo "Watching for changes (Ctrl-C or exit the game window to stop)..."
	@trap 'kill $$(cat $(PIDFILE) 2>/dev/null) 2>/dev/null; rm -f $(PIDFILE); echo; echo "Stopped game and watch."; exit 0' INT TERM; \
	while kill -0 $$(cat $(PIDFILE) 2>/dev/null) 2>/dev/null; do \
		if inotifywait -qr -t 1 -e modify,create,delete,move ./source ./assets >/dev/null 2>&1; then \
			$(MAKE) generate-enums; \
			./scripts/build_hot_reload.sh; \
		fi; \
	done; \
	echo "Game window closed, stopping watch."; \
	rm -f $(PIDFILE)

test: generate-enums
	@distrobox enter $(CONTAINER) -- ./scripts/test.sh

format:
	@distrobox enter $(CONTAINER) -- odinfmt -w source >/dev/null

clean:
	@rm -rf build

container:
	@podman container exists $(CONTAINER) || distrobox assemble create
