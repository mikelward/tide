package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// The host's waits between tries for the shell's socket: short, since a
// shell restart should list the tabs again at once, and capped, since each
// try is one failed connect.
const (
	firstRetry = 250 * time.Millisecond
	maxRetry   = 5 * time.Second
)

func retryDelay(attempt int) time.Duration {
	d := firstRetry
	for i := 0; i < attempt && d < maxRetry; i++ {
		d *= 2
	}
	if d > maxRetry {
		d = maxRetry
	}
	return d
}

type hostConfig struct {
	dial func() (net.Conn, error)
	// after(d) fires once d has passed; tests fire it at once.
	after func(time.Duration) <-chan time.Time
}

// host is the browser's end: Chrome starts it, and it relays between the
// extension (frames on stdin and stdout) and the shell (lines on the
// relay's socket), for as long as Chrome keeps the port open.
type host struct {
	cfg    hostConfig
	log    io.Writer
	outMu  sync.Mutex
	out    io.Writer
	mu     sync.Mutex
	shell  net.Conn
	last   []byte
	closed bool
}

func (h *host) toBrowser(v any) error {
	h.outMu.Lock()
	defer h.outMu.Unlock()
	return writeFrame(h.out, v)
}

func (h *host) logf(format string, args ...any) {
	fmt.Fprintf(h.log, "tide-tabs: "+format+"\n", args...)
}

// toShell sends a browser's tabs on, if the shell is there, and keeps them
// for when it next is.
func (h *host) toShell(line []byte) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.last = line
	if h.shell == nil {
		return
	}
	if _, err := h.shell.Write(line); err != nil {
		// The reader sees the same and reconnects.
		h.logf("couldn't send the tabs to the shell: %v", err)
	}
}

func runHost(stdin io.Reader, stdout, stderr io.Writer, cfg hostConfig) int {
	h := &host{cfg: cfg, log: stderr, out: stdout}
	if err := h.toBrowser(map[string]any{"type": "hello", "version": 1}); err != nil {
		h.logf("couldn't write to the browser: %v", err)
		return 1
	}
	done := make(chan struct{})
	go h.dialLoop(done)
	defer func() {
		close(done)
		h.mu.Lock()
		h.closed = true
		if h.shell != nil {
			h.shell.Close()
		}
		h.mu.Unlock()
	}()
	for {
		b, err := readFrame(stdin)
		if errors.Is(err, io.EOF) {
			// The browser closed the port: the extension went, or the
			// browser quit.
			return 0
		}
		if err != nil {
			h.logf("couldn't read from the browser: %v", err)
			return 1
		}
		m, err := parseTabs(b)
		if err != nil {
			h.logf("ignoring a message from the browser: %v", err)
			continue
		}
		line, err := json.Marshal(m)
		if err != nil {
			h.logf("couldn't encode the tabs: %v", err)
			continue
		}
		h.toShell(append(line, '\n'))
	}
}

// dialLoop keeps a connection to the shell's relay: each time it's lost,
// the extension hears so, and it tries again.
func (h *host) dialLoop(done <-chan struct{}) {
	attempt := 0
	for {
		conn, err := h.cfg.dial()
		if err == nil {
			attempt = 0
			h.serveShell(conn)
		} else if attempt == 0 {
			h.logf("tide's shell isn't listening (%v); trying again until it is", err)
		}
		select {
		case <-done:
			return
		case <-h.cfg.after(retryDelay(attempt)):
		}
		attempt++
	}
}

// serveShell runs one connection to the relay, until it ends.
func (h *host) serveShell(conn net.Conn) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		conn.Close()
		return
	}
	// What the shell missed goes first, under the lock toShell takes, so
	// a newer list can't reach the shell before it and be overwritten.
	if h.last != nil {
		if _, err := conn.Write(h.last); err != nil {
			h.logf("couldn't send the tabs to the shell: %v", err)
		}
	}
	h.shell = conn
	h.mu.Unlock()
	if err := h.toBrowser(map[string]any{"type": "shell", "connected": true}); err != nil {
		h.logf("couldn't write to the browser: %v", err)
	}
	// Then the extension's own list, which may be newer.
	if err := h.toBrowser(map[string]string{"type": "refresh"}); err != nil {
		h.logf("couldn't write to the browser: %v", err)
	}
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 4096), maxLine)
	for sc.Scan() {
		a, err := parseActivate(sc.Bytes())
		if err != nil {
			h.logf("ignoring a line from the shell: %v", err)
			continue
		}
		a.Source = ""
		if err := h.toBrowser(a); err != nil {
			h.logf("couldn't write to the browser: %v", err)
		}
	}
	if err := sc.Err(); err != nil && !errors.Is(err, net.ErrClosed) {
		h.logf("lost the shell: %v", err)
	}
	h.mu.Lock()
	h.shell = nil
	closed := h.closed
	h.mu.Unlock()
	conn.Close()
	if !closed {
		if err := h.toBrowser(map[string]any{"type": "shell", "connected": false}); err != nil {
			h.logf("couldn't write to the browser: %v", err)
		}
	}
}
