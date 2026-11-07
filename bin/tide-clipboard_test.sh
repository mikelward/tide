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
# With $FAKE_DIR/db, a history: "ID<TAB>text" lines, newest first, that
# store adds to (moving a repeat to the top, under a new ID), list prints
# and delete removes from.
db=$FAKE_DIR/db
case "$last" in
    store)
        cat > "$FAKE_DIR/stored"
        # As cliphist does, a copy that's only whitespace is passed over.
        if test -e "$db" && grep -q '[^[:space:]]' "$FAKE_DIR/stored"; then
            text=$(cat "$FAKE_DIR/stored")
            next=$(( $(cat "$FAKE_DIR/next" 2>/dev/null || echo 100) + 1 ))
            echo "$next" > "$FAKE_DIR/next"
            { printf '%s\t%s\n' "$next" "$text"; awk -F '\t' -v t="$text" '$2 != t' "$db"; } > "$db.new"
            mv "$db.new" "$db"
        fi
        ;;
    delete)
        cat > "$FAKE_DIR/deleted"
        # 0.4.0's delete reads only the first ID it's given.
        if test "${FAKE_CLIPHIST_VERSION:-}" = 0.4.0; then
            head -n 1 "$FAKE_DIR/deleted" > "$FAKE_DIR/deleted.first"
            mv "$FAKE_DIR/deleted.first" "$FAKE_DIR/deleted"
        fi
        if test -e "$db"; then
            awk -F '\t' 'FNR == NR { gone[$1] = 1; next } !($1 in gone)' "$FAKE_DIR/deleted" "$db" > "$db.new"
            mv "$db.new" "$db"
        fi
        ;;
    list)
        if test -n "${FAKE_NO_DB:-}"; then
            echo "opening db: please store something first" >&2
            exit 1
        fi
        if test -e "$db"; then
            cat "$db"
        else
            printf '2\tsecond\n1\tfirst\n'
        fi
        ;;
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
        if test -e "$db"; then
            awk -F '\t' -v id="$id" '$1 == id { printf "%s", $2 }' "$db"
            exit 0
        fi
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
# systemctl --user is-active prints $FAKE_UNIT_STATE, exiting 0 only when
# it's active, as systemctl does.
cat > "$fake/systemctl" <<'FAKE'
#!/bin/sh
printf "systemctl %s\n" "$*" >> "$FAKE_LOG"
printf '%s\n' "${FAKE_UNIT_STATE:-active}"
test "${FAKE_UNIT_STATE:-active}" = active
FAKE
# wl-copy, as wl-clipboard's: what it's given (stdin, or the words after
# --) goes to $FAKE_DIR/copied. With $FAKE_WLCOPY_HOLD it then leaves a
# child holding its stderr open until the FIFO at $FAKE_WLCOPY_HOLD is
# written, as the real one's background child keeps it while it owns the
# clipboard (wl-copy.c's did_set_selection_callback, 2.2.1).
cat > "$fake/wl-copy" <<'FAKE'
#!/bin/sh
printf "wl-copy %s\n" "$*" >> "$FAKE_LOG"
if test "${1:-}" = --; then
    shift
    printf '%s' "$*" > "$FAKE_DIR/copied"
else
    cat > "$FAKE_DIR/copied"
fi
if test -n "${FAKE_WLCOPY_HOLD:-}"; then
    # Read-write, so opening it never waits for a writer.
    (read -r _ <>"$FAKE_WLCOPY_HOLD") </dev/null >/dev/null &
fi
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
for t in cat grep mktemp rm printf mkfifo timeout date mkdir awk head chmod mv cut tr stat cmp flock; do
    p=$(command -v "$t") && ln -s "$p" "$base/$t"
done
SAVED_PATH=$PATH
export PATH="$fake:$base" XDG_RUNTIME_DIR="$tmp" XDG_STATE_HOME="$tmp/state"

reset() {
    : > "$log"
    rm -rf "$tmp/stored" "$tmp/deleted" "$tmp/copied" "$tmp/db" "$tmp/next" "$tmp/state"
    unset TIDE_CLIPBOARD_NOW FAKE_CLIPHIST_VERSION FAKE_NO_DB FAKE_UNIT_STATE FAKE_WLCOPY_HOLD CLIPBOARD_STATE FAKE_TYPES FAKE_WLPASTE_STATUS FAKE_CLIPHIST_STATUS FAKE_WLCOPY_STATUS
}

# --- store ---------------------------------------------------------------------

reset
printf 'hello' | CLIPBOARD_STATE=data "$cmd" store
check "store exits 0" test $? -eq 0
check "store stores the copy" test "$(cat "$tmp/stored")" = hello
check "store keeps the newest 100 by default" contains "$(cat "$log")" "cliphist -max-items 100 store"

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

