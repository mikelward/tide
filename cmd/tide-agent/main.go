// Command tide-agent is the shell's NetworkManager secret agent (SPEC.md
// §5.6).
//
//	tide-agent
//
// The shell starts it and talks to it over stdin and stdout, one JSON
// object per line. It registers on the system bus as NetworkManager's
// secret agent, and passes each request NetworkManager makes to the shell
// as a request line:
//
//	{"type": "request", "id": "1", "kind": "wifi", "title": "...",
//	 "message": "...", "fields": [{"key": "psk", "label": "Password",
//	 "secret": true, "value": ""}], "connection": {"id": "...",
//	 "uuid": "...", "type": "..."}, "ssid": "...", "userRequested": true}
//
// The shell answers it with {"type": "reply", "id", "values": {key:
// value}}, {"type": "go", "id"} (for kind "vpn-dialog", a VPN plugin's own
// window), {"type": "cancel", "id"} (you said no) or {"type": "decline",
// "id"} (the shell won't ask). It also sends:
//
//	{"type": "cancel", "id"}               NetworkManager gave up on a request
//	{"type": "status", "state": "registered" | "standing-aside" (with
//	 "pid", nm-applet's) | "waiting" (for NetworkManager) |
//	 "unregistered" (with "message")}
//	{"type": "lock", "locked": bool}       tide-lock.service started or stopped
//	{"type": "missed", "connection": {...}} a request declined while locked,
//	                                       or that nobody answered in time
//	{"type": "bt-status", "state": ...}    the same, for BlueZ's pairing
//	                                       agent ("standing-aside" with
//	                                       blueman's applet's pid)
//	{"type": "fault", "message"}           then it exits 1
//
// It's also BlueZ's default pairing agent (org.bluez.Agent1), passing its
// requests on as bt-* kinds (shell.go), and standing aside while
// org.blueman.Applet has an owner, as it does for nm-applet.
// Saved secrets come from the keyring, under nm-applet's schema. A line
// from or to the shell can hold a password, so none is ever logged. It
// exits 0 when stdin closes.
package main

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

type config struct {
	system, session func() (*dbus.Conn, error)
	dirs            []string
	timeout         time.Duration
	// BlueZ's, which is shorter; zero is bluezTimeout.
	btTimeout time.Duration
}

func main() {
	os.Exit(run(os.Stdin, os.Stdout, os.Stderr, config{
		system:  func() (*dbus.Conn, error) { return dbus.ConnectSystemBus() },
		session: func() (*dbus.Conn, error) { return dbus.ConnectSessionBus() },
		dirs:    pluginDirs(),
		timeout: defaultTimeout,
	}))
}

func run(stdin io.Reader, stdout, stderr io.Writer, cfg config) int {
	shell := newShellLink(stdout)
	fault := func(format string, args ...any) int {
		msg := fmt.Sprintf(format, args...)
		fmt.Fprintf(stderr, "tide-agent: %s\n", msg)
		if err := shell.send(map[string]string{"type": "fault", "message": msg}); err != nil {
			fmt.Fprintf(stderr, "tide-agent: couldn't tell the shell: %v\n", err)
		}
		return 1
	}
	sys, err := cfg.system()
	if err != nil {
		return fault("couldn't connect to the system bus, where NetworkManager is: %v", err)
	}
	defer sys.Close()
	session, err := cfg.session()
	if err != nil {
		return fault("couldn't connect to the session bus: %v", err)
	}
	defer session.Close()

	a := &agent{
		sys: sys, session: session, shell: shell,
		keys:     &secretService{conn: session},
		dirs:     cfg.dirs,
		timeout:  cfg.timeout,
		log:      stderr,
		requests: map[string]*pending{},
		kick:     make(chan struct{}, 1),
	}
	if err := sys.Export(secretAgent{a}, agentPath, agentIface); err != nil {
		return fault("couldn't offer the agent on the system bus: %v", err)
	}
	bt := &btAgent{a: a, timeout: cfg.btTimeout, kick: make(chan struct{}, 1)}
	if bt.timeout == 0 {
		bt.timeout = bluezTimeout
	}
	if err := sys.Export(bluezAgent{bt}, bluezPath, bluezIface); err != nil {
		return fault("couldn't offer the pairing agent on the system bus: %v", err)
	}

	// Order matters: every signal the agents act on is watched (each
	// AddMatch has returned, so the bus delivers from then on) before
	// anything registers, so nothing that happens just after registering
	// is missed. The name watchers only record owners and queue a kick;
	// the reconcilers that register start last.
	sysSignals := watchSignals(sys)
	sessionSignals := watchSignals(session)
	if err := bt.watchDevices(sys, sysSignals); err != nil {
		return fault("%v", err)
	}
	locked := func(l bool) {
		a.setLocked(l)
		if l {
			// A code shown under the lock can't be seen: its pairing ends.
			bt.endCurrent("", endLocked)
		}
	}
	if err := watchLock(session, sessionSignals, locked); err != nil {
		// Without it, a request while locked is asked for under the lock,
		// where it can't be seen, and times out into a missed request.
		fmt.Fprintf(stderr, "tide-agent: %v; requests while locked go unseen until they time out\n", err)
	}
	// The rivals before the services, so the first registration already
	// knows whether to stand aside.
	if err := watchName(session, sessionSignals, appletName, a.appletChanged); err != nil {
		return fault("%v", err)
	}
	if err := watchName(session, sessionSignals, bluemanName, bt.bluemanChanged); err != nil {
		return fault("%v", err)
	}
	if err := watchName(sys, sysSignals, nmName, a.nmChanged); err != nil {
		return fault("%v", err)
	}
	if err := watchName(sys, sysSignals, bluezName, bt.bluezChanged); err != nil {
		return fault("%v", err)
	}

	readErr := make(chan error, 1)
	go func() { readErr <- shell.read(stdin) }()
	// Each reconciler finishes the registration it's in before it stops,
	// so the exit below unregisters whatever got registered.
	var reconcilers sync.WaitGroup
	reconcilers.Add(2)
	go func() { defer reconcilers.Done(); a.reconciler(shell.done) }()
	go func() { defer reconcilers.Done(); bt.reconciler(shell.done) }()

	err = <-readErr
	// Every request waiting on the shell has been answered "gone"; end the
	// rest (a VPN's own dialog), and let each answer reach NetworkManager
	// before the connection closes.
	a.mu.Lock()
	for _, p := range a.requests {
		p.cancel()
	}
	a.mu.Unlock()
	reconcilers.Wait()
	bt.unregister()
	a.inflight.Wait()
	a.mu.Lock()
	registered, nm := a.registered, a.nmOwner
	a.mu.Unlock()
	if registered {
		if uerr := sys.Object(nm, agentManager).Call("org.freedesktop.NetworkManager.AgentManager.Unregister", 0).Err; uerr != nil {
			// It drops the agent anyway once the connection closes.
			fmt.Fprintf(stderr, "tide-agent: couldn't unregister from NetworkManager: %v\n", uerr)
		}
	}
	if err != nil {
		return fault("%v", err)
	}
	return 0
}
