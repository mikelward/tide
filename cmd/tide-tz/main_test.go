package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func loc(t *testing.T, name string) *time.Location {
	t.Helper()
	l, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func runTZ(t *testing.T, local *time.Location, n names, args ...string) (output, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := run(args, &stdout, &stderr, time.Date(2026, 10, 2, 12, 0, 0, 0, time.UTC), local, n)
	var out output
	if code == 0 {
		if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
			t.Fatalf("bad JSON %q: %v", stdout.String(), err)
		}
	}
	return out, stderr.String(), code
}

var utc = names{tz: "UTC", tzSet: true}

func ms(s string) int64 {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t.UnixMilli()
}

func TestPeriodsCrossDST(t *testing.T) {
	out, stderr, code := runTZ(t, loc(t, "America/New_York"), utc, "--from", "2026-10-02T12:00:00Z", "--days", "200",
		"America/Los_Angeles", "Europe/London")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	want := map[string][]period{
		"America/Los_Angeles": {
			{Start: ms("2026-10-02T12:00:00Z"), Offset: -420, Abbr: "PDT"},
			{Start: ms("2026-11-01T09:00:00Z"), Offset: -480, Abbr: "PST"},
			{Start: ms("2027-03-14T10:00:00Z"), Offset: -420, Abbr: "PDT"},
		},
		"Europe/London": {
			{Start: ms("2026-10-02T12:00:00Z"), Offset: 60, Abbr: "BST"},
			{Start: ms("2026-10-25T01:00:00Z"), Offset: 0, Abbr: "GMT"},
			{Start: ms("2027-03-28T01:00:00Z"), Offset: 60, Abbr: "BST"},
		},
		// Local's periods are the location it's given.
		"local": {
			{Start: ms("2026-10-02T12:00:00Z"), Offset: -240, Abbr: "EDT"},
			{Start: ms("2026-11-01T06:00:00Z"), Offset: -300, Abbr: "EST"},
			{Start: ms("2027-03-14T07:00:00Z"), Offset: -240, Abbr: "EDT"},
		},
	}
	for _, z := range append(out.Zones, zone{Zone: "local", Periods: out.Local.Periods}) {
		got, _ := json.Marshal(z.Periods)
		exp, _ := json.Marshal(want[z.Zone])
		if string(got) != string(exp) {
			t.Errorf("%s periods:\n got %s\nwant %s", z.Zone, got, exp)
		}
	}
}

func TestOffsetsKeepTheirSeconds(t *testing.T) {
	// Monrovia was UTC-0:44:30 until 1972.
	out, stderr, code := runTZ(t, time.UTC, utc, "--from", "1960-01-01T00:00:00Z", "--days", "1", "Africa/Monrovia")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if p := out.Zones[0].Periods; len(p) != 1 || p[0].Offset != -44.5 {
		t.Errorf("Africa/Monrovia periods = %+v, want offset -44.5", p)
	}
}

func TestOnlyCanonicalZonesAreAccepted(t *testing.T) {
	out, _, code := runTZ(t, time.UTC, utc, "--days", "1",
		"UTC", "Asia/Kolkata", "US/Pacific", "GB", "PST", "+05:30", "EST5EDT", "/etc/localtime", "Not/AZone",
		"America/Not_A_City", "Europe/../../../dev/zero", "", "Local", "America//New_York", "America/./New_York", "America/New_York/")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	for _, z := range out.Zones[:2] {
		if z.Error != "" || len(z.Periods) != 1 {
			t.Errorf("%s = %+v, want accepted", z.Zone, z)
		}
	}
	for _, z := range out.Zones[2:] {
		if z.Error == "" || z.Periods != nil {
			t.Errorf("%q = %+v, want an error", z.Zone, z)
		}
	}
	// A link name points at where the IDs are listed.
	if !strings.Contains(out.Zones[2].Error, "timedatectl list-timezones") {
		t.Errorf("US/Pacific error = %q", out.Zones[2].Error)
	}
}

