#!/bin/sh
#
# Tests for tidewm/tide.conf, tide's config for its tidewm session. tidewm
# can't run in CI, so these check the file as tidewm reads it (tidewm's
# docs/config.md): every line is a directive it takes, every binding runs
# commands it knows, no key is bound twice, and its named bindings are
# hypr/hyprland.lua's. From the repo root: `sh tidewm/config_test.sh`.

cd "$(dirname "$0")/.." || exit 1
cfg=tidewm/tide.conf
hypr=hypr/hyprland.lua

passes=0
failures=0
check() {
    _name=$1
    shift
    if "$@"; then passes=$((passes + 1)); else failures=$((failures + 1)); printf 'FAIL: %s\n' "$_name" >&2; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
empty() { test -z "$1"; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# The file with each binding's --name=NAME and --desc "TEXT" left out,
# for the checks of what a key runs, which don't care what it's called or
# how the Shortcuts page describes it.
sed -e 's/^\([[:space:]]*bind[a-z]* .*\)--name=[a-z0-9_]* /\1/' -e 's/--desc "[^"]*" //' "$cfg" >"$tmp/plain"
# And with only --desc left out, for the checks of a named binding.
sed 's/--desc "[^"]*" //' "$cfg" >"$tmp/named"

# The file's lines, comments and blank lines left out, an input block's
# lines prefixed "  ", a mode's read as the top level's.
lines=$(awk '
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*}[[:space:]]*$/ { inblock = 0; next }
    inblock == "input" { sub(/^[[:space:]]+/, ""); print "  " $0; next }
    inblock == "mode" { sub(/^[[:space:]]+/, ""); print; next }
    /{[[:space:]]*$/ { inblock = $1; sub(/[[:space:]]*{[[:space:]]*$/, ""); print; next }
    { print }' "$tmp/plain")

bad=$(printf '%s\n' "$lines" | grep -v '^  ' | awk '{ print $1 }' | grep -vxE \
    'set|bindsym|bindswitch|for_window|output|input|mode|single_window|dim_inactive|default_border|focus_guard|floating_modifier|xwayland_scaling|include' || true)
check "every line is a directive tidewm takes${bad:+: $bad}" empty "$bad"

# As tide on Hyprland: dimming, not a border, shows the focused window.
border=$(printf '%s\n' "$lines" | awk '$1 == "default_border"' | tail -n 1)
check "windows have no border (default_border none, not '$border')" test "$border" = "default_border none"

blocks=$(grep -E '{[[:space:]]*$' "$cfg" | grep -vE '^(input|mode) ' || true)
check "the file's blocks are input blocks and modes" empty "$blocks"

bindings=$(printf '%s\n' "$lines" | awk '$1 == "bindsym" || $1 == "bindswitch" {
    i = 2
    while ($i ~ /^--/) i++
    cmd = ""
    for (j = i + 1; j <= NF; j++) cmd = cmd (cmd == "" ? "" : " ") $j
    print cmd }')
unknown=$(printf '%s\n' "$bindings" | while IFS= read -r c; do
    case "$c" in exec\ *) echo exec; continue ;; esac
    printf '%s\n' "$c" | tr ';' '\n' | awk 'NF { print $1 }'
done | grep -vxE 'exec|kill|exit|layout|mfact|nmaster|zoom|focus|maximize|fullscreen|floating|workspace|move|movestack|resize|input|output|mode|reload|grant|dim|sticky|urgent|nop|rename|persist|unpersist|chvt|unlock|switch' || true)
check "every binding runs commands tidewm knows${unknown:+: $unknown}" empty "$unknown"

keys=$(awk '/^mode / { mode = $2 } /^}/ { mode = "" } $1 == "bindsym" {
    i = 2; flags = mode
    while ($i ~ /^--/) { if ($i == "--release" || $i == "--kept-open") flags = flags $i; i++ }
    print (flags == "" ? "-" : flags) " " tolower($i) }' "$tmp/plain" | while read -r f combo; do
    printf '%s %s\n' "$f" "$(printf '%s\n' "$combo" | tr '+' '\n' | sort | tr '\n' '+')"
done)
dup=$(printf '%s\n' "$keys" | sort | uniq -d)
check "no key is bound twice${dup:+: $dup}" empty "$dup"

for k in Ctrl+w Ctrl+Shift+w Ctrl+q Alt+F4; do
    check "a pinned window keeps $k from closing it" contains "$(cat "$tmp/plain")" "bindsym --kept-open $k kill"
done

nogrant=$(grep 'exec tide launch' "$cfg" | grep -v 'tide launch --app ' || true)
check "every tide launch names the app its window grant is for" empty "$nogrant"

# Every binding says what it does, as Hyprland's do, for the Shortcuts
# page (SPEC.md §16): tidewm lists a --desc as its description.
undescribed=$(grep -E '^[[:space:]]*bind(sym|switch|code) ' "$cfg" | grep -v -- '--desc "[^"]' || true)
check "every binding has a description${undescribed:+: $undescribed}" empty "$undescribed"

check "the settings tide's shell writes are included, then nwg-displays' outputs, last, so they win" \
    test "$(printf '%s\n' "$lines" | tail -n 2 | tr '\n' '|')" = "include tide-*.conf|include ~/.config/sway/outputs|"
check "the focus guard is on" contains "$(cat "$tmp/plain")" "focus_guard enable"
# The lock key runs what Hyprland's session runs: `tide lock`, which locks
# with no idle daemon running too, where logind's Lock alone has nothing
# to answer it.
hlock=$(sed -n 's/^local lock = tide_session and "\([^"]*\)" or .*/\1/p' "$hypr")
check "hyprland.lua's lock command is found" test -n "$hlock"
# shellcheck disable=SC2016 # $mod is the config's, not the shell's
check "Super+L locks as Hyprland's session does, with tide lock" \
    test "$(sed -n 's/^bindsym --name=lock \$mod+l exec //p' "$tmp/named")" = "$hlock"
check "which locks with no idle daemon running, and falls back to logind" \
    test "$hlock" = "tide lock || loginctl lock-session"

# The reload key runs `tide reload`, as Hyprland's session does: tidewm's
# own reload would leave a shell that isn't running stopped.
# shellcheck disable=SC2016 # $mod is the config's, not the shell's
check "Super+Ctrl+R reloads with tide reload" \
    test "$(sed -n 's/^bindsym --name=reload \$mod+Ctrl+r exec //p' "$tmp/named")" = "tide reload"

# Every name hyprland.lua binds, so keys.json serves both sessions, but the
# floating rules' key and the layout used last, which have no tidewm
# command yet, and restore, which has no key by default (Super+X and
# Super+Shift+X toggle).
hnames=$(grep -oE '^ *bind\("[a-z0-9_]+"' "$hypr" | sed 's/.*"\(.*\)"/\1/' | sort -u | grep -vxE 'floating_rule|last_layout|restore')
tnames=$(sed -n 's/^bindsym .*--name=\([a-z0-9_]*\) .*/\1/p' "$cfg" | sort -u)
missing=$(printf '%s\n' "$hnames" | grep -vxF "$tnames" || true)
check "each of hyprland.lua's named bindings is here too${missing:+: $missing}" empty "$missing"

# tide's own defaults, not anyone's preferences.
for personal in runenv dvorak kitty left_handed; do
    check "nothing personal: no $personal" empty "$(grep -v '^ *#' "$cfg" | grep "$personal" || true)"
done
check "Super+T opens the default terminal" contains "$(cat "$tmp/named")" "--name=terminal \$mod+t exec tide launch --app '*' -- xdg-terminal-exec"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh tidewm/config_test.sh
fi

printf 'config_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
