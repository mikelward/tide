#!/bin/sh
#
# Tests for bin/tide-greeter, installed in a scratch prefix as `make
# install-session` lays it out, with busctl (localed) and Hyprland
# stubbed.

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
lacks() { ! contains "$@"; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# A prefix with a space in it, as nothing stops one.
prefix="$tmp/the prefix"
mkdir -p "$prefix/bin" "$prefix/share/tide/greeter" "$prefix/share/tide/shell" "$tmp/stubs" || exit 1
cp bin/tide-greeter "$prefix/bin/" || exit 1
: >"$prefix/share/tide/greeter/hyprland.lua" || exit 1
: >"$prefix/share/tide/shell/greeter.qml" || exit 1
printf '#!/bin/sh\n' >"$prefix/bin/tide-greetd" || exit 1
chmod +x "$prefix/bin/tide-greetd" || exit 1

# busctl prints $BUSCTL_OUT and exits $BUSCTL_EXIT, and records its
# arguments; Hyprland records its arguments and the greeter's environment.
cat >"$tmp/stubs/busctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$STUB_LOG.busctl"
printf '%s' "$BUSCTL_OUT"
exit "${BUSCTL_EXIT:-0}"
EOF
cat >"$tmp/stubs/Hyprland" <<'EOF'
#!/bin/sh
{
    printf 'args'
    printf ' [%s]' "$@"
    printf '\n'
    env | grep '^TIDE_GREETER_' | sort
} >"$STUB_LOG"
exit "${HYPRLAND_EXIT:-0}"
EOF
printf '#!/bin/sh\n' >"$tmp/stubs/qs" || exit 1
chmod +x "$tmp/stubs/busctl" "$tmp/stubs/Hyprland" "$tmp/stubs/qs" || exit 1
# agreety, in a directory of its own so only some runs have it: it says how
# it was run.
mkdir "$tmp/agreety" || exit 1
printf '#!/bin/sh\necho "agreety $*"\n' >"$tmp/agreety/agreety" || exit 1
chmod +x "$tmp/agreety/agreety" || exit 1
# The system's commands the greeter needs, without the system's Hyprland,
# qs or agreety.
mkdir "$tmp/sys" || exit 1
for c in sh dirname sed test printf tr cat env grep sort; do
    ln -s "$(command -v "$c")" "$tmp/sys/$c" || exit 1
done

# greeter STATUS [ARG...]: runs the installed tide-greeter, leaving its
# output in $out and what Hyprland got in $ran, and checks that it exits
# STATUS, so no run goes unchecked.
greeter() {
    _want=$1
    shift
    rm -f "$tmp/log" "$tmp/log.busctl"
    out=$(env -i PATH="${GREETER_PATH:-$tmp/stubs:$tmp/sys}" STUB_LOG="$tmp/log" \
        BUSCTL_OUT="${BUSCTL_OUT-}" BUSCTL_EXIT="${BUSCTL_EXIT:-0}" HYPRLAND_EXIT="${HYPRLAND_EXIT:-0}" \
        TIDE_GREETER_AGREETY_DIRS="${AGREETY_DIRS-}" \
        "$prefix/bin/tide-greeter" "$@" 2>&1)
    _code=$?
    ran=$(cat "$tmp/log" 2>/dev/null)
    if test "$_code" -eq "$_want"; then
        pass
    else
        fail "tide-greeter $* exited $_code, not $_want: $out"
    fi
}

BUSCTL_OUT='s "us"
s "pc105"
s "dvorak"
s "compose:caps,altwin:menu_win"
'
greeter 0
check "Hyprland gets the greeter's config" \
    contains "$ran" "args [--config] [$prefix/bin/../share/tide/greeter/hyprland.lua]"
check "the greeter's QML is passed on" \
    contains "$ran" "TIDE_GREETER_QML=$prefix/bin/../share/tide/shell/greeter.qml"
check "the greetd client beside it is passed on" \
    contains "$ran" "TIDE_GREETER_GREETD=$prefix/bin/tide-greetd"
check "the layout is localed's" contains "$ran" "TIDE_GREETER_KB_LAYOUT=us"
check "the model is localed's" contains "$ran" "TIDE_GREETER_KB_MODEL=pc105"
check "the variant is localed's" contains "$ran" "TIDE_GREETER_KB_VARIANT=dvorak"
check "the options are localed's" contains "$ran" "TIDE_GREETER_KB_OPTIONS=compose:caps,altwin:menu_win"
check "localed is asked for the four X11 properties, in order" test "$(cat "$tmp/log.busctl")" = \
    "get-property org.freedesktop.locale1 /org/freedesktop/locale1 org.freedesktop.locale1 X11Layout X11Model X11Variant X11Options"
check "a keymap that's read says nothing" test -z "$out"

BUSCTL_OUT='s "de"
s ""
s ""
s ""
'
greeter 0
check "an empty setting is passed on empty" contains "$ran" "TIDE_GREETER_KB_VARIANT=
"
check "another layout is passed on" contains "$ran" "TIDE_GREETER_KB_LAYOUT=de"

BUSCTL_OUT='Failed to connect to bus: No such file or directory'
BUSCTL_EXIT=1
greeter 0
check "without localed no keymap is passed" lacks "$ran" "TIDE_GREETER_KB_"
check "without localed the QML is still passed" contains "$ran" "TIDE_GREETER_QML="
check "without localed it says why" \
    contains "$out" "couldn't read the system keymap from localed: Failed to connect to bus: No such file or directory"
BUSCTL_EXIT=0

BUSCTL_OUT='s "us"
u 3
'
greeter 0
check "a keymap that isn't four strings is ignored" lacks "$ran" "TIDE_GREETER_KB_"
check "a keymap that isn't four strings is reported" contains "$out" "localed's keymap isn't four strings"
check "and Hyprland still runs" contains "$ran" "args [--config]"

BUSCTL_OUT='s "us"
s ""
s ""
s ""
'
rm "$prefix/share/tide/shell/greeter.qml" || exit 1
greeter 1
check "a missing greeter is named" contains "$out" "can't read $prefix/bin/../share/tide/shell/greeter.qml"
check "a missing greeter starts no Hyprland" test -z "$ran"
: >"$prefix/share/tide/shell/greeter.qml" || exit 1

chmod -x "$prefix/bin/tide-greetd" || exit 1
greeter 1
check "a greetd client that can't run is named" contains "$out" "can't run $prefix/bin/tide-greetd"
check "a greetd client that can't run starts no Hyprland" test -z "$ran"
chmod +x "$prefix/bin/tide-greetd" || exit 1

# A greeter that can't run leaves greetd's text login, where there is one.
with_agreety="$tmp/agreety:$tmp/stubs:$tmp/sys"
HYPRLAND_EXIT=1
greeter 1
check "a Hyprland that fails is reported" contains "$out" "tide-greeter: Hyprland exited 1"
check "and without agreety, that's said too" contains "$out" "there's no agreety to log in with instead"
GREETER_PATH=$with_agreety
greeter 0
check "a Hyprland that fails leaves the text login" contains "$out" "agreety --cmd /bin/sh"
check "which says why on the console" contains "$out" "tide's greeter could not start: Hyprland exited 1"
HYPRLAND_EXIT=0
greeter 0
check "a Hyprland that exits cleanly starts no text login" lacks "$out" "agreety"
# Off the PATH, it's found where the distros put it.
GREETER_PATH="$tmp/stubs:$tmp/sys" AGREETY_DIRS="$tmp/nowhere $tmp/agreety" HYPRLAND_EXIT=1
greeter 0
check "agreety is found off the PATH too" contains "$out" "agreety --cmd /bin/sh"
unset AGREETY_DIRS
HYPRLAND_EXIT=0
GREETER_PATH=$with_agreety

rm "$prefix/share/tide/shell/greeter.qml" || exit 1
greeter 0
check "a missing greeter leaves the text login" contains "$out" "agreety --cmd /bin/sh"
check "and starts no Hyprland" test -z "$ran"
: >"$prefix/share/tide/shell/greeter.qml" || exit 1

GREETER_PATH="$tmp/agreety:$tmp/sys"
greeter 0
check "no Hyprland is reported" contains "$out" "there's no Hyprland on the greeter's PATH"
check "and leaves the text login" contains "$out" "agreety --cmd /bin/sh"
mkdir "$tmp/no-qs" || exit 1
ln -s "$tmp/stubs/Hyprland" "$tmp/no-qs/Hyprland" || exit 1
GREETER_PATH="$tmp/agreety:$tmp/no-qs:$tmp/sys"
greeter 0
check "no qs is reported" contains "$out" "there's no qs on the greeter's PATH"
check "and starts no Hyprland" test -z "$ran"
unset GREETER_PATH

greeter 0 --help
check "--help gives the usage" contains "$out" "Usage: tide-greeter"
check "--help starts no Hyprland" test -z "$ran"

greeter 2 extra
check "an argument starts no Hyprland" test -z "$ran"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh bin/tide-greeter bin/tide-greeter_test.sh
fi

printf 'tide-greeter_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
