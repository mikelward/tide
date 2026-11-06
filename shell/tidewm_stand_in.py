"""A stand-in for tidewm's IPC, for shell/integration_test.sh.

  tidewm_stand_in.py serve DIR   listen on DIR/ipc.sock, as tidewm does on
                                 the socket it names in SWAYSOCK
  tidewm_stand_in.py drain DIR   answer every request a listener has
                                 waiting, and print each one answered, a
                                 line each
  tidewm_stand_in.py play DIR    send EVENTS to every listener subscribed
                                 to them, and print how many there were

tidewm speaks sway's IPC (its docs/ipc.md). A connection whose first
message is SUBSCRIBE is a listener, as Quickshell's I3 module and its
listeners are, which send their requests on it too: those are answered
only when drained, so the test decides when the shell hears back, and can
tell when the shell has nothing left to ask. Any other connection is
tide-msg, which the shell runs as a command and the test waits for as one:
it asks one thing and goes, and is answered at once, from the same
fixtures. A command is checked against tidewm's command words, as tidewm
would refuse one it doesn't know. The workspaces, outputs and windows are
fixed: an event that changes them isn't reflected in later answers, as it
would be in tidewm, so the shell sees some churn, as it can when windows
come and go quickly.
"""

import json
import os
import re
import selectors
import socket
import struct
import sys

MAGIC = b"i3-ipc"
HEADER = struct.Struct("=II")

# The output headless sway makes.
MONITOR = "HEADLESS-1"
RECT = {"x": 0, "y": 0, "width": 2560, "height": 1440}
# Below the bar.
AREA = {"x": 0, "y": 30, "width": 2560, "height": 1410}

REQUESTS = {
    0: "run_command", 1: "get_workspaces", 2: "subscribe", 3: "get_outputs", 4: "get_tree",
    7: "get_version", 8: "get_binding_modes", 9: "get_config", 10: "send_tick",
    12: "get_binding_state", 100: "get_inputs", 101: "get_seats", 200: "get_bindings",
}
EVENT_TYPES = {
    "workspace": 0x80000000, "output": 0x80000001, "mode": 0x80000002, "window": 0x80000003,
    "binding": 0x80000005, "shutdown": 0x80000006, "tick": 0x80000007, "input": 0x80000015,
    "layout": 0x8000001E, "capture": 0x8000001F,
}


def window(id, workspace, app, title, floating=False, focused=False, urgent=False,
           fullscreen=0, maximized=False, minimized=False, x11_class=None):
    con = {
        "id": id, "type": "floating_con" if floating else "con", "name": title,
        "app_id": None if x11_class else app, "shell": "xwayland" if x11_class else "xdg_shell",
        "pid": 1000 + id, "focused": focused, "urgent": urgent, "urgent_order": id if urgent else 0,
        "visible": workspace == "1" and not minimized, "fullscreen_mode": fullscreen,
        "sticky": False, "dim": True, "dimmed": False, "maximized": maximized,
        "minimized": minimized, "rect": AREA, "workspace": workspace, "output": MONITOR,
        "foreign_toplevel_identifier": f"{id:032x}", "nodes": [], "floating_nodes": [],
    }
    if x11_class:
        con["window"] = 0x200000 + id
        con["window_properties"] = {"class": x11_class, "instance": x11_class.lower(), "title": title}
    return con


# Two windows side by side on 1, one focused; one on 2 and a floating one
# beside it; more than the bar shows on 3, one fullscreen and one an X11
# window; and one minimized on 2.
WINDOWS = [
    window(11, "1", "firefox", "Mozilla Firefox", focused=True),
    window(12, "1", "kitty", "~/src"),
    window(13, "2", "org.gnome.Nautilus", "Home"),
    window(14, "2", "pavucontrol", "Volume Control", floating=True),
    window(15, "2", "org.gnome.TextEditor", "notes", minimized=True),
    window(16, "3", "Slack", "Slack | general", fullscreen=1),
    window(17, "3", "code", "main.go - Visual Studio Code"),
    window(18, "3", "kitty", "htop"),
    window(19, "3", "kitty", "vim"),
    window(20, "3", "kitty", "make"),
    window(21, "3", None, "xterm", x11_class="XTerm"),
]


