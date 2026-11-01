package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestFramesRoundTripInNativeOrder(t *testing.T) {
	var b bytes.Buffer
	if err := writeFrame(&b, map[string]string{"type": "refresh"}); err != nil {
		t.Fatal(err)
	}
	want := `{"type":"refresh"}`
	if n := binary.NativeEndian.Uint32(b.Bytes()[:4]); n != uint32(len(want)) {
		t.Fatalf("length %d, want %d", n, len(want))
	}
	got, err := readFrame(&b)
	if err != nil || string(got) != want {
		t.Fatalf("readFrame = %q, %v", got, err)
	}
	if _, err := readFrame(&b); !errors.Is(err, io.EOF) {
		t.Fatalf("at the end: %v, want EOF", err)
	}
}

func TestFrameLimits(t *testing.T) {
	var b bytes.Buffer
	binary.Write(&b, binary.NativeEndian, uint32(maxFromBrowser+1))
	if _, err := readFrame(&b); !errors.Is(err, errTooBig) {
		t.Fatalf("an oversized frame: %v", err)
	}
	b.Reset()
	binary.Write(&b, binary.NativeEndian, uint32(10))
	b.WriteString("{}")
	if _, err := readFrame(&b); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("a cut-off frame: %v", err)
	}
	if err := writeFrame(io.Discard, strings.Repeat("x", maxToBrowser)); !errors.Is(err, errTooBig) {
		t.Fatalf("a frame over Chrome's 1 MiB: %v", err)
	}
}

