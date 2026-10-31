package main

import (
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// fakeBlueZ is bluetoothd's AgentManager1, and one device.
type fakeBlueZ struct {
	events chan string
	// When set, RegisterAgent waits on it before answering, so a test can
	// swap the daemon mid-registration.
	gate chan struct{}
}

const testDevice = dbus.ObjectPath("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")

func newFakeBlueZ(t *testing.T, c *dbus.Conn) *fakeBlueZ {
	t.Helper()
	f := &fakeBlueZ{events: make(chan string, 16)}
	if err := c.ExportMethodTable(map[string]any{
		"RegisterAgent": func(path dbus.ObjectPath, capability string) *dbus.Error {
			f.events <- "register " + string(path) + " " + capability
			if f.gate != nil {
				<-f.gate
			}
			return nil
		},
		"RequestDefaultAgent": func(path dbus.ObjectPath) *dbus.Error {
			f.events <- "default " + string(path)
			return nil
		},
		"UnregisterAgent": func(path dbus.ObjectPath) *dbus.Error {
			f.events <- "unregister " + string(path)
			return nil
		},
	}, bluezManager, "org.bluez.AgentManager1"); err != nil {
		t.Fatal(err)
	}
	if err := c.ExportMethodTable(map[string]any{
		"Get": func(iface, prop string) (dbus.Variant, *dbus.Error) {
			switch prop {
			case "Alias":
				return dbus.MakeVariant("Headphones"), nil
			case "Address":
				return dbus.MakeVariant("AA:BB:CC:DD:EE:FF"), nil
			}
			return dbus.Variant{}, dbus.NewError("org.freedesktop.DBus.Error.InvalidArgs", []any{"no such property"})
		},
	}, testDevice, "org.freedesktop.DBus.Properties"); err != nil {
		t.Fatal(err)
	}
	if err := c.ExportMethodTable(map[string]any{
		"CancelPairing": func() *dbus.Error {
			f.events <- "cancel-pairing"
			return nil
		},
	}, testDevice, "org.bluez.Device1"); err != nil {
		t.Fatal(err)
	}
	return f
}

func (w *world) expectBT(event string) {
	w.t.Helper()
	select {
	case got := <-w.btCalls.events:
		if got != event {
			w.t.Fatalf("BlueZ heard %q, want %q", got, event)
		}
	case <-time.After(patience):
		w.t.Fatalf("BlueZ never heard %q; the agent's log:\n%s", event, w.stderr)
	}
}

// btWorld is a world whose agent has registered with BlueZ as the default.
func btWorld(t *testing.T, btTimeout ...time.Duration) *world {
	t.Helper()
	w := newWorld(t, defaultTimeout, btTimeout...)
	w.expectBT("register " + string(bluezPath) + " KeyboardDisplay")
	w.expectBT("default " + string(bluezPath))
	return w
}

// call is one BlueZ call to the agent, from conn, answered on the channel.
func (w *world) btCall(from *dbus.Conn, method string, out any, args ...any) chan error {
	ch := make(chan error, 1)
	go func() {
		call := from.Object(w.agentName(), bluezPath).Call(bluezIface+"."+method, 0, args...)
		if call.Err == nil && out != nil {
			ch <- call.Store(out)
			return
		}
		ch <- call.Err
	}()
	return ch
}

func (w *world) btResult(ch chan error) error {
	w.t.Helper()
	select {
	case err := <-ch:
		return err
	case <-time.After(patience):
		w.t.Fatalf("BlueZ's call never returned; the agent's log:\n%s", w.stderr)
	}
	return nil
}

func TestBlueZConfirmation(t *testing.T) {
	w := btWorld(t)
	ch := w.btCall(w.bluez, "RequestConfirmation", nil, testDevice, uint32(12345))
	req := w.expect("request")
	if req["kind"] != "bt-confirm" || req["message"] != "Does “Headphones” show 012345?" || req["accept"] != "Pair" || req["userRequested"] != false {
		t.Errorf("request %v", req)
	}
	if c := req["connection"].(map[string]any); c["type"] != "bluetooth" || c["id"] != "Headphones" {
		t.Errorf("connection %v", c)
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{}})
	if err := w.btResult(ch); err != nil {
		t.Errorf("confirmed: %v", err)
	}
	for answer, want := range map[string]string{"cancel": errBTCanceled, "decline": errBTRejected} {
		ch = w.btCall(w.bluez, "RequestConfirmation", nil, testDevice, uint32(1))
		req = w.expect("request")
		w.answer(map[string]any{"type": answer, "id": req["id"]})
		if err := w.btResult(ch); errName(err) != want {
			t.Errorf("%s: err = %v, want %s", answer, err, want)
		}
	}
}

