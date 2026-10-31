package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeFile(t *testing.T, path, body string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
}

func TestFindPlugin(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	writeFile(t, filepath.Join(first, "openvpn.name"), `[VPN Connection]
service=org.freedesktop.NetworkManager.openvpn

[GNOME]
auth-dialog=/usr/libexec/nm-openvpn-auth-dialog
supports-external-ui-mode=true
supports-hints=true
`, 0o644)
	writeFile(t, filepath.Join(second, "openvpn.name"), "[VPN Connection]\nservice=org.freedesktop.NetworkManager.openvpn\n[GNOME]\nauth-dialog=/elsewhere\n", 0o644)
	writeFile(t, filepath.Join(second, "oc.name"), "[VPN Connection]\nservice=org.example.oc\naliases=org.example.oc.old;\n[GNOME]\nauth-dialog=/usr/libexec/oc-dialog\n", 0o644)
	writeFile(t, filepath.Join(second, "bad.name"), "[VPN Connection]\nservice=org.example.bad\n[GNOME]\nauth-dialog=relative\n", 0o644)
	dirs := []string{first, second}

	p, err := findPlugin(dirs, "org.freedesktop.NetworkManager.openvpn")
	if err != nil {
		t.Fatal(err)
	}
	if p.authDialog != "/usr/libexec/nm-openvpn-auth-dialog" || !p.externalUI || !p.hints {
		t.Errorf("the first directory should win: %+v", p)
	}
	p, err = findPlugin(dirs, "org.example.oc.old")
	if err != nil || p.authDialog != "/usr/libexec/oc-dialog" || p.externalUI || p.hints {
		t.Errorf("by alias: %+v, %v", p, err)
	}
	if _, err := findPlugin(dirs, "org.example.bad"); err == nil {
		t.Error("a relative auth-dialog should be an error")
	}
	if _, err := findPlugin(dirs, "org.example.none"); err == nil {
		t.Error("no plugin should be an error")
	}
}

func TestDialogArgs(t *testing.T) {
	conn := settings{
		"connection": {"id": v("Work VPN"), "uuid": v("u-3")},
		"vpn":        {"service-type": v("org.example.vpn")},
	}
	got := dialogArgs(plugin{externalUI: true, hints: true}, conn, []string{"x-vpn-message:Code", "otp"}, flagAllowInteraction|flagRequestNew)
	want := []string{"-u", "u-3", "-n", "Work VPN", "-s", "org.example.vpn", "--external-ui-mode", "-i", "-r", "-t", "x-vpn-message:Code", "-t", "otp"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("args = %q\nwant %q", got, want)
	}
	got = dialogArgs(plugin{}, conn, []string{"otp"}, 0)
	want = []string{"-u", "u-3", "-n", "Work VPN", "-s", "org.example.vpn"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("without hints or interaction: %q", got)
	}
}

func TestDialogInput(t *testing.T) {
	got := string(dialogInput(map[string]string{"remote": "vpn.example.com", "a": "1"}, map[string]string{"password": "p"}))
	want := "DATA_KEY=a\nDATA_VAL=1\n\nDATA_KEY=remote\nDATA_VAL=vpn.example.com\n\nSECRET_KEY=password\nSECRET_VAL=p\n\nDONE\n\n"
	if got != want {
		t.Errorf("input = %q", got)
	}
}

func TestParseExternalUI(t *testing.T) {
	ui, err := parseExternalUI([]byte(`[VPN Plugin UI]
Version=2
Title=Authenticate VPN
Description=Sign in to Work VPN.

[password]
Value=saved
Label=Password:
IsSecret=true
ShouldAsk=true

[challenge-response]
Value=
Label=Code:
IsSecret=false
ShouldAsk=true

[cert-pass]
Value=kept
ShouldAsk=false

[empty]
Value=
ShouldAsk=false
`))
	if err != nil {
		t.Fatal(err)
	}
	if ui.title != "Authenticate VPN" || ui.message != "Sign in to Work VPN." {
		t.Errorf("title %q, message %q", ui.title, ui.message)
	}
	// In the file's order.
	wantFields := []field{
		{Key: "password", Label: "Password:", Secret: true, Value: "saved"},
		{Key: "challenge-response", Label: "Code:", Secret: false, Value: ""},
	}
	if !reflect.DeepEqual(ui.fields, wantFields) {
		t.Errorf("fields %+v", ui.fields)
	}
	if !reflect.DeepEqual(ui.given, map[string]string{"cert-pass": "kept"}) {
		t.Errorf("given %v", ui.given)
	}
	ui, err = parseExternalUI(nil)
	if err != nil || len(ui.fields) != 0 {
		t.Errorf("no output means everything is saved: %+v, %v", ui, err)
	}
	if _, err := parseExternalUI([]byte("[VPN Plugin UI]\nVersion=1\n")); err == nil {
		t.Error("version 1 should be an error")
	}
}

