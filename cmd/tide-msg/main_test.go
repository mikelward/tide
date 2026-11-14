package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/mikelward/tide/internal/swayipc/swayipctest"
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

func TestGetNamedBindingsIsTidewmsOwnQuery(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"name":"terminal","keys":["Mod4+t"],"default_keys":["Mod4+t"]}]`)
	status, out, _ := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--type", "get_named_bindings")
	if status != 0 || !strings.Contains(out, `"terminal"`) {
		t.Fatalf("status %d, out %q", status, out)
	}
	if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 201 || got[0].Payload != "" {
		t.Fatalf("sent %v, not GET_NAMED_BINDINGS", got)
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

// installed puts a tidewm that says `says` for -v, as dwl does, to stderr
// and exiting 1, in a directory of its own, and returns PATH naming it.
func installed(t *testing.T, says string) string {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\ntest \"$1\" = -v || exit 64\necho '" + says + "' >&2\nexit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "tidewm"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return "PATH=" + dir
}

const version = `{"human_readable":"tidewm v0.3.100","variant":"tidewm","major":0,"minor":3,"patch":100}`

func TestOutdatedIsWhetherTheTidewmRunningIsTheOneInstalled(t *testing.T) {
	tidewm := swayipctest.New(t, version)
	sock := "SWAYSOCK=" + tidewm.Socket
	status, out, errOut := tideMsg([]string{sock, installed(t, "dwl v0.3.108")}, "--outdated")
	if status != 0 || out != "tidewm v0.3.100 is running, and v0.3.108 is installed\n" || errOut != "" {
		t.Errorf("a newer one installed: status %d, out %q, err %q", status, out, errOut)
	}
	for _, same := range []string{"dwl v0.3.100", "tidewm v0.3.100"} {
		if status, out, errOut := tideMsg([]string{sock, installed(t, same)}, "--outdated"); status != 1 || out != "" || errOut != "" {
			t.Errorf("%s installed: status %d, out %q, err %q", same, status, out, errOut)
		}
	}
	// With no tidewm on PATH, there's none newer to log in to.
	if status, out, errOut := tideMsg([]string{sock, "PATH=" + t.TempDir()}, "--outdated"); status != 1 || out != "" || errOut != "" {
		t.Errorf("none installed: status %d, out %q, err %q", status, out, errOut)
	}
	status, _, errOut = tideMsg([]string{sock, installed(t, "error while loading shared libraries")}, "--outdated")
	if status != 2 || !strings.Contains(errOut, "couldn't tell whether tidewm was updated") {
		t.Errorf("an installed one that can't say: status %d, err %q", status, errOut)
	}
	old := swayipctest.New(t, `{"variant":"tidewm"}`)
	status, _, errOut = tideMsg([]string{"SWAYSOCK=" + old.Socket, installed(t, "dwl v0.3.108")}, "--outdated")
	if status != 2 || !strings.Contains(errOut, "couldn't tell whether tidewm was updated") {
		t.Errorf("a running one that doesn't say: status %d, err %q", status, errOut)
	}
}

func TestIfCurrentLeavesAnOutdatedTidewmUnasked(t *testing.T) {
	tidewm := swayipctest.New(t, version, `[{"success":true}]`)
	status, out, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket, installed(t, "dwl v0.3.108")}, "--if-current", "reload")
	if status != 3 || out != "" || !strings.Contains(errOut, "reload wasn't sent: tidewm was updated (v0.3.100 is running, and v0.3.108 is installed)") ||
		!strings.Contains(errOut, "Log out and back in.") {
		t.Fatalf("status %d, out %q, err %q", status, out, errOut)
	}
	if got := tidewm.Payloads(); slices.Contains(got, "reload") {
		t.Fatalf("an outdated tidewm was sent %q", got)
	}
}

func TestIfCurrentRunsTheCommandOnTheTidewmInstalled(t *testing.T) {
	for what, c := range map[string]struct {
		path    string
		replies []string
	}{
		"the same one installed": {installed(t, "dwl v0.3.100"), []string{version, `[{"success":true}]`}},
		// With none on PATH, the one running isn't asked its version.
		"none installed": {"PATH=" + t.TempDir(), []string{`[{"success":true}]`}},
	} {
		tidewm := swayipctest.New(t, c.replies...)
		status, out, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket, c.path}, "--if-current", "reload")
		if status != 0 || out != "" || errOut != "" {
			t.Errorf("%s: status %d, out %q, err %q", what, status, out, errOut)
		}
		if got := tidewm.Payloads(); !slices.Contains(got, "reload") {
			t.Errorf("%s: sent %q, no reload", what, got)
		}
	}
}

func TestIfCurrentRunsTheCommandWhenItCantTell(t *testing.T) {
	tidewm := swayipctest.New(t, `{"variant":"tidewm"}`, `[{"success":true}]`)
	status, _, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket, installed(t, "dwl v0.3.108")}, "--if-current", "reload")
	if status != 0 || !strings.Contains(errOut, "couldn't tell whether tidewm was updated, so reload is sent anyway") {
		t.Fatalf("status %d, err %q", status, errOut)
	}
	if got := tidewm.Payloads(); !slices.Contains(got, "reload") {
		t.Fatalf("sent %q, no reload", got)
	}
}

func TestAPlainReloadIsSentWhateverIsInstalled(t *testing.T) {
	tidewm := swayipctest.New(t, `[{"success":true}]`)
	if status, _, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket, installed(t, "dwl v0.3.108")}, "reload"); status != 0 {
		t.Fatalf("status %d, err %q", status, errOut)
	}
	if got := tidewm.Payloads(); !reflect.DeepEqual(got, []string{"reload"}) {
		t.Fatalf("sent %q", got)
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"--focused-workspace", "nop"}, {"--nope"}, {"--prompt-may-focus", "--focused-workspace"},
		{"--type", "get_marks"}, {"--type", "get_config", "nop"}, {"--type", "get_config", "--focused-workspace"},
		{"--outdated", "nop"}, {"--if-current"}, {"--if-current", "--outdated"}, {"--if-current", "--type", "get_config"},
		{"--subscribe", "input", "nop"}, {"--subscribe", "input", "--type", "get_inputs"}, {"--subscribe", "input,"}} {
		if status, _, _ := tideMsg([]string{"SWAYSOCK=/x"}, args...); status != 2 {
			t.Errorf("%q: status %d", args, status)
		}
	}
}

func TestSubscribePrintsEachEventALineUntilTidewmExits(t *testing.T) {
	tidewm := swayipctest.New(t, `{"success":true}`)
	tidewm.Events(0x80000015, `{"change":"added","input":{}}`, `{"change":"libinput_config","input":{}}`)
	status, out, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--subscribe", "input,shutdown")
	if status != 0 || errOut != "" {
		t.Fatalf("status %d, err %q", status, errOut)
	}
	if want := `{"change":"added","input":{}}` + "\n" + `{"change":"libinput_config","input":{}}` + "\n"; out != want {
		t.Fatalf("out %q", out)
	}
	if got := tidewm.Sent(); len(got) != 1 || got[0].Type != 2 || got[0].Payload != `["input","shutdown"]` {
		t.Fatalf("sent %v, not SUBSCRIBE", got)
	}
}

func TestARefusedSubscriptionExits1(t *testing.T) {
	tidewm := swayipctest.New(t, `{"success":false,"error":"unknown event"}`)
	status, out, errOut := tideMsg([]string{"SWAYSOCK=" + tidewm.Socket}, "--subscribe", "nope")
	if status != 1 || out != "" || !strings.Contains(errOut, "refused a subscription to nope: unknown event") {
		t.Fatalf("status %d, out %q, err %q", status, out, errOut)
	}
}
