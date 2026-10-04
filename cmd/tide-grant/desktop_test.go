package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestExecProgram(t *testing.T) {
	for exec, want := range map[string]string{
		"/usr/bin/editor %F":                                      "editor",
		`"/opt/My App/my editor" %F`:                              "my editor",
		`"/opt/esc\"aped/my editor" --x`:                          "my editor",
		`env GDK_BACKEND=wayland "editor" --tool`:                 "editor",
		"env -u WAYLAND_DISPLAY --chdir /tmp -i -- LANG=C editor": "editor",
		"env -iu WAYLAND_DISPLAY editor":                          "editor", // a cluster whose last option takes a value
		"env -iCdir editor":                                       "editor",
		"nice -n 5 nohup editor":                                  "editor",
		"env -S 'editor --x'":                                     "", // the command is inside the string
		"sh -c 'editor'":                                          "sh",
		"/usr/bin/env editor":                                     "editor",
		"nice -- env editor":                                      "editor",
		"/usr/bin/nice -n 5 /usr/bin/editor":                      "editor",
		"":                                                        "",
	} {
		if got := execProgram(exec); got != want {
			t.Errorf("execProgram(%q) = %q, want %q", exec, got, want)
		}
	}
}

func TestUnescapeValue(t *testing.T) {
	for in, want := range map[string]string{
		`a\sb`:      "a b",
		`a\\b`:      `a\b`,
		`a\"b`:      `a\"b`, // left for Exec's own quoting
		`trailing\`: `trailing\`,
		`\t\n\r`:    "\t\n\r",
	} {
		if got := unescapeValue(in); got != want {
			t.Errorf("unescapeValue(%q) = %q, want %q", in, got, want)
		}
	}
}

// writeEntry writes a desktop entry under data/applications, as an
// application unless text gives a Type of its own.
func writeEntry(t *testing.T, data, rel, text string) {
	t.Helper()
	if !strings.Contains(text, "Type=") {
		text = strings.Replace(text, "[Desktop Entry]\n", "[Desktop Entry]\nType=Application\n", 1)
	}
	path := filepath.Join(data, "applications", rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func dataEnv(home, dirs string) []string {
	return []string{"XDG_DATA_HOME=" + home, "XDG_DATA_DIRS=" + dirs}
}

func TestDesktopClasses(t *testing.T) {
	home, sys := t.TempDir(), t.TempDir()
	writeEntry(t, sys, "org.example.Editor.desktop",
		"[Desktop Entry]\nName=Editor\nExec=/usr/bin/editor %F\nStartupWMClass=example-editor-x11\n\n[Desktop Action new]\nExec=other --new\n")
	writeEntry(t, sys, "vendor/tool.desktop", "[Desktop Entry]\nExec=\"editor\" %F\n")
	writeEntry(t, sys, "unrelated.desktop", "[Desktop Entry]\nExec=editor-helper\n")
	writeEntry(t, sys, "action-only.desktop", "[Desktop Entry]\nExec=other\n\n[Desktop Action a]\nExec=editor\n")
	writeEntry(t, sys, "same.desktop", "[Desktop Entry]\nExec=editor %F\nStartupWMClass=Editor\n")
	env := dataEnv(home, sys)

	got, err := desktopClasses("editor", nil, env)
	if err != nil {
		t.Fatalf("desktopClasses: %v", err)
	}
	// In the order the files sort, each class once: same.desktop's class
	// is the program's own name in another case, which its grant covers.
	want := []string{"org.example.Editor", "example-editor-x11", "same", "vendor-tool"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("desktopClasses = %q, want %q", got, want)
	}

	// The user's own entries override and hide the system's, by desktop ID.
	writeEntry(t, home, "org.example.Editor.desktop", "[Desktop Entry]\nExec=different\n")
	writeEntry(t, home, "vendor-tool.desktop", "[Desktop Entry]\nExec=editor\nHidden=true\n")
	if got, _ := desktopClasses("editor", nil, env); !reflect.DeepEqual(got, []string{"same"}) {
		want := []string{"same"}
		t.Errorf("with overrides, desktopClasses = %q, want %q", got, want)
	}

	writeEntry(t, sys, "org.example.Flat.desktop", "[Desktop Entry]\nExec=/usr/bin/flatpak run org.example.Flat\n")
	if got, _ := desktopClasses("flatpak", nil, env); len(got) != 0 {
		t.Errorf("a wrapper like flatpak got every entry it runs: %q", got)
	}
	if got, _ := desktopClasses("nothing", nil, env); len(got) != 0 {
		t.Errorf("a program with no entry got %q", got)
	}
	if got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", "/nonexistent")); len(got) != 0 || err != nil {
		t.Errorf("missing data directories got %q, %v; want nothing, and no error", got, err)
	}
}

// An entry that runs the program through a wrapper counts like any other.
func TestDesktopClassesThroughAWrapper(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "tool.desktop", "[Desktop Entry]\nExec=nice -n 5 env \"editor\" %F\n")
	if got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys)); err != nil || !reflect.DeepEqual(got, []string{"tool"}) {
		t.Errorf("desktopClasses = %q, %v; want [tool]", got, err)
	}
}

func TestRunClasses(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "org.example.Editor.desktop", "[Desktop Entry]\nExec=editor\nStartupWMClass=example-editor-x11\n")
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--classes", "editor"}, dataEnv("/nonexistent", sys), &stdout, &stderr); status != 0 {
		t.Fatalf("run --classes = %d, stderr %q", status, stderr.String())
	}
	if got, want := stdout.String(), "org.example.Editor\nexample-editor-x11\n"; got != want {
		t.Errorf("--classes printed %q, want %q", got, want)
	}
	// It takes a command as words: past wrappers to the program, whose own
	// arguments don't matter.
	writeEntry(t, sys, "org.example.Mode.desktop", "[Desktop Entry]\nExec=env MODE=a moded\n")
	for words, want := range map[string]string{
		"editor file.txt":                "org.example.Editor\nexample-editor-x11\n",
		"env LANG=C nice -n 5 editor":    "",
		"nice -n 5 editor --new-window":  "org.example.Editor\nexample-editor-x11\n",
		"env MODE=a moded":               "org.example.Mode\n",
		"env MODE=b moded":               "",
		"env PATH=/opt/vendor editor":    "",
		"env --help":                     "",
		"/usr/bin/env -- MODE=a moded x": "org.example.Mode\n",
	} {
		stdout.Reset()
		if status := run(append([]string{"--classes", "--"}, strings.Fields(words)...), dataEnv("/nonexistent", sys), &stdout, &stderr); status != 0 || stdout.String() != want {
			t.Errorf("--classes %s = %d, %q; want 0, %q", words, status, stdout.String(), want)
		}
	}
	for _, args := range [][]string{{"--classes"}, {"--program"}, {"--classes", "--program", "editor"}} {
		if status := run(args, dataEnv("/nonexistent", sys), io.Discard, io.Discard); status != 2 {
			t.Errorf("run %q = %d, want 2", args, status)
		}
	}
}

// --program prints the program a command runs, past wrappers, as written.
func TestRunProgram(t *testing.T) {
	for words, want := range map[string]string{
		"editor file.txt":                "editor\n",
		"env LANG=C /opt/x/editor --new": "/opt/x/editor\n",
		"nice -n 5 setsid -w editor":     "editor\n",
		"env --help":                     "",
		"flatpak run org.example.App":    "flatpak\n",
	} {
		var stdout bytes.Buffer
		if status := run(append([]string{"--program", "--"}, strings.Fields(words)...), nil, &stdout, io.Discard); status != 0 || stdout.String() != want {
			t.Errorf("--program %s = %d, %q; want 0, %q", words, status, stdout.String(), want)
		}
	}
}

// A terminal command's grant is widened with its desktop entries' classes,
// after the grant itself is recorded.
func TestRunExtendsTheGrant(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.gnome.Nautilus.desktop", "[Desktop Entry]\nExec=nautilus --new-window %U\n")
	env := append([]string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}, dataEnv("/nonexistent", sys)...)
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--pid", "4242", "nautilus ."}, env, &stdout, &stderr); status != 0 {
		t.Fatalf("run = %d, stderr %q", status, stderr.String())
	}
	want := `eval tide_focus.grant("nautilus", 4242, ` + key + `)` + "\n" +
		`eval tide_focus.extend("nautilus", { "org.gnome.Nautilus" }, 4242, ` + key + `)`
	if got := readLog(t, log); got != want {
		t.Errorf("hyprctl got %q, want %q", got, want)
	}
}

// A command run with an environment or directory of its own may run
// another program, so it's granted only its name.
func TestRunSkipsTheLookupForAnEnvironmentOfItsOwn(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.gnome.Nautilus.desktop", "[Desktop Entry]\nExec=nautilus\n")
	env := append([]string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}, dataEnv("/nonexistent", sys)...)
	for _, line := range []string{"PATH=/opt/vendor nautilus", "env PATH=/opt/vendor nautilus", "env --chdir /opt ./nautilus", "nice env -i nautilus"} {
		if err := os.WriteFile(log, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		var stdout, stderr bytes.Buffer
		if status := run([]string{"--pid", "4242", line}, env, &stdout, &stderr); status != 0 {
			t.Fatalf("run(%q) = %d, stderr %q", line, status, stderr.String())
		}
		if got := readLog(t, log); strings.Contains(got, "extend") || !strings.Contains(got, "tide_focus.grant(") {
			t.Errorf("run(%q): hyprctl got %q, want a grant and no extend", line, got)
		}
	}
}

// A command with settings of its own extends the grant only with the entry
// run with the same settings.
func TestRunMatchesTheCommandsSettings(t *testing.T) {
	log, path := fakeHyprctl(t, "ok")
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "writer.desktop", "[Desktop Entry]\nExec=env APP_MODE=writer nautilus\n")
	env := append([]string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}, dataEnv("/nonexistent", sys)...)
	for line, extends := range map[string]bool{
		"APP_MODE=writer nautilus":     true,
		"env APP_MODE=writer nautilus": true,
		"nautilus":                     true,
		"env APP_MODE=calc nautilus":   false,
		"APP_MODE=calc nautilus":       false,
	} {
		if err := os.WriteFile(log, nil, 0o644); err != nil {
			t.Fatal(err)
		}
		var stdout, stderr bytes.Buffer
		if status := run([]string{"--pid", "4242", line}, env, &stdout, &stderr); status != 0 {
			t.Fatalf("run(%q) = %d, stderr %q", line, status, stderr.String())
		}
		if got := readLog(t, log); strings.Contains(got, `extend("nautilus", { "writer" }`) != extends {
			t.Errorf("run(%q): hyprctl got %q; want an extend: %v", line, got, extends)
		}
	}
}

func TestRunReportsAFailedExtend(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	// ok to the grant, an error to the extend.
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + log + "'\ncase \"$*\" in *extend*) echo 'error: no extend' ;; *) echo ok ;; esac\n"
	if err := os.WriteFile(filepath.Join(dir, "hyprctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	path := dir + ":/bin:/usr/bin"
	t.Setenv("PATH", path)
	sys := t.TempDir()
	writeEntry(t, sys, "org.gnome.Nautilus.desktop", "[Desktop Entry]\nExec=nautilus\n")
	env := append([]string{"PATH=" + path, "XDG_CURRENT_DESKTOP=tide"}, dataEnv("/nonexistent", sys)...)
	var stdout, stderr bytes.Buffer
	if status := run([]string{"nautilus"}, env, &stdout, &stderr); status != 1 {
		t.Errorf("run = %d, want 1", status)
	}
	if want := "couldn't add org.gnome.Nautilus to the focus grant for nautilus: error: no extend"; !strings.Contains(stderr.String(), want) {
		t.Errorf("stderr %q doesn't contain %q", stderr.String(), want)
	}
}

// An entry that can't be read is an error, and no classes are given: it may
// have been one that made the others ambiguous. A dangling link fails to
// open even for root.
func TestDesktopClassesReportsAnUnreadableEntry(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "a.desktop", "[Desktop Entry]\nExec=editor\n")
	if err := os.Symlink(filepath.Join(sys, "gone"), filepath.Join(sys, "applications", "b.desktop")); err != nil {
		t.Fatal(err)
	}
	got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys))
	if len(got) != 0 || err == nil || !strings.Contains(err.Error(), "b.desktop") {
		t.Errorf("desktopClasses = %q, %v; want nothing and an error naming b.desktop", got, err)
	}
	var stdout, stderr bytes.Buffer
	if status := run([]string{"--classes", "editor"}, dataEnv("/nonexistent", sys), &stdout, &stderr); status != 1 || stdout.String() != "" {
		t.Errorf("run --classes = %d, stdout %q; want 1 and nothing printed", status, stdout.String())
	}
	if !strings.Contains(stderr.String(), "couldn't read every desktop entry") {
		t.Errorf("stderr %q doesn't say what failed", stderr.String())
	}
}

// Entries that run one program with different arguments are different
// apps, and none of them counts; nor does the program's plain entry.
func TestDesktopClassesWithDifferentArguments(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "libreoffice-startcenter.desktop", "[Desktop Entry]\nExec=libreoffice %U\nStartupWMClass=libreoffice-startcenter\n")
	writeEntry(t, sys, "libreoffice-writer.desktop", "[Desktop Entry]\nExec=libreoffice --writer %U\nStartupWMClass=libreoffice-writer\n")
	writeEntry(t, sys, "viewer.desktop", "[Desktop Entry]\nExec=viewer --open=%u\nStartupWMClass=viewer-x11\n")
	writeEntry(t, sys, "viewer-full.desktop", "[Desktop Entry]\nExec=viewer --open=%u\n")
	env := dataEnv("/nonexistent", sys)
	if got, err := desktopClasses("libreoffice", nil, env); len(got) != 0 || err != nil {
		t.Errorf("desktopClasses(libreoffice) = %q, %v; want nothing", got, err)
	}
	// So are entries that set the program up differently before running it.
	writeEntry(t, sys, "suite-writer.desktop", "[Desktop Entry]\nExec=env APP_MODE=writer suite\n")
	writeEntry(t, sys, "suite-calc.desktop", "[Desktop Entry]\nExec=env APP_MODE=calc suite\n")
	if got, err := desktopClasses("suite", nil, env); len(got) != 0 || err != nil {
		t.Errorf("desktopClasses(suite) = %q, %v; want nothing", got, err)
	}
	// Entries passing their own file (%k) may each mean something else.
	writeEntry(t, sys, "kit-a.desktop", "[Desktop Entry]\nExec=kit %k\n")
	writeEntry(t, sys, "kit-b.desktop", "[Desktop Entry]\nExec=kit %k\n")
	if got, err := desktopClasses("kit", nil, env); len(got) != 0 || err != nil {
		t.Errorf("desktopClasses(kit) = %q, %v; want nothing", got, err)
	}
	writeEntry(t, sys, "wrap-a.desktop", "[Desktop Entry]\nExec=wrap --entry=%k\n")
	writeEntry(t, sys, "wrap-b.desktop", "[Desktop Entry]\nExec=wrap --entry=%k\n")
	if got, err := desktopClasses("wrap", nil, env); len(got) != 0 || err != nil {
		t.Errorf("desktopClasses(wrap) = %q, %v; want nothing", got, err)
	}
	writeEntry(t, sys, "icon-a.desktop", "[Desktop Entry]\nExec=iconic %i\nIcon=a\n")
	writeEntry(t, sys, "icon-b.desktop", "[Desktop Entry]\nExec=iconic %i\nIcon=b\n")
	if got, err := desktopClasses("iconic", nil, env); len(got) != 0 || err != nil {
		t.Errorf("desktopClasses(iconic) = %q, %v; want nothing", got, err)
	}
	// One such entry alone still counts.
	writeEntry(t, sys, "solo.desktop", "[Desktop Entry]\nExec=solo %k\nStartupWMClass=solo-x11\n")
	if got, err := desktopClasses("solo", nil, env); err != nil || !reflect.DeepEqual(got, []string{"solo-x11"}) {
		t.Errorf("desktopClasses(solo) = %q, %v; want [solo-x11]", got, err)
	}
	// Entries naming one wrapper by path and by name agree.
	writeEntry(t, sys, "pad.desktop", "[Desktop Entry]\nExec=nice -n 5 pad\n")
	writeEntry(t, sys, "pad-alias.desktop", "[Desktop Entry]\nExec=/usr/bin/nice -n 5 pad\n")
	if got, err := desktopClasses("pad", nil, env); err != nil || !reflect.DeepEqual(got, []string{"pad-alias"}) {
		t.Errorf("desktopClasses(pad) = %q, %v; want [pad-alias]", got, err)
	}
	// An option's value isn't a wrapper, even one that looks like a
	// wrapper's path: these run in different directories.
	writeEntry(t, sys, "dir.desktop", "[Desktop Entry]\nExec=env --chdir /usr/bin/nice dirapp\n")
	writeEntry(t, sys, "dir-other.desktop", "[Desktop Entry]\nExec=env --chdir /opt/nice dirapp\n")
	if got, err := desktopClasses("dirapp", nil, env); err != nil || len(got) != 0 {
		t.Errorf("desktopClasses(dirapp) = %q, %v; want nothing", got, err)
	}
	// A program named by path in one entry and by name in another agrees.
	writeEntry(t, sys, "tool.desktop", "[Desktop Entry]\nExec=/usr/bin/tool --x\n")
	writeEntry(t, sys, "tool-alias.desktop", "[Desktop Entry]\nExec=tool --x\n")
	if got, err := desktopClasses("tool", nil, env); err != nil || !reflect.DeepEqual(got, []string{"tool-alias"}) {
		t.Errorf("desktopClasses(tool) = %q, %v; want [tool-alias]", got, err)
	}
	// Entries that agree count, field codes and all.
	if got, err := desktopClasses("viewer", nil, env); err != nil || !reflect.DeepEqual(got, []string{"viewer-full", "viewer-x11"}) {
		t.Errorf("desktopClasses(viewer) = %q, %v", got, err)
	}
}

func TestProgramPath(t *testing.T) {
	// The settings a command runs its program with: shell assignments,
	// then env's, as written; moves when one changes PATH or directory.
	for line, want := range map[string]struct {
		settings []string
		moves    bool
	}{
		"A=1 env -u B C=$X editor": {[]string{"A=1", "-u", "B", "C=x"}, false},
		"nice env -- A=1 editor":   {[]string{"A=1"}, false},
		"editor --x":               {nil, false},
		"PATH=/opt editor":         {[]string{"PATH=/opt"}, true},
		"env -C /opt editor":       {[]string{"-C", "/opt"}, true},
		"A+=1 editor":              {nil, true},
	} {
		_, settings, moves := programPathEnv(line, []string{"X=x"})
		if !reflect.DeepEqual(settings, want.settings) || moves != want.moves {
			t.Errorf("programPathEnv(%q) = %q, %v; want %q, %v", line, settings, moves, want.settings, want.moves)
		}
	}
	if got := programPath(`FOO=1 env -i "$DIR/gui" --writer`, []string{"DIR=/opt/My App"}); got != "/opt/My App/gui" {
		t.Errorf("programPath = %q", got)
	}
	if got := programPath("./gui x", nil); got != "./gui" {
		t.Errorf("programPath(./gui x) = %q; a path stays as written, for the lookup", got)
	}
	if got := programPath("libreoffice $(choose-mode)", nil); got != "libreoffice" {
		t.Errorf("programPath with an unexpandable argument = %q", got)
	}
}

// A program run by path matches the entries that run that file, whether
// they name it by path or by a name found on PATH, and not an entry for
// another program with the same name.
func TestDesktopClassesByPath(t *testing.T) {
	bin, vendor, sys := t.TempDir(), t.TempDir(), t.TempDir()
	for _, dir := range []string{bin, vendor} {
		if err := os.WriteFile(filepath.Join(dir, "editor"), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeEntry(t, sys, "system.desktop", "[Desktop Entry]\nExec="+filepath.Join(bin, "editor")+"\n")
	writeEntry(t, sys, "bare.desktop", "[Desktop Entry]\nExec=editor\nStartupWMClass=bare-x11\n")
	writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec="+filepath.Join(vendor, "editor")+"\n")
	env := append([]string{"PATH=" + bin}, dataEnv("/nonexistent", sys)...)
	for program, want := range map[string][]string{
		filepath.Join(vendor, "editor"): {"vendor"},
		filepath.Join(bin, "editor"):    {"bare", "bare-x11", "system"},
		"editor":                        {"bare", "bare-x11", "system"}, // PATH finds bin's
	} {
		got, err := desktopClasses(program, nil, env)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("desktopClasses(%q) = %q, %v; want %q", program, got, err, want)
		}
	}
	// A name PATH doesn't find is matched by basename.
	if got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys)); err != nil || !reflect.DeepEqual(got, []string{"bare", "bare-x11", "system", "vendor"}) {
		t.Errorf("desktopClasses(editor) off PATH = %q, %v", got, err)
	}

	// A link with a name of its own runs its target, so an entry naming
	// the target matches a launch through the link.
	real := filepath.Join(vendor, "edit-real")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, filepath.Join(bin, "edit")); err != nil {
		t.Fatal(err)
	}
	writeEntry(t, sys, "real.desktop", "[Desktop Entry]\nExec="+real+"\nStartupWMClass=real-x11\n")
	if got, err := desktopClasses("edit", nil, env); err != nil || !reflect.DeepEqual(got, []string{"real", "real-x11"}) {
		t.Errorf("desktopClasses(edit) through a link = %q, %v; want [real real-x11]", got, err)
	}
}

// An entry whose env changes PATH, clears the environment or changes
// directory may run another program, so it isn't matched. Other settings
// count, matched against the command's own, and other wrappers don't stop
// a match.
func TestDesktopClassesWrapperPath(t *testing.T) {
	bin, sys := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "editor"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	env := append([]string{"PATH=" + bin}, dataEnv("/nonexistent", sys)...)
	for _, exec := range []string{
		"env PATH=/opt/vendor editor",
		"env -i editor",
		"env -iuPATH editor",
		"env -u PATH editor",
		"env --unset=PATH editor",
		"env - editor",
		"/usr/bin/env --ignore-environment editor",
	} {
		writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec="+exec+"\nStartupWMClass=vendor-x11\n")
		if got, err := desktopClasses("editor", nil, env); err != nil || len(got) != 0 {
			t.Errorf("Exec=%s: desktopClasses(editor) = %q, %v; want nothing", exec, got, err)
		}
	}
	// A program run in another directory may be another app, as with Path.
	for _, exec := range []string{
		"env --chdir /opt/profile editor",
		"env --chdir=/opt/profile editor",
		"env -C /opt/profile " + filepath.Join(bin, "editor"),
		"env -iC/opt/profile editor",
	} {
		writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec="+exec+"\nStartupWMClass=vendor-x11\n")
		if got, err := desktopClasses("editor", nil, env); err != nil || len(got) != 0 {
			t.Errorf("Exec=%s: desktopClasses(editor) = %q, %v; want nothing", exec, got, err)
		}
	}
	// A class holding a line break would read as two on output, so it
	// isn't given; the entry's ID still is.
	writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec=editor\nStartupWMClass=first\\nsecond\n")
	if got, err := desktopClasses("editor", nil, env); err != nil || !reflect.DeepEqual(got, []string{"vendor"}) {
		t.Errorf("a class with a line break: desktopClasses(editor) = %q, %v; want [vendor]", got, err)
	}
	// A PATH of the entry's own stops a match even running a path.
	writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec=env PATH=/opt/vendor "+filepath.Join(bin, "editor")+"\nStartupWMClass=vendor-x11\n")
	if got, err := desktopClasses("editor", nil, env); err != nil || len(got) != 0 {
		t.Errorf("Exec=env PATH=… path: desktopClasses(editor) = %q, %v; want nothing", got, err)
	}
	// Other settings count: a command with none matches the entry, and one
	// with settings of its own matches only an entry with the same.
	for _, exec := range []string{"env APP_MODE=x editor", "env -u WAYLAND_DISPLAY editor"} {
		writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec="+exec+"\nStartupWMClass=vendor-x11\n")
		if got, err := desktopClasses("editor", nil, env); err != nil || !reflect.DeepEqual(got, []string{"vendor", "vendor-x11"}) {
			t.Errorf("Exec=%s: desktopClasses(editor) = %q, %v; want [vendor vendor-x11]", exec, got, err)
		}
	}
	writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec=env APP_MODE=writer editor\nStartupWMClass=writer-x11\n")
	if got, err := desktopClasses("editor", []string{"APP_MODE=writer"}, env); err != nil || !reflect.DeepEqual(got, []string{"vendor", "writer-x11"}) {
		t.Errorf("settings that match: desktopClasses(editor) = %q, %v; want [vendor writer-x11]", got, err)
	}
	for _, settings := range [][]string{{"APP_MODE=calc"}, {"APP_MODE=writer", "LANG=C"}} {
		if got, err := desktopClasses("editor", settings, env); err != nil || len(got) != 0 {
			t.Errorf("settings %q: desktopClasses(editor) = %q, %v; want nothing", settings, got, err)
		}
	}
	// A command with settings doesn't match a plain entry either.
	writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec=editor\nStartupWMClass=vendor-x11\n")
	if got, err := desktopClasses("editor", []string{"APP_MODE=calc"}, env); err != nil || len(got) != 0 {
		t.Errorf("settings against a plain entry: desktopClasses(editor) = %q, %v; want nothing", got, err)
	}
	// A wrapper that gives env nothing to do, or isn't env, changes nothing.
	for _, exec := range []string{"env editor", "env -- editor", "nice -n 5 editor"} {
		writeEntry(t, sys, "vendor.desktop", "[Desktop Entry]\nExec="+exec+"\nStartupWMClass=vendor-x11\n")
		if got, err := desktopClasses("editor", nil, env); err != nil || !reflect.DeepEqual(got, []string{"vendor", "vendor-x11"}) {
			t.Errorf("Exec=%s: desktopClasses(editor) = %q, %v; want [vendor vendor-x11]", exec, got, err)
		}
	}
}

// An entry run in another directory (Path) may be another app; two links
// to one directory each name their own desktop IDs; %F, %U and %i inside a
// word make an entry invalid.
func TestDesktopClassesPathAliasesAndCodes(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "here.desktop", "[Desktop Entry]\nExec=tool\nPath=/tmp/a\nStartupWMClass=here-x11\n")
	env := dataEnv("/nonexistent", sys)
	if got, err := desktopClasses("tool", nil, env); len(got) != 0 || err != nil {
		t.Errorf("an entry with a Path of its own = %q, %v; want nothing", got, err)
	}
	// A terminal entry runs the program in a terminal, so it neither
	// counts nor makes a GUI entry for the same program ambiguous.
	writeEntry(t, sys, "acme.desktop", "[Desktop Entry]\nExec=acme\nStartupWMClass=AcmeEditor\n")
	writeEntry(t, sys, "acme-diag.desktop", "[Desktop Entry]\nExec=acme --diagnostics\nTerminal=true\nStartupWMClass=acme-diag-x11\n")
	if got, err := desktopClasses("acme", nil, env); err != nil || !reflect.DeepEqual(got, []string{"AcmeEditor"}) {
		t.Errorf("a GUI entry beside a terminal one = %q, %v; want [AcmeEditor]", got, err)
	}
	// Only an application counts.
	writeEntry(t, sys, "link.desktop", "[Desktop Entry]\nType=Link\nExec=other\nStartupWMClass=link-x11\n")
	writeEntry(t, sys, "untyped.desktop", "[Desktop Entry]\nType=\nExec=other\n")
	if got, err := desktopClasses("other", nil, env); len(got) != 0 || err != nil {
		t.Errorf("non-application entries = %q, %v; want nothing", got, err)
	}
	vendor := t.TempDir()
	if err := os.WriteFile(filepath.Join(vendor, "app.desktop"), []byte("[Desktop Entry]\nType=Application\nExec=linked\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"one", "two"} {
		if err := os.Symlink(vendor, filepath.Join(sys, "applications", name)); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := desktopClasses("linked", nil, env); err != nil || !reflect.DeepEqual(got, []string{"one-app", "two-app"}) {
		t.Errorf("two links to one directory = %q, %v; want [one-app two-app]", got, err)
	}
	for _, exec := range []string{"editor --files=%F", "editor --url=%U", "editor --icon=%i"} {
		if _, _, ok := execCommand(exec); ok {
			t.Errorf("execCommand(%q) is valid", exec)
		}
	}
	// %% inside quotes is a literal percent sign.
	if _, args, ok := execCommand(`editor "100%%"`); !ok || !reflect.DeepEqual(args, []string{"100%"}) {
		t.Errorf(`execCommand(editor "100%%%%") = %q, %v; want [100%%], true`, args, ok)
	}
	// A quote left open, or a field code inside quotes, makes the entry
	// invalid.
	for _, exec := range []string{`editor "unterminated`, `"editor`, `editor "a\"`, `editor "%f"`, `editor "--open=%u"`, `editor "100%"`, `editor "a\q"`} {
		if _, _, ok := execCommand(exec); ok {
			t.Errorf("execCommand(%q) is valid", exec)
		}
	}
	if _, _, ok := execCommand("editor --open=%u %i"); !ok {
		t.Errorf("an embedded %%u and a standalone %%i are invalid")
	}
}

// %% in Exec is a literal percent sign, not a field code.
func TestExecCommandLiteralPercent(t *testing.T) {
	name, args, _ := execCommand("viewer --profile=100%% %U")
	if name != "viewer" || !reflect.DeepEqual(args, []string{"--profile=100%", "\x00U"}) {
		t.Errorf("execCommand = %q, %q", name, args)
	}
	name, args, _ = execCommand("/opt/100%%/viewer %%U %F")
	if name != "/opt/100%/viewer" || !reflect.DeepEqual(args, []string{"%U", "\x00F"}) {
		t.Errorf("execCommand with %%%% in the path = %q, %q; want /opt/100%%/viewer, [%%U, code F]", name, args)
	}
	// A deprecated code is removed, so these are the same command.
	_, a, _ := execCommand("viewer %f %m")
	_, b, _ := execCommand("viewer %f")
	if !reflect.DeepEqual(a, b) {
		t.Errorf("a deprecated %%m changed the command: %q, %q", a, b)
	}
	// A field code stays in the comparison, so these are different commands.
	_, plain, _ := execCommand("viewer")
	_, files, _ := execCommand("viewer %f")
	if reflect.DeepEqual(plain, files) {
		t.Errorf("viewer and viewer %%f compare equal")
	}
}

// An applications directory that is a link to nothing is reported; one that
// isn't there at all is not.
func TestDesktopClassesReportsADanglingRoot(t *testing.T) {
	sys := t.TempDir()
	if err := os.Symlink(filepath.Join(sys, "gone"), filepath.Join(sys, "applications")); err != nil {
		t.Fatal(err)
	}
	if _, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys)); err == nil || !strings.Contains(err.Error(), "applications") {
		t.Errorf("a dangling applications link gave %v; want an error naming it", err)
	}
	if _, err := desktopClasses("editor", nil, dataEnv("/nonexistent", t.TempDir())); err != nil {
		t.Errorf("a data directory with no applications directory gave %v", err)
	}
}

