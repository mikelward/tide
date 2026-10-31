package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// BlueZ's pairing agent (SPEC.md §5.6): org.bluez.Agent1, registered with
// AgentManager1 as the default agent, so a pairing a device starts, or one
// a program starts without an agent of its own, asks through the shell.
const (
	bluezName      = "org.bluez"
	bluezManager   = dbus.ObjectPath("/org/bluez")
	bluezPath      = dbus.ObjectPath("/io/github/mikelward/tide/bluez")
	bluezIface     = "org.bluez.Agent1"
	bluemanName    = "org.blueman.Applet"
	bluezCapable   = "KeyboardDisplay"
	errBTRejected  = "org.bluez.Error.Rejected"
	errBTCanceled  = "org.bluez.Error.Canceled"
	bluezTimeout   = 55 * time.Second // under bluetoothd's 60 s (src/agent.c, BlueZ 5.87)
	maxPinCodeSize = 16
)

type btAgent struct {
	a       *agent
	timeout time.Duration

	mu                  sync.Mutex
	owner, bluemanOwner string
	registered          bool
	// The request under way; BlueZ asks one at a time, and Cancel ends it.
	// done closes once it has told the shell it's over. dev is a code's
	// device while one is shown, so the device's changes can end it.
	cancel context.CancelCauseFunc
	done   chan struct{}
	dev    dbus.ObjectPath
	kick   chan struct{}
}

// How a request ends, as its context's cause. displayEnd says what each
// means for a code being shown.
var (
	endBlueZCancel  = errors.New("BlueZ canceled it")
	endReplaced     = errors.New("BlueZ asked something new")
	endPaired       = errors.New("the device paired")
	endDisconnected = errors.New("the device disconnected, so pairing failed")
	endDeviceGone   = errors.New("the device went away")
	endBlueZGone    = errors.New("bluetoothd went away or restarted")
	endTimeout      = errors.New("nobody answered in time")
	endLocked       = errors.New("the session locked")
	endExit         = errors.New("tide-agent is exiting")
	endShellCancel  = errors.New("you canceled it")
	endShellDecline = errors.New("the shell declined it")
)

// displayEnd is the one place that decides how a code being shown ends:
// whether its end cancels the pairing in BlueZ, and whether the shell has
// to be told to take it down (it hasn't when it ended it, or has gone).
// bluetoothd doesn't reliably call Cancel after DisplayPasskey or
// DisplayPinCode (BlueZ 5.87 keeps no request for them), so the device's
// own changes end it too.
func displayEnd(cause error) (cancelPairing, tellShell bool) {
	switch cause {
	case endShellCancel, endShellDecline:
		return true, false
	case endTimeout, endLocked:
		return true, true
	case endExit:
		return false, false
	}
	// BlueZ canceled, something replaced it, the device paired,
	// disconnected or went, or bluetoothd itself went (a new one knows
	// nothing of the pairing, so it's told nothing): it's over.
	return false, true
}

func btError(name, format string, args ...any) *dbus.Error {
	return dbus.NewError(name, []any{fmt.Sprintf(format, args...)})
}

func (b *btAgent) fromBlueZ(sender dbus.Sender) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.owner != "" && string(sender) == b.owner
}

// The name a device goes by: its alias (which BlueZ makes from its name),
// else its address, else its path.
func (b *btAgent) deviceName(dev dbus.ObjectPath) string {
	b.mu.Lock()
	owner := b.owner
	b.mu.Unlock()
	obj := b.a.sys.Object(owner, dev)
	var last error
	for _, prop := range []string{"Alias", "Name", "Address"} {
		v, err := obj.GetProperty("org.bluez.Device1." + prop)
		if err != nil {
			// A device may lack a Name; the next property stands in.
			last = err
			continue
		}
		if s, _ := v.Value().(string); s != "" {
			return s
		}
	}
	if last != nil {
		b.a.logf("couldn't read %s's name (%v), so it goes by its path", dev, last)
	}
	return string(dev)
}

