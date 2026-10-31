package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"
)

// A key file read as GLib's GKeyFile reads one (glib/gkeyfile.c, GLib
// 2.91), since the files read here (VPN plugins' .name files, and the
// description an auth dialog prints in external UI mode) are written for
// it. Values are kept raw and unescaped as they're read, as GKeyFile
// does:
//
//   - Lines end at "\n", with a "\r" before it dropped.
//   - Leading ASCII whitespace on a line is skipped. Then an empty line,
//     or one starting with "#", is a comment.
//   - "[NAME]", with only spaces or tabs after it, starts a group. NAME is
//     up to the last "]", and can't be empty or hold "[", "]" or a
//     control character.
//   - Anything else must be KEY=VALUE, in a group: the key loses trailing
//     whitespace and the value leading whitespace, but the value's
//     trailing whitespace is kept. A key can't be empty, start or end with
//     a space, or hold "[" or "]" except as a locale, KEY[LOCALE], which is
//     a key of its own.
//   - A later key replaces an earlier one, and a group named twice is one
//     group.
type keyFile struct {
	groups []string
	values map[string]map[string]string
}

func parseKeyFile(data []byte) (*keyFile, error) {
	kf := &keyFile{values: map[string]map[string]string{}}
	group := ""
	lines := strings.Split(string(data), "\n")
	for n, line := range lines {
		line = strings.TrimSuffix(line, "\r")
		start := strings.TrimLeft(line, asciiSpace)
		switch {
		case start == "" || start[0] == '#':
		case isGroupLine(start):
			name := start[1:strings.LastIndexByte(start, ']')]
			if !isGroupName(name) {
				return nil, fmt.Errorf("line %d: invalid group name %q", n+1, name)
			}
			if _, ok := kf.values[name]; !ok {
				kf.groups = append(kf.groups, name)
				kf.values[name] = map[string]string{}
			}
			group = name
		case strings.IndexByte(start, '=') > 0:
			if group == "" {
				return nil, fmt.Errorf("line %d: a key before any group", n+1)
			}
			eq := strings.IndexByte(start, '=')
			key := strings.TrimRight(start[:eq], asciiSpace)
			if !isKeyName(key) {
				return nil, fmt.Errorf("line %d: invalid key name %q", n+1, key)
			}
			kf.values[group][key] = strings.TrimLeft(start[eq+1:], asciiSpace)
		default:
			return nil, fmt.Errorf("line %d isn't a key=value pair, a group or a comment", n+1)
		}
	}
	return kf, nil
}

// g_ascii_isspace's set.
const asciiSpace = " \t\n\v\f\r"

func isGroupLine(line string) bool {
	if line[0] != '[' {
		return false
	}
	end := strings.IndexByte(line, ']')
	if end < 0 {
		return false
	}
	return strings.Trim(line[end+1:], " \t") == ""
}

func isGroupName(name string) bool {
	if name == "" {
		return false
	}
	for _, r := range name {
		if r == '[' || r == ']' || (r < 0x80 && unicode.IsControl(r)) {
			return false
		}
	}
	return true
}

func isKeyName(key string) bool {
	base, locale, hasLocale := strings.Cut(key, "[")
	if base == "" || strings.ContainsAny(base, "=]") || base[0] == ' ' || base[len(base)-1] == ' ' {
		return false
	}
	if !hasLocale {
		return true
	}
	if !strings.HasSuffix(locale, "]") {
		return false
	}
	for _, r := range strings.TrimSuffix(locale, "]") {
		if !(unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("-_.@", r)) {
			return false
		}
	}
	return true
}

var errNoKey = errors.New("no such key")

func (kf *keyFile) raw(group, key string) (string, error) {
	v, ok := kf.values[group][key]
	if !ok {
		return "", fmt.Errorf("[%s] %s: %w", group, key, errNoKey)
	}
	return v, nil
}

// str is g_key_file_get_string: \s, \n, \t, \r and \\ unescaped, and any
// other escape, or one at the end, an error.
func (kf *keyFile) str(group, key string) (string, error) {
	v, err := kf.raw(group, key)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	for i := 0; i < len(v); i++ {
		if v[i] != '\\' {
			b.WriteByte(v[i])
			continue
		}
		i++
		if i == len(v) {
			return "", fmt.Errorf("[%s] %s ends in an escape", group, key)
		}
		switch v[i] {
		case 's':
			b.WriteByte(' ')
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case '\\':
			b.WriteByte('\\')
		default:
			return "", fmt.Errorf("[%s] %s holds an invalid escape \\%c", group, key, v[i])
		}
	}
	return b.String(), nil
}

// boolean is g_key_file_get_boolean: true or 1, false or 0, before any
// trailing whitespace.
func (kf *keyFile) boolean(group, key string) (bool, error) {
	v, err := kf.raw(group, key)
	if err != nil {
		return false, err
	}
	switch strings.TrimRight(v, asciiSpace) {
	case "true", "1":
		return true, nil
	case "false", "0":
		return false, nil
	}
	return false, fmt.Errorf("[%s] %s is %q, which isn't a boolean", group, key, v)
}

// integer is g_key_file_get_integer: a decimal integer, surrounding
// whitespace allowed.
func (kf *keyFile) integer(group, key string) (int, error) {
	v, err := kf.raw(group, key)
	if err != nil {
		return 0, err
	}
	n, err := strconv.Atoi(strings.Trim(v, asciiSpace))
	if err != nil {
		return 0, fmt.Errorf("[%s] %s is %q, which isn't an integer", group, key, v)
	}
	return n, nil
}

// optional is a string that's fine to be missing, as libnm and GNOME Shell
// read a plugin's [GNOME] properties: "" when it is.
func (kf *keyFile) optional(group, key string) (string, error) {
	v, err := kf.str(group, key)
	if errors.Is(err, errNoKey) {
		return "", nil
	}
	return v, err
}
