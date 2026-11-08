#!/bin/sh
#
# Tests for releases: release.yml tags and publishes only from main, and
# `make dist` packages the source and the Go commands for both
# architectures, with a go that only writes each command it's asked to
# build. From the repo root: `sh .github/workflows/release_test.sh`.

# shellcheck disable=SC2016 # the sh -c scripts' and the workflow's $s are theirs

cd "$(dirname "$0")/../.." || exit 1
wf=.github/workflows/release.yml

passes=0
failures=0
check() {
    _name=$1
    shift
    if "$@"; then passes=$((passes + 1)); else failures=$((failures + 1)); printf 'FAIL: %s\n' "$_name" >&2; fi
}
has() { grep -qF -- "$2" "$1"; }

check "releases only from a push to main" has "$wf" "    branches: [main]"
check "no dispatch, which could tag a branch" sh -c '! grep -qE "^ *workflow_dispatch:" "$1"' sh "$wf"
check "fetches every commit, which the tag counts" has "$wf" "fetch-depth: 0"
check "publishes make dist's files" has "$wf" 'build/dist/*'
check "never moves a tag" has "$wf" 'git ls-remote --exit-code --tags origin "refs/tags/$TAG"'

tmp=$(mktemp -d) || exit 1
trap 'rm -r "$tmp"' EXIT
# go build -o FILE PKG writes FILE naming the platform it was asked for.
cat > "$tmp/go" <<'STUB'
#!/bin/sh
while test $# -gt 0; do
    test "$1" != -o || out=$2
    shift
done
echo "$GOOS/$GOARCH cgo=$CGO_ENABLED" > "$out"
STUB
chmod +x "$tmp/go"
tag=$(make -s release-tag SHALLOW_OK=yes)
check "the tag is v0.MINOR.<commits>" sh -c 'case "$1" in v0.[0-9]*.[0-9]*) ;; *) exit 1 ;; esac' sh "$tag"
if make -s dist SHALLOW_OK=yes GO="$tmp/go" >"$tmp/out" 2>&1; then
    check "dist runs" true
else
    check "dist runs: $(tail -n 3 "$tmp/out")" false
fi
for arch in amd64 arm64; do
    f=build/dist/tide-$tag-linux-$arch.tar.gz
    check "dist has the $arch commands" test -f "$f"
    for cmd in tide-grant tide-msg tide-tz tide-greetd tide-agent tide-tabs tide-pick tide-kwin-paste; do
        check "$arch's $cmd is built for linux/$arch with no C" \
            test "$(tar -xzOf "$f" "tide-$tag-linux-$arch/$cmd" 2>/dev/null)" = "linux/$arch cgo=0"
    done
done
src=build/dist/tide-$tag.tar.gz
check "dist has the source" test -f "$src"
check "the source has the installer" sh -c 'tar -tzf "$1" | grep -qx "tide-$2/install/tide-setup"' sh "$src" "$tag"
check "the source has the pins" sh -c 'tar -tzf "$1" | grep -qx "tide-$2/deps.lock"' sh "$src" "$tag"
# git archive fills in install/revision (.gitattributes' export-subst), so
# the installer knows a release's commit without its .git. It archives
# HEAD, so that's the commit.
check "the source names its commit" sh -c 'test "$(tar -xzOf "$1" "tide-$2/install/revision")" = "$(git rev-parse HEAD)"' sh "$src" "$tag"
# GNU's sha256sum, or macOS's shasum, as make dist picks.
if command -v sha256sum >/dev/null 2>&1; then sums="sha256sum"; else sums="shasum -a 256"; fi
# shellcheck disable=SC2086 # $sums is a command and its options
check "the sums cover all three" test "$(cd build/dist && $sums -c SHA256SUMS 2>/dev/null | grep -c ': OK$')" -eq 3

printf 'release_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