// Short names for the services a device most often asks to use; any other
// shows as its UUID.
var serviceNames = map[string]string{
	"0000110a-0000-1000-8000-00805f9b34fb": "audio playback (A2DP source)",
	"0000110b-0000-1000-8000-00805f9b34fb": "audio playback (A2DP sink)",
	"0000110e-0000-1000-8000-00805f9b34fb": "media controls (AVRCP)",
	"00001108-0000-1000-8000-00805f9b34fb": "a headset (HSP)",
	"0000111e-0000-1000-8000-00805f9b34fb": "hands-free calls (HFP)",
	"0000111f-0000-1000-8000-00805f9b34fb": "hands-free calls (HFP)",
	"00001124-0000-1000-8000-00805f9b34fb": "input (HID)",
	"00001105-0000-1000-8000-00805f9b34fb": "file transfer (OPP)",
	"0000112f-0000-1000-8000-00805f9b34fb": "the phone book (PBAP)",
	"00001132-0000-1000-8000-00805f9b34fb": "messages (MAP)",
	"00001116-0000-1000-8000-00805f9b34fb": "networking (PAN)",
}

func serviceName(uuid string) string {
	if n, ok := serviceNames[strings.ToLower(uuid)]; ok {
		return n
	}
	return uuid
}

// begin starts a request, ending the one before it, which BlueZ has
// abandoned if it asks again. It waits for the old one to take itself down
// in the shell first, so the shell hears the cancel before the new request.
// The caller calls end once its request is over in the shell.
func (b *btAgent) begin(dev dbus.ObjectPath) (ctx context.Context, cancel context.CancelCauseFunc, end func(), mine chan struct{}) {
	outer, cancel := context.WithCancelCause(context.Background())
	ctx, stop := context.WithTimeoutCause(outer, b.timeout, endTimeout)
	done := make(chan struct{})
	b.mu.Lock()
	oldCancel, oldDone := b.cancel, b.done
	b.cancel, b.done, b.dev = cancel, done, dev
	b.mu.Unlock()
	if oldCancel != nil {
		oldCancel(endReplaced)
		<-oldDone
	}
	return ctx, cancel, func() {
		stop()
		close(done)
	}, done
}

// endCurrent ends the code being shown for dev ("" for any), with cause.
func (b *btAgent) endCurrent(dev dbus.ObjectPath, cause error) {
	b.mu.Lock()
	cancel, shown := b.cancel, b.dev
	b.mu.Unlock()
	if cancel != nil && shown != "" && (dev == "" || dev == shown) {
		cancel(cause)
	}
}

// watchDevices ends a code being shown when its device pairs, disconnects
// or goes, as bluetoothd itself says.
func (b *btAgent) watchDevices(conn *dbus.Conn, sigs *signals) error {
	for _, member := range []string{"PropertiesChanged", "InterfacesRemoved"} {
		iface := "org.freedesktop.DBus.Properties"
		if member == "InterfacesRemoved" {
			iface = "org.freedesktop.DBus.ObjectManager"
		}
		if err := conn.AddMatchSignal(dbus.WithMatchSender(bluezName), dbus.WithMatchInterface(iface), dbus.WithMatchMember(member)); err != nil {
			return fmt.Errorf("couldn't watch BlueZ's devices: %w", err)
		}
	}
	sigs.on("org.freedesktop.DBus.Properties.PropertiesChanged", func(sig *dbus.Signal) {
		// Only bluetoothd's: a peer can send any signal straight here.
		if !b.fromBlueZ(dbus.Sender(sig.Sender)) || len(sig.Body) < 2 {
			return
		}
		if iface, _ := sig.Body[0].(string); iface != "org.bluez.Device1" {
			return
		}
		props, _ := sig.Body[1].(map[string]dbus.Variant)
		if v, ok := props["Paired"]; ok {
			if paired, _ := v.Value().(bool); paired {
				b.endCurrent(sig.Path, endPaired)
			}
		}
		if v, ok := props["Connected"]; ok {
			if connected, _ := v.Value().(bool); !connected {
				b.endCurrent(sig.Path, endDisconnected)
			}
		}
	})
	sigs.on("org.freedesktop.DBus.ObjectManager.InterfacesRemoved", func(sig *dbus.Signal) {
		if !b.fromBlueZ(dbus.Sender(sig.Sender)) || len(sig.Body) < 2 {
			return
		}
		path, _ := sig.Body[0].(dbus.ObjectPath)
		ifaces, _ := sig.Body[1].([]string)
		for _, i := range ifaces {
			if i == "org.bluez.Device1" {
				b.endCurrent(path, endDeviceGone)
			}
		}
	})
	return nil
}

