#!/bin/sh
#
# Tests for bin/tide-clipboard: the real openssl, with stand-ins for the
# keyring (secret-tool), wl-paste, wl-copy, cliphist (whose history is moved
# in), systemctl and notify-send on PATH.

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

# secret-tool, as libsecret's, on a keyring of one file, $FAKE_DIR/keyring:
# lookup prints the secret, or nothing and exit 1 without one; store reads
# it on stdin. With $FAKE_KEYRING_LOCKED, both fail as a locked keyring
# does. Each call's arguments are logged.
cat > "$fake/secret-tool" <<'FAKE'
#!/bin/sh
printf "secret-tool %s\n" "$*" >> "$FAKE_LOG"
if test -n "${FAKE_KEYRING_LOCKED:-}"; then
    echo "secret-tool: Cannot create an item in a locked collection" >&2
    exit 1
fi
case "$1" in
    lookup) test -s "$FAKE_DIR/keyring" || exit 1; cat "$FAKE_DIR/keyring" ;;
    store) cat > "$FAKE_DIR/keyring" ;;
esac
FAKE
# cliphist, with a history to move in: "ID<TAB>preview<TAB>content" lines in
# $FAKE_DIR/cliphist, listed and decoded as the real one does, and wiped.
cat > "$fake/cliphist" <<'FAKE'
#!/bin/sh
printf "cliphist %s\n" "$*" >> "$FAKE_LOG"
db=$FAKE_DIR/cliphist
case "$1" in
    list)
        # $FAKE_LIST_FAILS makes the listing fail.
        if test -n "${FAKE_LIST_FAILS:-}"; then
            echo "cliphist: couldn't open the database" >&2
            exit 1
        fi
        test -e "$db" && cut -f 1,2 "$db"
        ;;
    decode)
        IFS='	' read -r id _
        # $FAKE_DECODE_FAILS names an entry that won't decode.
        if test "$id" = "${FAKE_DECODE_FAILS:-}"; then
            echo "cliphist: couldn't decode $id" >&2
            exit 1
        fi
        awk -F '\t' -v id="$id" '$1 == id { printf "%s", $3 }' "$db"
        ;;
    wipe)
        # Whether tide's own history was written by then.
        if test -e "$XDG_STATE_HOME/tide/clipboard/index"; then echo "index written" >> "$FAKE_LOG"; fi
        rm -f "$db"
        ;;
