#!/bin/sh
#
# A stand-in for systemctl, for shell/shell_test.sh: the one call the shell
# makes, restarting hypridle once it has written hypridle's timings
# (shell/IdleData.qml), answered as a user manager with hypridle.service
# running would. Anything else fails, naming what it was asked.
#
#   systemctl_stand_in.sh --user try-restart hypridle.service

if test "$*" = "--user try-restart hypridle.service"; then
    exit 0
fi
echo "systemctl: the load test's stand-in has only --user try-restart hypridle.service, not $*" >&2
exit 1
