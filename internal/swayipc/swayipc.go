// Package swayipc speaks sway's IPC, which tidewm answers on the socket
// named in SWAYSOCK (SPEC.md §5.3): a command, a query, and the focused
// workspace, and the events tidewm sends.
// It's i3's protocol: a message is "i3-ipc", its payload's length and its
// type, both 32 bits in this machine's byte order, then the payload.
package swayipc

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"
)

// The message types tide sends.
const (
	RunCommand    = 0
	GetWorkspaces = 1
	// Subscribe asks for events, which come on the same connection.
	SubscribeType = 2
	GetOutputs    = 3
	GetTree       = 4
	GetVersion    = 7
	GetConfig     = 9
	GetInputs     = 100
	GetSeats      = 101
	// GetBindings is tidewm's own: the config file's bindings.
	GetBindings = 200
	// GetNamedBindings is tidewm's own: the bindings the config names,
	// with their default keys and their keys now.
	GetNamedBindings = 201
)

// Queries are the queries by the names swaymsg gives them.
var Queries = map[string]uint32{
	"get_workspaces":     GetWorkspaces,
	"get_outputs":        GetOutputs,
	"get_tree":           GetTree,
	"get_version":        GetVersion,
	"get_config":         GetConfig,
	"get_inputs":         GetInputs,
	"get_seats":          GetSeats,
	"get_bindings":       GetBindings,
	"get_named_bindings": GetNamedBindings,
}

var magic = []byte("i3-ipc")

// Timeout bounds a whole exchange, so a compositor that stops answering
// can't hang a launch or a shell's prompt.
var Timeout = 5 * time.Second

// ErrNoSocket is SWAYSOCK unset: no tidewm to ask.
var ErrNoSocket = errors.New("SWAYSOCK isn't set, so there's no tidewm to ask")

// Socket is the socket SWAYSOCK names in env, the last setting winning.
func Socket(env []string) (string, error) {
	for i := len(env) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(env[i], "SWAYSOCK="); ok {
			if v == "" {
				break
			}
			return v, nil
		}
	}
	return "", ErrNoSocket
}

// Send sends one message of type kind and returns its reply's payload.
func Send(socket string, kind uint32, payload []byte) ([]byte, error) {
	conn, err := net.DialTimeout("unix", socket, Timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(Timeout)); err != nil {
		return nil, err
	}
	return exchange(conn, kind, payload)
}

// exchange sends one message of type kind on conn and returns its reply's
// payload.
func exchange(conn net.Conn, kind uint32, payload []byte) ([]byte, error) {
	msg := make([]byte, 0, len(magic)+8+len(payload))
	msg = append(msg, magic...)
	msg = binary.NativeEndian.AppendUint32(msg, uint32(len(payload)))
	msg = binary.NativeEndian.AppendUint32(msg, kind)
	msg = append(msg, payload...)
	if _, err := conn.Write(msg); err != nil {
		return nil, err
	}
	got, reply, err := read(conn)
	if err != nil {
		return nil, err
	}
	if got != kind {
		return nil, fmt.Errorf("the reply is type %d, not %d", got, kind)
	}
	return reply, nil
}

// read reads one message from conn: its type and payload. Its error says
// "no reply" when none came, wrapping io.EOF when conn closed first.
func read(conn net.Conn) (uint32, []byte, error) {
	header := make([]byte, len(magic)+8)
	if _, err := io.ReadFull(conn, header); err != nil {
		return 0, nil, fmt.Errorf("no reply: %w", err)
	}
	if string(header[:len(magic)]) != string(magic) {
		return 0, nil, errors.New("the reply isn't sway's IPC")
	}
	n := binary.NativeEndian.Uint32(header[len(magic):])
	kind := binary.NativeEndian.Uint32(header[len(magic)+4:])
	payload := make([]byte, n)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return 0, nil, fmt.Errorf("the reply was cut short: %w", err)
	}
	return kind, payload, nil
}

