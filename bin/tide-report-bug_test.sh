#!/bin/sh
#
# Tests for bin/tide-report-bug, run as `tide report-bug`: the real jq and
# awk, with stand-ins for journalctl, date, uname, id, wl-copy, xdg-open,
# notify-send, the compositors' --version and tide-doctor.

cd "$(dirname "$0")/.." || exit 1

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
lacks() { ! contains "$1" "$2"; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/fake
mkdir "$fake"
# tide and tide-report-bug, with a stand-in tide-doctor beside them, as
# `make install-session` puts them.
inst=$tmp/inst
mkdir "$inst"
cp bin/tide bin/tide-report-bug "$inst/"
cat > "$inst/tide-doctor" <<'FAKE'
#!/bin/sh
echo "hypridle.service is inactive: see systemctl --user status hypridle.service"
exit 1
FAKE
log=$tmp/log
export FAKE_LOG="$log" FAKE_DIR="$tmp"

# journalctl: logs its arguments, and prints the lines of the journal it's
# asked for: $FAKE_DIR/j-kwin for -t kwin_wayland, j-units for tide's
# units, j-tags for tide's commands, j-wm for the compositor's unit, and
# j-all for the whole user journal. $FAKE_JOURNAL_FAILS makes it fail.
cat > "$fake/journalctl" <<'FAKE'
#!/bin/sh
printf 'journalctl %s\n' "$*" >> "$FAKE_LOG"
if test -n "${FAKE_JOURNAL_FAILS:-}"; then
    echo "No journal files were opened due to insufficient permissions." >&2
    exit 1
fi
case " $* " in
    *" -t kwin_wayland "*) f=kwin ;;
    *" -u tide.service "*) f=units ;;
    *" -u tide-kde.service "*) f=kde ;;
    *" -t tide-session "*) f=tags ;;
    *" -u wayland-wm@* "*) f=wm ;;
    *) f=all ;;
esac
test -e "$FAKE_DIR/j-$f" && cat "$FAKE_DIR/j-$f"
exit 0
FAKE
# date: the time is $FAKE_NOW; the rest is the real date's, in UTC.
cat > "$fake/date" <<'FAKE'
#!/bin/sh
if test "$*" = "+%s"; then
    echo "$FAKE_NOW"
    exit 0
fi
TZ=UTC exec "$FAKE_REAL_DATE" "$@"
FAKE
cat > "$fake/uname" <<'FAKE'
#!/bin/sh
case "$1" in
    -n) echo myhost ;;
    *) echo "Linux 6.1.0" ;;
esac
FAKE
cat > "$fake/id" <<'FAKE'
#!/bin/sh
echo "${FAKE_USER-alice}"
FAKE
cat > "$fake/wl-copy" <<'FAKE'
#!/bin/sh
printf 'wl-copy %s\n' "$*" >> "$FAKE_LOG"
cat > "$FAKE_DIR/copied"
exit "${FAKE_WLCOPY_STATUS:-0}"
FAKE
cat > "$fake/xdg-open" <<'FAKE'
#!/bin/sh
printf '%s\n' "$1" > "$FAKE_DIR/opened"
FAKE
cat > "$fake/notify-send" <<'FAKE'
#!/bin/sh
printf 'notify-send %s\n' "$*" >> "$FAKE_LOG"
FAKE
for v in Hyprland tidewm tidesway qs kwin_wayland plasmashell; do
    printf '#!/bin/sh\necho "%s 1.2.3"\n' "$v" > "$fake/$v"