func TestLocalName(t *testing.T) {
	dir := t.TempDir()
	link := filepath.Join(dir, "localtime-link")
	if err := os.Symlink("/usr/share/zoneinfo/Europe/London", link); err != nil {
		t.Fatal(err)
	}
	copied := filepath.Join(dir, "localtime-copy")
	if err := os.WriteFile(copied, []byte("TZif"), 0o644); err != nil {
		t.Fatal(err)
	}
	none := filepath.Join(dir, "missing")
	posixLink := filepath.Join(dir, "localtime-posix")
	if err := os.Symlink("/usr/share/zoneinfo/posix/Asia/Tokyo", posixLink); err != nil {
		t.Fatal(err)
	}
	etcUTC := filepath.Join(dir, "localtime-etc-utc")
	if err := os.Symlink("/usr/share/zoneinfo/Etc/UTC", etcUTC); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		n    names
		want string
	}{
		{"TZ names a zone", names{tz: ":America/New_York", tzSet: true, localtime: link}, "America/New_York"},
		{"TZ set but empty is UTC", names{tz: "", tzSet: true, localtime: link}, "UTC"},
		{"localtime links into posix/", names{localtime: posixLink}, "Asia/Tokyo"},
		{"TZ is a path", names{tz: "/usr/share/zoneinfo/Asia/Tokyo", tzSet: true, localtime: link}, ""},
		{"localtime links into zoneinfo", names{localtime: link}, "Europe/London"},
		{"localtime is a copy", names{localtime: copied}, ""},
		{"no localtime is UTC", names{localtime: none}, "UTC"},
		{"Etc/UTC is UTC", names{localtime: etcUTC}, "UTC"},
		{"TZ names Etc/UTC", names{tz: "Etc/UTC", tzSet: true}, "UTC"},
	}
	for _, c := range cases {
		if got, err := localName(c.n); got != c.want || err != nil {
			t.Errorf("%s: local = %q, %v, want %q", c.name, got, err, c.want)
		}
	}
}

func TestLocalNameReportsReadErrors(t *testing.T) {
	// A path through a regular file fails with ENOTDIR, not "not a link".
	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	out, _, code := runTZ(t, time.UTC, names{localtime: filepath.Join(file, "localtime")}, "--days", "1")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if out.Local.Zone != "" || !strings.HasPrefix(out.Local.Error, "naming the local zone: ") || len(out.Local.Periods) != 1 {
		t.Errorf("local = %+v, want periods and an error", out.Local)
	}
}

func TestLocalNameMustMatchLocalZone(t *testing.T) {
	// A $TZ, or a dangling link, that Go couldn't load leaves time.Local as
	// UTC, so its name mustn't hide a listed clock.
	for _, n := range []names{
		{tz: "Not/AZone", tzSet: true},
		{tz: "EST5EDT,M3.2.0,M11.1.0", tzSet: true},
		{tz: "Europe/London", tzSet: true},
	} {
		out, _, code := runTZ(t, time.UTC, n, "--days", "1")
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
		if out.Local.Zone != "" || out.Local.Error != "" {
			t.Errorf("TZ=%s with UTC local: local = %+v, want no ID", n.tz, out.Local)
		}
	}
}

func TestLocalInOutput(t *testing.T) {
	out, _, code := runTZ(t, loc(t, "Asia/Tokyo"), names{tz: "Asia/Tokyo", tzSet: true}, "--days", "1")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if out.Local.Zone != "Asia/Tokyo" || len(out.Local.Periods) != 1 || out.Local.Periods[0].Abbr != "JST" {
		t.Errorf("local = %+v", out.Local)
	}
}

func TestBadArguments(t *testing.T) {
	if _, stderr, code := runTZ(t, time.UTC, utc, "--from", "yesterday"); code != 2 || !strings.Contains(stderr, "--from") {
		t.Errorf("bad --from: exit %d, %q", code, stderr)
	}
	if _, stderr, code := runTZ(t, time.UTC, utc, "--days", "0"); code != 2 || !strings.Contains(stderr, "--days") {
		t.Errorf("bad --days: exit %d, %q", code, stderr)
	}
}

// The shell passes zones after "--" (shell/ClockData.qml), so a zone that
// looks like a flag, from a typo in clocks.json, is a zone with an error
// rather than a bad argument that stops tide-tz from answering at all.
func TestZonesAfterDashDashAreZones(t *testing.T) {
	out, stderr, code := runTZ(t, time.UTC, utc, "--days", "1", "--", "-bad", "--", "UTC")
	if code != 0 {
		t.Fatalf("exit %d: %q", code, stderr)
	}
	if len(out.Zones) != 3 {
		t.Fatalf("zones = %+v", out.Zones)
	}
	for i, want := range []string{"-bad", "--"} {
		if out.Zones[i].Zone != want || out.Zones[i].Error == "" {
			t.Errorf("zone %d = %+v, want an error for %q", i, out.Zones[i], want)
		}
	}
	if out.Zones[2].Zone != "UTC" || out.Zones[2].Error != "" {
		t.Errorf("zone 2 = %+v", out.Zones[2])
	}
}
