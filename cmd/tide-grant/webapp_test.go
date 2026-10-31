package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestWebAppClass(t *testing.T) {
	for in, want := range map[string]string{
		"https://calendar.google.com":            "chrome-calendar.google.com__-Default",
		"https://calendar.google.com/":           "chrome-calendar.google.com__-Default",
		"https://Mail.Google.com/mail/u/0/":      "chrome-mail.google.com__mail_u_0_-Default",
		"http://music.youtube.com:8080/":         "chrome-music.youtube.com__-Default",
		"file:///home/user/x.html":               "",
		"https://":                               "",
		"calendar.google.com":                    "",
		"https://chat.google.com/room/abc?x=1#y": "chrome-chat.google.com__room_abc-Default",
	} {
		if got := webAppClass(in); got != want {
			t.Errorf("webAppClass(%q) = %q, want %q", in, got, want)
		}
	}
}

// writeScript writes an executable file named name in dir.
func writeScript(t *testing.T, dir, name, text string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(text), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// A launcher script's window is the `--app` window it opens: scripts'
// google-calendar runs `chrome --app="https://calendar.google.com"`.
func TestWebAppClassesOfAScript(t *testing.T) {
	bin := t.TempDir()
	writeScript(t, bin, "google-calendar", "#!/bin/bash\nchrome --app=\"https://calendar.google.com\"\n")
	writeScript(t, bin, "youtube-music", "#!/bin/bash\n. \"$HOME/.shrc\"\nexec chrome --app='https://music.youtube.com' ${DIR:+--user-data-dir=\"$DIR\"}\n")
	writeScript(t, bin, "plain", "#!/bin/sh\nexec editor \"$@\"\n")
	writeScript(t, bin, "binary", "\x7fELF --app=https://example.com\n")
	env := []string{"PATH=" + bin}
	for runs, want := range map[string][]string{
		"google-calendar":                   {"chrome-calendar.google.com__-Default"},
		"youtube-music":                     {"chrome-music.youtube.com__-Default"},
		filepath.Join(bin, "youtube-music"): {"chrome-music.youtube.com__-Default"},
		"plain":                             nil,
		"binary":                            nil,
		"not-on-path":                       nil,
	} {
		if got := webAppClasses([]string{runs}, runs, env); !reflect.DeepEqual(got, want) {
			t.Errorf("webAppClasses(%s) = %q, want %q", runs, got, want)
		}
	}
	// Chrome's own command names its `--app` site.
	words := []string{"google-chrome", "--app=https://chat.google.com", "--app=https://chat.google.com/"}
	if got, want := webAppClasses(words, "google-chrome", env), []string{"chrome-chat.google.com__-Default"}; !reflect.DeepEqual(got, want) {
		t.Errorf("webAppClasses(%q) = %q, want %q", words, got, want)
	}
}

// --classes, which tide launch and the shell's home apps read, names a
// launcher script's `--app` window, through runenv too.
func TestRunClassesOfALauncherScript(t *testing.T) {
	bin := t.TempDir()
	writeScript(t, bin, "google-chat", "#!/bin/bash\nchrome --app=\"https://chat.google.com\"\n")
	env := append([]string{"PATH=" + bin}, dataEnv("/nonexistent", "/nonexistent")...)
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--classes", "--", "google-chat"}, env, &stdout, &stderr); status != 0 {
		t.Fatalf("run --classes = %d, stderr %q", status, stderr.String())
	}
	if got, want := stdout.String(), "chrome-chat.google.com__-Default\n"; got != want {
		t.Errorf("--classes google-chat printed %q, want %q", got, want)
	}
}

// scripts' runenv runs its arguments, so the program past it is the one
// granted, and looked up: Super+Shift+C's `runenv google-chat` is
// google-chat's --app window's.
func TestRunenvIsAWrapper(t *testing.T) {
	for _, words := range []string{"runenv google-chat", "/home/user/scripts/runenv google-chat", "env runenv google-chat"} {
		name, _, moves := commandProgram(strings.Fields(words))
		if name != "google-chat" || moves {
			t.Errorf("commandProgram(%s) = %q, moves %v; want google-chat, false", words, name, moves)
		}
	}
	bin := t.TempDir()
	writeScript(t, bin, "google-chat", "#!/bin/bash\nchrome --app=\"https://chat.google.com\"\n")
	env := append([]string{"PATH=" + bin}, dataEnv("/nonexistent", "/nonexistent")...)
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--program", "--", filepath.Join(bin, "runenv"), "google-chat"}, env, &stdout, &stderr); status != 0 || stdout.String() != "google-chat\n" {
		t.Errorf("--program runenv google-chat = %d, %q; want 0, google-chat", status, stdout.String())
	}
	stdout.Reset()
	if status := run([]string{"--classes", "--", filepath.Join(bin, "runenv"), "google-chat"}, env, &stdout, &stderr); status != 0 || stdout.String() != "chrome-chat.google.com__-Default\n" {
		t.Errorf("--classes runenv google-chat = %d, %q; want 0, its --app window's class", status, stdout.String())
	}
}
