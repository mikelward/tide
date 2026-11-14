package main

// tide-pick --thumbnails gives each picture the wallpaper grid shows a small
// copy to draw (SPEC.md §16), so a page of them shows at once, rather than
// each picture being decoded whole, one at a time, on Qt's one image thread.
//
//	tide-pick --thumbnails PATH...
//
// For each PATH it prints a line: the PATH and its thumbnail's path,
// tab-separated, or the PATH and a tab alone when it has none, which the
// grid takes as its cue to draw the picture itself. The thumbnails are the
// freedesktop.org thumbnail cache's x-large ones, 512 pixels at most, in
// $XDG_CACHE_HOME/thumbnails, so a file manager's are shared. One there whose
// Thumb::MTime is the picture's is printed first, as it is; the rest are
// made a few at once, in PATH's order, and each printed as it's done. JPEG
// and PNG are made here; any other type by a thumbnailer installed for it,
// a .thumbnailer file in thumbnailers under $XDG_DATA_HOME or $XDG_DATA_DIRS.
// It exits 0 having printed a line for every PATH, or 1 when it couldn't make
// some thumbnail it should have, saying why on stderr.

import (
	"bufio"
	"bytes"
	"context"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/crc32"
	"image"
	"image/draw"
	"image/png"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// The x-large size's longest side, crisp in the grid's cells at 2x.
	thumbSize = 512
	thumbDir  = "x-large"
	// A few at once: each 4K picture decoded takes some 30 MB.
	thumbWorkers = 4
	// A thumbnailer that hangs doesn't hold the grid up for good.
	thumbnailerTimeout = 30 * time.Second
)

// The MIME types of the pictures listed that aren't decoded here, for
// finding a thumbnailer.
var thumbnailerTypes = map[string]string{".webp": "image/webp", ".jxl": "image/jxl", ".svg": "image/svg+xml"}

// A picture still to be given a thumbnail.
type thumbJob struct {
	path, uri, thumb string
	mtime            int64
	exec             []string // its thumbnailer's Exec, or nil for one made here
}

func thumbnails(paths []string, stdout, stderr io.Writer) int {
	out := bufio.NewWriter(stdout)
	var mu sync.Mutex
	status := 0
	// Each line goes out as soon as it's known, so the grid fills as it goes.
	say := func(path, thumb string, err error) {
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			fmt.Fprintf(stderr, "tide-pick: couldn't make a thumbnail of %s: %v\n", path, err)
			status = 1
		}
		fmt.Fprintf(out, "%s\t%s\n", path, thumb)
		out.Flush()
	}
	dir := filepath.Join(cacheHome(), "thumbnails", thumbDir)
	var thumbnailers []thumbnailer
	thumbnailersRead := false
	var jobs []thumbJob
	for _, path := range paths {
		job, err := thumbFor(path, dir)
		if err != nil {
			say(path, "", err)
			continue
		}
		if thumbValid(job.thumb, job.uri, job.mtime) {
			say(path, job.thumb, nil)
			continue
		}
		if mime, ok := thumbnailerTypes[strings.ToLower(filepath.Ext(path))]; ok {
			if !thumbnailersRead {
				thumbnailers = findThumbnailers(stderr)
				thumbnailersRead = true
			}
			job.exec = thumbnailerFor(thumbnailers, mime)
			// With none installed, the grid draws it itself, as it always did.
			if job.exec == nil {
				say(path, "", nil)
				continue
			}
		}
		jobs = append(jobs, job)
	}
	queue := make(chan thumbJob)
	var wg sync.WaitGroup
	for i := 0; i < thumbWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range queue {
				if err := makeThumb(job, dir); err != nil {
					say(job.path, "", err)
				} else {
					say(job.path, job.thumb, nil)
				}
			}
		}()
	}
	for _, job := range jobs {
		queue <- job
	}
	close(queue)
	wg.Wait()
	return status
}

func cacheHome() string {
	if dir := os.Getenv("XDG_CACHE_HOME"); filepath.IsAbs(dir) {
		return dir
	}
	return filepath.Join(os.Getenv("HOME"), ".cache")
}

// The picture's URI, its mtime and where its thumbnail goes: the MD5 of the
// URI, as the thumbnail spec names it.
func thumbFor(path, dir string) (thumbJob, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return thumbJob{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return thumbJob{}, err
	}
	uri := (&url.URL{Scheme: "file", Path: abs}).String()
	sum := md5.Sum([]byte(uri))
	return thumbJob{
		path:  path,
		uri:   uri,
		thumb: filepath.Join(dir, hex.EncodeToString(sum[:])+".png"),
		mtime: info.ModTime().Unix(),
	}, nil
}

