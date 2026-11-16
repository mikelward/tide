// tide's launcher on KDE Plasma (SPEC.md §8.5): no bar, no notifications,
// nothing else tide's session runs, so nothing here takes a D-Bus name or
// a key from Plasma. Beside it, KdeBorders gives tide's window decoration
// there the Borders settings as they change, and PowerFollow switches the
// power profile as the power source changes, as in tide's session. tide-kde.service keeps it running, and
// setup-kde binds Meta+Space to `qs -c tide-kde ipc call launcher toggle`.
// No IconTheme pragma: Qt takes Plasma's icon theme, as Plasma's apps do.
import QtQuick
import Quickshell

ShellRoot {
    LauncherWindow {}

    KdeBorders {}

    PowerFollow {}
}