esac
exit 0
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
# cat, except that with $FAKE_CAT_SHORT it reads a temporary file as
# empty, as a full disk would leave one, and says nothing.
cat > "$fake/cat" <<'FAKE'
#!/bin/sh
if test -n "${FAKE_CAT_SHORT:-}"; then
    for arg; do
        case "$arg" in "$XDG_RUNTIME_DIR"/*) exit 0 ;; esac
    done
fi
exec "$FAKE_REAL_CAT" "$@"
FAKE
FAKE_REAL_CAT=$(command -v cat)
export FAKE_REAL_CAT
# openssl, logging each decryption, except that with $FAKE_SEAL_FAILS it
# can't encrypt.
cat > "$fake/openssl" <<'FAKE'
#!/bin/sh
test "$1 $2" != "enc -d" || echo "openssl decrypt" >> "$FAKE_LOG"
if test -n "${FAKE_SEAL_FAILS:-}" && test "$1" = enc && test "$2" != -d; then
    echo "openssl: no space left on device" >&2
    exit 1
fi
exec "$FAKE_REAL_OPENSSL" "$@"
FAKE
FAKE_REAL_OPENSSL=$(command -v openssl)
export FAKE_REAL_OPENSSL
chmod +x "$fake"/*
# Only the fakes, and what sh and the history need.
base=$tmp/base
mkdir "$base"
for t in cat grep mktemp rm printf mkfifo timeout date mkdir awk head chmod mv cut tr stat cmp flock \
    openssl od wc sed sort iconv ls sh; do
    p=$(command -v "$t") && ln -s "$p" "$base/$t"
done
SAVED_PATH=$PATH
export PATH="$fake:$base" XDG_RUNTIME_DIR="$tmp/run" XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
PATH=$SAVED_PATH mkdir -p "$tmp/run" "$tmp/config/hypr"
state=$tmp/state/tide/clipboard
conf=$tmp/config/hypr/tide-clipboard.conf

reset() {
    : > "$log"
    PATH=$SAVED_PATH rm -rf "$tmp/state" "$tmp/copied" "$tmp/keyring" "$tmp/cliphist" "$conf"
    unset TIDE_CLIPBOARD_NOW FAKE_SEAL_FAILS FAKE_CAT_SHORT FAKE_DECODE_FAILS FAKE_LIST_FAILS FAKE_KEYRING_LOCKED FAKE_UNIT_STATE FAKE_WLCOPY_HOLD CLIPBOARD_STATE FAKE_TYPES \
        FAKE_WLPASTE_STATUS FAKE_WLCOPY_STATUS TIDE_CLIPBOARD_LOCK_WAIT
}

DAY=86400
# copy TEXT [AT]: stores TEXT as a text copy, at second AT if given.
copy_text() {
    if test -n "${2:-}"; then
        printf '%s' "$1" | TIDE_CLIPBOARD_NOW=$2 CLIPBOARD_STATE=data "$cmd" store
    else
        printf '%s' "$1" | CLIPBOARD_STATE=data "$cmd" store
    fi
}
# The previews, newest first, on one line.
history() { "$cmd" list | cut -f 2 | tr '\n' '|'; }
# How many files folder $1 holds.
files() {
    set -- "$1"/*
    if test -e "$1"; then echo $#; else echo 0; fi
}
# Whether any file under the history holds TEXT as it was copied.
on_disk() { grep -rqF "$1" "$state" 2>/dev/null; }

# --- store and list ------------------------------------------------------------

reset
copy_text "first"
copy_text "second"
check "store exits 0" test $? -eq 0
check "list shows the copies, newest first" test "$(history)" = "second|first|"
check "with an ID before each, as the picker reads them" test -n "$("$cmd" list | grep -E '^[0-9]+	second$')"
check "nothing copied is on disk as it was copied" sh -c "! grep -rqF -e first -e second '$state'"
check "the history's folder is yours alone" test "$(stat -c %a "$state" 2>/dev/null || stat -f %Lp "$state")" = 700
for f in "$state/index" "$state"/entries/*; do
    check "$f is yours alone" test "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600
done
check "the first copy made a key and kept it in the keyring" test "$(wc -c < "$tmp/keyring")" -eq 64
check "the key went to secret-tool on stdin, not in its arguments" sh -c "! grep -qF '$(cat "$tmp/keyring")' '$log'"
check "it's labeled as tide's" contains "$(cat "$log")" "secret-tool store --label=tide clipboard history application tide purpose clipboard-history"
key=$(cat "$tmp/keyring")
copy_text "third"
check "later copies use the same key" test "$(cat "$tmp/keyring")" = "$key"
leftover=no
for f in "$tmp"/run/tide-clipboard.*; do
    test -e "$f" && leftover=yes
done
check "nothing's left on the runtime directory" test "$leftover" = no

reset
copy_text "a  b
	c"
check "a preview folds whitespace to single spaces" test "$(history)" = "a b c|"

reset
long=$(printf '%01200d' 0)
copy_text "$long"
check "a preview is the first 1,000 characters" test "$("$cmd" list | cut -f 2 | wc -c)" -eq 1001

reset
copy_text "again"
copy_text "other"
copy_text "again"
check "copying something again moves it to the top" test "$(history)" = "again|other|"

reset
copy_text "aaa"
copy_text "bbb"
copy_text "ccc"
: > "$log"
copy_text "ddd"
check "a copy beside others its size decrypts only the index" test "$(grep -c "openssl decrypt" "$log")" -eq 1
copy_text "bbb"
check "and still finds its repeat" test "$(history)" = "bbb|ddd|ccc|aaa|"

reset
copy_text "again"
copy_text "other"
id=$("$cmd" list | awk -F '\t' '$2 == "again" { print $1 }')
# The index can't be written: a folder where its new copy would go.
PATH=$SAVED_PATH mkdir "$state/index.new"
copy_text "again" 2>/dev/null
check "a repeat whose store fails says so" test $? -eq 1
PATH=$SAVED_PATH rmdir "$state/index.new"
check "and leaves the history as it was" test "$(history)" = "other|again|"
"$cmd" copy "$id"
check "with the earlier copy still there to paste" test "$(cat "$tmp/copied")" = "again"
copy_text "after"
set -- "$state/entries"/*
check "and the next store removes the file the failed one left" test $# -eq "$("$cmd" list | wc -l)"

reset
copy_text "first"
copy_text "second"
FAKE_CAT_SHORT=yes
export FAKE_CAT_SHORT
out=$(copy_text "third" 2>&1)
check "a history cut short while it's rewritten fails, saying so" contains "$out" "couldn't add the copy"
unset FAKE_CAT_SHORT
check "and isn't written back" test "$(history)" = "second|first|"

reset
copy_text "   "
check "a copy that's only whitespace isn't kept" test ! -e "$state/index"

reset
# A copy that never ends: read in full, it would fill the runtime
# directory, here capped at about 20 MiB.
(
    ulimit -f 40000
    PATH=$SAVED_PATH yes "a long copy" | CLIPBOARD_STATE=data "$cmd" store
)
check "a copy too big to keep is read only so far, then passed over" test $? -eq 0
check "and isn't kept" test ! -e "$state/index"

reset
CLIPBOARD_STATE=sensitive
export CLIPBOARD_STATE
printf 'hunter2' | "$cmd" store
check "a copy wl-clipboard calls sensitive isn't kept" test ! -e "$state/index"
unset CLIPBOARD_STATE
FAKE_TYPES="text/plain
x-kde-passwordManagerHint"
export FAKE_TYPES
copy_text "hunter2"
check "nor one marked with the password managers' hint" test ! -e "$state/index"
unset FAKE_TYPES
FAKE_WLPASTE_STATUS=1
export FAKE_WLPASTE_STATUS
out=$(copy_text "maybe" 2>&1)
check "nor one whose types can't be read, saying so" contains "$out" "couldn't list the copy's types"
unset FAKE_WLPASTE_STATUS

# --- the Clipboard page's settings ---------------------------------------------

reset
printf 'history=off\n' > "$conf"
copy_text "hello"
check "history off keeps nothing" test ! -e "$state/index"
reset
printf 'max_items=2' > "$conf"
copy_text one
copy_text two
copy_text three
check "the page's max_items is how many are kept, even on a last line with no newline" test "$(history)" = "three|two|"
check "and the ones past it leave the disk" test "$(files "$state/entries")" -eq 2
reset
copy_text one
copy_text two
printf 'tre' | CLIPBOARD_STATE=data "$cmd" store --max-items 1
check "--max-items, with no file" test "$(history)" = "tre|"
reset
printf 'history=maybe\nmax_items=none\ncolour=red\n' > "$conf"
out=$(copy_text "hello" 2>&1)
check "a bad file still keeps the copy" test "$(history)" = "hello|"
check "and says what's wrong with history" contains "$out" "history is on or off, not 'maybe'"
check "and with max_items" contains "$out" "max_items is a whole number above 0, not 'none'"
check "and names a setting it doesn't know" contains "$out" "colour isn't a setting (history, max_items, max_age_days)"

# --- forgetting old copies -----------------------------------------------------

reset
copy_text old 1000000
copy_text new $((1000000 + 6 * DAY))
check "six days on, both copies are kept" test "$(TIDE_CLIPBOARD_NOW=$((1000000 + 6 * DAY)) history)" = "new|old|"
copy_text newer $((1000000 + 7 * DAY + 1))
check "a copy a week old goes at the next copy" test "$(TIDE_CLIPBOARD_NOW=$((1000000 + 7 * DAY + 1)) history)" = "newer|new|"
check "and from the disk" test "$(files "$state/entries")" -eq 2
reset
copy_text again 1000000
copy_text other $((1000000 + 1))
copy_text again $((1000000 + 6 * DAY))
check "copying something again starts its week afresh" \
    test "$(TIDE_CLIPBOARD_NOW=$((1000000 + 8 * DAY)) history)" = "again|"
reset
copy_text old 1000000
check "listing forgets a week-old copy, with nothing copied since" \
    test "$(TIDE_CLIPBOARD_NOW=$((1000000 + 8 * DAY)) history)" = ""
reset
printf 'max_age_days=1\n' > "$conf"
copy_text a 1000000
copy_text b $((1000000 + DAY + 1))
check "the page's days are how long a copy stays" test "$(TIDE_CLIPBOARD_NOW=$((1000000 + DAY + 1)) history)" = "b|"

# --- images --------------------------------------------------------------------

reset
# A PNG's signature and IHDR, 640 wide and 480 high, then some bytes.
printf '\211PNG\r\n\032\n\000\000\000\015IHDR\000\000\002\200\000\000\001\340\010\006\000\000\000xxxx' > "$tmp/image.png"
FAKE_TYPES="image/png"
export FAKE_TYPES
CLIPBOARD_STATE=data "$cmd" store < "$tmp/image.png"
unset FAKE_TYPES
check "an image shows as its size, type and dimensions, as cliphist showed it" \
    test "$(history)" = "[[ binary data 33 B png 640x480 ]]|"
id=$("$cmd" list | cut -f 1)
"$cmd" copy "$id"
check "copying an image puts its bytes back" cmp -s "$tmp/copied" "$tmp/image.png"
check "as its type" contains "$(cat "$log")" "wl-copy --type image/png"

reset
# The list wl-paste gives may already be the next copy's.
FAKE_TYPES="image/png"
export FAKE_TYPES
copy_text "words"
check "text whose copy is replaced by an image at once stays text" test "$(history)" = "words|"
FAKE_TYPES="text/plain"
CLIPBOARD_STATE=data "$cmd" store < "$tmp/image.png"
check "and an image replaced by text stays an image" \
    test "$(history | cut -d '|' -f 1)" = "[[ binary data 33 B png 640x480 ]]"
FAKE_TYPES="text/plain
image/bmp"
printf 'BM\000\000\000\000' | CLIPBOARD_STATE=data "$cmd" store
unset FAKE_TYPES
check "an image of a type it doesn't know takes the type offered" \
    test "$(history | cut -d '|' -f 1)" = "[[ binary data 6 B bmp ]]"

# --- copy, put, delete, wipe ---------------------------------------------------

reset
copy_text "copy me"
id=$("$cmd" list | cut -f 1)
"$cmd" copy "$id"
check "copy exits 0" test $? -eq 0
check "copy puts the entry back on the clipboard" test "$(cat "$tmp/copied")" = "copy me"
check "as text, with no type" grep -qx "wl-copy " "$log"
out=$("$cmd" copy 999 2>&1)
check "copy of an entry there isn't says so" contains "$out" "there's no entry 999"
out=$("$cmd" copy 4x1 2>&1)
check "copy refuses a bad ID" test $? -eq 2
check "copy names the bad ID: $out" contains "$out" "4x1"

# wl-copy's background child keeps its stderr while it owns the clipboard,
# so copy mustn't wait on that pipe: the picker pastes once copy exits.
mkfifo "$tmp/hold"
FAKE_WLCOPY_HOLD=$tmp/hold
export FAKE_WLCOPY_HOLD
# Into a file, not $(...), whose pipe the child would hold too; and
# --foreground, so a copy that waited is stopped but the child isn't.
timeout --foreground 10 "$cmd" copy "$id" >"$tmp/out" 2>&1
code=$?
printf '\n' 1<>"$tmp/hold"
check "copy returns while wl-copy's child still owns the clipboard: status $code" test "$code" -eq 0
timeout --foreground 10 "$cmd" put "é" >"$tmp/out" 2>&1
code=$?
printf '\n' 1<>"$tmp/hold"
check "so does put: status $code" test "$code" -eq 0
check "put copies the text" test "$(cat "$tmp/copied")" = "é"
check "with the text after --, so one starting - isn't an option" contains "$(cat "$log")" "wl-copy -- é"
PATH=$SAVED_PATH rm -f "$tmp/hold"
unset FAKE_WLCOPY_HOLD
FAKE_WLCOPY_STATUS=1
export FAKE_WLCOPY_STATUS
out=$("$cmd" put x 2>&1)
check "a failed put says so" contains "$out" "wl-copy failed"
unset FAKE_WLCOPY_STATUS
"$cmd" put >/dev/null 2>&1
check "put needs the text" test $? -eq 2

reset
copy_text keep
copy_text gone
id=$("$cmd" list | head -n 1 | cut -f 1)
"$cmd" delete "$id"
check "delete removes the entry" test "$(history)" = "keep|"
check "and its file" test "$(files "$state/entries")" -eq 1
out=$("$cmd" delete "$id" 2>&1)
check "deleting it again says it's not there" contains "$out" "there's no entry $id"

reset
copy_text "something"
"$cmd" wipe
check "wipe removes the history" test ! -e "$state"
check "and leaves the key" test -s "$tmp/keyring"
copy_text "after"
check "and a copy after it gets a new ID, not one an old picker list still shows" \
    test "$("$cmd" list | cut -f 1)" -gt 1

# --- the keyring ---------------------------------------------------------------

reset
copy_text "before"
FAKE_KEYRING_LOCKED=1
export FAKE_KEYRING_LOCKED
out=$(copy_text "while locked" 2>&1)
check "with the keyring locked, a copy isn't kept, saying why" contains "$out" "the keyring wouldn't give the history's key"
out=$("$cmd" list 2>&1)
check "nor can the history be listed" test $? -eq 1
unset FAKE_KEYRING_LOCKED
check "and what was kept is there once it's unlocked" test "$(history)" = "before|"

reset
copy_text "before"
PATH=$SAVED_PATH rm "$tmp/keyring"
out=$("$cmd" list 2>&1)
check "a history whose key is gone can't be read, saying so" contains "$out" "the keyring has no key for the history"
check "and listing never makes one" test ! -e "$tmp/keyring"

reset
PATH=$SAVED_PATH mv "$fake/secret-tool" "$tmp/secret-tool"
out=$(copy_text "x" 2>&1)
check "without secret-tool, nothing's kept, naming the package" contains "$out" "install the libsecret-tools package"
PATH=$SAVED_PATH mv "$tmp/secret-tool" "$fake/secret-tool"

# --- before anything's stored --------------------------------------------------

reset
out=$("$cmd" list 2>&1)
check "list before anything is stored prints nothing" test -z "$out"
FAKE_UNIT_STATE=inactive
export FAKE_UNIT_STATE
out=$("$cmd" list 2>&1)
check "unless the unit isn't running, which it says" contains "$out" "tide-clipboard.service is inactive"

# --- cliphist's history, moved in ----------------------------------------------

reset
printf '7\tnewer\tnewer\n3\tolder\tolder\n9\t[[ binary data 37 B png 640x480 ]]\tPNGBYTES\n' > "$tmp/cliphist"
copy_text "now"
check "cliphist's history comes in, oldest first, under the new copy" \
    test "$(history | sed 's/\[\[ binary data [^]]*\]\]/IMG/')" = "now|IMG|newer|older|"
check "and cliphist's is wiped" test ! -e "$tmp/cliphist"
check "only once tide's own is written" grep -q "index written" "$log"
check "and nothing from it is on disk as it was" sh -c "! grep -rqF -e older -e newer '$state'"
printf '1\tlater\tlater\n' > "$tmp/cliphist"
copy_text "after"
check "it's moved in once" sh -c "! printf '%s' '$(history)' | grep -q later"
check "and cliphist's later history is left alone" test -e "$tmp/cliphist"

reset
printf '7\tnewer\tnewer\n3\tolder\tolder\n' > "$tmp/cliphist"
FAKE_DECODE_FAILS=3
export FAKE_DECODE_FAILS
out=$(copy_text "now" 2>&1)
check "an entry that won't come in from cliphist is said" contains "$out" "couldn't move cliphist's entry 3 in"
check "and cliphist's history stays" test -e "$tmp/cliphist"
unset FAKE_DECODE_FAILS
copy_text "later"
check "to come in at the next copy, without doubling what came before" test "$(history)" = "later|newer|older|now|"
check "and only then is cliphist's wiped" test ! -e "$tmp/cliphist"

reset
printf '3\tolder\tolder\n' > "$tmp/cliphist"
FAKE_LIST_FAILS=yes
export FAKE_LIST_FAILS
out=$(copy_text "now" 2>&1)
check "a history cliphist can't list is said" contains "$out" "couldn't read cliphist's history"
check "and the copy is still kept" test "$(history)" = "now|"
unset FAKE_LIST_FAILS
copy_text "later"
check "and cliphist's history comes in at the next copy" test "$(history)" = "later|older|now|"
check "and is wiped there only then" test ! -e "$tmp/cliphist"

reset
printf '3\tolder\tolder\n' > "$tmp/cliphist"
FAKE_SEAL_FAILS=yes
export FAKE_SEAL_FAILS
copy_text "secret" 2>/dev/null
unset FAKE_SEAL_FAILS
check "a move from cliphist that fails leaves no copy in the clear behind" test -z "$(ls "$tmp/run")"
check "and cliphist's history stays" test -e "$tmp/cliphist"

reset
copy_text "first"
copy_text "second"
first=$("$cmd" list | awk -F '\t' '$2 == "first" { print $1 }')
printf 'garbage' > "$state.next"
copy_text "third"
check "a damaged counter never reuses an ID" test "$("$cmd" list | cut -f 1 | awk 'seen[$0]++')" = ""
"$cmd" copy "$first"
check "so the earlier copies are as they were" test "$(cat "$tmp/copied")" = "first"

reset
printf '3\tolder\tolder\n' > "$tmp/cliphist"
"$cmd" wipe
check "a wipe before the first copy clears cliphist's history too" test ! -e "$tmp/cliphist"
copy_text "new"
check "so the next copy doesn't bring it back" test "$(history)" = "new|"

# --- one at a time -------------------------------------------------------------

reset
copy_text "first"
# Another tide clipboard holding the history, until the FIFO's written.
mkfifo "$tmp/release" "$tmp/locked"
(flock 8; echo locked >"$tmp/locked"; read -r _ <"$tmp/release") 8>>"$state.lock" &
holder=$!
read -r _ <"$tmp/locked"
out=$(printf 'second' | TIDE_CLIPBOARD_LOCK_WAIT=0 CLIPBOARD_STATE=data "$cmd" store 2>&1)
check "while another holds the history, a copy waits, then says why" contains "$out" "another tide clipboard held"
out=$(TIDE_CLIPBOARD_LOCK_WAIT=0 "$cmd" wipe 2>&1)
check "so does a wipe, which leaves the history alone" test -e "$state/index"
echo go > "$tmp/release"
wait "$holder"
PATH=$SAVED_PATH rm "$tmp/release" "$tmp/locked"
check "and the history is as the other left it" test "$(history)" = "first|"

reset
PATH=$SAVED_PATH mv "$base/flock" "$tmp/flock"
out=$(copy_text "unlocked" 2>&1)
check "without flock, a copy is still kept" test "$(history 2>/dev/null)" = "unlocked|"
check "saying the lock's missing" contains "$out" "flock isn't installed (util-linux)"
PATH=$SAVED_PATH mv "$tmp/flock" "$base/flock"

# --- arguments -----------------------------------------------------------------

reset
"$cmd" bogus >/dev/null 2>&1
check "an unknown command is a usage error" test $? -eq 2
"$cmd" store --max-items 0 </dev/null >/dev/null 2>&1
check "--max-items must be above 0" test $? -eq 2

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh "$cmd" bin/tide-clipboard_test.sh
fi

echo "tide-clipboard_test: $passes passed, $failures failed"
test "$failures" -eq 0
