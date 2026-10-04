// Command tide-grant records a tide focus grant for a shell
// command line (SPEC.md §14.3), so the first window the command opens may
// take focus.
//
// Every interactive shell calls it before running a command, in a
// tide session only:
//
//	tide-grant --pid SHELL-PID -- COMMAND-LINE
//
// The grant names the shell's pid, so a window from any process the command
// starts can use it: the focus guard walks the window's parents in /proc.
// It also names the app the line's first command runs, for an app that's
// already running, which opens its window from the process it already had
// (`firefox URL`). That name comes from parsing the line as bash with
// mvdan.cc/sh, past assignments, redirections, `!` and wrappers such as env
// and nohup, with words expanded from this process's environment. A command
// substitution is never run: a program word that needs one names nothing.
//
// The app's desktop entries may name another class its window has
// (Exec=nautilus, app_id org.gnome.Nautilus). They're read once the grant is
// in, and their classes added to it before tide-grant returns.
//
//	tide-grant --classes PROGRAM
//
// prints those classes, one per line, for `tide launch`, which grants a key
// binding's program the same way.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/syntax"
)

func main() {
	os.Exit(run(os.Args[1:], os.Environ(), os.Stdout, os.Stderr))
}

func run(args []string, env []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("tide-grant", flag.ContinueOnError)
	flags.SetOutput(stderr)
	pid := flags.Int("pid", os.Getppid(), "the `pid` of the shell running the command")
	classes := flags.Bool("classes", false, "print the window classes the desktop entries for the command `WORD...` name, one per line, and exit")
	program := flags.Bool("program", false, "print the program the command `WORD...` runs, past wrappers, and exit")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	// For `tide launch`, which runs a key binding's command as words, not a
	// line for the shell: the program it runs, past wrappers (`env VAR=x
	// editor` runs editor), to grant before the lookup, then its classes.
	if *classes || *program {
		if *classes && *program || flags.NArg() == 0 {
			fmt.Fprintln(stderr, "usage: tide-grant --program WORD...")
			fmt.Fprintln(stderr, "       tide-grant --classes WORD...")
			return 2
		}
		runs, settings, moves := commandProgram(flags.Args())
		if *program {
			if runs != "" {
				fmt.Fprintln(stdout, runs)
			}
			return 0
		}
		// A command run with a PATH or directory of its own may run
		// another program than its entries name.
		if runs == "" || moves {
			return 0
		}
		found, err := desktopClasses(runs, settings, env)
		for _, c := range found {
			fmt.Fprintln(stdout, c)
		}
		if err != nil {
			fmt.Fprintf(stderr, "tide-grant: couldn't read every desktop entry: %v\n", err)
			return 1
		}
		return 0
	}
	if flags.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: tide-grant [--pid PID] [--] COMMAND-LINE")
		fmt.Fprintln(stderr, "       tide-grant --program WORD...")
		fmt.Fprintln(stderr, "       tide-grant --classes WORD...")
		return 2
	}
	if !inTide(lookup(env, "XDG_CURRENT_DESKTOP")) {
		return 0
	}
	runs, settings, moves := programPathEnv(flags.Arg(0), env)
	app := ""
	if runs != "" {
		app = filepath.Base(runs)
	}
	if err := grant(app, *pid); err != nil {
		fmt.Fprintf(stderr, "tide: couldn't record a focus grant for %s: %v\n", flags.Arg(0), err)
		return 1
	}
	// A command run with a PATH or directory of its own may run another
	// program than the entries this lookup finds, so it's granted only its
	// name.
	if app == "" || moves {
		return 0
	}
	// The app's desktop entries may name the class its window has. They're
	// read after the grant is in, so a key press meanwhile still cancels it,
	// and before the command runs, so an app that's already running can't
	// activate its window ahead of them. That costs the shell about 4 ms
	// over 300 entries.
	return extendFromEntries(app, runs, settings, *pid, env, stderr)
}

// extendFromEntries adds the classes app's desktop entries name to its
// grant for pid.
// A desktop entry that couldn't be read is reported, and none are added.
func extendFromEntries(app, runs string, settings []string, pid int, env []string, stderr io.Writer) int {
	status := 0
	more, err := desktopClasses(runs, settings, env)
	if err != nil {
		fmt.Fprintf(stderr, "tide: couldn't read every desktop entry for %s's focus grant: %v\n", app, err)
		status = 1
	}
	if len(more) == 0 {
		return status
	}
	if err := extend(app, more, pid); err != nil {
		fmt.Fprintf(stderr, "tide: couldn't add %s to the focus grant for %s: %v\n", strings.Join(more, ", "), app, err)
		return 1
	}
	return status
}

