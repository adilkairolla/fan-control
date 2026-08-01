.DEFAULT_GOAL := up

.PHONY: up down build app run test install helper uninstall clean status watch

# ── The one command ──────────────────────────────────────────────────────
# Builds everything, installs the helper if it is missing or stale, installs
# and launches the app, and registers it to come back after a reboot.
# Idempotent: re-run it after any change.
up:
	@./scripts/up.sh

# Stop everything and remove the login item. Fans go back to macOS.
down:
	@./scripts/down.sh

# ── Pieces, if you want them individually ────────────────────────────────

# Fast compile check of every target.
build:
	swift build

# Assemble build/FanControl.app
app:
	./scripts/build-app.sh

# Build and launch from build/ without touching /Applications or login items.
# No sudo — the app monitors via its own unprivileged SMC reads.
run: app
	-pkill -x FanControl || true
	open build/FanControl.app

# Command Line Tools ship no XCTest, so the suite is a plain executable.
test:
	swift run CoreTests

# Copy into /Applications (monitoring only — no helper).
install: app
	-pkill -x FanControl || true
	rm -rf /Applications/FanControl.app
	cp -R build/FanControl.app /Applications/FanControl.app
	open /Applications/FanControl.app

# Just the privileged helper.
helper:
	sudo ./scripts/install.sh

# Full removal, including the helper binaries.
uninstall:
	-./scripts/down.sh
	rm -rf /Applications/FanControl.app
	sudo ./scripts/uninstall.sh

status:
	@fanctl status 2>/dev/null || swift run fanctl status

watch:
	@fanctl watch 2>/dev/null || swift run fanctl watch

clean:
	swift package clean
	rm -rf build .build
