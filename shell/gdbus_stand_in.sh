#!/bin/sh
#
# A stand-in for gdbus, for shell/integration_test.sh: the shell's own
# call, answered as GLib's would be on a machine that doesn't sleep.
#
#   gdbus_stand_in.sh monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1
#
# The monitor says the name's owner, as gdbus does, then hears nothing and
# waits for its parent to end in a tail: once the shell has started it,
# it's a monitor waiting, whose command line no longer names the test's
# wrappers, not a command settle has to wait for.

case "$*" in
    "monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1")
        echo "The name org.freedesktop.login1 is owned by :1.3"
        exec tail --pid="$PPID" -f /dev/null
        ;;
    *)
        echo "gdbus: the integration test's stand-in doesn't answer $*" >&2
        exit 2
        ;;
esac