func inTide(desktops string) bool {
	for _, d := range strings.Split(desktops, ":") {
		if d == "tide" {
			return true
		}
	}
	return false
}

func lookup(env []string, name string) string {
	for i := len(env) - 1; i >= 0; i-- {
		if value, ok := strings.CutPrefix(env[i], name+"="); ok {
			return value
		}
	}
	return ""
}

// program returns the app id (the program's basename) of the line's first
// command, or "" where it names none: a builtin, a program word only the
// shell could expand, or a line whose first command isn't a simple one
// (fish's `if true; firefox; end`). Later commands on the line go without a
// name; the pid covers them, unless their app was already running.
func program(line string, env []string) string {
	name := programPath(line, env)
	if name == "" {
		return ""
	}
	return filepath.Base(name)
}

// programPath is the program the line runs as written, a name or a path:
// the desktop-entry lookup matches a path to the file it names.
func programPath(line string, env []string) string {
	name, _, _ := programPathEnv(line, env)
	return name
}

// programPathEnv is programPath, also giving the settings the command runs
// it with: its shell assignments (`APP_MODE=calc suite`) as NAME=value, then
// what env is told to do (envSettings). moves is true when they change PATH,
// clear the environment or change directory, so that the command may run
// another program than its name finds here.
func programPathEnv(line string, env []string) (name string, settings []string, moves bool) {
	call := firstCall(line)
	if call == nil {
		return "", nil, false
	}
	cfg := &expand.Config{Env: expand.ListEnviron(env...)}
	// Expand one word at a time and stop once the program is known, so an
	// argument after it that only the shell could expand doesn't matter.
	var fields []string
	for _, word := range call.Args {
		more, err := expand.Fields(cfg, word)
		if err != nil {
			return "", nil, false
		}
		fields = append(fields, more...)
		wrapperAt := map[int]bool{}
		name, at, done := scanProgram(fields, func(i int) { wrapperAt[i] = true })
		if !done {
			continue
		}
		app := filepath.Base(name)
		// A quoted "$BROWSER" holding `firefox --new-window` is one
		// word, which names no program, and no window's class has a
		// space.
		if name == "" || app == "." || app == "/" || strings.ContainsAny(app, " \t\n") {
			return "", nil, false
		}
		for _, a := range call.Assigns {
			if a.Append || a.Array != nil || a.Index != nil || a.Naked {
				// `A+=x` or an array: what the program runs with
				// can't be told.
				return name, nil, true
			}
			value := ""
			if a.Value != nil {
				v, err := expand.Literal(cfg, a.Value)
				if err != nil {
					// A value only the shell could work out: what
					// the program runs with can't be told.
					return name, nil, true
				}
				value = v
			}
			setting := a.Name.Value + "=" + value
			settings = append(settings, setting)
			moves = moves || movesEnv(setting)
		}
		more, envMoves := envSettings(fields[:at], wrapperAt)
		return name, append(settings, more...), moves || envMoves
	}
	return "", nil, false
}

// commandProgram is the program a command given as words runs, as written,
// past wrappers, with the settings env runs it with and whether they move
// it (envSettings); "" when it runs none, such as `env --help`.
func commandProgram(words []string) (name string, settings []string, moves bool) {
	wrapperAt := map[int]bool{}
	name, at, done := scanProgram(words, func(i int) { wrapperAt[i] = true })
	app := filepath.Base(name)
	if !done || name == "" || app == "." || app == "/" || strings.ContainsAny(app, " \t\n") {
		return "", nil, false
	}
	settings, moves = envSettings(words[:at], wrapperAt)
	return name, settings, moves
}

// firstCall returns the line's first simple command, looking past `!`,
// `time` and the left side of a pipe or `&&`. A line bash rejects
// (fish's `nautilus (pwd)`) is cut where bash stops.
func firstCall(line string) *syntax.CallExpr {
	file := parsePrefix(line)
	if file == nil || len(file.Stmts) == 0 {
		return nil
	}
	cmd := file.Stmts[0].Cmd
	for {
		switch c := cmd.(type) {
		case *syntax.CallExpr:
			if len(c.Args) == 0 {
				return nil // only assignments
			}
			return c
		case *syntax.BinaryCmd:
			cmd = c.X.Cmd
		case *syntax.TimeClause:
			if c.Stmt == nil {
				return nil
			}
			cmd = c.Stmt.Cmd
		default:
			return nil
		}
	}
}

