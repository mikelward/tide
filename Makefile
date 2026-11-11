# tide
#
#   make test             run the tests: test-fast, test-selftest and
#                         test-install
#   make test-fast        all but the integration test's self-tests (CI's test
#                         job)
#   make test-lua         the Lua Hyprland runs, on $(LUA): LUA=lua5.4 for 5.4
#   make test-accents     the accents add-on's core (fcitx5/), with only a C++
#                         compiler
#   make fcitx5           build the accents add-on for fcitx5 into build/fcitx5
#                         (needs cmake, extra-cmake-modules and fcitx5's
#                         headers); `sudo cmake --install build/fcitx5`
#                         installs it (SPEC.md §8.6)
#   make test-install     the installer's tests (install/), a few minutes
#                         each; run them side by side with -j (CI's install
#                         job)
#   make test-selftest    the integration test's self-tests,
#                         shell/integration_test_test.sh, about a minute and a
#                         half on four CPUs (CI's selftest job)
#   make build            build tide-grant, tide-tz, tide-greetd, tide-agent and
#                         tide-tabs
#                         (needs Go)
#                         into build/
#   make install          build, then install the per-user parts: the
#                         Hyprland layout and focus guard, the Quickshell
#                         config (run it with `qs -c tide`),
#                         the session's systemd user units and the portal
#                         config, under ~/.config
#   make install-shell    install only the Quickshell config
#   make install-session  install the session entry, its compositor wrapper,
#                         the tide commands and the greeter (its command, its
#                         Hyprland config, a copy of the shell and a greetd
#                         config template) under $(PREFIX), and the lock's
#                         PAM service in /etc/pam.d (root; see README.md;
#                         run `make build` as yourself first)
#   make dist             a release's files, in build/dist: the source and
#                         the Go commands for amd64 and arm64
#   make connector-zip    package the tide connector, the browser extension
#                         that lists tabs in the switcher, for the Chrome Web
#                         Store, into build/ (connector/README.md)
#   make mocks            re-render the design mocks (docs/mocks/*.html -> *.png)
#   make palette          regenerate shell/lib/palette.mjs from
#                         theme/palette.json (SPEC.md §15)
#   make unicode UNICODE_DATA=...
#                         regenerate shell/lib/unicode.mjs, the floating rules'
#                         \w and \d, from Unicode 16.0.0's UnicodeData.txt
#                         (checked by its SHA-256)
#   make chars EMOJI_TEST=... UNICODE_DATA=...
#                         regenerate the picker's character list,
#                         shell/chars/chars.tsv, from Unicode's
#                         emoji-test.txt and UnicodeData.txt (SPEC.md §8.4)

