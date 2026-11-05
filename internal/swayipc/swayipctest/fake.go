// Package swayipctest is a fake tidewm for tests: a socket that answers
// sway's IPC, and remembers what it was sent.
package swayipctest

import (
	"encoding/binary"
	"io"
	"net"
	"path/filepath"
	"sync"
	"testing"
)

// Message is one message the fake was sent.
type Message struct {
	Type    uint32
	Payload string
}

// Fake answers each message with the next of its replies, of the type it
// was sent; the last reply answers every message after it.
type Fake struct {
	Socket string

	mu      sync.Mutex
	sent    []Message
	replies []string
}

// New starts a fake on a socket in a temporary directory, stopped when
// the test ends.
func New(t testing.TB, replies ...string) *Fake {
	t.Helper()
	if len(replies) == 0 {
		t.Fatal("swayipctest.New: no replies")
	}
	f := &Fake{Socket: filepath.Join(t.TempDir(), "ipc.sock"), replies: replies}
	ln, err := net.Listen("unix", f.Socket)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			f.answer(conn)
		}
	}()
	t.Cleanup(func() { ln.Close(); wg.Wait() })
	return f
}

// answer reads one message on conn and replies to it.
func (f *Fake) answer(conn net.Conn) {
	defer conn.Close()
	header := make([]byte, 14)
	if _, err := io.ReadFull(conn, header); err != nil || string(header[:6]) != "i3-ipc" {
		return
	}
	payload := make([]byte, binary.NativeEndian.Uint32(header[6:10]))
	if _, err := io.ReadFull(conn, payload); err != nil {
		return
	}
	kind := binary.NativeEndian.Uint32(header[10:14])
	f.mu.Lock()
	reply := f.replies[min(len(f.sent), len(f.replies)-1)]
	f.sent = append(f.sent, Message{kind, string(payload)})
	f.mu.Unlock()
	out := append([]byte("i3-ipc"), binary.NativeEndian.AppendUint32(nil, uint32(len(reply)))...)
	out = binary.NativeEndian.AppendUint32(out, kind)
	conn.Write(append(out, reply...))
}

// Sent is every message the fake has answered, in order.
func (f *Fake) Sent() []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]Message(nil), f.sent...)
}

// Payloads is the payload of each message Sent.
func (f *Fake) Payloads() []string {
	var p []string
	for _, m := range f.Sent() {
		p = append(p, m.Payload)
	}
	return p
}
