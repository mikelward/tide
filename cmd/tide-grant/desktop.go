package main

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// desktopClasses returns the window classes the desktop entries running
// program say its window may have (SPEC.md §14.3): the desktop ID and
// StartupWMClass of each entry whose Exec runs program, compared by
// basename, in XDG order and without repeats. program itself is left out,
// since the caller grants it already.
//
// Exec is read as the Desktop Entry spec quotes it, then past wrappers the
// same way a terminal line is (fieldsProgram), so `env -iu VAR editor`
// and `nice -n 5 editor` both run editor. Only the [Desktop Entry] group
// counts, not desktop actions. An entry hidden (Hidden=true) or overridden
// by one with the same desktop ID in an earlier directory is skipped, as
// the desktop does. A data directory with no applications directory is
// normal; anything else that can't be read is returned as an error, with
// no classes: the entry it couldn't read may have been one that made the
// others ambiguous.
//
// program is a path (/opt/vendor/editor, ./gui) or a name, which is found on
// PATH, and only entries that run that same file match; an entry's bare
// Exec name is found on PATH too. A name PATH doesn't find is matched by
// basename.
//
// Entries that run one program with different arguments (`libreoffice
// --writer`, `libreoffice --calc`) are different apps, and which one a
// command means can't be told reliably from its own arguments, so none of
// them counts. Where a program's entries all agree, as for nautilus's one
// `nautilus --new-window %U`, they count whatever the command's arguments.
//
// settings are those the command runs the program with (programPathEnv);
// when it has any, only entries run with the same settings match.
func desktopClasses(program string, settings []string, env []string) ([]string, error) {
	name := filepath.Base(program)
	if opaque[name] {
		return nil, nil
	}
	// The file the command runs: a path as given, a bare name as PATH finds
	// it. Entries are matched to that file; only a name PATH doesn't find
	// is matched by basename alone.
	resolved := program
	if !strings.Contains(program, "/") {
		resolved = lookPath(program, env)
	}
	// An entry is first picked out by its program's basename, which spares
	// a lookup per entry. A link's target counts too (`editor` linked to
	// editor-real), so an entry naming the target is still compared.
	names := map[string]bool{name: true}
	if resolved != "" {
		if real, err := filepath.EvalSymlinks(resolved); err == nil {
			names[filepath.Base(real)] = true
		}
	}
	var out []string
	var errs []error
	seen := map[string]bool{strings.ToLower(name): true}
	decided := map[string]bool{}
	var found []entryMatch
	for _, data := range dataDirs(env) {
		root := filepath.Join(data, "applications")
		walkEntries(root, func(rel, path string) {
			id := strings.ReplaceAll(strings.TrimSuffix(rel, ".desktop"), string(filepath.Separator), "-")
			if decided[id] {
				return
			}
			decided[id] = true
			e, err := readEntry(path)
			if err != nil {
				errs = append(errs, err)
				return
			}
			// Only an application runs a program (Type=Link, a missing
			// Type, or a hidden entry names no window). Nor does an entry
			// that runs in a directory of its own (Path): a command run
			// elsewhere isn't that entry, and a relative Exec there can't
			// be matched. A terminal entry's window is the terminal's, so
			// it says nothing of the program's own window.
			if e.hidden || e.kind != "Application" || e.dir != "" || e.terminal {
				return
			}
			runs, entryArgs, entrySettings, moves, valid := execCommandEnv(e.exec)
			if !valid {
				// The desktop doesn't launch an entry the spec calls
				// invalid, so it names no window of this program. It's
				// not reported: it would warn on every command, over a
				// file that isn't tide's to fix.
				return
			}
			// An entry whose env changes PATH, clears the environment or
			// changes directory (`env PATH=…`, `env -i`, `env --chdir`)
			// may run another program than the command, which this
			// lookup can't follow; so, like Path, it isn't matched.
			if moves {
				return
			}
			// A command run with settings of its own (`env APP_MODE=calc
			// suite`) is the entry with those settings, and no other.
			if len(settings) > 0 && !slices.Equal(settings, entrySettings) {
				return
			}
			if !names[filepath.Base(runs)] || resolved != "" && !sameProgram(resolved, runs, env) {
				return
			}
			found = append(found, entryMatch{id, e.class, entryArgs})
		}, func(err error) { errs = append(errs, err) })
	}
	// An entry that couldn't be read may have run the program differently
	// from those that could, which would make them ambiguous; so a partial
	// scan grants nothing.
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	// Entries that differ in their arguments, or in what runs the program
	// (`env APP_MODE=writer suite`), are different apps, and so may be
	// entries passing their own icon, name or file (%i, %c, %k).
	for _, f := range found {
		if !slices.Equal(f.args, found[0].args) || len(found) > 1 && slices.ContainsFunc(f.args, perEntry) {
			return nil, nil
		}
	}
	for _, f := range found {
		for _, c := range []string{f.id, f.class} {
			// One class a line on output: a value holding a line break
			// (an escaped \n) would read as two, so it isn't given.
			if key := strings.ToLower(c); c != "" && !strings.ContainsAny(c, "\r\n") && !seen[key] {
				seen[key] = true
				out = append(out, c)
			}
		}
	}
	return out, nil
}

