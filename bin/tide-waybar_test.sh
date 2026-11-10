#!/bin/sh
#
# Tests for bin/tide-waybar, with a fake waybar that says how it was run.

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

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tides/waybar" "$tmp/own/waybar" "$tmp/ownc/waybar" "$tmp/none"
printf '#!/bin/sh\necho "waybar $*"\n' > "$tmp/bin/waybar"
chmod +x "$tmp/bin/waybar"
cp waybar/tide-hyprland.jsonc waybar/tide-tidewm.jsonc waybar/tide.css "$tmp/tides/waybar/"
cp waybar/tide-hyprland.jsonc waybar/tide.css "$tmp/own/waybar/"
: > "$tmp/own/waybar/config"
: > "$tmp/ownc/waybar/config.jsonc"

# run CONFIG_HOME DESKTOP: what waybar was run with, and what was said.
run() {
    out=$(PATH="$tmp/bin:/usr/bin:/bin" XDG_CONFIG_HOME="$tmp/$1" XDG_CURRENT_DESKTOP="$2" sh bin/tide-waybar 2> "$tmp/err")
    err=$(cat "$tmp/err")
}

run tides tide:Hyprland
check "on Hyprland, waybar gets tide's config with Hyprland's workspaces" \
    test "$out" = "waybar --config $tmp/tides/waybar/tide-hyprland.jsonc --style $tmp/tides/waybar/tide.css"
run tides tide:tidewm
check "on tidewm, the one with sway's IPC workspaces" \
    test "$out" = "waybar --config $tmp/tides/waybar/tide-tidewm.jsonc --style $tmp/tides/waybar/tide.css"
check "a config that's there says nothing" test -z "$err"
run own tide:Hyprland
check "a waybar config of your own is waybar's to read" test "$out" = "waybar "
run ownc tide:tidewm
check "as is a config.jsonc of your own" test "$out" = "waybar "
run none tide:Hyprland
check "without tide's config installed, waybar still starts" test "$out" = "waybar "
check "and that's said, with the fix" \
    contains "$err" "can't read $tmp/none/waybar/tide-hyprland.jsonc and $tmp/none/waybar/tide.css, so waybar starts with its own default; run \`make install\` in tide"

# The configs are what waybar can read, and differ only in whose workspaces.
if command -v node >/dev/null 2>&1; then
    for f in waybar/tide-hyprland.jsonc waybar/tide-tidewm.jsonc; do
        check "$f is JSON" node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$f"
    done
fi
check "Hyprland's has Hyprland's workspaces" grep -q '"modules-left": \["hyprland/workspaces"\]' waybar/tide-hyprland.jsonc
check "tidewm's has sway's" grep -q '"modules-left": \["sway/workspaces"\]' waybar/tide-tidewm.jsonc
check "each says tide's bar isn't running" \
    sh -c 'grep -q "tide.s bar isn.t running" waybar/tide-hyprland.jsonc && grep -q "tide.s bar isn.t running" waybar/tide-tidewm.jsonc'
# shellcheck disable=SC2016 # make's own $(...)
check "make install installs the configs and the style" \
    grep -q '^	install -m 644 waybar/tide-hyprland.jsonc waybar/tide-tidewm.jsonc waybar/tide.css "$(WAYBAR_DIR)/"$' Makefile
check "and tide-waybar" grep -q 'bin/tide-waybar ' Makefile

check "tide-waybar is executable" test -x bin/tide-waybar
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes on tide-waybar and this test" shellcheck -s sh bin/tide-waybar bin/tide-waybar_test.sh
fi

echo "tide-waybar_test.sh: $passes passed, $failures failed"
test "$failures" -eq 0
