package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// fakeXdgMime stands in for xdg-mime: types maps a path to its type,
// defaults a type to its default app, and fail, if set, is every call's
// error. It returns the calls made.
func fakeXdgMime(t *testing.T, types, defaults map[string]string, fail error) *[]string {
	t.Helper()
	var calls []string
	real := xdgMime
	t.Cleanup(func() { xdgMime = real })
	xdgMime = func(_ []string, args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		if fail != nil {
			return "", fail
		}
		switch args[1] {
		case "filetype":
			return types[args[2]], nil
		case "default":
			return defaults[args[2]], nil
		}
		return "", errors.New("unexpected call")
	}
	return &calls
}

func TestOpenerTarget(t *testing.T) {
	for words, want := range map[string]string{
		"xdg-open https://example.com/":     "https://example.com/",
		"/usr/bin/xdg-open notes.txt":       "notes.txt",
		"nice -n 5 xdg-open notes.txt":      "notes.txt",
		"gio open notes.txt":                "notes.txt",
		"gio open -- notes.txt":             "notes.txt",
		"gio open -- -notes.txt":            "-notes.txt",
		"gio open -- a b":                   "",
		"xdg-open -- notes.txt":             "",
		"xdg-open":                          "",
		"xdg-open --help":                   "",
		"xdg-open a b":                      "",
		"gio open a b":                      "",
		"gio trash notes.txt":               "",
		"gio open --help":                   "",
		"editor notes.txt":                  "",
		"env --help":                        "",
		"flatpak run org.example.App a.txt": "",
	} {
		got, ok := openerTarget(strings.Fields(words))
		if got != want || ok != (want != "") {
			t.Errorf("openerTarget(%q) = %q, %v; want %q", words, got, ok, want)
		}
	}
}

func TestOpenerClasses(t *testing.T) {
	dir := t.TempDir()
	notes := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(notes, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	sys := t.TempDir()
	writeEntry(t, sys, "org.mozilla.firefox.desktop", "[Desktop Entry]\nExec=firefox %u\n")
	writeEntry(t, sys, "org.example.Editor.desktop", "[Desktop Entry]\nExec=editor %F\nStartupWMClass=example-editor\n")
	env := dataEnv("/nonexistent", sys)
	calls := fakeXdgMime(t, map[string]string{notes: "text/plain"}, map[string]string{
		"x-scheme-handler/https": "org.mozilla.firefox.desktop",
		"text/plain":             "org.example.Editor.desktop;other.desktop",
	}, nil)

	for target, want := range map[string][]string{
		"HTTPS://example.com/": {"org.mozilla.firefox", "firefox"},
		notes:                  {"org.example.Editor", "example-editor", "editor"},
		"file://" + notes:      {"org.example.Editor", "example-editor", "editor"},
	} {
		*calls = nil
		got, err := openerClasses(target, env)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("openerClasses(%q) = %q, %v; want %q", target, got, err, want)
		}
	}
	// A URL is typed by its scheme, never asked of xdg-mime as a file.
	*calls = nil
	openerClasses("https://example.com/", env)
	if want := []string{"query default x-scheme-handler/https"}; !reflect.DeepEqual(*calls, want) {
		t.Errorf("a URL's calls = %q, want %q", *calls, want)
	}
	// Neither a file nor a URL, or a file:// URL naming no file: nothing,
	// and nothing asked.
	for _, target := range []string{"no-such-file", "file://" + dir + "/my%20notes.txt", "1:2"} {
		*calls = nil
		if got, err := openerClasses(target, env); len(got) != 0 || err != nil || len(*calls) != 0 {
			t.Errorf("openerClasses(%q) = %q, %v after %q; want nothing", target, got, err, *calls)
		}
	}
	// No default app is errNoDefault, naming the type.
	if _, err := openerClasses("mailto:a@example.com", env); !errors.Is(err, errNoDefault) || !strings.Contains(err.Error(), "x-scheme-handler/mailto") {
		t.Errorf("no default app: %v", err)
	}
	// A stale default says which, and why.
	fakeXdgMime(t, nil, map[string]string{"x-scheme-handler/https": "gone.desktop"}, nil)
	if _, err := openerClasses("https://example.com/", env); err == nil || errors.Is(err, errNoDefault) || !strings.Contains(err.Error(), "gone.desktop, the default app for x-scheme-handler/https: no such desktop entry") {
		t.Errorf("a stale default: %v", err)
	}
	// xdg-mime failing is an error, for a file and for a URL.
	fakeXdgMime(t, nil, nil, errors.New("exit status 2"))
	for _, target := range []string{notes, "https://example.com/"} {
		if _, err := openerClasses(target, env); err == nil || errors.Is(err, errNoDefault) {
			t.Errorf("a failing xdg-mime for %q: %v", target, err)
		}
	}
}

