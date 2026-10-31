package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// The agent runs here against a private bus from dbus-daemon, standing in
// for both the system bus and the session bus, with stand-ins for
// NetworkManager's AgentManager, the Secret Service and systemd's lock
// unit. NetworkManager itself can't run here (SPEC.md §20).

const busConfig = `<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=%s</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
`

// The longest any step here waits: generous, since it's only reached when
// something is broken.
const patience = 10 * time.Second

func privateBus(t *testing.T) string {
	t.Helper()
	daemon, err := exec.LookPath("dbus-daemon")
	if err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal("no dbus-daemon on PATH, which CI must have to run the agent's tests")
		}
		t.Skip("no dbus-daemon on PATH; install dbus-daemon to run the agent's D-Bus tests")
	}
	dir := t.TempDir()
	socket := filepath.Join(dir, "bus")
	conf := filepath.Join(dir, "bus.conf")
	writeFile(t, conf, fmt.Sprintf(busConfig, socket), 0o644)
	cmd := exec.Command(daemon, "--config-file="+conf, "--nofork", "--print-address")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	// It complains it can't raise its fd limit, unprivileged; anything
	// that matters shows as a test failing to connect.
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		cmd.Wait()
	})
	// It prints its address once it's listening.
	addr, err := bufio.NewReader(out).ReadString('\n')
	if err != nil {
		t.Fatalf("dbus-daemon printed no address: %v", err)
	}
	return strings.TrimSpace(addr)
}

