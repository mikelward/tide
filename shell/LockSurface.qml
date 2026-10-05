import QtQuick
import Quickshell.Wayland
import "lib/lock.mjs" as Lock

// One output's lock (SPEC.md §10): the lock face (LockFace.qml) on a
// session-lock surface. lock.qml owns the state.
WlSessionLockSurface {
    id: surface

    property var lockState: Lock.INITIAL
    property string hostname: ""
    property string user: ""
    property date lockedAt: new Date()
    property string powerMessage: ""
    property bool powerBusy: false
    property int unread: 0
    property string layout: ""

    signal event(var event)
    signal power(string id)

    color: "#000000"

    LockFace {
        anchors.fill: parent
        lockState: surface.lockState
        hostname: surface.hostname
        user: surface.user
        lockedAt: surface.lockedAt
        powerMessage: surface.powerMessage
        powerBusy: surface.powerBusy
        unread: surface.unread
        layout: surface.layout
        onEvent: event => surface.event(event)
        onPower: id => surface.power(id)
    }
}
