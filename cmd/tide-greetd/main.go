// Command tide-greetd is the greeter's connection to greetd (SPEC.md §11).
//
//	tide-greetd
//
// It connects to greetd's socket, $GREETD_SOCK, and relays the greeter's
// requests one at a time. It reads a request from stdin, one JSON object on
// one line, as greetd's IPC takes it (create_session,
// post_auth_message_response, start_session or cancel_session). It sends
// it, and reads greetd's reply before it reads the next request, so each
// reply answers the request just before it. The reply goes to stdout on one
// line, with the type of the request it answers:
//
//	{"request": "create_session", "reply": {"type": "auth_message", ...}}
//
// Pairing replies with requests is what Quickshell 0.3.1's Greetd gets
// wrong (quickshell-mirror/quickshell#1266): it sends a create_session
// without waiting for the reply to the cancel_session before it, then
// reads that reply as the new session's.
//
// A failure of its own is one line, {"fault": "..."}, then exit 1: no
// $GREETD_SOCK, a socket it can't reach or that closes, or a line that isn't
// one of those four requests. It never writes a request back out, since an
// answer to a prompt is a password. It exits 0 when stdin closes.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
)

// The longest request or reply it takes. greetd's are a few hundred bytes;
// this only stops a garbled length from allocating gigabytes.
const maxMessage = 1 << 20

var requestTypes = map[string]bool{
	"create_session":             true,
	"post_auth_message_response": true,
	"start_session":              true,
	"cancel_session":             true,
}

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr, os.Getenv("GREETD_SOCK")))
}

func run(stdin io.Reader, stdout, stderr io.Writer, socket string) int {
	out := json.NewEncoder(stdout)
	fault := func(format string, args ...any) int {
		msg := fmt.Sprintf(format, args...)
		fmt.Fprintf(stderr, "tide-greetd: %s\n", msg)
		if err := out.Encode(map[string]string{"fault": msg}); err != nil {
			fmt.Fprintf(stderr, "tide-greetd: couldn't tell the greeter: %v\n", err)
		}
		return 1
	}
	if socket == "" {
		return fault("GREETD_SOCK isn't set, so greetd isn't running this greeter")
	}
	conn, err := net.Dial("unix", socket)
	if err != nil {
		return fault("couldn't connect to greetd at %s: %v", socket, err)
	}
	defer conn.Close()

	lines := bufio.NewScanner(stdin)
	lines.Buffer(make([]byte, 0, 4096), maxMessage)
	for lines.Scan() {
		line := lines.Bytes()
		var request struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(line, &request); err != nil {
			return fault("a request isn't a JSON object: %v", err)
		}
		if !requestTypes[request.Type] {
			return fault("%q isn't a request greetd takes", request.Type)
		}
		if err := send(conn, line); err != nil {
			return fault("couldn't send %s to greetd: %v", request.Type, err)
		}
		reply, err := receive(conn)
		if err != nil {
			return fault("no reply from greetd to %s: %v", request.Type, err)
		}
		if err := out.Encode(struct {
			Request string          `json:"request"`
			Reply   json.RawMessage `json:"reply"`
		}{request.Type, reply}); err != nil {
			// The greeter has gone; nobody is left to tell.
			fmt.Fprintf(stderr, "tide-greetd: couldn't pass on greetd's reply to %s: %v\n", request.Type, err)
			return 1
		}
	}
	if err := lines.Err(); err != nil {
		return fault("couldn't read a request: %v", err)
	}
	return 0
}

// greetd's framing: a native-endian 32-bit length, then that much JSON.
func send(w io.Writer, body []byte) error {
	frame := binary.NativeEndian.AppendUint32(make([]byte, 0, 4+len(body)), uint32(len(body)))
	_, err := w.Write(append(frame, body...))
	return err
}

func receive(r io.Reader) (json.RawMessage, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, errors.New("greetd closed the connection")
		}
		return nil, err
	}
	n := binary.NativeEndian.Uint32(header[:])
	if n > maxMessage {
		return nil, fmt.Errorf("a reply of %d bytes is longer than any greetd sends", n)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	var reply struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(body, &reply); err != nil || reply.Type == "" {
		return nil, fmt.Errorf("the reply isn't a JSON object with a type: %q", body)
	}
	return json.RawMessage(body), nil
}
