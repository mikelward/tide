"""A stand-in for Hyprland's IPC, for shell/shell_test.sh.

  hyprland_stand_in.py serve DIR   listen in DIR, as Hyprland does in
                                   $XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE
  hyprland_stand_in.py drain DIR   answer every request waiting, and print
                                   each one answered, a line each
  hyprland_stand_in.py play DIR    send EVENTS to every event listener, and
                                   print how many there were
  hyprland_stand_in.py ctl ARG...  answer as `hyprctl ARG...` would, at once

It answers requests only when drained, so the test decides when the shell
hears back, and can tell when the shell has nothing left to ask. As
hyprctl, which the shell runs as a command and the test waits for as one,
it answers at once, from the same fixtures, and evaluates only the focus
guard's calls that focus.lua defines, and conf's conf_input.reload(). Its
monitors, workspaces and windows are fixed: an event that changes them
isn't reflected in later answers, as it would be in Hyprland, so the shell
sees some churn, as it can when windows come and go quickly.
"""

import json
import os
import re
import socket
import sys

# The output headless sway makes.
MONITOR = "HEADLESS-1"


def client(address, workspace, cls, title, x=0, floating=False, fullscreen=0):
    return {
        "address": address, "mapped": True, "hidden": False,
        "at": [x, 30], "size": [1280, 1410],
        "workspace": {"id": workspace, "name": special(workspace)},
        "floating": floating, "pseudo": False, "monitor": 0,
        "class": cls, "title": title, "initialClass": cls, "initialTitle": title,
        "pid": 1000, "xwayland": False, "pinned": False,
        "fullscreen": fullscreen, "fullscreenClient": fullscreen,
        "grouped": [], "tags": [], "swallowing": "0x0", "focusHistoryID": 0,
        "inhibitingIdle": False,
    }


def special(workspace):
    return "special:scratch" if workspace < 0 else str(workspace)


# Two windows side by side on 1, one on 2, more than the bar shows on 3
# with one fullscreen, and one on a special workspace.
CLIENTS = [
    client("0x55aa01", 1, "firefox", "Mozilla Firefox"),
    client("0x55aa02", 1, "kitty", "~/src", x=1280),
    client("0x55aa03", 2, "org.gnome.Nautilus", "Home"),
    client("0x55aa04", 3, "Slack", "Slack | general", fullscreen=2),
    client("0x55aa05", 3, "code", "main.go - Visual Studio Code"),
    client("0x55aa06", 3, "kitty", "htop"),
    client("0x55aa07", 3, "kitty", "vim"),
    client("0x55aa08", 3, "kitty", "make"),
    client("0x55aa09", 3, "kitty", "less"),
    client("0x55aa0a", -98, "pavucontrol", "Volume Control", floating=True),
]


def workspace(id, last):
    windows = [c for c in CLIENTS if c["workspace"]["id"] == id]
    return {
        "id": id, "name": special(id), "monitor": MONITOR, "monitorID": 0,
        "windows": len(windows), "hasfullscreen": any(c["fullscreen"] for c in windows),
        "lastwindow": last, "lastwindowtitle": "", "ispersistent": False,
    }


ANSWERS = {
    # The user's Hyprland is configured in Lua, which changes how the
    # shell's dispatches are written.
    "j/status": {"configProvider": "lua"},
    "j/monitors": [{
        "id": 0, "name": MONITOR, "description": "Headless", "make": "", "model": "",
        "serial": "", "width": 2560, "height": 1440, "refreshRate": 60.0, "x": 0, "y": 0,
        "activeWorkspace": {"id": 1, "name": "1"}, "specialWorkspace": {"id": 0, "name": ""},
        "reserved": [0, 30, 0, 0], "scale": 1.0, "transform": 0, "focused": True,
        "dpmsStatus": True, "vrr": False, "solitary": "0", "activelyTearing": False,
        "disabled": False, "currentFormat": "XRGB8888", "mirrorOf": "none",
        "availableModes": [],
    }],
    "j/workspaces": [
        workspace(1, "0x55aa01"), workspace(2, "0x55aa03"),
        workspace(3, "0x55aa04"), workspace(-98, "0x55aa0a"),
    ],
    "j/clients": CLIENTS,
    "j/activewindow": CLIENTS[0],
    "j/devices": {"keyboards": [{
        "address": "0x1", "name": "keyboard", "layout": "us",
        "active_keymap": "English (US)", "main": True,
    }]},
}

# What the bar and the lock follow: focus moving between workspaces and
# windows, tide's layout announcements and attention marks, a special
# workspace shown and hidden, fullscreen, a layout switch and a reload.
EVENTS = [
    "workspacev2>>2,2",
    "focusedmonv2>>" + MONITOR + ",2",
    "activewindowv2>>55aa03",
    "custom>>tide-layout>>1,columns",
    "custom>>tide-layout>>3,monocle",
    "custom>>tide-attention>>0x55aa04",
    "urgent>>55aa05",
    "activespecialv2>>-98,special:scratch," + MONITOR,
    "activewindowv2>>55aa0a",
    "activespecialv2>>,," + MONITOR,
    "fullscreen>>1",
    "custom>>tide-cycle>>start",
    "custom>>tide-cycle>>end>>0x55aa04",
    "activelayout>>keyboard,English (UK)",
    "configreloaded>>",
]


def answer(request):
    if request in ANSWERS:
        return json.dumps(ANSWERS[request])
    # A dispatch, or anything else Hyprland would carry out.
    return "ok"


