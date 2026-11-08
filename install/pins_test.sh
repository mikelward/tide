#!/bin/sh
#
# Tests for install/pins and tide's own deps.lock. From the repo root:
# `sh install/pins_test.sh`.

cd "$(dirname "$0")/.." || exit 1
pins=$PWD/install/pins

passes=0
failures=0
check() {
    _name=$1
    shift
    if "$@"; then passes=$((passes + 1)); else failures=$((failures + 1)); printf 'FAIL: %s\n' "$_name" >&2; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

c1=1111111111111111111111111111111111111111
c2=2222222222222222222222222222222222222222
cat > "$tmp/ok.lock" <<LOCK
# a comment

g first https://example.com/first.git v1 $c1 cmake
other solo https://example.com/solo.git - $c2 make
g second https://example.com/second.git v2 $c2 meson
LOCK

# run LOCK ARGS...: $out, $err and $status.
run() {
    _lock=$1
    shift
    out=$(TIDE_DEPS_LOCK="$_lock" "$pins" "$@" 2>"$tmp/err")
    status=$?
    err=$(cat "$tmp/err")
}

run "$tmp/ok.lock" g
check "a group's pins print in order" test "$out" = "first https://example.com/first.git v1 $c1 cmake
second https://example.com/second.git v2 $c2 meson"
run "$tmp/ok.lock" --env solo
check "--env prints a pin's assignments" test "$out" = "PIN_REPO=https://example.com/solo.git
PIN_TAG=-
PIN_COMMIT=$c2"
run "$tmp/ok.lock" --check
check "--check passes a good file" test "$status" -eq 0
run "$tmp/ok.lock" nogroup
check "an unknown group fails" test "$status" -ne 0
check "an unknown group is named" contains "$err" "no group nogroup"
run "$tmp/ok.lock" --env nobody
check "an unknown pin fails" contains "$err" "nothing called nobody"
run "$tmp/ok.lock"
check "no arguments is a usage error" test "$status" -eq 2

bad() {
    printf '%s\n' "$2" > "$tmp/bad.lock"
    run "$tmp/bad.lock" g
    check "$1 fails" test "$status" -ne 0
    check "$1 prints nothing" test -z "$out"
    check "$1 is named with its line" contains "$err" "$tmp/bad.lock:1: $3"
}
bad "a short line" "g x https://e/x v1 $c1" "wants 6 fields"
bad "a short commit" "g x https://e/x v1 abc123 cmake" "x's commit isn't a full 40-digit hash"
bad "an unknown build" "g x https://e/x v1 $c1 bazel" "x's build is bazel"
bad "a plain-http repository" "g x http://e/x v1 $c1 cmake" "x's repository isn't https"
printf '%s\n' "g x https://e/x v1 $c1 cmake" "g x https://e/y v1 $c1 cmake" > "$tmp/bad.lock"
run "$tmp/bad.lock" g
check "a name pinned twice is named" contains "$err" ":2: x is pinned twice"

# tide's own file.
run "${TIDE_DEPS_LOCK:-deps.lock}" --check
check "deps.lock is well formed${err:+: $err}" test "$status" -eq 0
run deps.lock hyprland
check "Hyprland builds last in its group" contains "$(printf '%s\n' "$out" | tail -n 1)" "Hyprland https://github.com/hyprwm/Hyprland.git"
run deps.lock --env quickshell
check "Quickshell is pinned" contains "$out" "PIN_COMMIT="

# CI builds the pinned Quickshell, not a copy of the pin.
check "ci.yml names no Quickshell commit of its own" test -z "$(grep -E 'QUICKSHELL_(TAG|COMMIT): ' .github/workflows/ci.yml)"
check "ci.yml reads the pin from install/pins" contains "$(cat .github/workflows/ci.yml)" "install/pins --env quickshell"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck passes" shellcheck -s sh "$pins" install/pins_test.sh
fi

printf 'pins_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
