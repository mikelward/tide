package main

// tide-pick --list lists the wallpapers the settings panel's grid shows
// (SPEC.md §16), each with its size, so the grid can put the pictures your
// monitors' shape first without decoding every one.
//
//	tide-pick --list DIR...
//
// It prints a line for each picture under each DIR, following links, six
// folders deep at most: its width, its height and its path, separated by
// tabs. A size it can't read from the file's header is 0 0. A DIR that isn't
// there is passed over. So is a link to nothing, or a file that goes as it
// lists, which it names on stderr. A DIR it can't read all of still lists
// what it could, then exits 2 with why on stderr.

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/xml"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The pictures listed, by extension: what Qt decodes, JPEG XL where
// kimageformats is installed and SVG where Qt's SVG plugin is.
var pictureTypes = map[string]bool{".jpg": true, ".jpeg": true, ".png": true, ".webp": true, ".jxl": true, ".svg": true}

// As deep as `find -maxdepth 6` goes below a folder.
const listDepth = 6

func list(dirs []string, stdout, stderr io.Writer) int {
	out := bufio.NewWriter(stdout)
	defer out.Flush()
	status := 0
	fail := func(err error) {
		fmt.Fprintf(stderr, "tide-pick: %v\n", err)
		status = 2
	}
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			fail(err)
		}
		for _, e := range entries {
			path := filepath.Join(dir, e.Name())
			// Stat, not the entry's own type, follows a link.
			info, err := os.Stat(path)
			if errors.Is(err, fs.ErrNotExist) {
				// A link to nothing, or a file gone since its folder was
				// read, is no picture that couldn't be listed. So it's
				// passed over, as a DIR that isn't there is and as find -L
				// did, and said for the log.
				fmt.Fprintf(stderr, "tide-pick: passing over %s, a link to nothing or a file just gone\n", path)
				continue
			}
			if err != nil {
				fail(err)
				continue
			}
			if info.IsDir() {
				if depth < listDepth {
					walk(path, depth+1)
				}
				continue
			}
			if !info.Mode().IsRegular() || !pictureTypes[strings.ToLower(filepath.Ext(path))] || strings.ContainsAny(path, "\n\r") {
				continue
			}
			w, h := pictureSize(path)
			fmt.Fprintf(out, "%s\t%s\t%s\n", formatSize(w), formatSize(h), path)
		}
	}
	for _, dir := range dirs {
		info, err := os.Stat(dir)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			fail(err)
			continue
		}
		if info.IsDir() {
			walk(dir, 1)
		}
	}
	return status
}

func formatSize(v float64) string {
	return strconv.FormatFloat(v, 'f', -1, 64)
}

// The picture's width and height in pixels, as its header says, or 0, 0
// when it can't be read. An SVG's is its viewBox's, or its width and height.
func pictureSize(path string) (float64, float64) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	r := bufio.NewReader(f)
	var w, h float64
	switch strings.ToLower(filepath.Ext(path)) {
	case ".webp":
		w, h = webpSize(r)
	case ".jxl":
		w, h = jxlSize(r)
	case ".svg":
		w, h = svgSize(r)
	default:
		if c, _, err := image.DecodeConfig(r); err == nil {
			w, h = float64(c.Width), float64(c.Height)
		}
	}
	if !(w > 0 && h > 0) {
		return 0, 0
	}
	return w, h
}

// A WebP's canvas: lossy (VP8), lossless (VP8L) or extended (VP8X).
func webpSize(r io.Reader) (float64, float64) {
	b := make([]byte, 30)
	if _, err := io.ReadFull(r, b); err != nil || string(b[0:4]) != "RIFF" || string(b[8:12]) != "WEBP" {
		return 0, 0
	}
	switch string(b[12:16]) {
	case "VP8 ":
		if b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a {
			return 0, 0
		}
		return float64(binary.LittleEndian.Uint16(b[26:]) & 0x3fff), float64(binary.LittleEndian.Uint16(b[28:]) & 0x3fff)
	case "VP8L":
		if b[20] != 0x2f {
			return 0, 0
		}
		bits := binary.LittleEndian.Uint32(b[21:])
		return float64(bits&0x3fff + 1), float64(bits>>14&0x3fff + 1)
	case "VP8X":
		u24 := func(p []byte) uint32 { return uint32(p[0]) | uint32(p[1])<<8 | uint32(p[2])<<16 }
		return float64(u24(b[24:]) + 1), float64(u24(b[27:]) + 1)
	}
	return 0, 0
}

// The JPEG XL container's signature box; a bare codestream starts FF 0A.
var jxlContainer = []byte{0, 0, 0, 0x0c, 'J', 'X', 'L', ' ', 0x0d, 0x0a, 0x87, 0x0a}