done
chmod +x "$fake"/* "$inst"/*
FAKE_REAL_DATE=$(command -v date)
export FAKE_REAL_DATE
# 2026-11-18 10:00:00 UTC.
FAKE_NOW=1794996000
export FAKE_NOW

home=$tmp/home/alice
mkdir -p "$home/.local/share/tide"
echo "v0.0.1234 (abcdef123456)" > "$home/.local/share/tide/version"

# Whether no journal read reaches back past 30 s before it ran.
empty_since() { ! grep '^journalctl ' "$log" | grep -v -- "--since=@$((FAKE_NOW - 30)) " | grep -q .; }

reset() {
    rm -f "$tmp"/j-* "$log" "$tmp/copied" "$tmp/opened"
    rm -rf "$home/.local/state"
}

# Runs `tide report-bug` with ARGS, as the key would in the session named
# by $DESKTOP; its stderr goes to $tmp/err.
run() {
    status=0
    env -i PATH="$fake:$PATH" HOME="$home" XDG_CURRENT_DESKTOP="${DESKTOP-tide:Hyprland}" \
        FAKE_LOG="$log" FAKE_DIR="$tmp" FAKE_NOW="$FAKE_NOW" FAKE_REAL_DATE="$FAKE_REAL_DATE" \
        ${FAKE_USER+FAKE_USER="$FAKE_USER"} ${FAKE_WLCOPY_STATUS+FAKE_WLCOPY_STATUS="$FAKE_WLCOPY_STATUS"} \
        ${FAKE_JOURNAL_FAILS+FAKE_JOURNAL_FAILS=1} ${STATE+XDG_STATE_HOME="$STATE"} \
        sh "$inst/tide" report-bug "$@" >"$tmp/out" 2>"$tmp/err" || status=$?
    saved=$(find "$home/.local/state/tide/reports" -name "*.txt" 2>/dev/null | head -n 1)
    report=
    test -z "$saved" || report=$(cat "$saved")
}

# --- Hyprland: the 30 s before, the reasons, the log ---
reset
cat > "$tmp/j-all" <<'EOF'
2026-11-18T09:59:41.000000+0000 myhost Hyprland[10]: tide why: go to workspace web: the Super+2 key
2026-11-18T09:59:45.000000+0000 myhost Hyprland[10]: some other Hyprland line
2026-11-18T09:59:50.000000+0000 myhost qs[20]: tide why: workspace web shows
EOF
cat > "$tmp/j-units" <<EOF
2026-11-18T09:59:44.000000+0000 myhost qs[20]: tide: reading $home/.config/hypr/tide-workspaces.lua
2026-11-18T09:59:50.000000+0000 myhost qs[20]: tide why: workspace web shows
EOF
cat > "$tmp/j-tags" <<'EOF'
2026-11-18T09:59:42.000000+0000 myhost tide-keys[30]: alice ran a key on myhost.lan; myhostess stays
EOF
cat > "$tmp/j-wm" <<'EOF'
2026-11-18T09:59:43.000000+0000 myhost Hyprland[10]: [ERR] a config error
2026-11-18T09:59:43.500000+0000 myhost Hyprland[10]: [LOG] a busy line
EOF
run
check "it succeeds" test "$status" -eq 0
check "it saves the report" test -n "$saved"
check "under ~/.local/state/tide/reports, named for when it ran" \
    test "$saved" = "$home/.local/state/tide/reports/tide-20261118-100000.txt"
check "readable by you alone" test "$(stat -c %a "$saved")" = 600
check "every journal read starts 30 s before it ran" \
    test "$(grep -c '^journalctl ' "$log")" -eq "$(grep -c -- "--since=@$((FAKE_NOW - 30)) " "$log")"
check "and there are journal reads" test "$(grep -c '^journalctl ' "$log")" -ge 4
check "no read reaches further back" empty_since
check "and every read ends when it ran, so tide doctor's own lines stay out" \
    test "$(grep -c '^journalctl ' "$log")" -eq "$(grep -c -- "--until=@$FAKE_NOW " "$log")"
check "it names the port, version, OS and compositor" \
    contains "$report" "- Port: tide for Linux
- Version: v0.0.1234 (abcdef123456)"
check "and Hyprland's version" contains "$report" "- Compositor: Hyprland: Hyprland 1.2.3"
check "and Quickshell's" contains "$report" "- Quickshell: qs 1.2.3"
check "it has the workspace and focus changes with their reasons" \
    contains "$report" "tide why: go to workspace web: the Super+2 key"
reasons=$(printf '%s\n' "$report" | sed -n '/^## Workspace and focus changes/,/^## tide doctor/p')
check "only those lines" lacks "$reasons" "some other Hyprland line"
check "it has tide doctor's output" contains "$report" "hypridle.service is inactive"
check "and tide's log" contains "$report" "tide: reading ~/.config/hypr/tide-workspaces.lua"
check "with the compositor's errors" contains "$report" "[ERR] a config error"
check "but not Hyprland's every line" lacks "$report" "a busy line"
log_part=$(printf '%s\n' "$report" | sed -n '/^## tide.s log/,$p')
check "the log leaves out the reasons, listed above" lacks "$log_part" "tide why:"
check "in time order" test "$(printf '%s\n' "$log_part" | grep -n 'ran a key' | cut -d: -f1)" \
    -lt "$(printf '%s\n' "$log_part" | grep -n 'config error' | cut -d: -f1)"
check "it replaces the home folder with ~" lacks "$report" "$home"
check "the hostname with host1" contains "$report" "user1 ran a key on host1.lan"
check "but not within another word" contains "$report" "myhostess stays"
check "and the hostname is nowhere else" lacks "$(printf '%s\n' "$report" | sed 's/myhostess//g')" "myhost"
check "nor the user name" lacks "$report" "alice"
check "it copies the report to the clipboard" test "$(cat "$tmp/copied")" = "$report"
url=$(cat "$tmp/opened")
check "it opens a new issue on tide's repo" contains "$url" "https://github.com/mikelward/tide/issues/new?title=tide%20for%20Linux%3A%20&body="
check "whose body says first that nothing was sent" contains "$url" "body=This%20report%20was%20made%20on%20my%20computer%20and%20nothing%20was%20sent"
check "and to paste the report" contains "$url" "The%20full%20report%20is%20on%20your%20clipboard%3A%20paste%20it%20below"
check "naming the file to attach, not its folder" contains "$url" "saved%20as%20tide-20261118-100000.txt%20in%20tide%27s%20reports%20folder"
check "the address is well under 6000 characters" test "${#url}" -lt 3000
check "a notification says where the report is" \
    grep -qF "notify-send -a tide Bug report ready It's on the clipboard, and the issue page is open: paste it there." "$log"
check "the journal says it started and ended" \
    test "$(grep -c -e 'gathering a report' -e 'done: ' "$tmp/err")" -eq 2

# --- tidewm: its version, and all its compositor's lines ---
reset
cat > "$tmp/j-wm" <<'EOF'
2026-11-18T09:59:43.000000+0000 myhost tidewm[10]: ipc: client 3 dropped
EOF
DESKTOP=tidewm:tide run
check "tidewm's session names tidewm's version" contains "$report" "- Compositor: tidewm: tidewm 1.2.3"
check "and has all of tidewm's lines" contains "$report" "ipc: client 3 dropped"
DESKTOP=tidewm:tidesway:tide run
check "tidesway's names tidesway's" contains "$report" "- Compositor: tidesway: tidesway 1.2.3"

# --- KDE: tide-kde's repo, and its KWin script's lines ---
# tide-kde-report-bug.service runs `tide report-bug` with no arguments,
# in Plasma's session, whose XDG_CURRENT_DESKTOP is KDE.
reset
cat > "$tmp/j-all" <<'EOF'
2026-11-18T09:59:39.000000+0000 myhost qs[7]: tide: the launcher opened
2026-11-18T09:59:40.000000+0000 myhost kwin_wayland[5]: js: tide-kde: workspace 1 -> 2 (Meta+2)
2026-11-18T09:59:41.000000+0000 myhost kwin_wayland[5]: js: tide-kde: focus firefox on 2 (it asked, with a launch grant)
2026-11-18T09:59:41.500000+0000 myhost kwin_wayland[5]: js: tide-kde: laid out 3 windows
2026-11-18T09:59:42.000000+0000 myhost kwin_wayland[5]: kwin_core: something of KWin's
EOF
DESKTOP=KDE run
check "on KDE it succeeds" test "$status" -eq 0
check "it says it's tide on KDE" contains "$report" "- Port: tide on KDE"
check "with KWin's and Plasma's versions" contains "$report" "- Compositor: KWin kwin_wayland 1.2.3; Plasma plasmashell 1.2.3"
check "only 30 s of the journal" empty_since
reasons=$(printf '%s\n' "$report" | sed -n '/^## Workspace and focus changes/,/^## tide doctor/p')
check "the KWin script's workspace changes are the reasons" contains "$reasons" "js: tide-kde: workspace 1 -> 2 (Meta+2)"
check "and its focus changes" contains "$reasons" "js: tide-kde: focus firefox on 2 (it asked, with a launch grant)"
check "but not its other lines" lacks "$reasons" "laid out 3 windows"
log_part=$(printf '%s\n' "$report" | sed -n '/^## tide.s log/,$p')
check "which are its log" contains "$log_part" "js: tide-kde: laid out 3 windows"
check "with the launcher's" contains "$log_part" "tide: the launcher opened"
check "and not the reasons again" lacks "$log_part" "tide-kde: workspace"
check "nor KWin's own" lacks "$report" "something of KWin's"
check "it opens a new issue on tide-kde's repo" contains "$(cat "$tmp/opened")" "https://github.com/mikelward/tide-kde/issues/new?"
check "titled for tide on KDE" contains "$(cat "$tmp/opened")" "title=tide%20on%20KDE%3A%20"
check "its usage names report-bug, which tide-kde checks for an old tide" \
    contains "$(sh "$inst/tide" 2>&1)" "report-bug"
reset
DESKTOP=tide:Hyprland run --kde
check "--kde makes it KDE's anywhere" contains "$report" "- Port: tide on KDE"

# --- problems ---
reset
FAKE_JOURNAL_FAILS=1 run
check "a journal it can't read is said in the report" \
    contains "$report" "failed: No journal files were opened due to insufficient permissions."
check "and the report is still made" test "$status" -eq 0
check "the reasons say so too, not that nothing changed" \
    contains "$(printf '%s\n' "$report" | sed -n '/^## Workspace and focus changes/,/^## tide doctor/p')" "failed: No journal files"
reset
DESKTOP=KDE FAKE_JOURNAL_FAILS=1 run
check "on KDE, the reasons say the journal couldn't be read" \
    contains "$(printf '%s\n' "$report" | sed -n '/^## Workspace and focus changes/,/^## tide doctor/p')" "failed: No journal files"
check "and so does the log" \
    contains "$(printf '%s\n' "$report" | sed -n '/^## tide.s log/,$p')" "failed: No journal files"
reset
STATE=$tmp/elsewhere/alice-state run
check "a state folder outside home is used" test -e "$tmp/elsewhere/alice-state/tide/reports/tide-20261118-100000.txt"
check "but its path isn't in the issue page's address" lacks "$(cat "$tmp/opened")" "elsewhere"
check "which names the file alone" contains "$(cat "$tmp/opened")" "tide-20261118-100000.txt"
rm -rf "$tmp/elsewhere"
reset
FAKE_WLCOPY_STATUS=1 run
check "a failed copy is said in the notification" \
    grep -q "notify-send -a tide Bug report ready It couldn't be copied: attach ~/.local/state/tide/reports/tide-20261118-100000.txt instead. Then the issue page is open." "$log"
reset
FAKE_USER=user run
check "a user name that's a common word is kept, not mangled" contains "$report" "--user"
reset
mkdir -p "$home/.local/state/tide"
: > "$home/.local/state/tide/reports"
run
check "a report that can't be saved exits 1" test "$status" -eq 1
check "saying why" grep -q "couldn't save the report" "$tmp/err"
check "in a notification too" grep -q "notify-send -a tide -u critical No bug report" "$log"
check "and opens nothing" test ! -e "$tmp/opened"
reset
run --bogus
check "an unknown option is a usage error" test "$status" -eq 2

printf 'tide-report-bug_test: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