# Hyprland embeds Lua 5.5; the layout also runs on 5.4, which is what most
# distributions package today.
LUA ?= $(shell command -v lua5.5 || command -v lua5.4 || command -v lua)
HYPR_DIR ?= $(HOME)/.config/hypr/tide
# The login screen's sessions install-session installs: tide (Hyprland's)
# and tide-tidewm. install/tide-setup gives only those whose compositor runs.
SESSIONS ?= tide tide-tidewm
# tidewm's own directory, where tide-tidewm looks for tide.conf and tide's
# shell writes the tide-*.conf it includes: $XDG_CONFIG_HOME's, as both have it.
TIDEWM_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/tidewm
# Where hypridle's config and the Idle page's tide-idle.conf are.
IDLE_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/hypr
# Where waybar's config is: tide's fallback bar's goes beside yours.
WAYBAR_DIR ?= $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/waybar
SYSTEMD_USER_DIR ?= $(HOME)/.config/systemd/user
PORTAL_DIR ?= $(HOME)/.config/xdg-desktop-portal
SHELL_DIR ?= $(HOME)/.config/quickshell/tide
PREFIX ?= /usr/local
# The per-agent drop-ins earlier versions installed, which the allowlist
# replaces, are found by how their first line starts, so ones installed
# under a custom POLKIT_AUTOSTART go too. Left behind, they would keep
# skipping their agent even if it were allowlisted, since systemd runs every
# ExecCondition.
OLD_AUTOSTART_DROPIN_MARK = \# A drop-in for another desktop's autostarted polkit agent
# What the rename from quickspace (2026-10-03) left installed, each found by
# the first line every version of it had, so a file of yours by that name
# stays. hypridle's old drop-in is the one that matters: its ExecCondition
# skips hypridle outside a quickspace session, and systemd runs every
# ExecCondition, so beside tide.conf it skipped hypridle in tide too, and
# nothing answered logind's Lock: no lock at all. The others do nothing in
# tide, and go with it.
OLD_HYPRIDLE_DROPIN_MARK = \# hypridle counts as started only once it owns org.freedesktop.ScreenSaver:
OLD_AUTOSTART_ALLOWLIST_MARK = \# XDG autostart is an allowlist in quickspace
OLD_SHELL_UNIT_MARK = \# The quickspace shell:
OLD_PORTALS_MARK = \# Portal backends for XDG_CURRENT_DESKTOP=quickspace:Hyprland.
GO ?= go
# The shell's pure logic (shell/lib) is tested with node --test (SPEC.md §20).
NODE ?= node
# Qt's own parser checks the shell's modules (shell/lib), whose syntax Node
# accepts but Quickshell's QML engine may not. Debian and Ubuntu ship it in
# qt6-declarative-dev-tools, outside PATH. The Qt 6 names come first: a bare
# qmllint can be Qt 5's qtchooser wrapper, whose parser rejects what Qt 6 runs.
QMLLINT ?= $(shell command -v qmllint6 || command -v qmllint-qt6 || command -v /usr/lib/qt6/bin/qmllint || command -v /usr/lib64/qt6/bin/qmllint || command -v qmllint)
# Build with the Go that's installed, never one downloaded to match go.mod.
export GOTOOLCHAIN := local

.PHONY: test test-fast test-lua test-selftest test-install test-accents fcitx5 build install install-shell install-session mocks palette chars unicode connector-zip unshallow-check release-tag dist
test: test-fast test-selftest test-install

# install/tide-setup's tests, one target each, so -j runs them side by side.
INSTALL_TESTS = \
	install/tide-setup_test \
	install/tide-setup_hyprland_test \
	install/tide-setup_tidewm_test \
	install/tide-setup_fcitx5_test \
	install/tide-setup_greeter_test \
	install/tide-setup_greeter_pam_test \
	install/tide-setup_greeter_pam_modules_test \
	install/tide-setup_greetd_unit_test \
	install/tide-setup_greetd_test \
	install/tide-setup_pam_test
# Phony here, below the list: a .PHONY above it would see it empty.
.PHONY: $(INSTALL_TESTS)
test-install: $(INSTALL_TESTS)
$(INSTALL_TESTS):
	./$@

# The integration test's self-tests run the whole integration test against
# stand-ins for each of their cases, which takes minutes, so CI runs them as
# a job of their own beside test-fast's.
test-selftest:
	sh shell/integration_test_test.sh

# The Lua that Hyprland runs, on $(LUA): CI runs it on 5.5, Hyprland's,
# and again on 5.4, which most distributions package.
test-lua:
	@test -n "$(LUA)" || { echo "make test: no lua5.5, lua5.4 or lua on PATH" >&2; exit 1; }
	$(LUA) hypr/tide/layout_test.lua
	$(LUA) hypr/tide/direction_test.lua
	$(LUA) hypr/tide/span_test.lua
	$(LUA) hypr/tide/focus_test.lua
	$(LUA) hypr/tide/pinned_test.lua
	$(LUA) greeter/hyprland_test.lua
	$(LUA) hypr/hyprland_test.lua