// Subscribe asks for the events named, such as "input", and calls each
// with every one's payload as it comes. It returns nil once tidewm closes
// the connection, as when it exits, or each's error, or why the events
// stopped coming.
func Subscribe(socket string, events []string, each func(payload []byte) error) error {
	conn, err := net.DialTimeout("unix", socket, Timeout)
	if err != nil {
		return err
	}
	defer conn.Close()
	// Only the subscription has a deadline: the events come when they do.
	if err := conn.SetDeadline(time.Now().Add(Timeout)); err != nil {
		return err
	}
	names, err := json.Marshal(events)
	if err != nil {
		return err
	}
	reply, err := exchange(conn, SubscribeType, names)
	if err != nil {
		return err
	}
	var result struct {
		Success bool   `json:"success"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal(reply, &result); err != nil {
		return fmt.Errorf("couldn't read the reply %q: %w", reply, err)
	}
	if !result.Success {
		if result.Error == "" {
			result.Error = "tidewm refused the subscription"
		}
		return Refused{result.Error}
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return err
	}
	for {
		kind, payload, err := read(conn)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		// An event's type has the high bit set; anything else isn't one.
		if kind&0x80000000 == 0 {
			continue
		}
		if err := each(payload); err != nil {
			return err
		}
	}
}

// Refused is tidewm's answer that commands failed: each one's error.
type Refused []string

func (r Refused) Error() string { return strings.Join(r, "; ") }

// Command runs cmd, one or more commands separated by ";". Its error is a
// Refused when tidewm ran them and one or more failed.
func Command(socket, cmd string) error {
	reply, err := Send(socket, RunCommand, []byte(cmd))
	if err != nil {
		return err
	}
	var results []struct {
		Success bool   `json:"success"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal(reply, &results); err != nil {
		return fmt.Errorf("couldn't read the reply %q: %w", reply, err)
	}
	if len(results) == 0 {
		return errors.New("no command ran")
	}
	var failed []string
	for _, r := range results {
		if !r.Success {
			failed = append(failed, r.Error)
		}
	}
	if len(failed) > 0 {
		return Refused(failed)
	}
	return nil
}

// FocusedWorkspace is the focused workspace's name.
func FocusedWorkspace(socket string) (string, error) {
	reply, err := Send(socket, GetWorkspaces, nil)
	if err != nil {
		return "", err
	}
	var workspaces []struct {
		Name    string `json:"name"`
		Focused bool   `json:"focused"`
	}
	if err := json.Unmarshal(reply, &workspaces); err != nil {
		return "", fmt.Errorf("couldn't read the workspaces %q: %w", reply, err)
	}
	for _, w := range workspaces {
		if w.Focused {
			return w.Name, nil
		}
	}
	return "", errors.New("no workspace is focused")
}

// PromptMayFocus is whether a polkit prompt opening now may take the
// keyboard, by tidewm's focus guard (GET_SEATS's prompt_may_focus). A
// tidewm too old to say is an error.
func PromptMayFocus(socket string) (bool, error) {
	reply, err := Send(socket, GetSeats, nil)
	if err != nil {
		return false, err
	}
	var seats []struct {
		PromptMayFocus *bool `json:"prompt_may_focus"`
	}
	if err := json.Unmarshal(reply, &seats); err != nil {
		return false, fmt.Errorf("couldn't read the seats %q: %w", reply, err)
	}
	if len(seats) == 0 || seats[0].PromptMayFocus == nil {
		return false, errors.New("tidewm doesn't say whether a prompt may take the keyboard: update tidewm")
	}
	return *seats[0].PromptMayFocus, nil
}

// Word makes s one argument of a command, as tidewm reads one: as it is,
// or in double quotes when it has a space, a tab or a ";". tidewm's
// quotes take no escapes, so s can't have a double quote, and it can't be
// empty or have a line break or other control character.
func Word(s string) (string, error) {
	if s == "" || strings.ContainsFunc(s, func(r rune) bool { return r == '"' || (r < 0x20 && r != '\t') || r == 0x7f }) {
		return "", fmt.Errorf("%q can't be one word of a tidewm command", s)
	}
	if strings.ContainsAny(s, " \t;") {
		return `"` + s + `"`, nil
	}
	return s, nil
}
