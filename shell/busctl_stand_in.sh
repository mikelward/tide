#!/bin/sh
#
# A stand-in for busctl, for shell/integration_test.sh: the one call the
# shell makes, asking the file chooser portal its version before Start at
# login runs (shell/StartupData.qml), answered as xdg-desktop-portal would.
# Anything else fails, naming what it was asked.
#
#   busctl_stand_in.sh --user --timeout=30 get-property org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser version

if test "$*" = "--user --timeout=30 get-property org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser version"; then
    echo "u 4"
    exit 0
fi
echo "busctl: the integration test's stand-in has only the file chooser portal's version, not $*" >&2
exit 1
