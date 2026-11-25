// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package packview

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const partBytes = 512 << 10

type file struct {
	path string
	data []byte
	exec bool
}

func digestOf(name string) string {
	sum := sha256.Sum256([]byte(name))
	return "sha256:" + hex.EncodeToString(sum[:])
}

func lineOf(f file) Line {
	sum := sha256.Sum256(f.data)
	return Line{Path: f.path, Size: int64(len(f.data)), SHA256: "sha256:" + hex.EncodeToString(sum[:]), Executable: f.exec}
}

// stream is a generation's stream: the manifest of lines, then entries.
func stream(t *testing.T, lines []Line, entries []*tar.Header, bodies [][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	if lines == nil {
		lines = []Line{}
	}
	manifest, err := json.Marshal(Manifest{Files: lines})
	if err != nil {
		t.Fatal(err)
	}
	if err := tw.WriteHeader(&tar.Header{Name: ManifestName, Mode: 0o644, Size: int64(len(manifest)), Typeflag: tar.TypeReg, Format: tar.FormatPAX}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(manifest); err != nil {
		t.Fatal(err)
	}
	for i, h := range entries {
		if h.Format == tar.FormatUnknown {
			h.Format = tar.FormatPAX
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		if bodies[i] != nil {
			if _, err := tw.Write(bodies[i]); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func streamOf(t *testing.T, files []file) []byte {
	t.Helper()
	var lines []Line
	var hdrs []*tar.Header
	var bodies [][]byte
	for _, f := range files {
		lines = append(lines, lineOf(f))
		mode := int64(0o644)
		if f.exec {
			mode = 0o755
		}
		hdrs = append(hdrs, &tar.Header{Name: f.path, Mode: mode, Size: int64(len(f.data)), Typeflag: tar.TypeReg})
		bodies = append(bodies, f.data)
	}
	return stream(t, lines, hdrs, bodies)
}

func parts(b []byte) [][]byte {
	var out [][]byte
	for len(b) > partBytes {
		out = append(out, b[:partBytes])
		b = b[partBytes:]
	}
	return append(out, b)
}

// putAll sends every part of b and answers the last answer, or the first
// refusal with the seq it came at.
func putAll(s *Store, owner *Owner, athanor, lifetime, digest string, b []byte) (string, int, error) {
	ps := parts(b)
	for i, p := range ps {
		state, err := s.Put(owner, athanor, lifetime, digest, uint64(i), i == len(ps)-1, p)
		if err != nil {
			return "", i, err
		}
		if i == len(ps)-1 {
			return state, i, nil
		}
		if state != Taken {
			return state, i, fmt.Errorf("part %d answered %s", i, state)
		}
	}
	return "", 0, nil
}

func newStore(t *testing.T) *Store {
	t.Helper()
	s := New(filepath.Join(t.TempDir(), ".packs"))
	t.Cleanup(func() { _ = removeTree(s.Dir()) })
	return s
}

// tree is every entry under dir: its path, its mode and, for a file, its
// bytes.
func tree(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		v := info.Mode().String()
		if info.Mode().IsRegular() {
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			v += " " + string(data)
		}
		out[rel] = v
		return nil
	})
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func entries(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range es {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names
}

func TestAPutWritesEveryFileReadOnly(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	files := []file{
		{path: "pstack/skills/poteto-mode/SKILL.md", data: []byte("# poteto\n")},
		{path: "pstack/skills/poteto-mode/scripts/watch-pr", data: []byte("#!/bin/sh\necho hi\n"), exec: true},
		{path: "taste/README.md", data: bytes.Repeat([]byte("x"), 3*partBytes+17)},
	}
	d := digestOf("one")
	state, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, files))
	if err != nil || state != Held {
		t.Fatalf("put: %q %v", state, err)
	}
	got := tree(t, s.Path("ath_1", d))
	want := map[string]string{
		".":                                  "dr-xr-xr-x",
		"pstack":                             "dr-xr-xr-x",
		"pstack/skills":                      "dr-xr-xr-x",
		"pstack/skills/poteto-mode":          "dr-xr-xr-x",
		"pstack/skills/poteto-mode/SKILL.md": "-r--r--r-- # poteto\n",
		"pstack/skills/poteto-mode/scripts":  "dr-xr-xr-x",
		"pstack/skills/poteto-mode/scripts/watch-pr": "-r-xr-xr-x #!/bin/sh\necho hi\n",
		"taste":           "dr-xr-xr-x",
		"taste/README.md": "-r--r--r-- " + strings.Repeat("x", 3*partBytes+17),
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("the generation is\n%v\nwant\n%v", got, want)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("the person's folder holds %v", es)
	}
	for _, p := range []string{s.Dir(), filepath.Join(s.Dir(), Person("ath_1"))} {
		info, err := os.Stat(p)
		if err != nil || info.Mode().Perm() != 0o711 {
			t.Fatalf("%s: %v %v", p, info.Mode(), err)
		}
	}
	held, err := s.Hold("ath_1", "lt_2", d)
	if err != nil || !held {
		t.Fatalf("a hold of the written generation: %v %v", held, err)
	}
	if _, empty, release, err := s.Acquire("ath_1", d); err != nil || empty {
		t.Fatalf("acquire: %v %v", empty, err)
	} else {
		release()
	}
}

// refused puts its stream and checks the refusal comes at the part named
// (-1: the last, as for a manifest refused once it is read whole) and
// leaves no folder of the person.
func refused(t *testing.T, name string, b []byte, atPart int) {
	role := &Owner{}
	t.Helper()
	s := newStore(t)
	d := digestOf(name)
	state, at, err := putAll(s, role, "ath_1", "lt_1", d, b)
	if !errors.Is(err, ErrRefused) {
		t.Fatalf("%s: answered %q %v, want refused", name, state, err)
	}
	if atPart < 0 {
		atPart = len(parts(b)) - 1
	}
	if at != atPart {
		t.Fatalf("%s: refused at part %d, want %d", name, at, atPart)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 {
		t.Fatalf("%s: left %v", name, es)
	}
	if held, err := s.Hold("ath_1", "lt_1", d); held || err != nil {
		t.Fatalf("%s: a hold after the refusal: %v %v", name, held, err)
	}
}

func TestARefusedPutLeavesNothing(t *testing.T) {
	role := &Owner{}
	big := bytes.Repeat([]byte("b"), 4*partBytes)
	reg := func(name string, data []byte) (*tar.Header, []byte) {
		return &tar.Header{Name: name, Mode: 0o644, Size: int64(len(data)), Typeflag: tar.TypeReg}, data
	}
	t.Run("a link", func(t *testing.T) {
		f := file{path: "p/a", data: big}
		h, body := reg("p/a", big)
		link := &tar.Header{Name: "p/l", Linkname: "/etc/passwd", Typeflag: tar.TypeSymlink}
		b := stream(t, []Line{lineOf(f), {Path: "p/l", Size: 0, SHA256: digestOf("")}}, []*tar.Header{h, link, h}, [][]byte{body, nil, body})
		refused(t, "link", b, 4)
	})
	t.Run("a hard link", func(t *testing.T) {
		link := &tar.Header{Name: "p/l", Linkname: "p/a", Typeflag: tar.TypeLink}
		b := stream(t, []Line{{Path: "p/l", Size: 0, SHA256: digestOf("")}}, []*tar.Header{link}, [][]byte{nil})
		refused(t, "hard link", b, 0)
	})
	t.Run("a dotdot", func(t *testing.T) {
		f := file{path: "p/../../x", data: []byte("x")}
		refused(t, "dotdot", streamOf(t, []file{f}), 0)
	})
	t.Run("a path past its bound inside its pack", func(t *testing.T) {
		f := file{path: "p/" + strings.Repeat("ab/", 84) + "ends", data: []byte("x")}
		refused(t, "long", streamOf(t, []file{f}), 0)
	})
	t.Run("a pack's record", func(t *testing.T) {
		refused(t, "record", streamOf(t, []file{{path: "p/" + RecordName, data: []byte("{}")}}), 0)
	})
	t.Run("a digest that does not match", func(t *testing.T) {
		f := file{path: "p/a", data: big}
		line := lineOf(f)
		line.SHA256 = digestOf("other")
		h, body := reg("p/a", big)
		refused(t, "mismatch", stream(t, []Line{line}, []*tar.Header{h}, [][]byte{body}), 4)
	})
	t.Run("a size that does not match", func(t *testing.T) {
		f := file{path: "p/a", data: []byte("abc")}
		line := lineOf(f)
		line.Size = 2
		h, body := reg("p/a", f.data)
		refused(t, "size", stream(t, []Line{line}, []*tar.Header{h}, [][]byte{body}), 0)
	})
	t.Run("an executable bit the manifest does not say", func(t *testing.T) {
		f := file{path: "p/a", data: []byte("abc")}
		h, body := reg("p/a", f.data)
		h.Mode = 0o755
		refused(t, "exec", stream(t, []Line{lineOf(f)}, []*tar.Header{h}, [][]byte{body}), 0)
	})
	t.Run("a mode beyond the executable bit", func(t *testing.T) {
		f := file{path: "p/a", data: []byte("abc")}
		h, body := reg("p/a", f.data)
		h.Mode = 0o4644
		refused(t, "setuid", stream(t, []Line{lineOf(f)}, []*tar.Header{h}, [][]byte{body}), 0)
	})
	t.Run("a file the manifest does not name", func(t *testing.T) {
		h, body := reg("p/a", []byte("abc"))
		refused(t, "unnamed", stream(t, []Line{}, []*tar.Header{h}, [][]byte{body}), 0)
	})
	t.Run("a file named twice", func(t *testing.T) {
		f := file{path: "p/a", data: []byte("abc")}
		h, body := reg("p/a", f.data)
		refused(t, "twice", stream(t, []Line{lineOf(f)}, []*tar.Header{h, h}, [][]byte{body, body}), 0)
	})
	t.Run("a manifest line never written", func(t *testing.T) {
		refused(t, "unwritten", stream(t, []Line{lineOf(file{path: "p/a", data: []byte("abc")})}, nil, nil), 0)
	})
	t.Run("a folder entry", func(t *testing.T) {
		dir := &tar.Header{Name: "p/d/", Mode: 0o755, Typeflag: tar.TypeDir}
		refused(t, "folder", stream(t, []Line{}, []*tar.Header{dir}, [][]byte{nil}), 0)
	})
	t.Run("a first entry that is not the manifest", func(t *testing.T) {
		var buf bytes.Buffer
		tw := tar.NewWriter(&buf)
		_ = tw.WriteHeader(&tar.Header{Name: "p/a", Mode: 0o644, Size: 1, Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte("a"))
		_ = tw.Close()
		refused(t, "first", buf.Bytes(), 0)
	})
	t.Run("a pack past its files", func(t *testing.T) {
		var lines []Line
		for i := 0; i <= MaxPackFiles; i++ {
			lines = append(lines, lineOf(file{path: fmt.Sprintf("p/f%d", i)}))
		}
		refused(t, "pack files", stream(t, lines, nil, nil), -1)
	})
	t.Run("a pack past its bytes", func(t *testing.T) {
		lines := []Line{{Path: "p/a", Size: MaxPackBytes, SHA256: digestOf("")}, {Path: "p/b", Size: 1, SHA256: digestOf("")}}
		refused(t, "pack bytes", stream(t, lines, nil, nil), 0)
	})
	t.Run("a set past its files", func(t *testing.T) {
		var lines []Line
		for i := 0; i <= MaxSetFiles; i++ {
			lines = append(lines, lineOf(file{path: fmt.Sprintf("p%d/f%d", i/MaxPackFiles, i)}))
		}
		refused(t, "set files", stream(t, lines, nil, nil), -1)
	})
	t.Run("a set past its bytes", func(t *testing.T) {
		var lines []Line
		for i := 0; i < 5; i++ {
			lines = append(lines, Line{Path: fmt.Sprintf("p%d/a", i), Size: MaxPackBytes, SHA256: digestOf("")})
		}
		refused(t, "set bytes", stream(t, lines, nil, nil), 0)
	})
	t.Run("a pack's name past its bound", func(t *testing.T) {
		refused(t, "name", streamOf(t, []file{{path: strings.Repeat("n", MaxNameBytes+1) + "/a", data: []byte("x")}}), 0)
	})
	t.Run("a manifest past its bound", func(t *testing.T) {
		var buf bytes.Buffer
		tw := tar.NewWriter(&buf)
		body := append([]byte(`{"files":[]}`), bytes.Repeat([]byte(" "), int(MaxManifestBytes)-11)...)
		_ = tw.WriteHeader(&tar.Header{Name: ManifestName, Mode: 0o644, Size: int64(len(body)), Typeflag: tar.TypeReg})
		_, _ = tw.Write(body)
		_ = tw.Close()
		refused(t, "manifest", buf.Bytes(), 0)
	})
	t.Run("bytes after the archive's end", func(t *testing.T) {
		b := append(streamOf(t, []file{{path: "p/a", data: []byte("a")}}), bytes.Repeat([]byte("x"), 3*partBytes)...)
		refused(t, "after", b, 0)
	})
	t.Run("a part out of order", func(t *testing.T) {
		s := newStore(t)
		d := digestOf("order")
		b := streamOf(t, []file{{path: "p/a", data: big}})
		ps := parts(b)
		if _, err := s.Put(role, "ath_1", "lt_1", d, 0, false, ps[0]); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Put(role, "ath_1", "lt_1", d, 2, false, ps[2]); !errors.Is(err, ErrRefused) {
			t.Fatalf("a skipped part: %v", err)
		}
		if _, err := s.Put(role, "ath_1", "lt_1", d, 1, false, ps[1]); !errors.Is(err, ErrRefused) {
			t.Fatalf("a part after the refusal: %v", err)
		}
		if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 {
			t.Fatalf("left %v", es)
		}
	})
}

func TestTheLegalWorstCasesGoThroughWhole(t *testing.T) {
	role := &Owner{}
	if testing.Short() {
		t.Skip("writes 256 MiB")
	}
	t.Run("four packs of 32 MiB, each two files of 16 MiB", func(t *testing.T) {
		s := newStore(t)
		var files []file
		for p := 0; p < 4; p++ {
			for f := 0; f < 2; f++ {
				files = append(files, file{path: fmt.Sprintf("p%d/f%d", p, f), data: bytes.Repeat([]byte{byte('a' + p*2 + f)}, 16<<20)})
			}
		}
		d := digestOf("bytes")
		if state, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, files)); err != nil || state != Held {
			t.Fatalf("%q %v", state, err)
		}
		for _, f := range files {
			data, err := os.ReadFile(filepath.Join(s.Path("ath_1", d), f.path))
			if err != nil || !bytes.Equal(data, f.data) {
				t.Fatalf("%s: %d bytes %v", f.path, len(data), err)
			}
		}
	})
	// The largest manifest a legal set makes: every file at the longest
	// pack name and path the store holds, each segment within the store's.
	t.Run("four packs of 2,048 files making 128 MiB, at the longest names", func(t *testing.T) {
		s := newStore(t)
		var files []file
		each := (128 << 20) / (4 * MaxPackFiles)
		for p := 0; p < 4; p++ {
			name := fmt.Sprintf("%d", p) + strings.Repeat("n", MaxNameBytes-1)
			for f := 0; f < MaxPackFiles; f++ {
				inside := strings.Repeat("a", 120) + "/" + fmt.Sprintf("%04d", f) + strings.Repeat("b", MaxPathBytes-125)
				files = append(files, file{path: name + "/" + inside, data: bytes.Repeat([]byte{byte(f)}, each)})
			}
		}
		b := streamOf(t, files)
		hdr, err := tar.NewReader(bytes.NewReader(b)).Next()
		if err != nil || hdr.Size <= 4<<20 {
			t.Fatalf("the manifest is %d bytes: %v", hdr.Size, err)
		}
		d := digestOf("files")
		if state, _, err := putAll(s, role, "ath_1", "lt_1", d, b); err != nil || state != Held {
			t.Fatalf("%q %v", state, err)
		}
		n := 0
		_ = filepath.WalkDir(s.Path("ath_1", d), func(_ string, e fs.DirEntry, _ error) error {
			if e.Type().IsRegular() {
				n++
			}
			return nil
		})
		if n != 4*MaxPackFiles {
			t.Fatalf("%d files written", n)
		}
	})
}

func TestASecondPutOfOneDigestChangesNothing(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	d := digestOf("again")
	files := []file{{path: "p/a", data: []byte("one")}}
	if _, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, files)); err != nil {
		t.Fatal(err)
	}
	before := tree(t, s.Path("ath_1", d))
	info, _ := os.Stat(filepath.Join(s.Path("ath_1", d), "p/a"))
	if state, _, err := putAll(s, role, "ath_1", "lt_2", d, streamOf(t, files)); err != nil || state != Held {
		t.Fatalf("the second put: %q %v", state, err)
	}
	after := tree(t, s.Path("ath_1", d))
	again, _ := os.Stat(filepath.Join(s.Path("ath_1", d), "p/a"))
	if fmt.Sprint(before) != fmt.Sprint(after) || !os.SameFile(info, again) {
		t.Fatalf("the second put changed the generation:\n%v\n%v", before, after)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("left %v", es)
	}
}

// start is a start as Opus makes one (Opus.Programs.Session): a hold, a
// put on missing, and, while another put of its athanor is under way, a
// hold again once a moment has passed, until held. It answers the hold's
// final state and how many times the start met a put under way.
func start(t *testing.T, s *Store, owner *Owner, athanor, lifetime, digest string, b []byte) (string, int, error) {
	t.Helper()
	waits := 0
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); {
		held, err := s.Hold(athanor, lifetime, digest)
		if err != nil || held {
			return Held, waits, err
		}
		state, _, err := putAll(s, owner, athanor, lifetime, digest, b)
		if !errors.Is(err, ErrUnderWay) {
			return state, waits, err
		}
		waits++
		time.Sleep(5 * time.Millisecond) // sleep-ok: a start waits a moment before it holds again
	}
	return "", waits, errors.New("never held")
}

// Two starts of one person at once both start: the second's put meets the
// first's under way, and that start holds again until the generation the
// first put is held. One athanor has one put in progress all along.
func TestTwoStartsOfOnePersonAtOnce(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	d := digestOf("both")
	b := streamOf(t, []file{{path: "p/a", data: bytes.Repeat([]byte("z"), 5*partBytes)}})
	ps := parts(b)
	// The first start is mid-put when the second starts.
	if _, err := s.Put(role, "ath_1", "lt_0", d, 0, false, ps[0]); err != nil {
		t.Fatal(err)
	}
	second := make(chan error, 1)
	var waits int
	go func() {
		var state string
		var err error
		state, waits, err = start(t, s, role, "ath_1", "lt_1", d, b)
		if err == nil && state != Held {
			err = fmt.Errorf("answered %s", state)
		}
		second <- err
	}()
	for i := 1; i < len(ps); i++ {
		time.Sleep(5 * time.Millisecond) // sleep-ok: the first put's parts arrive while the second start waits
		if _, err := s.Put(role, "ath_1", "lt_0", d, uint64(i), i == len(ps)-1, ps[i]); err != nil {
			t.Fatal(err)
		}
	}
	if err := <-second; err != nil || waits == 0 {
		t.Fatalf("the second start: %v, after %d waits", err, waits)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("left %v", es)
	}
}

// When the first start's put fails, the second, holding again, finds the
// generation missing and puts it itself.
func TestTwoStartsOfOnePersonWhenTheFirstPutFails(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	d := digestOf("first fails")
	b := streamOf(t, []file{{path: "p/a", data: bytes.Repeat([]byte("f"), 3*partBytes)}})
	ps := parts(b)
	if _, err := s.Put(role, "ath_1", "lt_0", d, 0, false, ps[0]); err != nil {
		t.Fatal(err)
	}
	second := make(chan error, 1)
	var waits int
	go func() {
		var state string
		var err error
		state, waits, err = start(t, s, role, "ath_1", "lt_1", d, b)
		if err == nil && state != Held {
			err = fmt.Errorf("answered %s", state)
		}
		second <- err
	}()
	time.Sleep(20 * time.Millisecond) // sleep-ok: the second start meets the first put under way
	// The first put's next part is out of order: it is refused and dropped.
	if _, err := s.Put(role, "ath_1", "lt_0", d, 2, false, ps[2]); !errors.Is(err, ErrRefused) {
		t.Fatalf("the first put's failing part: %v", err)
	}
	if err := <-second; err != nil || waits == 0 {
		t.Fatalf("the second start: %v, after %d waits", err, waits)
	}
	data, err := os.ReadFile(filepath.Join(s.Path("ath_1", d), "p", "a"))
	if err != nil || len(data) != 3*partBytes {
		t.Fatalf("the second start's generation: %d bytes %v", len(data), err)
	}
}

// No person holds another's start: one athanor asking for seventeen puts
// gets one, and MaxPuts athanors fill the store whatever one of them asks.
func TestOneAthanorAskingForSeventeen(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	t.Cleanup(func() { s.End(role) })
	d := digestOf("many")
	for i := 0; i <= MaxPuts; i++ {
		_, err := s.Put(role, "ath_1", fmt.Sprintf("lt_%d", i), d, 0, false, []byte{})
		if want := i > 0; want != errors.Is(err, ErrUnderWay) {
			t.Fatalf("ath_1's put %d: %v", i, err)
		}
	}
	for i := 2; i <= MaxPuts; i++ {
		if _, err := s.Put(role, fmt.Sprintf("ath_%d", i), "lt_1", d, 0, false, []byte{}); err != nil {
			t.Fatalf("athanor %d's put: %v", i, err)
		}
	}
	if _, err := s.Put(role, "ath_17", "lt_1", d, 0, false, []byte{}); !errors.Is(err, ErrFull) {
		t.Fatalf("a put past %d: %v", MaxPuts, err)
	}
	if len(s.puts) != MaxPuts {
		t.Fatalf("%d puts in progress", len(s.puts))
	}
}

// A put ends within its bound from its first part, however steadily its
// parts arrive, and leaves nothing.
func TestAPutFedSlowlyEndsAtItsBound(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	s.putFor = 300 * time.Millisecond
	d := digestOf("slow")
	ps := parts(streamOf(t, []file{{path: "p/a", data: bytes.Repeat([]byte("s"), 40*partBytes)}}))
	began := time.Now()
	var err error
	i := 0
	for ; i < len(ps) && err == nil; i++ {
		_, err = s.Put(role, "ath_1", "lt_1", d, uint64(i), i == len(ps)-1, ps[i])
		time.Sleep(25 * time.Millisecond) // sleep-ok: the parts arrive slowly, well inside IdleFor
	}
	if !errors.Is(err, ErrRefused) || i == len(ps) {
		t.Fatalf("part %d of %d: %v", i, len(ps), err)
	}
	if took := time.Since(began); took > s.putFor+time.Second {
		t.Fatalf("refused after %v", took)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 || len(s.puts) != 0 {
		t.Fatalf("left %v, %d puts", es, len(s.puts))
	}
}

// Two starts of one key are one transfer: one put registered, one folder.
func TestTwoStartsOfOneKeyAreOneTransfer(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	t.Cleanup(func() { s.End(role) })
	reached, proceed := make(chan struct{}, 2), make(chan struct{})
	var calls atomic.Int32
	s.now = func() time.Time {
		if calls.Add(1) <= 2 {
			reached <- struct{}{}
			<-proceed
		}
		return time.Now()
	}
	d := digestOf("twice")
	errs := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := s.Put(role, "ath_1", "lt_1", d, 0, false, []byte{})
			errs <- err
		}()
	}
	<-reached
	<-reached
	close(proceed)
	<-errs
	<-errs
	s.mu.Lock()
	n := len(s.puts)
	s.mu.Unlock()
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); n != 1 || len(es) != 1 {
		t.Fatalf("%d registered, folders %v", n, es)
	}
}