def workspace(id, name, persistent=False):
    current = name == "1"
    return {
        "id": id, "type": "workspace", "name": name,
        "num": int(name) if name.isdigit() else -1, "focused": current, "visible": current,
        "urgent": any(c["urgent"] for c in WINDOWS if c["workspace"] == name),
        "persistent": persistent, "output": MONITOR, "rect": AREA,
        "layout": "tile" if current else None,
    }


# 1 current; home, by its default name, kept empty, as tide-tidewm keeps
# it; and a workspace named as the name prompt names one, with a comma in
# it.
WORKSPACES = [
    workspace(2, "1"), workspace(3, "2"), workspace(4, "3"),
    workspace(5, "in", persistent=True), workspace(6, "PR-12, login", persistent=True),
]

OUTPUT = {
    "id": 7, "type": "output", "name": MONITOR, "make": "Headless", "model": "", "serial": "",
    "active": True, "power": True, "primary": False, "scale": 1.0, "transform": "normal",
    "focused": True, "current_workspace": "1", "rect": RECT,
    "current_mode": {"width": 2560, "height": 1440, "refresh": 60000},
    "window_area": AREA,
    "layers": [{"namespace": "tide-bar", "layer": "top", "rect": {"x": 0, "y": 0, "width": 2560, "height": 30},
                "exclusive_zone": 30}],
}


def tree():
    def part(ws):
        windows = [c for c in WINDOWS if c["workspace"] == ws["name"]]
        return dict(ws, nodes=[c for c in windows if c["type"] == "con"],
                    floating_nodes=[c for c in windows if c["type"] == "floating_con"])
    output = dict(OUTPUT, nodes=[part(ws) for ws in WORKSPACES], floating_nodes=[])
    return {"id": 1, "type": "root", "name": "root", "focused": False, "rect": RECT,
            "nodes": [output], "floating_nodes": []}


KEYBOARD = {
    "identifier": "1:1:Test_keyboard", "hyprland_name": "test-keyboard", "name": "Test keyboard",
    "vendor": 1, "product": 1, "type": "keyboard", "xkb_layout_names": ["English (US)"],
    "xkb_active_layout_index": 0, "xkb_active_layout_name": "English (US)",
    "repeat_delay": 600, "repeat_rate": 25,
}
TOUCHPAD = {
    "identifier": "2:7:Test_touchpad", "hyprland_name": "test-touchpad", "name": "Test touchpad",
    "vendor": 2, "product": 7, "type": "touchpad", "scroll_factor": 1.0,
    "libinput": {"send_events": "enabled", "tap": "enabled", "natural_scroll": "disabled",
                 "accel_speed": 0.0},
}

# Two of conf's tidewm key bindings, as tidewm's GET_BINDINGS gives them.
BINDINGS = [
    {"type": "key", "keys": "Mod4+t", "command": "exec tide terminal", "mode": "default",
     "release": False, "locked": False},
    {"type": "key", "keys": "Mod4+backslash", "command": "layout toggle", "mode": "default",
     "release": False, "locked": False},
]

CONFIG = "include ~/.config/tidewm/tide-*.conf\n"
ANSWERS = {
    "get_workspaces": WORKSPACES,
    "get_outputs": [OUTPUT],
    "get_tree": tree(),
    "get_version": {"human_readable": "tidewm stand-in", "variant": "tidewm", "major": 0,
                    "minor": 9, "patch": 0, "loaded_config_file_name": "config"},
    "get_binding_modes": ["default"],
    "get_config": {"config": CONFIG, "included_configs": [], "path": "config", "errors": []},
    "send_tick": {"success": True},
    "get_binding_state": {"name": "default"},
    "get_inputs": [KEYBOARD, TOUCHPAD],
    "get_seats": [{"name": "seat0", "capabilities": 3, "focus": 11, "devices": [KEYBOARD, TOUCHPAD],
                   "last_input": None, "prompt_may_focus": False}],
    "get_bindings": BINDINGS,
}


