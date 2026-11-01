package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
)

// relay is the shell's end: the shell starts `tide-tabs serve`, which
// listens on a socket for the hosts each browser starts, and passes their
// tabs to the shell on stdout and the shell's asks back to them, a JSON
// object per line each way.
type relay struct {
	log   io.Writer
	outMu sync.Mutex
	out   *json.Encoder
	mu    sync.Mutex
	hosts map[string]net.Conn
	next  int
}

func (r *relay) logf(format string, args ...any) {
	fmt.Fprintf(r.log, "tide-tabs: "+format+"\n", args...)
}

func (r *relay) toShell(v any) {
	r.outMu.Lock()
	defer r.outMu.Unlock()
	if err := r.out.Encode(v); err != nil {
		r.logf("couldn't write to the shell: %v", err)
	}
}

// listen makes the socket, in a directory only you can enter. A lock
// beside it, held for as long as the relay listens, makes the relay the
// only one: a second one stops, and a socket left by one that died is
// taken over, since the kernel lets its lock go with it.
func listen(path string) (net.Listener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("couldn't make %s: %w", filepath.Dir(path), err)
	}
	lock, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("couldn't open the lock %s.lock: %w", path, err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("another tide-tabs serve is listening on %s", path)
		}
		return nil, fmt.Errorf("couldn't lock %s.lock: %w", path, err)
	}
	fail := func(err error) (net.Listener, error) {
		lock.Close()
		return nil, err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fail(fmt.Errorf("couldn't remove the old socket %s: %w", path, err))
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return fail(fmt.Errorf("couldn't listen on %s: %w", path, err))
	}
	// Removed by Close below, and only if it's still this one.
	l.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := os.Chmod(path, 0o600); err != nil {
		l.Close()
		os.Remove(path)
		return fail(fmt.Errorf("couldn't make %s yours alone: %w", path, err))
	}
	mine, err := os.Stat(path)
	if err != nil {
		l.Close()
		os.Remove(path)
		return fail(fmt.Errorf("couldn't look at %s: %w", path, err))
	}
	return &ownedListener{Listener: l, path: path, mine: mine, lock: lock}, nil
}

// ownedListener removes its socket, if it's still the one it made, and
// lets the lock go, when it closes.
type ownedListener struct {
	net.Listener
	path string
	mine os.FileInfo
	lock *os.File
	once sync.Once
}

func (o *ownedListener) Close() error {
	err := o.Listener.Close()
	o.once.Do(func() {
		if now, statErr := os.Stat(o.path); statErr == nil && os.SameFile(now, o.mine) {
			if rmErr := os.Remove(o.path); rmErr != nil && err == nil {
				err = rmErr
			}
		}
		// Closing the file lets the lock go.
		if closeErr := o.lock.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
	})
	return err
}

func runServe(stdin io.Reader, stdout, stderr io.Writer, path string) int {
	r := &relay{log: stderr, out: json.NewEncoder(stdout), hosts: map[string]net.Conn{}}
	l, err := listen(path)
	if err != nil {
		r.logf("%v", err)
		r.toShell(map[string]string{"type": "fault", "message": err.Error()})
		return 1
	}
	// A unix listener removes its socket when closed.
	defer l.Close()
	r.toShell(map[string]string{"type": "ready", "socket": path})
	go r.accept(l)

	sc := bufio.NewScanner(stdin)
	sc.Buffer(make([]byte, 0, 4096), maxLine)
	for sc.Scan() {
		a, err := parseActivate(sc.Bytes())
		if err != nil {
			r.logf("ignoring a line from the shell: %v", err)
			continue
		}
		r.activate(a)
	}
	if err := sc.Err(); err != nil {
		r.logf("couldn't read from the shell: %v", err)
		return 1
	}
	// The shell went: so does the relay, and with it every host's
	// connection, which each host reports to its extension.
	r.mu.Lock()
	for _, c := range r.hosts {
		c.Close()
	}
	r.mu.Unlock()
	return 0
}

func (r *relay) accept(l net.Listener) {
	for {
		c, err := l.Accept()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) {
				r.logf("stopped taking browsers: %v", err)
			}
			return
		}
		r.mu.Lock()
		r.next++
		id := strconv.Itoa(r.next)
		r.hosts[id] = c
		r.mu.Unlock()
		go r.serveHost(id, c)
	}
}

func (r *relay) serveHost(id string, c net.Conn) {
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 4096), maxLine)
	for sc.Scan() {
		m, err := parseTabs(sc.Bytes())
		if err != nil {
			r.logf("ignoring a line from browser %s: %v", id, err)
			continue
		}
		m.Source = id
		r.toShell(m)
	}
	if err := sc.Err(); err != nil && !errors.Is(err, net.ErrClosed) {
		r.logf("lost browser %s: %v", id, err)
	}
	r.mu.Lock()
	delete(r.hosts, id)
	r.mu.Unlock()
	c.Close()
	r.toShell(map[string]string{"type": "gone", "source": id})
}

func (r *relay) activate(a activate) {
	r.mu.Lock()
	c := r.hosts[a.Source]
	r.mu.Unlock()
	if c == nil {
		r.logf("no browser %q to bring tab %d up in; it has gone", a.Source, a.TabID)
		return
	}
	id := a.Source
	a.Source = ""
	b, err := json.Marshal(a)
	if err != nil {
		r.logf("couldn't encode the ask: %v", err)
		return
	}
	if _, err := c.Write(append(b, '\n')); err != nil {
		r.logf("couldn't ask browser %s to bring tab %d up: %v", id, a.TabID, err)
	}
}
