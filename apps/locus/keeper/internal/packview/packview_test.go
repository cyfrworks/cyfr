// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package packview

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
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
func putAll(s *Store, owner any, athanor, lifetime, digest string, b []byte) (string, int, error) {
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
	s, err := Open(filepath.Join(t.TempDir(), ".packs"))
	if err != nil {
		t.Fatal(err)
	}
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
	s := newStore(t)
	files := []file{
		{path: "pstack/skills/poteto-mode/SKILL.md", data: []byte("# poteto\n")},
		{path: "pstack/skills/poteto-mode/scripts/watch-pr", data: []byte("#!/bin/sh\necho hi\n"), exec: true},
		{path: "taste/README.md", data: bytes.Repeat([]byte("x"), 3*partBytes+17)},
	}
	d := digestOf("one")
	state, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, files))
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
	t.Helper()
	s := newStore(t)
	d := digestOf(name)
	state, at, err := putAll(s, "role", "ath_1", "lt_1", d, b)
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
	t.Run("a long path", func(t *testing.T) {
		f := file{path: "p/" + strings.Repeat("a", MaxPathBytes-1), data: []byte("x")}
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
	t.Run("a part out of order", func(t *testing.T) {
		s := newStore(t)
		d := digestOf("order")
		b := streamOf(t, []file{{path: "p/a", data: big}})
		ps := parts(b)
		if _, err := s.Put("role", "ath_1", "lt_1", d, 0, false, ps[0]); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Put("role", "ath_1", "lt_1", d, 2, false, ps[2]); !errors.Is(err, ErrRefused) {
			t.Fatalf("a skipped part: %v", err)
		}
		if _, err := s.Put("role", "ath_1", "lt_1", d, 1, false, ps[1]); !errors.Is(err, ErrRefused) {
			t.Fatalf("a part after the refusal: %v", err)
		}
		if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 {
			t.Fatalf("left %v", es)
		}
	})
}

func TestTheLegalWorstCasesGoThroughWhole(t *testing.T) {
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
		if state, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, files)); err != nil || state != Held {
			t.Fatalf("%q %v", state, err)
		}
		for _, f := range files {
			data, err := os.ReadFile(filepath.Join(s.Path("ath_1", d), f.path))
			if err != nil || !bytes.Equal(data, f.data) {
				t.Fatalf("%s: %d bytes %v", f.path, len(data), err)
			}
		}
	})
	t.Run("four packs of 2,048 files making 128 MiB", func(t *testing.T) {
		s := newStore(t)
		var files []file
		each := (128 << 20) / (4 * MaxPackFiles)
		for p := 0; p < 4; p++ {
			for f := 0; f < MaxPackFiles; f++ {
				files = append(files, file{path: fmt.Sprintf("p%d/skills/s%d/SKILL.md", p, f), data: bytes.Repeat([]byte{byte(f)}, each)})
			}
		}
		d := digestOf("files")
		if state, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, files)); err != nil || state != Held {
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
	s := newStore(t)
	d := digestOf("again")
	files := []file{{path: "p/a", data: []byte("one")}}
	if _, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, files)); err != nil {
		t.Fatal(err)
	}
	before := tree(t, s.Path("ath_1", d))
	info, _ := os.Stat(filepath.Join(s.Path("ath_1", d), "p/a"))
	if state, _, err := putAll(s, "role", "ath_1", "lt_2", d, streamOf(t, files)); err != nil || state != Held {
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

func TestTwoStartsOfOnePersonAtOnce(t *testing.T) {
	s := newStore(t)
	d := digestOf("both")
	b := streamOf(t, []file{{path: "p/a", data: bytes.Repeat([]byte("z"), 5*partBytes)}})
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for i := range errs {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			state, _, err := putAll(s, "role", "ath_1", fmt.Sprintf("lt_%d", i), d, b)
			if err == nil && state != Held {
				err = fmt.Errorf("answered %s", state)
			}
			errs[i] = err
		}(i)
	}
	wg.Wait()
	if errs[0] != nil || errs[1] != nil {
		t.Fatalf("%v", errs)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("left %v", es)
	}
}