// Each case against what GNOME Shell's _showNewStyleDialog makes of it.
func TestParseExternalUIStrictly(t *testing.T) {
	const head = "[VPN Plugin UI]\nVersion=2\nTitle=T\nDescription=D\n"
	for _, tc := range []struct {
		name   string
		out    string
		fields []field
		given  map[string]string
		bad    bool
	}{
		{"a value's trailing space is kept", head + "[p]\nValue=pass \nShouldAsk=false\n", nil, map[string]string{"p": "pass "}, false},
		{"a value's leading space needs \\s", head + "[p]\nValue=  \\spass\nShouldAsk=false\n", nil, map[string]string{"p": " pass"}, false},
		{"escapes", head + "[p]\nValue=a\\tb\\nc\\rd\\\\e\nShouldAsk=false\n", nil, map[string]string{"p": "a\tb\nc\rd\\e"}, false},
		{"fields keep the file's order", head + "[z]\nValue=\nShouldAsk=true\nLabel=Z\nIsSecret=true\n[a]\nValue=\nShouldAsk=true\nLabel=A\nIsSecret=false\n",
			[]field{{Key: "z", Label: "Z", Secret: true}, {Key: "a", Label: "A"}}, map[string]string{}, false},
		{"booleans are true, false, 1 or 0, trailing space allowed", head + "[a]\nValue=v\nShouldAsk=1 \nLabel=A\nIsSecret=0\n",
			[]field{{Key: "a", Label: "A", Value: "v"}}, map[string]string{}, false},
		{"comments, blank lines and indentation", "  # c\n\n" + head + "\t[p]\n  Value = v\n # x\nShouldAsk=false\n", nil, map[string]string{"p": "v"}, false},
		{"CRLF line ends", strings.ReplaceAll(head+"[p]\nValue=v\nShouldAsk=false\n", "\n", "\r\n"), nil, map[string]string{"p": "v"}, false},
		{"a translated label is a key of its own", head + "[a]\nValue=\nShouldAsk=true\nLabel[de]=Passwort\nLabel=Password\nIsSecret=true\n",
			[]field{{Key: "a", Label: "Password", Secret: true}}, map[string]string{}, false},
		{"a later key replaces an earlier", head + "[p]\nValue=1\nValue=2\nShouldAsk=false\n", nil, map[string]string{"p": "2"}, false},
		{"a group named twice is one group", head + "[p]\nValue=v\n[q]\nValue=w\nShouldAsk=false\n[p]\nShouldAsk=false\n", nil, map[string]string{"p": "v", "q": "w"}, false},
		{"spaces after a group's ] are fine", strings.Replace(head, "[VPN Plugin UI]", "[VPN Plugin UI]  \t", 1) + "[p]\nValue=v\nShouldAsk=false\n", nil, map[string]string{"p": "v"}, false},
		{"yes isn't a boolean", head + "[p]\nValue=v\nShouldAsk=yes\n", nil, nil, true},
		{"ShouldAsk missing", head + "[p]\nValue=v\n", nil, nil, true},
		{"Value missing", head + "[p]\nShouldAsk=false\n", nil, nil, true},
		{"Label missing on a field to ask", head + "[p]\nValue=\nShouldAsk=true\nIsSecret=true\n", nil, nil, true},
		{"IsSecret missing on a field to ask", head + "[p]\nValue=\nShouldAsk=true\nLabel=P\n", nil, nil, true},
		{"Title missing", "[VPN Plugin UI]\nVersion=2\nDescription=D\n", nil, nil, true},
		{"an unknown escape", head + "[p]\nValue=a\\qb\nShouldAsk=false\n", nil, nil, true},
		{"an escape at the end", head + "[p]\nValue=a\\\nShouldAsk=false\n", nil, nil, true},
		{"a key before any group", "Version=2\n" + head, nil, nil, true},
		{"a line that's none of the three", head + "[p]\njunk\n", nil, nil, true},
		{"an empty key", head + "[p]\n=v\n", nil, nil, true},
		{"a key with a ]", head + "[p]\na]b=v\n", nil, nil, true},
		{"an empty group name", head + "[]\n", nil, nil, true},
		{"text after a group's ]", head + "[p] x\n", nil, nil, true},
		{"whitespace alone isn't empty output", " \n", nil, nil, true},
		{"a Version that isn't a number", "[VPN Plugin UI]\nVersion=two\nTitle=T\nDescription=D\n", nil, nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ui, err := parseExternalUI([]byte(tc.out))
			if tc.bad {
				if err == nil {
					t.Errorf("no error; got %+v", ui)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(ui.fields, tc.fields) || !reflect.DeepEqual(ui.given, tc.given) {
				t.Errorf("fields %+v, given %q; want %+v, %q", ui.fields, ui.given, tc.fields, tc.given)
			}
		})
	}
}

func TestFindPluginSkipsBrokenFiles(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "a-broken.name"), "not a key file\n", 0o644)
	writeFile(t, filepath.Join(dir, "b.name"), "[VPN Connection]\nservice=org.example.b\n[GNOME]\nauth-dialog=/usr/libexec/b\\sdialog\n", 0o644)
	p, err := findPlugin([]string{dir}, "org.example.b")
	if err != nil || p.authDialog != "/usr/libexec/b dialog" {
		t.Errorf("%+v, %v", p, err)
	}
	_, err = findPlugin([]string{dir}, "org.example.none")
	if err == nil || !strings.Contains(err.Error(), "a-broken.name") {
		t.Errorf("a broken file should be named when nothing's found: %v", err)
	}
}

