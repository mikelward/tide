package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	nmName         = "org.freedesktop.NetworkManager"
	agentManager   = dbus.ObjectPath("/org/freedesktop/NetworkManager/AgentManager")
	agentPath      = dbus.ObjectPath("/org/freedesktop/NetworkManager/SecretAgent")
	agentIface     = "org.freedesktop.NetworkManager.SecretAgent"
	agentID        = "io.github.mikelward.tide"
	capVPNHints    = 0x1
	appletName     = "org.freedesktop.network-manager-applet"
	errNoSecrets   = "org.freedesktop.NetworkManager.SecretAgent.NoSecrets"
	errUserCancel  = "org.freedesktop.NetworkManager.SecretAgent.UserCanceled"
	errCanceled    = "org.freedesktop.NetworkManager.SecretAgent.AgentCanceled"
	errFailed      = "org.freedesktop.NetworkManager.SecretAgent.Failed"
	errPermission  = "org.freedesktop.NetworkManager.SecretAgent.PermissionDenied"
	defaultTimeout = 115 * time.Second
)

func nmError(name, format string, args ...any) *dbus.Error {
	return dbus.NewError(name, []any{fmt.Sprintf(format, args...)})
}

type agent struct {
	sys     *dbus.Conn
	session *dbus.Conn
	shell   *shellLink
	keys    keyring
	dirs    []string
	// How long a request may wait on you: under NetworkManager's 120 s, so
	// the answer arrives while it's still listening.
	timeout time.Duration
	log     io.Writer

	mu sync.Mutex
	// The unique names that own NetworkManager's name and nm-applet's.
	nmOwner, appletOwner string
	registered           bool
	locked               bool
	// The requests under way, by connection path and setting, for
	// CancelGetSecrets.
	requests map[string]*pending
	// Requests being answered, so the helper exits only once each has its
	// answer.
	inflight sync.WaitGroup
	kick     chan struct{}
}

func (a *agent) logf(format string, args ...any) {
	fmt.Fprintf(a.log, "tide-agent: "+format+"\n", args...)
}

// tell sends the shell news, whose loss is only logged: the shell has gone,
// and the helper is about to follow.
func (a *agent) tell(msg any) {
	if err := a.shell.send(msg); err != nil {
		a.logf("couldn't tell the shell: %v", err)
	}
}

// fromNM is whether a call came from NetworkManager: any other process on
// the system bus could otherwise raise a prompt that looks like tide's.
func (a *agent) fromNM(sender dbus.Sender) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.nmOwner != "" && string(sender) == a.nmOwner
}

func (a *agent) isLocked() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.locked
}

func (a *agent) setLocked(l bool) {
	a.mu.Lock()
	a.locked = l
	a.mu.Unlock()
	a.tell(map[string]any{"type": "lock", "locked": l})
}

type pending struct{ cancel context.CancelFunc }

// The D-Bus object NetworkManager calls.
type secretAgent struct{ a *agent }

func (s secretAgent) GetSecrets(conn settings, path dbus.ObjectPath, setting string, hints []string, flags uint32, sender dbus.Sender) (settings, *dbus.Error) {
	a := s.a
	if !a.fromNM(sender) {
		a.logf("refused a request for secrets from %s, which isn't NetworkManager", sender)
		return nil, nmError(errPermission, "only NetworkManager may ask")
	}
	a.inflight.Add(1)
	defer a.inflight.Done()
	key := string(path) + "\x00" + setting
	ctx, cancel := context.WithTimeout(context.Background(), a.timeout)
	mine := &pending{cancel}
	a.mu.Lock()
	if old, ok := a.requests[key]; ok {
		// NetworkManager asked again: the new request replaces the old.
		old.cancel()
	}
	a.requests[key] = mine
	a.mu.Unlock()
	defer func() {
		cancel()
		a.mu.Lock()
		// Only its own entry: a newer request may have replaced it.
		if a.requests[key] == mine {
			delete(a.requests, key)
		}
		a.mu.Unlock()
	}()
	c := info(conn)
	var out settings
	var derr *dbus.Error
	if setting == "vpn" {
		out, derr = a.vpn(ctx, conn, hints, flags)
	} else {
		out, derr = a.plain(ctx, conn, setting, hints, flags)
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) && derr != nil && derr.Name == errNoSecrets {
		a.logf("nobody answered for %s within %s", c.ID, a.timeout)
		a.tell(map[string]any{"type": "missed", "connection": c})
	}
	return out, derr
}

func (s secretAgent) CancelGetSecrets(path dbus.ObjectPath, setting string, sender dbus.Sender) *dbus.Error {
	a := s.a
	if !a.fromNM(sender) {
		return nmError(errPermission, "only NetworkManager may cancel")
	}
	a.mu.Lock()
	p, ok := a.requests[string(path)+"\x00"+setting]
	a.mu.Unlock()
	if ok {
		p.cancel()
	}
	return nil
}

