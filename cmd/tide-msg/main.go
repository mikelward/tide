// Command tide-msg talks to tidewm over its IPC, as swaymsg does to sway,
// for tide's scripts in tidewm's session (SPEC.md §5.3). It finds tidewm
// by SWAYSOCK.
//
//	tide-msg [--] COMMAND...
//
// joins its arguments with spaces and runs them as one payload, so the
// caller quotes as tidewm reads a command. It prints nothing when every
// command worked, and each error when one didn't.
//
//	tide-msg --focused-workspace
//
// prints the focused workspace's name.
//
//	tide-msg --prompt-may-focus
//
// exits 0 if a polkit prompt opening now may take the keyboard, by
// tidewm's focus guard, and 1 if not, for tide prompt-focus.
//
//	tide-msg --type QUERY
//
// prints the reply to a query, as JSON: get_workspaces, get_outputs,
// get_tree, get_version, get_config, get_inputs or get_seats, as swaymsg
// names them, or tidewm's own get_bindings and get_named_bindings. tide
// doctor reads tidewm's outputs and config errors so, and the shell its
// bindings.
//
//	tide-msg --subscribe EVENTS
//
// prints each of the events named, comma-separated, such as input, as a
// line of JSON as it comes, as swaymsg -t subscribe -m does, until tidewm
// exits. watch-input.sh follows input devices so.
//
//	tide-msg --outdated
//
// exits 0 if the tidewm running isn't the one installed, the `tidewm` on
// PATH, as after a setup run that built a newer one, saying both
// versions; 1 if it is, or none is installed; and 2 if it can't tell. The
// one running stays until its session ends, and may not read a config
// written for the new one (SPEC.md §7.4).
//
//	tide-msg --if-current COMMAND...
//
// runs the command only if --outdated wouldn't exit 0, and otherwise says
// why not and exits 3. tide reloads tidewm's config so: an older tidewm
// drops each line it doesn't know, key bindings among them.
//
// It exits 0 when that worked, or when tidewm exited during a
// subscription, 1 when tidewm refused a command or a subscription, and 2
// for a usage error, or when there's no tidewm to ask or it didn't answer.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/mikelward/tide/internal/swayipc"
)

func main() {
	os.Exit(run(os.Args[1:], os.Environ(), os.Stdout, os.Stderr))
}

// notCurrent is --if-current's exit status when it didn't send the command.
const notCurrent = 3

// runningVersion is what the tidewm at socket calls its version:
// GET_VERSION's human_readable, "tidewm v0.3.120", without the name.
func runningVersion(socket string) (string, error) {
	reply, err := swayipc.Send(socket, swayipc.Queries["get_version"], nil)
	if err != nil {
		return "", fmt.Errorf("couldn't ask tidewm at %s for its version: %v", socket, err)
	}
	var version struct {
		HumanReadable string `json:"human_readable"`
	}
	if err := json.Unmarshal(reply, &version); err != nil {
		return "", fmt.Errorf("tidewm's version isn't JSON: %v", err)
	}
	name, rest, _ := strings.Cut(version.HumanReadable, " ")
	if name != "tidewm" || rest == "" {
		return "", fmt.Errorf("tidewm's version is %q, not \"tidewm VERSION\"", version.HumanReadable)
	}
	return rest, nil
}

// installedVersion is what the tidewm on env's PATH calls its version, or
// "" if there's none there. `tidewm -v` prints "dwl VERSION" to stderr
// and exits 1, being dwl's (mikelward/tidewm's dwl.c, 2026-11); "tidewm
// VERSION" is taken too, should it come to say its own name. Both come
// from the one VERSION the binary was built with, so the same build says
// the same over IPC.
func installedVersion(env []string) (string, error) {
	var path string
	for _, e := range env {
		if dirs, ok := strings.CutPrefix(e, "PATH="); ok {
			for _, dir := range filepath.SplitList(dirs) {
				file := filepath.Join(dir, "tidewm")
				if info, err := os.Stat(file); dir != "" && err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
					path = file
					break
				}
			}
		}
	}
	if path == "" {
		return "", nil
	}
	cmd := exec.Command(path, "-v")
	cmd.Env = env
	// It exits 1 having said its version, so only what it says counts.
	out, err := cmd.CombinedOutput()
	line, _, _ := strings.Cut(string(out), "\n")
	name, rest, _ := strings.Cut(strings.TrimSpace(line), " ")
	if (name != "dwl" && name != "tidewm") || rest == "" {
		if line == "" && err != nil {
			return "", fmt.Errorf("couldn't run %s -v: %v", path, err)
		}
		return "", fmt.Errorf("%s -v said %q, not its version", path, line)
	}
	return rest, nil
}

// outdated is whether the tidewm running isn't the one installed, and
// both versions. With none installed there's nothing newer to run.
func outdated(socket string, env []string) (bool, string, string, error) {
	installed, err := installedVersion(env)
	if err != nil || installed == "" {
		return false, "", installed, err
	}
	running, err := runningVersion(socket)
	if err != nil {
		return false, "", installed, err
	}
	return running != installed, running, installed, nil
}

