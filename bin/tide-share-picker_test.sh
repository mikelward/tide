#!/bin/sh
#
# Tests for bin/tide-share-picker, with qs and hyprland-share-picker stubbed
# on PATH.

cd "$(dirname "$0")/.." || exit 1
picker=$PWD/bin/tide-share-picker

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
mkdir "$tmp/bin" "$tmp/run" "$tmp/alt"

# The shell: it logs each call's arguments, one per line, says a pick is
# shown (or $FAKE_QS_SHOWN), and answers it on the reply pipe with
# $FAKE_ANSWER, as the dialog would, unless FAKE_QS_SILENT is set.
# FAKE_QS_ERROR makes the call fail with that text.
cat > "$tmp/bin/qs" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >> "$FAKE_LOG"
echo -- >> "$FAKE_LOG"
if test -n "${FAKE_QS_ERROR:-}"; then
    echo "$FAKE_QS_ERROR" >&2
    exit 1
fi
# The answer comes later, from a child that holds none of qs's output open,
# or the picker's $(qs ...) would wait on it while it waits on the picker.
if test "$6" = pick; then
    echo "${FAKE_QS_SHOWN-shown}"
    if test -z "${FAKE_QS_SILENT:-}"; then
        (printf '%s\n' "$FAKE_ANSWER" > "$7") < /dev/null > /dev/null 2>&1 &
    fi
fi
exit 0
EOF
chmod +x "$tmp/bin/qs"
# xdph's own picker, for when no shell is running.
cat > "$tmp/alt/hyprland-share-picker" <<'EOF'
#!/bin/sh
echo "[SELECTION]/screen:stock $*"
EOF
chmod +x "$tmp/alt/hyprland-share-picker"

# Runs the picker with the stub shell; $out, $err and $status are its
# results. Extra arguments go to the picker.
run() {
    : > "$tmp/log"
    out=$(FAKE_LOG="$tmp/log" XDG_RUNTIME_DIR="$tmp/run" PATH="$tmp/bin:$PATH" \
        XDPH_WINDOW_SHARING_LIST='11[HC>]kitty[HT>]~/src[HE>]255[HA>]' \
        "$picker" "$@" 2> "$tmp/err")
    status=$?
    err=$(cat "$tmp/err")
}

FAKE_ANSWER='[SELECTION]/screen:DP-1'
export FAKE_ANSWER
run
check "a screen answer is printed" test "$out" = '[SELECTION]/screen:DP-1'
check "it exits 0" test "$status" -eq 0
check "it says nothing on stderr" test -z "$err"
log=$(cat "$tmp/log")
check "it asks the shell's sharepicker" contains "$log" "$(printf 'ipc\ncall\nsharepicker\npick\n')"
check "it passes xdph's window list" contains "$log" '11[HC>]kitty[HT>]~/src[HE>]255[HA>]'
check "without --allow-token, reuse starts unchecked" contains "$log" "$(printf '\nfalse\n')"
check "the reply pipe is in the runtime directory" contains "$log" "$tmp/run/tide-share-picker."
check "the reply pipe is removed" test -z "$(ls "$tmp/run")"

# xdph strips the last character of a screen answer, so it must be the
# newline.
FAKE_LOG="$tmp/log" XDG_RUNTIME_DIR="$tmp/run" PATH="$tmp/bin:$PATH" "$picker" > "$tmp/raw" 2>/dev/null
check "the answer ends in a newline" test "$(od -An -c "$tmp/raw" | tr -d ' \n' | tail -c 2)" = '\n'

run --allow-token
check "--allow-token starts reuse checked" contains "$(cat "$tmp/log")" "$(printf '\ntrue\n')"
check "--allow-token still prints the answer" test "$out" = '[SELECTION]/screen:DP-1'

FAKE_ANSWER='[SELECTION]r/region:DP-1@440,0,2560,1440' run
check "a region answer with reuse is printed" test "$out" = '[SELECTION]r/region:DP-1@440,0,2560,1440'

FAKE_ANSWER='' run
check "a cancel prints nothing" test -z "$out"
check "a cancel exits 0" test "$status" -eq 0
check "a cancel removes the pipe" test -z "$(ls "$tmp/run")"

FAKE_ANSWER='garbage' run
check "an answer xdph can't read prints nothing" test -z "$out"
check "an unreadable answer fails" test "$status" -eq 1
check "an unreadable answer is named" contains "$err" "answered something xdph can't read, so nothing is shared: garbage"

