pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/osd.mjs" as Osd
import "lib/presenter.mjs" as Presenter

// Presenter mode (SPEC.md §10): Do not disturb and keep awake together.
// It holds both on over your own toggles without changing them, so turning
// it off leaves each as it was before it came on. Turning either one off
// while presenting ends it (shell/lib/presenter.mjs). Like keep awake, it
// survives a config reload and starts off in a new shell.
Singleton {
    id: root

    readonly property bool on: held.on

    // Presenter mode and your toggles under it, as presenter.mjs takes them.
    function parts() {
        return {
            presenting: held.on,
            dnd: NotificationData.ownDnd,
            keepAwake: KeepAwakeData.asked
        };
    }

    // Puts a state from presenter.mjs in place.
    function apply(next) {
        held.on = next.presenting;
        NotificationData.setOwnDnd(next.dnd);
        KeepAwakeData.setAsked(next.keepAwake);
    }

    function toggle() {
        root.apply(Presenter.presenterToggled(root.parts()));
    }

    PersistentProperties {
        id: held

        reloadableId: "tide-presenter"

        property bool on: false
    }

    // `qs -c tide ipc call presenter toggle`, from Super+P. The OSD says
    // what it did, and when there's no Do not disturb to turn on (the shell
    // isn't the notification server). `status` says "on" or "off".
    IpcHandler {
        target: "presenter"

        function status(): string {
            return root.on ? "on" : "off";
        }

        function toggle(): void {
            root.toggle();
            OsdData.show(Osd.presenterPill({
                presenting: root.on,
                dndAvailable: NotificationData.enabled
            }));
        }
    }
}
