package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Chrome's native messaging (SPEC.md §8.3): each message is UTF-8 JSON
// after its length, a 32-bit unsigned integer in the machine's own byte
// order. Chrome sends a host up to 64 MiB at once, and takes at most 1 MiB
// back.
const (
	maxFromBrowser = 64 << 20
	maxToBrowser   = 1 << 20
	// A line from a host to the relay, or from the relay to the shell: one
	// browser's tabs, re-encoded, so no larger than what the browser sent.
	maxLine = maxFromBrowser
)

var errTooBig = errors.New("message too big")

// readFrame reads one message. io.EOF means the browser closed the port
// between messages.
func readFrame(r io.Reader) ([]byte, error) {
	var n uint32
	if err := binary.Read(r, binary.NativeEndian, &n); err != nil {
		return nil, err
	}
	if n > maxFromBrowser {
		return nil, fmt.Errorf("%w: %d bytes", errTooBig, n)
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return b, nil
}

// writeFrame writes v as one message, in a single write.
func writeFrame(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(b) > maxToBrowser {
		return fmt.Errorf("%w: %d bytes", errTooBig, len(b))
	}
	out := make([]byte, 4+len(b))
	binary.NativeEndian.PutUint32(out, uint32(len(b)))
	copy(out[4:], b)
	_, err = w.Write(out)
	return err
}

// What the extension sends (tileco's src/tabsbridge.js): every normal
// window of one browser, and its tabs. Only these fields go on, so nothing
// else the extension or another local process puts in reaches the shell.
type tab struct {
	ID     int    `json:"id"`
	Title  string `json:"title"`
	URL    string `json:"url"`
	Active bool   `json:"active"`
}

type window struct {
	ID      int    `json:"id"`
	Focused bool   `json:"focused"`
	Title   string `json:"title"`
	Tabs    []tab  `json:"tabs"`
}

type tabsMessage struct {
	Type string `json:"type"`
	// Set by the relay: which host connection it came from.
	Source  string   `json:"source,omitempty"`
	Browser string   `json:"browser"`
	Windows []window `json:"windows"`
}

// parseTabs checks a tabs message. A window or tab list that's missing is
// empty, so the shell never meets a null.
func parseTabs(b []byte) (tabsMessage, error) {
	var m tabsMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return m, fmt.Errorf("not a JSON object: %w", err)
	}
	if m.Type != "tabs" {
		return m, fmt.Errorf("unknown type %q", m.Type)
	}
	if m.Windows == nil {
		m.Windows = []window{}
	}
	for i := range m.Windows {
		if m.Windows[i].Tabs == nil {
			m.Windows[i].Tabs = []tab{}
		}
	}
	m.Source = ""
	return m, nil
}

// What the shell asks for: a tab brought up, with its window. Source says
// which browser, as the relay named it.
type activate struct {
	Type     string `json:"type"`
	Source   string `json:"source,omitempty"`
	TabID    int    `json:"tabId"`
	WindowID int    `json:"windowId"`
}

func parseActivate(b []byte) (activate, error) {
	var raw struct {
		Type     string          `json:"type"`
		Source   string          `json:"source"`
		TabID    json.RawMessage `json:"tabId"`
		WindowID json.RawMessage `json:"windowId"`
	}
	var a activate
	if err := json.Unmarshal(b, &raw); err != nil {
		return a, fmt.Errorf("not a JSON object: %w", err)
	}
	if raw.Type != "activate" {
		return a, fmt.Errorf("unknown type %q", raw.Type)
	}
	if err := json.Unmarshal(raw.TabID, &a.TabID); err != nil {
		return a, errors.New("activate without a whole-number tabId")
	}
	if err := json.Unmarshal(raw.WindowID, &a.WindowID); err != nil {
		return a, errors.New("activate without a whole-number windowId")
	}
	a.Type = "activate"
	a.Source = raw.Source
	return a, nil
}
