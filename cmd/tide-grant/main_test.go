package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestProgram(t *testing.T) {
	env := []string{
		"PATH=/usr/bin:/bin",
		"BROWSER=firefox --new-window",
		"EDITOR=/usr/bin/code",
		"APP=/opt/My App/bin/editor",
		"DIR=/opt/tools",
		"CMD=env GTK_THEME=dark nohup nautilus",
		"EMPTY=",
	}
	tests := []struct {
		line, want string
	}{
		{"nautilus .", "nautilus"},
		{"/usr/bin/nautilus .", "nautilus"},
		{"./gui", "gui"},
		{"gui-not-on-path", "gui-not-on-path"},
		{"GDK_BACKEND=x11  FOO=1 gimp photo.png", "gimp"},
		{"GTK_THEME='Adwaita Dark' A=\"x y z\" B='' nautilus .", "nautilus"},
		{"command exec env -i GTK_THEME=dark nohup setsid nautilus .", "nautilus"},
		{`"/usr/bin/nautilus" .`, "nautilus"},
		{`\nautilus .`, "nautilus"},
		{`'nau'"ti"lus .`, "nautilus"},
		{`"/opt/My App/bin/editor" file`, "editor"},
		{"GTK_THEME=$(printf '%s' dark) nautilus .", "nautilus"}, // assignments aren't expanded
		{">/tmp/log nautilus .", "nautilus"},
		{"2>&1 nautilus .", "nautilus"},
		{"env -u DISPLAY nautilus .", "nautilus"},
		{"env --chdir /tmp nautilus .", "nautilus"},
		{"env --chdir=/tmp nautilus", "nautilus"},
		{"env -iC/opt/app ./gui", "gui"},
		{"env -vC /opt/app ./gui", "gui"},
		{"exec -a gui-name nautilus .", "nautilus"},
		{"exec -cla gui-name nautilus .", "nautilus"},
		{"exec -agui-name nautilus .", "nautilus"},
		{"nice -n 5 firefox", "firefox"},
		{"nice -n5 firefox", "firefox"},
		{"nice --adjustment 5 firefox", "firefox"},
		{"nice --adjustment=5 firefox", "firefox"},
		{"nice -5 firefox", "firefox"},
		{"nice pwd", "pwd"},
		{"! nautilus .", "nautilus"},
		{"time nautilus .", "nautilus"},
		{"env -- nautilus", "nautilus"},
		{"env -v nautilus .", "nautilus"},
		// Wrapper modes that run nothing, or run a string the helper
		// doesn't read, name nothing.
		{"command -v firefox", ""},
		{"command -p -V firefox", ""},
		{"env --version firefox", ""},
		{"nohup --help firefox", ""},
		{"env -S 'nautilus .'", ""},
		{"env --split-string='nautilus .'", ""},
		// Variables are expanded the way the shell would.
		{`"$EDITOR" file`, "code"},
		{"$BROWSER https://example.com/", "firefox"},
		{`"$BROWSER" https://example.com/`, ""}, // one word, which no window's class is
		{`"$APP" file`, "editor"},
		{`"${UNSET:-firefox}" URL`, "firefox"},
		{`"${EMPTY-firefox}" URL`, ""},
		{`${DIR}/bin/viewer file`, "viewer"},
		{"$CMD .", "nautilus"},
		{"$UNSET x", "x"},
		{`"$(echo firefox)" x`, ""},
		{"$(which firefox) --new-window", ""},
		{"ls $(firefox)", "ls"},
		// Only the first command is named; the pid covers the rest.
		{"nautilus . && firefox", "nautilus"},
		{"ls | gimp -", "ls"},
		{"firefox & nautilus .", "firefox"},
		{"cd /tmp && nautilus .", ""},
		{"if true; then gedit x; fi", ""},
		{"f() { nautilus .; }", ""},
		{"A=1 B=2", ""},
		// Builtins run in the shell, unless a wrapper runs a separate program.
		{"echo hi", ""},
		{"eval firefox", ""},
		{"command echo hi", ""},
		{"env echo hi", "echo"},
		{"nohup pwd", "pwd"},
		// fish's control prefixes, since fish lines are parsed as bash.
		{"not nautilus .", "nautilus"},
		// Another shell's syntax keeps what comes before the part bash
		// rejects; a block names nothing.
		{"nautilus (pwd)", "nautilus"},
		{"nautilus . && firefox 'unterminated", "nautilus"},
		{"if true; firefox; end", ""},
		{"if true { firefox }", ""},
		{"   ", ""},
		{"", ""},
	}
	for _, tt := range tests {
		if got := program(tt.line, env); got != tt.want {
			t.Errorf("program(%q) = %q, want %q", tt.line, got, tt.want)
		}
	}
}

