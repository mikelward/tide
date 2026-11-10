#!/bin/sh
#
# Tests for bin/tide-lock, with a fake qs and a temporary HOME. A lock
# that can't start must exit 78, which tide-lock.service doesn't restart,
# so its OnFailure= starts hyprlock at once (session/session_test.sh checks
# the unit's side). No Quickshell runs here.

cd "$(dirname "$0")/.." || exit 1
lock=$PWD/bin/tide-lock

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

# qs logs how it was run and exits $FAKE_QS_EXIT (0, an unlock). Its
# --version is 0.3.1's, or prints $FAKE_QS_VERSION and exits
# $FAKE_QS_VERSION_STATUS. It's in its own directory, so a run can leave it
# off the PATH.
qs=$tmp/qs-bin
mkdir "$qs"
cat > "$qs/qs" <<'FAKE'
#!/bin/sh
if test "$*" = --version; then
    printf '%s\n' "${FAKE_QS_VERSION:-Quickshell 0.3.1 (revision 1a4716c, distributed by test)}"
    exit "${FAKE_QS_VERSION_STATUS:-0}"
fi
printf 'qs %s\n' "$*" >> "$FAKE_LOG"
printf 'qs QS_DISABLE_FILE_WATCHER=%s\n' "${QS_DISABLE_FILE_WATCHER-}" >> "$FAKE_LOG"
exit "${FAKE_QS_EXIT:-0}"
FAKE
chmod +x "$qs/qs"
home=$tmp/home
mkdir -p "$home/.config/quickshell/tide" "$tmp/etc/pam.d" "$tmp/no-etc"
: > "$tmp/etc/pam.d/tide-lock"
: > "$home/.config/quickshell/tide/lock.qml"

# run ENV...: runs tide-lock as the unit would, with the fake qs.
run() {
    : > "$tmp/log"
    env PATH="$qs:$PATH" HOME="$home" TIDE_SYSCONFDIR="$tmp/etc" FAKE_LOG="$tmp/log" QS_DISABLE_FILE_WATCHER=1 \
        "$@" sh "$lock" > "$tmp/out" 2> "$tmp/err"
    status=$?
    err=$(cat "$tmp/err")
    log=$(cat "$tmp/log")
}

run
check "the lock runs the installed lock.qml" \
    test "$(grep '^qs -p' "$tmp/log")" = "qs -p $home/.config/quickshell/tide/lock.qml"
check "the unit's environment reaches qs" contains "$log" "qs QS_DISABLE_FILE_WATCHER=1"
check "an unlock is a clean exit, which starts no fallback" test "$status" -eq 0
check "a good lock says nothing" test -z "$err"

run FAKE_QS_EXIT=134
check "a crash is the lock's own status, so the unit restarts it" test "$status" -eq 134

run FAKE_QS_VERSION="Quickshell 0.3.0 (revision 0000000)"
check "Quickshell 0.3.0 runs the lock" contains "$log" "qs -p"

# Debian's 0.2.1 can't load the lock, so it never locked: tide-lock fails
# at once, saying why, and the unit's fallback locks instead.
run FAKE_QS_VERSION="quickshell 0.2.1, revision 0000000, distributed by: Debian"
check "an old Quickshell fails, not to be retried" test "$status" -eq 78
check "an old Quickshell runs no lock" test -z "$log"
check "an old Quickshell is named, with the fallback" \
    contains "$err" "qs ($qs/qs) is Quickshell 0.2.1, and tide's lock needs 0.3 or newer, so the lock is hyprlock's"

run PATH="$PATH"
check "no qs fails, not to be retried" test "$status" -eq 78
check "no qs is reported" contains "$err" "qs (Quickshell) isn't installed, so the lock is hyprlock's"

run HOME="$tmp/no-home"
check "no lock.qml fails, not to be retried" test "$status" -eq 78
check "no lock.qml is reported, with the fix" \
    contains "$err" "there's no lock at $tmp/no-home/.config/quickshell/tide/lock.qml, so the lock is hyprlock's; run \`make install\` in tide"
check "no lock.qml runs no lock" test -z "$log"

# Without its PAM service the lock would take no password at all, so it
# never starts, and hyprlock, with a PAM service of its own, locks.
run TIDE_SYSCONFDIR="$tmp/no-etc"
check "no PAM service fails, not to be retried" test "$status" -eq 78
check "no PAM service is reported, with the fix" \
    contains "$err" "can't read $tmp/no-etc/pam.d/tide-lock, which the lock checks passwords with, so the lock is hyprlock's; run \`sudo make install-session\` in tide"
check "no PAM service runs no lock" test -z "$log"

# A version it can't read lets the lock run, as tide-shell does with the
# bar: if that qs can't load it, the unit's restarts run out to the
# fallback anyway.
run FAKE_QS_VERSION="Quickshell nightly"
check "an unreadable Quickshell version still runs the lock" contains "$log" "qs -p"
check "an unreadable Quickshell version is logged" \
    contains "$err" "couldn't tell which Quickshell $qs/qs is (qs --version printed 'Quickshell nightly'); running its lock anyway"
run FAKE_QS_VERSION="qs: cannot open display" FAKE_QS_VERSION_STATUS=1
check "a failing qs --version still runs the lock" contains "$log" "qs -p"
check "a failing qs --version is logged" \
    contains "$err" "couldn't tell which Quickshell $qs/qs is (qs --version: qs: cannot open display)"

check "tide-lock is executable" test -x "$lock"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes on tide-lock and this test" shellcheck -s sh "$lock" bin/tide-lock_test.sh
fi

echo "tide-lock_test.sh: $passes passed, $failures failed"
test "$failures" -eq 0