def workspace_event(change, current, old=None):
    return ("workspace", {"change": change, "current": current, "old": old})


def window_event(change, con):
    return ("window", {"change": change, "container": con})


def changed(con, **fields):
    return dict(con, **fields)


NEW = window(22, "2", "org.gnome.Nautilus", "Downloads")
# What the bar, the marks and the name prompt follow: focus moving to
# another workspace and window, a window opening, retitled, made urgent,
# moved, minimized and closed, a workspace made, home renamed, and a
# layout switched.
EVENTS = [
    workspace_event("focus", changed(WORKSPACES[1], focused=True, visible=True),
                    changed(WORKSPACES[0], focused=False, visible=False)),
    ("output", {"change": "focus", "output": MONITOR}),
    # A window opening, then focused: the name prompt judges it by the
    # event, and lets it be, since it isn't on home.
    window_event("new", NEW),
    window_event("focus", changed(NEW, focused=True)),
    window_event("title", changed(WINDOWS[1], name="~/src/tide")),
    window_event("urgent", changed(WINDOWS[6], urgent=True, urgent_order=30)),
    window_event("move", changed(WINDOWS[1], workspace="3")),
    window_event("minimize", changed(WINDOWS[7], minimized=True)),
    window_event("close", WINDOWS[8]),
    ("layout", {"change": "layout", "workspace": "2", "output": MONITOR, "layout": "monocle",
                "symbol": "[3]"}),
    workspace_event("init", workspace(8, "docs, draft")),
    workspace_event("rename", changed(WORKSPACES[3], name="mail")),
    ("input", {"change": "xkb_layout", "input": KEYBOARD}),
]

# tidewm's commands, by the word that starts each (its docs/ipc.md), and
# the criteria that may come first.
COMMANDS = {
    "nop", "exit", "workspace", "move", "focus", "kill", "send_shortcut", "exec", "reload",
    "mode", "output", "input", "dim", "sticky", "floating", "fullscreen", "maximize",
    "minimize", "layout", "nmaster", "mfact", "zoom", "switch", "unlock", "chvt", "rename",
    "persist", "unpersist", "urgent", "grant",
}
CRITERIA = re.compile(r"\[con_id=[0-9]+\]\s*")


def commands(payload):
    """Each command in a RUN_COMMAND payload, as tidewm splits them: at
    each ; outside double quotes, but an exec takes the rest."""
    out = []
    rest = payload
    while rest.strip():
        head = rest.lstrip()
        if CRITERIA.sub("", head, count=1).startswith("exec "):
            out.append(head.strip())
            break
        quoted = False
        for i, c in enumerate(rest):
            if c == '"':
                quoted = not quoted
            elif c == ";" and not quoted:
                command, rest = rest[:i], rest[i + 1:]
                break
        else:
            command, rest = rest, ""
        if command.strip():
            out.append(command.strip())
    return out


def run(payload):
    results = []
    for command in commands(payload):
        word = CRITERIA.sub("", command, count=1).split(None, 1)
        if not word or word[0] not in COMMANDS or command.startswith("[") and not CRITERIA.match(command):
            results.append({"success": False, "parse_error": True,
                            "error": f"the stand-in tidewm doesn't know {command!r}"})
        else:
            results.append({"success": True})
    return results


def answer(kind, payload, subscribed):
    """The reply to a message of type `kind` with `payload`, adding what it
    subscribes to to the set `subscribed`."""
    name = REQUESTS.get(kind)
    if name == "run_command":
        return run(payload)
    if name == "subscribe":
        try:
            events = json.loads(payload)
        except ValueError:
            return {"success": False}
        if not isinstance(events, list) or not all(e in EVENT_TYPES for e in events):
            return {"success": False}
        subscribed.update(events)
        return {"success": True}
    if name in ANSWERS:
        return ANSWERS[name]
    return {"success": False, "error": "unsupported message type"}


def message(kind, body):
    data = json.dumps(body).encode()
    return MAGIC + HEADER.pack(len(data), kind) + data