# The Clipboard page's settings, in the file the shell writes (SPEC.md §16).
PATH=$SAVED_PATH mkdir -p "$tmp/config/hypr"
conf=$tmp/config/hypr/tide-clipboard.conf
reset
printf 'history=off\nmax_items=50\n' > "$conf"
printf 'hello' | XDG_CONFIG_HOME="$tmp/config" CLIPBOARD_STATE=data "$cmd" store
check "history off exits 0" test $? -eq 0
check "history off stores nothing" test ! -e "$tmp/stored"
check "and never reaches cliphist" test -z "$(grep cliphist "$log")"
reset
printf 'history=on\nmax_items=50' > "$conf"
printf 'hello' | XDG_CONFIG_HOME="$tmp/config" CLIPBOARD_STATE=data "$cmd" store --max-items 200
check "the page's max_items replaces --max-items, even on a last line with no newline" contains "$(cat "$log")" "cliphist -max-items 50 store"
reset
printf 'history=maybe\nmax_items=none\ncolour=red\n' > "$conf"
out=$(printf 'hello' | XDG_CONFIG_HOME="$tmp/config" CLIPBOARD_STATE=data "$cmd" store 2>&1)
check "a bad file still stores, with the default cap" contains "$(cat "$log")" "cliphist -max-items 100 store"
check "and says what's wrong with history" contains "$out" "history is on or off, not 'maybe'"
check "and with max_items" contains "$out" "max_items is a whole number above 0, not 'none'"
check "and names a setting it doesn't know" contains "$out" "colour isn't a setting (history, max_items, max_age_days)"
rm "$conf"

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

# cliphist refuses to list before its first store makes the database.
reset
FAKE_NO_DB=1
export FAKE_NO_DB
out=$("$cmd" list 2>&1)
check "list before anything is stored exits 0" test $? -eq 0
check "list before anything is stored prints nothing: $out" test -z "$out"
reset
FAKE_NO_DB=1 FAKE_UNIT_STATE=inactive
export FAKE_NO_DB FAKE_UNIT_STATE
out=$("$cmd" list 2>&1)
check "list with no history and the unit stopped exits 1" test $? -eq 1
check "list with the unit stopped says so, and how to start it: $out" contains "$out" "tide-clipboard.service is inactive, so nothing you copy is kept: systemctl --user enable --now tide-clipboard.service"
check "list with the unit stopped doesn't pass on cliphist's words" test -n "${out##*please store*}"
reset
FAKE_CLIPHIST_STATUS=1
export FAKE_CLIPHIST_STATUS
out=$("$cmd" list 2>&1)
check "a failed list exits 1" test $? -eq 1
check "a failed list says why: $out" contains "$out" "cliphist broke"

reset
"$cmd" copy 41
check "copy exits 0" test $? -eq 0
check "copy puts the decoded entry on the clipboard" test "$(cat "$tmp/copied")" = "entry 41"
leftover=no
for f in "$tmp"/tide-clipboard.*; do
    test -e "$f" && leftover=yes
done
check "copy leaves no temporary file" test "$leftover" = no

# wl-copy's background child keeps its stderr while it owns the clipboard,
# so copy mustn't wait on that pipe: the picker pastes once copy exits.
# The child is let go after; a copy that waited would only end then.
reset
mkfifo "$tmp/hold"
FAKE_WLCOPY_HOLD=$tmp/hold
export FAKE_WLCOPY_HOLD
# Into a file, not $(...), whose pipe the child would hold too; and
# --foreground, so a copy that waited is stopped but the child isn't.
timeout --foreground 10 "$cmd" copy 41 >"$tmp/out" 2>&1
code=$?
printf '\n' 1<>"$tmp/hold"
check "copy returns while wl-copy's child still owns the clipboard: status $code" test "$code" -eq 0
check "and copied the entry" test "$(cat "$tmp/copied")" = "entry 41"
rm -f "$tmp/hold"

# put: text onto the clipboard, as the picker's Characters tab copies one.
reset
mkfifo "$tmp/hold"
FAKE_WLCOPY_HOLD=$tmp/hold
export FAKE_WLCOPY_HOLD
# Into a file, not $(...), whose pipe the child would hold too; and
# --foreground, so a copy that waited is stopped but the child isn't.
timeout --foreground 10 "$cmd" put "é" >"$tmp/out" 2>&1
code=$?
printf '\n' 1<>"$tmp/hold"
check "put returns while wl-copy's child still owns the clipboard: status $code" test "$code" -eq 0
check "and copied the text" test "$(cat "$tmp/copied")" = "é"
check "with the text after --, so one starting - isn't an option" contains "$(cat "$log")" "wl-copy -- é"
rm -f "$tmp/hold"
reset
FAKE_WLCOPY_STATUS=1
export FAKE_WLCOPY_STATUS
out=$("$cmd" put x 2>&1)
check "a failed put exits 1" test $? -eq 1
check "a failed put says so: $out" contains "$out" "wl-copy failed"
reset
out=$("$cmd" put 2>&1)
check "put needs the text" test $? -eq 2

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

# --- forgetting old copies ------------------------------------------------------

export PATH="$fake:$base"

DAY=86400
# copy TEXT AT: stores TEXT as copied at second AT.
copy_at() {
    printf '%s' "$1" | TIDE_CLIPBOARD_NOW=$2 XDG_CONFIG_HOME="$tmp/noconf" CLIPBOARD_STATE=data "$cmd" store
}
history() { cut -f2 "$tmp/db" | tr '\n' ' '; }

