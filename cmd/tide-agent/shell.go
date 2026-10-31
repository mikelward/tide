package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"sync"
)

// A field the shell asks for. Value is what to fill in, which can be a
// saved secret, so no line to or from the shell is ever logged.
type field struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	Secret bool   `json:"secret"`
	Value  string `json:"value"`
}

// The connection a request is for, as the shell names it.
type connInfo struct {
	ID   string `json:"id"`
	UUID string `json:"uuid"`
	Type string `json:"type"`
}

// A request for the shell to ask for something (SPEC.md §5.6). Kind is
// "wifi", "8021x", "vpn" (fields from the plugin's dialog) or
// "vpn-dialog" (the plugin's own window, which runs once the shell says
// "go"); or for BlueZ, "bt-pin", "bt-passkey", "bt-confirm",
// "bt-authorize", "bt-service" and "bt-display" (a code to show, which
// stays until it's canceled). Accept and Decline name the prompt's buttons
// where they aren't Connect and Cancel; a bt-display has no Accept.
type request struct {
	Type          string   `json:"type"`
	ID            string   `json:"id"`
	Kind          string   `json:"kind"`
	Title         string   `json:"title"`
	Message       string   `json:"message"`
	Fields        []field  `json:"fields"`
	Connection    connInfo `json:"connection"`
	SSID          string   `json:"ssid,omitempty"`
	UserRequested bool     `json:"userRequested"`
	Accept        string   `json:"accept,omitempty"`
	Decline       string   `json:"decline,omitempty"`
}

// The shell's answer to a request: "reply" with values, "go", "cancel"
// (you said no) or "decline" (the shell won't ask). "gone" is made here,
// when the shell has closed its end.
type answer struct {
	Type   string            `json:"type"`
	ID     string            `json:"id"`
	Values map[string]string `json:"values"`
}

var answerTypes = map[string]bool{"reply": true, "go": true, "cancel": true, "decline": true}

// The longest line the shell sends: a few fields of text.
const maxLine = 1 << 20

// shellLink is the helper's end of the pipe to the shell: requests and
// news out on stdout, answers in on stdin.
type shellLink struct {
	mu      sync.Mutex
	out     *json.Encoder
	pending map[string]chan answer
	next    int
	closed  bool
	// Closed once stdin ends.
	done chan struct{}
}

func newShellLink(out io.Writer) *shellLink {
	return &shellLink{
		out:     json.NewEncoder(out),
		pending: map[string]chan answer{},
		done:    make(chan struct{}),
	}
}

// send writes one message. A shell that has gone can't be told anything,
// which the caller learns from the error.
func (s *shellLink) send(msg any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.out.Encode(msg)
}

// ask sends req and waits for its answer, or for ctx to end, which tells
// the shell to take the request down.
func (s *shellLink) ask(ctx context.Context, req request) (answer, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return answer{Type: "gone"}, nil
	}
	s.next++
	req.Type = "request"
	req.ID = strconv.Itoa(s.next)
	ch := make(chan answer, 1)
	s.pending[req.ID] = ch
	err := s.out.Encode(req)
	s.mu.Unlock()
	if err != nil {
		s.forget(req.ID)
		return answer{}, fmt.Errorf("couldn't send the request to the shell: %w", err)
	}
	select {
	case a := <-ch:
		return a, nil
	case <-ctx.Done():
		s.forget(req.ID)
		if err := s.send(map[string]string{"type": "cancel", "id": req.ID}); err != nil {
			return answer{}, fmt.Errorf("couldn't tell the shell to cancel: %w", err)
		}
		return answer{}, ctx.Err()
	}
}

func (s *shellLink) forget(id string) {
	s.mu.Lock()
	delete(s.pending, id)
	s.mu.Unlock()
}

// read takes the shell's answers until stdin closes, then answers every
// waiting request "gone". An answer to a request that has already ended
// (canceled by NetworkManager, say) is dropped. A line it can't read is an
// error: the shell and the helper disagree about the protocol.
func (s *shellLink) read(in io.Reader) error {
	defer func() {
		s.mu.Lock()
		s.closed = true
		for id, ch := range s.pending {
			ch <- answer{Type: "gone", ID: id}
			delete(s.pending, id)
		}
		s.mu.Unlock()
		close(s.done)
	}()
	lines := bufio.NewScanner(in)
	lines.Buffer(make([]byte, 0, 4096), maxLine)
	for lines.Scan() {
		var a answer
		if err := json.Unmarshal(lines.Bytes(), &a); err != nil {
			// Not the line itself: it may hold a password.
			return errors.New("a line from the shell isn't a JSON object")
		}
		if !answerTypes[a.Type] {
			return fmt.Errorf("the shell sent %q, which isn't an answer", a.Type)
		}
		s.mu.Lock()
		ch, ok := s.pending[a.ID]
		delete(s.pending, a.ID)
		s.mu.Unlock()
		if ok {
			ch <- a
		}
	}
	return lines.Err()
}
