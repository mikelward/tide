#!/bin/sh
#
# Compiles the shell's modules (shell/lib/*.mjs) and QML files with Qt's own
# compiler, qmlcachegen, as Quickshell does when it loads them, and fails
# on any name used before its declaration. Qt warns of each in the journal
# (qt.qml.usedbeforedeclared), as at the greeter's start, but only for the
# files Quickshell loads; this checks them all. Reading a module-level
# `const` before the line that declares it throws, should it run first.
#
# Usage: compile_test.sh QMLCACHEGEN [FILE...]
# With no FILE, every shell/lib/*.mjs but the tests', and shell/*.qml.

cd "$(dirname "$0")/.." || exit 1

if test $# -lt 1; then
    echo "usage: compile_test.sh QMLCACHEGEN [FILE...]" >&2
    exit 2
fi
qmlcachegen=$1
shift

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# used_before FILE: Qt's warnings of names FILE uses before it declares
# them, on stdout, with FILE's name; fails when qmlcachegen does.
used_before() {
    if ! _out=$("$qmlcachegen" -o "$tmp/out.qmlc" "$1" 2>&1); then
        printf '%s: qmlcachegen failed: %s\n' "$1" "$_out"
        return 1
    fi
    printf '%s\n' "$_out" | sed -n "/before its declaration/s|^[^:]*: :\{0,1\}|$1:|p"
}

# Qt's compiler has to say it, or the check below proves nothing.
cat >"$tmp/late.mjs" <<'EOF'
export function limit(v) {
    return v > MAX;
}
export const MAX = 1;
EOF
if ! warned=$(used_before "$tmp/late.mjs") || test -z "$warned"; then
    echo "compile_test.sh: $qmlcachegen doesn't warn of a name used before its declaration: ${warned:-it said nothing}" >&2
    exit 1
fi

if test $# -eq 0; then
    set --
    for file in shell/lib/*.mjs shell/*.qml; do
        case $file in
            *_test.mjs) ;;
            *) set -- "$@" "$file" ;;
        esac
    done
fi

failures=0
for file in "$@"; do
    if ! warned=$(used_before "$file") || test -n "$warned"; then
        printf '%s\n' "$warned" >&2
        failures=$((failures + 1))
    fi
done
printf 'compile_test.sh: %d files, %d with a name used before its declaration\n' "$#" "$failures"
test "$failures" -eq 0
