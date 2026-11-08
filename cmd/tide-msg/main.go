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
// It exits 0 when that worked, or when tidewm exited during a
// subscription, 1 when tidewm refused a command or a subscription, and 2
// for a usage error, or when there's no tidewm to ask or it didn't answer.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"

	"github.com/mikelward/tide/internal/swayipc"
)

func main() {
	os.Exit(run(os.Args[1:], os.Environ(), os.Stdout, os.Stderr))
}

func run(args []string, env []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("tide-msg", flag.ContinueOnError)
	flags.SetOutput(stderr)
	focused := flags.Bool("focused-workspace", false, "print the focused workspace's name")
	prompt := flags.Bool("prompt-may-focus", false, "exit 0 if a polkit prompt may take the keyboard now, 1 if not")
	query := flags.String("type", "", "print the reply to the query `QUERY` (get_outputs, get_config and the rest), as JSON")
	subscribe := flags.String("subscribe", "", "print each of the `EVENTS`, comma-separated, as a line of JSON, until tidewm exits")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	kind, known := swayipc.Queries[*query]
	modes := 0
	for _, on := range []bool{*focused, *prompt, *query != "", *subscribe != "", flags.NArg() > 0} {
		if on {
			modes++
		}
	}
	events := strings.Split(*subscribe, ",")
	if modes != 1 || (*query != "" && !known) || (*subscribe != "" && slices.Contains(events, "")) {
		fmt.Fprintln(stderr, "usage: tide-msg [--] COMMAND...")
		fmt.Fprintln(stderr, "       tide-msg --focused-workspace")
		fmt.Fprintln(stderr, "       tide-msg --prompt-may-focus")
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
	cmd := strings.Join(flags.Args(), " ")
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
