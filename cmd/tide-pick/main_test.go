package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/godbus/dbus/v5"
)

// tide-pick runs here against a private bus from dbus-daemon, with a
// stand-in for the desktop portal's FileChooser. The portal and GTK's
// dialog can't run here (SPEC.md §20).

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

func privateBus(t *testing.T) string {
	t.Helper()
	daemon, err := exec.LookPath("dbus-daemon")
	if err != nil {
		if os.Getenv("CI") != "" {
			t.Fatal("no dbus-daemon on PATH, which CI must have to run tide-pick's tests")
		}
		t.Skip("no dbus-daemon on PATH; install dbus-daemon to run tide-pick's tests")
	}
	dir := t.TempDir()
	socket := filepath.Join(dir, "bus")
	conf := filepath.Join(dir, "bus.conf")
	if err := os.WriteFile(conf, []byte(fmt.Sprintf(busConfig, socket)), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(daemon, "--config-file="+conf, "--nofork", "--print-address")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
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

// fakePortal answers each OpenFile with `response` and `uris`, on the
// request's documented path, or on a path of its own as an old portal
// does; with `silent`, it answers nothing and quits.
type fakePortal struct {
	conn     *dbus.Conn
	response uint32
	uris     []string
	oldPath  bool
	silent   bool
	title    string
	opts     map[string]dbus.Variant
}

func (f *fakePortal) OpenFile(parent, title string, opts map[string]dbus.Variant, sender dbus.Sender) (dbus.ObjectPath, *dbus.Error) {
	f.title, f.opts = title, opts
	token, _ := opts["handle_token"].Value().(string)
	path := requestPath(string(sender), token)
	if f.oldPath {
		path = "/org/freedesktop/portal/desktop/request/old/1"
	}
	go func() {
		// Giving up the name, rather than closing the connection, so the
		// call's reply still goes out whichever comes first.
		if f.silent {
			f.conn.ReleaseName(portalName)
			return
		}
		results := map[string]dbus.Variant{}
		if f.uris != nil {
			results["uris"] = dbus.MakeVariant(f.uris)
		}
		f.conn.Emit(path, requestIface+".Response", f.response, results)
	}()
	return path, nil
}

func portal(t *testing.T, addr string, f *fakePortal) {
	t.Helper()
	f.conn = connect(t, addr)
	if err := f.conn.Export(f, portalPath, chooserIface); err != nil {
		t.Fatal(err)
	}
	reply, err := f.conn.RequestName(portalName, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		t.Fatalf("couldn't own %s: %v %v", portalName, reply, err)
	}
}

func pickWith(t *testing.T, addr string, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := run(args, &stdout, &stderr, func() (*dbus.Conn, error) { return dbus.Connect(addr) })
	return code, stdout.String(), stderr.String()
}

func TestPrintsTheChosenFile(t *testing.T) {
	addr := privateBus(t)
	f := &fakePortal{uris: []string{"file:///home/u/Pictures/Day%20one.jpg"}}
	portal(t, addr, f)
	code, out, errs := pickWith(t, addr, "--title", "Light wallpaper", "--images", "--folder=/home/u/Pictures")
	if code != 0 || out != "/home/u/Pictures/Day one.jpg\n" {
		t.Fatalf("got %d %q %q", code, out, errs)
	}
	if f.title != "Light wallpaper" {
		t.Errorf("titled %q", f.title)
	}
	if folder, _ := f.opts["current_folder"].Value().([]byte); string(folder) != "/home/u/Pictures\x00" {
		t.Errorf("opened in %q", folder)
	}
	var filters []filter
	if err := dbus.Store([]interface{}{f.opts["filters"].Value()}, &filters); err != nil || len(filters) != 1 ||
		len(filters[0].Rules) != 1 || filters[0].Rules[0] != (rule{Kind: 1, Pattern: "image/*"}) {
		t.Errorf("filters %v (%v)", filters, err)
	}
}

func TestOffersEveryFileWithoutImages(t *testing.T) {
	addr := privateBus(t)
	f := &fakePortal{uris: []string{"file:///tmp/notes.txt"}}
	portal(t, addr, f)
	if code, out, _ := pickWith(t, addr); code != 0 || out != "/tmp/notes.txt\n" {
		t.Fatalf("got %d %q", code, out)
	}
	if _, ok := f.opts["filters"]; ok {
		t.Error("filtered without --images")
	}
	if _, ok := f.opts["current_folder"]; ok {
		t.Error("a folder without --folder")
	}
}

func TestCancelledPrintsNothing(t *testing.T) {
	addr := privateBus(t)
	portal(t, addr, &fakePortal{response: 1})
	if code, out, errs := pickWith(t, addr, "--images"); code != 0 || out != "" || errs != "" {
		t.Fatalf("got %d %q %q", code, out, errs)
	}
}

func TestAnOldPortalsOwnRequestPath(t *testing.T) {
	addr := privateBus(t)
	portal(t, addr, &fakePortal{uris: []string{"file:///tmp/a.png"}, oldPath: true})
	if code, out, errs := pickWith(t, addr); code != 0 || out != "/tmp/a.png\n" {
		t.Fatalf("got %d %q %q", code, out, errs)
	}
}

func TestAFileElsewhereIsAnError(t *testing.T) {
	addr := privateBus(t)
	portal(t, addr, &fakePortal{uris: []string{"https://example.com/a.png"}})
	code, out, errs := pickWith(t, addr)
	if code != 2 || out != "" || !strings.Contains(errs, "isn't a file on this machine") {
		t.Fatalf("got %d %q %q", code, out, errs)
	}
}

func TestNoPortalIsAnError(t *testing.T) {
	addr := privateBus(t)
	code, _, errs := pickWith(t, addr)
	if code != 2 || !strings.Contains(errs, "xdg-desktop-portal-gtk") {
		t.Fatalf("got %d %q", code, errs)
	}
}

func TestAPortalQuittingEndsTheWait(t *testing.T) {
	addr := privateBus(t)
	portal(t, addr, &fakePortal{silent: true})
	code, _, errs := pickWith(t, addr)
	if code != 2 || !strings.Contains(errs, "quit before") {
		t.Fatalf("got %d %q", code, errs)
	}
}

func TestTakesNoArguments(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"a.png"}, &stdout, &stderr, func() (*dbus.Conn, error) {
		t.Fatal("connected for a bad command line")
		return nil, nil
	})
	if code != 2 || !strings.Contains(stderr.String(), "takes no arguments") {
		t.Fatalf("got %d %q", code, stderr.String())
	}
}