class Connection:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""
        self.listener = None
        self.subscribed = set()
        self.waiting = []

    def send(self, data):
        self.sock.setblocking(True)
        try:
            self.sock.sendall(data)
        finally:
            self.sock.setblocking(False)

    def read(self):
        """Takes what's arrived, answering a tide-msg at once and keeping a
        listener's requests for a drain. False once it has closed."""
        while True:
            try:
                chunk = self.sock.recv(65536)
            except BlockingIOError:
                break
            except OSError:
                return False
            if not chunk:
                return False
            self.buffer += chunk
        while len(self.buffer) >= len(MAGIC) + HEADER.size:
            if not self.buffer.startswith(MAGIC):
                return False
            size, kind = HEADER.unpack_from(self.buffer, len(MAGIC))
            end = len(MAGIC) + HEADER.size + size
            if len(self.buffer) < end:
                break
            payload = self.buffer[len(MAGIC) + HEADER.size:end].decode()
            self.buffer = self.buffer[end:]
            if self.listener is None:
                self.listener = kind == 2
            if self.listener:
                self.waiting.append((kind, payload))
            else:
                try:
                    self.send(message(kind, answer(kind, payload, self.subscribed)))
                except OSError:
                    return False
        return True

    def drain(self):
        answered = []
        for kind, payload in self.waiting:
            self.send(message(kind, answer(kind, payload, self.subscribed)))
            answered.append(REQUESTS.get(kind, str(kind)) + (f" {payload}" if payload else ""))
            # Subscribing to ticks sends one at once.
            if REQUESTS.get(kind) == "subscribe" and "tick" in self.subscribed:
                self.send(message(EVENT_TYPES["tick"], {"first": True, "payload": ""}))
        self.waiting = []
        return answered


def serve(directory):
    os.makedirs(directory, exist_ok=True)
    ipc = socket.socket(socket.AF_UNIX)
    ipc.bind(os.path.join(directory, "ipc.sock"))
    ipc.listen(64)
    ipc.setblocking(False)
    connections = {}
    selector = selectors.DefaultSelector()

    def take():
        """Takes every connection waiting, and everything sent so far."""
        while True:
            try:
                sock, _ = ipc.accept()
            except BlockingIOError:
                break
            sock.setblocking(False)
            connections[sock] = Connection(sock)
            selector.register(sock, selectors.EVENT_READ)
        for sock, conn in list(connections.items()):
            if not conn.read():
                # The shell, or a tide-msg, gone.
                selector.unregister(sock)
                sock.close()
                del connections[sock]

    def drain():
        take()
        answered = []
        for sock, conn in list(connections.items()):
            try:
                answered += conn.drain()
            except OSError:
                selector.unregister(sock)
                sock.close()
                del connections[sock]
        return "".join(r + "\n" for r in answered)

    def play():
        take()
        sent = 0
        for sock, conn in list(connections.items()):
            events = [message(EVENT_TYPES[t], e) for t, e in EVENTS if t in conn.subscribed]
            if not events:
                continue
            try:
                conn.send(b"".join(events))
                sent += 1
            except OSError:
                selector.unregister(sock)
                sock.close()
                del connections[sock]
        return f"{sent}\n"

    control = socket.socket(socket.AF_UNIX)
    # Bound last: once it's there, the stand-in is ready.
    control.bind(os.path.join(directory, "control.sock"))
    control.listen(4)
    selector.register(ipc, selectors.EVENT_READ)
    selector.register(control, selectors.EVENT_READ)
    while True:
        for key, _ in selector.select():
            if key.fileobj is control:
                conn, _ = control.accept()
                with conn:
                    command = conn.recv(64).decode()
                    reply = drain() if command == "drain" else play() if command == "play" else f"unknown command {command}\n"
                    conn.sendall(reply.encode())
            else:
                # A tide-msg is answered as soon as it asks.
                take()


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
    if len(argv) != 3 or argv[1] not in ("serve", "drain", "play"):
        sys.stderr.write(__doc__)
        return 2
    if argv[1] == "serve":
        serve(argv[2])
        return 0
    return ask(argv[2], argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
