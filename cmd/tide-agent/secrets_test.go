package main

import (
	"errors"
	"reflect"
	"testing"

	"github.com/godbus/dbus/v5"
)

func v(x any) dbus.Variant { return dbus.MakeVariant(x) }

func wifi(sec map[string]dbus.Variant) settings {
	return settings{
		"connection":               {"id": v("Home"), "uuid": v("u-1"), "type": v("802-11-wireless")},
		"802-11-wireless":          {"ssid": v([]byte("Home Net"))},
		"802-11-wireless-security": sec,
	}
}

func keys(a ask) []string {
	var out []string
	for _, f := range a.fields {
		out = append(out, f.Key)
	}
	return out
}

func TestAsksWifi(t *testing.T) {
	for _, tc := range []struct {
		name  string
		sec   map[string]dbus.Variant
		hints []string
		want  []string
	}{
		{"WPA personal asks for the psk", map[string]dbus.Variant{"key-mgmt": v("wpa-psk")}, nil, []string{"psk"}},
		{"WPA3 personal asks for the psk", map[string]dbus.Variant{"key-mgmt": v("sae")}, nil, []string{"psk"}},
		{"WEP asks for the key it transmits with", map[string]dbus.Variant{"key-mgmt": v("none"), "wep-tx-keyidx": v(uint32(2))}, nil, []string{"wep-key2"}},
		{"LEAP asks for its password", map[string]dbus.Variant{"key-mgmt": v("ieee8021x"), "auth-alg": v("leap")}, nil, []string{"leap-password"}},
		{"hints come first", map[string]dbus.Variant{"key-mgmt": v("none")}, []string{"wep-key1"}, []string{"wep-key1"}},
		{"a hint for another setting's key is ignored", map[string]dbus.Variant{"key-mgmt": v("wpa-psk")}, []string{"password"}, []string{"psk"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, err := asks(wifi(tc.sec), "802-11-wireless-security", tc.hints)
			if err != nil {
				t.Fatal(err)
			}
			if got := keys(a); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("keys = %v, want %v", got, tc.want)
			}
			if a.kind != "wifi" || a.message != "“Home Net” needs a password." {
				t.Errorf("kind %q, message %q", a.kind, a.message)
			}
			for _, f := range a.fields {
				if !f.Secret {
					t.Errorf("%s isn't secret", f.Key)
				}
			}
		})
	}
}

func TestAsksDeclines(t *testing.T) {
	for _, tc := range []struct {
		name    string
		conn    settings
		setting string
	}{
		{"enhanced open has no key", wifi(map[string]dbus.Variant{"key-mgmt": v("owe")}), "802-11-wireless-security"},
		{"dynamic WEP asks through 802-1x", wifi(map[string]dbus.Variant{"key-mgmt": v("ieee8021x")}), "802-11-wireless-security"},
		{"PPPoE", settings{"connection": {"id": v("DSL")}, "pppoe": {}}, "pppoe"},
		{"WireGuard", settings{"connection": {"id": v("wg")}, "wireguard": {}}, "wireguard"},
		{"a setting the connection lacks", settings{"connection": {"id": v("x")}}, "802-1x"},
		{"802.1X with no username", settings{"connection": {"id": v("Work")}, "802-1x": {"eap": v([]string{"peap"})}}, "802-1x"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := asks(tc.conn, tc.setting, nil)
			var d declined
			if !errors.As(err, &d) {
				t.Errorf("err = %v, want it declined", err)
			}
		})
	}
}

func TestAsks8021x(t *testing.T) {
	conn := func(eap ...string) settings {
		return settings{
			"connection": {"id": v("Work"), "uuid": v("u-2"), "type": v("802-3-ethernet")},
			"802-1x":     {"eap": v(eap), "identity": v("alice")},
		}
	}
	a, err := asks(conn("peap"), "802-1x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(a); !reflect.DeepEqual(got, []string{"password"}) {
		t.Errorf("PEAP asks %v", got)
	}
	if a.message != "Sign in to “Work” as alice." {
		t.Errorf("message %q", a.message)
	}
	a, err = asks(conn("tls"), "802-1x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(a); !reflect.DeepEqual(got, []string{"private-key-password"}) {
		t.Errorf("TLS asks %v", got)
	}
	a, err = asks(conn("ttls"), "802-1x", []string{"phase2-private-key-password"})
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(a); !reflect.DeepEqual(got, []string{"phase2-private-key-password"}) {
		t.Errorf("hinted asks %v", got)
	}
}

func TestAnswerFor(t *testing.T) {
	got := answerFor("802-11-wireless-security", map[string]string{"psk": "hunter22"})
	if got["802-11-wireless-security"]["psk"].Value() != "hunter22" {
		t.Errorf("wifi answer %v", got)
	}
	got = answerFor("vpn", map[string]string{"password": "p"})
	if !reflect.DeepEqual(got["vpn"]["secrets"].Value(), map[string]string{"password": "p"}) {
		t.Errorf("vpn answer %v", got)
	}
}

func TestAgentOwned(t *testing.T) {
	conn := settings{
		"802-11-wireless-security": {"psk": v("a"), "psk-flags": v(uint32(1)), "leap-password": v("b")},
		"802-1x":                   {"password": v("c"), "password-flags": v(uint32(2))},
		"vpn": {
			"data":    v(map[string]string{"password-flags": "1", "otp-flags": "2"}),
			"secrets": v(map[string]string{"password": "d", "otp": "e"}),
		},
	}
	want := []saved{{"802-11-wireless-security", "psk", "a"}, {"vpn", "password", "d"}}
	if got := agentOwned(conn); !reflect.DeepEqual(got, want) {
		t.Errorf("agentOwned = %v, want %v", got, want)
	}
}

func TestWEPKeysShareOneFlagsProperty(t *testing.T) {
	conn := wifi(map[string]dbus.Variant{
		"key-mgmt": v("none"), "wep-key1": v("k1"), "wep-key-flags": v(uint32(secretAgentOwned)),
	})
	want := []saved{{"802-11-wireless-security", "wep-key1", "k1"}}
	if got := agentOwned(conn); !reflect.DeepEqual(got, want) {
		t.Errorf("agentOwned = %v, want %v", got, want)
	}
	conn["802-11-wireless-security"]["wep-key-flags"] = v(uint32(secretNotSaved))
	if got := flagsOf(conn, "802-11-wireless-security", "wep-key3"); got != secretNotSaved {
		t.Errorf("wep-key3's flags = %d, want always-ask from wep-key-flags", got)
	}
}
