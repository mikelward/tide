#!/bin/sh
#
# A stand-in for gsettings, for shell/shell_test.sh: the shell's own calls,
# answered as GNOME's would answer them.
#
#   gsettings_stand_in.sh set org.gnome.desktop.interface color-scheme VALUE
#   gsettings_stand_in.sh set org.gnome.desktop.interface gtk-theme NAME
#   gsettings_stand_in.sh monitor org.gnome.desktop.interface color-scheme
#
# A color scheme the schema doesn't have fails as it does in GNOME:
# gsettings-desktop-schemas 50.0 has default, prefer-dark and prefer-light,
# and GLib 2.88's gsettings refuses anything else with this message and
# exit 1, as it does a set or monitor with the wrong number of arguments,
# with its usage. The monitor hears nothing, since nothing else sets the
# scheme in the test, and waits for its parent to end in a tail: once the
# shell has started it, it's a monitor waiting, whose command line no
# longer names the test's wrappers, not a command settle has to wait for.

usage() {
    printf 'Usage:\n  gsettings [--schemadir SCHEMADIR] %s\n' "$1" >&2
    exit 1
}

case ${1:-} in
    set) test $# -eq 4 || usage "set SCHEMA[:PATH] KEY VALUE" ;;
    monitor) test $# -eq 2 || test $# -eq 3 || usage "monitor SCHEMA[:PATH] [KEY]" ;;
esac

case "$#|${1:-}|${2:-}|${3:-}" in
    "3|monitor|org.gnome.desktop.interface|color-scheme")
        exec tail --pid="$PPID" -f /dev/null
        ;;
    "4|set|org.gnome.desktop.interface|color-scheme")
        case $4 in
            default | prefer-dark | prefer-light) ;;
            *)
                echo "The provided value is outside of the valid range" >&2
                exit 1
                ;;
        esac
        ;;
    "4|set|org.gnome.desktop.interface|gtk-theme") ;;
    *)
        echo "gsettings: the load test's stand-in doesn't answer $*" >&2
        exit 2
        ;;
esac