// sameProgram reports whether the command's program, given as a path, is
// the file an entry's Exec runs. A bare Exec name is looked up on PATH.
func sameProgram(path, runs string, env []string) bool {
	if !strings.Contains(runs, "/") {
		runs = lookPath(runs, env)
		if runs == "" {
			return false
		}
	}
	a, errA := os.Stat(path)
	b, errB := os.Stat(runs)
	if errA == nil && errB == nil {
		return os.SameFile(a, b)
	}
	// One isn't there to compare; the paths themselves still can be.
	absA, errA := filepath.Abs(path)
	absB, errB := filepath.Abs(runs)
	return errA == nil && errB == nil && absA == absB
}

// lookPath finds name on env's PATH, or returns "".
func lookPath(name string, env []string) string {
	for _, dir := range filepath.SplitList(lookup(env, "PATH")) {
		if dir == "" {
			dir = "."
		}
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// perEntry reports whether a decoded Exec argument holds a field code that
// expands from the entry itself, alone or within a word (--entry=%k): %i
// its icon, %c its name, %k its file. The other codes stand for what the
// app is opened with, the same for every entry.
func perEntry(arg string) bool {
	for _, c := range "ick" {
		if strings.Contains(arg, codeMark+string(c)) {
			return true
		}
	}
	return false
}

// entryMatch is a desktop entry that runs the program being looked up.
type entryMatch struct {
	id, class string
	args      []string // the entry's other Exec words: wrappers, settings, arguments
}

// walkEntries calls visit for each .desktop file under root, with its path
// relative to root, in lexical order. Unlike filepath.WalkDir it follows
// symlinks to directories, root's included, since a distribution may link
// applications or a vendor directory in from elsewhere. A link back to a
// directory being walked is a cycle and isn't followed; two links to one
// directory are each walked, since each path names its own desktop IDs. A
// link to a file counts as that file, and a dangling one is still visited,
// for reading it to report; any other link that doesn't resolve is
// reported. A root that doesn't exist is normal; anything else that can't
// be read goes to report, and the walk goes on.
func walkEntries(root string, visit func(rel, path string), report func(error)) {
	onPath := map[string]bool{}
	var walk func(dir, rel string)
	walk = func(dir, rel string) {
		real, err := filepath.EvalSymlinks(dir)
		if err != nil {
			// Only a root that isn't there at all is normal; a link to
			// nothing is reported like any other.
			if _, lerr := os.Lstat(dir); dir != root || !errors.Is(lerr, fs.ErrNotExist) {
				report(fmt.Errorf("%s: %w", dir, err))
			}
			return
		}
		// A directory already being walked further up is a cycle. Another
		// link to a directory walked elsewhere is not: each path names its
		// own desktop IDs.
		if onPath[real] {
			return
		}
		onPath[real] = true
		defer delete(onPath, real)
		entries, err := os.ReadDir(dir)
		if err != nil {
			report(err)
			return
		}
		for _, e := range entries {
			path := filepath.Join(dir, e.Name())
			r := filepath.Join(rel, e.Name())
			isDir := e.IsDir()
			if e.Type()&fs.ModeSymlink != 0 {
				info, err := os.Stat(path)
				switch {
				case err == nil:
					isDir = info.IsDir()
				case !strings.HasSuffix(e.Name(), ".desktop"):
					// A link that doesn't resolve may have been a
					// directory of entries. One ending .desktop is
					// visited below, and its read reports it.
					report(err)
					continue
				}
			}
			switch {
			case isDir:
				walk(path, r)
			case strings.HasSuffix(e.Name(), ".desktop"):
				// Opening a FIFO or device could block every launch and
				// shell command on it, so only a regular file is read.
				if info, err := os.Stat(path); err == nil && !info.Mode().IsRegular() {
					report(fmt.Errorf("%s: not a regular file", path))
					continue
				}
				visit(r, path)
			}
		}
	}
	walk(root, "")
}

// Programs that start some other app, named later on their command line:
// every Flatpak entry runs flatpak, so matching on it would grant every
// Flatpak app's classes at once. The guard's grant for the name itself
// still stands. The launcher keeps the same list (WRAPPERS in
// shell/lib/launcher.mjs).
var opaque = map[string]bool{}

func init() {
	for _, name := range strings.Fields(`env sh bash dash zsh exec nohup setsid sudo pkexec
		systemd-run flatpak snap gtk-launch gapplication dbus-launch xdg-open gio uwsm
		uwsm-app app2unit python python3 perl java wine toolbox distrobox`) {
		opaque[name] = true
	}
}

// dataDirs lists the XDG data directories, most important first.
func dataDirs(env []string) []string {
	home := lookup(env, "XDG_DATA_HOME")
	if home == "" {
		if h := lookup(env, "HOME"); h != "" {
			home = filepath.Join(h, ".local", "share")
		}
	}
	dirs := lookup(env, "XDG_DATA_DIRS")
	if dirs == "" {
		dirs = "/usr/local/share:/usr/share"
	}
	var out []string
	if home != "" {
		out = append(out, home)
	}
	for _, d := range strings.Split(dirs, ":") {
		if d != "" {
			out = append(out, d)
		}
	}
	return out
}

// readEntry reads a desktop entry's Exec, StartupWMClass, Path (its working
// directory), Type and Hidden from its [Desktop Entry] group, with the
// string escapes (\s, \n, \t, \r, \\) undone.
func readEntry(path string) (e entry, err error) {
	f, err := os.Open(path)
	if err != nil {
		return entry{}, err
	}
	defer f.Close()
	group := ""
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "[") {
			group = line
			continue
		}
		if group != "[Desktop Entry]" {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		value = unescapeValue(strings.TrimSpace(value))
		switch strings.TrimSpace(key) {
		case "Exec":
			e.exec = value
		case "StartupWMClass":
			e.class = value
		case "Path":
			e.dir = value
		case "Type":
			e.kind = value
		case "Hidden":
			e.hidden = value == "true"
		case "Terminal":
			e.terminal = value == "true"
		}
	}
	if err := scanner.Err(); err != nil {
		return entry{}, fmt.Errorf("reading %s: %w", path, err)
	}
	return e, nil
}

// entry is what readEntry reads of a desktop entry.
type entry struct {
	exec, class, dir, kind string
	hidden, terminal       bool
}

// unescapeValue undoes a string value's escapes. A backslash before any
// other character stays, for Exec's own quoting to read.
func unescapeValue(v string) string {
	if !strings.Contains(v, `\`) {
		return v
	}
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		if v[i] != '\\' || i+1 == len(v) {
			b.WriteByte(v[i])
			continue
		}
		i++
		switch v[i] {
		case 's':
			b.WriteByte(' ')
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte('\\')
			b.WriteByte(v[i])
		}
	}
	return b.String()
}

// execWords splits an Exec value into words as the Desktop Entry spec
// quotes them: a double-quoted word may hold spaces, and inside quotes a
// backslash escapes the next character.
func execWords(exec string) (words []string, ok bool) {
	var cur strings.Builder
	inQuote, have := false, false
	for i := 0; i < len(exec); i++ {
		c := exec[i]
		switch {
		case inQuote && c == '\\':
			// Only ", `, $ and \ may be escaped inside quotes.
			if i+1 == len(exec) || !strings.ContainsRune("\"`$\\", rune(exec[i+1])) {
				return nil, false
			}
			i++
			cur.WriteByte(exec[i])
		case inQuote && c == '%':
			// A field code isn't allowed inside quotes; %% is a
			// literal percent sign, decoded later.
			if i+1 == len(exec) || exec[i+1] != '%' {
				return nil, false
			}
			i++
			cur.WriteString("%%")
		case c == '"':
			inQuote = !inQuote
			have = true
		case !inQuote && (c == ' ' || c == '\t'):
			if have || cur.Len() > 0 {
				words = append(words, cur.String())
			}
			cur.Reset()
			have = false
		default:
			cur.WriteByte(c)
		}
	}
	// A quote left open makes the Exec value invalid.
	if inQuote {
		return nil, false
	}
	if have || cur.Len() > 0 {
		words = append(words, cur.String())
	}
	return words, true
}

