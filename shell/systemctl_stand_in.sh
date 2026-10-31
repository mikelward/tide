#!/bin/sh
#
# A stand-in for systemctl, for shell/integration_test.sh: the calls the shell
# makes, answered as a user manager with hypridle.service running and a
# graphical session started would: restarting hypridle once it has written
# hypridle's timings (shell/IdleData.qml), and the graphical session's
# invocation ID, which tells Start at login one session from the next
# (shell/StartupData.qml). Anything else fails, naming what it was asked.
#
#   systemctl_stand_in.sh --user try-restart hypridle.service
#   systemctl_stand_in.sh --user show -p InvocationID --value graphical-session.target

if test "$*" = "--user try-restart hypridle.service"; then
    exit 0
fi
if test "$*" = "--user show -p InvocationID --value graphical-session.target"; then
    echo 0123456789abcdef0123456789abcdef
    exit 0
fi
echo "systemctl: the integration test's stand-in has only --user try-restart hypridle.service and the graphical session's InvocationID, not $*" >&2
exit 1