// Whether the thumbnail at thumb is for uri as it was last changed, at
// mtime: its Thumb::URI and Thumb::MTime say so.
func thumbValid(thumb, uri string, mtime int64) bool {
	data, err := os.ReadFile(thumb)
	if err != nil {
		// Not there yet is the usual case, so it's made, saying nothing.
		return false
	}
	text := pngText(data)
	return text["Thumb::URI"] == uri && text["Thumb::MTime"] == strconv.FormatInt(mtime, 10)
}

var pngSignature = []byte("\x89PNG\r\n\x1a\n")

// A PNG's tEXt chunks, by keyword: empty for one that isn't a PNG.
func pngText(data []byte) map[string]string {
	text := map[string]string{}
	if !bytes.HasPrefix(data, pngSignature) {
		return text
	}
	for p := len(pngSignature); p+12 <= len(data); {
		n := int(binary.BigEndian.Uint32(data[p:]))
		if n < 0 || p+12+n > len(data) {
			break
		}
		kind := string(data[p+4 : p+8])
		if kind == "tEXt" {
			if k, v, ok := bytes.Cut(data[p+8:p+8+n], []byte{0}); ok {
				if _, seen := text[string(k)]; !seen {
					text[string(k)] = string(v)
				}
			}
		}
		if kind == "IEND" {
			break
		}
		p += 12 + n
	}
	return text
}

// The PNG data with tEXt chunks naming the picture added after its header,
// as the thumbnail spec has a thumbnail say what it's of.
func withThumbText(data []byte, uri string, mtime int64) ([]byte, error) {
	// The signature, then IHDR: 4 bytes of length, 4 of type, 13 of data
	// and 4 of CRC.
	const header = 8 + 4 + 4 + 13 + 4
	if !bytes.HasPrefix(data, pngSignature) || len(data) < header || string(data[12:16]) != "IHDR" {
		return nil, errors.New("not a PNG")
	}
	var out bytes.Buffer
	out.Write(data[:header])
	for _, kv := range [][2]string{{"Thumb::URI", uri}, {"Thumb::MTime", strconv.FormatInt(mtime, 10)}, {"Software", "tide-pick"}} {
		body := append(append([]byte(kv[0]), 0), kv[1]...)
		out.Write(binary.BigEndian.AppendUint32(nil, uint32(len(body))))
		chunk := append([]byte("tEXt"), body...)
		out.Write(chunk)
		out.Write(binary.BigEndian.AppendUint32(nil, crc32.ChecksumIEEE(chunk)))
	}
	out.Write(data[header:])
	return out.Bytes(), nil
}

func makeThumb(job thumbJob, dir string) error {
	var data []byte
	var err error
	if job.exec != nil {
		data, err = runThumbnailer(job)
	} else {
		data, err = decodeThumb(job.path)
	}
	if err != nil {
		return err
	}
	if data, err = withThumbText(data, job.uri, job.mtime); err != nil {
		return err
	}
	// The spec's: the cache is the user's alone, and a thumbnail appears
	// whole or not at all.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".tide-pick-*.png")
	if err != nil {
		return err
	}
	_, werr := f.Write(data)
	cerr := f.Close()
	if err := errors.Join(werr, cerr); err != nil {
		os.Remove(f.Name())
		return err
	}
	if err := os.Rename(f.Name(), job.thumb); err != nil {
		os.Remove(f.Name())
		return err
	}
	return nil
}