// execProgram is the basename of the program an Exec value runs, past
// wrappers, or "" when it names none.
func execProgram(exec string) string {
	name, _, _ := execCommand(exec)
	if name == "" {
		return ""
	}
	return filepath.Base(name)
}

// execCommand is the program an Exec value runs, as written (a name or a
// path), and every other word of it: the wrappers and their settings before
// the program (`env APP_MODE=writer`), then its arguments. ok is false for
// an Exec the Desktop Entry spec calls invalid: one with an unknown field
// code, or a code in the program itself.
//
// Each word is decoded once (fieldCodes): %% is a literal percent sign, and
// a field code is kept as codeMark and its letter, which no literal text
// can produce. Codes stay in args, so `viewer` and `viewer %f` differ.
func execCommand(exec string) (name string, args []string, ok bool) {
	name, args, _, _, ok = execCommandEnv(exec)
	return name, args, ok
}

// execCommandEnv is execCommand, also giving what env is told to do before
// the program, and whether that moves it (envSettings).
func execCommandEnv(exec string) (name string, args, settings []string, moves, ok bool) {
	raw, ok := execWords(exec)
	if !ok {
		return "", nil, nil, false, false
	}
	var words []string
	for _, w := range raw {
		text, codes, valid := fieldCodes(w)
		if !valid {
			return "", nil, nil, false, false
		}
		// %F, %U and %i stand only as a word of their own.
		if text != codeMark+codes && strings.ContainsAny(codes, "FUi") {
			return "", nil, nil, false, false
		}
		// A word that was only deprecated codes is gone, as the spec says.
		if text == "" && w != "" {
			continue
		}
		words = append(words, text)
	}
	wrapperAt := map[int]bool{}
	name, at, done := scanProgram(words, func(i int) { wrapperAt[i] = true })
	if !done || name == "" {
		return "", nil, nil, false, true
	}
	if strings.Contains(name, codeMark) {
		return "", nil, nil, false, false
	}
	settings, moves = envSettings(words[:at], wrapperAt)
	for i, w := range words {
		if i == at {
			continue
		}
		// A wrapper named by path is that wrapper: /usr/bin/env is env.
		// Only a wrapper: an option's value is kept as written, since
		// `env --chdir /usr/bin/nice` and `--chdir /opt/nice` differ.
		if wrapperAt[i] {
			w = wrapperName(w)
		}
		args = append(args, w)
	}
	return name, args, settings, moves, true
}

