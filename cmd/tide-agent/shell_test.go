package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

func TestShellLink(t *testing.T) {
	outR, outW := io.Pipe()
	inR, inW := io.Pipe()
	s := newShellLink(outW)
	readErr := make(chan error, 1)
	go func() { readErr <- s.read(inR) }()
	lines := bufio.NewScanner(outR)
	next := func() map[string]any {
		t.Helper()
		if !lines.Scan() {
			t.Fatal("no line from the helper")
		}
		var m map[string]any
		if err := json.Unmarshal(lines.Bytes(), &m); err != nil {
			t.Fatal(err)
		}
		return m
	}

	// An answer reaches the request it names.
	got := make(chan answer, 1)
	go func() {
		a, err := s.ask(context.Background(), request{Kind: "wifi"})
		if err != nil {
			t.Error(err)
		}
		got <- a
	}()
	m := next()
	if m["type"] != "request" || m["kind"] != "wifi" || m["id"] != "1" {
		t.Fatalf("request %v", m)
	}
	io.WriteString(inW, `{"type":"reply","id":"1","values":{"psk":"x"}}`+"\n")
	if a := <-got; a.Type != "reply" || a.Values["psk"] != "x" {
		t.Errorf("answer %+v", a)
	}

	// A request that ends first tells the shell to cancel, and the late
	// answer to it is dropped.
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := s.ask(ctx, request{Kind: "vpn"})
		done <- err
	}()
	if m := next(); m["id"] != "2" {
		t.Fatalf("second request %v", m)
	}
	cancel()
	if m := next(); m["type"] != "cancel" || m["id"] != "2" {
		t.Errorf("cancel %v", m)
	}
	if err := <-done; err == nil {
		t.Error("a canceled request should return an error")
	}
	io.WriteString(inW, `{"type":"reply","id":"2","values":{}}`+"\n")

	// Once stdin closes, waiting requests hear "gone".
	go func() {
		a, _ := s.ask(context.Background(), request{Kind: "wifi"})
		got <- a
	}()
	next()
	inW.Close()
	if a := <-got; a.Type != "gone" {
		t.Errorf("after EOF: %+v", a)
	}
	if err := <-readErr; err != nil {
		t.Errorf("read: %v", err)
	}
	if a, _ := s.ask(context.Background(), request{}); a.Type != "gone" {
		t.Errorf("a request after EOF: %+v", a)
	}
}

func TestShellLinkBadLines(t *testing.T) {
	for _, line := range []string{`not json {"psk":"hunter22"}`, `{"type":"bogus"}`} {
		s := newShellLink(io.Discard)
		err := s.read(strings.NewReader(line + "\n"))
		if err == nil {
			t.Errorf("%q: no error", line)
		} else if strings.Contains(err.Error(), "hunter22") {
			t.Errorf("the error repeats the line, which may hold a password: %v", err)
		}
	}
}