reset
: > "$tmp/db"
copy_at old 1000000
copy_at new $((1000000 + 6 * DAY))
check "six days on, both copies are kept" test "$(history)" = "new old "
copy_at newer $((1000000 + 7 * DAY + 1))
check "a copy a week old goes at the next copy" test "$(history)" = "newer new "
check "and its time with it" test "$(grep -c . "$tmp/state/tide/clipboard-times")" -eq 2
check "the times are yours alone" test "$(stat -c %a "$tmp/state/tide/clipboard-times" 2>/dev/null || stat -f %Lp "$tmp/state/tide/clipboard-times")" = 600

reset
: > "$tmp/db"
copy_at again 1000000
copy_at other $((1000000 + 1))
copy_at again $((1000000 + 6 * DAY))
copy_at last $((1000000 + 8 * DAY))
check "copying something again starts its week afresh" test "$(history)" = "last again "

reset
: > "$tmp/db"
copy_at kept 1000000
copy_at '   ' $((1000000 + 6 * DAY))
copy_at last $((1000000 + 7 * DAY + 1))
check "a copy cliphist passes over starts no entry's week again" test "$(history)" = "last "

reset
: > "$tmp/db"
FAKE_CLIPHIST_VERSION=0.4.0
export FAKE_CLIPHIST_VERSION
copy_at one 1000000
copy_at two $((1000000 + 1))
copy_at three $((1000000 + 8 * DAY))
check "on cliphist 0.4.0, several old copies go at once" test "$(history)" = "three "
unset FAKE_CLIPHIST_VERSION

reset
: > "$tmp/db"
copy_at old 1000000
# Another tide clipboard holding the times' lock, until the FIFO's written.
mkfifo "$tmp/release" "$tmp/locked"
(flock 8; echo locked >"$tmp/locked"; read -r _ <"$tmp/release") 8>>"$tmp/state/tide/clipboard-times.lock" &
holder=$!
read -r _ <"$tmp/locked"
out=$(printf 'new' | TIDE_CLIPBOARD_LOCK_WAIT=0 TIDE_CLIPBOARD_NOW=$((1000000 + 8 * DAY)) XDG_CONFIG_HOME="$tmp/noconf" CLIPBOARD_STATE=data "$cmd" store 2>&1)
check "while another holds the times, a copy is still stored" test "$(history)" = "new old "
check "and the old one waits, saying why" contains "$out" "another tide clipboard held"
echo go > "$tmp/release"
wait "$holder"
rm "$tmp/release" "$tmp/locked"
copy_at newer $((1000000 + 8 * DAY))
check "and goes once the lock's free" test "$(history)" = "newer new "

reset
: > "$tmp/db"
PATH=$SAVED_PATH mv "$base/flock" "$tmp/flock"
copy_at old 1000000
out=$(printf 'new' | TIDE_CLIPBOARD_NOW=$((1000000 + 8 * DAY)) XDG_CONFIG_HOME="$tmp/noconf" CLIPBOARD_STATE=data "$cmd" store 2>&1)
check "without flock, copies are kept and old ones still go" test "$(history)" = "new "
check "saying the lock's missing" contains "$out" "flock isn't installed (util-linux)"
PATH=$SAVED_PATH mv "$tmp/flock" "$base/flock"

reset
: > "$tmp/db"
copy_at old 1000000
TIDE_CLIPBOARD_NOW=$((1000000 + 8 * DAY)) XDG_CONFIG_HOME="$tmp/noconf" "$cmd" list > "$tmp/listed"
check "listing forgets a week-old copy too, with nothing copied since" test "$(cat "$tmp/listed")" = ""

reset
: > "$tmp/db"
mkdir -p "$tmp/agecfg/hypr"
printf 'max_age_days=1\n' > "$tmp/agecfg/hypr/tide-clipboard.conf"
printf 'a' | TIDE_CLIPBOARD_NOW=1000000 XDG_CONFIG_HOME="$tmp/agecfg" CLIPBOARD_STATE=data "$cmd" store
printf 'b' | TIDE_CLIPBOARD_NOW=$((1000000 + DAY + 1)) XDG_CONFIG_HOME="$tmp/agecfg" CLIPBOARD_STATE=data "$cmd" store
check "the Clipboard page's days are how long a copy stays" test "$(history)" = "b "
printf 'max_age_days=soon\n' > "$tmp/agecfg/hypr/tide-clipboard.conf"
out=$(printf 'c' | TIDE_CLIPBOARD_NOW=1000000 XDG_CONFIG_HOME="$tmp/agecfg" CLIPBOARD_STATE=data "$cmd" store 2>&1)
check "a bad max_age_days says so, and the copy is kept" contains "$out" "max_age_days is a whole number above 0, not 'soon'"

reset
: > "$tmp/db"
copy_at x 1000000
"$cmd" wipe
check "wiping forgets the times too" test ! -e "$tmp/state/tide/clipboard-times"

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