func connect(t *testing.T, addr string) *dbus.Conn {
	t.Helper()
	c, err := dbus.Connect(addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func own(t *testing.T, c *dbus.Conn, name string) {
	t.Helper()
	reply, err := c.RequestName(name, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		t.Fatalf("couldn't own %s: %v %v", name, reply, err)
	}
}

// fakeNM is NetworkManager's AgentManager.
type fakeNM struct {
	events chan string
	mu     sync.Mutex
	// The agent's unique name, which NetworkManager calls back.
	agent string
	// When set, registration waits on it before answering.
	gate chan struct{}
}

func (f *fakeNM) RegisterWithCapabilities(id string, caps uint32, sender dbus.Sender) *dbus.Error {
	f.mu.Lock()
	f.agent = string(sender)
	gate := f.gate
	f.mu.Unlock()
	f.events <- fmt.Sprintf("register %s %d", id, caps)
	if gate != nil {
		<-gate
	}
	return nil
}

func (f *fakeNM) Unregister(sender dbus.Sender) *dbus.Error {
	f.events <- "unregister"
	return nil
}

// fakeKeyring is the Secret Service, keeping items in memory.
type fakeKeyring struct {
	conn  *dbus.Conn
	mu    sync.Mutex
	items map[dbus.ObjectPath]keyItem
	next  int
}

type keyItem struct {
	attrs map[string]string
	value string
}

type keyringService struct{ k *fakeKeyring }

func (s keyringService) OpenSession(alg string, in dbus.Variant) (dbus.Variant, dbus.ObjectPath, *dbus.Error) {
	if alg != "plain" {
		return dbus.Variant{}, "", dbus.NewError("org.freedesktop.DBus.Error.NotSupported", nil)
	}
	return dbus.MakeVariant(""), "/org/freedesktop/secrets/session/1", nil
}

func (s keyringService) SearchItems(attrs map[string]string) ([]dbus.ObjectPath, []dbus.ObjectPath, *dbus.Error) {
	s.k.mu.Lock()
	defer s.k.mu.Unlock()
	var found []dbus.ObjectPath
	for path, item := range s.k.items {
		match := true
		for k, v := range attrs {
			match = match && item.attrs[k] == v
		}
		if match {
			found = append(found, path)
		}
	}
	return found, []dbus.ObjectPath{}, nil
}

func (s keyringService) GetSecrets(items []dbus.ObjectPath, session dbus.ObjectPath) (map[dbus.ObjectPath]secretValue, *dbus.Error) {
	s.k.mu.Lock()
	defer s.k.mu.Unlock()
	out := map[dbus.ObjectPath]secretValue{}
	for _, p := range items {
		if item, ok := s.k.items[p]; ok {
			out[p] = secretValue{Session: session, Parameters: []byte{}, Value: []byte(item.value), ContentType: "text/plain"}
		}
	}
	return out, nil
}

type keyringCollection struct{ k *fakeKeyring }

func (c keyringCollection) CreateItem(props map[string]dbus.Variant, secret secretValue, replace bool) (dbus.ObjectPath, dbus.ObjectPath, *dbus.Error) {
	attrs, _ := props["org.freedesktop.Secret.Item.Attributes"].Value().(map[string]string)
	return c.k.add(attrs, string(secret.Value)), "/", nil
}

func (k *fakeKeyring) add(attrs map[string]string, value string) dbus.ObjectPath {
	k.mu.Lock()
	k.next++
	path := dbus.ObjectPath(fmt.Sprintf("/org/freedesktop/secrets/collection/login/%d", k.next))
	k.items[path] = keyItem{attrs, value}
	k.mu.Unlock()
	k.conn.ExportMethodTable(map[string]any{
		"Get": func(iface, prop string) (dbus.Variant, *dbus.Error) {
			k.mu.Lock()
			defer k.mu.Unlock()
			return dbus.MakeVariant(k.items[path].attrs), nil
		},
	}, path, "org.freedesktop.DBus.Properties")
	k.conn.ExportMethodTable(map[string]any{
		"Delete": func() (dbus.ObjectPath, *dbus.Error) {
			k.mu.Lock()
			delete(k.items, path)
			k.mu.Unlock()
			return "/", nil
		},
	}, path, "org.freedesktop.Secret.Item")
	return path
}

func (k *fakeKeyring) values() map[string]string {
	k.mu.Lock()
	defer k.mu.Unlock()
	out := map[string]string{}
	for _, item := range k.items {
		out[item.attrs["connection-uuid"]+"/"+item.attrs["setting-name"]+"/"+item.attrs["setting-key"]] = item.value
	}
	return out
}

// fakeSystemd is the user manager, with tide-lock.service.
type fakeSystemd struct {
	conn  *dbus.Conn
	mu    sync.Mutex
	state string
	// The agent's session connection, which subscribes.
	subscriber string
}

const lockPath = dbus.ObjectPath("/org/freedesktop/systemd1/unit/tide_2dlock_2eservice")

func (f *fakeSystemd) Subscribe(sender dbus.Sender) *dbus.Error {
	f.mu.Lock()
	f.subscriber = string(sender)
	f.mu.Unlock()
	return nil
}

func (f *fakeSystemd) LoadUnit(name string) (dbus.ObjectPath, *dbus.Error) {
	if name != lockUnit {
		return "", dbus.NewError("org.freedesktop.systemd1.NoSuchUnit", nil)
	}
	return lockPath, nil
}

func (f *fakeSystemd) set(state string) {
	f.mu.Lock()
	f.state = state
	f.mu.Unlock()
	f.conn.Emit(lockPath, "org.freedesktop.DBus.Properties.PropertiesChanged", "org.freedesktop.systemd1.Unit",
		map[string]dbus.Variant{"ActiveState": dbus.MakeVariant(state)}, []string{})
}

type world struct {
	t       *testing.T
	addr    string
	nm      *dbus.Conn
	nmCalls *fakeNM
	keyring *fakeKeyring
	systemd *fakeSystemd
	bluez   *dbus.Conn
	btCalls *fakeBlueZ
	plugins string
	toShell io.WriteCloser
	msgs    chan map[string]any
	stderr  *syncBuffer
	exit    chan int
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newWorld(t *testing.T, timeout time.Duration, btTimeout ...time.Duration) *world {
	t.Helper()
	w := &world{t: t, addr: privateBus(t), plugins: t.TempDir(), msgs: make(chan map[string]any, 64), stderr: &syncBuffer{}, exit: make(chan int, 1)}

	w.nm = connect(t, w.addr)
	w.nmCalls = &fakeNM{events: make(chan string, 16)}
	if err := w.nm.Export(w.nmCalls, agentManager, "org.freedesktop.NetworkManager.AgentManager"); err != nil {
		t.Fatal(err)
	}
	own(t, w.nm, nmName)

	kc := connect(t, w.addr)
	w.keyring = &fakeKeyring{conn: kc, items: map[dbus.ObjectPath]keyItem{}}
	kc.Export(keyringService{w.keyring}, secretsPath, "org.freedesktop.Secret.Service")
	kc.Export(keyringCollection{w.keyring}, secretsDefault, "org.freedesktop.Secret.Collection")
	own(t, kc, secretsName)

	sc := connect(t, w.addr)
	w.systemd = &fakeSystemd{conn: sc, state: "inactive"}
	sc.Export(w.systemd, "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager")
	sc.ExportMethodTable(map[string]any{
		"Get": func(iface, prop string) (dbus.Variant, *dbus.Error) {
			w.systemd.mu.Lock()
			defer w.systemd.mu.Unlock()
			return dbus.MakeVariant(w.systemd.state), nil
		},
	}, lockPath, "org.freedesktop.DBus.Properties")
	own(t, sc, "org.freedesktop.systemd1")

	w.bluez = connect(t, w.addr)
	w.btCalls = newFakeBlueZ(t, w.bluez)
	own(t, w.bluez, bluezName)

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	w.toShell = inW
	go func() {
		lines := bufio.NewScanner(outR)
		for lines.Scan() {
			var m map[string]any
			if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
				t.Errorf("a line that isn't JSON: %q", lines.Text())
				continue
			}
			w.msgs <- m
		}
	}()
	dial := func() (*dbus.Conn, error) { return dbus.Connect(w.addr) }
	go func() {
		w.exit <- run(inR, outW, w.stderr, config{system: dial, session: dial, dirs: []string{w.plugins}, timeout: timeout, btTimeout: firstOr(btTimeout, 0)})
		outW.Close()
	}()
	t.Cleanup(func() {
		inW.Close()
		select {
		case <-w.exit:
		case <-time.After(patience):
			t.Error("tide-agent didn't exit once stdin closed")
		}
	})
	w.expectNM("register io.github.mikelward.tide 1")
	w.expect("status")
	return w
}

// expect is the next message of type typ, skipping any others.
func (w *world) expect(typ string) map[string]any {
	w.t.Helper()
	deadline := time.After(patience)
	for {
		select {
		case m := <-w.msgs:
			if m["type"] == typ {
				return m
			}
		case <-deadline:
			w.t.Fatalf("no %q message from tide-agent; its log:\n%s", typ, w.stderr)
		}
	}
}

func (w *world) expectNM(event string) {
	w.t.Helper()
	select {
	case got := <-w.nmCalls.events:
		if got != event {
			w.t.Fatalf("NetworkManager heard %q, want %q", got, event)
		}
	case <-time.After(patience):
		w.t.Fatalf("NetworkManager never heard %q; the agent's log:\n%s", event, w.stderr)
	}
}

func (w *world) answer(m map[string]any) {
	w.t.Helper()
	b, _ := json.Marshal(m)
	if _, err := w.toShell.Write(append(b, '\n')); err != nil {
		w.t.Fatal(err)
	}
}

// The agent's unique name, as NetworkManager would call it.
func (w *world) agentName() string {
	w.nmCalls.mu.Lock()
	defer w.nmCalls.mu.Unlock()
	return w.nmCalls.agent
}

type result struct {
	secrets settings
	err     error
}

func (w *world) getSecrets(from *dbus.Conn, conn settings, setting string, hints []string, flags uint32) chan result {
	ch := make(chan result, 1)
	name := w.agentName()
	go func() {
		var out settings
		err := from.Object(name, agentPath).Call(agentIface+".GetSecrets", 0, conn, dbus.ObjectPath("/org/freedesktop/NetworkManager/Settings/1"), setting, hints, flags).Store(&out)
		ch <- result{out, err}
	}()
	return ch
}

func (w *world) result(ch chan result) result {
	w.t.Helper()
	select {
	case r := <-ch:
		return r
	case <-time.After(patience):
		w.t.Fatalf("GetSecrets never returned; the agent's log:\n%s", w.stderr)
	}
	return result{}
}

func errName(err error) string {
	if e, ok := err.(dbus.Error); ok {
		return e.Name
	}
	return fmt.Sprint(err)
}

func psk(flags uint32) settings {
	return wifi(map[string]dbus.Variant{"key-mgmt": v("wpa-psk"), "psk-flags": v(flags)})
}

func TestWifiAskedThroughTheShell(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction|flagUserRequested)
	req := w.expect("request")
	if req["kind"] != "wifi" || req["ssid"] != "Home Net" || req["userRequested"] != true {
		t.Errorf("request %v", req)
	}
	fields, _ := req["fields"].([]any)
	if len(fields) != 1 || fields[0].(map[string]any)["key"] != "psk" {
		t.Errorf("fields %v", req["fields"])
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"psk": "hunter22", "extra": "x"}})
	r := w.result(ch)
	if r.err != nil {
		t.Fatal(r.err)
	}
	if got := r.secrets["802-11-wireless-security"]; len(got) != 1 || got["psk"].Value() != "hunter22" {
		t.Errorf("secrets %v", r.secrets)
	}
	if strings.Contains(w.stderr.String(), "hunter22") {
		t.Errorf("the log holds the password:\n%s", w.stderr)
	}
}