// ask passes one request to the shell and turns its answer into BlueZ's:
// the values for a reply, Canceled for Esc or a request that ended, and
// Rejected for a decline.
func (b *btAgent) ask(dev dbus.ObjectPath, req request) (map[string]string, *dbus.Error) {
	name := b.deviceName(dev)
	if b.a.isLocked() {
		b.a.logf("%s asked to pair while the session is locked; rejected", name)
		return nil, btError(errBTRejected, "the session is locked")
	}
	b.a.inflight.Add(1)
	defer b.a.inflight.Done()
	ctx, cancel, end, _ := b.begin("")
	defer end()
	defer cancel(nil)
	req.Connection = connInfo{ID: name, UUID: string(dev), Type: "bluetooth"}
	req.Message = strings.ReplaceAll(req.Message, "DEVICE", "“"+name+"”")
	if req.Fields == nil {
		req.Fields = []field{}
	}
	ans, err := b.a.shell.ask(ctx, req)
	if err != nil {
		if ctx.Err() == nil {
			b.a.logf("%s: %v", name, err)
		}
		return nil, btError(errBTCanceled, "%v", err)
	}
	switch ans.Type {
	case "reply":
		return ans.Values, nil
	case "decline":
		return nil, btError(errBTRejected, "declined")
	}
	return nil, btError(errBTCanceled, "canceled")
}

// The D-Bus object BlueZ calls.
type bluezAgent struct{ b *btAgent }

func (s bluezAgent) Release(sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may release the agent")
	}
	s.b.mu.Lock()
	s.b.registered = false
	s.b.mu.Unlock()
	s.b.a.logf("BlueZ released the pairing agent")
	return nil
}

func (s bluezAgent) RequestPinCode(dev dbus.ObjectPath, sender dbus.Sender) (string, *dbus.Error) {
	if !s.b.fromBlueZ(sender) {
		return "", btError(errBTRejected, "only BlueZ may ask")
	}
	v, derr := s.b.ask(dev, request{
		Kind: "bt-pin", Title: "Bluetooth pairing", Message: "Type the PIN for DEVICE, as the device shows it or its manual gives it.",
		Fields: []field{{Key: "pin", Label: "PIN"}}, Accept: "Pair",
	})
	if derr != nil {
		return "", derr
	}
	pin := v["pin"]
	if len(pin) < 1 || len(pin) > maxPinCodeSize {
		return "", btError(errBTRejected, "a PIN is 1 to %d characters", maxPinCodeSize)
	}
	return pin, nil
}

func (s bluezAgent) RequestPasskey(dev dbus.ObjectPath, sender dbus.Sender) (uint32, *dbus.Error) {
	if !s.b.fromBlueZ(sender) {
		return 0, btError(errBTRejected, "only BlueZ may ask")
	}
	v, derr := s.b.ask(dev, request{
		Kind: "bt-passkey", Title: "Bluetooth pairing", Message: "Type the six-digit code DEVICE shows.",
		Fields: []field{{Key: "passkey", Label: "Code"}}, Accept: "Pair",
	})
	if derr != nil {
		return 0, derr
	}
	text := strings.TrimSpace(v["passkey"])
	n, err := strconv.ParseUint(text, 10, 32)
	if err != nil || n > 999999 || text == "" {
		return 0, btError(errBTRejected, "a passkey is a number from 0 to 999999")
	}
	return uint32(n), nil
}

