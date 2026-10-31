package main

import (
	"fmt"
	"sync"

	"github.com/godbus/dbus/v5"
)

// The keyring, through the Secret Service API on the session bus
// (gnome-keyring in tide, §5.2). Entries use the schema nm-applet and GNOME
// Shell store NetworkManager's agent-owned secrets under
// (shell-network-agent.c, GNOME Shell 51.1), so the ones they saved are
// found here, and the other way round.
const (
	secretsName    = "org.freedesktop.secrets"
	secretsPath    = dbus.ObjectPath("/org/freedesktop/secrets")
	secretsDefault = dbus.ObjectPath("/org/freedesktop/secrets/aliases/default")
	nmSchema       = "org.freedesktop.NetworkManager.Connection"
)

type keyring interface {
	// lookup is the saved values for one setting of a connection, by key.
	lookup(uuid, setting string) (map[string]string, error)
	save(uuid, connID string, s saved) error
	// remove deletes every entry for the connection.
	remove(uuid string) error
}

// The Secret Service's (oayays) struct.
type secretValue struct {
	Session     dbus.ObjectPath
	Parameters  []byte
	Value       []byte
	ContentType string
}

type secretService struct {
	conn *dbus.Conn
	mu   sync.Mutex
	// The session secrets travel under, opened on first use. It's "plain":
	// the values cross the session bus unencrypted, to and from the user's
	// own keyring daemon, which is the bus's own trust boundary.
	session dbus.ObjectPath
}

func (k *secretService) openSession() (dbus.ObjectPath, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.session != "" {
		return k.session, nil
	}
	var out dbus.Variant
	var session dbus.ObjectPath
	err := k.conn.Object(secretsName, secretsPath).Call("org.freedesktop.Secret.Service.OpenSession", 0, "plain", dbus.MakeVariant("")).Store(&out, &session)
	if err != nil {
		return "", fmt.Errorf("couldn't open a keyring session: %w", err)
	}
	k.session = session
	return session, nil
}

// withSession runs f with a session, opening a new one once if the keyring
// has forgotten the old (it restarted).
func (k *secretService) withSession(f func(dbus.ObjectPath) error) error {
	session, err := k.openSession()
	if err != nil {
		return err
	}
	if err := f(session); err != nil {
		k.mu.Lock()
		k.session = ""
		k.mu.Unlock()
		session, err2 := k.openSession()
		if err2 != nil {
			return err
		}
		return f(session)
	}
	return nil
}

func (k *secretService) lookup(uuid, setting string) (map[string]string, error) {
	var unlocked, locked []dbus.ObjectPath
	attrs := map[string]string{"connection-uuid": uuid, "setting-name": setting}
	if err := k.conn.Object(secretsName, secretsPath).Call("org.freedesktop.Secret.Service.SearchItems", 0, attrs).Store(&unlocked, &locked); err != nil {
		return nil, fmt.Errorf("couldn't search the keyring: %w", err)
	}
	values := map[string]string{}
	if len(unlocked) == 0 {
		if len(locked) > 0 {
			return values, fmt.Errorf("the keyring has %d saved secret(s) for %s, but it's locked", len(locked), setting)
		}
		return values, nil
	}
	var found map[dbus.ObjectPath]secretValue
	err := k.withSession(func(session dbus.ObjectPath) error {
		return k.conn.Object(secretsName, secretsPath).Call("org.freedesktop.Secret.Service.GetSecrets", 0, unlocked, session).Store(&found)
	})
	if err != nil {
		return nil, fmt.Errorf("couldn't read the keyring's secrets: %w", err)
	}
	for _, item := range unlocked {
		v, ok := found[item]
		if !ok {
			continue
		}
		prop, err := k.conn.Object(secretsName, item).GetProperty("org.freedesktop.Secret.Item.Attributes")
		if err != nil {
			return nil, fmt.Errorf("couldn't read a keyring entry's attributes: %w", err)
		}
		a, _ := prop.Value().(map[string]string)
		if key := a["setting-key"]; key != "" {
			values[key] = string(v.Value)
		}
	}
	return values, nil
}

func (k *secretService) save(uuid, connID string, s saved) error {
	props := map[string]dbus.Variant{
		// nm-applet's label for one.
		"org.freedesktop.Secret.Item.Label": dbus.MakeVariant(fmt.Sprintf("Network secret for %s/%s/%s", connID, s.setting, s.key)),
		"org.freedesktop.Secret.Item.Attributes": dbus.MakeVariant(map[string]string{
			"xdg:schema":      nmSchema,
			"connection-uuid": uuid,
			"setting-name":    s.setting,
			"setting-key":     s.key,
		}),
	}
	return k.withSession(func(session dbus.ObjectPath) error {
		var item, prompt dbus.ObjectPath
		secret := secretValue{Session: session, Value: []byte(s.value), ContentType: "text/plain"}
		if err := k.conn.Object(secretsName, secretsDefault).Call("org.freedesktop.Secret.Collection.CreateItem", 0, props, secret, true).Store(&item, &prompt); err != nil {
			return fmt.Errorf("couldn't save %s/%s in the keyring: %w", s.setting, s.key, err)
		}
		if prompt != "/" {
			return fmt.Errorf("couldn't save %s/%s: the keyring is locked", s.setting, s.key)
		}
		return nil
	})
}

func (k *secretService) remove(uuid string) error {
	var unlocked, locked []dbus.ObjectPath
	if err := k.conn.Object(secretsName, secretsPath).Call("org.freedesktop.Secret.Service.SearchItems", 0, map[string]string{"connection-uuid": uuid}).Store(&unlocked, &locked); err != nil {
		return fmt.Errorf("couldn't search the keyring: %w", err)
	}
	for _, item := range unlocked {
		var prompt dbus.ObjectPath
		if err := k.conn.Object(secretsName, item).Call("org.freedesktop.Secret.Item.Delete", 0).Store(&prompt); err != nil {
			return fmt.Errorf("couldn't delete a keyring entry: %w", err)
		}
	}
	if len(locked) > 0 {
		return fmt.Errorf("left %d entries in the locked keyring", len(locked))
	}
	return nil
}