func TestLuaString(t *testing.T) {
	for in, want := range map[string]string{
		"nautilus":      `"nautilus"`,
		`a"b\c`:         `"a\"b\\c"`,
		"tab\there\x7f": `"tab\009here\127"`,
	} {
		if got := luaString(in); got != want {
			t.Errorf("luaString(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestInTide(t *testing.T) {
	for desktops, want := range map[string]bool{
		"tide:Hyprland": true,
		"Hyprland:tide": true,
		"tide":          true,
		"KDE":           false,
		"tide2":         false,
		"":              false,
	} {
		if got := inTide(desktops); got != want {
			t.Errorf("inTide(%q) = %v, want %v", desktops, got, want)
		}
	}
}

// fakeHyprctl puts a hyprctl on PATH that logs its arguments and answers
// reply, and returns the log's path and the PATH to use.
func fakeHyprctl(t *testing.T, reply string) (string, string) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " + strconv.Quote(log) + "\necho " + strconv.Quote(reply) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "hyprctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "nautilus"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return log, dir + ":/bin:/usr/bin"
}

func readLog(t *testing.T, log string) string {
	data, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}

func TestRun(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path) // exec.Command finds hyprctl through the real PATH
	env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide:Hyprland"}
	var stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", "--", "nautilus ."}, env, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	if got, want := readLog(t, log), `eval tide_focus.grant("nautilus", 4242)`; got != want {
		t.Errorf("hyprctl got %q, want %q", got, want)
	}
	if status := run([]string{"--pid=7", "nautilus ."}, env, &stderr); status != 0 {
		t.Fatalf("run --pid=7 = %d", status)
	}
	if !strings.HasSuffix(readLog(t, log), `grant("nautilus", 7)`) {
		t.Errorf("--pid=7 wasn't used: %q", readLog(t, log))
	}
}

// A line that names no app still grants the shell's pid, for the windows
// of whatever it starts.
func TestRunGrantsThePidAlone(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	env := []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}
	var stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", "cd /tmp && nautilus ."}, env, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	if got, want := readLog(t, log), "eval tide_focus.grant(nil, 4242)"; got != want {
		t.Errorf("hyprctl got %q, want %q", got, want)
	}
}

func TestRunOutsideTide(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	var stderr bytes.Buffer
	status := run([]string{"nautilus ."}, []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=KDE"}, &stderr)
	if status != 0 || readLog(t, log) != "" {
		t.Errorf("run outside tide = %d, hyprctl log %q", status, readLog(t, log))
	}
}

func TestRunReportsARejectedGrant(t *testing.T) {
	_, path := fakeHyprctl(t, "error: attempt to index a nil value")
	t.Setenv("PATH", path)
	var stderr bytes.Buffer
	status := run([]string{"nautilus ."}, []string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}, &stderr)
	if status != 1 {
		t.Errorf("run = %d, want 1", status)
	}
	if want := "couldn't record a focus grant for nautilus .: error: attempt to index a nil value"; !strings.Contains(stderr.String(), want) {
		t.Errorf("stderr %q doesn't contain %q", stderr.String(), want)
	}
}

func TestRunReportsNoHyprctl(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "nautilus"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	var stderr bytes.Buffer
	status := run([]string{"nautilus"}, []string{"PATH=" + dir, "XDG_CURRENT_DESKTOP=tide"}, &stderr)
	if status != 1 || !strings.Contains(stderr.String(), "hyprctl") {
		t.Errorf("run without hyprctl = %d, stderr %q", status, stderr.String())
	}
}

func TestRunUsage(t *testing.T) {
	var stderr bytes.Buffer
	if status := run(nil, nil, &stderr); status != 2 || !strings.Contains(stderr.String(), "usage") {
		t.Errorf("run() = %d, stderr %q", status, stderr.String())
	}
}