func (s bluezAgent) RequestConfirmation(dev dbus.ObjectPath, passkey uint32, sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may ask")
	}
	_, derr := s.b.ask(dev, request{
		Kind: "bt-confirm", Title: "Bluetooth pairing",
		Message: fmt.Sprintf("Does DEVICE show %06d?", passkey), Accept: "Pair",
	})
	return derr
}

func (s bluezAgent) RequestAuthorization(dev dbus.ObjectPath, sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may ask")
	}
	_, derr := s.b.ask(dev, request{
		Kind: "bt-authorize", Title: "Bluetooth pairing", Message: "Pair with DEVICE?", Accept: "Pair",
	})
	return derr
}

func (s bluezAgent) AuthorizeService(dev dbus.ObjectPath, uuid string, sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may ask")
	}
	_, derr := s.b.ask(dev, request{
		Kind: "bt-service", Title: "Bluetooth",
		Message: fmt.Sprintf("Allow DEVICE to use %s?", serviceName(uuid)), Accept: "Allow", Decline: "Deny",
	})
	return derr
}

// The Display methods return at once: the code stays on screen until
// BlueZ calls Cancel, or you cancel, which cancels the pairing.
func (s bluezAgent) DisplayPinCode(dev dbus.ObjectPath, pin string, sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may ask")
	}
	return s.b.display(dev, fmt.Sprintf("Type %s on DEVICE, then Enter.", pin))
}

func (s bluezAgent) DisplayPasskey(dev dbus.ObjectPath, passkey uint32, entered uint16, sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may ask")
	}
	msg := fmt.Sprintf("Type %06d on DEVICE, then Enter.", passkey)
	if entered > 0 {
		msg += fmt.Sprintf(" %d typed so far.", entered)
	}
	return s.b.display(dev, msg)
}

func (s bluezAgent) Cancel(sender dbus.Sender) *dbus.Error {
	if !s.b.fromBlueZ(sender) {
		return btError(errBTRejected, "only BlueZ may cancel")
	}
	// Kept, not cleared: the next request waits on it to finish.
	s.b.mu.Lock()
	cancel := s.b.cancel
	s.b.mu.Unlock()
	if cancel != nil {
		cancel(endBlueZCancel)
	}
	return nil
}

func (b *btAgent) display(dev dbus.ObjectPath, msg string) *dbus.Error {
	name := b.deviceName(dev)
	if b.a.isLocked() {
		b.a.logf("%s asked to pair while the session is locked; rejected", name)
		return btError(errBTRejected, "the session is locked")
	}
	ctx, cancel, end, mine := b.begin(dev)
	req := request{
		Kind: "bt-display", Title: "Bluetooth pairing", Fields: []field{},
		Message:    strings.ReplaceAll(msg, "DEVICE", "“"+name+"”"),
		Connection: connInfo{ID: name, UUID: string(dev), Type: "bluetooth"},
	}
	b.a.inflight.Add(1)
	go func() {
		defer b.a.inflight.Done()
		// shell.ask takes it down in the shell when ctx ends first.
		ans, err := b.a.shell.ask(ctx, req)
		cause := context.Cause(ctx)
		if err == nil {
			switch ans.Type {
			case "decline":
				cause = endShellDecline
			case "gone":
				cause = endExit
			default:
				cause = endShellCancel
			}
		}
		b.mu.Lock()
		// Only its own: a newer code may be showing for the same device.
		if b.done == mine {
			b.dev = ""
		}
		owner := b.owner
		b.mu.Unlock()
		// Before end, so BlueZ hears it before the next request starts.
		if cancelPairing, _ := displayEnd(cause); cancelPairing {
			b.a.logf("canceling pairing with %s: %v", name, cause)
			if err := b.a.sys.Object(owner, dev).Call("org.bluez.Device1.CancelPairing", 0).Err; err != nil {
				b.a.logf("couldn't cancel pairing with %s: %v", name, err)
			}
		}
		cancel(cause)
		end()
	}()
	return nil
}