// A .desktop name that isn't a regular file, such as a FIFO, which would
// block a read until something wrote to it, is reported and never opened.
func TestDesktopClassesSkipsAFIFO(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "a.desktop", "[Desktop Entry]\nExec=editor\n")
	if err := syscall.Mkfifo(filepath.Join(sys, "applications", "b.desktop"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys))
	if len(got) != 0 || err == nil || !strings.Contains(err.Error(), "b.desktop: not a regular file") {
		t.Errorf("desktopClasses = %q, %v; want nothing and an error naming b.desktop", got, err)
	}
}

func TestFieldCodes(t *testing.T) {
	for _, tc := range []struct {
		in, text, codes string
		valid           bool
	}{
		{"plain", "plain", "", true},
		{"100%%", "100%", "", true},
		{"%%i", "%i", "", true}, // a literal, not the icon code
		{"--entry=%k", "--entry=\x00k", "k", true},
		{"%U", "\x00U", "U", true},
		{"%x", "", "", false},
		{"%d", "", "", true}, // deprecated: removed
		{"--dir=%D/x", "--dir=/x", "", true},
		{"trailing%", "", "", false},
	} {
		text, codes, valid := fieldCodes(tc.in)
		if text != tc.text || codes != tc.codes || valid != tc.valid {
			t.Errorf("fieldCodes(%q) = %q, %q, %v; want %q, %q, %v", tc.in, text, codes, valid, tc.text, tc.codes, tc.valid)
		}
	}
}

