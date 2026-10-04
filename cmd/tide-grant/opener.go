package main

import (
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"mvdan.cc/sh/v3/expand"
)

// errNoDefault is a type mimeapps.list names no default app for: the
// opener will say so itself, and the grant stays as it was.
var errNoDefault = errors.New("no default app")

// opensWith reports whether a command, as words, runs an opener: xdg-open,
// or gio with the subcommand open, past wrappers (`nice gio open URL`,
// `env --unset gio gio open URL`). The program's position is the parsed
// one, so a wrapper's operand that happens to read `gio` doesn't count.
func opensWith(words []string) bool {
	name, at, done := fieldsProgramAt(words)
	if !done || name == "" {
		return false
	}
	switch filepath.Base(name) {
	case "xdg-open":
		return true
	case "gio":
		return at+1 < len(words) && words[at+1] == "open"
	}
	return false
}

// openerTarget is the one thing a command opens through xdg-open or gio
// open, from its words, past wrappers (`nice xdg-open URL`). ok is false
// for any other command, for an option, and for several targets: those
// may each open another app, which one grant can't name.
func openerTarget(words []string) (target string, ok bool) {
	name, at, done := fieldsProgramAt(words)
	if !done || name == "" {
		return "", false
	}
	rest := words[at+1:]
	switch filepath.Base(name) {
	case "xdg-open":
		if len(rest) == 1 {
			target = rest[0]
		}
	case "gio":
		// `--` ends gio's options, so the location after it may start
		// with a dash (`gio open -- -notes.txt`).
		if len(rest) == 3 && rest[0] == "open" && rest[1] == "--" && rest[2] != "" {
			return rest[2], true
		}
		if len(rest) == 2 && rest[0] == "open" {
			target = rest[1]
		}
	}
	if target == "" || strings.HasPrefix(target, "-") {
		return "", false
	}
	return target, true
}

var scheme = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9+.-]*):`)

// targetType is the MIME type the opener picks an app by: a file's own,
// as xdg-mime reads it, or a URL's scheme handler (x-scheme-handler/https).
// A file: URL is its local file. "" with no error for a target that's
// neither a file nor a URL; a relative path is the caller's working
// directory's, as the opener's would be.
func targetType(target string, env []string) (string, error) {
	path := target
	isFile := false
	if m := scheme.FindStringSubmatch(target); m != nil && strings.EqualFold(m[1], "file") {
		// The one form both openers read as the same local file:
		// file:///PATH, the scheme in lower case, escapes undone and any
		// query or fragment dropped. xdg-open's generic path (xdg-utils
		// 1.1.3) takes only that prefix as a file, while GIO also reads
		// FILE:, file:/x and file://localhost/x but refuses user info
		// and an escaped / or NUL. Any other form may open another file,
		// or none, so it names nothing here.
		isFile = true
		u, err := url.Parse(target)
		if err != nil || !strings.HasPrefix(target, "file:///") || u.Host != "" || u.User != nil ||
			strings.Contains(u.Path, "\x00") || strings.Contains(strings.ToLower(rawFilePath(target)), "%2f") {
			return "", nil
		}
		path = u.Path
	}
	// Any other scheme is a URL, whatever the filesystem holds: both
	// openers read a word with a scheme as a URI before trying it as a
	// path, so `https://example.com` opens the browser even where
	// ./https:/example.com exists.
	if m := scheme.FindStringSubmatch(target); m != nil && !isFile {
		// xdg-open (xdg-utils 1.1.3) takes a word as a URL only when its
		// scheme has no digit (`^[[:alpha:]+.-]+:`), and GIO when it has
		// any, so the openers disagree on `web+demo2://item`: it names
		// nothing.
		if strings.ContainsAny(m[1], "0123456789") {
			return "", nil
		}
		return "x-scheme-handler/" + strings.ToLower(m[1]), nil
	}
	_, err := os.Stat(path)
	if err != nil {
		// Not there is a target that names no file: a word the opener
		// will reject itself. Any other failure (no permission, an I/O
		// error) is said, by its reason alone: the path may be a file:
		// URL's, and so a secret.
		if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.ENAMETOOLONG) {
			return "", nil
		}
		var pathErr *fs.PathError
		if errors.As(err, &pathErr) {
			err = pathErr.Err
		}
		return "", fmt.Errorf("couldn't read the file: %v", err)
	}
	// The error names neither the path nor what xdg-mime said, which may
	// quote it: the path may be a file: URL's, and so a secret
	// (shownTarget). Its exit status is what's left to say.
	mime, err := xdgMime(env, "query", "filetype", path)
	if err != nil {
		return "", fmt.Errorf("xdg-mime couldn't read the file's type: %s", exitStatus(err))
	}
	if mime == "" {
		return "", errors.New("xdg-mime gave no type for the file")
	}
	return mime, nil
}