func TestShellCancelIsUserCanceled(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req := w.expect("request")
	w.answer(map[string]any{"type": "cancel", "id": req["id"]})
	if r := w.result(ch); errName(r.err) != errUserCancel {
		t.Errorf("err = %v, want %s", r.err, errUserCancel)
	}
	ch = w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req = w.expect("request")
	w.answer(map[string]any{"type": "decline", "id": req["id"]})
	if r := w.result(ch); errName(r.err) != errNoSecrets {
		t.Errorf("decline: err = %v, want %s", r.err, errNoSecrets)
	}
}

func TestOnlyNetworkManagerMayAsk(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	other := connect(t, w.addr)
	r := w.result(w.getSecrets(other, psk(0), "802-11-wireless-security", nil, flagAllowInteraction))
	if errName(r.err) != errPermission {
		t.Errorf("err = %v, want %s", r.err, errPermission)
	}
	// And no prompt went to the shell: the next request is NetworkManager's.
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req := w.expect("request")
	w.answer(map[string]any{"type": "cancel", "id": req["id"]})
	w.result(ch)
	if req["id"] != "1" {
		t.Errorf("a request reached the shell from another sender: this one is %v", req["id"])
	}
}

func TestSavedSecretsAnswerWithoutAsking(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	w.keyring.add(map[string]string{"connection-uuid": "u-1", "setting-name": "802-11-wireless-security", "setting-key": "psk"}, "from-keyring")
	r := w.result(w.getSecrets(w.nm, psk(secretAgentOwned), "802-11-wireless-security", nil, flagAllowInteraction))
	if r.err != nil || r.secrets["802-11-wireless-security"]["psk"].Value() != "from-keyring" {
		t.Errorf("secrets %v, err %v", r.secrets, r.err)
	}
	// Asking for new ones skips the keyring, and shows the shell nothing
	// saved.
	ch := w.getSecrets(w.nm, psk(secretAgentOwned), "802-11-wireless-security", nil, flagAllowInteraction|flagRequestNew)
	req := w.expect("request")
	if f := req["fields"].([]any)[0].(map[string]any); f["value"] != "" {
		t.Errorf("REQUEST_NEW filled in %v", f["value"])
	}
	w.answer(map[string]any{"type": "cancel", "id": req["id"]})
	w.result(ch)
}

