// Command tide-tz reads tzdata for the bar's clocks (SPEC.md §7.3).
//
//	tide-tz [--from RFC3339] [--days N] ZONE...
//
// It prints JSON on stdout: for the local zone and each ZONE, the periods of
// constant offset from --from (default now) for --days days (default 400),
// each with its UTC offset in minutes (fractional for the rare offset with
// seconds) and tzdata's abbreviation:
//
//	{"local": {"zone": "Europe/London",
//	           "place": {"latitude": 51.5083, "longitude": -0.1253, "city": "London"},
//	           "periods": [...]},
//	 "zones": [{"zone": "America/Los_Angeles",
//	            "periods": [{"start": 1790000000000, "offset": -420, "abbr": "PDT"}, ...]},
//	           {"zone": "US/Pacific", "error": "unknown time zone US/Pacific; ..."}]}
//
// The shell runs it at startup and again when a period ends, and the
// clocks' JavaScript (shell/lib/clocks.mjs) looks offsets and
// abbreviations up in the periods. Go's time package reads the system's
// tzdata, so abbreviations are tzdata's (BST, not ICU's GMT+1). QML has no
// time zone API of its own.
//
// Local's periods are Go's time.Local, which the session's environment
// picks. Its name only decides which listed clock is hidden as local, so it
// comes only from the cheap places: a $TZ that names a zone, else
// /etc/localtime's link into the zoneinfo tree. Otherwise it's empty, and
// hides no clock.
//
// Local's place is where tzdata puts its zone's main city: zone1970.tab's
// coordinates, else zone.tab's, beside the zone files. Sunrise and sunset
// (SPEC.md §15) fall back to it when no location is set. A zone in neither,
// such as UTC, has no place.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, time.Now(), time.Local, systemNames()))
}

// Where local's name comes from, so tests can stand in.
type names struct {
	// tz is $TZ, and tzSet whether it's set at all: set but empty is UTC.
	tz    string
	tzSet bool
	// localtime is /etc/localtime, normally a link into the zoneinfo tree.
	localtime string
	// tabs are the zone tables to look local's place up in, best first.
	tabs []string
}

func systemNames() names {
	n := names{localtime: "/etc/localtime"}
	n.tz, n.tzSet = os.LookupEnv("TZ")
	// Where Go looks for zone files, $ZONEINFO first when it's a folder.
	dirs := []string{"/usr/share/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo"}
	if z := os.Getenv("ZONEINFO"); z != "" {
		dirs = append([]string{z}, dirs...)
	}
	for _, dir := range dirs {
		n.tabs = append(n.tabs, filepath.Join(dir, "zone1970.tab"), filepath.Join(dir, "zone.tab"))
	}
	return n
}

// place is where tzdata puts a zone's main city, in decimal degrees, north
// and east positive.
type place struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	City      string  `json:"city"`
}

type period struct {
	Start int64 `json:"start"`
	// Offset is in minutes, with a fraction for the offsets with seconds
	// that some zones had before 1972.
	Offset float64 `json:"offset"`
	Abbr   string  `json:"abbr"`
}

type zone struct {
	Zone    string   `json:"zone"`
	Place   *place   `json:"place,omitempty"`
	Periods []period `json:"periods,omitempty"`
	Error   string   `json:"error,omitempty"`
}

type output struct {
	Local zone   `json:"local"`
	Zones []zone `json:"zones"`
}

func run(args []string, stdout, stderr io.Writer, now time.Time, local *time.Location, n names) int {
	flags := flag.NewFlagSet("tide-tz", flag.ContinueOnError)
	flags.SetOutput(stderr)
	from := flags.String("from", "", "the `RFC3339` time to start at (default now)")
	days := flags.Int("days", 400, "how many `days` of periods to list")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	start := now
	if *from != "" {
		t, err := time.Parse(time.RFC3339, *from)
		if err != nil {
			fmt.Fprintf(stderr, "tide-tz: --from: %v\n", err)
			return 2
		}
		start = t
	}
	if *days < 1 || *days > 3660 {
		fmt.Fprintln(stderr, "tide-tz: --days must be from 1 to 3660")
		return 2
	}
	end := start.Add(time.Duration(*days) * 24 * time.Hour)
	out := output{
		Local: zone{Periods: periods(local, start, end)},
		Zones: []zone{},
	}
	if name, err := localName(n); err != nil {
		// Local's periods still stand; only the clock to hide is unknown.
		out.Local.Error = fmt.Sprintf("naming the local zone: %v", err)
	} else if name != "" {
		// Keep the name only if it means the zone Go actually uses: a $TZ
		// or link Go couldn't load leaves time.Local as UTC.
		if loc, err := time.LoadLocation(name); err == nil && slices.Equal(periods(loc, start, end), out.Local.Periods) {
			out.Local.Zone = name
			out.Local.Place = placeOf(name, n.tabs, stderr)
		}
	}
	for _, name := range flags.Args() {
		out.Zones = append(out.Zones, describe(name, start, end))
	}
	if err := json.NewEncoder(stdout).Encode(out); err != nil {
		fmt.Fprintf(stderr, "tide-tz: %v\n", err)
		return 1
	}
	return 0
}

