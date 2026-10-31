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
#   systemctl_stand_in.sh --user start|stop tide-lid-inhibit.service

if test "$*" = "--user try-restart hypridle.service"; then
    exit 0
fi
# The Power page's lid action holding logind's lid switch, or letting go.
if test "$*" = "--user start tide-lid-inhibit.service" || test "$*" = "--user stop tide-lid-inhibit.service"; then
    exit 0
fi
if test "$*" = "--user show -p InvocationID --value graphical-session.target"; then
    echo 0123456789abcdef0123456789abcdef
    exit 0
fi
echo "systemctl: the integration test's stand-in has only --user try-restart hypridle.service, the graphical session's InvocationID and the lid action's unit, not $*" >&2
exit 1