// A role that ends while its put registers leaves nothing pending once
// End returns, and no folder.
func TestARoleEndingDuringARegistration(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	reached, proceed := make(chan struct{}), make(chan struct{})
	var once sync.Once
	s.now = func() time.Time {
		once.Do(func() { close(reached); <-proceed })
		return time.Now()
	}
	errs := make(chan error, 1)
	go func() {
		_, err := s.Put(role, "ath_1", "lt_1", digestOf("ending"), 0, false, []byte{})
		errs <- err
	}()
	<-reached
	s.End(role)
	close(proceed)
	if err := <-errs; !errors.Is(err, ErrRefused) {
		t.Fatalf("a put begun after its role's end: %v", err)
	}
	if es, _ := os.ReadDir(filepath.Join(s.Dir(), Person("ath_1"))); len(s.puts) != 0 || len(es) != 0 {
		t.Fatalf("%d pending, folders %v", len(s.puts), es)
	}
}

// A role's end mid-stream returns once its put's folder is gone.
func TestARoleEndingMidStream(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	d := digestOf("mid")
	ps := parts(streamOf(t, []file{{path: "p/a", data: bytes.Repeat([]byte("m"), 3*partBytes)}}))
	if _, err := s.Put(role, "ath_1", "lt_1", d, 0, false, ps[0]); err != nil {
		t.Fatal(err)
	}
	s.End(role)
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(s.puts) != 0 || len(es) != 0 {
		t.Fatalf("%d pending, folders %v", len(s.puts), es)
	}
	if _, err := s.Put(role, "ath_1", "lt_1", d, 1, false, ps[1]); !errors.Is(err, ErrRefused) {
		t.Fatalf("a part after its role's end: %v", err)
	}
}

