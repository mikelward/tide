"""A stand-in for tidewm's IPC, sway's as tidewm speaks it (its
docs/ipc.md), for shell/integration_test.sh.

  tidewm_stand_in.py serve SOCKET LOG   listen on SOCKET, as tidewm does on
                                        $SWAYSOCK, and log each request
                                        to LOG, a line each

It answers each request at once, as tidewm does: Quickshell's I3 module,
TidewmData's listener and tide-msg each hold a connection of their own.
Its outputs, workspaces, windows and keyboard are fixed, and every
command works and changes nothing, so the shell sees the same answers
however often it asks. Subscribing sends a tick at once, with "first",
as sway and tidewm do, which TidewmData takes as the listener connecting.
"""

import json
import os
import selectors
import socket
import struct
import sys

MAGIC = b"i3-ipc"
HEADER = struct.Struct("=6sII")

RUN_COMMAND, GET_WORKSPACES, SUBSCRIBE, GET_OUTPUTS, GET_TREE = 0, 1, 2, 3, 4
GET_VERSION, GET_CONFIG, SEND_TICK = 7, 9, 10
GET_INPUTS, GET_SEATS, GET_BINDINGS = 100, 101, 200
EVENT_TICK = 0x80000007

OUTPUT = "HEADLESS-1"
RECT = {"x": 0, "y": 0, "width": 2560, "height": 1440}


def window(id, app_id, title, focused=False):
    return {
        "id": id, "type": "con", "name": title, "app_id": app_id, "pid": 1000 + id,
        "focused": focused, "urgent": False, "fullscreen_mode": 0, "maximized": False,
        "visible": True, "rect": RECT, "nodes": [], "floating_nodes": [],
    }


def workspace_node(num, windows, name=None):
    return {
        "id": 100 + num, "type": "workspace", "name": name or str(num), "num": num,
        "output": OUTPUT, "rect": RECT, "focused": False,
        "nodes": windows, "floating_nodes": [],
    }


# Two windows on 1, the focused one among them, one on 2, and home, in, empty.
TREE = {
    "id": 1, "type": "root", "name": "root", "rect": RECT, "focused": False,
    "nodes": [{
        "id": 2, "type": "output", "name": OUTPUT, "rect": RECT, "focused": False,
        "nodes": [
            workspace_node(1, [window(11, "firefox", "Mozilla Firefox", focused=True),
                               window(12, "kitty", "~/src")]),
            workspace_node(2, [window(13, "org.gnome.Nautilus", "Home")]),
            workspace_node(-1, [], name="in"),
        ],
        "floating_nodes": [],
    }],
    "floating_nodes": [],
}


def workspace(num, name=None, focused=False):
    return {
        "id": 100 + num, "num": num, "name": name or str(num), "visible": focused,
        "focused": focused, "urgent": False, "output": OUTPUT, "rect": RECT,
    }


ANSWERS = {
    GET_WORKSPACES: [workspace(1, focused=True), workspace(2), workspace(-1, name="in")],
    GET_OUTPUTS: [{
        "name": OUTPUT, "make": "headless", "model": "headless", "serial": "",
        "active": True, "dpms": True, "power": True, "primary": False, "focused": True,
        "scale": 1.0, "transform": "normal", "current_workspace": "1",
        "modes": [{"width": 2560, "height": 1440, "refresh": 60000}],
        "current_mode": {"width": 2560, "height": 1440, "refresh": 60000},
        "rect": RECT,
    }],
    GET_TREE: TREE,
    GET_VERSION: {"major": 1, "minor": 11, "patch": 0, "human_readable": "tidewm stand-in",
                  "loaded_config_file_name": ""},
    GET_CONFIG: {"config": ""},
    GET_INPUTS: [{
        "identifier": "1:1:keyboard", "name": "keyboard", "type": "keyboard",
        "hyprland_name": "keyboard", "xkb_layout_names": ["English (US)"],
        "xkb_active_layout_index": 0, "xkb_active_layout_name": "English (US)",
    }],
    GET_SEATS: [{"name": "seat0", "capabilities": 3, "focus": 11, "devices": []}],
    GET_BINDINGS: {"bindings": []},
}


def message(kind, payload):
    data = json.dumps(payload).encode()
    return HEADER.pack(MAGIC, len(data), kind) + data


def reply(kind, body):
    """What tidewm sends back for a request of `kind` with `body`."""
    if kind == RUN_COMMAND:
        commands = [c for c in body.split(";") if c.strip() != ""]
        return [message(kind, [{"success": True} for _ in commands or [""]])]
    if kind == SUBSCRIBE:
        out = [message(kind, {"success": True})]
        try:
            events = json.loads(body)
        except ValueError:
            events = []
        if "tick" in events:
            out.append(message(EVENT_TICK, {"first": True, "payload": ""}))
        return out
    if kind == SEND_TICK:
        return [message(kind, {"success": True})]
    if kind in ANSWERS:
        return [message(kind, ANSWERS[kind])]
    return [message(kind, {"success": False, "error": "unknown request"})]


def serve(path, log_path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(64)
    server.setblocking(False)
    selector = selectors.DefaultSelector()
    selector.register(server, selectors.EVENT_READ)
    buffers = {}
    with open(log_path, "a", buffering=1) as log:
        while True:
            for key, _ in selector.select():
                sock = key.fileobj
                if sock is server:
                    conn, _ = server.accept()
                    selector.register(conn, selectors.EVENT_READ)
                    buffers[conn] = b""
                    continue
                try:
                    data = sock.recv(65536)
                except OSError:
                    data = b""
                if not data:
                    selector.unregister(sock)
                    buffers.pop(sock, None)
                    sock.close()
                    continue
                buffers[sock] += data
                while len(buffers[sock]) >= HEADER.size:
                    magic, length, kind = HEADER.unpack_from(buffers[sock])
                    if magic != MAGIC:
                        buffers[sock] = b""
                        break
                    if len(buffers[sock]) < HEADER.size + length:
                        break
                    body = buffers[sock][HEADER.size:HEADER.size + length].decode()
                    buffers[sock] = buffers[sock][HEADER.size + length:]
                    log.write(f"{kind} {body}".rstrip() + "\n")
                    try:
                        for out in reply(kind, body):
                            sock.sendall(out)
                    except OSError:
                        pass


def main(args):
    if len(args) == 3 and args[0] == "serve":
        serve(args[1], args[2])
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