func TestParseTabsKeepsOnlyKnownFields(t *testing.T) {
	m, err := parseTabs([]byte(`{"type":"tabs","source":"9","browser":"Brave","windows":[{"id":1,"focused":true,"title":"Docs","favicon":"x","tabs":[{"id":12,"title":"Docs","url":"https://docs.example.com/","active":true,"cookie":"x"}]},{"id":2}]}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(m)
	want := `{"type":"tabs","browser":"Brave","windows":[{"id":1,"focused":true,"title":"Docs","tabs":[{"id":12,"title":"Docs","url":"https://docs.example.com/","active":true}]},{"id":2,"focused":false,"title":"","tabs":[]}]}`
	if string(b) != want {
		t.Fatalf("got  %s\nwant %s", b, want)
	}
	for _, bad := range []string{`[]`, `{"type":"navigate"}`, `{"type":"tabs","windows":[{"id":"1"}]}`} {
		if _, err := parseTabs([]byte(bad)); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
}

func TestParseActivate(t *testing.T) {
	a, err := parseActivate([]byte(`{"type":"activate","source":"1","tabId":12,"windowId":1}`))
	if err != nil || a != (activate{Type: "activate", Source: "1", TabID: 12, WindowID: 1}) {
		t.Fatalf("got %+v, %v", a, err)
	}
	for _, bad := range []string{`{"type":"activate","tabId":12}`, `{"type":"activate","tabId":"12","windowId":1}`, `{"type":"activate","tabId":1.5,"windowId":1}`, `{"type":"close","tabId":1,"windowId":1}`} {
		if _, err := parseActivate([]byte(bad)); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
}

func TestRetryDelayBacksOffToAFewSeconds(t *testing.T) {
	var got []time.Duration
	for i := 0; i < 8; i++ {
		got = append(got, retryDelay(i))
	}
	want := []time.Duration{250 * time.Millisecond, 500 * time.Millisecond, time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second, 5 * time.Second, 5 * time.Second}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestSocketPath(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if p, err := socketPath(env(map[string]string{"XDG_RUNTIME_DIR": "/run/user/1000"})); err != nil || p != "/run/user/1000/tide/tabs.sock" {
		t.Fatalf("got %q, %v", p, err)
	}
	if p, _ := socketPath(env(map[string]string{"XDG_RUNTIME_DIR": "/run/user/1000", "TIDE_TABS_SOCKET": "/tmp/x.sock"})); p != "/tmp/x.sock" {
		t.Fatalf("the override: %q", p)
	}
	if _, err := socketPath(env(nil)); err == nil {
		t.Fatal("no runtime dir, but no error")
	}
}

func TestRunRefusesAnythingButABrowserOrServe(t *testing.T) {
	var stderr bytes.Buffer
	env := func(string) string { return "/run/user/1000" }
	if code := run([]string{"--help"}, strings.NewReader(""), io.Discard, &stderr, env); code != 2 {
		t.Fatalf("exit %d", code)
	}
	if !strings.Contains(stderr.String(), "usage") {
		t.Fatalf("stderr %q", stderr.String())
	}
}

// A relay and its shell's pipes.
type testRelay struct {
	path  string
	in    *io.PipeWriter
	out   *bufio.Scanner
	done  chan int
	stder *bytes.Buffer
}

func startRelay(t *testing.T) *testRelay {
	t.Helper()
	// Short: a socket's path has to fit in 108 bytes.
	dir, err := os.MkdirTemp("", "tt")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	r := &testRelay{path: filepath.Join(dir, "tide", "tabs.sock"), done: make(chan int, 1), stder: &bytes.Buffer{}}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	r.in = inW
	r.out = bufio.NewScanner(outR)
	go func() {
		r.done <- runServe(inR, outW, r.stder, r.path)
		outW.Close()
	}()
	if got := r.line(t); got["type"] != "ready" {
		t.Fatalf("first line %v", got)
	}
	return r
}

func (r *testRelay) line(t *testing.T) map[string]any {
	t.Helper()
	if !r.out.Scan() {
		t.Fatalf("the relay's stdout ended: %v", r.out.Err())
	}
	var m map[string]any
	if err := json.Unmarshal(r.out.Bytes(), &m); err != nil {
		t.Fatalf("bad line %q: %v", r.out.Bytes(), err)
	}
	return m
}

// A host as Chrome runs it: frames in and out.
type testHost struct {
	in    *io.PipeWriter
	out   *io.PipeReader
	done  chan int
	retry chan time.Time
	// Each dial's result, in order.
	dials chan error
}

func startHost(t *testing.T, path string) *testHost {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &testHost{in: inW, out: outR, done: make(chan int, 1), retry: make(chan time.Time), dials: make(chan error, 16)}
	cfg := hostConfig{
		dial: func() (net.Conn, error) {
			c, err := net.Dial("unix", path)
			h.dials <- err
			return c, err
		},
		after: func(time.Duration) <-chan time.Time { return h.retry },
	}
	go func() {
		h.done <- runHost(inR, outW, io.Discard, cfg)
		outW.Close()
	}()
	return h
}

func (h *testHost) frame(t *testing.T) map[string]any {
	t.Helper()
	b, err := readFrame(h.out)
	if err != nil {
		t.Fatalf("reading the host's frame: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func (h *testHost) send(t *testing.T, v any) {
	t.Helper()
	if err := writeFrame(h.in, v); err != nil {
		t.Fatal(err)
	}
}

func expect(t *testing.T, got map[string]any, want string) {
	t.Helper()
	var w map[string]any
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, w) {
		b, _ := json.Marshal(got)
		t.Fatalf("got  %s\nwant %s", b, want)
	}
}

const tabsFrame = `{"type":"tabs","browser":"Google Chrome","windows":[{"id":1,"focused":true,"title":"Docs","tabs":[{"id":12,"title":"Docs","url":"https://docs.example.com/","active":true}]}]}`

func TestTabsGoFromBrowserToShellAndActivateComesBack(t *testing.T) {
	r := startRelay(t)
	h := startHost(t, r.path)
	expect(t, h.frame(t), `{"type":"hello","version":1}`)
	expect(t, h.frame(t), `{"connected":true,"type":"shell"}`)
	expect(t, h.frame(t), `{"type":"refresh"}`)

	var tabs map[string]any
	json.Unmarshal([]byte(tabsFrame), &tabs)
	h.send(t, tabs)
	got := r.line(t)
	if got["source"] != "1" {
		t.Fatalf("source %v", got["source"])
	}
	delete(got, "source")
	expect(t, got, tabsFrame)

	// A tab is asked for: it reaches that browser, without the source.
	io.WriteString(r.in, `{"type":"activate","source":"1","tabId":12,"windowId":1}`+"\n")
	expect(t, h.frame(t), `{"tabId":12,"type":"activate","windowId":1}`)
	// One for a browser that isn't there goes nowhere.
	io.WriteString(r.in, `{"type":"activate","source":"7","tabId":12,"windowId":1}`+"\n")

	// The browser closes the port: the host exits, and the shell hears.
	h.in.Close()
	if code := <-h.done; code != 0 {
		t.Fatalf("host exit %d", code)
	}
	expect(t, r.line(t), `{"source":"1","type":"gone"}`)
	r.in.Close()
	if code := <-r.done; code != 0 {
		t.Fatalf("relay exit %d", code)
	}
	if !strings.Contains(r.stder.String(), `no browser "7"`) {
		t.Fatalf("stderr %q", r.stder.String())
	}
	if _, err := os.Stat(r.path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the socket is left behind: %v", err)
	}
}

// The shell restarting is a relay going and another coming: the host says
// so, waits, and gives the new one the tabs it had.
func TestHostReconnectsWhenTheShellComesBack(t *testing.T) {
	dir, err := os.MkdirTemp("", "tt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "tabs.sock")
	h := startHost(t, path)
	expect(t, h.frame(t), `{"type":"hello","version":1}`)
	var tabs map[string]any
	json.Unmarshal([]byte(tabsFrame), &tabs)
	// Sent while no shell listens: kept.
	h.send(t, tabs)
	// The host has tried and failed before the shell comes up.
	if err := <-h.dials; err == nil {
		t.Fatal("the first dial reached a relay that isn't there")
	}

	r := startRelayAt(t, path)
	h.retry <- time.Time{}
	expect(t, h.frame(t), `{"connected":true,"type":"shell"}`)
	got := r.line(t)
	delete(got, "source")
	expect(t, got, tabsFrame)
	expect(t, h.frame(t), `{"type":"refresh"}`)

	// The shell goes.
	r.in.Close()
	<-r.done
	expect(t, h.frame(t), `{"connected":false,"type":"shell"}`)
	h.in.Close()
	if code := <-h.done; code != 0 {
		t.Fatalf("host exit %d", code)
	}
}

func startRelayAt(t *testing.T, path string) *testRelay {
	t.Helper()
	r := &testRelay{path: path, done: make(chan int, 1), stder: &bytes.Buffer{}}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	r.in = inW
	r.out = bufio.NewScanner(outR)
	go func() {
		r.done <- runServe(inR, outW, r.stder, path)
		outW.Close()
	}()
	if got := r.line(t); got["type"] != "ready" {
		t.Fatalf("first line %v", got)
	}
	return r
}

func TestOneRelayAtATime(t *testing.T) {
	r := startRelay(t)
	var out, stderr bytes.Buffer
	if code := runServe(strings.NewReader(""), &out, &stderr, r.path); code != 1 {
		t.Fatalf("a second relay: exit %d", code)
	}
	if !strings.Contains(out.String(), `"type":"fault"`) || !strings.Contains(stderr.String(), "another tide-tabs serve") {
		t.Fatalf("stdout %q, stderr %q", out.String(), stderr.String())
	}
	r.in.Close()
	<-r.done
}

func TestStaleSocketIsTakenOverAndPrivate(t *testing.T) {
	dir, err := os.MkdirTemp("", "tt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "tabs.sock")
	// A socket nothing listens on, as a relay that was killed leaves.
	l, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	l.Close()
	r := startRelayAt(t, path)
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v", fi.Mode().Perm())
	}
	r.in.Close()
	<-r.done
}

// A connection whose first write waits for the test to let it go, and
// which records what's written, in order.
type gatedConn struct {
	net.Conn
	entered chan struct{}
	gate    chan struct{}
	mu      sync.Mutex
	writes  []string
	n       int
}

func (g *gatedConn) Write(b []byte) (int, error) {
	g.mu.Lock()
	g.n++
	first := g.n == 1
	g.mu.Unlock()
	if first {
		close(g.entered)
		<-g.gate
	}
	g.mu.Lock()
	g.writes = append(g.writes, string(b))
	g.mu.Unlock()
	return len(b), nil
}

// A relay coming back gets the kept tabs, and a newer list sent while that
// replay is still being written goes after it, never before.
func TestReplayIsNeverOverwrittenByAnOlderList(t *testing.T) {
	near, far := net.Pipe()
	defer far.Close()
	g := &gatedConn{Conn: near, entered: make(chan struct{}), gate: make(chan struct{})}
	h := &host{log: io.Discard, out: io.Discard, last: []byte("old\n")}
	served := make(chan struct{})
	go func() {
		h.serveShell(g)
		close(served)
	}()
	<-g.entered
	// The replay holds the lock toShell needs, so the newer list waits.
	if h.mu.TryLock() {
		h.mu.Unlock()
		t.Fatal("the replay is written without the lock, so a newer list can pass it")
	}
	sent := make(chan struct{})
	go func() {
		h.toShell([]byte("new\n"))
		close(sent)
	}()
	close(g.gate)
	<-sent
	far.Close()
	<-served
	g.mu.Lock()
	defer g.mu.Unlock()
	if !reflect.DeepEqual(g.writes, []string{"old\n", "new\n"}) {
		t.Fatalf("the shell got %q", g.writes)
	}
}

// Two relays started at once: exactly one listens, the other stops, and
// the one that stops leaves the other's socket alone.
func TestTwoRelaysStartingAtOnce(t *testing.T) {
	dir, err := os.MkdirTemp("", "tt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "tabs.sock")
	type result struct {
		in   *io.PipeWriter
		out  *bufio.Scanner
		done chan int
	}
	start := make(chan struct{})
	var rs []*result
	for i := 0; i < 2; i++ {
		inR, inW := io.Pipe()
		outR, outW := io.Pipe()
		r := &result{in: inW, out: bufio.NewScanner(outR), done: make(chan int, 1)}
		rs = append(rs, r)
		go func() {
			<-start
			r.done <- runServe(inR, outW, io.Discard, path)
			outW.Close()
		}()
	}
	close(start)
	var winner, loser *result
	for _, r := range rs {
		if !r.out.Scan() {
			t.Fatal("a relay said nothing")
		}
		var m map[string]any
		json.Unmarshal(r.out.Bytes(), &m)
		switch m["type"] {
		case "ready":
			if winner != nil {
				t.Fatal("both relays are ready")
			}
			winner = r
		case "fault":
			loser = r
		default:
			t.Fatalf("first line %v", m)
		}
	}
	if winner == nil || loser == nil {
		t.Fatal("not one of each")
	}
	if code := <-loser.done; code != 1 {
		t.Fatalf("the second relay: exit %d", code)
	}
	// The winner's socket still answers.
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("the winner's socket is gone: %v", err)
	}
	c.Close()
	winner.in.Close()
	for winner.out.Scan() {
	}
	if code := <-winner.done; code != 0 {
		t.Fatalf("the relay: exit %d", code)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the socket is left behind: %v", err)
	}
}

// A relay leaves a socket that isn't its own, made after it, alone.
func TestRelayRemovesOnlyItsOwnSocket(t *testing.T) {
	dir, err := os.MkdirTemp("", "tt")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "tabs.sock")
	l, err := listen(path)
	if err != nil {
		t.Fatal(err)
	}
	os.Remove(path)
	other, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	l.Close()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("someone else's socket went: %v", err)
	}
}
