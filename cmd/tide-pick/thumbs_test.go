package main

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Each line --thumbnails printed, path to thumbnail ("" for none).
func thumbLines(t *testing.T, out string) map[string]string {
	t.Helper()
	got := map[string]string{}
	for _, line := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
		path, thumb, ok := strings.Cut(line, "\t")
		if !ok {
			t.Fatalf("a line with no tab: %q", line)
		}
		got[path] = thumb
	}
	return got
}

func runThumbs(t *testing.T, paths ...string) (map[string]string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := run(append([]string{"--thumbnails"}, paths...), &stdout, &stderr, nil)
	return thumbLines(t, stdout.String()), stderr.String(), code
}

func pngSize(t *testing.T, path string) (int, int) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	c, err := png.DecodeConfig(f)
	if err != nil {
		t.Fatal(err)
	}
	return c.Width, c.Height
}

func TestThumbnailsAreSmallAndCached(t *testing.T) {
	cache := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cache)
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	t.Setenv("XDG_DATA_DIRS", t.TempDir())
	dir := t.TempDir()
	wide := filepath.Join(dir, "wide.jpg")
	tall := filepath.Join(dir, "tall.png")
	small := filepath.Join(dir, "small.png")
	writeJPEG(t, wide, 3840, 2160)
	writePNG(t, tall, 1080, 1920)
	writePNG(t, small, 64, 36)
	got, stderr, code := runThumbs(t, wide, tall, small)
	if code != 0 || stderr != "" {
		t.Fatalf("got %d %q", code, stderr)
	}
	if len(got) != 3 {
		t.Fatalf("got %v: a line for each picture", got)
	}
	want := map[string][2]int{wide: {512, 288}, tall: {288, 512}, small: {64, 36}}
	for path, size := range want {
		thumb := got[path]
		if !strings.HasPrefix(thumb, filepath.Join(cache, "thumbnails", "x-large")+"/") || !strings.HasSuffix(thumb, ".png") {
			t.Fatalf("%s's thumbnail is %q, not in the x-large cache", path, thumb)
		}
		if w, h := pngSize(t, thumb); w != size[0] || h != size[1] {
			t.Errorf("%s's thumbnail is %dx%d, want %dx%d", path, w, h, size[0], size[1])
		}
		data, err := os.ReadFile(thumb)
		if err != nil {
			t.Fatal(err)
		}
		text := pngText(data)
		if text["Thumb::URI"] != "file://"+path {
			t.Errorf("%s's Thumb::URI is %q", path, text["Thumb::URI"])
		}
		info, _ := os.Stat(path)
		if text["Thumb::MTime"] != strconv.FormatInt(info.ModTime().Unix(), 10) {
			t.Errorf("%s's Thumb::MTime is %q", path, text["Thumb::MTime"])
		}
		if info, _ := os.Stat(thumb); info.Mode().Perm() != 0o600 {
			t.Errorf("%s's thumbnail is %v, not the user's alone", path, info.Mode().Perm())
		}
	}
	// Made once: the next run prints the same one without making it again.
	before, _ := os.Stat(got[wide])
	again, _, _ := runThumbs(t, wide)
	after, _ := os.Stat(again[wide])
	if again[wide] != got[wide] || !after.ModTime().Equal(before.ModTime()) {
		t.Errorf("the thumbnail was made again")
	}
}

func TestAChangedPictureGetsANewThumbnail(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	path := filepath.Join(dir, "a.png")
	writePNG(t, path, 1000, 1000)
	first, _, _ := runThumbs(t, path)
	// Changed since, as a newer picture saved over it would be.
	writePNG(t, path, 2000, 1000)
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	second, _, _ := runThumbs(t, path)
	if second[path] != first[path] {
		t.Fatalf("the thumbnail moved: %q, then %q", first[path], second[path])
	}
	if w, h := pngSize(t, second[path]); w != 512 || h != 256 {
		t.Errorf("the thumbnail is still the old picture's: %dx%d", w, h)
	}
}