// A put being finished stays registered until it has settled: another put
// of its athanor is refused under way meanwhile, and its role's End
// returns once it is dropped, its folder gone and no generation made.
func TestAPutBeingFinishedStaysRegistered(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	paused, resume := make(chan struct{}), make(chan struct{})
	s.finishing = func() { close(paused); <-resume }
	d := digestOf("finishing")
	first := make(chan error, 1)
	go func() {
		_, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, []file{{path: "p/a", data: []byte("a")}}))
		first <- err
	}()
	<-paused
	if _, err := s.Put(&Owner{}, "ath_1", "lt_2", digestOf("other"), 0, false, []byte{}); !errors.Is(err, ErrUnderWay) {
		t.Errorf("another put of the athanor while the first is finished: %v", err)
	}
	type seen struct {
		folders []string
		gen     error
	}
	ended := make(chan seen, 1)
	go func() {
		s.End(role)
		_, err := os.Stat(s.Path("ath_1", d))
		var folders []string
		es, _ := os.ReadDir(filepath.Join(s.Dir(), Person("ath_1")))
		for _, e := range es {
			folders = append(folders, e.Name())
		}
		ended <- seen{folders, err}
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		s.mu.Lock()
		e := role.ended
		s.mu.Unlock()
		if e || time.Now().After(deadline) {
			break
		}
		runtime.Gosched()
	}
	close(resume)
	at := <-ended
	if len(at.folders) != 0 || !errors.Is(at.gen, fs.ErrNotExist) {
		t.Errorf("once End returned: folders %v, generation %v", at.folders, at.gen)
	}
	if err := <-first; !errors.Is(err, ErrRefused) {
		t.Errorf("the first put, its role ended while it was finished: %v", err)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 || len(s.puts) != 0 {
		t.Fatalf("left %v, %d registered", es, len(s.puts))
	}
}