test-fast: test-lua
	sh hypr/tide/input_test.sh
	sh hypr/hypridle_test.sh
	sh tidewm/config_test.sh
	sh session/session_test.sh
	sh bin/tide_test.sh
	sh bin/tide-clipboard_test.sh
	sh bin/tide-fill_test.sh
	sh bin/tide-lock_test.sh
	sh bin/tide-waybar_test.sh
	sh bin/tide-shell_test.sh
	sh bin/tide-doctor_test.sh
	sh bin/tide-sysmon_test.sh
	sh bin/tide-greeter_test.sh
	sh bin/tide-share-picker_test.sh
	sh shell/install_test.sh
	sh shell/integration_test.sh
	sh .github/workflows/ci_test.sh
	sh .github/workflows/release_test.sh
	sh install/pins_test.sh
	$(MAKE) test-accents
	@test -n "$(QMLLINT)" || { echo "make test: no qmllint; install qt6-declarative-dev-tools" >&2; exit 1; }
	$(QMLLINT) $(filter-out %_test.mjs,$(wildcard shell/lib/*.mjs))
	$(NODE) --import ./shell/lib/qtjs_env_test.mjs --test shell/lib/clocks_test.mjs shell/lib/workspaces_test.mjs shell/lib/span_test.mjs shell/lib/minimized_test.mjs shell/lib/mute_test.mjs shell/lib/workspacenames_test.mjs shell/lib/switcher_test.mjs shell/lib/tabs_test.mjs shell/lib/tzdata_test.mjs shell/lib/layouts_test.mjs shell/lib/appearance_test.mjs shell/lib/status_test.mjs shell/lib/dst_test.mjs shell/lib/popover_test.mjs shell/lib/session_test.mjs shell/lib/audio_test.mjs shell/lib/bluetooth_test.mjs shell/lib/launch_test.mjs shell/lib/dispatch_test.mjs shell/lib/osd_test.mjs shell/lib/network_test.mjs shell/lib/notifications_test.mjs shell/lib/tray_test.mjs shell/lib/settings_test.mjs shell/lib/settingssearch_test.mjs shell/lib/steps_test.mjs shell/lib/idle_test.mjs shell/lib/writes_test.mjs shell/lib/input_test.mjs shell/lib/keys_test.mjs shell/lib/keymaps_test.mjs shell/lib/outputs_test.mjs shell/lib/title_test.mjs shell/lib/history_test.mjs shell/lib/share_test.mjs shell/lib/sysmon_test.mjs shell/lib/keepawake_test.mjs shell/lib/wallclock_test.mjs shell/lib/presenter_test.mjs shell/lib/icons_test.mjs shell/lib/report_test.mjs shell/lib/vpn_test.mjs shell/lib/mic_test.mjs shell/lib/fuzzy_test.mjs shell/lib/frecency_test.mjs shell/lib/launcher_test.mjs shell/lib/lock_test.mjs shell/lib/greeter_test.mjs shell/lib/greetd_test.mjs shell/lib/unplug_test.mjs shell/lib/polkit_test.mjs shell/lib/agent_test.mjs shell/lib/sharepicker_test.mjs shell/lib/picker_test.mjs shell/lib/startup_test.mjs shell/lib/barclick_test.mjs shell/lib/barhit_test.mjs shell/lib/barsettings_test.mjs shell/lib/dnd_test.mjs shell/lib/clipboard_test.mjs shell/lib/power_test.mjs shell/lib/workspacepage_test.mjs shell/lib/floating_test.mjs shell/lib/unicode_test.mjs shell/lib/popups_test.mjs shell/lib/persist_test.mjs shell/lib/compositor_test.mjs shell/lib/tidewm_test.mjs shell/lib/kwin_test.mjs shell/lib/workspacekeys_test.mjs shell/lib/overview_test.mjs
# theme/ is build-time Node, not loaded by the shell, so runs unguarded.
	$(NODE) --test theme/palette_test.mjs
	$(NODE) --test connector/bridge_test.js
	$(NODE) --test shell/chars/generate_test.mjs
	$(NODE) theme/generate.mjs --check
	$(GO) vet ./...
	$(GO) test ./...

test-accents: build/accents_core_test
	build/accents_core_test fcitx5/accents.json

build/accents_core_test: fcitx5/accents_core.cpp fcitx5/accents_core.h fcitx5/accents_core_test.cpp
	@mkdir -p build
	$(CXX) -std=c++17 -Wall -Wextra -Werror -o $@ fcitx5/accents_core.cpp fcitx5/accents_core_test.cpp

fcitx5:
	cmake -S fcitx5 -B build/fcitx5 -DCMAKE_BUILD_TYPE=Release
	cmake --build build/fcitx5

palette:
	$(NODE) theme/generate.mjs

# Written whole, then renamed, so a failed run leaves the classes as they were.
unicode:
	@test -n "$(UNICODE_DATA)" || { echo "make unicode: set UNICODE_DATA to Unicode 16.0.0's UnicodeData.txt" >&2; exit 2; }
	$(NODE) shell/unicode/generate.mjs "$(UNICODE_DATA)" > shell/lib/unicode.mjs.tmp || { rm -f shell/lib/unicode.mjs.tmp; exit 1; }
	mv shell/lib/unicode.mjs.tmp shell/lib/unicode.mjs

# Written whole, then renamed, so a failed run leaves the list as it was.
chars:
	@test -n "$(EMOJI_TEST)" && test -n "$(UNICODE_DATA)" || { echo "make chars: set EMOJI_TEST and UNICODE_DATA to Unicode's emoji-test.txt and UnicodeData.txt" >&2; exit 2; }
	$(NODE) shell/chars/generate.mjs "$(EMOJI_TEST)" "$(UNICODE_DATA)" > shell/chars/chars.tsv.tmp || { rm -f shell/chars/chars.tsv.tmp; exit 1; }
	mv shell/chars/chars.tsv.tmp shell/chars/chars.tsv

build: build/tide-grant build/tide-msg build/tide-tz build/tide-greetd build/tide-agent build/tide-tabs build/tide-pick build/tide-kwin-paste

# The sway IPC client tide-grant and tide-msg share, for tidewm.
SWAYIPC = $(wildcard internal/swayipc/*.go)

build/tide-grant: go.mod go.sum $(wildcard cmd/tide-grant/*.go) $(SWAYIPC)
	$(GO) build -o $@ ./cmd/tide-grant

build/tide-msg: go.mod $(wildcard cmd/tide-msg/*.go) $(SWAYIPC)
	$(GO) build -o $@ ./cmd/tide-msg

build/tide-tz: go.mod $(wildcard cmd/tide-tz/*.go)
	$(GO) build -o $@ ./cmd/tide-tz

build/tide-greetd: go.mod $(wildcard cmd/tide-greetd/*.go)
	$(GO) build -o $@ ./cmd/tide-greetd

build/tide-agent: go.mod go.sum $(wildcard cmd/tide-agent/*.go)
	$(GO) build -o $@ ./cmd/tide-agent

build/tide-tabs: go.mod $(wildcard cmd/tide-tabs/*.go)
	$(GO) build -o $@ ./cmd/tide-tabs

build/tide-pick: go.mod go.sum $(wildcard cmd/tide-pick/*.go)
	$(GO) build -o $@ ./cmd/tide-pick

build/tide-kwin-paste: go.mod $(wildcard cmd/tide-kwin-paste/*.go)
	$(GO) build -o $@ ./cmd/tide-kwin-paste

# Copies only. Enabling tide.service, which hangs it off the tide
# session's target, is the installer's job (install/tide-setup).
install: build install-shell
	install -d "$(HYPR_DIR)"
	install -m 644 hypr/tide/geometry.lua hypr/tide/direction.lua hypr/tide/span.lua hypr/tide/layout.lua hypr/tide/focus.lua hypr/tide/pinned.lua hypr/hyprland.lua hypr/hyprland.local.lua.template "$(HYPR_DIR)/"
	@# tide's hypridle config, for a hypridle with none of yours, beside
	@# the tide-idle.conf it sources, which hypridle finds beside it.
	install -d "$(IDLE_DIR)"
	install -m 644 hypr/hypridle.conf "$(IDLE_DIR)/tide-hypridle.conf"
	@# And its hyprlock config, for the lock's fallback with none of yours.
	install -m 644 hypr/hyprlock.conf "$(IDLE_DIR)/tide-hyprlock.conf"
	@# The fallback bar's config (SPEC.md §5.2), beside any of yours, which
	@# tide-waybar leaves waybar to read.
	install -d "$(WAYBAR_DIR)"
	install -m 644 waybar/tide-hyprland.jsonc waybar/tide-tidewm.jsonc waybar/tide.css "$(WAYBAR_DIR)/"
	install -m 755 hypr/tide/apply-input.sh hypr/tide/watch-input.sh hypr/tide/next-layout.sh "$(HYPR_DIR)/"
	install -d "$(TIDEWM_DIR)"
	install -m 644 tidewm/tide.conf "$(TIDEWM_DIR)/"
	install -d "$(SYSTEMD_USER_DIR)/hypridle.service.d" "$(SYSTEMD_USER_DIR)/hyprpolkitagent.service.d" "$(SYSTEMD_USER_DIR)/app-.service.d"
	install -m 644 systemd/user/tide.service systemd/user/tide-lock.service systemd/user/tide-lock-fallback.service systemd/user/tide-idle-fallback.service systemd/user/tide-shell-fallback.service systemd/user/tide-clipboard.service systemd/user/tide-fcitx5.service systemd/user/tide-lid-inhibit.service systemd/user/tide-kde.service "$(SYSTEMD_USER_DIR)/"
	install -m 644 systemd/user/hypridle.service.d/tide.conf "$(SYSTEMD_USER_DIR)/hypridle.service.d/"
	install -m 644 systemd/user/hyprpolkitagent.service.d/tide.conf "$(SYSTEMD_USER_DIR)/hyprpolkitagent.service.d/"
	install -m 644 systemd/user/app-.service.d/tide-autostart.conf "$(SYSTEMD_USER_DIR)/app-.service.d/"
	@# rmdir only removes a directory this emptied.
	for f in "$(SYSTEMD_USER_DIR)"/app-*@autostart.service.d/quickspace.conf; do \
		test -f "$$f" || continue; \
		case "$$(head -n 1 "$$f")" in "$(OLD_AUTOSTART_DROPIN_MARK)"*) ;; *) continue ;; esac; \
		rm -f "$$f" || exit 1; \
		d=$${f%/*}; \
		if test -z "$$(ls -A "$$d")"; then rmdir "$$d" || exit 1; fi; \
	done
	@# The quickspace leftovers (OLD_HYPRIDLE_DROPIN_MARK above), and the
	@# old shell unit's enablement, once its unit is gone.
	@remove_ours() { \
		test -f "$$1" || return 0; \
		case "$$(head -n 1 "$$1")" in "$$2"*) ;; *) return 0 ;; esac; \
		rm -f "$$1" || return 1; \
		echo "make install: removed $$1, left from quickspace"; \
	}; \
	remove_ours "$(SYSTEMD_USER_DIR)/hypridle.service.d/quickspace.conf" "$(OLD_HYPRIDLE_DROPIN_MARK)" \
	&& remove_ours "$(SYSTEMD_USER_DIR)/app-.service.d/quickspace-autostart.conf" "$(OLD_AUTOSTART_ALLOWLIST_MARK)" \
	&& remove_ours "$(SYSTEMD_USER_DIR)/quickspace.service" "$(OLD_SHELL_UNIT_MARK)" \
	&& remove_ours "$(PORTAL_DIR)/quickspace-portals.conf" "$(OLD_PORTALS_MARK)" \
	|| exit 1; \
	wants="$(SYSTEMD_USER_DIR)/wayland-session@quickspace-hyprland.target.wants"; \
	if test -L "$$wants/quickspace.service" && ! test -e "$$wants/quickspace.service"; then \
		rm -f "$$wants/quickspace.service" || exit 1; \
		if test -z "$$(ls -A "$$wants")"; then rmdir "$$wants" || exit 1; fi; \
	fi
	install -d "$(PORTAL_DIR)"
	install -m 644 xdg-desktop-portal/tide-portals.conf xdg-desktop-portal/tidewm-portals.conf "$(PORTAL_DIR)/"

# The Quickshell config alone, which shell/integration_test.sh loads. Each
# file goes in by rename, so the running shell's reload never finds one
# missing (shell/install.sh).
SHELL_FILES = $(patsubst shell/%,%,$(wildcard shell/*.qml) $(wildcard shell/icons/*.svg) \
	$(filter-out %_test.mjs,$(wildcard shell/lib/*.mjs)) shell/chars/chars.tsv shell/chars/LICENSE-UNICODE)
install-shell:
	install -d "$(SHELL_DIR)/lib" "$(SHELL_DIR)/icons" "$(SHELL_DIR)/chars"
	sh shell/install.sh shell "$(SHELL_DIR)" $(SHELL_FILES)

# Display managers list sessions from wayland-sessions under the system data
# dirs. Not every one searches /usr/local/share; if the session doesn't show
# up at the greeter, install with PREFIX=/usr.
# Root has no Go module cache to build with, so install-session only copies
# the Go commands that `make build` (or `make install`) left in build/.
install-session:
	@for cmd in tide-grant tide-msg tide-tz tide-greetd tide-agent tide-tabs tide-pick tide-kwin-paste; do \
		test -x build/$$cmd || { echo "make install-session: no build/$$cmd; run make build first, as yourself" >&2; exit 1; }; \
	done
	install -d "$(DESTDIR)$(PREFIX)/bin" "$(DESTDIR)$(PREFIX)/share/wayland-sessions"
	install -m 755 bin/tide bin/tide-session bin/tide-clipboard bin/tide-fill bin/tide-doctor bin/tide-greeter bin/tide-hyprland bin/tide-tidewm bin/tide-lock bin/tide-share-picker bin/tide-shell bin/tide-shell-fallback bin/tide-waybar bin/tide-sysmon build/tide-grant build/tide-msg build/tide-tz build/tide-greetd build/tide-agent build/tide-tabs build/tide-pick build/tide-kwin-paste "$(DESTDIR)$(PREFIX)/bin/"
	$(if $(strip $(SESSIONS)),install -m 644 $(SESSIONS:%=session/%.desktop) "$(DESTDIR)$(PREFIX)/share/wayland-sessions/")
	@# KWin lets a program use its fake-input (KDE's Win+V paste) only if
	@# a desktop entry whose Exec is that program's path lists it in
	@# X-KDE-Wayland-Interfaces (cmd/tide-kwin-paste).
	install -d "$(DESTDIR)$(PREFIX)/share/applications"
	sed 's|@BINDIR@|$(PREFIX)/bin|' session/tide-kwin-paste.desktop.in >"$(DESTDIR)$(PREFIX)/share/applications/tide-kwin-paste.desktop"
	chmod 644 "$(DESTDIR)$(PREFIX)/share/applications/tide-kwin-paste.desktop"
	@# The greeter runs as greetd's own user, which can't read anyone's
	@# ~/.config, so it gets a copy of the shell of its own. tide-greeter
	@# finds both under the PREFIX it's installed in.
	$(MAKE) install-shell SHELL_DIR="$(DESTDIR)$(PREFIX)/share/tide/shell"
	install -d "$(DESTDIR)$(PREFIX)/share/tide/greeter"
	install -m 644 greeter/hyprland.lua greeter/greetd.toml "$(DESTDIR)$(PREFIX)/share/tide/greeter/"
	@# PAM reads /etc/pam.d, whatever PREFIX is.
	install -d "$(DESTDIR)/etc/pam.d"
	install -m 644 pam/tide-lock "$(DESTDIR)/etc/pam.d/tide-lock"

# The tide connector's Chrome Web Store upload: manifest.json at the top, and
# nothing only development needs. Its version is the number of commits, so
# each commit on main is a higher version than the last, as the store
# requires; a shallow clone would count too few.
CONNECTOR_FILES = manifest.json background.js bridge.js popup.html popup.css popup.js \
	icons/tide-16.png icons/tide-32.png icons/tide-48.png icons/tide-128.png
# SHALLOW_OK=yes skips it, for a test in a shallow clone.
unshallow-check:
	@test "$(SHALLOW_OK)" = yes || if test "$$(git rev-parse --is-shallow-repository)" != false; then \
		echo "the history is shallow, so the commit count is wrong; run git fetch --unshallow" >&2; exit 1; fi
connector-zip: unshallow-check
	rm -rf build/connector && install -d build/connector/icons
	cd connector && cp $(filter-out icons/%,$(CONNECTOR_FILES)) ../build/connector/ && cp $(filter icons/%,$(CONNECTOR_FILES)) ../build/connector/icons/
	$(NODE) -e 'const fs = require("fs"); const f = process.argv[1]; const m = JSON.parse(fs.readFileSync(f)); m.version = process.argv[2]; fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");' build/connector/manifest.json "$$(git rev-list --count HEAD)"
	rm -f build/tide-connector.zip
	cd build/connector && zip -qrX ../tide-connector.zip .
	rm -rf build/connector
	@echo build/tide-connector.zip

# Needs Node and Playwright with Chromium. A global Playwright install is
# found through NODE_PATH; a project-local one works without it.
mocks:
	NODE_PATH="$$(npm root -g)" node docs/mocks/render.js

# Releases (.github/workflows/release.yml): every push to main is one,
# tagged v0.MINOR.<commits on main>, as tidewm's and tideco's are. Bump
# MINOR for a change that breaks an installed setup.
RELEASE_MINOR = 0
# GNU's sha256sum, or macOS's shasum, which writes and checks the same lines.
SHA256SUM ?= $(shell command -v sha256sum 2>/dev/null || echo shasum -a 256)
GO_COMMANDS = tide-grant tide-msg tide-tz tide-greetd tide-agent tide-tabs tide-pick tide-kwin-paste
release-tag: unshallow-check
	@echo v0.$(RELEASE_MINOR).`git rev-list --count HEAD`

# A release's files, in build/dist: the source, which the installer runs
# from (install/tide-setup), and the Go commands, built for Linux on amd64
# and arm64 with no C, with their SHA-256 sums.
dist: unshallow-check
	rm -rf build/dist
	mkdir -p build/dist
	tag=$$($(MAKE) -s release-tag) || exit 1; \
	git archive --format=tar.gz --prefix=tide-$$tag/ -o build/dist/tide-$$tag.tar.gz HEAD || exit 1; \
	for arch in amd64 arm64; do \
		dir=tide-$$tag-linux-$$arch; \
		mkdir -p build/dist/$$dir || exit 1; \
		for cmd in $(GO_COMMANDS); do \
			CGO_ENABLED=0 GOOS=linux GOARCH=$$arch $(GO) build -trimpath -o build/dist/$$dir/$$cmd ./cmd/$$cmd || exit 1; \
		done; \
		tar -C build/dist -czf build/dist/$$dir.tar.gz $$dir || exit 1; \
		rm -r build/dist/$$dir; \
	done; \
	cd build/dist && $(SHA256SUM) -- *.tar.gz > SHA256SUMS