func TestRunOpener(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "org.mozilla.firefox.desktop", "[Desktop Entry]\nExec=firefox %u\n")
	env := dataEnv("/nonexistent", sys)
	fakeXdgMime(t, nil, map[string]string{"x-scheme-handler/https": "org.mozilla.firefox.desktop"}, nil)
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--opener", "--", "xdg-open", "https://example.com/"}, env, &stdout, &stderr); status != 0 || stdout.String() != "org.mozilla.firefox\nfirefox\n" {
		t.Errorf("--opener = %d, %q, stderr %q", status, stdout.String(), stderr.String())
	}
	// An opener whose app can't be named (several targets): nothing,
	// quietly. A command that runs no opener exits 3, for the caller to
	// grant its program; that's decided at the parsed program's position,
	// so a wrapper's operand reading `gio` isn't the program.
	for words, want := range map[string]int{
		"gio open a b": 0,
		"env --unset gio gio open https://example.com/": 0,
		"editor x":                    3,
		"gio trash x":                 3,
		"gio copy gio open":           3,
		"env --unset gio gio trash x": 3,
	} {
		stdout.Reset()
		stderr.Reset()
		if status := run(append([]string{"--opener", "--"}, strings.Fields(words)...), env, &stdout, &stderr); status != want || stdout.Len() != 0 || stderr.Len() != 0 {
			t.Errorf("--opener %s = %d, %q, %q; want %d and nothing", words, status, stdout.String(), stderr.String(), want)
		}
	}
	// No default app is said, and isn't a failure.
	stderr.Reset()
	if status := run([]string{"--opener", "--", "xdg-open", "mailto:a@example.com"}, env, io.Discard, &stderr); status != 0 || !strings.Contains(stderr.String(), "no default app for x-scheme-handler/mailto") {
		t.Errorf("--opener with no default = %d, stderr %q", status, stderr.String())
	}
	// A failed lookup is.
	fakeXdgMime(t, nil, map[string]string{"x-scheme-handler/https": "gone.desktop"}, nil)
	stderr.Reset()
	if status := run([]string{"--opener", "--", "xdg-open", "https://example.com/"}, env, io.Discard, &stderr); status != 1 || !strings.Contains(stderr.String(), "couldn't find the app that opens the https: URL") {
		t.Errorf("--opener with a stale default = %d, stderr %q", status, stderr.String())
	}
	for _, args := range [][]string{{"--opener"}, {"--opener", "--classes", "xdg-open", "x"}, {"--opener", "--entry", "x", "xdg-open", "y"}} {
		if status := run(args, env, io.Discard, io.Discard); status != 2 {
			t.Errorf("run %q = %d, want 2", args, status)
		}
	}
}

