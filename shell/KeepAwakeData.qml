pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "lib/keepawake.mjs" as KeepAwake
import "lib/osd.mjs" as Osd
import "lib/presenter.mjs" as Presenter

// Keep awake (SPEC.md §10), shared by every monitor's bar: while it's on,
// each bar holds an idle inhibitor, so hypridle doesn't dim, lock, blank or
// suspend. It's on while you asked for it, which lasts until you click it
// off, survives a config reload, and starts off in a new shell; and while
// the mic is live (MicData), so an audio-only call with nothing moving on
// screen doesn't blank; and while presenter mode is on (PresenterData).
Singleton {
    id: root

    // You turned it on.
    readonly property bool asked: held.on
    // Presenter mode holds it on too (PresenterData), over your toggle.
    readonly property bool on: root.asked || MicData.live || PresenterData.on

    // Turns your request on or off. While the mic is live it stays on
    // either way; the click still decides what's left once the call ends.
    // While presenting it reads on, so a click turns it off and ends
    // presenter mode (Presenter.keepAwakeToggled).
    function toggle() {
        PresenterData.apply(Presenter.keepAwakeToggled(PresenterData.parts(), NotificationData.enabled));
    }

    // Your own toggle, for PresenterData.apply.
    function setAsked(on) {
        held.on = on;
        held.until = 0;
    }

    // `qs -c tide ipc call keepawake toggle`, from Super+S. The OSD says
    // what it did, since the bar's icon may be on another monitor.
    // `status` says whether it's in effect, "on" or "off".
    IpcHandler {
        target: "keepawake"

        function status(): string {
            return root.on ? "on" : "off";
        }

        function toggle(): void {
            root.toggle();
            OsdData.show(Osd.keepAwakePill({
                on: root.on,
                asked: root.asked,
                presenting: PresenterData.on
            }));
        }
    }

    PersistentProperties {
        id: held

        // The same id as before, so a reload into this version keeps keep
        // awake on if it was.
        reloadableId: "tide-keep-awake"

        property bool on: false
        // Set only by the versions that turned it off after two hours;
        // cleared by the migration below.
        property real until: 0

        // Whether it was on before the reload, from either version's state
        // (KeepAwake.migrated), read once now that the old values are in.
        onLoaded: {
            const next = KeepAwake.migrated({
                on: held.on,
                until: held.until
            }, Date.now());
            held.on = next.on;
            held.until = next.until;
        }
    }
}