// A JPEG or PNG made small and encoded as PNG.
func decodeThumb(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	src, _, err := image.Decode(bufio.NewReader(f))
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	if err := png.Encode(&out, shrink(src, thumbSize)); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// src with its longest side at most size, each pixel the average of the
// ones it covers; one already that small, as it is.
func shrink(src image.Image, size int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= size && h <= size {
		return src
	}
	tw, th := size, h*size/w
	if h > w {
		tw, th = w*size/h, size
	}
	tw, th = max(tw, 1), max(th, 1)
	// The standard library's fast paths turn JPEG's YCbCr and PNG's kinds
	// into RGBA, whose bytes can then be summed directly.
	whole := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(whole, whole.Bounds(), src, b.Min, draw.Src)
	dst := image.NewRGBA(image.Rect(0, 0, tw, th))
	for ty := 0; ty < th; ty++ {
		y0, y1 := ty*h/th, max((ty+1)*h/th, ty*h/th+1)
		for tx := 0; tx < tw; tx++ {
			x0, x1 := tx*w/tw, max((tx+1)*w/tw, tx*w/tw+1)
			var sum [4]int
			for y := y0; y < y1; y++ {
				row := whole.Pix[y*whole.Stride+x0*4 : y*whole.Stride+x1*4]
				for i := 0; i < len(row); i += 4 {
					sum[0] += int(row[i])
					sum[1] += int(row[i+1])
					sum[2] += int(row[i+2])
					sum[3] += int(row[i+3])
				}
			}
			n := (y1 - y0) * (x1 - x0)
			o := ty*dst.Stride + tx*4
			for c := 0; c < 4; c++ {
				dst.Pix[o+c] = uint8(sum[c] / n)
			}
		}
	}
	return dst
}

// An installed thumbnailer: the MIME types it makes thumbnails of, and the
// command that does.
type thumbnailer struct {
	types []string
	exec  []string
}

// The thumbnailers in $XDG_DATA_HOME and $XDG_DATA_DIRS, the first for a
// type winning; one that can't be read is said on stderr and passed over.
func findThumbnailers(stderr io.Writer) []thumbnailer {
	home := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(home) {
		home = filepath.Join(os.Getenv("HOME"), ".local", "share")
	}
	dirs := os.Getenv("XDG_DATA_DIRS")
	if dirs == "" {
		dirs = "/usr/local/share:/usr/share"
	}
	var found []thumbnailer
	for _, dir := range append([]string{home}, filepath.SplitList(dirs)...) {
		files, err := filepath.Glob(filepath.Join(dir, "thumbnailers", "*.thumbnailer"))
		if err != nil {
			continue // only a malformed pattern, which this isn't
		}
		for _, file := range files {
			t, err := readThumbnailer(file)
			if err != nil {
				fmt.Fprintf(stderr, "tide-pick: passing over the thumbnailer %s: %v\n", file, err)
				continue
			}
			found = append(found, t)
		}
	}
	return found
}

// A .thumbnailer file's MimeType and Exec, from its [Thumbnailer Entry].
func readThumbnailer(file string) (thumbnailer, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return thumbnailer{}, err
	}
	var t thumbnailer
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "MimeType":
			for _, m := range strings.Split(value, ";") {
				if m = strings.TrimSpace(m); m != "" {
					t.types = append(t.types, m)
				}
			}
		case "Exec":
			if t.exec, err = execArgs(value); err != nil {
				return thumbnailer{}, err
			}
		}
	}
	if len(t.exec) == 0 {
		return thumbnailer{}, errors.New("it has no Exec")
	}
	return t, nil
}

// An Exec value's arguments, as the desktop entry spec splits them: at
// spaces, but not inside double quotes, where a backslash takes the next
// character as it is.
func execArgs(value string) ([]string, error) {
	var args []string
	var arg strings.Builder
	inArg, quoted := false, false
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case quoted && c == '\\' && i+1 < len(value):
			i++
			arg.WriteByte(value[i])
		case c == '"':
			quoted = !quoted
			inArg = true
		case !quoted && (c == ' ' || c == '\t'):
			if inArg {
				args = append(args, arg.String())
				arg.Reset()
				inArg = false
			}
		default:
			arg.WriteByte(c)
			inArg = true
		}
	}
	if quoted {
		return nil, errors.New("its Exec has a quote that isn't closed")
	}
	if inArg {
		args = append(args, arg.String())
	}
	return args, nil
}

func thumbnailerFor(thumbnailers []thumbnailer, mime string) []string {
	for _, t := range thumbnailers {
		for _, m := range t.types {
			if m == mime {
				return t.exec
			}
		}
	}
	return nil
}

// The thumbnail a thumbnailer made, as PNG data: its Exec run with %i the
// picture's path, %u its URI, %o where to write and %s the size.
func runThumbnailer(job thumbJob) ([]byte, error) {
	tmp, err := os.MkdirTemp("", "tide-pick-thumb-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	output := filepath.Join(tmp, "thumb.png")
	args := make([]string, len(job.exec))
	for i, a := range job.exec {
		var b strings.Builder
		for j := 0; j < len(a); j++ {
			if a[j] != '%' || j+1 == len(a) {
				b.WriteByte(a[j])
				continue
			}
			j++
			switch a[j] {
			case 'i':
				b.WriteString(job.path)
			case 'u':
				b.WriteString(job.uri)
			case 'o':
				b.WriteString(output)
			case 's':
				b.WriteString(strconv.Itoa(thumbSize))
			case '%':
				b.WriteByte('%')
			}
		}
		args[i] = b.String()
	}
	ctx, cancel := context.WithTimeout(context.Background(), thumbnailerTimeout)
	defer cancel()
	var stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s: %v: %s", args[0], err, strings.TrimSpace(stderr.String()))
	}
	data, err := os.ReadFile(output)
	if err != nil {
		return nil, fmt.Errorf("%s wrote no thumbnail: %v", args[0], err)
	}
	return data, nil
}
