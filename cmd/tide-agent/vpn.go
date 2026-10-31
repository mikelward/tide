package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// VPN plugins, found as libnm finds them (nm-vpn-plugin-info.c,
// NetworkManager 1.54.3): a .name file per plugin in $NM_VPN_PLUGIN_DIR,
// /etc/NetworkManager/VPN and /usr/lib/NetworkManager/VPN, the first
// naming a service winning.
func pluginDirs() []string {
	var dirs []string
	if d := os.Getenv("NM_VPN_PLUGIN_DIR"); d != "" {
		dirs = append(dirs, d)
	}
	return append(dirs, "/etc/NetworkManager/VPN", "/usr/lib/NetworkManager/VPN")
}

type plugin struct {
	file       string
	authDialog string
	externalUI bool
	hints      bool
}

// truthy is how GNOME Shell reads a plugin's supports-external-ui-mode
// (networkAgent.js): trimmed, any case.
func truthy(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true", "yes", "on", "1":
		return true
	}
	return false
}

// findPlugin is the plugin whose service, or one of its aliases, is
// service. A .name file that won't load is skipped, as libnm skips one,
// and named if no other plugin is found.
func findPlugin(dirs []string, service string) (plugin, error) {
	var skipped []string
	for _, dir := range dirs {
		names, err := filepath.Glob(filepath.Join(dir, "*.name"))
		if err != nil {
			return plugin{}, err
		}
		sort.Strings(names)
		for _, name := range names {
			p, match, err := readPlugin(name, service)
			if err != nil {
				skipped = append(skipped, err.Error())
				continue
			}
			if match {
				return p, nil
			}
		}
	}
	msg := fmt.Sprintf("no VPN plugin for %s in %s", service, strings.Join(dirs, ", "))
	if len(skipped) > 0 {
		msg += " (skipped: " + strings.Join(skipped, "; ") + ")"
	}
	return plugin{}, errors.New(msg)
}

func readPlugin(name, service string) (plugin, bool, error) {
	data, err := os.ReadFile(name)
	if err != nil {
		return plugin{}, false, fmt.Errorf("couldn't read %s: %w", name, err)
	}
	kf, err := parseKeyFile(data)
	if err != nil {
		return plugin{}, false, fmt.Errorf("%s: %w", name, err)
	}
	svc, err := kf.optional("VPN Connection", "service")
	if err != nil {
		return plugin{}, false, fmt.Errorf("%s: %w", name, err)
	}
	aliases, err := kf.optional("VPN Connection", "aliases")
	if err != nil {
		return plugin{}, false, fmt.Errorf("%s: %w", name, err)
	}
	match := svc == service
	for _, a := range strings.Split(aliases, ";") {
		match = match || (a != "" && a == service)
	}
	if !match {
		return plugin{}, false, nil
	}
	p := plugin{file: name}
	var external, hints string
	for _, f := range []struct {
		key string
		to  *string
	}{{"auth-dialog", &p.authDialog}, {"supports-external-ui-mode", &external}, {"supports-hints", &hints}} {
		if *f.to, err = kf.optional("GNOME", f.key); err != nil {
			return plugin{}, false, fmt.Errorf("%s: %w", name, err)
		}
	}
	p.externalUI, p.hints = truthy(external), truthy(hints)
	if p.authDialog == "" {
		return plugin{}, false, fmt.Errorf("%s names no auth-dialog", name)
	}
	if !filepath.IsAbs(p.authDialog) {
		return plugin{}, false, fmt.Errorf("%s's auth-dialog %s isn't an absolute path", name, p.authDialog)
	}
	return p, true, nil
}

// dialogArgs is how GNOME Shell runs an auth dialog (networkAgent.js,
// GNOME Shell 51.1).
func dialogArgs(p plugin, conn settings, hints []string, flags uint32) []string {
	c := info(conn)
	args := []string{"-u", c.UUID, "-n", c.ID, "-s", str(conn["vpn"], "service-type")}
	if p.externalUI {
		args = append(args, "--external-ui-mode")
	}
	if flags&flagAllowInteraction != 0 {
		args = append(args, "-i")
	}
	if flags&flagRequestNew != 0 {
		args = append(args, "-r")
	}
	if p.hints {
		for _, h := range hints {
			args = append(args, "-t", h)
		}
	}
	return args
}

// dialogInput is the connection as the dialog reads it on stdin.
func dialogInput(data, secrets map[string]string) []byte {
	var b bytes.Buffer
	for _, k := range sortedKeys(data) {
		fmt.Fprintf(&b, "DATA_KEY=%s\nDATA_VAL=%s\n\n", k, data[k])
	}
	for _, k := range sortedKeys(secrets) {
		fmt.Fprintf(&b, "SECRET_KEY=%s\nSECRET_VAL=%s\n\n", k, secrets[k])
	}
	b.WriteString("DONE\n\n")
	return b.Bytes()
}

func sortedKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// The external UI's description of what to ask (Version=2): the values to
// pass on as they are, and the fields to ask for.
type externalUI struct {
	title, message string
	given          map[string]string
	fields         []field
}

// parseExternalUI reads it as GNOME Shell's _showNewStyleDialog does:
// strictly, every key it reads being there and well formed, its groups in
// the file's order. Output that's empty means everything is saved; any
// other output it can't read is an error.
func parseExternalUI(out []byte) (externalUI, error) {
	ui := externalUI{given: map[string]string{}}
	if len(out) == 0 {
		return ui, nil
	}
	kf, err := parseKeyFile(out)
	if err != nil {
		return ui, err
	}
	const head = "VPN Plugin UI"
	version, err := kf.integer(head, "Version")
	if err != nil {
		return ui, err
	}
	if version != 2 {
		return ui, fmt.Errorf("the dialog's description is version %d, not 2", version)
	}
	if ui.title, err = kf.str(head, "Title"); err != nil {
		return ui, err
	}
	if ui.message, err = kf.str(head, "Description"); err != nil {
		return ui, err
	}
	for _, g := range kf.groups {
		if g == head {
			continue
		}
		value, err := kf.str(g, "Value")
		if err != nil {
			return ui, err
		}
		ask, err := kf.boolean(g, "ShouldAsk")
		if err != nil {
			return ui, err
		}
		if !ask {
			if value != "" {
				ui.given[g] = value
			}
			continue
		}
		label, err := kf.str(g, "Label")
		if err != nil {
			return ui, err
		}
		secret, err := kf.boolean(g, "IsSecret")
		if err != nil {
			return ui, err
		}
		ui.fields = append(ui.fields, field{Key: g, Label: label, Secret: secret, Value: value})
	}
	return ui, nil
}

// The most a dialog may print: a few fields' worth.
const maxDialogOutput = 1 << 20

// runExternal runs a dialog in external UI mode, which prints its fields
// and exits without drawing anything.
func runExternal(ctx context.Context, p plugin, args []string, input []byte) ([]byte, error) {
	cmd := exec.CommandContext(ctx, p.authDialog, args...)
	cmd.Stdin = bytes.NewReader(input)
	var out bytes.Buffer
	cmd.Stdout = &limitWriter{w: &out, n: maxDialogOutput}
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s: %w", p.authDialog, err)
	}
	return out.Bytes(), nil
}

type limitWriter struct {
	w io.Writer
	n int
}

func (l *limitWriter) Write(b []byte) (int, error) {
	if len(b) > l.n {
		return 0, errors.New("the dialog printed more than any dialog does")
	}
	l.n -= len(b)
	return l.w.Write(b)
}

// errDialogCanceled is a dialog that exited non-zero: you closed it.
var errDialogCanceled = errors.New("the dialog was canceled")

// runOwnWindow runs a dialog that draws its own window. It answers with a
// key line and a value line per secret, then two blank lines, after which
// it's told QUIT (networkAgent.js's old style).
func runOwnWindow(ctx context.Context, p plugin, args []string, input []byte) (map[string]string, error) {
	cmd := exec.CommandContext(ctx, p.authDialog, args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("couldn't run %s: %w", p.authDialog, err)
	}
	if _, err := stdin.Write(input); err != nil {
		// Its exit, below, says why.
		fmt.Fprintf(os.Stderr, "tide-agent: couldn't write the connection to %s: %v\n", p.authDialog, err)
	}
	values, readErr := parseOwnWindow(io.LimitReader(stdout, maxDialogOutput), func() {
		if _, err := io.WriteString(stdin, "QUIT\n\n"); err != nil {
			fmt.Fprintf(os.Stderr, "tide-agent: couldn't tell %s to quit: %v\n", p.authDialog, err)
		}
	})
	stdin.Close()
	if err := cmd.Wait(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return nil, errDialogCanceled
		}
		return nil, fmt.Errorf("%s: %w", p.authDialog, err)
	}
	if readErr != nil {
		return nil, fmt.Errorf("couldn't read %s's answer: %w", p.authDialog, readErr)
	}
	return values, nil
}

// parseOwnWindow reads a dialog's answer as GNOME Shell does
// (_vpnChildProcessLineOldStyle): lines split at "\n" alone, as
// GDataInputStream's read_line does, in pairs, a key then its value, which
// may be empty. An empty key with an empty value is the end, at which quit
// is called.
func parseOwnWindow(r io.Reader, quit func()) (map[string]string, error) {
	values := map[string]string{}
	in := bufio.NewReader(r)
	var key *string
	for {
		line, err := in.ReadString('\n')
		if err != nil && line == "" {
			if errors.Is(err, io.EOF) {
				return values, nil
			}
			return values, err
		}
		line = strings.TrimSuffix(line, "\n")
		if key == nil {
			k := line
			key = &k
			continue
		}
		if *key == "" && line == "" {
			quit()
		} else {
			values[*key] = line
		}
		key = nil
	}
}