func TestThumbnailsAverageThePixelsTheyCover(t *testing.T) {
	// Black and white columns, a pixel each, make an even gray.
	src := image.NewRGBA(image.Rect(0, 0, 1024, 2))
	for x := 0; x < 1024; x++ {
		v := uint8(0)
		if x%2 == 1 {
			v = 254
		}
		src.Set(x, 0, color.RGBA{v, v, v, 255})
		src.Set(x, 1, color.RGBA{v, v, v, 255})
	}
	got := shrink(src, 512)
	if b := got.Bounds(); b.Dx() != 512 || b.Dy() != 1 {
		t.Fatalf("got %v", b)
	}
	if c := color.RGBAModel.Convert(got.At(100, 0)).(color.RGBA); c != (color.RGBA{127, 127, 127, 255}) {
		t.Errorf("got %v, want an even gray", c)
	}
}

func TestOtherTypesGoToAThumbnailerOrToTheGrid(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	data := t.TempDir()
	t.Setenv("XDG_DATA_HOME", data)
	t.Setenv("XDG_DATA_DIRS", t.TempDir())
	dir := t.TempDir()
	svg := filepath.Join(dir, "a.svg")
	jxl := filepath.Join(dir, "b.jxl")
	writeFile(t, svg, []byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 9"/>`))
	writeFile(t, jxl, bicycles)
	// A thumbnailer for SVG only, which copies a PNG it was given to %o,
	// and logs its arguments.
	made := filepath.Join(dir, "made.png")
	writePNG(t, made, 160, 90)
	log := filepath.Join(dir, "args")
	script := filepath.Join(dir, "thumb.sh")
	writeFile(t, script, []byte("#!/bin/sh\necho \"$@\" > "+log+"\ncp "+made+" \"$2\"\n"))
	if err := os.Chmod(script, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(data, "thumbnailers", "svg.thumbnailer"),
		[]byte("[Thumbnailer Entry]\nTryExec="+script+"\nExec="+script+" %i %o --size=%s %u\nMimeType=image/svg+xml;image/svg+xml-compressed;\n"))
	got, stderr, code := runThumbs(t, svg, jxl)
	if code != 0 || stderr != "" {
		t.Fatalf("got %d %q", code, stderr)
	}
	if got[jxl] != "" {
		t.Errorf("a JPEG XL with no thumbnailer got %q, where the grid should draw it", got[jxl])
	}
	if got[svg] == "" {
		t.Fatalf("the SVG's thumbnailer wasn't used")
	}
	args, _ := os.ReadFile(log)
	if !strings.HasPrefix(string(args), svg+" ") || !strings.Contains(string(args), " --size=512 file://"+svg) {
		t.Errorf("the thumbnailer was run as %q", args)
	}
	thumb, _ := os.ReadFile(got[svg])
	if pngText(thumb)["Thumb::URI"] != "file://"+svg {
		t.Errorf("the thumbnailer's PNG wasn't tagged with what it's of")
	}
}

func TestAPictureThatWontDecodeIsSaid(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.jpg")
	good := filepath.Join(dir, "good.png")
	writeFile(t, bad, []byte("not a JPEG"))
	writePNG(t, good, 600, 600)
	got, stderr, code := runThumbs(t, bad, filepath.Join(dir, "gone.png"), good)
	if code != 1 {
		t.Errorf("got %d, want 1", code)
	}
	if got[bad] != "" || got[filepath.Join(dir, "gone.png")] != "" || got[good] == "" {
		t.Errorf("got %v: every picture has its line, the good one its thumbnail", got)
	}
	if !strings.Contains(stderr, "couldn't make a thumbnail of "+bad) {
		t.Errorf("stderr doesn't name the bad picture: %q", stderr)
	}
}

func TestThumbnailerExecQuotingIsTheDesktopEntrySpecs(t *testing.T) {
	for _, c := range []struct {
		exec string
		want []string
	}{
		{"helper %i %o", []string{"helper", "%i", "%o"}},
		{`helper "%i" %o`, []string{"helper", "%i", "%o"}},
		{`"/opt/My Tools/thumb" -s %s "%u"`, []string{"/opt/My Tools/thumb", "-s", "%s", "%u"}},
		{`helper "a \"b\" \\c" %o`, []string{"helper", `a "b" \c`, "%o"}},
		{"  helper\t%i  ", []string{"helper", "%i"}},
		{`helper ""`, []string{"helper", ""}},
	} {
		got, err := execArgs(c.exec)
		if err != nil || strings.Join(got, "|") != strings.Join(c.want, "|") || len(got) != len(c.want) {
			t.Errorf("execArgs(%q) = %q, %v; want %q", c.exec, got, err, c.want)
		}
	}
	if _, err := execArgs(`helper "%i`); err == nil {
		t.Errorf("an unclosed quote was taken")
	}
}
