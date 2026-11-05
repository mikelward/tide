package swayipc

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// serve answers one message on a socket in a temporary directory with
// reply, as type replyKind, and sends what it got on the channel.
type message struct {
	kind    uint32
	payload string
}

func serve(t *testing.T, replyKind uint32, reply string) (string, <-chan message) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ipc.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	got := make(chan message, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		header := make([]byte, 14)
		if _, err := io.ReadFull(conn, header); err != nil || string(header[:6]) != "i3-ipc" {
			return
		}
		payload := make([]byte, binary.NativeEndian.Uint32(header[6:]))
		if _, err := io.ReadFull(conn, payload); err != nil {
			return
		}
		got <- message{binary.NativeEndian.Uint32(header[10:]), string(payload)}
		out := append([]byte("i3-ipc"), binary.NativeEndian.AppendUint32(nil, uint32(len(reply)))...)
		out = binary.NativeEndian.AppendUint32(out, replyKind)
		conn.Write(append(out, reply...))
	}()
	return path, got
}

func TestCommandSendsItAndSucceeds(t *testing.T) {
	socket, got := serve(t, RunCommand, `[{"success":true},{"success":true}]`)
	if err := Command(socket, `grant --workspace "a b" foot; nop`); err != nil {
		t.Fatal(err)
	}
	m := <-got
	if m.kind != RunCommand || m.payload != `grant --workspace "a b" foot; nop` {
		t.Fatalf("sent %d %q", m.kind, m.payload)
	}
}

func TestCommandSaysWhatFailed(t *testing.T) {
	socket, _ := serve(t, RunCommand, `[{"success":true},{"success":false,"error":"grant: expected app ids","parse_error":true}]`)
	err := Command(socket, "nop; grant")
	var refused Refused
	if !errors.As(err, &refused) || err.Error() != "grant: expected app ids" {
		t.Fatalf("got %v", err)
	}
}

func TestCommandWithNoResultsFails(t *testing.T) {
	socket, _ := serve(t, RunCommand, `[]`)
	if err := Command(socket, ""); err == nil {
		t.Fatal("no results counted as success")
	}
}

func TestFocusedWorkspace(t *testing.T) {
	socket, got := serve(t, GetWorkspaces,
		`[{"name":"in","focused":false},{"name":"PR 12","focused":true,"visible":true}]`)
	name, err := FocusedWorkspace(socket)
	if err != nil || name != "PR 12" {
		t.Fatalf("got %q, %v", name, err)
	}
	if m := <-got; m.kind != GetWorkspaces || m.payload != "" {
		t.Fatalf("sent %d %q", m.kind, m.payload)
	}
}

func TestNoFocusedWorkspaceIsAnError(t *testing.T) {
	socket, _ := serve(t, GetWorkspaces, `[{"name":"in","focused":false}]`)
	if _, err := FocusedWorkspace(socket); err == nil {
		t.Fatal("no error")
	}
}

func TestAReplyOfAnotherTypeIsAnError(t *testing.T) {
	socket, _ := serve(t, GetWorkspaces, `[]`)
	err := Command(socket, "nop")
	var refused Refused
	if err == nil || errors.As(err, &refused) || !strings.Contains(err.Error(), "type 1, not 0") {
		t.Fatalf("got %v", err)
	}
}

func TestNoReplyTimesOut(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ipc.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		if conn, err := ln.Accept(); err == nil {
			<-done
			conn.Close()
		}
	}()
	saved := Timeout
	Timeout = 50 * time.Millisecond
	defer func() { Timeout = saved }()
	if err := Command(path, "nop"); err == nil || !strings.Contains(err.Error(), "no reply") {
		t.Fatalf("got %v", err)
	}
}

func TestNothingListeningIsAnError(t *testing.T) {
	if err := Command(filepath.Join(t.TempDir(), "none.sock"), "nop"); err == nil {
		t.Fatal("no error")
	}
}

func TestSocketIsSwaysock(t *testing.T) {
	if s, err := Socket([]string{"SWAYSOCK=/a", "HOME=/h", "SWAYSOCK=/b"}); err != nil || s != "/b" {
		t.Fatalf("got %q, %v", s, err)
	}
	for _, env := range [][]string{nil, {"SWAYSOCK="}, {"HOME=/h"}} {
		if _, err := Socket(env); err != ErrNoSocket {
			t.Fatalf("%v: got %v", env, err)
		}
	}
}

func TestWord(t *testing.T) {
	for in, want := range map[string]string{
		"foot": "foot", "org.gnome.Nautilus": "org.gnome.Nautilus", "*": "*",
		"Bob's tasks": `"Bob's tasks"`, "a;b": `"a;b"`, "a\tb": "\"a\tb\"",
	} {
		if got, err := Word(in); err != nil || got != want {
			t.Errorf("Word(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", `say "hi"`, "two\nlines", "bell\a"} {
		if _, err := Word(in); err == nil {
			t.Errorf("Word(%q) took it", in)
		}
	}
}