// A dialog that records how it was run, in $1's directory.
func fakeDialog(t *testing.T, body func(dir string) string) (plugin, string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "dialog")
	writeFile(t, script, "#!/bin/sh\nprintf '%s\\n' \"$@\" > "+filepath.Join(dir, "args")+"\n"+body(dir), 0o755)
	return plugin{authDialog: script}, dir
}

func TestRunExternal(t *testing.T) {
	p, dir := fakeDialog(t, func(dir string) string {
		return "cat > " + filepath.Join(dir, "stdin") + "\nprintf '[VPN Plugin UI]\\nVersion=2\\n'\n"
	})
	out, err := runExternal(context.Background(), p, []string{"-u", "u"}, []byte("DONE\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "[VPN Plugin UI]\nVersion=2\n" {
		t.Errorf("out %q", out)
	}
	in, _ := os.ReadFile(filepath.Join(dir, "stdin"))
	args, _ := os.ReadFile(filepath.Join(dir, "args"))
	if string(in) != "DONE\n\n" || string(args) != "-u\nu\n" {
		t.Errorf("stdin %q, args %q", in, args)
	}
	p, _ = fakeDialog(t, func(string) string { return "exit 3\n" })
	if _, err := runExternal(context.Background(), p, nil, nil); err == nil {
		t.Error("a failing dialog should be an error")
	}
}

func TestRunOwnWindow(t *testing.T) {
	// It answers, then waits for QUIT before exiting, as auth dialogs do.
	p, dir := fakeDialog(t, func(dir string) string {
		return `while read -r line; do test "$line" = DONE && break; done
read -r blank
printf 'password\nsecret\nuser\nalice\n\n\n'
read -r quit
echo "$quit" > ` + filepath.Join(dir, "quit") + "\n"
	})
	values, err := runOwnWindow(context.Background(), p, nil, []byte("DATA_KEY=a\nDATA_VAL=b\n\nDONE\n\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(values, map[string]string{"password": "secret", "user": "alice"}) {
		t.Errorf("values %v", values)
	}
	quit, _ := os.ReadFile(filepath.Join(dir, "quit"))
	if strings.TrimSpace(string(quit)) != "QUIT" {
		t.Errorf("told %q, want QUIT", quit)
	}

	p, _ = fakeDialog(t, func(string) string { return "while read -r line; do test \"$line\" = DONE && break; done\nexit 1\n" })
	if _, err := runOwnWindow(context.Background(), p, nil, []byte("DONE\n\n")); !errors.Is(err, errDialogCanceled) {
		t.Errorf("a non-zero exit is a cancel: %v", err)
	}
}

func TestParseOwnWindow(t *testing.T) {
	for _, tc := range []struct {
		name  string
		out   string
		want  map[string]string
		quits int
	}{
		{"pairs, then the end", "password\nsecret\n\n\n", map[string]string{"password": "secret"}, 1},
		{"an empty value is kept", "optional\n\npassword\ncorrect\n\n\n", map[string]string{"optional": "", "password": "correct"}, 1},
		{"spaces in a value are kept", "password\n  pass word  \n\n\n", map[string]string{"password": "  pass word  "}, 1},
		{"a carriage return is part of the line, as read_line keeps it", "password\nsecret\r\n\n\n", map[string]string{"password": "secret\r"}, 1},
		{"no end before EOF", "password\nsecret\n", map[string]string{"password": "secret"}, 0},
		{"a last line with no newline", "password\nsecret", map[string]string{"password": "secret"}, 0},
		{"an empty key with a value is a pair", "\nvalue\n\n\n", map[string]string{"": "value"}, 1},
		{"a later value replaces an earlier", "k\n1\nk\n2\n\n\n", map[string]string{"k": "2"}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			quits := 0
			got, err := parseOwnWindow(strings.NewReader(tc.out), func() { quits++ })
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tc.want) || quits != tc.quits {
				t.Errorf("values = %q, quits = %d; want %q, %d", got, quits, tc.want, tc.quits)
			}
		})
	}
}