// A literal "%%i" is text, so identical entries with it still agree; an
// entry with an unknown code is invalid and names nothing.
func TestDesktopClassesLiteralAndInvalidCodes(t *testing.T) {
	sys := t.TempDir()
	writeEntry(t, sys, "a.desktop", "[Desktop Entry]\nExec=editor %%i\n")
	writeEntry(t, sys, "b.desktop", "[Desktop Entry]\nExec=editor %%i\n")
	writeEntry(t, sys, "bad.desktop", "[Desktop Entry]\nExec=editor %x\nStartupWMClass=bad-x11\n")
	got, err := desktopClasses("editor", nil, dataEnv("/nonexistent", sys))
	if err != nil || !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Errorf("desktopClasses = %q, %v; want [a b]", got, err)
	}
	if _, _, ok := execCommand("%k --x"); ok {
		t.Errorf("a field code as the program is valid")
	}
}

// --entry prints the classes one desktop entry names, for the app an
// opener hands a URL to.
func TestEntryClasses(t *testing.T) {
	home, sys := t.TempDir(), t.TempDir()
	writeEntry(t, sys, "org.mozilla.firefox.desktop", "[Desktop Entry]\nExec=/usr/lib/firefox/firefox %u\nStartupWMClass=firefox\n")
	writeEntry(t, sys, "vendor/viewer.desktop", "[Desktop Entry]\nExec=env GDK_BACKEND=x11 image-viewer %f\nStartupWMClass=Viewer\n")
	writeEntry(t, sys, "org.example.Flat.desktop", "[Desktop Entry]\nExec=flatpak run org.example.Flat %U\n")
	writeEntry(t, sys, "htop.desktop", "[Desktop Entry]\nExec=htop\nTerminal=true\n")
	writeEntry(t, sys, "link.desktop", "[Desktop Entry]\nType=Link\nURL=https://example.com\n")
	writeEntry(t, sys, "bad.desktop", "[Desktop Entry]\nExec=\"unclosed\n")
	writeEntry(t, sys, "gone.desktop", "[Desktop Entry]\nExec=gone\n")
	writeEntry(t, home, "gone.desktop", "[Desktop Entry]\nExec=gone\nHidden=true\n")
	env := dataEnv(home, sys)
	for id, want := range map[string][]string{
		"org.mozilla.firefox":         {"org.mozilla.firefox", "firefox"},
		"org.mozilla.firefox.desktop": {"org.mozilla.firefox", "firefox"},
		"vendor-viewer":               {"vendor-viewer", "Viewer", "image-viewer"},
		"org.example.Flat":            {"org.example.Flat"},
	} {
		got, err := entryClasses(id, env)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("entryClasses(%q) = %q, %v; want %q", id, got, err, want)
		}
	}
	// One that names no class says why, so the caller's fallback is
	// reported: a stale default in mimeapps.list is the common case.
	for id, why := range map[string]string{
		"htop":    "terminal",
		"link":    "not an application",
		"bad":     "Exec is invalid",
		"gone":    "hidden",
		"missing": "no such desktop entry",
	} {
		got, err := entryClasses(id, env)
		if len(got) != 0 || err == nil || !strings.Contains(err.Error(), why) {
			t.Errorf("entryClasses(%q) = %q, %v; want nothing and an error saying %q", id, got, err, why)
		}
	}
	for _, id := range []string{"", "a/b", ".desktop"} {
		if _, err := entryClasses(id, env); err == nil {
			t.Errorf("entryClasses(%q) took a bad ID", id)
		}
	}

	var stdout, stderr bytes.Buffer
	if status := run([]string{"--entry", "org.mozilla.firefox"}, env, &stdout, &stderr); status != 0 || stdout.String() != "org.mozilla.firefox\nfirefox\n" {
		t.Errorf("run --entry = %d, %q, stderr %q", status, stdout.String(), stderr.String())
	}
	for _, args := range [][]string{{"--entry", "x", "y"}, {"--entry", "x", "--classes"}} {
		if status := run(args, env, io.Discard, io.Discard); status != 2 {
			t.Errorf("run %q = %d, want 2", args, status)
		}
	}
	if err := os.Symlink(filepath.Join(sys, "nothing"), filepath.Join(sys, "applications", "dangling.desktop")); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
	if status := run([]string{"--entry", "dangling"}, env, io.Discard, &stderr); status != 1 || !strings.Contains(stderr.String(), "desktop entry dangling names no window class") {
		t.Errorf("an unreadable entry = %d, stderr %q", status, stderr.String())
	}
	// What can't be read after the entry is found doesn't count; before
	// it, it may have been the entry.
	later := t.TempDir()
	writeEntry(t, later, "a.desktop", "[Desktop Entry]\nExec=a-app\n")
	if err := os.Symlink(filepath.Join(later, "nothing"), filepath.Join(later, "applications", "zz-dir")); err != nil {
		t.Fatal(err)
	}
	if got, err := entryClasses("a", dataEnv("/nonexistent", later)); err != nil || !reflect.DeepEqual(got, []string{"a", "a-app"}) {
		t.Errorf("an unreadable path after the entry: %q, %v; want [a a-app]", got, err)
	}
	earlier := t.TempDir()
	writeEntry(t, earlier, "a.desktop", "[Desktop Entry]\nExec=a-app\n")
	if err := os.Symlink(filepath.Join(earlier, "nothing"), filepath.Join(earlier, "applications", "0-dir")); err != nil {
		t.Fatal(err)
	}
	if got, err := entryClasses("a", dataEnv("/nonexistent", earlier)); err == nil || len(got) != 0 {
		t.Errorf("an unreadable path before the entry: %q, %v; want an error", got, err)
	}
	stderr.Reset()
	if status := run([]string{"--entry", "missing.desktop"}, env, io.Discard, &stderr); status != 1 || !strings.Contains(stderr.String(), "missing.desktop names no window class: no such desktop entry") {
		t.Errorf("a stale default = %d, stderr %q", status, stderr.String())
	}
}