func (s secretAgent) SaveSecrets(conn settings, path dbus.ObjectPath, sender dbus.Sender) *dbus.Error {
	a := s.a
	if !a.fromNM(sender) {
		return nmError(errPermission, "only NetworkManager may save")
	}
	c := info(conn)
	// As nm-applet and GNOME Shell do: what's saved is what the connection
	// now holds, so a secret that's no longer agent-owned goes.
	if err := a.keys.remove(c.UUID); err != nil {
		a.logf("couldn't clear %s's saved secrets: %v", c.ID, err)
	}
	for _, s := range agentOwned(conn) {
		if err := a.keys.save(c.UUID, c.ID, s); err != nil {
			a.logf("%s: %v", c.ID, err)
			return nmError(errFailed, "%v", err)
		}
	}
	return nil
}

func (s secretAgent) DeleteSecrets(conn settings, path dbus.ObjectPath, sender dbus.Sender) *dbus.Error {
	a := s.a
	if !a.fromNM(sender) {
		return nmError(errPermission, "only NetworkManager may delete")
	}
	c := info(conn)
	if err := a.keys.remove(c.UUID); err != nil {
		a.logf("couldn't delete %s's saved secrets: %v", c.ID, err)
		return nmError(errFailed, "%v", err)
	}
	return nil
}

// answered turns the shell's answer into NetworkManager's.
func (a *agent) answered(ctx context.Context, c connInfo, ans answer, err error, setting string, keys []field, given map[string]string) (settings, *dbus.Error) {
	if err != nil {
		if ctx.Err() != nil {
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				return nil, nmError(errNoSecrets, "nobody answered")
			}
			return nil, nmError(errCanceled, "NetworkManager canceled the request")
		}
		a.logf("%s: %v", c.ID, err)
		return nil, nmError(errNoSecrets, "%v", err)
	}
	switch ans.Type {
	case "reply":
		values := maps.Clone(given)
		if values == nil {
			values = map[string]string{}
		}
		for _, f := range keys {
			if v, ok := ans.Values[f.Key]; ok {
				values[f.Key] = v
			}
		}
		return answerFor(setting, values), nil
	case "cancel":
		return nil, nmError(errUserCancel, "canceled")
	case "gone":
		return nil, nmError(errNoSecrets, "the shell has gone")
	}
	return nil, nmError(errNoSecrets, "the shell didn't ask")
}

// missedWhileLocked answers a request that would need typing while the
// lock is up: nothing is shown under the lock (SPEC.md §5.6).
func (a *agent) missedWhileLocked(c connInfo) (settings, *dbus.Error) {
	a.logf("%s needs a password while the session is locked; declined", c.ID)
	a.tell(map[string]any{"type": "missed", "connection": c})
	return nil, nmError(errNoSecrets, "the session is locked")
}

func (a *agent) plain(ctx context.Context, conn settings, setting string, hints []string, flags uint32) (settings, *dbus.Error) {
	c := info(conn)
	ak, err := asks(conn, setting, hints)
	if err != nil {
		a.logf("%s: declined: %v", c.ID, err)
		return nil, nmError(errNoSecrets, "%v", err)
	}
	alwaysAsk := false
	for _, f := range ak.fields {
		alwaysAsk = alwaysAsk || flagsOf(conn, setting, f.Key)&secretNotSaved != 0
	}
	if flags&flagRequestNew == 0 && !alwaysAsk {
		saved, err := a.keys.lookup(c.UUID, setting)
		if err != nil {
			a.logf("%s: %v", c.ID, err)
		}
		values := map[string]string{}
		for i, f := range ak.fields {
			if v, ok := saved[f.Key]; ok {
				values[f.Key] = v
				ak.fields[i].Value = v
			}
		}
		if len(values) == len(ak.fields) {
			return answerFor(setting, values), nil
		}
	}
	if flags&flagAllowInteraction == 0 {
		return nil, nmError(errNoSecrets, "nothing saved, and NetworkManager may not ask")
	}
	if a.isLocked() {
		return a.missedWhileLocked(c)
	}
	ans, err := a.shell.ask(ctx, request{
		Kind: ak.kind, Title: ak.title, Message: ak.message, Fields: ak.fields,
		Connection: c, SSID: ssid(conn), UserRequested: flags&flagUserRequested != 0,
	})
	return a.answered(ctx, c, ans, err, setting, ak.fields, nil)
}