// reconcile registers as BlueZ's default agent while bluetoothd runs and
// blueman's applet doesn't, as the NetworkManager agent does for nm-applet.
func (b *btAgent) reconcile() {
	b.mu.Lock()
	owner, blueman, registered := b.owner, b.bluemanOwner, b.registered
	b.mu.Unlock()
	// Each attempt is bound to the daemon it read: calls go to that
	// unique name, not the well-known one, and the result counts only if
	// it's still the owner (setRegistered). A new owner queues another
	// reconcile, which registers with it.
	manager := b.a.sys.Object(owner, bluezManager)
	switch {
	case owner == "":
		b.a.tell(map[string]any{"type": "bt-status", "state": "waiting"})
	case blueman != "":
		if registered {
			if err := manager.Call("org.bluez.AgentManager1.UnregisterAgent", 0, bluezPath).Err; err != nil {
				b.a.logf("couldn't unregister from BlueZ for blueman: %v", err)
			}
			b.setRegistered(owner, false)
		}
		b.a.tell(map[string]any{"type": "bt-status", "state": "standing-aside", "pid": ownerPID(b.a.session, blueman)})
	case !registered:
		if err := manager.Call("org.bluez.AgentManager1.RegisterAgent", 0, bluezPath, bluezCapable).Err; err != nil {
			b.a.logf("couldn't register the pairing agent with BlueZ: %v", err)
			b.a.tell(map[string]any{"type": "bt-status", "state": "unregistered", "message": err.Error()})
			return
		}
		if err := manager.Call("org.bluez.AgentManager1.RequestDefaultAgent", 0, bluezPath).Err; err != nil {
			b.a.logf("BlueZ took the pairing agent, but not as the default: %v", err)
		}
		if !b.setRegistered(owner, true) {
			return
		}
		b.a.tell(map[string]any{"type": "bt-status", "state": "registered"})
	}
}

// setRegistered records the result of a call made to owner, if it still
// owns the name; it says whether it did.
func (b *btAgent) setRegistered(owner string, r bool) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.owner != owner {
		return false
	}
	b.registered = r
	return true
}

func (b *btAgent) poke() {
	select {
	case b.kick <- struct{}{}:
	default:
	}
}

func (b *btAgent) reconciler(done <-chan struct{}) {
	for {
		select {
		case <-b.kick:
			b.reconcile()
		case <-done:
			return
		}
	}
}

func (b *btAgent) bluezChanged(owner string) {
	b.mu.Lock()
	gone := b.owner != "" && owner != b.owner
	if owner != b.owner {
		b.registered = false
	}
	b.owner = owner
	cancel := b.cancel
	b.mu.Unlock()
	// Whatever bluetoothd asked went with it: the request, a code shown or
	// a question, comes down now rather than at its timeout.
	if gone && cancel != nil {
		cancel(endBlueZGone)
	}
	b.poke()
}

func (b *btAgent) bluemanChanged(owner string) {
	b.mu.Lock()
	b.bluemanOwner = owner
	b.mu.Unlock()
	b.poke()
}

// unregister, as the helper exits; BlueZ drops the agent anyway once the
// connection closes.
func (b *btAgent) unregister() {
	b.mu.Lock()
	registered, owner := b.registered, b.owner
	cancel := b.cancel
	b.mu.Unlock()
	if cancel != nil {
		cancel(endExit)
	}
	if registered {
		if err := b.a.sys.Object(owner, bluezManager).Call("org.bluez.AgentManager1.UnregisterAgent", 0, bluezPath).Err; err != nil {
			b.a.logf("couldn't unregister from BlueZ: %v", err)
		}
	}
}