// openerClasses is the window classes of the app an opener hands target
// to: the default app for its type in mimeapps.list, as xdg-mime finds it
// (the first, when several are listed), and what its desktop entry names
// (entryClasses). Nothing, and no error, for a target that can't be typed;
// errNoDefault, wrapped with the type, when no app is the default.
func openerClasses(target string, env []string) ([]string, error) {
	mime, err := targetType(target, env)
	if err != nil || mime == "" {
		return nil, err
	}
	desktop, err := xdgMime(env, "query", "default", mime)
	if err != nil {
		return nil, fmt.Errorf("the default app for %s: %w", mime, err)
	}
	desktop, _, _ = strings.Cut(desktop, ";")
	if desktop = strings.TrimSpace(desktop); desktop == "" {
		return nil, fmt.Errorf("%w for %s", errNoDefault, mime)
	}
	found, err := entryClasses(desktop, env)
	if err != nil {
		return nil, fmt.Errorf("%s, the default app for %s: %w", desktop, mime, err)
	}
	return found, nil
}

// exitStatus is how err says a command ended ("exit status 2"), without
// anything the command printed. A command that couldn't start says why
// (not on PATH, not executable): that names the program, never its
// arguments.
func exitStatus(err error) string {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ProcessState.String()
	}
	return err.Error()
}

// xdgMime runs xdg-mime with env and returns its output's first line. A
// field so the tests can stand in for it.
var xdgMime = func(env []string, args ...string) (string, error) {
	cmd := exec.Command("xdg-mime", args...)
	cmd.Env = env
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && len(exitErr.Stderr) > 0 {
			return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return "", err
	}
	line, _, _ := strings.Cut(string(out), "\n")
	return strings.TrimSpace(line), nil
}

// shownTarget is target as a message names it: a URL by its scheme alone
// ("the https: URL"), since any part of one may carry a secret (a password,
// a token in its query, a reset link's path), and a file path as it is.
func shownTarget(target string) string {
	if m := scheme.FindStringSubmatch(target); m != nil {
		return "the " + strings.ToLower(m[1]) + ": URL"
	}
	return target
}

// lineWords is the words of a line's first command, expanded as the shell
// would from this process's environment; ok is false when one needs what
// only the shell can do: a command substitution, an unset `${X?}`, or a
// glob. What a glob matches depends on the shell and its options (zsh's
// `**/` and `noglob`, bash's `globstar` and `nullglob`, fish's own rules),
// so `xdg-open *.pdf` names no app rather than a guessed one.
func lineWords(line string, env []string) (words []string, ok bool) {
	call := firstCall(line)
	if call == nil {
		return nil, false
	}
	globbed := false
	cfg := &expand.Config{
		Env: expand.ListEnviron(env...),
		// Called only for a word with an unquoted pattern in it.
		ReadDir2: func(string) ([]fs.DirEntry, error) {
			globbed = true
			return nil, errGlob
		},
	}
	for _, word := range call.Args {
		more, err := expand.Fields(cfg, word)
		if err != nil || globbed {
			return nil, false
		}
		words = append(words, more...)
	}
	return words, true
}

// errGlob stops a glob's expansion: lineWords declines it.
var errGlob = errors.New("a glob")

// rawFilePath is a file: URL's path as written, before its escapes are
// undone: what follows the scheme and authority, up to a fragment or a
// query, which both openers drop.
func rawFilePath(target string) string {
	path := strings.TrimPrefix(target, "file://")
	path, _, _ = strings.Cut(path, "#")
	path, _, _ = strings.Cut(path, "?")
	return path
}
