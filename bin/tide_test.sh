#!/bin/sh
#
# Tests for bin/tide, against fake systemctl, hyprctl and uwsm on PATH.

cd "$(dirname "$0")/.." || exit 1
qs=$PWD/bin/tide

passes=0
failures=0
pass() { passes=$((passes + 1)); }
fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}
check() {
    _name=$1
    shift
    if "$@"; then pass; else fail "$_name"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/bin
mkdir "$fake"
log=$tmp/log

# Each fake logs its arguments. systemctl sleeps $FAKE_SYSTEMCTL_SLEEP and
# exits $FAKE_SYSTEMCTL_STATUS; hyprctl answers $FAKE_HYPRCTL_REPLY (ok by
# default); uwsm runs the command after --, as `uwsm app` does.
cat > "$fake/systemctl" <<'FAKE'
#!/bin/sh
printf "systemctl %s\n" "$*" >> "$FAKE_LOG"
sleep "${FAKE_SYSTEMCTL_SLEEP:-0}"
test "${FAKE_SYSTEMCTL_STATUS:-0}" -eq 0 || echo "Job failed" >&2
exit "${FAKE_SYSTEMCTL_STATUS:-0}"
FAKE
cat > "$fake/hyprctl" <<'FAKE'
#!/bin/sh
printf "hyprctl %s\n" "$*" >> "$FAKE_LOG"
echo "${FAKE_HYPRCTL_REPLY:-ok}"
FAKE
cat > "$fake/uwsm" <<'FAKE'
#!/bin/sh
printf "uwsm %s\n" "$*" >> "$FAKE_LOG"
while test "$1" != --; do shift; done
shift
exec "$@"
FAKE
cat > "$fake/app" <<'FAKE'
#!/bin/sh
printf "app %s\n" "$*" >> "$FAKE_LOG"
FAKE
chmod +x "$fake"/*
# tide-grant answers --program with $FAKE_PROGRAM, else the command's first
# word, exiting $FAKE_PROGRAM_STATUS; and --classes with $FAKE_CLASSES
# (words), exiting $FAKE_CLASSES_STATUS. It logs --classes calls only, so the
# log shows the lookup where it happens.
cat > "$fake/tide-grant" <<'FAKE'
#!/bin/sh
if test "$1" = --program; then
    shift 2
    printf '%s\n' "${FAKE_PROGRAM-$1}"
    exit "${FAKE_PROGRAM_STATUS:-0}"
fi
printf "tide-grant %s\n" "$*" >> "$FAKE_LOG"
test -z "${FAKE_CLASSES:-}" || printf '%s\n' $FAKE_CLASSES
exit "${FAKE_CLASSES_STATUS:-0}"
FAKE
chmod +x "$fake/tide-grant"

# run ENV... -- ARGS...: runs tide with the fakes first on PATH, in a
# tide session unless the env says otherwise.
run() {
    : > "$log"
    env PATH="$fake:$PATH" FAKE_LOG="$log" XDG_CURRENT_DESKTOP=tide:Hyprland \
        XDG_DATA_HOME="$tmp/home-data" XDG_DATA_DIRS="$tmp/sys-data" \
        "$@" 2> "$tmp/err"
}

run "$qs" launch app one two
check "launch exits 0" test $? -eq 0
out=$(cat "$log")
check "launch waits for the shell" contains "$out" "systemctl --user start tide.service"
check "launch grants focus to the command's basename" \
    contains "$out" 'hyprctl eval tide_focus.grant("app", nil, '
check "launch runs the app through uwsm app" contains "$out" "uwsm app -- app one two"
check "the app gets its arguments" contains "$out" "app one two"
check "the grant, then its desktop-entry lookup, then the wait, then the app" \
    test "$(sed -n 's/ .*//p' "$log" | tr '\n' ' ')" = "hyprctl tide-grant systemctl uwsm app "
check "a clean launch says nothing" test ! -s "$tmp/err"

run "$qs" launch --app org.gnome.Nautilus -- "$fake/app" .
check "--app names the grant" \
    contains "$(cat "$log")" 'tide_focus.grant("org.gnome.Nautilus")'
run "$qs" launch --app=kitty app
check "--app=ID works too" contains "$(cat "$log")" 'tide_focus.grant("kitty")'
run "$qs" launch --app org.example.Editor --app=example-editor -- "$fake/app"
check "repeated --app grants a list any of them can use" \
    contains "$(cat "$log")" 'tide_focus.grant({ "org.example.Editor", "example-editor" })'
run "$qs" launch --app '*' --app firefox -- app
check "--app '*' beside another ID is refused" test $? -eq 2
check "--app '*' beside another ID says why" \
    contains "$(cat "$tmp/err")" "--app '*' grants any app's window"
check "--app '*' beside another ID starts nothing" test ! -s "$log"
run "$qs" launch --app firefox --app '*' -- app
check "--app '*' after another ID is refused too" test $? -eq 2
run "$qs" launch --app '' -- "$fake/app"
check "an empty --app falls back to the basename" \
    contains "$(cat "$log")" 'tide_focus.grant("app", nil, '
run FAKE_HYPRCTL_REPLY='error: no tide_focus' "$qs" launch --app a --app b -- app
check "a rejected list grant names every ID" \
    contains "$(cat "$tmp/err")" "couldn't record a focus grant for a, b: error"
run "$qs" launch --app '*' -- "$fake/app"
check "--app '*' grants the next window of any app" \
    contains "$(cat "$log")" 'tide_focus.grant("*")'
for opener in xdg-open "gio open"; do
    printf '#!/bin/sh\n' > "$fake/${opener%% *}"
    chmod +x "$fake/${opener%% *}"
    # shellcheck disable=SC2086  # "gio open" is two words
    run "$qs" launch "$fake"/$opener https://example.com/
    check "$opener grants the first window of any app" \
        contains "$(cat "$log")" 'tide_focus.grant("*")'
done
run "$qs" launch "$fake/gio" trash file.txt
check "gio trash opens no app, so it grants no wildcard" \
    contains "$(cat "$log")" 'tide_focus.grant("gio")'
run "$qs" launch --app 'a"b\c' app
check "the grant escapes the ID for Lua" \
    contains "$(cat "$log")" 'tide_focus.grant("a\"b\\c")'

# A program's desktop entries name the classes its window may have; tide-grant
# reads them (its own tests cover how).
printf '#!/bin/sh\n' > "$fake/editor"
chmod +x "$fake/editor"
run FAKE_CLASSES="org.example.Editor example-editor-x11 EDITOR" "$qs" launch editor
# The grant is keyed by tide's pid, so the extend finds that grant only.
key=$(sed -n '1s/^hyprctl eval tide_focus.grant("editor", nil, \([0-9][0-9]*\))$/\1/p' "$log")
check "the program's own grant goes in first, keyed by tide's pid" test -n "$key"
check "its classes are read after the grant" test "$(sed -n 2p "$log")" = 'tide-grant --classes -- editor'
check "its desktop entries' classes are added to that grant, by its key, without repeats" \
    test "$(sed -n 3p "$log")" = "hyprctl eval tide_focus.extend(\"editor\", { \"org.example.Editor\", \"example-editor-x11\" }, nil, $key)"
check "reading desktop entries says nothing" test ! -s "$tmp/err"
run "$qs" launch "$fake/editor" --writer letter.odt
check "the command goes to the lookup as written" \
    test "$(grep 'tide-grant' "$log")" = "tide-grant --classes -- $fake/editor --writer letter.odt"
check "a program run by path is still granted by name" \
    contains "$(cat "$log")" 'tide_focus.grant("editor", nil, '
# Past wrappers: the program tide-grant finds is granted, and the whole
# command goes to the lookup.
run FAKE_PROGRAM=editor FAKE_CLASSES="org.example.Editor" "$qs" launch env MODE=a editor
check "a wrapped program is granted by its own name" \
    contains "$(cat "$log")" 'tide_focus.grant("editor", nil, '
check "the wrapped command goes to the lookup whole" \
    test "$(grep 'tide-grant' "$log")" = "tide-grant --classes -- env MODE=a editor"
check "the wrapped command runs as given" contains "$(cat "$log")" "uwsm app -- env MODE=a editor"
run FAKE_PROGRAM=/opt/x/xdg-open "$qs" launch env xdg-open https://example.com/
check "a wrapped opener still grants any app's window" \
    contains "$(cat "$log")" 'tide_focus.grant("*")'
run FAKE_PROGRAM= "$qs" launch env --help > /dev/null
check "a command that runs no program is granted its first word" \
    contains "$(cat "$log")" 'tide_focus.grant("env", nil, '
run FAKE_PROGRAM=editor FAKE_PROGRAM_STATUS=2 "$qs" launch env editor
check "a failed program lookup is reported" \
    contains "$(cat "$tmp/err")" "tide-grant couldn't read the program env runs"
check "a failed program lookup grants the first word" \
    contains "$(cat "$log")" 'tide_focus.grant("env", nil, '
run "$qs" launch editor
check "no classes, no extend" test "$(grep -c 'tide_focus' "$log")" -eq 1
run FAKE_CLASSES_STATUS=1 "$qs" launch editor
check "a failed lookup is reported" contains "$(cat "$tmp/err")" "tide-grant couldn't read editor's desktop entries"
check "a failed lookup still launches the app" contains "$(cat "$log")" "uwsm app -- editor"
run FAKE_HYPRCTL_REPLY='error: no tide_focus' FAKE_CLASSES="org.example.Editor" "$qs" launch editor
check "a failed grant isn't widened" test "$(grep -c 'tide_focus' "$log")" -eq 1
run FAKE_CLASSES="org.example.Editor" "$qs" launch --app editor -- editor
check "--app is taken as given, without reading desktop entries" \
    test "$(grep -c 'tide-grant\|extend' "$log")" -eq 0
rm "$fake/tide-grant"
run "$qs" launch editor
check "without tide-grant the grant names the program alone, and says why" \
    contains "$(cat "$tmp/err")" "no tide-grant, so editor's desktop entries weren't read"

run XDG_CURRENT_DESKTOP=KDE "$qs" launch app x
out=$(cat "$log")
check "outside tide it just runs the command" test "$out" = "app x"

# A stuck shell: the wait gives up at the bound and the app starts anyway.
run TIDE_LAUNCH_WAIT=1 FAKE_SYSTEMCTL_SLEEP=5 "$qs" launch app
check "a stuck shell still launches the app" contains "$(cat "$log")" "app "
check "a stuck shell is reported" contains "$(cat "$tmp/err")" "the shell isn't ready"
for bad in 0 abc -1 3601 999999999999999999999; do
    run TIDE_LAUNCH_WAIT="$bad" "$qs" launch app
    check "TIDE_LAUNCH_WAIT=$bad is reported by name" \
        contains "$(cat "$tmp/err")" "TIDE_LAUNCH_WAIT must be a whole number of seconds from 1 to 3600, not '$bad'"
    check "TIDE_LAUNCH_WAIT=$bad still launches the app" contains "$(cat "$log")" "uwsm app -- app"
done
run FAKE_SYSTEMCTL_STATUS=1 "$qs" launch app
check "a failed shell still launches the app" contains "$(cat "$log")" "uwsm app -- app"
check "a failed shell is reported with systemctl's error" \
    contains "$(cat "$tmp/err")" "Job failed"

run FAKE_HYPRCTL_REPLY='error: attempt to index a nil value' "$qs" launch app
check "a rejected grant still launches the app" contains "$(cat "$log")" "uwsm app -- app"
check "a rejected grant is reported" \
    contains "$(cat "$tmp/err")" "couldn't record a focus grant for app: error: attempt"

run "$qs" grant google-chrome
check "grant exits 0 once recorded" test $? -eq 0
check "grant records only the grant, falling back to the app's last window" \
    test "$(cat "$log")" = 'hyprctl eval tide_focus.grant_or_recent("google-chrome")'
run "$qs" grant 'a"b'
check "grant escapes the ID for Lua" contains "$(cat "$log")" 'tide_focus.grant_or_recent("a\"b")'
run FAKE_HYPRCTL_REPLY='error: no tide_focus' "$qs" grant app
check "a rejected grant exits 1" test $? -eq 1
check "a rejected grant says why" \
    contains "$(cat "$tmp/err")" "tide grant: couldn't record a focus grant for app: error: no tide_focus"
run XDG_CURRENT_DESKTOP=KDE "$qs" grant app
check "outside tide grant does nothing" test $? -eq 0 -a ! -s "$log"
run "$qs" focus org.example.Chat
check "focus exits 0 once the guard took it" test $? -eq 0
check "focus asks the guard for the app's most recent window" \
    test "$(cat "$log")" = 'hyprctl eval tide_focus.focus_recent("org.example.Chat")'
run FAKE_HYPRCTL_REPLY='error: no tide_focus' "$qs" focus app
check "a rejected focus exits 1" test $? -eq 1
check "a rejected focus says why" \
    contains "$(cat "$tmp/err")" "tide focus: couldn't focus its window for app: error: no tide_focus"
run XDG_CURRENT_DESKTOP=KDE "$qs" focus app
check "outside tide focus does nothing" test $? -eq 0 -a ! -s "$log"
run "$qs" focus
check "focus with no ID is a usage error" test $? -eq 2
run "$qs" grant
check "grant with no ID is a usage error" test $? -eq 2
run "$qs" grant ''
check "grant with an empty ID is a usage error" test $? -eq 2
run "$qs" grant a b
check "grant takes one ID" test $? -eq 2

run "$qs" launch
check "launch with no command is a usage error" test $? -eq 2
run "$qs" launch --bogus app
check "an unknown option is a usage error" test $? -eq 2
run "$qs" frobnicate
check "an unknown subcommand is a usage error" test $? -eq 2

# autostart-allowed: the allowlist the autostart drop-in consults.
allowed() {
    env XDG_CONFIG_HOME="$tmp/config" sh "$qs" autostart-allowed "$1" 2>"$tmp/err"
}
check "nm-applet's autostart is allowed" allowed 'app-nm\x2dapplet@autostart.service'
check "blueman's autostart is allowed" allowed 'app-blueman@autostart.service'
check "another desktop's autostart is skipped" test "$(allowed 'app-hplip\x2dsystray@autostart.service'; echo $?)" -eq 1
check "a skip says how to allow it" \
    contains "$(cat "$tmp/err")" "not starting hplip-systray in tide; add hplip-systray to $tmp/config/tide/autostart"
mkdir -p "$tmp/config/tide"
printf '# extra applets\nhplip-systray\n\n  xiccd  \nhas space\nhash#tag\n# commented-out\n\\x23lead\n' > "$tmp/config/tide/autostart"
check "the user's list allows more" allowed 'app-hplip\x2dsystray@autostart.service'
check "surrounding spaces in the user's list are ignored" allowed 'app-xiccd@autostart.service'
check "an ID with a space is matched whole" allowed 'app-has\x20space@autostart.service'
check "an ID with a # is matched whole" allowed 'app-hash\x23tag@autostart.service'
check "half of an ID with a space isn't allowed" test "$(allowed 'app-has@autostart.service'; echo $?)" -eq 1
check "an ID starting with # is allowed by its escaped form" allowed 'app-\x23lead@autostart.service'
check "a commented-out line allows nothing" test "$(allowed 'app-commented\x2dout@autostart.service'; echo $?)" -eq 1
check "the defaults still apply beside the user's list" allowed 'app-nm\x2dapplet@autostart.service'
check "an entry the user's list lacks is still skipped" \
    test "$(allowed 'app-xfce4\x2dnotifyd@autostart.service'; echo $?)" -eq 1
rm -rf "$tmp/config"
mkdir -p "$tmp/config/tide/autostart"
check "an unreadable allowlist stops the check rather than denying" \
    test "$(allowed 'app-nm\x2dapplet@autostart.service'; echo $?)" -eq 3
check "an unreadable allowlist is named" contains "$(cat "$tmp/err")" "couldn't read $tmp/config/tide/autostart"
rm -rf "$tmp/config"
mkdir -p "$tmp/config/tide"
ln -s "$tmp/nowhere" "$tmp/config/tide/autostart"
check "a dangling allowlist symlink stops the check too" \
    test "$(allowed 'app-hplip\x2dsystray@autostart.service'; echo $?)" -eq 3
rm -rf "$tmp/config"
check "other escaped characters are undone too" \
    test "$(XDG_CONFIG_HOME="$tmp/config" sh "$qs" autostart-allowed 'app-org.example.a\x2bb@autostart.service' 2>&1)" = \
        "tide: not starting org.example.a+b in tide; add org.example.a+b to $tmp/config/tide/autostart to allow it"
check "a unit that isn't an autostart one is a usage error" test "$(allowed 'app-foo.service'; echo $?)" -eq 2

# The drop-in on every app-*.service: only autostart units in tide ask
# the allowlist; everything else passes without asking.
dropin=$(sed -n "s/^ExecCondition=\/bin\/sh -c '\(.*\)'\$/\1/p" systemd/user/app-.service.d/tide-autostart.conf)
check "the drop-in has one ExecCondition" test -n "$dropin"
cat > "$fake/tide" <<'FAKE'
#!/bin/sh
printf "tide %s\n" "$*" >> "$FAKE_LOG"
exit "${FAKE_ALLOWED_STATUS:-0}"
FAKE
chmod +x "$fake/tide"
condition() {
    unit=$1
    shift
    : > "$log"
    # As systemd does: $$ becomes $, and %n the unit's name.
    cmd=$(printf '%s\n' "$dropin" | sed -e 's/\$\$/$/g' -e "s/%n/$(printf '%s' "$unit" | sed 's/\\/\\\\/g')/g")
    env PATH="$fake:$PATH" FAKE_LOG="$log" "$@" sh -c "$cmd"
}
condition 'app-hplip\x2dsystray@autostart.service' XDG_CURRENT_DESKTOP=tide:Hyprland FAKE_ALLOWED_STATUS=1
check "in tide, an autostart unit gets the allowlist's answer" test $? -eq 1
check "the allowlist is asked about that unit" \
    contains "$(cat "$log")" 'tide autostart-allowed app-hplip\x2dsystray@autostart.service'
condition 'app-hplip\x2dsystray@autostart.service' XDG_CURRENT_DESKTOP=KDE FAKE_ALLOWED_STATUS=1
check "under Plasma, an autostart unit runs" test $? -eq 0
check "under Plasma, the allowlist isn't asked" test ! -s "$log"
condition 'app-nm\x2dapplet@autostart.service' XDG_CURRENT_DESKTOP=tide:Hyprland FAKE_ALLOWED_STATUS=0
check "in tide, an allowed autostart unit runs" test $? -eq 0
condition 'app-nm\x2dapplet@autostart.service' XDG_CURRENT_DESKTOP=tide:Hyprland FAKE_ALLOWED_STATUS=127 2>"$tmp/err"
check "a helper that can't run fails the unit, rather than skipping it" test $? -eq 255
check "a failing helper is named in the unit's log" \
    contains "$(cat "$tmp/err")" 'tide autostart-allowed failed (127) for app-nm\x2dapplet@autostart.service'
condition 'app-nm\x2dapplet@autostart.service' XDG_CURRENT_DESKTOP=tide:Hyprland FAKE_ALLOWED_STATUS=2 2>/dev/null
check "a helper usage error fails the unit too" test $? -eq 255
condition 'app-org.kde.dolphin@1234.service' XDG_CURRENT_DESKTOP=tide:Hyprland FAKE_ALLOWED_STATUS=1
check "in tide, an app that isn't autostarted runs" test $? -eq 0
check "in tide, an app that isn't autostarted isn't asked about" test ! -s "$log"

# brightness: brightnessctl answers in its machine-readable form, and qs
# logs the OSD call.
cat > "$fake/brightnessctl" <<'FAKE'
#!/bin/sh
printf "brightnessctl %s\n" "$*" >> "$FAKE_LOG"
echo "${FAKE_BRIGHTNESS_OUT-intel_backlight,backlight,12000,50%,24000}"
exit "${FAKE_BRIGHTNESS_STATUS:-0}"
FAKE
cat > "$fake/qs" <<'FAKE'
#!/bin/sh
printf "qs %s\n" "$*" >> "$FAKE_LOG"
test -z "${FAKE_QS_SAYS:-}" || echo "$FAKE_QS_SAYS" >&2
exit "${FAKE_QS_STATUS:-0}"
FAKE
chmod +x "$fake/brightnessctl" "$fake/qs"
run "$qs" brightness 5%+
check "brightness exits 0" test $? -eq 0
out=$(cat "$log")
check "brightness sets the backlight" contains "$out" "brightnessctl -m set 5%+"
check "brightness shows the new level on the OSD" contains "$out" "qs -c tide ipc call osd brightness 50"
check "a clean brightness change says nothing" test ! -s "$tmp/err"
run FAKE_QS_STATUS=255 FAKE_QS_SAYS="No running instances for /home/user/.config/quickshell/tide/shell.qml" "$qs" brightness 5%-
check "no shell to show the OSD isn't a failure" test $? -eq 0
check "no shell to show the OSD says nothing" test ! -s "$tmp/err"
run FAKE_QS_STATUS=255 FAKE_QS_SAYS="Target not found" "$qs" brightness 5%-
check "an OSD the shell rejects still exits 0" test $? -eq 0
check "an OSD the shell rejects is reported" contains "$(cat "$tmp/err")" "the shell's OSD didn't take it: Target not found"
run FAKE_BRIGHTNESS_STATUS=1 FAKE_BRIGHTNESS_OUT="no backlight" "$qs" brightness 5%+
check "a failed brightnessctl fails" test $? -eq 1
check "a failed brightnessctl is reported" contains "$(cat "$tmp/err")" "brightnessctl set 5%+ failed: no backlight"
check "a failed brightnessctl shows no OSD" test "$(grep -c '^qs ' "$log")" -eq 0
run FAKE_BRIGHTNESS_OUT="something else" "$qs" brightness 40%
check "an unreadable level still exits 0" test $? -eq 0
check "an unreadable level is reported" contains "$(cat "$tmp/err")" "couldn't read the new level"
check "an unreadable level shows no OSD" test "$(grep -c '^qs ' "$log")" -eq 0
run XDG_CURRENT_DESKTOP=KDE "$qs" brightness 5%+
check "outside tide, brightness still changes" contains "$(cat "$log")" "brightnessctl -m set 5%+"
check "outside tide, there's no OSD to tell" test "$(grep -c '^qs ' "$log")" -eq 0
run "$qs" brightness
check "brightness needs a step" test $? -eq 2

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh "$qs" bin/tide_test.sh
fi

printf 'tide_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