func TestTheCleanupRule(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	clock := time.Unix(1_000_000, 0)
	var mu sync.Mutex
	s.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return clock }
	advance := func(d time.Duration) { mu.Lock(); clock = clock.Add(d); mu.Unlock() }
	write := func(name, lifetime string) string {
		d := digestOf(name)
		if _, _, err := putAll(s, role, "ath_1", lifetime, d, streamOf(t, []file{{path: "p/" + name, data: []byte(name)}})); err != nil {
			t.Fatal(err)
		}
		return d
	}
	person := filepath.Join(s.Dir(), Person("ath_1"))
	has := func(ds ...string) {
		t.Helper()
		var want []string
		for _, d := range ds {
			want = append(want, d[7:])
		}
		sort.Strings(want)
		if got := entries(t, person); fmt.Sprint(got) != fmt.Sprint(want) {
			t.Fatalf("the person holds %v, want %v", got, want)
		}
	}

	// A live session's generation and a start in preparation's each stay
	// through another start's hold.
	a := write("a", "lt_a")
	_, _, releaseA, err := s.Acquire("ath_1", a)
	if err != nil {
		t.Fatal(err)
	}
	advance(HoldFor) // a's own hold is over; its session holds it.
	b := write("b", "lt_b")
	c := digestOf("c")
	if held, err := s.Hold("ath_1", "lt_c", c); held || err != nil {
		t.Fatalf("c: %v %v", held, err)
	}
	has(a, b)
	// Both go at the first start after both end.
	releaseA()
	advance(HoldFor)
	if held, _ := s.Hold("ath_1", "lt_c2", c); held {
		t.Fatal("c is not written")
	}
	has()
	// A start of another person removes nothing of this one's.
	d := write("d", "lt_d")
	if _, err := s.Hold("ath_2", "lt_x", digestOf("x")); err != nil {
		t.Fatal(err)
	}
	advance(HoldFor)
	has(d)
	// A hold removes no put folder: one in progress is its put's, and its
	// owner's end removes it.
	e := digestOf("e")
	if _, err := s.Put(role, "ath_1", "lt_e", e, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Hold("ath_1", "lt_f", d); err != nil {
		t.Fatal(err)
	}
	got := entries(t, person)
	if len(got) != 2 || got[1] != d[7:] || !strings.HasPrefix(got[0], "."+e[7:]+".") {
		t.Fatalf("the person holds %v", got)
	}
	s.End(role)
	has(d)
}

