#!/bin/sh
#
# Tests for install/version, in throwaway git repositories and
# directories.

cd "$(dirname "$0")/.." || exit 1
script=$PWD/install/version

passes=0
failures=0
check() {
    _name=$1
    shift
    if "$@"; then passes=$((passes + 1)); else failures=$((failures + 1)); printf 'FAIL: %s\n' "$_name" >&2; fi
}

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$tmp/repo" -c user.name=t -c user.email=t@example.com "$@"; }

mkdir "$tmp/repo"
g init -q
echo a >"$tmp/repo/f"
g add f
g commit -q -m one
g commit -q --allow-empty -m two
commit=$(g rev-parse --short=12 HEAD)
check "a checkout gives the tag its commit would have, and the commit" \
    test "$(cd "$tmp/repo" && sh "$script" 3)" = "v0.3.2 ($commit)"
echo b >"$tmp/repo/f"
check "and says when there are changes" \
    test "$(cd "$tmp/repo" && sh "$script" 3)" = "v0.3.2 ($commit, with changes)"

mkdir "$tmp/tide-v0.0.987"
check "a release's directory gives its tag" \
    test "$(cd "$tmp/tide-v0.0.987" && GIT_CEILING_DIRECTORIES=$tmp sh "$script" 0)" = "v0.0.987"
mkdir "$tmp/other"
check "anything else is unknown" \
    test "$(cd "$tmp/other" && GIT_CEILING_DIRECTORIES=$tmp sh "$script" 0)" = "unknown"

printf 'version_test: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