func TestBlueZPasskeyAndPin(t *testing.T) {
	w := btWorld(t)
	var passkey uint32
	ch := w.btCall(w.bluez, "RequestPasskey", &passkey, testDevice)
	req := w.expect("request")
	if req["kind"] != "bt-passkey" {
		t.Errorf("request %v", req)
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"passkey": " 004321 "}})
	if err := w.btResult(ch); err != nil || passkey != 4321 {
		t.Errorf("passkey %d, err %v", passkey, err)
	}
	for _, bad := range []string{"abc", "1000000", "", "-1"} {
		ch = w.btCall(w.bluez, "RequestPasskey", &passkey, testDevice)
		req = w.expect("request")
		w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"passkey": bad}})
		if err := w.btResult(ch); errName(err) != errBTRejected {
			t.Errorf("passkey %q: err = %v, want rejected", bad, err)
		}
	}
	var pin string
	ch = w.btCall(w.bluez, "RequestPinCode", &pin, testDevice)
	req = w.expect("request")
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"pin": "0000"}})
	if err := w.btResult(ch); err != nil || pin != "0000" {
		t.Errorf("pin %q, err %v", pin, err)
	}
	ch = w.btCall(w.bluez, "RequestPinCode", &pin, testDevice)
	req = w.expect("request")
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"pin": strings.Repeat("1", 17)}})
	if err := w.btResult(ch); errName(err) != errBTRejected {
		t.Errorf("a 17-character PIN: err = %v", err)
	}
}

func TestBlueZAuthorization(t *testing.T) {
	w := btWorld(t)
	ch := w.btCall(w.bluez, "AuthorizeService", nil, testDevice, "0000110B-0000-1000-8000-00805F9B34FB")
	req := w.expect("request")
	if req["kind"] != "bt-service" || req["message"] != "Allow “Headphones” to use audio playback (A2DP sink)?" || req["accept"] != "Allow" || req["decline"] != "Deny" {
		t.Errorf("request %v", req)
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{}})
	if err := w.btResult(ch); err != nil {
		t.Error(err)
	}
	ch = w.btCall(w.bluez, "RequestAuthorization", nil, testDevice)
	req = w.expect("request")
	if req["kind"] != "bt-authorize" || req["message"] != "Pair with “Headphones”?" {
		t.Errorf("request %v", req)
	}
	w.answer(map[string]any{"type": "decline", "id": req["id"]})
	if err := w.btResult(ch); errName(err) != errBTRejected {
		t.Errorf("err = %v", err)
	}
}

func TestBlueZDisplay(t *testing.T) {
	w := btWorld(t)
	// It returns at once, and the code stays up until BlueZ cancels.
	if err := w.btResult(w.btCall(w.bluez, "DisplayPasskey", nil, testDevice, uint32(42), uint16(0))); err != nil {
		t.Fatal(err)
	}
	req := w.expect("request")
	if req["kind"] != "bt-display" || req["message"] != "Type 000042 on “Headphones”, then Enter." {
		t.Errorf("request %v", req)
	}
	// A key typed on the device updates it: a new request for the old.
	if err := w.btResult(w.btCall(w.bluez, "DisplayPasskey", nil, testDevice, uint32(42), uint16(2))); err != nil {
		t.Fatal(err)
	}
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("the old code's cancel is %v", m)
	}
	req = w.expect("request")
	if !strings.HasSuffix(req["message"].(string), "2 typed so far.") {
		t.Errorf("updated %v", req)
	}
	if err := w.btResult(w.btCall(w.bluez, "Cancel", nil)); err != nil {
		t.Fatal(err)
	}
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	// You canceling it cancels the pairing.
	if err := w.btResult(w.btCall(w.bluez, "DisplayPinCode", nil, testDevice, "123456")); err != nil {
		t.Fatal(err)
	}
	req = w.expect("request")
	w.answer(map[string]any{"type": "cancel", "id": req["id"]})
	w.expectBT("cancel-pairing")
}