func TestTheCleanupRule(t *testing.T) {
	s := newStore(t)
	clock := time.Unix(1_000_000, 0)
	var mu sync.Mutex
	s.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return clock }
	advance := func(d time.Duration) { mu.Lock(); clock = clock.Add(d); mu.Unlock() }
	write := func(name, lifetime string) string {
		d := digestOf(name)
		if _, _, err := putAll(s, "role", "ath_1", lifetime, d, streamOf(t, []file{{path: "p/" + name, data: []byte(name)}})); err != nil {
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
	// A put folder of a put in progress stays; a stale one goes.
	e := digestOf("e")
	if _, err := s.Put("role", "ath_1", "lt_e", e, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(person, "."+strings.Repeat("0", 64)+".0123456789abcdef.part")
	if err := os.Mkdir(stale, 0o555); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Hold("ath_1", "lt_f", d); err != nil {
		t.Fatal(err)
	}
	got := entries(t, person)
	if len(got) != 2 || got[1] != d[7:] || !strings.HasPrefix(got[0], "."+e[7:]+".") {
		t.Fatalf("the person holds %v", got)
	}
	s.End("role")
	has(d)
}

func TestAnIdlePutIsDropped(t *testing.T) {
	s := newStore(t)
	clock := time.Unix(1_000_000, 0)
	var mu sync.Mutex
	s.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return clock }
	d := digestOf("idle")
	if _, err := s.Put("role", "ath_1", "lt_1", d, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	p := s.puts[putKey{"ath_1", d, "lt_1"}]
	s.mu.Unlock()
	// Before its time the timer re-arms; after it, the put goes.
	s.idle(p)
	if _, err := s.Put("role", "ath_1", "lt_1", d, 1, false, []byte{}); err != nil {
		t.Fatalf("a part before the idle bound: %v", err)
	}
	mu.Lock()
	clock = clock.Add(IdleFor)
	mu.Unlock()
	s.idle(p)
	if _, err := s.Put("role", "ath_1", "lt_1", d, 2, true, []byte{}); !errors.Is(err, ErrRefused) {
		t.Fatalf("a part after the idle bound: %v", err)
	}
	if es := entries(t, filepath.Join(s.Dir(), Person("ath_1"))); len(es) != 0 {
		t.Fatalf("left %v", es)
	}
}

func TestAPutOfAnotherOwnerIsRefused(t *testing.T) {
	s := newStore(t)
	d := digestOf("owner")
	if _, err := s.Put("role", "ath_1", "lt_1", d, 0, false, []byte{}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Put("other", "ath_1", "lt_1", d, 1, true, []byte{}); !errors.Is(err, ErrRefused) {
		t.Fatalf("%v", err)
	}
}

func TestAKeeperStartRemovesEveryPutFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), ".packs")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = removeTree(dir) })
	d := digestOf("kept")
	if _, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, []file{{path: "p/a", data: []byte("a")}})); err != nil {
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
	if _, err := Open(dir); err != nil {
		t.Fatal(err)
	}
	if es := entries(t, filepath.Join(dir, Person("ath_1"))); fmt.Sprint(es) != fmt.Sprint([]string{d[7:]}) {
		t.Fatalf("left %v", es)
	}
}

func TestAnEmptySetIsAGenerationThatHoldsNoPack(t *testing.T) {
	s := newStore(t)
	d := digestOf("none")
	if state, _, err := putAll(s, "role", "ath_1", "lt_1", d, streamOf(t, nil)); err != nil || state != Held {
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
		"path_bytes": float64(MaxPathBytes), "manifest": ManifestName,
	}
	if fmt.Sprint(v.Bounds) != fmt.Sprint(want) {
		t.Fatalf("the vectors pin %v, the keeper has %v", v.Bounds, want)
	}
}
