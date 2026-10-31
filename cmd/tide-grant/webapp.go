package main

import (
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// The programs that open a site as an `--app` window: Chrome and
// Chromium, and scripts' `chrome`, which runs one of them.
var chromes = map[string]bool{
	"chrome": true, "google-chrome": true, "google-chrome-stable": true, "google-chrome-beta": true,
	"google-chrome-unstable": true, "chromium": true, "chromium-browser": true,
}

// An `--app=URL` in a script's text, quoted or not.
var appFlag = regexp.MustCompile(`--app=["']?(https?://[^"'\s;&|)]+)`)

// The most of a script read for its `--app` URL: a launcher is a few lines.
const maxScript = 64 * 1024

// webAppClass is the class Chrome gives an `--app` window of rawURL on
// Wayland, as its default profile, or "": its host, then its path with
// each `/` a `_`, so https://calendar.google.com is
// chrome-calendar.google.com__-Default.
func webAppClass(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return ""
	}
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	return "chrome-" + strings.ToLower(u.Hostname()) + "_" + strings.ReplaceAll(path, "/", "_") + "-Default"
}

// webAppClasses is the classes of the `--app` windows a command given as
// words opens (SPEC.md §14.3): a Chrome command's own `--app=URL`, or,
// for a launcher script such as scripts' google-calendar, the `--app=URL`
// its text passes. runs is the program, past wrappers. A script is a file
// on PATH (or the path given) that starts with `#!`; anything else, or a
// file that can't be read, opens no `--app` window that can be told.
func webAppClasses(words []string, runs string, env []string) []string {
	var urls []string
	if chromes[filepath.Base(runs)] {
		for _, w := range words {
			if strings.HasPrefix(w, "--app=") {
				urls = append(urls, strings.TrimPrefix(w, "--app="))
			}
		}
	} else {
		path := runs
		if !strings.Contains(runs, "/") {
			path = lookPath(runs, env)
		}
		if path == "" {
			return nil
		}
		for _, m := range appFlag.FindAllStringSubmatch(scriptText(path), -1) {
			urls = append(urls, m[1])
		}
	}
	var out []string
	seen := map[string]bool{}
	for _, u := range urls {
		if c := webAppClass(u); c != "" && !seen[strings.ToLower(c)] {
			seen[strings.ToLower(c)] = true
			out = append(out, c)
		}
	}
	return out
}

// scriptText is the start of the script at path, or "" for a file that
// isn't one or can't be read: a binary has no `--app` to find.
func scriptText(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf, err := io.ReadAll(io.LimitReader(f, maxScript))
	if err != nil || !strings.HasPrefix(string(buf), "#!") {
		return ""
	}
	return string(buf)
}

// appendNew is list with each of more not already in it, ignoring case.
func appendNew(list []string, more ...string) []string {
	for _, m := range more {
		if !slices.ContainsFunc(list, func(c string) bool { return strings.EqualFold(c, m) }) {
			list = append(list, m)
		}
	}
	return list
}