func TestOnlyBlueZMayAskToPair(t *testing.T) {
	w := btWorld(t)
	other := connect(t, w.addr)
	if err := w.btResult(w.btCall(other, "RequestConfirmation", nil, testDevice, uint32(1))); errName(err) != errBTRejected {
		t.Errorf("err = %v", err)
	}
	// Forged: bluetoothd gone, so nothing would answer it.
	forge(t, other, w.agentName(), "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", bluezName, w.bluez.Names()[0], "")
	ch := w.btCall(w.bluez, "RequestAuthorization", nil, testDevice)
	req := w.expect("request")
	if req["kind"] != "bt-authorize" {
		t.Errorf("the first request to reach the shell is %v", req)
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{}})
	if err := w.btResult(ch); err != nil {
		t.Error(err)
	}
}

func TestBlueZWhileLocked(t *testing.T) {
	w := btWorld(t)
	w.systemd.set("active")
	w.expect("lock")
	if err := w.btResult(w.btCall(w.bluez, "RequestConfirmation", nil, testDevice, uint32(1))); errName(err) != errBTRejected {
		t.Errorf("err = %v", err)
	}
}

func TestBlueZStandsAsideForBlueman(t *testing.T) {
	w := btWorld(t)
	applet := connect(t, w.addr)
	own(t, applet, bluemanName)
	w.expectBT("unregister " + string(bluezPath))
	if m := w.expect("bt-status"); m["state"] != "registered" && m["state"] != "standing-aside" {
		t.Errorf("status %v", m)
	}
	if _, err := applet.ReleaseName(bluemanName); err != nil {
		t.Fatal(err)
	}
	w.expectBT("register " + string(bluezPath) + " KeyboardDisplay")
	w.expectBT("default " + string(bluezPath))
}

func TestBlueZUnregistersOnExit(t *testing.T) {
	w := btWorld(t)
	w.toShell.Close()
	w.expectBT("unregister " + string(bluezPath))
}

func TestDisplayEnd(t *testing.T) {
	for _, tc := range []struct {
		cause                    error
		cancelPairing, tellShell bool
	}{
		{endBlueZCancel, false, true},
		{endReplaced, false, true},
		{endPaired, false, true},
		{endDisconnected, false, true},
		{endDeviceGone, false, true},
		{endBlueZGone, false, true},
		{endTimeout, true, true},
		{endLocked, true, true},
		{endShellCancel, true, false},
		{endShellDecline, true, false},
		{endExit, false, false},
	} {
		c, s := displayEnd(tc.cause)
		if c != tc.cancelPairing || s != tc.tellShell {
			t.Errorf("%v: cancelPairing %v, tellShell %v; want %v, %v", tc.cause, c, s, tc.cancelPairing, tc.tellShell)
		}
	}
}

// showCode puts a code on screen, and returns its request.
func (w *world) showCode() map[string]any {
	w.t.Helper()
	if err := w.btResult(w.btCall(w.bluez, "DisplayPasskey", nil, testDevice, uint32(42), uint16(0))); err != nil {
		w.t.Fatal(err)
	}
	return w.expect("request")
}

// noCancelPairing checks the agent didn't cancel the pairing: it's asked to
// show another code, which it does only once the last has ended, so any
// CancelPairing from that end would be heard first.
func (w *world) noCancelPairing() {
	w.t.Helper()
	w.showCode()
	select {
	case e := <-w.btCalls.events:
		w.t.Errorf("BlueZ heard %q", e)
	default:
	}
}

func TestDisplayEndsWhenTheDevicePairs(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.bluez.Emit(testDevice, "org.freedesktop.DBus.Properties.PropertiesChanged", "org.bluez.Device1",
		map[string]dbus.Variant{"Paired": dbus.MakeVariant(true)}, []string{})
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	w.noCancelPairing()
}

func TestDisplayEndsWhenPairingFails(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.bluez.Emit(testDevice, "org.freedesktop.DBus.Properties.PropertiesChanged", "org.bluez.Device1",
		map[string]dbus.Variant{"Connected": dbus.MakeVariant(false)}, []string{})
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	w.noCancelPairing()
}

