#!/bin/sh
#
# A stand-in for udevadm, for shell/integration_test.sh: the lock's and the
# greeter's watch on input devices (shell/LockKeyboards.qml).
#
#   udevadm_stand_in.sh monitor --udev --subsystem-match=input
#
# It prints the header udevadm's monitor prints once it's listening
# (systemd's src/udev/udevadm-monitor.c), which the watch takes as a cue to
# count the keyboards again. Then it hears nothing, since no device comes
# or goes in the test, and waits for its parent to end in a tail, as the
# gsettings stand-in does: once the lock has started it, it's a monitor
# waiting, whose command line no longer names the test's wrappers, not a
# command settle has to wait for. Anything else fails, naming what it got.

case "$*" in
    "monitor --udev --subsystem-match=input")
        printf '%s\n' "monitor will print the received events for:" \
            "UDEV - the event which udev sends out after rule processing" ""
        exec tail --pid="$PPID" -f /dev/null
        ;;
esac
echo "udevadm: the integration test's stand-in has only monitor --udev --subsystem-match=input, not $*" >&2
exit 2
