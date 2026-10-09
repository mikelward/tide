package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
)

// A fake greetd: it reads each framed request and answers it with the next
// of replies, recording what it got. It answers only once it has read the
// request, as greetd does.
func fakeGreetd(t *testing.T, replies []string) (socket string, got func() []string) {
	t.Helper()
	socket = filepath.Join(t.TempDir(), "greetd.sock")
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	seen := make(chan []string, 1)
	go func() {
		var requests []string
		defer func() { seen <- requests }()
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		for _, reply := range replies {
			var header [4]byte
			if _, err := io.ReadFull(conn, header[:]); err != nil {
				return
			}
			body := make([]byte, binary.NativeEndian.Uint32(header[:]))
			if _, err := io.ReadFull(conn, body); err != nil {
				return
			}
			requests = append(requests, string(body))
			if reply == "" {
				return // hang up instead of answering
			}
			if err := send(conn, []byte(reply)); err != nil {
				return
			}
		}
		// Hold the connection until the client closes it.
		io.Copy(io.Discard, conn)
	}()
	return socket, func() []string { return <-seen }
}

func lines(s string) []string {
	return strings.Split(strings.TrimRight(s, "\n"), "\n")
}

func TestRelaysEachRequestAndLabelsItsReply(t *testing.T) {
	socket, got := fakeGreetd(t, []string{
		`{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}`,
		`{"type":"error","error_type":"auth_error","description":"pam_authenticate: AUTH_ERR"}`,
		`{"type":"success"}`,
		`{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}`,
	})
	in := strings.NewReader(`{"type":"create_session","username":"probe"}
{"type":"post_auth_message_response","response":"wrong"}
{"type":"cancel_session"}
{"type":"create_session","username":"probe"}
`)
	var out, errs bytes.Buffer
	if code := run(in, &out, &errs, socket); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errs.String())
	}
	want := []string{
		`{"request":"create_session","reply":{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}}`,
		`{"request":"post_auth_message_response","reply":{"type":"error","error_type":"auth_error","description":"pam_authenticate: AUTH_ERR"}}`,
		`{"request":"cancel_session","reply":{"type":"success"}}`,
		`{"request":"create_session","reply":{"type":"auth_message","auth_message_type":"secret","auth_message":"Password: "}}`,
	}
	if g := lines(out.String()); strings.Join(g, "\n") != strings.Join(want, "\n") {
		t.Errorf("stdout:\n%s\nwant:\n%s", strings.Join(g, "\n"), strings.Join(want, "\n"))
	}
	sent := got()
	if len(sent) != 4 || sent[1] != `{"type":"post_auth_message_response","response":"wrong"}` || sent[2] != `{"type":"cancel_session"}` {
		t.Errorf("greetd got %q", sent)
	}
}

// Each reply on stdout is valid JSON, so the greeter can parse it whole.
func TestRepliesAreJSONLines(t *testing.T) {
	socket, _ := fakeGreetd(t, []string{`{"type":"success"}`})
	var out, errs bytes.Buffer
	if code := run(strings.NewReader(`{"type":"cancel_session"}`+"\n"), &out, &errs, socket); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errs.String())
	}
	var line struct {
		Request string         `json:"request"`
		Reply   map[string]any `json:"reply"`
	}
	if err := json.Unmarshal(out.Bytes(), &line); err != nil || line.Request != "cancel_session" || line.Reply["type"] != "success" {
		t.Errorf("stdout %q: %v", out.String(), err)
	}
}

func TestNoSocketIsAFault(t *testing.T) {
	var out, errs bytes.Buffer
	if code := run(strings.NewReader(""), &out, &errs, ""); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.HasPrefix(out.String(), `{"fault":"GREETD_SOCK isn't set`) {
		t.Errorf("stdout %q", out.String())
	}
	if !strings.Contains(errs.String(), "GREETD_SOCK") {
		t.Errorf("stderr %q", errs.String())
	}
}

func TestUnreachableSocketIsAFault(t *testing.T) {
	var out, errs bytes.Buffer
	missing := filepath.Join(t.TempDir(), "none.sock")
	if code := run(strings.NewReader(""), &out, &errs, missing); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.HasPrefix(out.String(), `{"fault":"couldn't connect to greetd at `+missing) {
		t.Errorf("stdout %q", out.String())
	}
}

func TestBadRequestsAreFaultsAndNeverEchoed(t *testing.T) {
	for _, line := range []string{
		`not json`,
		`["create_session"]`,
		`null`,
		`{"type":"post_auth_message_response_secret","response":"hunter2"}`,
	} {
		socket, got := fakeGreetd(t, []string{`{"type":"success"}`})
		var out, errs bytes.Buffer
		if code := run(strings.NewReader(line+"\n"), &out, &errs, socket); code != 1 {
			t.Errorf("%s: exit %d, want 1", line, code)
		}
		if !strings.HasPrefix(out.String(), `{"fault":`) {
			t.Errorf("%s: stdout %q", line, out.String())
		}
		if strings.Contains(out.String()+errs.String(), "hunter2") {
			t.Errorf("%s: the request's answer was written out: %q %q", line, out.String(), errs.String())
		}
		if out.Len() > 0 {
			// The connection closes on the fault; greetd saw nothing.
			if sent := got(); len(sent) != 0 {
				t.Errorf("%s: greetd got %q", line, sent)
			}
		}
	}
}

func TestGreetdHangingUpIsAFault(t *testing.T) {
	socket, _ := fakeGreetd(t, []string{""})
	var out, errs bytes.Buffer
	in := strings.NewReader(`{"type":"post_auth_message_response","response":"hunter2"}` + "\n")
	if code := run(in, &out, &errs, socket); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if out.String() != `{"fault":"no reply from greetd to post_auth_message_response: greetd closed the connection"}`+"\n" {
		t.Errorf("stdout %q", out.String())
	}
	if strings.Contains(out.String()+errs.String(), "hunter2") {
		t.Errorf("the answer was written out: %q %q", out.String(), errs.String())
	}
}

func TestMalformedReplyIsAFault(t *testing.T) {
	socket, _ := fakeGreetd(t, []string{`{"no":"type"}`})
	var out, errs bytes.Buffer
	if code := run(strings.NewReader(`{"type":"cancel_session"}`+"\n"), &out, &errs, socket); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.HasPrefix(out.String(), `{"fault":"no reply from greetd to cancel_session: the reply isn't a JSON object with a type`) {
		t.Errorf("stdout %q", out.String())
	}
}

func TestReceiveRefusesAnOversizedLength(t *testing.T) {
	var frame bytes.Buffer
	frame.Write(binary.NativeEndian.AppendUint32(nil, maxMessage+1))
	if _, err := receive(&frame); err == nil || !strings.Contains(err.Error(), "longer than any greetd sends") {
		t.Errorf("err %v", err)
	}
}

// greetd's framing is a native-endian length, then the JSON.
func TestSendFrames(t *testing.T) {
	var buf bytes.Buffer
	if err := send(&buf, []byte(`{"type":"cancel_session"}`)); err != nil {
		t.Fatal(err)
	}
	b := buf.Bytes()
	if n := binary.NativeEndian.Uint32(b[:4]); n != 25 || string(b[4:]) != `{"type":"cancel_session"}` {
		t.Errorf("frame %q", b)
	}
}
