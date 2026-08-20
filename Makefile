PREFIX ?= $(HOME)/Applications
APP = GrokUsage.app
BIN = $(APP)/Contents/MacOS/GrokUsage
SOURCES = Sources/AuthStore.swift Sources/BillingClient.swift Sources/GrokUsage.swift
LAUNCH_AGENT = $(HOME)/Library/LaunchAgents/com.local.grokusage.plist
GUI_DOMAIN = gui/$(shell id -u)

.PHONY: build run check install uninstall

build: $(BIN)

$(BIN): $(SOURCES) Info.plist Resources/GrokMark.svg
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp Resources/GrokMark.svg $(APP)/Contents/Resources/GrokMark.svg
	echo "APPL????" > $(APP)/Contents/PkgInfo
	swiftc -O -parse-as-library \
		-strict-concurrency=minimal \
		-framework AppKit -framework Foundation \
		-o $(BIN) \
		$(SOURCES)
	codesign --force --sign - --timestamp=none $(APP)

run: build
	killall GrokUsage 2>/dev/null || true
	open $(APP)

check: build
	$(BIN) --once

install: build
	mkdir -p "$(PREFIX)"
	rm -rf "$(PREFIX)/$(APP)"
	cp -R "$(APP)" "$(PREFIX)/$(APP)"
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed 's|@APP_BIN@|$(PREFIX)/$(APP)/Contents/MacOS/GrokUsage|g' LaunchAgent.plist > "$(LAUNCH_AGENT)"
	launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT)" 2>/dev/null || true
	killall GrokUsage 2>/dev/null || true
	launchctl bootstrap $(GUI_DOMAIN) "$(LAUNCH_AGENT)"

uninstall:
	launchctl bootout $(GUI_DOMAIN) "$(LAUNCH_AGENT)" 2>/dev/null || true
	rm -f "$(LAUNCH_AGENT)"
	killall GrokUsage 2>/dev/null || true
	rm -rf "$(PREFIX)/$(APP)"
