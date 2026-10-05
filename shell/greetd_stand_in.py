"""A stand-in for greetd, for shell/shell_test.sh.

  greetd_stand_in.py SOCKET LOG USER PASSWORD [CODE]

It listens on SOCKET, as greetd 0.10.3 does on $GREETD_SOCK, and speaks
greetd's IPC: a native-endian 32-bit length, then that much JSON. It answers
as greetd does over a PAM stack that asks once for a password, and then,
given CODE, asks for that code as a visible prompt (PAM_PROMPT_ECHO_ON, a
one-time code some modules echo). USER with PASSWORD, and CODE, logs in;
any other answer is an auth_error. As in greetd, a failed
attempt keeps its session until cancel_session, a second create_session
before then is refused, and start_session refuses a session that hasn't
logged in.

Each request is a line in LOG, written once its answer is sent. The line
is the request's type, plus: the user for create_session, "right" or
"wrong" for an answer to the password, "code right" or "code wrong" for
one to the code (never the answer itself), and the JSON of the cmd and env
for start_session, or why it was refused.
"""

import json
import os
import socket
import struct
import sys

HEADER = struct.Struct("=I")


def read_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def error(kind, description):
    return {"type": "error", "error_type": kind, "description": description}


def serve(conn, log, user, password, code):
    configuring = None
    while True:
        header = read_exact(conn, HEADER.size)
        if header is None:
            return
        body = read_exact(conn, HEADER.unpack(header)[0])
        if body is None:
            return
        request = json.loads(body)
        kind = request.get("type")
        line = kind
        if kind == "create_session":
            line += " " + request.get("username", "")
            if configuring is not None:
                reply = error("error", "a session is already being configured")
            else:
                configuring = {"user": request.get("username"), "ready": False, "asked": None}
                reply = {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password: "}
        elif kind == "post_auth_message_response":
            if configuring is None:
                line = "answer without a session"
                reply = error("error", "no session under configuration")
            elif configuring["asked"] == "code":
                if request.get("response") == code:
                    line = "answer code right"
                    configuring["ready"] = True
                    reply = {"type": "success"}
                else:
                    line = "answer code wrong"
                    reply = error("auth_error", "pam_authenticate: AUTH_ERR")
            elif configuring["user"] == user and request.get("response") == password:
                line = "answer right"
                if code is None:
                    configuring["ready"] = True
                    reply = {"type": "success"}
                else:
                    configuring["asked"] = "code"
                    reply = {"type": "auth_message", "auth_message_type": "visible", "auth_message": "Code: "}
            else:
                line = "answer wrong"
                reply = error("auth_error", "pam_authenticate: AUTH_ERR")
        elif kind == "cancel_session":
            configuring = None
            reply = {"type": "success"}
        elif kind == "start_session":
            session, configuring = configuring, None
            if session is None:
                line += " refused: no session active"
                reply = error("error", "no session active")
            elif not session["ready"]:
                line += " refused: session is not ready"
                reply = error("error", "session is not ready")
            else:
                line += " " + json.dumps({"cmd": request.get("cmd"), "env": request.get("env")})
                reply = {"type": "success"}
        else:
            reply = error("error", "unknown request")
        data = json.dumps(reply).encode()
        conn.sendall(HEADER.pack(len(data)) + data)
        log.write(line + "\n")
        log.flush()


def main():
    path, log_path, user, password = sys.argv[1:5]
    code = sys.argv[5] if len(sys.argv) > 5 else None
    server = socket.socket(socket.AF_UNIX)
    # Bound under another name and renamed, so the socket appears ready.
    server.bind(path + ".new")
    server.listen(1)
    os.rename(path + ".new", path)
    with open(log_path, "a", encoding="utf-8") as log:
        while True:
            conn, _ = server.accept()
            with conn:
                serve(conn, log, user, password, code)


if __name__ == "__main__":
    main()
