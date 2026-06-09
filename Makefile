.PHONY: build run

PIDFILE=build/hot_reload/game.pid

build:
	./scripts/build_hot_reload.sh

run:
	@./scripts/build_hot_reload.sh run
	@echo "Watching for changes (exit the game window to stop)..."
	@while kill -0 $$(cat $(PIDFILE) 2>/dev/null) 2>/dev/null; do \
		if inotifywait -qr -t 1 -e modify,create,delete,move ./source ./assets >/dev/null 2>&1; then \
			$(MAKE) --no-print-directory build; \
		fi; \
	done
	@echo "Game window closed, stopping watch."
	@rm -f $(PIDFILE)