// envSettings is what the words before a program, read past their
// wrappers, tell env to do: its settings, unsets and options, in order
// (`APP_MODE=writer`, `-u WAYLAND_DISPLAY`). moves is true when they
// change PATH, clear the environment or change directory, so that which
// program runs, and where, can't be told from here.
func envSettings(words []string, wrapperAt map[int]bool) (settings []string, moves bool) {
	wrapper := ""
	for i, w := range words {
		if wrapperAt[i] {
			wrapper = wrapperName(w)
			continue
		}
		if wrapper != "env" || w == "--" {
			continue
		}
		settings = append(settings, w)
		moves = moves || movesEnv(w)
	}
	return settings, moves
}

// movesEnv reports whether one of env's words, or a shell assignment, sets,
// unsets or clears PATH, or changes directory.
func movesEnv(w string) bool {
	switch {
	case w == "PATH", strings.HasPrefix(w, "PATH="), w == "-", w == "--ignore-environment",
		w == "--unset=PATH", w == "--chdir", strings.HasPrefix(w, "--chdir="):
		return true
	case strings.HasPrefix(w, "-") && !strings.HasPrefix(w, "--"):
		// A short cluster: -i clears the environment, -C changes
		// directory, and -u's value may follow in the same word
		// (`-uPATH`, `-iuPATH`).
		opts, value, _ := strings.Cut(w[1:], "u")
		return strings.ContainsAny(opts, "iC") || value == "PATH"
	}
	return false
}