// A terminal's `xdg-open URL` is granted the handler's classes too, so a
// browser that's already running takes focus when it gets the URL.
func TestRunExtendsAnOpenersGrant(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.mozilla.firefox.desktop", "[Desktop Entry]\nExec=firefox %u\n")
	env := append(dataEnv("/nonexistent", sys), "PATH="+path, "XDG_CURRENT_DESKTOP=tide", "SITE=example.com")
	fakeXdgMime(t, nil, map[string]string{"x-scheme-handler/https": "org.mozilla.firefox.desktop"}, nil)
	var stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", `xdg-open "https://$SITE/" &`}, env, io.Discard, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	want := `eval tide_focus.grant("xdg-open", 4242, ` + key + `)` + "\n" +
		`eval tide_focus.extend("xdg-open", { "org.mozilla.firefox", "firefox" }, 4242, ` + key + `)`
	if got := readLog(t, log); got != want {
		t.Errorf("hyprctl got %q, want %q", got, want)
	}

	// No default app is the opener's to say: the grant stands, quietly.
	if err := os.Truncate(log, 0); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
	if status := run([]string{"--pid", "4242", "xdg-open mailto:a@example.com"}, env, io.Discard, &stderr); status != 0 || stderr.Len() != 0 {
		t.Errorf("no default = %d, stderr %q", status, stderr.String())
	}
	if got := readLog(t, log); got != `eval tide_focus.grant("xdg-open", 4242, `+key+`)` {
		t.Errorf("no default: hyprctl got %q", got)
	}

	// A failed lookup is reported; the grant stands.
	fakeXdgMime(t, nil, nil, errors.New("exit status 4"))
	stderr.Reset()
	if status := run([]string{"--pid", "4242", "xdg-open https://example.com/"}, env, io.Discard, &stderr); status != 1 || !strings.Contains(stderr.String(), "couldn't find the app that opens the https: URL for its focus grant") {
		t.Errorf("a failed lookup = %d, stderr %q", status, stderr.String())
	}
}

// A message names a URL by its scheme alone: any part of it may be a
// secret.
func TestShownTarget(t *testing.T) {
	for target, want := range map[string]string{
		"https://example.com/page":              "the https: URL",
		"https://user:hunter2@example.com/page": "the https: URL",
		"https://example.com/reset/s3cr3t":      "the https: URL",
		"HTTPS://example.com/cb?token=abc":      "the https: URL",
		"mailto:a@example.com?subject=hi":       "the mailto: URL",
		"file:///home/user/notes.txt":           "the file: URL",
		"/home/user/notes.txt":                  "/home/user/notes.txt",
		"notes.txt":                             "notes.txt",
	} {
		if got := shownTarget(target); got != want {
			t.Errorf("shownTarget(%q) = %q, want %q", target, got, want)
		}
	}
	// The terminal's failure message is one of them.
	_, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	fakeXdgMime(t, nil, nil, errors.New("exit status 4"))
	env := append(dataEnv("/nonexistent", "/nonexistent"), "PATH="+path, "XDG_CURRENT_DESKTOP=tide")
	var stderr bytes.Buffer
	run([]string{"--pid", "4242", "xdg-open 'https://user:hunter2@example.com/reset/s3cr3t?token=abc'"}, env, io.Discard, &stderr)
	if out := stderr.String(); strings.Contains(out, "hunter2") || strings.Contains(out, "s3cr3t") || strings.Contains(out, "abc") || !strings.Contains(out, "opens the https: URL") {
		t.Errorf("the terminal's message: %q", out)
	}
	stderr.Reset()
	run([]string{"--opener", "--", "xdg-open", "https://example.com/reset/s3cr3t"}, env, io.Discard, &stderr)
	if out := stderr.String(); strings.Contains(out, "s3cr3t") || !strings.Contains(out, "opens the https: URL") {
		t.Errorf("--opener's message: %q", out)
	}
}

