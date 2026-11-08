package main

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// How long exit waits for the answers a connection owes.
const replyGrace = 5 * time.Second

// replies tracks the method calls a connection has received and not yet
// answered, so it closes only once each answer has gone. godbus answers a
// call on its own goroutine after the method returns: without this, exit
// could close the connection between the two, and NetworkManager or BlueZ
// would hear that the agent disconnected instead of its answer.
type replies struct {
	log io.Writer
	// For tests: sees each message before it's sent.
	sending func(*dbus.Message)

	mu   sync.Mutex
	owed map[replyKey]bool
	// Closed, and replaced, whenever an answer goes.
	answered chan struct{}
}

// A call is known by who sent it and its serial; its answer names the same
// pair as its destination and reply serial.
type replyKey struct {
	peer   string
	serial uint32
}

func newReplies(log io.Writer, sending func(*dbus.Message)) *replies {
	return &replies{log: log, sending: sending, owed: map[replyKey]bool{}, answered: make(chan struct{})}
}

func (r *replies) options() []dbus.ConnOption {
	return []dbus.ConnOption{dbus.WithIncomingInterceptor(r.received), dbus.WithOutgoingInterceptor(r.sent)}
}

// received runs on the connection's reader before godbus starts the call's
// goroutine, so a call is owed before it can be answered.
func (r *replies) received(msg *dbus.Message) {
	if msg.Type != dbus.TypeMethodCall || msg.Flags&dbus.FlagNoReplyExpected != 0 {
		return
	}
	sender, _ := msg.Headers[dbus.FieldSender].Value().(string)
	r.mu.Lock()
	r.owed[replyKey{sender, msg.Serial()}] = true
	r.mu.Unlock()
}

// sent runs just before godbus takes the lock it writes under, which Close
// waits for.
func (r *replies) sent(msg *dbus.Message) {
	if r.sending != nil {
		r.sending(msg)
	}
	if msg.Type != dbus.TypeMethodReply && msg.Type != dbus.TypeError {
		return
	}
	dest, _ := msg.Headers[dbus.FieldDestination].Value().(string)
	serial, _ := msg.Headers[dbus.FieldReplySerial].Value().(uint32)
	r.mu.Lock()
	if r.owed[replyKey{dest, serial}] {
		delete(r.owed, replyKey{dest, serial})
		close(r.answered)
		r.answered = make(chan struct{})
	}
	r.mu.Unlock()
}

// close closes conn once every call it received has its answer on the way,
// or replyGrace has passed, or the bus has dropped it.
func (r *replies) close(conn *dbus.Conn) {
	ctx, cancel := context.WithTimeout(conn.Context(), replyGrace)
	defer cancel()
	if n := r.wait(ctx); n > 0 {
		fmt.Fprintf(r.log, "tide-agent: exiting with %d answers unsent: %v\n", n, ctx.Err())
	}
	// The last answer can still be between sent and the write lock. A round
	// trip on the same connection gives it that long to take the lock, after
	// which Close waits for it. Once ctx is done the round trip fails at
	// once, and why was logged above or is the bus having gone.
	if err := conn.BusObject().CallWithContext(ctx, "org.freedesktop.DBus.Peer.Ping", 0).Err; err != nil && ctx.Err() == nil {
		fmt.Fprintf(r.log, "tide-agent: couldn't reach the bus before exiting: %v\n", err)
	}
	if err := conn.Close(); err != nil {
		fmt.Fprintf(r.log, "tide-agent: couldn't close a bus connection: %v\n", err)
	}
}

// wait is how many answers are still owed once none are, or ctx is done.
func (r *replies) wait(ctx context.Context) int {
	for logged := false; ; logged = true {
		r.mu.Lock()
		n, answered := len(r.owed), r.answered
		r.mu.Unlock()
		if n == 0 {
			return 0
		}
		if !logged {
			fmt.Fprintf(r.log, "tide-agent: waiting to send %d answers before exiting\n", n)
		}
		select {
		case <-answered:
		case <-ctx.Done():
			return n
		}
	}
}
