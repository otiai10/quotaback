# make install puts Quotaback.app in ~/Applications (replacing any existing copy)
PREFIX ?= $(HOME)/Applications
APP     = Quotaback.app
BUNDLE  = dist/$(APP)
DEST    = $(PREFIX)/$(APP)

.PHONY: build test bundle install uninstall

build:
	swift build

test:
	swift test

bundle:
	./scripts/bundle.sh

# If running, quit it before replacing, then relaunch afterwards
install: bundle
	@running=; \
	if pgrep -x Quotaback >/dev/null; then \
		running=1; \
		osascript -e 'quit app id "com.otiai10.quotaback"' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Quotaback >/dev/null || break; sleep 0.5; done; \
		pkill -x Quotaback 2>/dev/null || true; \
	fi; \
	mkdir -p "$(PREFIX)"; \
	rm -rf "$(DEST)"; \
	ditto "$(BUNDLE)" "$(DEST)"; \
	echo "installed $(DEST)"; \
	if [ -n "$$running" ]; then open "$(DEST)"; echo "restarted Quotaback"; fi

uninstall:
	@if pgrep -x Quotaback >/dev/null; then osascript -e 'quit app id "com.otiai10.quotaback"' >/dev/null 2>&1 || true; fi
	rm -rf "$(DEST)"