// FILE:// is file://: the scheme is case-insensitive.
func TestUppercaseFileURL(t *testing.T) {
	notes := filepath.Join(t.TempDir(), "notes.txt")
	if err := os.WriteFile(notes, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	spaced := filepath.Join(filepath.Dir(notes), "my notes.txt")
	if err := os.WriteFile(spaced, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	calls := fakeXdgMime(t, map[string]string{notes: "text/plain", spaced: "text/x-spaced"}, nil, nil)
	for target, want := range map[string]string{
		// The form both openers read as that file, escapes undone and a
		// query or fragment dropped.
		"file://" + notes: "text/plain",
		"file://" + strings.ReplaceAll(spaced, " ", "%20"): "text/x-spaced",
		"file://" + notes + "?x":                           "text/plain",
		"file://" + notes + "?":                            "text/plain",
		"file://" + notes + "#x":                           "text/plain",
		"file://" + notes + "?x#y":                         "text/plain",
		"file://" + notes + "?next=%2F":                    "text/plain",
		"file://" + notes + "#a%2Fb":                       "text/plain",
		// Forms the openers read differently, or not as this file, name
		// nothing.
		"FILE://" + notes:               "",
		"File://" + notes:               "",
		"file:" + notes:                 "",
		"file://localhost" + notes:      "",
		"file://user@localhost" + notes: "",
		"file://elsewhere" + notes:      "",
		"file:notes.txt":                "",
		"file://" + strings.Replace(notes, "/notes.txt", "%2Fnotes.txt", 1): "",
		"file://" + strings.Replace(notes, "/notes.txt", "%2fnotes.txt", 1): "",
		"file://" + notes + "%00": "",
	} {
		if mime, err := targetType(target, nil); mime != want || err != nil {
			t.Errorf("targetType(%q) = %q, %v; want %q", target, mime, err, want)
		}
	}
	for _, call := range *calls {
		if call != "query filetype "+notes && call != "query filetype "+spaced {
			t.Errorf("unexpected call %q", call)
		}
	}
	// A file:// URL naming nothing is no file, not a file: scheme handler.
	if mime, err := targetType("file:///nonexistent/notes.txt", nil); mime != "" || err != nil {
		t.Errorf("a missing file:// = %q, %v; want nothing", mime, err)
	}
}

// A path that's there but can't be read is a failure to report, by its
// reason alone; one that isn't there names nothing. A link loop fails
// stat for every user, root included.
func TestStatFailure(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "s3cr3t")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	loop := filepath.Join(dir, "loop.txt")
	if err := os.Symlink(loop, loop); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{loop, "file://" + loop} {
		_, err := targetType(target, nil)
		if err == nil || !strings.Contains(err.Error(), "couldn't read the file: too many levels of symbolic links") || strings.Contains(err.Error(), "s3cr3t") {
			t.Errorf("targetType(%q) = %v; want the reason, with no path", target, err)
		}
	}
	if mime, err := targetType(filepath.Join(dir, "missing", "x"), nil); mime != "" || err != nil {
		t.Errorf("a missing path = %q, %v; want nothing", mime, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "plain"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if mime, err := targetType(filepath.Join(dir, "plain", "x"), nil); mime != "" || err != nil {
		t.Errorf("a path through a file = %q, %v; want nothing", mime, err)
	}
}

// A file: URL's path may hold a secret too, and xdg-mime's own message may
// quote it, so a failed file type lookup names neither.
func TestFileTypeErrorNamesNoPath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "s3cr3t")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	notes := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(notes, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// A real command that fails, printing the path, as xdg-mime might.
	real := xdgMime
	t.Cleanup(func() { xdgMime = real })
	xdgMime = func(_ []string, args ...string) (string, error) {
		cmd := exec.Command("sh", "-c", `echo "no such type: $1" >&2; exit 3`, "sh", args[len(args)-1])
		_, err := cmd.Output()
		if exitErr := (*exec.ExitError)(nil); errors.As(err, &exitErr) {
			return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return "", err
	}
	for _, target := range []string{notes, "file://" + notes} {
		_, err := openerClasses(target, nil)
		if err == nil || strings.Contains(err.Error(), "s3cr3t") || !strings.Contains(err.Error(), "exit status 3") {
			t.Errorf("openerClasses(%q) = %v; want an exit status and no path", target, err)
		}
	}
}

// A command run with settings of its own may open another app than this
// environment's default, so it names none; one with no settings, past a
// wrapper, still does.
func TestOpenerWithSettingsNamesNoApp(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.mozilla.firefox.desktop", "[Desktop Entry]\nExec=firefox %u\n")
	env := append(dataEnv("/nonexistent", sys), "PATH="+path, "XDG_CURRENT_DESKTOP=tide")
	calls := fakeXdgMime(t, nil, map[string]string{"x-scheme-handler/https": "org.mozilla.firefox.desktop"}, nil)
	for _, line := range []string{"XDG_CONFIG_HOME=/alt xdg-open https://example.com/", "env XDG_DATA_HOME=/alt gio open https://example.com/"} {
		*calls = nil
		if err := os.Truncate(log, 0); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if status := run([]string{"--pid", "4242", line}, env, io.Discard, io.Discard); status != 0 || len(*calls) != 0 || strings.Contains(readLog(t, log), "extend") {
			t.Errorf("%q = %d, calls %q, hyprctl %q; want only the opener's grant", line, status, *calls, readLog(t, log))
		}
	}
	var stdout bytes.Buffer
	if status := run([]string{"--opener", "--", "env", "XDG_DATA_HOME=/alt", "xdg-open", "https://example.com/"}, env, &stdout, io.Discard); status != 0 || stdout.Len() != 0 {
		t.Errorf("--opener with settings = %d, %q; want nothing", status, stdout.String())
	}
	stdout.Reset()
	if status := run([]string{"--opener", "--", "nice", "-n", "5", "xdg-open", "https://example.com/"}, env, &stdout, io.Discard); status != 0 || stdout.String() != "org.mozilla.firefox\nfirefox\n" {
		t.Errorf("--opener past nice = %d, %q", status, stdout.String())
	}
}

// A glob names no words: what it matches depends on the shell and its
// options. A quoted pattern is a word like any other.
func TestOpenerGlob(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "report.pdf"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{
		"xdg-open " + dir + "/*.pdf",
		"xdg-open " + dir + "/**/*.pdf",
		"xdg-open " + dir + "/report.pd?",
		"xdg-open " + dir + "/report.[p]df",
		"noglob xdg-open " + dir + "/*.pdf",
		"gio open " + dir + "/*.none",
	} {
		if words, ok := lineWords(line, nil); ok {
			t.Errorf("lineWords(%q) = %q; want no words", line, words)
		}
	}
	quoted := "xdg-open '" + dir + "/*.pdf'"
	if words, ok := lineWords(quoted, nil); !ok || !reflect.DeepEqual(words, []string{"xdg-open", dir + "/*.pdf"}) {
		t.Errorf("lineWords(%q) = %q, %v; want the word as it is", quoted, words, ok)
	}
	if words, ok := lineWords("xdg-open "+dir+"/report.pdf", nil); !ok || !reflect.DeepEqual(words, []string{"xdg-open", dir + "/report.pdf"}) {
		t.Errorf("a plain path = %q, %v", words, ok)
	}
}

// A word with a scheme is a URL to both openers, even where a path of the
// same spelling exists.
func TestURLBeforePath(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "https:", "example.com"), 0o755); err != nil {
		t.Fatal(err)
	}
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(old); err != nil {
			t.Errorf("going back to %s: %v", old, err)
		}
	})
	real := xdgMime
	t.Cleanup(func() { xdgMime = real })
	xdgMime = func(env []string, args ...string) (string, error) {
		t.Errorf("xdg-mime %q: a URL needs no file type", args)
		return "", nil
	}
	if mime, err := targetType("https://example.com", nil); err != nil || mime != "x-scheme-handler/https" {
		t.Errorf("targetType = %q, %v; want x-scheme-handler/https", mime, err)
	}
}

