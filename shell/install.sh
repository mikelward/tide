#!/bin/sh
#
# Installs the shell's files into a directory a running Quickshell may be
# loading from, as `make install-shell` does into
# ~/.config/quickshell/tide (SPEC.md §5.4).
#
# Quickshell reloads the shell when a file it loaded changes, and its
# reload scans the directory while an install may still be copying.
# `install` unlinks each file before writing it, so a scan could find one
# missing. That reload then went without it, such as ShareData, leaving
# the Sharing pill up with nothing shared. A file that wasn't there to load
# isn't watched, so its return didn't reload the shell again.
#
# So each file is written beside its place under a hidden name, then
# renamed over it: a scan finds the old file or the new one, whole. Files
# new to the directory go first, so one that a changed file uses is there
# before that file changes.
#
# Each reload still loads whatever is in by then, and Quickshell reloads
# at each file's change, so a reload between two files that change
# together, such as Bar.qml setting a property Workspaces.qml has just
# gained, failed to load. And when another file went in during that failed
# reload, Quickshell missed its change, so the shell stayed broken. So a
# shell running from TO is first told to stop watching its files (`qs ipc
# call install hold`), and once every file is in, to reload them once
# (`install reload`, shell.qml). A shell too old to answer reloads as before.
#
# Usage: install.sh FROM TO FILE...
# Each FILE, a path under FROM, goes to the same path under TO, whose
# directories must exist. Stops at the first file it can't install.
# $TIDE_QS is the qs to ask (default: qs).

if test "$#" -lt 2; then
    echo "usage: install.sh FROM TO FILE..." >&2
    exit 2
fi
from=$1
to=$2
shift 2
qs=${TIDE_QS:-qs}

# Holds a shell running from TO, if there is one that answers, and releases
# it on exit, whether every file went in or not, so it never stays deaf to
# its files. Any display's, so an install over SSH holds it too.
held=0
release() {
    if test "$held" -eq 1; then
        held=0
        if ! "$qs" ipc -p "$to" --any-display call install reload >/dev/null; then
            echo "install.sh: couldn't tell the shell running from $to to reload; restart it to load what's installed" >&2
        fi
    fi
}
if test -e "$to/shell.qml" && command -v "$qs" >/dev/null 2>&1 &&
    "$qs" ipc -p "$to" --any-display call install hold >/dev/null 2>&1; then
    held=1
    trap release EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
fi

# Copies FILE to its hidden name beside its place, then renames it in.
put() {
    _dest=$to/$1
    _tmp=${_dest%/*}/.${_dest##*/}.tide-new
    if ! install -m 644 "$from/$1" "$_tmp"; then
        rm -f "$_tmp"
        echo "install.sh: couldn't copy $from/$1 to $_tmp" >&2
        exit 1
    fi
    if ! mv -f "$_tmp" "$_dest"; then
        rm -f "$_tmp"
        echo "install.sh: couldn't rename $_tmp to $_dest" >&2
        exit 1
    fi
}

# Which files are new, before any goes in, one per line. A path can't
# hold a newline.
nl='
'
new=$nl
for f in "$@"; do
    if ! test -e "$to/$f"; then
        new=$new$f$nl
    fi
done
isnew() {
    case $new in
        *"$nl$1$nl"*) return 0 ;;
    esac
    return 1
}

for f in "$@"; do
    if isnew "$f"; then put "$f"; fi
done
for f in "$@"; do
    if ! isnew "$f"; then put "$f"; fi
done