func TestNoInteractionMeansNoPrompt(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	r := w.result(w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, 0))
	if errName(r.err) != errNoSecrets {
		t.Errorf("err = %v", r.err)
	}
}

func TestSaveAndDeleteSecrets(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	agent := w.nm.Object(w.agentName(), agentPath)
	conn := wifi(map[string]dbus.Variant{"key-mgmt": v("wpa-psk"), "psk": v("saved-psk"), "psk-flags": v(uint32(secretAgentOwned))})
	if err := agent.Call(agentIface+".SaveSecrets", 0, conn, dbus.ObjectPath("/x")).Err; err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"u-1/802-11-wireless-security/psk": "saved-psk"}
	if got := w.keyring.values(); !reflect.DeepEqual(got, want) {
		t.Errorf("keyring %v", got)
	}
	// A system-owned secret isn't the agent's to keep, and saving again
	// drops the old entry.
	conn["802-11-wireless-security"]["psk-flags"] = v(uint32(0))
	if err := agent.Call(agentIface+".SaveSecrets", 0, conn, dbus.ObjectPath("/x")).Err; err != nil {
		t.Fatal(err)
	}
	if got := w.keyring.values(); len(got) != 0 {
		t.Errorf("keyring after a system-owned save %v", got)
	}
	w.keyring.add(map[string]string{"connection-uuid": "u-1", "setting-name": "vpn", "setting-key": "password"}, "p")
	if err := agent.Call(agentIface+".DeleteSecrets", 0, conn, dbus.ObjectPath("/x")).Err; err != nil {
		t.Fatal(err)
	}
	if got := w.keyring.values(); len(got) != 0 {
		t.Errorf("keyring after delete %v", got)
	}
}

