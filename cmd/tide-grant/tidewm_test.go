package main

import (
	"bytes"
	"io"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/mikelward/quickspace/internal/swayipc/swayipctest"
)

// In tidewm's session (SPEC.md §5.3) a terminal command's grant goes
// over tidewm's IPC, found by SWAYSOCK, and never to Hyprland.
func TestTidewmGetsTheGrant(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tidewm:tide", "SWAYSOCK=" + tidewm.Socket,
		"XDG_DATA_HOME=/nonexistent", "XDG_DATA_DIRS=/nonexistent"}
	var stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", "--", "nautilus ."}, env, io.Discard, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	if got, want := tidewm.Payloads(), []string{"grant --pid 4242 --key " + key + " nautilus"}; !reflect.DeepEqual(got, want) {
		t.Errorf("tidewm got %q, want %q", got, want)
	}
	if got := readLog(t, log); got != "" {
		t.Errorf("hyprctl was asked too: %q", got)
	}
}

func TestTidewmGetsThePidAlone(t *testing.T) {
	_, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tidewm:tide", "SWAYSOCK=" + tidewm.Socket,
		"XDG_DATA_HOME=/nonexistent", "XDG_DATA_DIRS=/nonexistent"}
	if status := run([]string{"--pid", "4242", "cd /tmp && nautilus ."}, env, io.Discard, io.Discard); status != 0 {
		t.Fatalf("run = %d", status)
	}
	if got, want := tidewm.Payloads(), []string{"grant --pid 4242 --key " + key}; !reflect.DeepEqual(got, want) {
		t.Errorf("tidewm got %q, want %q", got, want)
	}
}

// The desktop entries' classes widen the grant with `grant extend`, keyed
// as the grant was.
func TestTidewmGetsTheExtension(t *testing.T) {
	_, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.gnome.Nautilus.desktop", "[Desktop Entry]\nExec=nautilus --new-window %U\n")
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	env := append([]string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tidewm:tide", "SWAYSOCK=" + tidewm.Socket},
		dataEnv("/nonexistent", sys)...)
	var stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", "nautilus ."}, env, io.Discard, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	want := []string{
		"grant --pid 4242 --key " + key + " nautilus",
		"grant extend --key " + key + " --pid 4242 nautilus org.gnome.Nautilus",
	}
	if got := tidewm.Payloads(); !reflect.DeepEqual(got, want) {
		t.Errorf("tidewm got %q, want %q", got, want)
	}
}

func TestTidewmRefusingTheGrantIsReported(t *testing.T) {
	_, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	tidewm := swayipctest.New(t, `[{"success":false,"error":"grant: expected app ids"}]`)
	env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tidewm:tide", "SWAYSOCK=" + tidewm.Socket,
		"XDG_DATA_HOME=/nonexistent", "XDG_DATA_DIRS=/nonexistent"}
	var stderr bytes.Buffer
	if status := run([]string{"nautilus ."}, env, io.Discard, &stderr); status != 1 {
		t.Errorf("run = %d, want 1", status)
	}
	if want := "couldn't record a focus grant for nautilus .: grant: expected app ids"; !strings.Contains(stderr.String(), want) {
		t.Errorf("stderr %q doesn't contain %q", stderr.String(), want)
	}
}

func TestTidewmUnreachableIsReported(t *testing.T) {
	_, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	for _, sock := range []string{"", "SWAYSOCK=" + filepath.Join(t.TempDir(), "gone.sock")} {
		env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tidewm:tide", sock,
			"XDG_DATA_HOME=/nonexistent", "XDG_DATA_DIRS=/nonexistent"}
		var stderr bytes.Buffer
		if status := run([]string{"nautilus ."}, env, io.Discard, &stderr); status != 1 {
			t.Errorf("%q: run = %d, want 1", sock, status)
		}
		if !strings.Contains(stderr.String(), "couldn't record a focus grant for nautilus .") {
			t.Errorf("%q: stderr %q", sock, stderr.String())
		}
	}
}

func TestInTidewm(t *testing.T) {
	for desktops, want := range map[string]bool{
		"tidewm:tide": true, "tide:tidewm": true, "tide:Hyprland": false, "tidewm": false, "tide": false, "": false,
	} {
		if got := inTidewm(desktops); got != want {
			t.Errorf("inTidewm(%q) = %v", desktops, got)
		}
	}
}
