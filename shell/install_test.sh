#!/bin/sh
#
# Tests for shell/install.sh, which make install-shell runs: over an empty
# directory and over an install, with stand-in install and mv commands on
# PATH that check, before each step, what a reload scanning the directory
# then would find.

cd "$(dirname "$0")/.." || exit 1
script=$PWD/shell/install.sh

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

# A source tree: two files at the top and one in lib.
src=$tmp/src
mkdir -p "$src/lib"
echo 'bar v2' > "$src/Bar.qml"
echo 'share v2' > "$src/ShareData.qml"
echo 'new' > "$src/New.qml"
echo 'lib v2' > "$src/lib/share.mjs"
echo 'new lib' > "$src/lib/fresh.mjs"

# Into an empty directory, every file lands whole, readable by all, and no
# hidden copy is left.
dest=$tmp/empty
mkdir -p "$dest/lib"
sh "$script" "$src" "$dest" Bar.qml ShareData.qml lib/share.mjs; code=$?
check "an install exits 0" test "$code" -eq 0
check "a top-level file lands whole" test "$(cat "$dest/Bar.qml")" = "bar v2"
check "a file in lib lands whole" test "$(cat "$dest/lib/share.mjs")" = "lib v2"
# find's -perm is POSIX, unlike stat's flags (GNU -c, BSD -f).
check "an installed file is mode 644" test -n "$(find "$dest/ShareData.qml" -perm 644)"
check "no hidden copy is left" test -z "$(find "$dest" -name '.*.tide-new')"

# Over an install: stand-ins for install and mv record what a scan at each
# step would find. install unlinks the file it writes, so it must never
# write over one a reload could load, only a hidden copy, and before each
# copy and rename every file of the old install must be there. Before each
# changed file goes in, every new one must already be.
dest=$tmp/live
mkdir -p "$dest/lib"
echo 'bar v1' > "$dest/Bar.qml"
echo 'share v1' > "$dest/ShareData.qml"
echo 'lib v1' > "$dest/lib/share.mjs"
old="Bar.qml ShareData.qml lib/share.mjs"
new="New.qml lib/fresh.mjs"
log=$tmp/log
: > "$log"
fakebin=$tmp/bin
mkdir -p "$fakebin"
for cmd in install mv; do
    real=$(command -v "$cmd") || { echo "install_test.sh: no $cmd on PATH" >&2; exit 1; }
    cat > "$fakebin/$cmd" <<EOF
#!/bin/sh
for f in $old; do
    test -e "$dest/\$f" || echo "$cmd: \$f missing" >> "$log"
done
# The last argument is where it goes; a rename over an old file changes it.
for last in "\$@"; do :; done
case \${last##*/} in
    .*) ;;
    *) if test "$cmd" = install && test -e "\$last"; then echo "install: wrote over \${last##*/}" >> "$log"; fi ;;
esac
if test "$cmd" = mv && test -e "\$last"; then
    for f in $new; do
        test -e "$dest/\$f" || echo "mv: \${last##*/} changed before \$f was in" >> "$log"
    done
fi
exec "$real" "\$@"
EOF
    chmod +x "$fakebin/$cmd"
done
PATH=$fakebin:$PATH sh "$script" "$src" "$dest" Bar.qml lib/share.mjs New.qml ShareData.qml lib/fresh.mjs; code=$?
check "an install over an install exits 0" test "$code" -eq 0
check "no live file is written over or missing, and new ones go in first" test -z "$(cat "$log")"
test -s "$log" && cat "$log" >&2
check "a changed file is replaced" test "$(cat "$dest/ShareData.qml")" = "share v2"
check "a new file is added" test "$(cat "$dest/lib/fresh.mjs")" = "new lib"
check "no hidden copy is left over an install" test -z "$(find "$dest" -name '.*.tide-new')"

# A copy that fails stops the install, names the file, and leaves no
# hidden copy behind.
dest=$tmp/broken
mkdir -p "$dest/lib"
echo 'bar v1' > "$dest/Bar.qml"
sh "$script" "$src" "$dest" Bar.qml Missing.qml ShareData.qml 2>"$tmp/err"; code=$?
check "a failed copy fails the install" test "$code" -eq 1
check "and names the file" contains "$(cat "$tmp/err")" "$src/Missing.qml"
check "and installs nothing after it" test ! -e "$dest/ShareData.qml"
check "and leaves no hidden copy" test -z "$(find "$dest" -name '.*.tide-new')"

# A shell running from the directory is held before the first file goes
# in and told to reload once, after the last. A stand-in qs records each
# call, with which files were in then.
qslog=$tmp/qs.log
cat > "$tmp/qs" <<EOF
#!/bin/sh
echo "\$* bar=\$(cat "\$3/Bar.qml" 2>/dev/null) share=\$(cat "\$3/ShareData.qml" 2>/dev/null)" >> "$qslog"
test -z "\$QS_FAIL"
EOF
chmod +x "$tmp/qs"
dest=$tmp/running
mkdir -p "$dest/lib"
echo 'shell' > "$dest/shell.qml"
echo 'bar v1' > "$dest/Bar.qml"
echo 'share v1' > "$dest/ShareData.qml"
: > "$qslog"
TIDE_QS=$tmp/qs sh "$script" "$src" "$dest" Bar.qml ShareData.qml; code=$?
check "an install over a running shell exits 0" test "$code" -eq 0
want="ipc -p $dest --any-display call install hold bar=bar v1 share=share v1
ipc -p $dest --any-display call install reload bar=bar v2 share=share v2"
check "holds the shell before any file and reloads it after all" test "$(cat "$qslog")" = "$want"
test "$(cat "$qslog")" = "$want" || cat "$qslog" >&2

# A failed install still tells it to reload, so it isn't left deaf to its
# files.
: > "$qslog"
TIDE_QS=$tmp/qs sh "$script" "$src" "$dest" Missing.qml 2>/dev/null; code=$?
check "a failed install over a running shell fails" test "$code" -eq 1
check "and still reloads it" contains "$(cat "$qslog")" "call install reload"

# A shell that doesn't answer (none running, or one too old to know
# install) isn't told to reload.
: > "$qslog"
QS_FAIL=1 TIDE_QS=$tmp/qs sh "$script" "$src" "$dest" Bar.qml; code=$?
check "an install with no shell to hold exits 0" test "$code" -eq 0
check "and asks it only to hold" test "$(grep -c 'call install' "$qslog")" -eq 1

# A directory with no shell.qml has no shell to hold.
dest=$tmp/fresh
mkdir -p "$dest/lib"
: > "$qslog"
TIDE_QS=$tmp/qs sh "$script" "$src" "$dest" Bar.qml; code=$?
check "an install into a new directory exits 0" test "$code" -eq 0
check "and asks no shell anything" test ! -s "$qslog"

sh "$script" "$src" 2>/dev/null; code=$?
check "too few arguments is a usage error" test "$code" -eq 2

printf 'install_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
