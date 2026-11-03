// tide-pick asks the desktop portal's file chooser for one file and prints
// its path: xdg-desktop-portal's FileChooser, which xdg-desktop-portal-gtk
// serves with GTK's dialog, so it looks as every other app's does (SPEC.md
// §2). The settings panel's Appearance page runs it to choose a wallpaper
// (SPEC.md §16).
//
//	tide-pick [--title TITLE] [--folder DIR] [--images]
//
// It exits 0 having printed the path, or nothing when the chooser is
// cancelled, which is no failure; and 2 with what went wrong on stderr.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"

	"github.com/godbus/dbus/v5"
)

const (
	portalName   = "org.freedesktop.portal.Desktop"
	portalPath   = dbus.ObjectPath("/org/freedesktop/portal/desktop")
	chooserIface = "org.freedesktop.portal.FileChooser"
	requestIface = "org.freedesktop.portal.Request"
	requestRoot  = dbus.ObjectPath("/org/freedesktop/portal/desktop/request")
)

// The chooser was closed without a file.
var errCancelled = errors.New("cancelled")

// A filter's rule: by glob (0) or MIME type (1), as the portal takes them.
type rule struct {
	Kind    uint32
	Pattern string
}

type filter struct {
	Name  string
	Rules []rule
}

// What to ask the chooser.
type ask struct {
	title  string
	folder string
	images bool
	// The request's token, which names the object its answer comes from.
	token string
}

// The object the portal answers on, for a request from `sender` with
// `token`, as its documentation has it.
func requestPath(sender, token string) dbus.ObjectPath {
	name := strings.ReplaceAll(strings.TrimPrefix(sender, ":"), ".", "_")
	return dbus.ObjectPath(string(requestRoot) + "/" + name + "/" + token)
}

func options(a ask) map[string]dbus.Variant {
	opts := map[string]dbus.Variant{
		"handle_token": dbus.MakeVariant(a.token),
		"modal":        dbus.MakeVariant(true),
	}
	if a.images {
		images := filter{Name: "Images", Rules: []rule{{Kind: 1, Pattern: "image/*"}}}
		opts["filters"] = dbus.MakeVariant([]filter{images})
		opts["current_filter"] = dbus.MakeVariant(images)
	}
	if a.folder != "" {
		// A byte string with its NUL, as the portal takes a path.
		opts["current_folder"] = dbus.MakeVariant(append([]byte(a.folder), 0))
	}
	return opts
}

// The local path a file:// URI names.
func pathOf(uri string) (string, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return "", fmt.Errorf("the chooser answered %q, which isn't a URI: %w", uri, err)
	}
	if u.Scheme != "file" || u.Path == "" {
		return "", fmt.Errorf("the chooser answered %q, which isn't a file on this machine", uri)
	}
	return u.Path, nil
}

// pick asks the portal on `conn` for a file, and waits for the answer.
func pick(conn *dbus.Conn, a ask) (string, error) {
	signals := make(chan *dbus.Signal, 8)
	conn.Signal(signals)
	defer conn.RemoveSignal(signals)
	// Every request's answer, heard from before asking, so one can't come
	// first: a portal older than handle_token answers on a path it names
	// only as it returns. The handle it returns picks out ours.
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(requestIface), dbus.WithMatchMember("Response"),
		dbus.WithMatchPathNamespace(requestRoot)); err != nil {
		return "", fmt.Errorf("can't listen for the file chooser: %w", err)
	}
	// The portal going away mid-request answers nothing, so that ends it.
	if err := conn.AddMatchSignal(dbus.WithMatchSender("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, portalName)); err != nil {
		return "", fmt.Errorf("can't watch the desktop portal: %w", err)
	}
	var handle dbus.ObjectPath
	err := conn.Object(portalName, portalPath).Call(chooserIface+".OpenFile", 0, "", a.title, options(a)).Store(&handle)
	if err != nil {
		return "", fmt.Errorf("the desktop portal's file chooser (xdg-desktop-portal-gtk) didn't open: %w", err)
	}
	for s := range signals {
		if s.Name == "org.freedesktop.DBus.NameOwnerChanged" && len(s.Body) == 3 && s.Body[0] == portalName && s.Body[2] == "" {
			return "", errors.New("the desktop portal quit before the file chooser answered")
		}
		if s.Name != requestIface+".Response" || s.Path != handle || len(s.Body) != 2 {
			continue
		}
		response, _ := s.Body[0].(uint32)
		results, _ := s.Body[1].(map[string]dbus.Variant)
		switch response {
		case 0:
			var uris []string
			if v, ok := results["uris"]; ok {
				uris, _ = v.Value().([]string)
			}
			if len(uris) == 0 {
				return "", errors.New("the file chooser answered with no file")
			}
			return pathOf(uris[0])
		case 1:
			return "", errCancelled
		default:
			return "", errors.New("the file chooser ended without a file")
		}
	}
	return "", errors.New("lost the session bus before the file chooser answered")
}

func run(args []string, stdout, stderr io.Writer, connect func() (*dbus.Conn, error)) int {
	flags := flag.NewFlagSet("tide-pick", flag.ContinueOnError)
	flags.SetOutput(stderr)
	title := flags.String("title", "Choose a file", "the chooser's title")
	folder := flags.String("folder", "", "the folder it opens in")
	images := flags.Bool("images", false, "offer only images")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if flags.NArg() > 0 {
		fmt.Fprintf(stderr, "tide-pick: takes no arguments, only flags: %s\n", strings.Join(flags.Args(), " "))
		return 2
	}
	conn, err := connect()
	if err != nil {
		fmt.Fprintf(stderr, "tide-pick: no session bus: %v\n", err)
		return 2
	}
	defer conn.Close()
	path, err := pick(conn, ask{title: *title, folder: *folder, images: *images, token: fmt.Sprintf("tide_pick_%d", os.Getpid())})
	if errors.Is(err, errCancelled) {
		return 0
	}
	if err != nil {
		fmt.Fprintf(stderr, "tide-pick: %v\n", err)
		return 2
	}
	fmt.Fprintln(stdout, path)
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, func() (*dbus.Conn, error) { return dbus.ConnectSessionBus() }))
}
