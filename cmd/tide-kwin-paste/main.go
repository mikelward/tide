// Command tide-kwin-paste pastes into the focused window on KDE Plasma's
// Wayland session (SPEC.md §8.4): it presses Ctrl+V, or Ctrl+Shift+V with
// --shift, through KWin's org_kde_kwin_fake_input.
//
//	tide-kwin-paste [--shift]
//
// Wayland has no common way for one program to press keys in another's
// window. Hyprland has its own (the picker's send_shortcut). wtype uses the
// virtual-keyboard protocol, which KWin offers only to the on-screen
// keyboard, and ydotool needs /dev/uinput. KWin's fake-input does it, and
// from version 6 (Plasma 6.5) takes keys by keysym, so KWin finds the key
// for "v" in the layout in use: Dvorak's isn't QWERTY's.
//
// Released Plasma (6.5 to 6.7) offers fake-input only to a program whose
// desktop entry lists it in X-KDE-Wayland-Interfaces, found by the path of
// the running executable (KWin's wayland_server.cpp and
// utils/serviceutils.h). That's why this is a compiled program, not a
// script, whose executable would be the interpreter's: `make install-kde`
// installs session/tide-kwin-paste.desktop beside it, naming its path.
// Plasma 6.8 drops that rule for programs outside a sandbox.
//
// It speaks the Wayland wire protocol itself, with only the standard
// library. Exits 1, saying why, when there's no Wayland session, KWin
// doesn't offer fake-input version 6, or KWin reports an error; 2 for a bad
// argument.
package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
)

const (
	iface   = "org_kde_kwin_fake_input"
	version = 6

	// Requests, numbered in the order fake-input.xml
	// (plasma-wayland-protocols) declares them.
	reqAuthenticate   = 0
	reqKeyboardKeysym = 12

	// wl_display, wl_registry and wl_callback, from wayland.xml.
	displayID          = 1
	displaySync        = 0
	displayGetRegistry = 1
	displayError       = 0
	registryBind       = 0
	registryGlobal     = 0
	callbackDone       = 0

	keyControlL = 0xffe3
	keyShiftL   = 0xffe1
	keyV        = 0x0076
	pressed     = 1
	released    = 0
)

func str(s string) []byte {
	data := append([]byte(s), 0)
	b := binary.LittleEndian.AppendUint32(nil, uint32(len(data)))
	b = append(b, data...)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	return b
}

func u32(v ...uint32) []byte {
	var b []byte
	for _, x := range v {
		b = binary.LittleEndian.AppendUint32(b, x)
	}
	return b
}

func message(obj uint32, opcode uint16, payload ...[]byte) []byte {
	body := bytes.Join(payload, nil)
	return append(u32(obj, uint32(8+len(body))<<16|uint32(opcode)), body...)
}

func readStr(p []byte, at int) (string, int, error) {
	if at+4 > len(p) {
		return "", 0, errors.New("the compositor sent a short message")
	}
	n := int(binary.LittleEndian.Uint32(p[at:]))
	end := at + 4 + n
	if n == 0 || end > len(p) {
		return "", 0, errors.New("the compositor sent a malformed string")
	}
	s := string(p[at+4 : end-1])
	for end%4 != 0 {
		end++
	}
	return s, end, nil
}

type event struct {
	obj    uint32
	opcode uint16
	body   []byte
}

type conn struct {
	rw   io.ReadWriter
	next uint32
}

func (c *conn) newID() uint32 {
	c.next++
	return c.next
}

func (c *conn) send(b []byte) error {
	_, err := c.rw.Write(b)
	return err
}

func (c *conn) read() (event, error) {
	var head [8]byte
	if _, err := io.ReadFull(c.rw, head[:]); err != nil {
		return event{}, errors.New("the compositor closed the connection")
	}
	word := binary.LittleEndian.Uint32(head[4:])
	size := int(word >> 16)
	if size < 8 {
		return event{}, errors.New("the compositor sent a malformed message")
	}
	body := make([]byte, size-8)
	if _, err := io.ReadFull(c.rw, body); err != nil {
		return event{}, errors.New("the compositor closed the connection")
	}
	return event{binary.LittleEndian.Uint32(head[:]), uint16(word), body}, nil
}

