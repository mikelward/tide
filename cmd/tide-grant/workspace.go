package main

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// workspaceValue is a workspace's name as TIDE_WORKSPACE holds it (SPEC.md
// §6.5): its letters and digits (Unicode categories L and N) in any script,
// NFC-normalized. Normalizing first composes a decomposed é (e and U+0301,
// as macOS can hand it over) into a letter that's kept, where the bare mark
// would be dropped; normalizing again composes what dropping the rest put
// side by side (Hangul jamo either side of a dash). Bytes that aren't UTF-8
// read as U+FFFD, which goes.
func workspaceValue(name string) string {
	var b strings.Builder
	for _, r := range norm.NFC.String(name) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
		}
	}
	return norm.NFC.String(b.String())
}