func TestAnIdlePutIsDropped(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	clock := time.Unix(1_000_000, 0)
	var mu sync.Mutex
	s.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return clock }
	d := digestOf("idle")
	if _, err := s.Put(role, "ath_1", "lt_1", d, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	p := s.current(putKey{"ath_1", d, "lt_1"})
	s.mu.Unlock()
	// Before its time the timer re-arms; after it, the put goes.
	s.idled(p)
	if _, err := s.Put(role, "ath_1", "lt_1", d, 1, false, []byte{}); err != nil {
		t.Fatalf("a part before the idle bound: %v", err)
	}
	mu.Lock()
	clock = clock.Add(IdleFor)
	mu.Unlock()
	s.idled(p)
	if _, err := s.Put(role, "ath_1", "lt_1", d, 2, true, []byte{}); !errors.Is(err, ErrRefused) {
		t.Fatalf("a part after the idle bound: %v", err)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 {
		t.Fatalf("left %v", es)
	}
}

func TestAPutOfAnotherOwnerIsRefused(t *testing.T) {
	role, other := &Owner{}, &Owner{}
	s := newStore(t)
	d := digestOf("owner")
	if _, err := s.Put(role, "ath_1", "lt_1", d, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Put(other, "ath_1", "lt_1", d, 1, true, []byte{}); !errors.Is(err, ErrRefused) {
		t.Fatalf("%v", err)
	}
}

func TestAKeeperStartRemovesEveryPutFolder(t *testing.T) {
	role := &Owner{}
	dir := filepath.Join(t.TempDir(), ".packs")
	s := New(dir)
	t.Cleanup(func() { _ = removeTree(dir) })
	d := digestOf("kept")
	if _, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, []file{{path: "p/a", data: []byte("a")}})); err != nil {
		t.Fatal(err)
	}
	// A keeper that died mid-put left its folder, half written.
	half := filepath.Join(dir, Person("ath_1"), "."+strings.Repeat("1", 64)+".0123456789abcdef.part")
	if err := os.MkdirAll(filepath.Join(half, "p"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(half, "p", "a"), []byte("half"), 0o444); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(half, 0o555); err != nil {
		t.Fatal(err)
	}
	if err := New(dir).Sweep(); err != nil {
		t.Fatal(err)
	}
	if es := entries(t, filepath.Join(dir, Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("left %v", es)
	}
}

// A store whose folder is not there yet, or that its kept root cannot
// take, has nothing to sweep and holds nothing; its first put makes the
// folder, and a put that cannot is refused saying so. None needs root.
func TestTheStoresFolderIsMadeByItsFirstPut(t *testing.T) {
	role := &Owner{}
	root := t.TempDir()
	dir := filepath.Join(root, ".packs")
	s := New(dir)
	if err := s.Sweep(); err != nil {
		t.Fatalf("a sweep of a store not made: %v", err)
	}
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatalf("New or Sweep made the folder: %v", err)
	}
	d := digestOf("first")
	if held, err := s.Hold("ath_1", "lt_1", d); held || err != nil {
		t.Fatalf("a hold of a store not made: %v %v", held, err)
	}
	if state, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, []file{{path: "p/a", data: []byte("a")}})); err != nil || state != Held {
		t.Fatalf("the first put: %q %v", state, err)
	}
	t.Cleanup(func() { _ = removeTree(dir) })
	if info, err := os.Lstat(dir); err != nil || info.Mode().Perm() != 0o711 {
		t.Fatalf("the first put's folder: %v %v", info, err)
	}

	// A kept root where the folder's name is taken by a file: whatever the
	// uid, nothing can be made under it.
	blocked := t.TempDir()
	if err := os.WriteFile(filepath.Join(blocked, ".packs"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	b := New(filepath.Join(blocked, ".packs"))
	if err := b.Sweep(); err == nil {
		t.Fatal("a sweep of a file in the folder's place says nothing")
	}
	if held, err := b.Hold("ath_1", "lt_1", d); held || err != nil {
		t.Fatalf("a hold where no folder can be: %v %v", held, err)
	}
	if _, _, _, err := b.Acquire("ath_1", d); !errors.Is(err, ErrAbsent) {
		t.Fatalf("an acquire where no folder can be: %v", err)
	}
	if _, err := b.Put(role, "ath_1", "lt_1", d, 0, true, []byte{}); !errors.Is(err, ErrNoStore) || !strings.Contains(err.Error(), "not a folder") {
		t.Fatalf("a put where no folder can be: %v", err)
	}
}

func TestAnEmptySetIsAGenerationThatHoldsNoPack(t *testing.T) {
	role := &Owner{}
	s := newStore(t)
	d := digestOf("none")
	if state, _, err := putAll(s, role, "ath_1", "lt_1", d, streamOf(t, nil)); err != nil || state != Held {
		t.Fatalf("%q %v", state, err)
	}
	_, empty, release, err := s.Acquire("ath_1", d)
	if err != nil || !empty {
		t.Fatalf("%v %v", empty, err)
	}
	release()
	if _, _, _, err := s.Acquire("ath_1", digestOf("unwritten")); !errors.Is(err, ErrAbsent) {
		t.Fatalf("an unwritten generation: %v", err)
	}
}

// The bounds are the shared vectors' pack_bounds, which the store holds too.
func TestTheBoundsAreTheSharedOnes(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Bounds map[string]any `json:"pack_bounds"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"set_files": float64(MaxSetFiles), "set_bytes": float64(MaxSetBytes),
		"pack_files": float64(MaxPackFiles), "pack_bytes": float64(MaxPackBytes),
		"file_bytes": float64(MaxFileBytes), "name_bytes": float64(MaxNameBytes),
		"path_bytes": float64(MaxPathBytes), "manifest": ManifestName,
	}
	if fmt.Sprint(v.Bounds) != fmt.Sprint(want) {
		t.Fatalf("the vectors pin %v, the keeper has %v", v.Bounds, want)
	}
}

// A declared size is checked before it is added: negative, past a file's
// bound (its pack's), or carrying a sum past its budget, with no sum that
// can wrap.
func TestAManifestsSizesAreCheckedBeforeTheyAreAdded(t *testing.T) {
	small := lineOf(file{path: "mine/a", data: []byte("a")})
	at := func(path string, size int64) Line {
		l := lineOf(file{path: path})
		l.Size = size
		return l
	}
	for name, lines := range map[string][]Line{
		"the reviewer's manifest": {small, at("mine/b", math.MaxInt64)},
		"a negative size":         {small, at("mine/b", -1)},
		"a file past its bound":   {at("mine/b", MaxFileBytes+1)},
		"a pack's sum past it":    {at("mine/b", MaxPackBytes), at("mine/c", 1)},
		"a set's sum past it":     {at("p0/a", MaxPackBytes), at("p1/a", MaxPackBytes), at("p2/a", MaxPackBytes), at("p3/a", MaxPackBytes), at("p4/a", 1)},
		"two that wrap together":  {at("p0/a", math.MaxInt64/2+1), at("p1/a", math.MaxInt64/2+1)},
	} {
		body, err := json.Marshal(Manifest{Files: lines})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := readManifest(bytes.NewReader(body), int64(len(body))); err == nil {
			t.Errorf("%s was taken", name)
		}
	}
	var full []Line
	for p := 0; p < 4; p++ {
		full = append(full, at(fmt.Sprintf("p%d/a", p), MaxPackBytes/2), at(fmt.Sprintf("p%d/b", p), MaxPackBytes/2))
	}
	body, _ := json.Marshal(Manifest{Files: full})
	if _, err := readManifest(bytes.NewReader(body), int64(len(body))); err != nil {
		t.Errorf("a set at its budget: %v", err)
	}
}

// The store's own archive of a pack at the longest name and path, the
// shared vectors' pack_archive, extracts, and a set of MaxSetFiles of its
// manifest's line, each with a size of MaxFileBytes's digits, is within
// the manifest's bound: the largest manifest the store makes puts.
func TestTheStoresArchiveAtTheLongestNamesExtracts(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Archive struct {
			Pack    string `json:"pack"`
			Path    string `json:"path"`
			Data    string `json:"data"`
			Archive string `json:"archive"`
		} `json:"pack_archive"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	a := v.Archive
	if len(a.Pack) != MaxNameBytes || len(a.Path) != MaxPathBytes {
		t.Fatalf("the vectors' pack_archive is at %d and %d bytes", len(a.Pack), len(a.Path))
	}
	archive, err := base64.StdEncoding.DecodeString(a.Archive)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := Extract(bytes.NewReader(archive), dir); err != nil {
		t.Fatalf("the store's archive: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(dir, a.Pack, a.Path)); err != nil || string(got) != a.Data {
		t.Fatalf("its file: %q %v", got, err)
	}
	tr := tar.NewReader(bytes.NewReader(archive))
	hdr, err := tr.Next()
	if err != nil {
		t.Fatal(err)
	}
	var m Manifest
	if err := json.NewDecoder(tr).Decode(&m); err != nil || len(m.Files) != 1 {
		t.Fatalf("its manifest: %+v %v", m, err)
	}
	around := int64(len(`{"files":[]}`))
	line := hdr.Size - around + int64(len(strconv.Itoa(MaxFileBytes))-len(strconv.FormatInt(m.Files[0].Size, 10)))
	if full := around + MaxSetFiles*(line+1) - 1; full > MaxManifestBytes {
		t.Fatalf("a full set of the store's longest lines makes %d bytes, past %d", full, MaxManifestBytes)
	}
}

// A path's bound is the store's, on the path inside its pack, read from
// the shared vectors' edge.
func TestAPathsBoundIsTheStores(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "..", "tests", "fixtures", "keeper_protocol.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Paths struct {
			Pack    string   `json:"pack"`
			Held    []string `json:"held"`
			Refused []string `json:"refused"`
		} `json:"pack_paths"`
	}
	if err := json.Unmarshal(data, &v); err != nil || v.Paths.Pack == "" || len(v.Paths.Held) == 0 || len(v.Paths.Refused) == 0 {
		t.Fatalf("the vectors' pack_paths: %+v %v", v.Paths, err)
	}
	for _, p := range v.Paths.Held {
		if _, err := checkPath(v.Paths.Pack + "/" + p); err != nil {
			t.Errorf("%d bytes inside the pack: %v", len(p), err)
		}
		b := streamOf(t, []file{{path: v.Paths.Pack + "/" + p, data: []byte("x")}})
		if err := Extract(bytes.NewReader(b), t.TempDir()); err != nil {
			t.Errorf("%d bytes inside the pack, extracted: %v", len(p), err)
		}
	}
	for _, p := range v.Paths.Refused {
		if _, err := checkPath(v.Paths.Pack + "/" + p); err == nil {
			t.Errorf("%d bytes inside the pack was taken", len(p))
		}
	}
}
