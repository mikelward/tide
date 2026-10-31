package main

import (
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/godbus/dbus/v5"
)

// A connection as NetworkManager sends it: settings by name, each a map of
// properties.
type settings = map[string]map[string]dbus.Variant

// NetworkManager's GetSecrets flags (nm-dbus-interface.h).
const (
	flagAllowInteraction = 0x1
	flagRequestNew       = 0x2
	flagUserRequested    = 0x4
)

// A secret's own flags, its "<key>-flags" property.
const (
	secretAgentOwned  = 0x1
	secretNotSaved    = 0x2
	secretNotRequired = 0x4
)

// The settings and keys whose values are secrets the helper asks for or
// keeps, apart from a VPN's, which are its "secrets" dictionary.
var secretKeys = map[string][]string{
	"802-11-wireless-security": {"psk", "wep-key0", "wep-key1", "wep-key2", "wep-key3", "leap-password"},
	"802-1x":                   {"password", "private-key-password", "phase2-private-key-password"},
}

// What a setting needs asked for: the fields, and the words around them.
type ask struct {
	kind    string
	title   string
	message string
	fields  []field
}

// declined says why a request is answered with NoSecrets rather than asked,
// for the log.
type declined struct{ reason string }

func (d declined) Error() string { return d.reason }

func str(s map[string]dbus.Variant, key string) string {
	v, _ := s[key].Value().(string)
	return v
}

func u32(s map[string]dbus.Variant, key string) uint32 {
	v, _ := s[key].Value().(uint32)
	return v
}

func strs(s map[string]dbus.Variant, key string) []string {
	v, _ := s[key].Value().([]string)
	return v
}

func info(conn settings) connInfo {
	c := conn["connection"]
	return connInfo{ID: str(c, "id"), UUID: str(c, "uuid"), Type: str(c, "type")}
}

func ssid(conn settings) string {
	b, _ := conn["802-11-wireless"]["ssid"].Value().([]byte)
	return string(b)
}

// The connection's name as people see it: a Wi-Fi network's SSID, else its
// own name.
func displayName(conn settings) string {
	if s := ssid(conn); s != "" {
		return s
	}
	return info(conn).ID
}

// asks says what to ask for to answer a request for setting (SPEC.md
// §5.6's table). hints, when NetworkManager gives them, name the keys it
// wants; each is used only if it's one this setting has.
func asks(conn settings, setting string, hints []string) (ask, error) {
	s, ok := conn[setting]
	if !ok && setting != "802-11-wireless-security" {
		return ask{}, declined{fmt.Sprintf("the connection has no %s setting", setting)}
	}
	name := displayName(conn)
	hinted := func() []string {
		var keys []string
		for _, h := range hints {
			if slices.Contains(secretKeys[setting], h) {
				keys = append(keys, h)
			}
		}
		return keys
	}
	switch setting {
	case "802-11-wireless-security":
		keys := hinted()
		if len(keys) == 0 {
			switch mgmt := str(s, "key-mgmt"); mgmt {
			case "wpa-psk", "sae":
				keys = []string{"psk"}
			case "none":
				keys = []string{fmt.Sprintf("wep-key%d", u32(s, "wep-tx-keyidx"))}
			case "ieee8021x":
				if str(s, "auth-alg") != "leap" {
					return ask{}, declined{"dynamic WEP asks through the 802-1x setting, which is a separate request"}
				}
				keys = []string{"leap-password"}
			default:
				return ask{}, declined{fmt.Sprintf("Wi-Fi key management %q has no key to ask for", mgmt)}
			}
		}
		a := ask{kind: "wifi", title: "Wi-Fi password", message: fmt.Sprintf("“%s” needs a password.", name)}
		for _, k := range keys {
			label := "Password"
			if k != "psk" && k != "leap-password" {
				label = "Key"
			}
			a.fields = append(a.fields, field{Key: k, Label: label, Secret: true})
		}
		return a, nil
	case "802-1x":
		identity := str(s, "identity")
		keys := hinted()
		if len(keys) == 0 {
			if slices.Contains(strs(s, "eap"), "tls") {
				keys = []string{"private-key-password"}
			} else {
				keys = []string{"password"}
			}
		}
		a := ask{kind: "8021x", title: "Network login"}
		for _, k := range keys {
			switch k {
			case "password":
				if identity == "" {
					return ask{}, declined{"802.1X with no username, which isn't a secret; set it in nm-connection-editor"}
				}
				a.fields = append(a.fields, field{Key: k, Label: "Password", Secret: true})
			default:
				a.fields = append(a.fields, field{Key: k, Label: "Private key password", Secret: true})
			}
		}
		if identity != "" {
			a.message = fmt.Sprintf("Sign in to “%s” as %s.", name, identity)
		} else {
			a.message = fmt.Sprintf("“%s” needs the private key's password.", name)
		}
		return a, nil
	}
	return ask{}, declined{fmt.Sprintf("tide doesn't ask for %s secrets", setting)}
}

// flagsOf is a secret's flags. A VPN keeps them in its data dictionary as
// text, and WEP's four keys share one property, wep-key-flags.
func flagsOf(conn settings, setting, key string) uint32 {
	if setting == "vpn" {
		var n uint32
		fmt.Sscanf(vpnData(conn)[key+"-flags"], "%d", &n)
		return n
	}
	if setting == "802-11-wireless-security" && strings.HasPrefix(key, "wep-key") {
		return u32(conn[setting], "wep-key-flags")
	}
	return u32(conn[setting], key+"-flags")
}

func vpnData(conn settings) map[string]string {
	d, _ := conn["vpn"]["data"].Value().(map[string]string)
	return d
}

func vpnSecrets(conn settings) map[string]string {
	d, _ := conn["vpn"]["secrets"].Value().(map[string]string)
	return d
}

// answerFor is NetworkManager's form of the values for setting.
func answerFor(setting string, values map[string]string) settings {
	if setting == "vpn" {
		return settings{"vpn": {"secrets": dbus.MakeVariant(values)}}
	}
	s := map[string]dbus.Variant{}
	for k, v := range values {
		s[k] = dbus.MakeVariant(v)
	}
	return settings{setting: s}
}

// The secrets in conn that the keyring keeps: agent-owned ones with a
// value, by setting and key, in a fixed order.
type saved struct {
	setting, key, value string
}

func agentOwned(conn settings) []saved {
	var out []saved
	for setting, keys := range secretKeys {
		for _, k := range keys {
			v := str(conn[setting], k)
			if v != "" && flagsOf(conn, setting, k) == secretAgentOwned {
				out = append(out, saved{setting, k, v})
			}
		}
	}
	for k, v := range vpnSecrets(conn) {
		if v != "" && flagsOf(conn, "vpn", k) == secretAgentOwned {
			out = append(out, saved{"vpn", k, v})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].setting != out[j].setting {
			return out[i].setting < out[j].setting
		}
		return out[i].key < out[j].key
	})
	return out
}