// A JPEG XL's size, from its codestream's SizeHeader, in a container's
// jxlc box or its first jxlp box, or bare.
func jxlSize(r io.Reader) (float64, float64) {
	// A SizeHeader is at most 9 bytes; the bits reader says if it's cut short.
	head := readUpTo(r, 2+16)
	if bytes.HasPrefix(head, []byte{0xff, 0x0a}) {
		return jxlSizeHeader(head[2:])
	}
	if !bytes.HasPrefix(head, jxlContainer) {
		return 0, 0
	}
	r = io.MultiReader(bytes.NewReader(head[len(jxlContainer):]), r)
	for {
		box := make([]byte, 8)
		if _, err := io.ReadFull(r, box); err != nil {
			return 0, 0
		}
		size := uint64(binary.BigEndian.Uint32(box))
		kind := string(box[4:])
		header := uint64(8)
		if size == 1 {
			large := make([]byte, 8)
			if _, err := io.ReadFull(r, large); err != nil {
				return 0, 0
			}
			size = binary.BigEndian.Uint64(large)
			header = 16
		}
		if kind == "jxlc" || kind == "jxlp" {
			skip := 0
			if kind == "jxlp" {
				skip = 4 // the part's index
			}
			code := readUpTo(r, skip+2+16)
			if len(code) < skip+2 || code[skip] != 0xff || code[skip+1] != 0x0a {
				return 0, 0
			}
			return jxlSizeHeader(code[skip+2:])
		}
		if size == 0 || size < header {
			return 0, 0
		}
		if _, err := io.CopyN(io.Discard, r, int64(size-header)); err != nil {
			return 0, 0
		}
	}
}

// Up to n bytes of r, fewer at its end.
func readUpTo(r io.Reader, n int) []byte {
	b := make([]byte, n)
	got, _ := io.ReadFull(r, b)
	return b[:got]
}

// Reads a JPEG XL's bits, least significant first.
type jxlBits struct {
	b   []byte
	pos int
	bad bool
}

func (j *jxlBits) u(n int) uint32 {
	var v uint32
	for i := 0; i < n; i++ {
		if j.pos/8 >= len(j.b) {
			j.bad = true
			return 0
		}
		v |= uint32(j.b[j.pos/8]>>(j.pos%8)&1) << i
		j.pos++
	}
	return v
}

// U32(u(9), u(13), u(18), u(30)), as SizeHeader codes a side, plus 1.
func (j *jxlBits) side() uint32 {
	return 1 + j.u([]int{9, 13, 18, 30}[j.u(2)])
}

// The ratios a SizeHeader names, width over height, by its 3-bit code.
var jxlRatios = [8][2]uint32{{0, 0}, {1, 1}, {12, 10}, {4, 3}, {3, 2}, {16, 9}, {5, 4}, {2, 1}}

// A SizeHeader (ISO/IEC 18181-1 §D.2): the height, then a ratio or the
// width.
func jxlSizeHeader(b []byte) (float64, float64) {
	j := &jxlBits{b: b}
	small := j.u(1) == 1
	var h uint32
	if small {
		h = 8 * (1 + j.u(5))
	} else {
		h = j.side()
	}
	var w uint32
	if ratio := j.u(3); ratio != 0 {
		w = uint32(uint64(h) * uint64(jxlRatios[ratio][0]) / uint64(jxlRatios[ratio][1]))
	} else if small {
		w = 8 * (1 + j.u(5))
	} else {
		w = j.side()
	}
	if j.bad {
		return 0, 0
	}
	return float64(w), float64(h)
}

// An SVG's shape: its viewBox's, else its width and height in plain
// numbers or px. One in percent, or with neither, has none.
func svgSize(r io.Reader) (float64, float64) {
	d := xml.NewDecoder(io.LimitReader(r, 1<<20))
	d.Strict = false
	for {
		t, err := d.Token()
		if err != nil {
			return 0, 0
		}
		e, ok := t.(xml.StartElement)
		if !ok {
			continue
		}
		if e.Name.Local != "svg" {
			return 0, 0
		}
		var w, h, box string
		for _, a := range e.Attr {
			switch a.Name.Local {
			case "width":
				w = a.Value
			case "height":
				h = a.Value
			case "viewBox":
				box = a.Value
			}
		}
		if f := strings.FieldsFunc(box, func(r rune) bool { return r == ' ' || r == ',' || r == '\t' || r == '\n' }); len(f) == 4 {
			bw, err1 := strconv.ParseFloat(f[2], 64)
			bh, err2 := strconv.ParseFloat(f[3], 64)
			if err1 == nil && err2 == nil {
				return bw, bh
			}
		}
		px := func(s string) float64 {
			v, err := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(s), "px"), 64)
			if err != nil {
				return 0
			}
			return v
		}
		return px(w), px(h)
	}
}