// parsePrefix parses line as bash, or as much of it as comes before bash's
// first error.
func parsePrefix(line string) *syntax.File {
	parser := syntax.NewParser()
	for range 4 {
		file, err := parser.Parse(strings.NewReader(line), "")
		if err == nil {
			return file
		}
		var offset uint
		var parseErr syntax.ParseError
		var langErr syntax.LangError
		switch {
		case errors.As(err, &parseErr):
			offset = parseErr.Pos.Offset()
		case errors.As(err, &langErr):
			offset = langErr.Pos.Offset()
		default:
			return nil
		}
		if offset == 0 {
			// `word (…)` reads as the start of a function definition.
			offset = uint(max(strings.IndexByte(line, '('), 0))
		}
		if offset == 0 || offset >= uint(len(line)) {
			return nil
		}
		line = line[:offset]
	}
	return nil
}

// Commands that run the next word as the program. and, or and not are
// fish's control prefixes (`false; or firefox`), since fish lines are
// parsed as bash too.
var wrappers = map[string]bool{
	"builtin": true, "command": true, "env": true, "exec": true, "nice": true,
	"nocorrect": true, "noglob": true, "nohup": true, "setsid": true, "time": true,
	"and": true, "or": true, "not": true,
}

// Wrapper long options that take the next word as their value.
var valueOptions = map[string]map[string]bool{
	"env":  {"--chdir": true, "--unset": true},
	"nice": {"--adjustment": true},
}

// Wrapper short options that take a value, in the word or the next.
var valueLetters = map[string]string{"env": "CSu", "exec": "a", "nice": "n"}

// Wrapper short options that print help or a version and exit, running
// nothing (`setsid -h`), like --help and --version.
var exitLetters = map[string]string{"setsid": "hV"}

// The shell's own builtins in bash and zsh, which run in the shell even
// where a file of the same name is on PATH (echo, pwd, test ...).
var builtins = map[string]bool{}

func init() {
	for _, name := range strings.Fields(`
		. : [ alias autoload bg bind bindkey break builtin caller cd chdir
		command compgen complete compopt continue declare dirs disown echo
		emulate enable eval exec exit export false fc fg functions getopts
		hash help history jobs kill let local logout mapfile popd print
		printf pushd pwd read readarray readonly rehash return set setopt
		shift shopt source suspend test times trap true type typeset ulimit
		umask unalias unfunction unset unsetopt wait whence where which zle
		zmodload`) {
		builtins[name] = true
	}
}

// Wrappers after which the program is a separate executable, never a
// builtin: `env echo` runs /usr/bin/echo.
var externalWrappers = map[string]bool{"env": true, "exec": true, "nice": true, "nohup": true, "setsid": true}

// wrapperName is the wrapper field names, or "": a path counts when it
// names a wrapper that is a program of its own in a system directory
// (/usr/bin/env), never a builtin or keyword. Elsewhere (/opt/vendor/env,
// ./env) a path is a program that only shares the name.
func wrapperName(field string) string {
	if wrappers[field] {
		return field
	}
	if base := filepath.Base(field); strings.Contains(field, "/") && externalWrappers[base] && systemDirs[filepath.Dir(field)] {
		return base
	}
	return ""
}

// The directories a distribution installs env, nice and the like in.
var systemDirs = map[string]bool{"/bin": true, "/usr/bin": true, "/usr/local/bin": true, "/run/current-system/sw/bin": true}

// fieldsProgram finds the program in the expanded words of a simple
// command, so far. done is false while the words so far don't settle it.
// A command that runs no program, or whose program the helper can't tell,
// settles on "": a builtin, `command -v NAME` (which only looks NAME up), a
// wrapper's --help or --version, and `env -S STRING`.
func fieldsProgram(fields []string) (name string, done bool) {
	name, _, done = fieldsProgramAt(fields)
	return name, done
}

// fieldsProgramAt is fieldsProgram, also returning the program's index in
// fields (-1 when it names none), so its arguments are the fields after.
func fieldsProgramAt(fields []string) (name string, at int, done bool) {
	return scanProgram(fields, func(int) {})
}