func TestLockedRequestsAreMissed(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	w.systemd.set("active")
	if m := w.expect("lock"); m["locked"] != true {
		t.Fatalf("lock %v", m)
	}
	r := w.result(w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction))
	if errName(r.err) != errNoSecrets {
		t.Errorf("err = %v", r.err)
	}
	m := w.expect("missed")
	if c, _ := m["connection"].(map[string]any); c["uuid"] != "u-1" {
		t.Errorf("missed %v", m)
	}
	w.systemd.set("inactive")
	if m := w.expect("lock"); m["locked"] != false {
		t.Errorf("unlock %v", m)
	}
}

func TestCancelGetSecrets(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req := w.expect("request")
	if err := w.nm.Object(w.agentName(), agentPath).Call(agentIface+".CancelGetSecrets", 0, dbus.ObjectPath("/org/freedesktop/NetworkManager/Settings/1"), "802-11-wireless-security").Err; err != nil {
		t.Fatal(err)
	}
	if m := w.expect("cancel"); m["id"] != req["id"] {
		t.Errorf("cancel %v for request %v", m, req["id"])
	}
	if r := w.result(ch); errName(r.err) != errCanceled {
		t.Errorf("err = %v", r.err)
	}
}

func TestUnansweredRequestTimesOut(t *testing.T) {
	// A short limit, so the test doesn't wait out the real one.
	w := newWorld(t, 200*time.Millisecond)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	w.expect("request")
	w.expect("cancel")
	if r := w.result(ch); errName(r.err) != errNoSecrets {
		t.Errorf("err = %v", r.err)
	}
	w.expect("missed")
}

func TestStandsAsideForNMApplet(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	applet := connect(t, w.addr)
	own(t, applet, appletName)
	w.expectNM("unregister")
	if m := w.expect("status"); m["state"] != "standing-aside" || m["pid"].(float64) != float64(os.Getpid()) {
		t.Errorf("status %v", m)
	}
	if _, err := applet.ReleaseName(appletName); err != nil {
		t.Fatal(err)
	}
	w.expectNM("register io.github.mikelward.tide 1")
	if m := w.expect("status"); m["state"] != "registered" {
		t.Errorf("status %v", m)
	}
}

func TestShellGoneAnswersNoSecrets(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	w.expect("request")
	w.toShell.Close()
	if r := w.result(ch); errName(r.err) != errNoSecrets {
		t.Errorf("err = %v", r.err)
	}
	select {
	case code := <-w.exit:
		w.exit <- code
		if code != 0 {
			t.Errorf("exit %d", code)
		}
	case <-time.After(patience):
		t.Fatal("no exit")
	}
	w.expectNM("unregister")
}

func vpnConn(service string) settings {
	return settings{
		"connection": {"id": v("Work VPN"), "uuid": v("u-3"), "type": v("vpn")},
		"vpn": {
			"service-type": v(service),
			"data":         v(map[string]string{"remote": "vpn.example.com", "password-flags": "1"}),
			"secrets":      v(map[string]string{}),
		},
	}
}

