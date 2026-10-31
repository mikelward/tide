#!/bin/sh
#
# Tests for bin/tide-clipboard, against fake cliphist, wl-paste, wl-copy and
# notify-send on PATH.

cd "$(dirname "$0")/.." || exit 1
cmd=$PWD/bin/tide-clipboard

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
export FAKE_LOG="$log" FAKE_DIR="$tmp"

# cliphist logs its arguments, keeps what `store` and `delete` read in
# $FAKE_DIR/stored and $FAKE_DIR/deleted, and exits $FAKE_CLIPHIST_STATUS.
# `decode` is 0.4.0's: it refuses an argument, and decodes the "ID<TAB>"
# line on stdin to "entry ID".
cat > "$fake/cliphist" <<'FAKE'
#!/bin/sh
printf "cliphist %s\n" "$*" >> "$FAKE_LOG"
for last; do :; done
case "$last" in
    store) cat > "$FAKE_DIR/stored" ;;
    delete) cat > "$FAKE_DIR/deleted" ;;
    list) printf '2\tsecond\n1\tfirst\n' ;;
    version)
        # 0.6.0 and later list their flags; 0.4.0 has no version command.
        case "${FAKE_CLIPHIST_VERSION:-0.7.0}" in
            0.4.0) echo "usage: cliphist <store|list|decode|delete|delete-query|wipe>" >&2; exit 1 ;;
            0.5.0) printf '0.5.0\n' >&2 ;;
            *) printf 'version\t%s\npreview-width\t100\n' "$FAKE_CLIPHIST_VERSION" >&2 ;;
        esac
        exit 0
        ;;
    decode)
        if test "$1" != decode; then
            echo "decode takes no arguments" >&2
            exit 1
        fi
        IFS='	' read -r id _
        case "$id" in
            '' | *[!0-9]*) echo "input not prefixed with id" >&2; exit 1 ;;
        esac
        printf 'entry %s' "$id"
        ;;
