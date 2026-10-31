pragma Singleton

import QtQuick
import Quickshell
import "lib/barclick.mjs" as Click

// The bar's popovers (SPEC.md §7.1): at most one open, the target on the bar
// that opened it, and every bar, which each popover's focus grab takes in
// (PopoverGrab.qml) so a click on a bar reaches it.
Singleton {
    id: root

    // The open popover, and the click target that opened it, if any. Typed
    // as objects, so one destroyed while open (its monitor unplugged) reads
    // as none.
    property QtObject open: null
    property Item opener: null
    // Every monitor's bar.
    property var bars: []

    function addBar(bar) {
        root.bars = root.bars.concat([bar]);
    }

    function removeBar(bar) {
        root.bars = root.bars.filter(b => b !== bar);
    }

    // A tap on `opener` toggles `popover`.
    function toggle(popover, opener) {
        if (Click.toggled(root.open, popover) === null) {
            popover.visible = false;
            return;
        }
        root.opener = opener ?? null;
        popover.visible = true;
    }

    // A popover shown or hidden, by toggle() or its own doing: one showing
    // closes any other.
    function shown(popover) {
        const next = Click.shownState({ open: root.open, opener: root.opener }, popover, popover.visible);
        root.open = next.open;
        root.opener = next.opener;
        // After `open` has moved on, so its own shown() changes nothing.
        if (next.hide !== null) {
            next.hide.visible = false;
        }
    }

    // A popover going away, as its monitor is unplugged, closed or not.
    function gone(popover) {
        const next = Click.shownState({ open: root.open, opener: root.opener }, popover, false);
        root.open = next.open;
        root.opener = next.opener;
    }

    // A press on a bar, at `scenePoint` in the bar `window`: anywhere but the
    // open popover's own target closes it, so the press goes on to act on
    // what it's on (Click.closesOnPress).
    function pressed(window, scenePoint) {
        const o = root.opener;
        const onOpener = o !== null && o.barWindow === window
            && o.contains(o.mapFromItem(null, scenePoint.x, scenePoint.y));
        if (Click.closesOnPress(root.open !== null, onOpener)) {
            root.open.visible = false;
        }
    }
}
