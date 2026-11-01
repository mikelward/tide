// Command tide-tabs hands a browser's tabs to tide's switcher (SPEC.md
// §8.3). It has two ends, which meet on a socket only you can reach,
// $XDG_RUNTIME_DIR/tide/tabs.sock:
//
//	tide-tabs serve
//	tide-tabs chrome-extension://ID/
//
// `serve` is the shell's end. The shell starts it and reads one JSON object
// per line from its stdout:
//
//	{"type": "ready", "socket"}         listening
//	{"type": "tabs", "source", "browser", "windows": [{"id", "focused",
//	 "title", "tabs": [{"id", "title", "url", "active"}]}]}
//	                                    one browser's tabs, whole, each time
//	                                    they change; source names it
//	{"type": "gone", "source"}          that browser closed or quit
//	{"type": "fault", "message"}        then it exits 1
//
// The shell writes {"type": "activate", "source", "tabId", "windowId"} to
// its stdin to bring a tab up. It exits 0 when stdin closes.
//
// The other is the browser's end, its native-messaging host: Chrome or
// Brave starts it for tileco, the extension that reads the tabs, passing
// the extension's origin, and talks to it in Chrome's native-messaging
// frames on stdin and stdout. It passes the tabs on to `serve` and the
// asks back, and tells the extension whether the shell is listening,
// trying again whenever it isn't. It exits when the browser closes the
// port. Neither end makes a network call; the tabs never leave the machine.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv))
}

// socketPath is where the two ends meet. TIDE_TABS_SOCKET overrides it.
func socketPath(getenv func(string) string) (string, error) {
	if p := getenv("TIDE_TABS_SOCKET"); p != "" {
		return p, nil
	}
	dir := getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		return "", fmt.Errorf("XDG_RUNTIME_DIR isn't set, so there's no socket only you can reach")
	}
	return filepath.Join(dir, "tide", "tabs.sock"), nil
}

const usage = "usage: tide-tabs serve | tide-tabs chrome-extension://ID/ (as the browser runs it)"

func run(args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) int {
	path, err := socketPath(getenv)
	if err != nil {
		fmt.Fprintf(stderr, "tide-tabs: %v\n", err)
		return 1
	}
	if len(args) == 1 && args[0] == "serve" {
		return runServe(stdin, stdout, stderr, path)
	}
	// Chrome passes the caller's origin, and on Windows a window handle;
	// anything else isn't a browser starting the host.
	if len(args) == 0 || !strings.HasPrefix(args[0], "chrome-extension://") {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	return runHost(stdin, stdout, stderr, hostConfig{
		dial:  func() (net.Conn, error) { return net.Dial("unix", path) },
		after: time.After,
	})
}