func TestDisplayEndsWhenTheDeviceGoes(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.bluez.Emit("/", "org.freedesktop.DBus.ObjectManager.InterfacesRemoved", testDevice, []string{"org.bluez.Device1"})
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
}

func TestDisplayIgnoresAnotherDevicesChanges(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.bluez.Emit("/org/bluez/hci0/dev_11_22_33_44_55_66", "org.freedesktop.DBus.Properties.PropertiesChanged", "org.bluez.Device1",
		map[string]dbus.Variant{"Paired": dbus.MakeVariant(true)}, []string{})
	// A forged one from a peer, for the right device.
	peer := connect(t, w.addr)
	forge(t, peer, w.agentName(), testDevice, "org.freedesktop.DBus.Properties", "PropertiesChanged",
		"org.bluez.Device1", map[string]dbus.Variant{"Paired": dbus.MakeVariant(true)}, []string{})
	// The shell's cancel is still the first thing to end it.
	w.answer(map[string]any{"type": "cancel", "id": req["id"]})
	w.expectBT("cancel-pairing")
}

func TestDisplayDeclinedByTheShellCancelsPairing(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.answer(map[string]any{"type": "decline", "id": req["id"]})
	w.expectBT("cancel-pairing")
}

func TestDisplayTimesOut(t *testing.T) {
	w := btWorld(t, 200*time.Millisecond)
	req := w.showCode()
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	w.expectBT("cancel-pairing")
}

func TestDisplayEndsWithTheLock(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	w.systemd.set("active")
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	w.expectBT("cancel-pairing")
}

func TestDisplayEndsQuietlyOnExit(t *testing.T) {
	w := btWorld(t)
	w.showCode()
	w.toShell.Close()
	w.expectBT("unregister " + string(bluezPath))
	select {
	case e := <-w.btCalls.events:
		t.Errorf("BlueZ heard %q after the exit", e)
	case <-w.exit:
		w.exit <- 0
	}
}

func TestBlueZGoingTakesItsRequestsDown(t *testing.T) {
	w := btWorld(t)
	req := w.showCode()
	if _, err := w.bluez.ReleaseName(bluezName); err != nil {
		t.Fatal(err)
	}
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	// And no CancelPairing went anywhere.
	select {
	case e := <-w.btCalls.events:
		t.Errorf("BlueZ heard %q", e)
	default:
	}
}

func TestBlueZGoingEndsAQuestion(t *testing.T) {
	w := btWorld(t)
	ch := w.btCall(w.bluez, "RequestConfirmation", nil, testDevice, uint32(1))
	req := w.expect("request")
	if _, err := w.bluez.ReleaseName(bluezName); err != nil {
		t.Fatal(err)
	}
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v", m)
	}
	if err := w.btResult(ch); errName(err) != errBTCanceled {
		t.Errorf("err = %v", err)
	}
}

func expectOn(t *testing.T, f *fakeBlueZ, event string) {
	t.Helper()
	select {
	case got := <-f.events:
		if got != event {
			t.Fatalf("heard %q, want %q", got, event)
		}
	case <-time.After(patience):
		t.Fatalf("never heard %q", event)
	}
}

func TestBlueZRestartingMidRegistrationRegistersWithTheNewOne(t *testing.T) {
	w := btWorld(t)
	register := "register " + string(bluezPath) + " KeyboardDisplay"
	// bluetoothd restarts as B, which holds its answer to RegisterAgent.
	b := connect(t, w.addr)
	fb := newFakeBlueZ(t, b)
	fb.gate = make(chan struct{})
	if _, err := w.bluez.ReleaseName(bluezName); err != nil {
		t.Fatal(err)
	}
	own(t, b, bluezName)
	expectOn(t, fb, register)
	// While B is still answering, it goes too, and C takes the name.
	if _, err := b.ReleaseName(bluezName); err != nil {
		t.Fatal(err)
	}
	c := connect(t, w.addr)
	fc := newFakeBlueZ(t, c)
	own(t, c, bluezName)
	// B's late success is B's, not C's: the agent registers with C.
	close(fb.gate)
	expectOn(t, fc, register)
	expectOn(t, fc, "default "+string(bluezPath))
}