// localName is the zone ID of the local zone, or "" when it isn't to hand.
// The error is for /etc/localtime failing to read in a way that isn't
// simply its being a copy rather than a link.
func localName(n names) (string, error) {
	name, err := rawLocalName(n)
	// The posix/ and right/ copies of the tree hold the same zones.
	name = strings.TrimPrefix(strings.TrimPrefix(name, "posix/"), "right/")
	if name == "Etc/UTC" {
		// The name /etc/localtime links to; clocks.json says UTC.
		name = "UTC"
	}
	return name, err
}

func rawLocalName(n names) (string, error) {
	if n.tzSet {
		tz := strings.TrimPrefix(n.tz, ":")
		if tz == "" {
			return "UTC", nil
		}
		if strings.HasPrefix(tz, "/") {
			// A zone file named by path: no ID to compare.
			return "", nil
		}
		return tz, nil
	}
	target, err := os.Readlink(n.localtime)
	if errors.Is(err, os.ErrNotExist) {
		// No /etc/localtime is UTC, for Go as for libc.
		return "UTC", nil
	}
	if errors.Is(err, syscall.EINVAL) {
		// A copied file rather than a link: no ID to compare.
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if i := strings.LastIndex(target, "zoneinfo/"); i >= 0 {
		return target[i+len("zoneinfo/"):], nil
	}
	return "", nil
}

// The tzdata areas a canonical zone ID starts with (SPEC.md §7.3). Link
// names such as US/Pacific and GB fall outside them.
var areas = []string{
	"Africa/", "America/", "Antarctica/", "Arctic/", "Asia/", "Atlantic/",
	"Australia/", "Europe/", "Indian/", "Pacific/",
}

func describe(name string, start, end time.Time) zone {
	canonical := name == "UTC"
	for _, area := range areas {
		canonical = canonical || strings.HasPrefix(name, area)
	}
	// America//New_York loads New York but wouldn't match local's ID.
	canonical = canonical && path.Clean(name) == name
	if !canonical {
		return zone{Zone: name, Error: fmt.Sprintf(
			"unknown time zone %s; use a zone ID from timedatectl list-timezones, such as America/Los_Angeles", name)}
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return zone{Zone: name, Error: err.Error()}
	}
	return zone{Zone: name, Periods: periods(loc, start, end)}
}

// periods lists the spans of constant offset and abbreviation from start to
// end. Go doesn't expose a zone's transitions, so it steps an hour at a
// time and narrows each change to the second; tzdata changes no more often
// than that.
func periods(loc *time.Location, start, end time.Time) []period {
	at := func(t time.Time) period {
		abbr, offset := t.In(loc).Zone()
		return period{Start: t.UnixMilli(), Offset: float64(offset) / 60, Abbr: abbr}
	}
	start = start.Truncate(time.Second)
	cur := at(start)
	list := []period{cur}
	for t := start; t.Before(end); {
		next := t.Add(time.Hour)
		p := at(next)
		if p.Offset != cur.Offset || p.Abbr != cur.Abbr {
			lo, hi := t, next
			for hi.Sub(lo) > time.Second {
				mid := lo.Add(hi.Sub(lo) / 2).Truncate(time.Second)
				if q := at(mid); q.Offset == cur.Offset && q.Abbr == cur.Abbr {
					lo = mid
				} else {
					hi = mid
				}
			}
			cur = at(hi)
			list = append(list, cur)
		}
		t = next
	}
	return list
}

// placeOf is the zone's place in the first of tabs that lists it, or nil.
// A table that's missing is skipped; one that can't be read is reported
// and skipped, since a place is only a fallback.
func placeOf(name string, tabs []string, stderr io.Writer) *place {
	for _, tab := range tabs {
		data, err := os.ReadFile(tab)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			fmt.Fprintf(stderr, "tide-tz: %v\n", err)
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			// Country codes, coordinates, zone, and maybe comments.
			f := strings.Split(line, "\t")
			if strings.HasPrefix(line, "#") || len(f) < 3 || f[2] != name {
				continue
			}
			lat, long, ok := coordinates(f[1])
			if !ok {
				fmt.Fprintf(stderr, "tide-tz: %s: bad coordinates %q for %s\n", tab, f[1], name)
				break
			}
			city := strings.ReplaceAll(path.Base(name), "_", " ")
			return &place{Latitude: lat, Longitude: long, City: city}
		}
	}
	return nil
}

// coordinates reads ISO 6709 as the zone tables write it: ±DDMM±DDDMM or
// ±DDMMSS±DDDMMSS, as decimal degrees to four places.
func coordinates(s string) (float64, float64, bool) {
	var split int
	switch len(s) {
	case 11:
		split = 5
	case 15:
		split = 7
	default:
		return 0, 0, false
	}
	lat, ok := degrees(s[:split], 2)
	if !ok {
		return 0, 0, false
	}
	long, ok := degrees(s[split:], 3)
	if !ok {
		return 0, 0, false
	}
	return lat, long, true
}

func degrees(s string, width int) (float64, bool) {
	sign := 1.0
	switch s[0] {
	case '+':
	case '-':
		sign = -1
	default:
		return 0, false
	}
	digits := s[1:]
	if len(digits) != width+2 && len(digits) != width+4 {
		return 0, false
	}
	value := 0.0
	scale := 1.0
	for i := 0; i < len(digits); {
		n := 2
		if i == 0 {
			n = width
		}
		part, err := strconv.Atoi(digits[i : i+n])
		if err != nil || (i > 0 && part >= 60) {
			return 0, false
		}
		value += float64(part) / scale
		scale *= 60
		i += n
	}
	return sign * math.Round(value*10000) / 10000, true
}
