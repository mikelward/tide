#!/bin/sh
#
# A stand-in for busctl, for shell/integration_test.sh: the calls the
# shell makes, answered as the services would. It asks the file chooser
# portal its version before Start at login runs (shell/StartupData.qml),
# and, on tidewm, `tide lid-docked` asks logind whether the lid is shut,
# which it isn't here. Anything else fails, naming what it was asked.
#
#   busctl_stand_in.sh --user --timeout=30 get-property org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser version
#   busctl_stand_in.sh get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed

if test "$*" = "--user --timeout=30 get-property org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser version"; then
    echo "u 4"
    exit 0
fi
if test "$*" = "get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed"; then
    echo "b false"
    exit 0
fi
echo "busctl: the integration test's stand-in has only the file chooser portal's version and the lid, not $*" >&2
exit 1