// codeMark stands in a decoded Exec word where a field code was, before the
// code's letter. Exec values are text, so it can't come from a literal.
const codeMark = "\x00"

// fieldCodes decodes an Exec word: %% becomes %, a deprecated code (%d, %D,
// %n, %N, %v, %m) is removed, and each other field code becomes codeMark
// and its letter, collected in codes. valid is false for an unknown code or
// a lone % at the end, which make the entry invalid.
func fieldCodes(w string) (text, codes string, valid bool) {
	if !strings.Contains(w, "%") {
		return w, "", true
	}
	var b strings.Builder
	for i := 0; i < len(w); i++ {
		if w[i] != '%' {
			b.WriteByte(w[i])
			continue
		}
		if i+1 == len(w) {
			return "", "", false
		}
		i++
		switch c := w[i]; {
		case c == '%':
			b.WriteByte('%')
		case strings.IndexByte("dDnNvm", c) >= 0:
			// Deprecated: removed and ignored, as the spec says.
		case strings.IndexByte("fFuUick", c) >= 0:
			b.WriteString(codeMark)
			b.WriteByte(c)
			codes += string(c)
		default:
			return "", "", false
		}
	}
	return b.String(), codes, true
}

// entryClasses returns the window classes the desktop entry with desktop
// ID id (`org.mozilla.firefox`, with or without `.desktop`) says its
// window may have: the ID, its StartupWMClass, and the program its Exec
// runs, past wrappers, unless that program is itself one that opens other
// apps (opaque). It's for `tide launch xdg-open URL`, granting the app the
// opener hands the URL to. The entry is found as the desktop finds it: the
// first data directory holding the ID wins, even hidden. An ID no
// directory holds (a stale default in mimeapps.list), a hidden entry, one
// that isn't an application, a terminal entry (its window is the
// terminal's) or one whose Exec is invalid names no class, and is an error
// saying which, so the caller's fallback is reported. So is anything that
// can't be read on the way, since it may have been the entry asked for.
func entryClasses(id string, env []string) ([]string, error) {
	id = strings.TrimSuffix(id, ".desktop")
	if id == "" || strings.ContainsAny(id, "/\r\n") {
		return nil, fmt.Errorf("not a desktop ID: %q", id)
	}
	var errs []error
	var e entry
	found := false
	for _, data := range dataDirs(env) {
		if found {
			break
		}
		walkEntries(filepath.Join(data, "applications"), func(rel, path string) {
			if found || strings.ReplaceAll(strings.TrimSuffix(rel, ".desktop"), string(filepath.Separator), "-") != id {
				return
			}
			found = true
			var err error
			if e, err = readEntry(path); err != nil {
				errs = append(errs, err)
			}
		}, func(err error) {
			// Once the entry is found, what can't be read later in the
			// walk can't be the entry asked for, so it doesn't count.
			if !found {
				errs = append(errs, err)
			}
		})
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	switch {
	case !found:
		return nil, errors.New("no such desktop entry")
	case e.hidden:
		return nil, errors.New("the entry is hidden")
	case e.kind != "Application":
		return nil, fmt.Errorf("the entry is a %q, not an application", e.kind)
	case e.terminal:
		return nil, errors.New("the entry runs in a terminal, whose window is the terminal's")
	}
	runs, _, valid := execCommand(e.exec)
	if !valid {
		return nil, fmt.Errorf("the entry's Exec is invalid: %q", e.exec)
	}
	var out []string
	seen := map[string]bool{}
	program := filepath.Base(runs)
	if opaque[program] {
		program = ""
	}
	for _, c := range []string{id, e.class, program} {
		if key := strings.ToLower(c); c != "" && !strings.ContainsAny(c, "\r\n") && !seen[key] {
			seen[key] = true
			out = append(out, c)
		}
	}
	return out, nil
}