esac
test "${FAKE_CLIPHIST_STATUS:-0}" -eq 0 || echo "cliphist broke" >&2
exit "${FAKE_CLIPHIST_STATUS:-0}"
FAKE
# wl-paste --list-types prints $FAKE_TYPES, exiting $FAKE_WLPASTE_STATUS.
cat > "$fake/wl-paste" <<'FAKE'
#!/bin/sh
printf "wl-paste %s\n" "$*" >> "$FAKE_LOG"
printf '%s\n' "${FAKE_TYPES-text/plain;charset=utf-8}"
exit "${FAKE_WLPASTE_STATUS:-0}"
FAKE
cat > "$fake/wl-copy" <<'FAKE'
#!/bin/sh
printf "wl-copy %s\n" "$*" >> "$FAKE_LOG"
cat > "$FAKE_DIR/copied"
exit "${FAKE_WLCOPY_STATUS:-0}"
FAKE
cat > "$fake/notify-send" <<'FAKE'
#!/bin/sh
printf "notify-send %s\n" "$*" >> "$FAKE_LOG"
FAKE
chmod +x "$fake"/*
# Only the fakes, and what sh itself needs.
base=$tmp/base
mkdir "$base"
for t in cat grep mktemp rm printf; do
    p=$(command -v "$t") && ln -s "$p" "$base/$t"
done
SAVED_PATH=$PATH
export PATH="$fake:$base" XDG_RUNTIME_DIR="$tmp"

reset() {
    : > "$log"
    rm -f "$tmp/stored" "$tmp/deleted" "$tmp/copied"
    unset FAKE_CLIPHIST_VERSION CLIPBOARD_STATE FAKE_TYPES FAKE_WLPASTE_STATUS FAKE_CLIPHIST_STATUS FAKE_WLCOPY_STATUS
}

# --- store ---------------------------------------------------------------------

reset
printf 'hello' | CLIPBOARD_STATE=data "$cmd" store
check "store exits 0" test $? -eq 0
check "store stores the copy" test "$(cat "$tmp/stored")" = hello
check "store keeps the newest 200 by default" contains "$(cat "$log")" "cliphist -max-items 200 store"

reset
printf 'hello' | "$cmd" store --max-items 50
check "--max-items N sets the cap" contains "$(cat "$log")" "cliphist -max-items 50 store"
reset
printf 'hello' | "$cmd" store --max-items=7
check "--max-items=N sets the cap" contains "$(cat "$log")" "cliphist -max-items 7 store"
reset
out=$(printf 'hello' | "$cmd" store --max-items=lots 2>&1)
check "a bad --max-items exits 2" test $? -eq 2
check "a bad --max-items names it: $out" contains "$out" "--max-items"
check "a bad --max-items stores nothing" test ! -e "$tmp/stored"

reset
printf 'hunter2' | CLIPBOARD_STATE=sensitive "$cmd" store
check "a sensitive copy exits 0" test $? -eq 0
check "a sensitive copy isn't stored" test ! -e "$tmp/stored"
check "a sensitive copy isn't even looked at" test ! -s "$log"

reset
FAKE_TYPES='text/plain
x-kde-passwordManagerHint
text/plain;charset=utf-8'
export FAKE_TYPES
printf 'hunter2' | CLIPBOARD_STATE=data "$cmd" store
check "a copy marked with the hint exits 0" test $? -eq 0
check "a copy marked with the hint isn't stored" test ! -e "$tmp/stored"
check "a copy marked with the hint never reaches cliphist" test -z "$(grep cliphist "$log")"

reset
FAKE_TYPES='x-kde-passwordManagerHint-not
text/plain'
export FAKE_TYPES
printf 'fine' | "$cmd" store
check "only the exact hint type counts" test "$(cat "$tmp/stored")" = fine

reset
FAKE_WLPASTE_STATUS=1 FAKE_TYPES="Nothing is copied"
export FAKE_WLPASTE_STATUS FAKE_TYPES
out=$(printf 'maybe a password' | "$cmd" store 2>&1)
check "unreadable types exit 1" test $? -eq 1
check "unreadable types aren't stored" test ! -e "$tmp/stored"
check "unreadable types say why: $out" contains "$out" "Nothing is copied"

reset
printf '' | CLIPBOARD_STATE=nil "$cmd" store
check "an emptied clipboard stores nothing" test ! -e "$tmp/stored"

reset
FAKE_CLIPHIST_STATUS=1
export FAKE_CLIPHIST_STATUS
printf 'x' | "$cmd" store 2>/dev/null # the status is what's checked
check "a cliphist failure is the exit status" test $? -eq 1

# --- list, copy, delete ----------------------------------------------------------

reset
out=$("$cmd" list)
check "list prints cliphist's list" test "$out" = "$(printf '2\tsecond\n1\tfirst')"
check "list asks for 1,000-character previews where cliphist can" contains "$(cat "$log")" "cliphist -preview-width 1000 list"
for v in 0.4.0 0.5.0; do
    reset
    out=$(FAKE_CLIPHIST_VERSION=$v "$cmd" list)
    check "cliphist $v lists anyway" test "$out" = "$(printf '2\tsecond\n1\tfirst')"
    check "without -preview-width, which cliphist $v lacks" test -z "$(grep -e '-preview-width' "$log")"
done

reset
"$cmd" copy 41
check "copy exits 0" test $? -eq 0
check "copy puts the decoded entry on the clipboard" test "$(cat "$tmp/copied")" = "entry 41"
leftover=no
for f in "$tmp"/tide-clipboard.*; do
    test -e "$f" && leftover=yes
done
check "copy leaves no temporary file" test "$leftover" = no

reset
out=$("$cmd" copy 4x1 2>&1)
check "copy refuses a bad ID" test $? -eq 2
check "copy names the bad ID: $out" contains "$out" "4x1"

reset
FAKE_CLIPHIST_STATUS=1
export FAKE_CLIPHIST_STATUS
out=$("$cmd" copy 9 2>&1)
check "copy of a missing entry exits 1" test $? -eq 1
check "copy of a missing entry copies nothing" test ! -e "$tmp/copied"
check "copy of a missing entry says why: $out" contains "$out" "entry 9"

reset
FAKE_WLCOPY_STATUS=1
export FAKE_WLCOPY_STATUS
out=$("$cmd" copy 9 2>&1)
check "a wl-copy failure exits 1" test $? -eq 1
check "a wl-copy failure says so: $out" contains "$out" "wl-copy failed"

reset
"$cmd" delete 12
check "delete exits 0" test $? -eq 0
check "delete hands cliphist the ID" test "$(cat "$tmp/deleted")" = "$(printf '12\t')"

# --- wipe ----------------------------------------------------------------------

reset
"$cmd" wipe --notify
check "wipe exits 0" test $? -eq 0
check "wipe runs cliphist wipe, and notifies nothing" test "$(cat "$log")" = "cliphist wipe"

reset
FAKE_CLIPHIST_STATUS=1
export FAKE_CLIPHIST_STATUS
out=$("$cmd" wipe --notify 2>&1)
check "a failed wipe exits 1" test $? -eq 1
check "a failed wipe says why: $out" contains "$out" "cliphist broke"
check "a failed wipe from the launcher notifies" contains "$(cat "$log")" "notify-send -a tide Clipboard history not cleared"
reset
FAKE_CLIPHIST_STATUS=1
export FAKE_CLIPHIST_STATUS
"$cmd" wipe 2>/dev/null # the status is what's checked
check "a failed wipe without --notify doesn't notify" test -z "$(grep notify-send "$log")"

# --- without cliphist -------------------------------------------------------------

reset
rm "$fake/cliphist"
out=$("$cmd" list 2>&1)
check "list without cliphist exits 1" test $? -eq 1
check "list without cliphist names the package: $out" contains "$out" "install the cliphist package"
out=$(printf 'x' | "$cmd" store 2>&1)
check "store without cliphist exits 1" test $? -eq 1
out=$("$cmd" wipe 2>&1)
check "wipe without cliphist exits 1, saying so: $out" contains "$out" "cliphist isn't installed"

out=$("$cmd" frob 2>&1)
check "an unknown subcommand exits 2" test $? -eq 2

PATH=$SAVED_PATH
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh "$cmd" bin/tide-clipboard_test.sh
fi

echo "tide-clipboard_test: $passes passed, $failures failed"
test "$failures" -eq 0
