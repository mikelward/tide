// tide's launcher on KDE Plasma (SPEC.md §8.5), alone: no bar, no
// notifications, nothing else tide's session runs, so nothing here takes a
// D-Bus name or a key from Plasma. tide-kde.service keeps it running, and
// setup-kde binds Meta+Space to `qs -c tide-kde ipc call launcher toggle`.
// No IconTheme pragma: Qt takes Plasma's icon theme, as Plasma's apps do.
import QtQuick
import Quickshell

ShellRoot {
    LauncherWindow {}
}
