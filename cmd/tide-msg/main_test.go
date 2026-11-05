package main

import (
	"bytes"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/mikelward/quickspace/internal/swayipc/swayipctest"
)

func tideMsg(env []string, args ...string) (int, string, string) {
	var stdout, stderr bytes.Buffer
	status := run(args, env, &stdout, &stderr)
	return status, stdout.String(), stderr.String()
}

func TestACommandThatWorksPrintsNothing(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	status, out, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "grant", "--key", "7", `"a b"`)
	if status != 0 || out != "" || errOut != "" {
		t.Fatalf("status %d, out %q, err %q", status, out, errOut)
	}
	// The arguments are one payload, joined with spaces, as given.
	if got := tidewm.Sent(); !reflect.DeepEqual(got, []swayipctest.Message{{Type: 0, Payload: `grant --key 7 "a b"`}}) {
		t.Fatalf("sent %q", got)
	}
}

func TestArgumentsAfterDashDashAreTheCommand(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	if status, _, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--", "focus", "recent", "foot"); status != 0 {
		t.Fatalf("status %d, err %q", status, errOut)
	}
	if got := tidewm.Payloads(); !reflect.DeepEqual(got, []string{"focus recent foot"}) {
		t.Fatalf("sent %q", got)
	}
}

func TestARefusedCommandSaysWhyAndExits1(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"success":false,"error":"focus recent: no window of foot"}]`)
	status, _, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "focus", "recent", "foot")
	if status != 1 || errOut != "tide-msg: focus recent foot: focus recent: no window of foot\n" {
		t.Fatalf("status %d, err %q", status, errOut)
	}
}

func TestTheFocusedWorkspaceIsPrinted(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"name":"in","focused":false},{"name":"PR 12","focused":true}]`)
	status, out, _ := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--focused-workspace")
	if status != 0 || out != "PR 12\n" {
		t.Fatalf("status %d, out %q", status, out)
	}
	if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 1 {
		t.Fatalf("sent %v, not GET_WORKSPACES", got)
	}
}

func TestNoTidewmExits2(t *testing.T) {
	status, _, errOut := tideMsg(nil, "nop")
	if status != 2 || errOut != "tide-msg: SWAYSOCK isn't set, so there's no tidewm to ask\n" {
		t.Fatalf("status %d, err %q", status, errOut)
	}
	status, _, _ = tideMsg([]string{"SWAYSOCK=" + filepath.Join(t.TempDir(), "gone.sock")}, "nop")
	if status != 2 {
		t.Fatalf("a socket nothing listens on: status %d", status)
	}
}

func TestAQueryPrintsTheReply(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"name":"eDP-1","layers":[]}]`)
	status, out, _ := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--type", "get_outputs")
	if status != 0 || out != `[{"name":"eDP-1","layers":[]}]`+"\n" {
		t.Fatalf("status %d, out %q", status, out)
	}
	if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 3 || got[0].Payload != "" {
		t.Fatalf("sent %v, not GET_OUTPUTS", got)
	}
}

func TestGetBindingsIsTidewmsOwnQuery(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"type":"key","keys":"Mod4+Return","command":"exec foot","mode":"default"}]`)
	status, out, _ := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--type", "get_bindings")
	if status != 0 || !strings.Contains(out, `"Mod4+Return"`) {
		t.Fatalf("status %d, out %q", status, out)
	}
	if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 200 || got[0].Payload != "" {
		t.Fatalf("sent %v, not GET_BINDINGS", got)
	}
}

func TestPromptMayFocusIsTheExitStatus(t *testing.T) {
	for reply, want := range map[string]int{
		`[{"name":"seat0","prompt_may_focus":true}]`:  0,
		`[{"name":"seat0","prompt_may_focus":false}]`: 1,
		`[{"name":"seat0"}]`:                          2, // a tidewm too old to say
	} {
		tidewm := swayipctest.New(t, reply)
		status, out, _ := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--prompt-may-focus")
		if status != want || out != "" {
			t.Errorf("%s: status %d, out %q, want %d", reply, status, out, want)
		}
		if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 101 {
			t.Errorf("%s: sent %v, not GET_SEATS", reply, got)
		}
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"--focused-workspace", "nop"}, {"--nope"}, {"--prompt-may-focus", "--focused-workspace"},
		{"--type", "get_marks"}, {"--type", "get_config", "nop"}, {"--type", "get_config", "--focused-workspace"}} {
		if status, _, _ := tideMsg([]string{"SWAYSOCK=/x"}, args...); status != 2 {
			t.Errorf("%q: status %d", args, status)
		}
	}
}
