package main

import (
	"fmt"
	"sync"

	"github.com/godbus/dbus/v5"
)

// signals hands each signal on a connection to the handlers that asked for
// its member, so one connection serves several watchers.
type signals struct {
	mu       sync.Mutex
	handlers map[string][]func(*dbus.Signal)
}

func watchSignals(conn *dbus.Conn) *signals {
	s := &signals{handlers: map[string][]func(*dbus.Signal){}}
	ch := make(chan *dbus.Signal, 16)
	conn.Signal(ch)
	go func() {
		for sig := range ch {
			s.mu.Lock()
			hs := s.handlers[sig.Name]
			s.mu.Unlock()
			for _, h := range hs {
				h(sig)
			}
		}
	}()
	return s
}

func (s *signals) on(name string, h func(*dbus.Signal)) {
	s.mu.Lock()
	s.handlers[name] = append(s.handlers[name], h)
	s.mu.Unlock()
}

// watchName calls changed with whether name has an owner now, then each
// time that changes, with the owner's unique name ("" for none).
func watchName(conn *dbus.Conn, sigs *signals, name string, changed func(owner string)) error {
	if err := conn.AddMatchSignal(
		dbus.WithMatchSender("org.freedesktop.DBus"),
		dbus.WithMatchInterface("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg(0, name),
	); err != nil {
		return fmt.Errorf("couldn't watch %s: %w", name, err)
	}
	sigs.on("org.freedesktop.DBus.NameOwnerChanged", func(sig *dbus.Signal) {
		// Only the bus says who owns a name. A peer can send any signal
		// straight to this connection, past the match rule, so one that
		// claims to be NameOwnerChanged from anyone else is a forgery
		// (an empty owner would turn NetworkManager's own calls away).
		if sig.Sender != "org.freedesktop.DBus" {
			return
		}
		if len(sig.Body) == 3 {
			if n, _ := sig.Body[0].(string); n == name {
				owner, _ := sig.Body[2].(string)
				changed(owner)
			}
		}
	})
	var owner string
	err := conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, name).Store(&owner)
	if err != nil {
		if e, ok := err.(dbus.Error); ok && e.Name == "org.freedesktop.DBus.Error.NameHasNoOwner" {
			changed("")
			return nil
		}
		return fmt.Errorf("couldn't ask who owns %s: %w", name, err)
	}
	changed(owner)
	return nil
}

// ownerPID is the process that owns a bus name, for `tide doctor`.
func ownerPID(conn *dbus.Conn, owner string) uint32 {
	var pid uint32
	if err := conn.BusObject().Call("org.freedesktop.DBus.GetConnectionUnixProcessID", 0, owner).Store(&pid); err != nil {
		return 0
	}
	return pid
}

// The lock (SPEC.md §10) runs as tide-lock.service, so the session is
// locked while that unit is anything but inactive or failed.
const lockUnit = "tide-lock.service"

func lockedState(active string) bool {
	switch active {
	case "active", "activating", "deactivating", "reloading":
		return true
	}
	return false
}

// watchLock calls changed with whether the session is locked, then on each
// change, from systemd's user manager.
func watchLock(conn *dbus.Conn, sigs *signals, changed func(bool)) error {
	// The unit's changes count only from systemd itself: a peer can send
	// any signal straight to this connection, and a forged "locked" would
	// turn every request away.
	var systemd string
	if err := conn.BusObject().Call("org.freedesktop.DBus.GetNameOwner", 0, "org.freedesktop.systemd1").Store(&systemd); err != nil {
		return fmt.Errorf("couldn't find systemd's user manager: %w", err)
	}
	manager := conn.Object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
	// systemd sends units' PropertiesChanged only to subscribed clients.
	if err := manager.Call("org.freedesktop.systemd1.Manager.Subscribe", 0).Err; err != nil {
		if e, ok := err.(dbus.Error); !ok || e.Name != "org.freedesktop.systemd1.AlreadySubscribed" {
			return fmt.Errorf("couldn't subscribe to systemd's unit changes: %w", err)
		}
	}
	var path dbus.ObjectPath
	if err := manager.Call("org.freedesktop.systemd1.Manager.LoadUnit", 0, lockUnit).Store(&path); err != nil {
		return fmt.Errorf("couldn't find %s: %w", lockUnit, err)
	}
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(path),
		dbus.WithMatchInterface("org.freedesktop.DBus.Properties"),
		dbus.WithMatchMember("PropertiesChanged"),
	); err != nil {
		return fmt.Errorf("couldn't watch %s: %w", lockUnit, err)
	}
	var mu sync.Mutex
	last := false
	report := func(active string) {
		mu.Lock()
		defer mu.Unlock()
		if l := lockedState(active); l != last {
			last = l
			changed(l)
		}
	}
	sigs.on("org.freedesktop.DBus.Properties.PropertiesChanged", func(sig *dbus.Signal) {
		if sig.Sender != systemd || sig.Path != path || len(sig.Body) < 2 {
			return
		}
		if iface, _ := sig.Body[0].(string); iface != "org.freedesktop.systemd1.Unit" {
			return
		}
		props, _ := sig.Body[1].(map[string]dbus.Variant)
		if v, ok := props["ActiveState"]; ok {
			s, _ := v.Value().(string)
			report(s)
		}
	})
	v, err := conn.Object("org.freedesktop.systemd1", path).GetProperty("org.freedesktop.systemd1.Unit.ActiveState")
	if err != nil {
		return fmt.Errorf("couldn't read whether %s runs: %w", lockUnit, err)
	}
	s, _ := v.Value().(string)
	report(s)
	return nil
}