func run(args []string, env []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("tide-msg", flag.ContinueOnError)
	flags.SetOutput(stderr)
	focused := flags.Bool("focused-workspace", false, "print the focused workspace's name")
	prompt := flags.Bool("prompt-may-focus", false, "exit 0 if a polkit prompt may take the keyboard now, 1 if not")
	query := flags.String("type", "", "print the reply to the query `QUERY` (get_outputs, get_config and the rest), as JSON")
	subscribe := flags.String("subscribe", "", "print each of the `EVENTS`, comma-separated, as a line of JSON, until tidewm exits")
	isOutdated := flags.Bool("outdated", false, "exit 0 if the tidewm running isn't the one installed, 1 if it is")
	ifCurrent := flags.Bool("if-current", false, "run the command only if the tidewm running is the one installed; exit 3 if not")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	kind, known := swayipc.Queries[*query]
	modes := 0
	for _, on := range []bool{*focused, *prompt, *isOutdated, *query != "", *subscribe != "", flags.NArg() > 0} {
		if on {
			modes++
		}
	}
	events := strings.Split(*subscribe, ",")
	if modes != 1 || (*query != "" && !known) || (*subscribe != "" && slices.Contains(events, "")) || (*ifCurrent && flags.NArg() == 0) {
		fmt.Fprintln(stderr, "usage: tide-msg [--if-current] [--] COMMAND...")
		fmt.Fprintln(stderr, "       tide-msg --focused-workspace")
		fmt.Fprintln(stderr, "       tide-msg --prompt-may-focus")
		fmt.Fprintln(stderr, "       tide-msg --outdated")
		fmt.Fprintln(stderr, "       tide-msg --type get_workspaces|get_outputs|get_tree|get_version|get_config|get_inputs|get_seats|get_bindings|get_named_bindings")
		fmt.Fprintln(stderr, "       tide-msg --subscribe EVENT[,EVENT...]")
		return 2
	}
	socket, err := swayipc.Socket(env)
	if err != nil {
		fmt.Fprintf(stderr, "tide-msg: %v\n", err)
		return 2
	}
	if *prompt {
		may, err := swayipc.PromptMayFocus(socket)
		if err != nil {
			fmt.Fprintf(stderr, "tide-msg: couldn't ask tidewm at %s whether a prompt may take the keyboard: %v\n", socket, err)
			return 2
		}
		if may {
			return 0
		}
		return 1
	}
	if *focused {
		name, err := swayipc.FocusedWorkspace(socket)
		if err != nil {
			fmt.Fprintf(stderr, "tide-msg: couldn't read the focused workspace from %s: %v\n", socket, err)
			return 2
		}
		fmt.Fprintln(stdout, name)
		return 0
	}
	if *subscribe != "" {
		err := swayipc.Subscribe(socket, events, func(payload []byte) error {
			_, err := fmt.Fprintf(stdout, "%s\n", payload)
			return err
		})
		var refused swayipc.Refused
		if errors.As(err, &refused) {
			fmt.Fprintf(stderr, "tide-msg: tidewm at %s refused a subscription to %s: %v\n", socket, *subscribe, err)
			return 1
		}
		if err != nil {
			fmt.Fprintf(stderr, "tide-msg: couldn't follow tidewm's %s events at %s: %v\n", *subscribe, socket, err)
			return 2
		}
		return 0
	}
	if *query != "" {
		reply, err := swayipc.Send(socket, kind, nil)
		if err != nil {
			fmt.Fprintf(stderr, "tide-msg: couldn't ask tidewm at %s for %s: %v\n", socket, *query, err)
			return 2
		}
		fmt.Fprintln(stdout, string(reply))
		return 0
	}
	if *isOutdated {
		is, running, installed, err := outdated(socket, env)
		if err != nil {
			fmt.Fprintf(stderr, "tide-msg: couldn't tell whether tidewm was updated: %v\n", err)
			return 2
		}
		if !is {
			return 1
		}
		fmt.Fprintf(stdout, "tidewm %s is running, and %s is installed\n", running, installed)
		return 0
	}
	cmd := strings.Join(flags.Args(), " ")
	if *ifCurrent {
		is, running, installed, err := outdated(socket, env)
		if err != nil {
			// Not known to be older, so it's asked, as it would be
			// without --if-current.
			fmt.Fprintf(stderr, "tide-msg: couldn't tell whether tidewm was updated, so %s is sent anyway: %v\n", cmd, err)
		} else if is {
			fmt.Fprintf(stderr, "tide-msg: %s wasn't sent: tidewm was updated (%s is running, and %s is installed), and the one running may not read the new one's config. Log out and back in.\n", cmd, running, installed)
			return notCurrent
		}
	}
	if err := swayipc.Command(socket, cmd); err != nil {
		var refused swayipc.Refused
		if errors.As(err, &refused) {
			fmt.Fprintf(stderr, "tide-msg: %s: %v\n", cmd, err)
			return 1
		}
		fmt.Fprintf(stderr, "tide-msg: couldn't ask tidewm at %s: %v\n", socket, err)
		return 2
	}
	return 0
}