func (w *world) plugin(service, dialog string, externalUI bool) string {
	w.t.Helper()
	script := filepath.Join(w.plugins, "dialog-"+strings.ReplaceAll(service, ".", "-"))
	writeFile(w.t, script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > "+script+".args\n"+dialog, 0o755)
	writeFile(w.t, filepath.Join(w.plugins, service+".name"), fmt.Sprintf("[VPN Connection]\nservice=%s\n[GNOME]\nauth-dialog=%s\nsupports-external-ui-mode=%v\nsupports-hints=true\n", service, script, externalUI), 0o644)
	return script
}

func TestVPNExternalUI(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	script := w.plugin("org.example.ovpn", `cat > "$0.stdin"
cat <<EOF
[VPN Plugin UI]
Version=2
Title=Authenticate VPN
Description=Sign in to Work VPN.

[password]
Value=
Label=Password:
IsSecret=true
ShouldAsk=true

[challenge-response]
Value=
Label=Code:
IsSecret=false
ShouldAsk=true

[cert-pass]
Value=kept
ShouldAsk=false
EOF
`, true)
	w.keyring.add(map[string]string{"connection-uuid": "u-3", "setting-name": "vpn", "setting-key": "password"}, "from-keyring")
	ch := w.getSecrets(w.nm, vpnConn("org.example.ovpn"), "vpn", []string{"x-vpn-message:Enter the code"}, flagAllowInteraction|flagUserRequested)
	req := w.expect("request")
	if req["kind"] != "vpn" || req["title"] != "Authenticate VPN" || len(req["fields"].([]any)) != 2 {
		t.Errorf("request %v", req)
	}
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"password": "typed", "challenge-response": "123456"}})
	r := w.result(ch)
	if r.err != nil {
		t.Fatal(r.err)
	}
	want := map[string]string{"password": "typed", "challenge-response": "123456", "cert-pass": "kept"}
	if got := r.secrets["vpn"]["secrets"].Value(); !reflect.DeepEqual(got, want) {
		t.Errorf("secrets %v", got)
	}
	args, _ := os.ReadFile(script + ".args")
	if want := "-u\nu-3\n-n\nWork VPN\n-s\norg.example.ovpn\n--external-ui-mode\n-i\n-t\nx-vpn-message:Enter the code\n"; string(args) != want {
		t.Errorf("args %q", args)
	}
	// The saved password went to the dialog, as nm-applet's would.
	stdin, _ := os.ReadFile(script + ".stdin")
	if !strings.Contains(string(stdin), "SECRET_KEY=password\nSECRET_VAL=from-keyring\n") {
		t.Errorf("stdin %q", stdin)
	}
	if strings.Contains(w.stderr.String(), "123456") || strings.Contains(w.stderr.String(), "typed") {
		t.Errorf("the log holds a secret:\n%s", w.stderr)
	}
}

func TestVPNOwnWindow(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	script := w.plugin("org.example.oc", `while read -r line; do test "$line" = DONE && break; done
read -r blank
printf 'cookie\nabc\n\n\n'
read -r quit
echo "$quit" > "$0.quit"
`, false)
	ch := w.getSecrets(w.nm, vpnConn("org.example.oc"), "vpn", nil, flagAllowInteraction|flagUserRequested)
	req := w.expect("request")
	if req["kind"] != "vpn-dialog" {
		t.Errorf("request %v", req)
	}
	if _, err := os.Stat(script + ".args"); err == nil {
		t.Error("the dialog ran before the shell said go")
	}
	w.answer(map[string]any{"type": "go", "id": req["id"]})
	r := w.result(ch)
	if r.err != nil {
		t.Fatal(r.err)
	}
	if got := r.secrets["vpn"]["secrets"].Value(); !reflect.DeepEqual(got, map[string]string{"cookie": "abc"}) {
		t.Errorf("secrets %v", got)
	}
	if quit, _ := os.ReadFile(script + ".quit"); strings.TrimSpace(string(quit)) != "QUIT" {
		t.Errorf("quit %q", quit)
	}
}

func TestVPNWithoutPlugin(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	r := w.result(w.getSecrets(w.nm, vpnConn("org.example.missing"), "vpn", nil, flagAllowInteraction))
	if errName(r.err) != errNoSecrets {
		t.Errorf("err = %v", r.err)
	}
	if !strings.Contains(w.stderr.String(), "no VPN plugin for org.example.missing") {
		t.Errorf("the log doesn't name the plugin:\n%s", w.stderr)
	}
}