def serve(directory):
    os.makedirs(directory, exist_ok=True)
    requests = socket.socket(socket.AF_UNIX)
    requests.bind(os.path.join(directory, ".socket.sock"))
    requests.listen(64)
    requests.setblocking(False)

    listeners = []
    events = socket.socket(socket.AF_UNIX)
    events.bind(os.path.join(directory, ".socket2.sock"))
    events.listen(64)
    events.setblocking(False)

    def drain():
        answered = []
        while True:
            try:
                conn, _ = requests.accept()
            except BlockingIOError:
                return "".join(r + "\n" for r in answered)
            with conn:
                conn.setblocking(True)
                # Quickshell writes each request whole, then waits.
                request = conn.recv(65536).decode()
                conn.sendall(answer(request).encode())
            answered.append(request)

    def play():
        # Taken here, not as they arrive, so a listener that connected
        # before the test asked is always counted.
        while True:
            try:
                conn, _ = events.accept()
            except BlockingIOError:
                break
            conn.setblocking(True)
            listeners.append(conn)
        sent = 0
        for conn in list(listeners):
            try:
                conn.sendall("".join(e + "\n" for e in EVENTS).encode())
                sent += 1
            except OSError:
                # A shell that has since exited.
                listeners.remove(conn)
        return f"{sent}\n"

    control = socket.socket(socket.AF_UNIX)
    # Bound last: once it's there, the stand-in is ready.
    control.bind(os.path.join(directory, "control.sock"))
    control.listen(4)
    while True:
        conn, _ = control.accept()
        with conn:
            command = conn.recv(64).decode()
            reply = drain() if command == "drain" else play() if command == "play" else f"unknown command {command}\n"
            conn.sendall(reply.encode())


# Two of conf's key bindings, as Hyprland 0.56.2's `hyprctl binds -j`
# gives them: one with a description, and one without.
BINDS = [
    {"locked": False, "mouse": False, "release": False, "repeat": False, "longPress": False,
     "non_consuming": False, "auto_consuming": False, "has_description": True, "modmask": 64,
     "submap": "", "submap_universal": "false", "key": "T", "keycode": 0, "catch_all": False,
     "description": "Terminal", "allow_input_capture": False, "dispatcher": "__lua", "arg": "1"},
    {"locked": False, "mouse": False, "release": False, "repeat": True, "longPress": False,
     "non_consuming": False, "auto_consuming": False, "has_description": False, "modmask": 64,
     "submap": "", "submap_universal": "false", "key": "backslash", "keycode": 0, "catch_all": False,
     "description": "", "allow_input_capture": False, "dispatcher": "__lua", "arg": "2"},
]


# What the shell runs hyprctl for: the focused window at startup, the
# keyboards for the lock's layout badge, the key bindings for the settings
# panel's Keys page, and the focus guard's calls.
CTL = {
    ("activewindow", "-j"): lambda: json.dumps(ANSWERS["j/activewindow"]),
    ("devices", "-j"): lambda: json.dumps(ANSWERS["j/devices"]),
    ("binds", "-j"): lambda: json.dumps(BINDS),
}


# The focus guard's calls MarkData.qml makes: the replay, and the marked
# windows in order, as Ws.attentionOrder writes their addresses.
GUARD_CALLS = [
    ("announce_waiting", re.compile(r"tide_focus\.announce_waiting\(\)")),
    ("set_order", re.compile(r'tide_focus\.set_order\(\{(?:"0x[0-9a-f]+"(?:,"0x[0-9a-f]+")*)?\}\)')),
]
FOCUS_LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hypr", "tide", "focus.lua")


# conf's hyprland.lua's call InputData.qml makes, applying tide's mouse and
# touchpad settings; conf isn't here to check, so it's taken as defined.
CONF_CALLS = ["conf_input.reload()"]


def guard_call(code):
    """What Hyprland would say to `hyprctl eval CODE`: ok for a guard call
    focus.lua defines, or conf's, else why not."""
    if code in CONF_CALLS:
        return None
    name = next((n for n, pattern in GUARD_CALLS if pattern.fullmatch(code)), None)
    if name is None:
        return f"the stand-in hyprctl doesn't evaluate {code!r}"
    with open(FOCUS_LUA) as f:
        source = f.read()
    if "_G.tide_focus = M" not in source or f"function M.{name}(" not in source:
        return f"hypr/tide/focus.lua has no tide_focus.{name}"
    return None


def ctl(args):
    if args and args[0] == "eval" and len(args) == 2:
        error = guard_call(args[1])
        if error is not None:
            sys.stderr.write(error + "\n")
            return 1
        print("ok")
        return 0
    reply = CTL.get(tuple(args))
    if reply is None:
        sys.stderr.write(f"the stand-in hyprctl doesn't answer {' '.join(args)!r}\n")
        return 2
    print(reply())
    return 0


def ask(directory, command):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.connect(os.path.join(directory, "control.sock"))
        conn.sendall(command.encode())
        conn.shutdown(socket.SHUT_WR)
        reply = b""
        while chunk := conn.recv(65536):
            reply += chunk
    sys.stdout.write(reply.decode())
    return 1 if reply.startswith(b"unknown") else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "ctl":
        return ctl(argv[2:])
    if len(argv) != 3 or argv[1] not in ("serve", "drain", "play"):
        sys.stderr.write(__doc__)
        return 2
    if argv[1] == "serve":
        serve(argv[2])
        return 0
    return ask(argv[2], argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