func (a *agent) vpn(ctx context.Context, conn settings, hints []string, flags uint32) (settings, *dbus.Error) {
	c := info(conn)
	service := str(conn["vpn"], "service-type")
	p, err := findPlugin(a.dirs, service)
	if err != nil {
		a.logf("%s: declined: %v", c.ID, err)
		return nil, nmError(errNoSecrets, "%v", err)
	}
	secrets := maps.Clone(vpnSecrets(conn))
	if secrets == nil {
		secrets = map[string]string{}
	}
	if flags&flagRequestNew == 0 {
		saved, err := a.keys.lookup(c.UUID, "vpn")
		if err != nil {
			a.logf("%s: %v", c.ID, err)
		}
		for k, v := range saved {
			if _, ok := secrets[k]; !ok {
				secrets[k] = v
			}
		}
	}
	args := dialogArgs(p, conn, hints, flags)
	input := dialogInput(vpnData(conn), secrets)
	interactive := flags&flagAllowInteraction != 0
	if p.externalUI {
		out, err := runExternal(ctx, p, args, input)
		if err != nil {
			a.logf("%s: %v", c.ID, err)
			return nil, nmError(errNoSecrets, "%v", err)
		}
		ui, err := parseExternalUI(out)
		if err != nil {
			a.logf("%s: %s: %v", c.ID, p.authDialog, err)
			return nil, nmError(errNoSecrets, "%v", err)
		}
		if len(ui.fields) == 0 || !interactive {
			return answerFor("vpn", ui.given), nil
		}
		if a.isLocked() {
			return a.missedWhileLocked(c)
		}
		title, message := ui.title, ui.message
		if title == "" {
			title = "VPN password"
		}
		if message == "" {
			message = fmt.Sprintf("“%s” needs a password.", c.ID)
		}
		ans, err := a.shell.ask(ctx, request{
			Kind: "vpn", Title: title, Message: message, Fields: ui.fields,
			Connection: c, UserRequested: flags&flagUserRequested != 0,
		})
		return a.answered(ctx, c, ans, err, "vpn", ui.fields, ui.given)
	}
	if interactive {
		if a.isLocked() {
			return a.missedWhileLocked(c)
		}
		ans, err := a.shell.ask(ctx, request{
			Kind: "vpn-dialog", Title: "VPN login", Message: fmt.Sprintf("Sign in to “%s”.", c.ID),
			Fields: []field{}, Connection: c, UserRequested: flags&flagUserRequested != 0,
		})
		if err != nil || ans.Type != "go" {
			return a.answered(ctx, c, ans, err, "vpn", nil, nil)
		}
	}
	values, err := runOwnWindow(ctx, p, args, input)
	switch {
	case errors.Is(err, errDialogCanceled):
		return nil, nmError(errUserCancel, "the dialog was canceled")
	case err != nil:
		if ctx.Err() != nil {
			return a.answered(ctx, c, answer{}, err, "vpn", nil, nil)
		}
		a.logf("%s: %v", c.ID, err)
		return nil, nmError(errNoSecrets, "%v", err)
	}
	return answerFor("vpn", values), nil
}

// reconcile registers with NetworkManager while it runs and nm-applet
// doesn't, and unregisters while nm-applet does (SPEC.md §5.6's standing
// aside), telling the shell where that leaves it.
func (a *agent) reconcile() {
	a.mu.Lock()
	nm, applet, registered := a.nmOwner, a.appletOwner, a.registered
	a.mu.Unlock()
	// Bound to the NetworkManager it read, as the BlueZ agent's is: calls
	// go to that unique name, and the result counts only if it's still
	// the owner.
	manager := a.sys.Object(nm, agentManager)
	switch {
	case nm == "":
		a.tell(map[string]any{"type": "status", "state": "waiting"})
	case applet != "":
		if registered {
			if err := manager.Call("org.freedesktop.NetworkManager.AgentManager.Unregister", 0).Err; err != nil {
				a.logf("couldn't unregister from NetworkManager for nm-applet: %v", err)
			}
			a.setRegistered(nm, false)
		}
		a.tell(map[string]any{"type": "status", "state": "standing-aside", "pid": ownerPID(a.session, applet)})
	case !registered:
		if err := manager.Call("org.freedesktop.NetworkManager.AgentManager.RegisterWithCapabilities", 0, agentID, uint32(capVPNHints)).Err; err != nil {
			a.logf("couldn't register with NetworkManager: %v", err)
			a.tell(map[string]any{"type": "status", "state": "unregistered", "message": err.Error()})
			return
		}
		if !a.setRegistered(nm, true) {
			return
		}
		a.tell(map[string]any{"type": "status", "state": "registered"})
	}
}

// setRegistered records the result of a call made to owner, if it still
// owns the name; it says whether it did.
func (a *agent) setRegistered(owner string, r bool) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.nmOwner != owner {
		return false
	}
	a.registered = r
	return true
}

// reconciler runs reconcile once per kick, off the signal goroutine, since
// it calls NetworkManager.
func (a *agent) reconciler(done <-chan struct{}) {
	for {
		select {
		case <-a.kick:
			a.reconcile()
		case <-done:
			return
		}
	}
}

func (a *agent) poke() {
	select {
	case a.kick <- struct{}{}:
	default:
	}
}

func (a *agent) nmChanged(owner string) {
	a.mu.Lock()
	gone := a.nmOwner != "" && owner != a.nmOwner
	if owner != a.nmOwner {
		// A new NetworkManager knows no agents.
		a.registered = false
	}
	a.nmOwner = owner
	var cancels []context.CancelFunc
	if gone {
		// Its requests went with it: nobody is left to answer.
		for _, p := range a.requests {
			cancels = append(cancels, p.cancel)
		}
	}
	a.mu.Unlock()
	for _, c := range cancels {
		c()
	}
	a.poke()
}

func (a *agent) appletChanged(owner string) {
	a.mu.Lock()
	a.appletOwner = owner
	a.mu.Unlock()
	a.poke()
}