// forge sends a signal from conn straight to dest, past any match rule, as
// any peer on the bus can.
func forge(t *testing.T, conn *dbus.Conn, dest string, path dbus.ObjectPath, iface, member string, body ...any) {
	t.Helper()
	msg := &dbus.Message{
		Type: dbus.TypeSignal,
		Headers: map[dbus.HeaderField]dbus.Variant{
			dbus.FieldPath:        dbus.MakeVariant(path),
			dbus.FieldInterface:   dbus.MakeVariant(iface),
			dbus.FieldMember:      dbus.MakeVariant(member),
			dbus.FieldDestination: dbus.MakeVariant(dest),
		},
		Body: body,
	}
	if len(body) > 0 {
		msg.Headers[dbus.FieldSignature] = dbus.MakeVariant(dbus.SignatureOf(body...))
	}
	if call := <-conn.Send(msg, make(chan *dbus.Call, 1)).Done; call != nil && call.Err != nil {
		t.Fatal(call.Err)
	}
}

func TestForgedSignalsAreIgnored(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	peer := connect(t, w.addr)
	// Claim NetworkManager has gone, and that nm-applet has come, then
	// that the session has locked.
	forge(t, peer, w.agentName(), "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", nmName, w.nm.Names()[0], "")
	forge(t, peer, w.agentName(), "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged", appletName, "", peer.Names()[0])
	w.systemd.mu.Lock()
	session := w.systemd.subscriber
	w.systemd.mu.Unlock()
	forge(t, peer, session, lockPath, "org.freedesktop.DBus.Properties", "PropertiesChanged",
		"org.freedesktop.systemd1.Unit", map[string]dbus.Variant{"ActiveState": dbus.MakeVariant("active")}, []string{})
	// A real request is still asked, so none of them took.
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req := w.expect("request")
	w.answer(map[string]any{"type": "reply", "id": req["id"], "values": map[string]string{"psk": "p"}})
	if r := w.result(ch); r.err != nil {
		t.Errorf("err = %v", r.err)
	}
	select {
	case e := <-w.nmCalls.events:
		t.Errorf("NetworkManager heard %q after forged signals", e)
	default:
	}
}

func firstOr(d []time.Duration, or time.Duration) time.Duration {
	if len(d) > 0 {
		return d[0]
	}
	return or
}

func TestNetworkManagerGoingTakesItsRequestsDown(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	ch := w.getSecrets(w.nm, psk(0), "802-11-wireless-security", nil, flagAllowInteraction)
	req := w.expect("request")
	if _, err := w.nm.ReleaseName(nmName); err != nil {
		t.Fatal(err)
	}
	// The cancel and the new status come in either order.
	got := w.expectBoth("cancel", "status")
	if got["cancel"]["id"] != req["id"] || got["status"]["state"] != "waiting" {
		t.Errorf("got %v", got)
	}
	if r := w.result(ch); errName(r.err) != errCanceled {
		t.Errorf("err = %v", r.err)
	}
}

// expectBoth is the next message of each type, in whatever order they come.
func (w *world) expectBoth(a, b string) map[string]map[string]any {
	w.t.Helper()
	got := map[string]map[string]any{}
	deadline := time.After(patience)
	for len(got) < 2 {
		select {
		case m := <-w.msgs:
			if typ, _ := m["type"].(string); (typ == a || typ == b) && got[typ] == nil {
				got[typ] = m
			}
		case <-deadline:
			w.t.Fatalf("no %q and %q from tide-agent; its log:\n%s", a, b, w.stderr)
		}
	}
	return got
}

func TestNetworkManagerRestartingMidRegistrationRegistersWithTheNewOne(t *testing.T) {
	w := newWorld(t, defaultTimeout)
	register := "register io.github.mikelward.tide 1"
	nm := func() (*dbus.Conn, *fakeNM) {
		c := connect(t, w.addr)
		f := &fakeNM{events: make(chan string, 16)}
		if err := c.Export(f, agentManager, "org.freedesktop.NetworkManager.AgentManager"); err != nil {
			t.Fatal(err)
		}
		return c, f
	}
	expect := func(f *fakeNM, event string) {
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
	b, fb := nm()
	fb.gate = make(chan struct{})
	if _, err := w.nm.ReleaseName(nmName); err != nil {
		t.Fatal(err)
	}
	own(t, b, nmName)
	expect(fb, register)
	if _, err := b.ReleaseName(nmName); err != nil {
		t.Fatal(err)
	}
	c, fc := nm()
	own(t, c, nmName)
	close(fb.gate)
	expect(fc, register)
}