// roundtrip sends a sync and returns the events before its done, or the
// compositor's error.
func (c *conn) roundtrip() ([]event, error) {
	callback := c.newID()
	if err := c.send(message(displayID, displaySync, u32(callback))); err != nil {
		return nil, err
	}
	var seen []event
	for {
		e, err := c.read()
		if err != nil {
			return nil, err
		}
		if e.obj == displayID && e.opcode == displayError && len(e.body) >= 8 {
			code := binary.LittleEndian.Uint32(e.body[4:])
			text, _, _ := readStr(e.body, 8)
			return nil, fmt.Errorf("the compositor reported error %d: %s", code, text)
		}
		if e.obj == callback && e.opcode == callbackDone {
			return seen, nil
		}
		seen = append(seen, e)
	}
}

// paste presses Ctrl(+Shift)+V over rw, a connection to the compositor.
func paste(rw io.ReadWriter, shift bool) error {
	c := &conn{rw: rw, next: 1}
	registry := c.newID()
	if err := c.send(message(displayID, displayGetRegistry, u32(registry))); err != nil {
		return err
	}
	events, err := c.roundtrip()
	if err != nil {
		return err
	}
	var name, offered uint32
	found := false
	for _, e := range events {
		if e.obj != registry || e.opcode != registryGlobal || len(e.body) < 4 {
			continue
		}
		s, at, err := readStr(e.body, 4)
		if err != nil {
			return err
		}
		if s == iface && at+4 <= len(e.body) {
			name, offered, found = binary.LittleEndian.Uint32(e.body), binary.LittleEndian.Uint32(e.body[at:]), true
		}
	}
	if !found {
		return fmt.Errorf("the compositor offers no %s, so this can't paste: it's for KDE Plasma's Wayland session, "+
			"and KWin offers it only to programs its desktop entry names (session/tide-kwin-paste.desktop)", iface)
	}
	if offered < version {
		return fmt.Errorf("KWin offers %s version %d, and pasting needs %d (Plasma 6.5 or later), which presses keys by name",
			iface, offered, version)
	}
	fake := c.newID()
	reqs := [][]byte{
		message(registry, registryBind, u32(name), str(iface), u32(version, fake)),
		message(fake, reqAuthenticate, str("Clipboard menu"), str("Paste what you chose")),
	}
	keys := []uint32{keyControlL}
	if shift {
		keys = append(keys, keyShiftL)
	}
	keys = append(keys, keyV)
	for _, k := range keys {
		reqs = append(reqs, message(fake, reqKeyboardKeysym, u32(k, pressed)))
	}
	for i := len(keys) - 1; i >= 0; i-- {
		reqs = append(reqs, message(fake, reqKeyboardKeysym, u32(keys[i], released)))
	}
	if err := c.send(bytes.Join(reqs, nil)); err != nil {
		return err
	}
	// The sync's done comes once KWin has handled every request before
	// it, or its error does.
	_, err = c.roundtrip()
	return err
}

func socketPath(getenv func(string) string) (string, error) {
	display := getenv("WAYLAND_DISPLAY")
	if display == "" {
		display = "wayland-0"
	}
	if filepath.IsAbs(display) {
		return display, nil
	}
	runtime := getenv("XDG_RUNTIME_DIR")
	if runtime == "" {
		return "", errors.New("XDG_RUNTIME_DIR isn't set, so there's no Wayland session to paste in")
	}
	return filepath.Join(runtime, display), nil
}

func run(args []string, getenv func(string) string, stderr io.Writer) int {
	if len(args) > 1 || (len(args) == 1 && args[0] != "--shift") {
		fmt.Fprintln(stderr, "usage: tide-kwin-paste [--shift]")
		return 2
	}
	fail := func(err error) int {
		fmt.Fprintf(stderr, "tide-kwin-paste: %s\n", strings.TrimSpace(err.Error()))
		return 1
	}
	path, err := socketPath(getenv)
	if err != nil {
		return fail(err)
	}
	c, err := net.Dial("unix", path)
	if err != nil {
		return fail(fmt.Errorf("couldn't reach the Wayland compositor at %s: %w", path, err))
	}
	defer c.Close()
	if err := paste(c, len(args) == 1); err != nil {
		return fail(err)
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stderr))
}