// scanProgram is fieldsProgramAt, calling isWrapper with the index of each
// field it took for a wrapper, not an option or its value.
func scanProgram(fields []string, isWrapper func(int)) (name string, at int, done bool) {
	wrapper := ""
	external := false
	found := func(i int) (string, int, bool) {
		if !external && builtins[fields[i]] {
			return "", -1, true
		}
		return fields[i], i, true
	}
	for i := 0; i < len(fields); i++ {
		field := fields[i]
		if wrapper == "" {
			name := wrapperName(field)
			if name == "" {
				return found(i)
			}
			wrapper = name
			external = externalWrappers[name]
			isWrapper(i)
			continue
		}
		switch {
		case wrapperName(field) != "":
			isWrapper(i)
			wrapper = wrapperName(field)
			external = external || externalWrappers[wrapper]
		case field == "--help" || field == "--version":
			return "", -1, true
		case exitLetters[wrapper] != "" && strings.HasPrefix(field, "-") && !strings.HasPrefix(field, "--") &&
			strings.ContainsAny(field[1:], exitLetters[wrapper]):
			return "", -1, true
		case wrapper == "command" && strings.HasPrefix(field, "-") && strings.ContainsAny(field[1:], "vV"):
			return "", -1, true
		case wrapper == "env" && (field == "--split-string" || strings.HasPrefix(field, "--split-string=")):
			return "", -1, true
		case wrapper == "env" && strings.Contains(field, "=") && syntax.ValidName(strings.SplitN(field, "=", 2)[0]):
			// env's own NAME=value arguments
		case field == "--":
			i++
			// env still takes NAME=value words after its options end.
			for wrapper == "env" && i < len(fields) && strings.Contains(fields[i], "=") &&
				syntax.ValidName(strings.SplitN(fields[i], "=", 2)[0]) {
				i++
			}
			if i == len(fields) {
				return "", -1, false
			}
			// What follows may be another wrapper (`nice -- env editor`).
			if w := wrapperName(fields[i]); w != "" {
				isWrapper(i)
				wrapper = w
				external = external || externalWrappers[w]
				continue
			}
			return found(i)
		case valueLetters[wrapper] != "" && strings.HasPrefix(field, "-") && !strings.HasPrefix(field, "--"):
			// Short options, which may be clustered (`env -iC/opt/app`,
			// `exec -cla NAME`). One that takes a value takes the rest of
			// the word, or the next.
			for j := 1; j < len(field); j++ {
				c := field[j]
				if !strings.ContainsRune(valueLetters[wrapper], rune(c)) {
					continue
				}
				if wrapper == "env" && c == 'S' {
					return "", -1, true
				}
				if j+1 == len(field) {
					i++
				}
				break
			}
		case strings.HasPrefix(field, "-"):
			if valueOptions[wrapper][field] {
				i++
			}
		default:
			return found(i)
		}
	}
	return "", -1, false
}

// grant records a one-shot grant through Hyprland's Lua config, for app's
// windows and those of pid's descendants; with no app, for the descendants
// only. The grant is keyed by this process's pid, so extend widens this
// grant and no later one for the same app and shell.
func grant(app string, pid int) error {
	lua := "nil"
	if app != "" {
		lua = luaString(app)
	}
	return eval("tide_focus.grant(" + lua + ", " + strconv.Itoa(pid) + ", " + strconv.Itoa(os.Getpid()) + ")")
}

// extend adds classes to the grant this process recorded for app and pid,
// if it still holds.
func extend(app string, classes []string, pid int) error {
	quoted := make([]string, len(classes))
	for i, c := range classes {
		quoted[i] = luaString(c)
	}
	return eval("tide_focus.extend(" + luaString(app) + ", { " + strings.Join(quoted, ", ") + " }, " + strconv.Itoa(pid) + ", " + strconv.Itoa(os.Getpid()) + ")")
}

// eval runs a Lua call in Hyprland, which answers "ok" when it ran.
func eval(call string) error {
	out, err := exec.Command("hyprctl", "eval", call).CombinedOutput()
	reply := strings.TrimSpace(string(out))
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && reply != "" {
			return errors.New(reply)
		}
		return err
	}
	if reply != "ok" {
		return errors.New(reply)
	}
	return nil
}

// luaString quotes s as a Lua string literal.
func luaString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, "\\%03d", c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
