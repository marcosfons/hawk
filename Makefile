# hawk - a menu bar toolkit for Apple Silicon Macs: monitor, fans, energy, storage
#
#   make                        build everything (release) and assemble Hawk.app
#   make install                Hawk.app -> ~/Applications, hawk CLI -> ~/.local/bin
#   make run                    build and open Hawk.app
#   sudo make install-helper    install the root helper (fan control, system process figures)
#   sudo make uninstall-helper  remove it (fans go back to macOS)
#   make test                   unit tests
#   make check                  warnings as errors + unit tests (before every commit)
#   make log                    last hour of Hawk and helper log entries (timings at debug level)
#   make log-live               stream everything as it happens, debug timings included
#   make problems               warnings and errors kept in ~/Library/Logs/Hawk/hawk.log
#   make icon                   redraw the app icon (Support/AppIcon.iconset)
#   make perf SCENARIO=name     build, then measure CPU, memory, energy, threads (tools/perf.sh list)
#
# Build as yourself first; install-helper only copies the already built binary,
# so nothing under .build is ever owned by root.

PREFIX   ?= $(HOME)/.local
APPDIR   ?= $(HOME)/Applications
BIN       = .build/release
APP       = build/Hawk.app

HELPER_LABEL = com.marcos.hawkd
HELPER_BIN   = /Library/PrivilegedHelperTools/$(HELPER_LABEL)
HELPER_PLIST = /Library/LaunchDaemons/$(HELPER_LABEL).plist

.PHONY: all build app install run install-helper uninstall-helper test check perf log log-live problems icon clean

all: app

build:
	swift build -c release --quiet

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)/HawkApp" "$(APP)/Contents/MacOS/Hawk"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	iconutil -c icns Support/AppIcon.iconset -o "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - -r='designated => identifier "com.marcos.Hawk"' "$(APP)"

install: app
	mkdir -p "$(APPDIR)" "$(PREFIX)/bin"
	rm -rf "$(APPDIR)/Hawk.app"
	cp -R "$(APP)" "$(APPDIR)/Hawk.app"
	cp "$(BIN)/hawk" "$(PREFIX)/bin/hawk"
	@echo "Installed $(APPDIR)/Hawk.app and $(PREFIX)/bin/hawk"

run: app
	open "$(APP)"

install-helper:
	@test "$$(id -u)" = 0 || { echo "error: run with sudo: sudo make install-helper" >&2; exit 1; }
	@test -x "$(BIN)/hawkd" || { echo "error: build first, as yourself: make" >&2; exit 1; }
	-launchctl bootout system/$(HELPER_LABEL) 2>/dev/null
	install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
	install -o root -g wheel -m 755 "$(BIN)/hawkd" "$(HELPER_BIN)"
	install -o root -g wheel -m 644 Support/$(HELPER_LABEL).plist "$(HELPER_PLIST)"
	launchctl bootstrap system "$(HELPER_PLIST)"
	@echo "Helper installed and running ($(HELPER_LABEL))"

uninstall-helper:
	@test "$$(id -u)" = 0 || { echo "error: run with sudo: sudo make uninstall-helper" >&2; exit 1; }
	-launchctl bootout system/$(HELPER_LABEL) 2>/dev/null
	rm -f "$(HELPER_BIN)" "$(HELPER_PLIST)" /var/run/$(HELPER_LABEL).sock
	@echo "Helper removed; fans are under macOS control"

test:
	swift test --quiet

check:
	swift build -c release -Xswiftc -warnings-as-errors --quiet
	swift test --quiet

perf: app
	@test -n "$(SCENARIO)" || { echo "usage: make perf SCENARIO=<name>"; tools/perf.sh list; exit 2; }
	tools/perf.sh $(SCENARIO)

log:
	@/usr/bin/log show --last 1h --style compact --info --debug \
		--predicate 'subsystem == "com.marcos.Hawk" OR subsystem == "$(HELPER_LABEL)"'

log-live:
	@/usr/bin/log stream --style compact --level debug \
		--predicate 'subsystem == "com.marcos.Hawk" OR subsystem == "$(HELPER_LABEL)"'

icon:
	swift tools/make-icon.swift Support/AppIcon.iconset

problems:
	@tail -n 60 ~/Library/Logs/Hawk/hawk.log 2>/dev/null || echo "No problems logged."

clean:
	rm -rf .build build
