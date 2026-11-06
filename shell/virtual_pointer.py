"""A pointer for shell/integration_test.sh to click the shell with.

  virtual_pointer.py WIDTH HEIGHT WAIT   make a pointer on the compositor
                                         WAYLAND_DISPLAY names, for an
                                         output WIDTH by HEIGHT, and say
                                         "ready"; then take a command a
                                         line from stdin, and say "ok"
                                         once the compositor has it. A
                                         compositor that doesn't answer in
                                         WAIT seconds is an error.

The commands are "move X Y" and "click left|right|middle". The pointer is
the wlr virtual pointer protocol's, which headless sway offers, and it
stays for the whole run: a pointer made for each click, as wlrctl's is,
comes and goes before the shell has bound it, and the click is lost. It
speaks the Wayland wire protocol itself, as there's no Python binding to
lean on: each request is the object, the opcode and size, and the
arguments, and each command ends with a wl_display.sync round trip.
"""

import os
import socket
import struct
import sys

BUTTONS = {"left": 0x110, "right": 0x111, "middle": 0x112}  # linux/input-event-codes.h
MANAGER = "zwlr_virtual_pointer_manager_v1"
DISPLAY = 1


class Connection:
    def __init__(self, wait):
        path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-0"))
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(wait)
        self.wait = wait
        try:
            self.sock.connect(path)
        except OSError as e:
            sys.exit(f"virtual_pointer.py: couldn't connect to {path}: {e}")
        self.last_id = DISPLAY
        self.buf = b""

    def new_id(self):
        self.last_id += 1
        return self.last_id

    def send(self, obj, opcode, *args):
        payload = b"".join(arg if isinstance(arg, bytes) else struct.pack("=I", arg) for arg in args)
        self.sock.sendall(struct.pack("=II", obj, (8 + len(payload)) << 16 | opcode) + payload)

    def events(self):
        while True:
            while len(self.buf) >= 8:
                obj, word = struct.unpack("=II", self.buf[:8])
                size = word >> 16
                if len(self.buf) < size:
                    break
                body, self.buf = self.buf[8:size], self.buf[size:]
                yield obj, word & 0xFFFF, body
            try:
                data = self.sock.recv(65536)
            except TimeoutError:
                sys.exit(f"virtual_pointer.py: the compositor didn't answer in {self.wait:g} s")
            if not data:
                sys.exit("virtual_pointer.py: the compositor hung up")
            self.buf += data

    def roundtrip(self, on_event=lambda obj, opcode, body: None):
        callback = self.new_id()
        self.send(DISPLAY, 0, callback)  # wl_display.sync
        for obj, opcode, body in self.events():
            if obj == DISPLAY and opcode == 0:  # wl_display.error
                sys.exit(f"virtual_pointer.py: the compositor says {body[12:-1].decode(errors='replace')}")
            if obj == callback and opcode == 0:  # wl_callback.done
                return
            on_event(obj, opcode, body)


def string(s):
    b = s.encode() + b"\0"
    return struct.pack("=I", len(b)) + b + b"\0" * (-len(b) % 4)


def main():
    width, height, wait = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
    conn = Connection(wait)
    registry = conn.new_id()
    conn.send(DISPLAY, 1, registry)  # wl_display.get_registry
    found = {}

    def global_(obj, opcode, body):
        if obj == registry and opcode == 0:  # wl_registry.global
            name, length = struct.unpack("=II", body[:8])
            version, = struct.unpack("=I", body[8 + length + (-length % 4):][:4])
            found[body[8:8 + length - 1].decode()] = (name, version)

    conn.roundtrip(global_)
    if MANAGER not in found:
        sys.exit(f"virtual_pointer.py: the compositor has no {MANAGER}")
    name, version = found[MANAGER]
    manager = conn.new_id()
    conn.send(registry, 0, name, string(MANAGER), min(version, 2), manager)  # wl_registry.bind
    pointer = conn.new_id()
    conn.send(manager, 0, 0, pointer)  # create_virtual_pointer, on the default seat
    conn.roundtrip()
    print("ready", flush=True)
    time = 0
    for line in sys.stdin:
        words = line.split()
        time += 10
        if words[:1] == ["move"] and len(words) == 3:
            conn.send(pointer, 1, time, int(words[1]), int(words[2]), width, height)  # motion_absolute
            conn.send(pointer, 4)  # frame
        elif words[:1] == ["click"] and len(words) == 2 and words[1] in BUTTONS:
            for state in (1, 0):
                conn.send(pointer, 2, time, BUTTONS[words[1]], state)  # button
                conn.send(pointer, 4)
                time += 10
        else:
            sys.exit(f"virtual_pointer.py: no command {line.strip()!r}; the commands are move X Y and click {'|'.join(BUTTONS)}")
        conn.roundtrip()
        print("ok", flush=True)


if __name__ == "__main__":
    main()