run --future-flag
check "an unknown argument is ignored" test "$out" = '[SELECTION]/screen:DP-1'
check "an unknown argument is named" contains "$err" "ignoring unknown argument --future-flag"

# No answer in time: it closes the dialog and cancels.
FAKE_QS_SILENT=1 TIDE_SHARE_PICKER_TIMEOUT=1 run
check "no answer in time prints nothing" test -z "$out"
check "no answer in time fails" test "$status" -eq 1
check "no answer in time is said" contains "$err" "no answer from the picker in 1 seconds"
check "no answer in time closes the dialog" contains "$(cat "$tmp/log")" "$(printf 'sharepicker\ncancel\n%s' "$tmp/run/tide-share-picker.")"
check "no answer in time removes the pipe" test -z "$(ls "$tmp/run")"

# Stopped while it waits, as when xdph stops: it closes the dialog at once,
# not after the timeout.
: > "$tmp/log"
FAKE_LOG="$tmp/log" FAKE_QS_SILENT=1 TIDE_SHARE_PICKER_TIMEOUT=60 XDG_RUNTIME_DIR="$tmp/run" \
    PATH="$tmp/bin:$PATH" "$picker" > "$tmp/out" 2> "$tmp/err" &
pid=$!
i=0
until grep -qx pick "$tmp/log" 2>/dev/null || test "$i" -ge 100; do
    sleep 0.1
    i=$((i + 1))
done
start=$(date +%s)
kill -TERM "$pid"
wait "$pid"
status=$?
took=$(($(date +%s) - start))
check "stopped while waiting, it fails" test "$status" -eq 1
check "stopped while waiting, it stops at once ($took s)" test "$took" -lt 5
check "stopped while waiting, it prints nothing" test ! -s "$tmp/out"
check "stopped while waiting, it says so" contains "$(cat "$tmp/err")" "stopped, so nothing is shared"
check "stopped while waiting, it closes the dialog" contains "$(cat "$tmp/log")" "$(printf 'sharepicker\ncancel\n%s' "$tmp/run/tide-share-picker.")"
check "stopped while waiting, it leaves nothing behind" test -z "$(ls "$tmp/run")"

# No shell running, with xdph's own picker installed: that one runs.
: > "$tmp/log"
out=$(FAKE_LOG="$tmp/log" FAKE_QS_ERROR="No running instances for tide" XDG_RUNTIME_DIR="$tmp/run" \
    PATH="$tmp/bin:$tmp/alt:$PATH" "$picker" --allow-token 2> "$tmp/err")
status=$?
check "with no shell, xdph's picker answers" test "$out" = '[SELECTION]/screen:stock --allow-token'
check "with no shell, xdph's picker's exit is kept" test "$status" -eq 0
check "with no shell, the pipe is removed" test -z "$(ls "$tmp/run")"

# No shell and no fallback: nothing is shared, and it says why.
FAKE_QS_ERROR="No running instances for tide" run
check "with no shell and no fallback, nothing is printed" test -z "$out"
check "with no shell and no fallback, it fails" test "$status" -eq 1
check "with no shell and no fallback, it says so" contains "$err" "tide's shell isn't running, and there's no hyprland-share-picker"
check "with no shell and no fallback, the pipe is removed" test -z "$(ls "$tmp/run")"

# A shell that's there but refuses: reported, no fallback.
FAKE_QS_ERROR="function pick not found" run
check "a refusing shell prints nothing" test -z "$out"
check "a refusing shell is named" contains "$err" "tide's shell couldn't show the picker, so nothing is shared: function pick not found"

# A shell that answers but doesn't show it, as one refusing the pipe does.
FAKE_QS_SHOWN="refused: not a pipe" FAKE_QS_SILENT=1 run
check "a shell that doesn't show it prints nothing" test -z "$out"
check "a shell that doesn't show it fails" test "$status" -eq 1
check "a shell that doesn't show it is named" contains "$err" "tide's shell didn't show the picker, so nothing is shared: refused: not a pipe"
check "a shell that doesn't show it leaves no pipe" test -z "$(ls "$tmp/run")"

# No runtime directory: nowhere for an answer.
out=$(FAKE_LOG="$tmp/log" XDG_RUNTIME_DIR='' PATH="$tmp/bin:$PATH" "$picker" 2> "$tmp/err")
status=$?
check "without XDG_RUNTIME_DIR, it fails" test "$status" -eq 1
check "without XDG_RUNTIME_DIR, it says so" contains "$(cat "$tmp/err")" "no XDG_RUNTIME_DIR for the shell to answer in"

printf 'tide-share-picker_test: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
