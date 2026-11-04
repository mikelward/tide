package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

type global struct {
	iface   string
	version uint32
}

// compositor is a stand-in that speaks enough of the Wayland wire protocol:
// it answers get_registry with globals, each sync with done (or, with
// errorText, the second sync with a wl_display error), and records the
// fake-input requests. That checks the bytes KWin would get, not KWin: a
// real session's paste can only be seen on Plasma.
type compositor struct {
	globals   []global
	errorText string

	mu       sync.Mutex
	requests []string
}

func (s *compositor) serve(rw io.ReadWriter) {
	var registry uint32
	syncs := 0
	for {
		var head [8]byte
		if _, err := io.ReadFull(rw, head[:]); err != nil {
			return
		}
		obj := binary.LittleEndian.Uint32(head[:])
		word := binary.LittleEndian.Uint32(head[4:])
		body := make([]byte, int(word>>16)-8)
		if _, err := io.ReadFull(rw, body); err != nil {
			return
		}
		opcode := uint16(word)
		switch {
		case obj == displayID && opcode == displayGetRegistry:
			registry = binary.LittleEndian.Uint32(body)
			for i, g := range s.globals {
				rw.Write(message(registry, registryGlobal, u32(uint32(i+1)), str(g.iface), u32(g.version)))
			}
		case obj == displayID && opcode == displaySync:
			callback := binary.LittleEndian.Uint32(body)
			syncs++
			if s.errorText != "" && syncs == 2 {
				rw.Write(message(displayID, displayError, u32(callback, 3), str(s.errorText)))
			} else {
				rw.Write(message(callback, callbackDone, u32(0)))
			}
		case obj == registry && opcode == registryBind:
			name, at, _ := readStr(body, 4)
			s.record("bind " + name + " v" + string(rune('0'+binary.LittleEndian.Uint32(body[at:]))))
		case opcode == reqAuthenticate:
			app, _, _ := readStr(body, 0)
			s.record("authenticate " + app)
		case opcode == reqKeyboardKeysym:
			k, st := binary.LittleEndian.Uint32(body), binary.LittleEndian.Uint32(body[4:])
			names := map[uint32]string{keyControlL: "Control_L", keyShiftL: "Shift_L", keyV: "v", keyReturn: "Return", 'h': "h", 'é': "eacute", 0x0100263a: "U263A"}
			s.record(map[uint32]string{1: "press ", 0: "release "}[st] + names[k])
		default:
			s.record("other")
		}
	}
}

func (s *compositor) record(r string) {
	s.mu.Lock()
	s.requests = append(s.requests, r)
	s.mu.Unlock()
}

// listen serves one client on a socket in a fresh XDG_RUNTIME_DIR, and
// returns the getenv that finds it.
func listen(t *testing.T, s *compositor) func(string) string {
	t.Helper()
	dir := t.TempDir()
	l, err := net.Listen("unix", filepath.Join(dir, "wayland-1"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		s.serve(c)
	}()
	return func(k string) string {
		return map[string]string{"XDG_RUNTIME_DIR": dir, "WAYLAND_DISPLAY": "wayland-1"}[k]
	}
}

var kde = []global{{"wl_compositor", 6}, {iface, 6}, {"wl_seat", 9}}

func TestCtrlVPastesByKeysym(t *testing.T) {
	s := &compositor{globals: kde}
	var stderr bytes.Buffer
	if code := run(nil, listen(t, s), nil, &stderr); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	want := []string{"bind org_kde_kwin_fake_input v6", "authenticate Clipboard menu",
		"press Control_L", "press v", "release v", "release Control_L"}
	if !reflect.DeepEqual(s.requests, want) {
		t.Errorf("requests %q, want %q", s.requests, want)
	}
}

func TestShiftPastesWithCtrlShiftV(t *testing.T) {
	s := &compositor{globals: kde}
	var stderr bytes.Buffer
	if code := run([]string{"--shift"}, listen(t, s), nil, &stderr); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	want := []string{"press Control_L", "press Shift_L", "press v", "release v", "release Shift_L", "release Control_L"}
	if !reflect.DeepEqual(s.requests[2:], want) {
		t.Errorf("keys %q, want %q", s.requests[2:], want)
	}
}

func TestFailures(t *testing.T) {
	for _, tc := range []struct {
		name    string
		s       *compositor
		wants   []string
		pressed bool // the keys went before KWin's error came back
	}{
		{"no fake-input, as on sway or for a program KWin doesn't allow",
			&compositor{globals: []global{{"wl_compositor", 6}}},
			[]string{"no org_kde_kwin_fake_input", "tide-kwin-paste.desktop"}, false},
		{"fake-input before version 6", &compositor{globals: []global{{iface, 5}}},
			[]string{"version 5", "Plasma 6.5"}, false},
		{"an error from KWin", &compositor{globals: kde, errorText: "not allowed"},
			[]string{"error 3: not allowed"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var stderr bytes.Buffer
			if code := run(nil, listen(t, tc.s), nil, &stderr); code != 1 {
				t.Errorf("exit %d, want 1", code)
			}
			for _, w := range tc.wants {
				if !strings.Contains(stderr.String(), w) {
					t.Errorf("stderr %q lacks %q", stderr.String(), w)
				}
			}
			if !tc.pressed && strings.Contains(strings.Join(tc.s.requests, " "), "press") {
				t.Errorf("pressed keys anyway: %q", tc.s.requests)
			}
		})
	}
}

func TestNoSession(t *testing.T) {
	var stderr bytes.Buffer
	dir := t.TempDir()
	env := func(k string) string { return map[string]string{"XDG_RUNTIME_DIR": dir}[k] }
	if code := run(nil, env, nil, &stderr); code != 1 || !strings.Contains(stderr.String(), filepath.Join(dir, "wayland-0")) {
		t.Errorf("no compositor: exit %d, %q; want 1, naming the socket", code, stderr.String())
	}
	stderr.Reset()
	if code := run(nil, func(string) string { return "" }, nil, &stderr); code != 1 || !strings.Contains(stderr.String(), "XDG_RUNTIME_DIR") {
		t.Errorf("no XDG_RUNTIME_DIR: exit %d, %q", code, stderr.String())
	}
}

func TestUsage(t *testing.T) {
	var stderr bytes.Buffer
	if code := run([]string{"--ctrl"}, nil, nil, &stderr); code != 2 || !strings.Contains(stderr.String(), "usage") {
		t.Errorf("exit %d, %q; want 2 and usage", code, stderr.String())
	}
}

func TestTypeTypesStdinByKeysym(t *testing.T) {
	s := &compositor{globals: kde}
	var stderr bytes.Buffer
	if code := run([]string{"--type"}, listen(t, s), strings.NewReader("hé\n\x07☺"), &stderr); code != 0 {
		t.Fatalf("exit %d: %s", code, stderr.String())
	}
	want := []string{"press h", "release h", "press eacute", "release eacute", "press Return", "release Return",
		"press U263A", "release U263A"}
	if !reflect.DeepEqual(s.requests[2:], want) {
		t.Errorf("keys %q, want %q: Latin-1 as itself, newline as Return, a bell left out, the rest as Unicode", s.requests[2:], want)
	}
}

func TestTypeRefusesTooMuch(t *testing.T) {
	var stderr bytes.Buffer
	big := strings.NewReader(strings.Repeat("a", maxType+1))
	if code := run([]string{"--type"}, func(string) string { return "" }, big, &stderr); code != 1 || !strings.Contains(stderr.String(), "64 KiB") {
		t.Errorf("exit %d, %q; want 1 and the limit", code, stderr.String())
	}
}
