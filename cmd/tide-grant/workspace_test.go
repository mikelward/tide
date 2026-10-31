package main

import (
	"bytes"
	"testing"
)

func TestWorkspaceValue(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"ASCII punctuation and spaces go", "PR-12 login", "PR12login"},
		{"accented Latin, composed", "café", "café"},
		{"accented Latin, decomposed, comes out composed", "café", "café"},
		{"Cyrillic", "Привет, мир", "Приветмир"},
		{"CJK", "日本語 メモ", "日本語メモ"},
		{"Arabic-Indic and Devanagari digits", "build-١٢ १", "build١٢१"},
		{"other numbers", "Ⅻ ½", "Ⅻ½"},
		{"emoji go", "🚀 launch ✨", "launch"},
		{"control characters go", "a\tb\nc\x00d​e", "abcde"},
		{"symbols go", "a+b=c$ €5", "abc5"},
		{"a mark with no letter goes", "-́-", ""},
		{"jamo a dash kept apart are composed", "ᄀ-ᅡ", "가"},
		{"none gives the empty string", "--- !!", ""},
		{"bytes that aren't UTF-8 go", "a\xffb", "ab"},
	}
	for _, tt := range tests {
		if got := workspaceValue(tt.in); got != tt.want {
			t.Errorf("%s: workspaceValue(%q) = %q, want %q", tt.name, tt.in, got, tt.want)
		}
	}
}

func TestWorkspaceNameFlag(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if got := run([]string{"--workspace-name", "--", "-PR-12 café"}, nil, &stdout, &stderr); got != 0 {
		t.Fatalf("exit %d, stderr %q", got, stderr.String())
	}
	if got, want := stdout.String(), "PR12café\n"; got != want {
		t.Errorf("printed %q, want %q", got, want)
	}
	for _, args := range [][]string{
		{"--workspace-name"},
		{"--workspace-name", "--", "a", "b"},
		{"--workspace-name", "--classes", "--", "a"},
	} {
		stdout.Reset()
		stderr.Reset()
		if got := run(args, nil, &stdout, &stderr); got != 2 {
			t.Errorf("%q: exit %d, want 2", args, got)
		}
	}
}
