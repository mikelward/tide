#!/bin/sh
#
# A stand-in for timedatectl, for shell/shell_test.sh: the one call the
# shell makes, setting the system's time zone from the Clocks page
# (shell/ClockData.qml), answered as systemd-timedated would once polkit
# allows it. It changes nothing. Anything else fails, naming what it was
# asked.
#
#   timedatectl_stand_in.sh set-timezone ZONE

if test "$#" -eq 2 && test "$1" = set-timezone; then
    exit 0
fi
echo "timedatectl: the load test's stand-in has only set-timezone ZONE, not $*" >&2
exit 1
