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
# Usage: install.sh FROM TO FILE...
# Each FILE, a path under FROM, goes to the same path under TO, whose
# directories must exist. Stops at the first file it can't install.

if test "$#" -lt 2; then
    echo "usage: install.sh FROM TO FILE..." >&2
    exit 2
fi
from=$1
to=$2
shift 2

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