// An xdg-mime that can't start says why, naming no argument.
func TestXdgMimeNotStarted(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "secret-token.pdf")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// exec.Command looks the program up on this process's PATH.
	t.Setenv("PATH", dir)
	_, err := targetType(file, []string{"PATH=" + dir})
	if err == nil || !strings.Contains(err.Error(), "executable file not found") || strings.Contains(err.Error(), "secret-token") {
		t.Errorf("targetType with no xdg-mime = %v; want the reason, without the path", err)
	}
}

// A scheme with a digit is a URL to GIO and a path to xdg-open, so it
// names nothing.
func TestDigitScheme(t *testing.T) {
	real := xdgMime
	t.Cleanup(func() { xdgMime = real })
	xdgMime = func(env []string, args ...string) (string, error) {
		t.Errorf("xdg-mime %q: nothing to look up", args)
		return "", nil
	}
	for _, target := range []string{"web+demo2://item", "s3://bucket/key"} {
		if mime, err := targetType(target, nil); mime != "" || err != nil {
			t.Errorf("targetType(%q) = %q, %v; want nothing", target, mime, err)
		}
	}
	if mime, err := targetType("web+demo://item", nil); mime != "x-scheme-handler/web+demo" || err != nil {
		t.Errorf("targetType(web+demo://item) = %q, %v", mime, err)
	}
}
