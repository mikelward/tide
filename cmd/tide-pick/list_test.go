package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/godbus/dbus/v5"
)

// testdata's WebPs were made by ImageMagick: lossy (VP8), lossless (VP8L)
// and, with alpha, extended (VP8X).

func writeJPEG(t *testing.T, path string, w, h int) {
	t.Helper()
	var b bytes.Buffer
	if err := jpeg.Encode(&b, image.NewRGBA(image.Rect(0, 0, w, h)), nil); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, b.Bytes())
}

func writePNG(t *testing.T, path string, w, h int) {
	t.Helper()
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path, b.Bytes())
}

func writeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// A JPEG XL codestream's start: libjxl's conformance "bicycles", 1024 by
// 631, with its height coded in 13 bits and its width given apart.
var bicycles = []byte{0xff, 0x0a, 0xb2, 0x13, 0xe8, 0x7f, 0x0c, 0x08, 0x81, 0x00, 0x00, 0x8e, 0x94, 0x01}

// A box of the JPEG XL container.
func box(kind string, data []byte) []byte {
	b := binary.BigEndian.AppendUint32(nil, uint32(8+len(data)))
	return append(append(b, kind...), data...)
}

func TestPictureSizes(t *testing.T) {
	dir := t.TempDir()
	writeJPEG(t, filepath.Join(dir, "a.jpg"), 64, 36)
	writePNG(t, filepath.Join(dir, "a.png"), 30, 20)
	container := append(append([]byte{}, jxlContainer...), box("ftyp", []byte("jxl \x00\x00\x00\x00jxl "))...)
	writeFile(t, filepath.Join(dir, "bare.jxl"), bicycles)
	writeFile(t, filepath.Join(dir, "boxed.jxl"), append(container, box("jxlc", bicycles)...))
	writeFile(t, filepath.Join(dir, "parts.jxl"), append(append(container, box("jbrd", []byte{1, 2, 3})...), box("jxlp", append([]byte{0, 0, 0, 0}, bicycles...))...))
	// Height 8 × 5, small; ratio 16:9; so 71 × 40.
	writeFile(t, filepath.Join(dir, "ratio.jxl"), append([]byte{0xff, 0x0a, 0x1 | 4<<1 | 1<<6, 1}, make([]byte, 10)...))
	// Height 8 × 3, small; no ratio; width 8 × 4.
	writeFile(t, filepath.Join(dir, "small.jxl"), append([]byte{0xff, 0x0a, 0x1 | 2<<1, 3 << 1}, make([]byte, 10)...))
	writeFile(t, filepath.Join(dir, "box.svg"), []byte(`<?xml version="1.0"?><!-- drawn --><svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 2560 1600"/>`))
	writeFile(t, filepath.Join(dir, "sized.svg"), []byte(`<svg width="1920px" height="1080"></svg>`))
	writeFile(t, filepath.Join(dir, "percent.svg"), []byte(`<svg width="100%" height="100%"></svg>`))
	writeFile(t, filepath.Join(dir, "html.svg"), []byte(`<html></html>`))
	writeFile(t, filepath.Join(dir, "short.jxl"), []byte{0xff, 0x0a})
	writeFile(t, filepath.Join(dir, "junk.jpg"), []byte("not a picture"))
	for _, c := range []struct {
		path string
		w, h float64
	}{
		{filepath.Join(dir, "a.jpg"), 64, 36},
		{filepath.Join(dir, "a.png"), 30, 20},
		{"testdata/lossy.webp", 48, 27},
		{"testdata/lossless.webp", 40, 30},
		{"testdata/extended.webp", 35, 21},
		{filepath.Join(dir, "bare.jxl"), 1024, 631},
		{filepath.Join(dir, "boxed.jxl"), 1024, 631},
		{filepath.Join(dir, "parts.jxl"), 1024, 631},
		{filepath.Join(dir, "ratio.jxl"), 71, 40},
		{filepath.Join(dir, "small.jxl"), 32, 24},
		{filepath.Join(dir, "box.svg"), 2560, 1600},
		{filepath.Join(dir, "sized.svg"), 1920, 1080},
		{filepath.Join(dir, "percent.svg"), 0, 0},
		{filepath.Join(dir, "html.svg"), 0, 0},
		{filepath.Join(dir, "short.jxl"), 0, 0},
		{filepath.Join(dir, "junk.jpg"), 0, 0},
		{filepath.Join(dir, "missing.png"), 0, 0},
	} {
		if w, h := pictureSize(c.path); w != c.w || h != c.h {
			t.Errorf("%s: got %v × %v, want %v × %v", filepath.Base(c.path), w, h, c.w, c.h)
		}
	}
}

func TestListsPicturesWithTheirSizes(t *testing.T) {
	dir := t.TempDir()
	writeJPEG(t, filepath.Join(dir, "a", "Day.JPG"), 16, 9)
	writePNG(t, filepath.Join(dir, "a", "b", "c", "d", "e", "deep.png"), 4, 3)
	writePNG(t, filepath.Join(dir, "a", "b", "c", "d", "e", "f", "deeper.png"), 4, 3)
	writeFile(t, filepath.Join(dir, "a", "notes.txt"), []byte("hi"))
	writeFile(t, filepath.Join(dir, "a", "broken.webp"), []byte("RIFF"))
	other := t.TempDir()
	writePNG(t, filepath.Join(other, "linked.png"), 8, 8)
	if err := os.Symlink(other, filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"--list", filepath.Join(dir, "missing"), dir}, &stdout, &stderr, func() (*dbus.Conn, error) {
		t.Fatal("connected to list")
		return nil, nil
	})
	if code != 0 || stderr.Len() != 0 {
		t.Fatalf("got %d %q", code, stderr.String())
	}
	want := strings.Join([]string{
		"16\t9\t" + filepath.Join(dir, "a", "Day.JPG"),
		"4\t3\t" + filepath.Join(dir, "a", "b", "c", "d", "e", "deep.png"),
		"0\t0\t" + filepath.Join(dir, "a", "broken.webp"),
		"8\t8\t" + filepath.Join(dir, "link", "linked.png"),
	}, "\n") + "\n"
	if stdout.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", stdout.String(), want)
	}
}

func TestListsWhatItCanReadThenFails(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every folder")
	}
	dir := t.TempDir()
	writePNG(t, filepath.Join(dir, "a.png"), 2, 1)
	locked := filepath.Join(dir, "locked")
	writePNG(t, filepath.Join(locked, "b.png"), 2, 1)
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o755) })
	var stdout, stderr bytes.Buffer
	code := run([]string{"--list", dir}, &stdout, &stderr, nil)
	if code != 2 || !strings.Contains(stderr.String(), "locked") {
		t.Fatalf("got %d %q", code, stderr.String())
	}
	if stdout.String() != "2\t1\t"+filepath.Join(dir, "a.png")+"\n" {
		t.Fatalf("got %q", stdout.String())
	}
}
