// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Package packview keeps each person's packs as the keeper's own
// read-only copy, one generation for each set digest the control plane
// names, which a space binds at /run/cyfr/scrolls (package stage).
//
// A generation is <dir>/<a>/<d>/, where dir is <kept root>/.packs, <a> the
// SHA-256 of the athanor's id in lowercase hex (the id's grammar allows a
// slash) and <d> the set digest's hex. Its files are mode 0444, or 0555
// with the executable bit; its folders 0555. dir and each <a> are 0711: a
// space's first process builds its files as the session's uid, which
// passes through them by name and lists neither. Everything is the
// keeper's own.
//
// A generation is written by a put: a stream of parts, in order, of a
// ustar archive whose first entry is the manifest, ManifestName, read
// before any file: one line for each file of the generation, {path, size,
// sha256, executable}, path being <pack>/<path inside the pack>. The
// keeper extracts as the parts land into a folder of that put's own,
// .<d>.<random>.part, and refuses at once, from the manifest before a file
// lands and from each file as it lands: a first entry that is not the
// manifest, a manifest that does not read or names a path twice, a set
// past MaxSetFiles or MaxSetBytes, a pack past MaxPackFiles or
// MaxPackBytes, a path past MaxPathBytes or with an empty, "." or ".."
// segment, a pack's record (RecordName at a pack's root), an entry that is
// not a regular file (a link, a folder, a device), a mode beyond the
// executable bit, a file the manifest does not name or names otherwise
// (size, SHA-256, executable bit), and a file named twice. At the last part
// every manifest line must have been written; the files and folders are
// made read only, the filesystem synced and the folder renamed to <d>/,
// which records the generation complete. A refused put leaves nothing.
//
// The keeper recomputes neither a pack's revision digest nor the set's:
// the manifest proves the files written are the files the control plane
// sent, and the generation is named by the digest the control plane gave.
//
// A hold names an athanor, a start's lifetime and a digest, and holds that
// generation for HoldFor; a live spawn that names a generation holds it
// from its Acquire to its release. At each hold the keeper removes every
// generation of that athanor but the one named that no hold and no live
// spawn holds, and every put folder of it no put in progress writes. A
// put idle for IdleFor, or whose owner ended, is dropped with its folder;
// the keeper's start removes every put folder left by an earlier keeper.
//
// The store's folder is made by the first put, not at the keeper's start:
// a kept root that cannot take it leaves the keeper serving every program
// that loads no packs, each hold answered missing and each put refused
// (ErrNoStore), which the start it was for takes as packs not made ready.
package packview

import (
	"archive/tar"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

// Bounds of a generation, the store's (Compendium.Packs) bounds: what the
// control plane hands a program is within them, so the keeper's own count
// can only agree with it.
const (
	MaxSetFiles  = 8192
	MaxSetBytes  = 128 << 20
	MaxPackFiles = 2048
	MaxPackBytes = 32 << 20
	MaxPathBytes = 255
	// MaxManifestBytes bounds the manifest: a set of MaxSetFiles lines of
	// the longest paths fits.
	MaxManifestBytes = 4 << 20
	// MaxPuts is the most puts in progress at once.
	MaxPuts = 16
)

// ManifestName is the stream's first entry; RecordName a pack's record,
// which never leaves the store.
const (
	// DirName is the store's folder under the kept homes' root: no kept
	// home's id begins with a dot (home.ValidID).
	DirName      = ".packs"
	ManifestName = ".cyfr-packs.json"
	RecordName   = ".cyfr-pack.json"
)

// HoldFor is how long a hold holds its generation: beyond the open's
// preparation bound (Opus.Programs.Session waits 310 s for an open).
// IdleFor is how long a put may go without a part.
const (
	HoldFor = 10 * time.Minute
	IdleFor = 60 * time.Second
)

// Put answers.
const (
	Taken = "taken"
	Held  = "held"
)

// ErrRefused refuses a put: its stream, a bound, its order or its state.
var ErrRefused = errors.New("packs refused")

// ErrNoStore refuses a put whose store's folder cannot be made or is no
// folder of the keeper's own.
var ErrNoStore = errors.New("the packs' folder cannot be made")

// ErrAbsent refuses an Acquire of a generation that is not complete.
var ErrAbsent = errors.New("no such generation")

var (
	hexDigest = regexp.MustCompile(`^[0-9a-f]{64}$`)
	partName  = regexp.MustCompile(`^\.[0-9a-f]{64}\.[0-9a-f]{16}\.part$`)
)

// Line is one file of the manifest.
type Line struct {
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	SHA256     string `json:"sha256"`
	Executable bool   `json:"executable"`
}

// Manifest is the stream's first entry.
type Manifest struct {
	Files []Line `json:"files"`
}

type hold struct {
	digest string
	until  time.Time
}

type putKey struct{ athanor, digest, lifetime string }

type put struct {
	mu    sync.Mutex
	key   putKey
	owner any
	dir   string
	next  uint64
	pipe  *io.PipeWriter
	done  chan error
	timer *time.Timer
	// touched is when its last part ended; the idle timer drops it only
	// IdleFor after that.
	touched time.Time
	gone    bool
}

// Store is the keeper's packs.
type Store struct {
	dir string
	now func() time.Time

	mu    sync.Mutex
	holds map[string]map[string]hold // <a> -> lifetime -> hold
	live  map[string]map[string]int  // <a> -> <d> -> live spawns
	puts  map[putKey]*put
}

// New is the store at dir, which it does not touch: the folder is made by
// the first put that needs it (ensure), so a keeper whose kept root cannot
// take it boots and serves every program that loads no packs, and only a
// put is refused.
func New(dir string) *Store {
	return &Store{dir: dir, now: time.Now, holds: map[string]map[string]hold{}, live: map[string]map[string]int{}, puts: map[putKey]*put{}}
}

// Sweep removes every put folder an earlier keeper left, at the keeper's
// start; a store whose folder is not there, or is no folder of the
// keeper's own, has none to remove.
func (s *Store) Sweep() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.usable(); err != nil {
		if absent(err) {
			return nil
		}
		return err
	}
	people, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	for _, p := range people {
		if !hexDigest.MatchString(p.Name()) {
			continue
		}
		entries, err := os.ReadDir(filepath.Join(s.dir, p.Name()))
		if err != nil {
			return err
		}
		for _, e := range entries {
			if partName.MatchString(e.Name()) {
				if err := removeTree(filepath.Join(s.dir, p.Name(), e.Name())); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// usable answers why the store's folder cannot be read now: absent, or no
// folder of the keeper's own (a link, or an entry another uid made in the
// kept root first), which is no store; s.mu is held.
func (s *Store) usable() error {
	var st unix.Stat_t
	if err := unix.Lstat(s.dir, &st); err != nil {
		return err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR || int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("%s is not a folder of the keeper's own", s.dir)
	}
	return nil
}

// ensure makes the store's folder, 0711, when it is not there yet, and
// answers why it cannot be one; s.mu is held.
func (s *Store) ensure() error {
	if err := os.Mkdir(s.dir, 0o711); err != nil && !errors.Is(err, fs.ErrExist) {
		return fmt.Errorf("%w: %v", ErrNoStore, err)
	}
	if err := s.usable(); err != nil {
		return fmt.Errorf("%w: %v", ErrNoStore, err)
	}
	if err := os.Chmod(s.dir, 0o711); err != nil {
		return fmt.Errorf("%w: %v", ErrNoStore, err)
	}
	return nil
}

// absent says err finds nothing there: no entry, or a path through one
// that is no folder.
func absent(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, unix.ENOTDIR)
}

// Dir is the store's folder.
func (s *Store) Dir() string { return s.dir }

// Person is an athanor's folder name, <a>.
func Person(athanor string) string {
	sum := sha256.Sum256([]byte(athanor))
	return hex.EncodeToString(sum[:])
}

// digestHex is a set digest's folder name, <d>: "sha256:" and its hex.
func digestHex(digest string) (string, bool) {
	h, ok := strings.CutPrefix(digest, "sha256:")
	return h, ok && hexDigest.MatchString(h)
}

// Path is the generation's folder.
func (s *Store) Path(athanor, digest string) string {
	d, _ := digestHex(digest)
	return filepath.Join(s.dir, Person(athanor), d)
}

// Hold holds the generation athanor and digest name for lifetime when it
// is complete, and answers whether it is; first it removes every
// generation of athanor that the cleanup rule lets go.
func (s *Store) Hold(athanor, lifetime, digest string) (bool, error) {
	d, ok := digestHex(digest)
	if !ok {
		return false, ErrRefused
	}
	a := Person(athanor)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.expire()
	if s.usable() != nil {
		return false, nil
	}
	if err := s.clean(a, d); err != nil {
		return false, err
	}
	info, err := os.Lstat(filepath.Join(s.dir, a, d))
	switch {
	case absent(err):
		return false, nil
	case err != nil:
		return false, err
	case !info.IsDir():
		return false, fmt.Errorf("%s/%s is not a folder", a, d)
	}
	s.holdLocked(a, lifetime, d)
	return true, nil
}

func (s *Store) holdLocked(a, lifetime, d string) {
	if s.holds[a] == nil {
		s.holds[a] = map[string]hold{}
	}
	s.holds[a][lifetime] = hold{digest: d, until: s.now().Add(HoldFor)}
}

// expire forgets every hold past its time; s.mu is held.
func (s *Store) expire() {
	now := s.now()
	for a, byLifetime := range s.holds {
		for lt, h := range byLifetime {
			if !now.Before(h.until) {
				delete(byLifetime, lt)
			}
		}
		if len(byLifetime) == 0 {
			delete(s.holds, a)
		}
	}
}

// clean removes every generation of the person a but named that no hold
// and no live spawn holds, and every put folder of a no put in progress
// writes; s.mu is held.
func (s *Store) clean(a, named string) error {
	entries, err := os.ReadDir(filepath.Join(s.dir, a))
	if absent(err) {
		return nil
	}
	if err != nil {
		return err
	}
	kept := map[string]bool{named: true}
	for _, h := range s.holds[a] {
		kept[h.digest] = true
	}
	for d, n := range s.live[a] {
		if n > 0 {
			kept[d] = true
		}
	}
	writing := map[string]bool{}
	for _, p := range s.puts {
		if Person(p.key.athanor) == a {
			writing[filepath.Base(p.dir)] = true
		}
	}
	for _, e := range entries {
		name := e.Name()
		switch {
		case hexDigest.MatchString(name) && !kept[name]:
		case partName.MatchString(name) && !writing[name]:
		default:
			continue
		}
		if err := removeTree(filepath.Join(s.dir, a, name)); err != nil {
			return err
		}
	}
	return nil
}

// Acquire holds a complete generation for a live spawn: its folder, whether
// it holds no pack, and the release the spawn's end calls once.
func (s *Store) Acquire(athanor, digest string) (path string, empty bool, release func(), err error) {
	d, ok := digestHex(digest)
	if !ok {
		return "", false, nil, ErrAbsent
	}
	a := Person(athanor)
	path = filepath.Join(s.dir, a, d)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.usable() != nil {
		return "", false, nil, ErrAbsent
	}
	f, err := os.Open(path)
	if absent(err) {
		return "", false, nil, ErrAbsent
	}
	if err != nil {
		return "", false, nil, err
	}
	names, err := f.Readdirnames(1)
	_ = f.Close()
	if err != nil && !errors.Is(err, io.EOF) {
		return "", false, nil, err
	}
	if s.live[a] == nil {
		s.live[a] = map[string]int{}
	}
	s.live[a][d]++
	var once sync.Once
	release = func() {
		once.Do(func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.live[a][d]--; s.live[a][d] <= 0 {
				delete(s.live[a], d)
			}
			if len(s.live[a]) == 0 {
				delete(s.live, a)
			}
		})
	}
	return path, len(names) == 0, release, nil
}

// Put applies one part of the put of athanor's digest for lifetime, made
// by owner: seq 0 begins it (and drops one of the same key in progress),
// every later seq must follow the last, and the last ends it. It answers
// Taken, or Held once the generation is complete and held for lifetime.
func (s *Store) Put(owner any, athanor, lifetime, digest string, seq uint64, last bool, part []byte) (string, error) {
	d, ok := digestHex(digest)
	if !ok {
		return "", ErrRefused
	}
	key := putKey{athanor, digest, lifetime}
	var p *put
	if seq == 0 {
		var err error
		if p, err = s.begin(owner, key, d); err != nil {
			return "", err
		}
	} else {
		s.mu.Lock()
		p = s.puts[key]
		s.mu.Unlock()
		if p == nil || p.owner != owner {
			return "", ErrRefused
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.gone || p.next != seq {
		s.drop(p, ErrRefused)
		return "", ErrRefused
	}
	defer func() { p.touched = s.now() }()
	if len(part) > 0 {
		if _, err := p.pipe.Write(part); err != nil {
			s.drop(p, err)
			return "", ErrRefused
		}
	}
	p.next++
	if !last {
		return Taken, nil
	}
	_ = p.pipe.Close()
	if err := <-p.done; err != nil {
		s.drop(p, err)
		return "", ErrRefused
	}
	if err := s.commit(p, d); err != nil {
		s.drop(p, err)
		return "", ErrRefused
	}
	return Held, nil
}

// begin starts a put of key; a put of the same key in progress is dropped.
func (s *Store) begin(owner any, key putKey, d string) (*put, error) {
	a := Person(key.athanor)
	s.mu.Lock()
	old := s.puts[key]
	s.mu.Unlock()
	if old != nil {
		old.mu.Lock()
		s.drop(old, ErrRefused)
		old.mu.Unlock()
	}
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return nil, err
	}
	person := filepath.Join(s.dir, a)
	dir := filepath.Join(person, "."+d+"."+hex.EncodeToString(suffix[:])+".part")
	r, w := io.Pipe()
	p := &put{key: key, owner: owner, dir: dir, pipe: w, done: make(chan error, 1), touched: s.now()}
	p.timer = time.AfterFunc(IdleFor, func() { s.idle(p) })
	s.mu.Lock()
	err := func() error {
		if len(s.puts) >= MaxPuts {
			return ErrRefused
		}
		if err := s.ensure(); err != nil {
			return err
		}
		// A space's first process passes through the person's folder as
		// the session's uid, whatever the keeper's umask.
		if err := os.Mkdir(person, 0o711); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
		if err := os.Chmod(person, 0o711); err != nil {
			return err
		}
		return os.Mkdir(dir, 0o700)
	}()
	if err != nil {
		s.mu.Unlock()
		p.timer.Stop()
		return nil, err
	}
	s.puts[key] = p
	s.mu.Unlock()
	go func() {
		err := Extract(r, dir)
		if err == nil {
			// What follows the archive's end is read as nothing, so the
			// writer is never left waiting; a refusal ends the writer's
			// next write at once.
			_, err = io.Copy(io.Discard, r)
		}
		_ = r.CloseWithError(err)
		p.done <- err
	}()
	return p, nil
}

// idle drops p once IdleFor has passed since its last part.
func (s *Store) idle(p *put) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.gone {
		return
	}
	if left := IdleFor - s.now().Sub(p.touched); left > 0 {
		p.timer.Reset(left)
		return
	}
	s.drop(p, errors.New("idle"))
}

// drop ends p and removes its folder; p.mu is held.
func (s *Store) drop(p *put, why error) {
	if p.gone {
		return
	}
	p.gone = true
	p.timer.Stop()
	_ = p.pipe.CloseWithError(why)
	s.mu.Lock()
	if s.puts[p.key] == p {
		delete(s.puts, p.key)
	}
	s.mu.Unlock()
	_ = removeTree(p.dir)
}

// commit makes p's files read only, syncs, and renames its folder to the
// generation, which it then holds for p's lifetime; a generation another
// put made first is kept and p's folder removed. p.mu is held.
func (s *Store) commit(p *put, d string) error {
	if err := readOnly(p.dir); err != nil {
		return err
	}
	f, err := os.Open(p.dir)
	if err != nil {
		return err
	}
	err = unix.Syncfs(int(f.Fd()))
	_ = f.Close()
	if err != nil {
		return err
	}
	a := Person(p.key.athanor)
	target := filepath.Join(s.dir, a, d)
	s.mu.Lock()
	defer s.mu.Unlock()
	p.gone = true
	p.timer.Stop()
	if s.puts[p.key] == p {
		delete(s.puts, p.key)
	}
	if err := os.Rename(p.dir, target); err != nil {
		if !errors.Is(err, fs.ErrExist) && !errors.Is(err, unix.ENOTEMPTY) {
			_ = removeTree(p.dir)
			return err
		}
		if err := removeTree(p.dir); err != nil {
			return err
		}
	}
	s.holdLocked(a, p.key.lifetime, d)
	return nil
}

// End drops every put owner made: its role's process ended.
func (s *Store) End(owner any) {
	s.mu.Lock()
	var mine []*put
	for _, p := range s.puts {
		if p.owner == owner {
			mine = append(mine, p)
		}
	}
	s.mu.Unlock()
	for _, p := range mine {
		p.mu.Lock()
		s.drop(p, errors.New("its role ended"))
		p.mu.Unlock()
	}
}

// Extract reads a generation's stream from r into dir, as the package
// doc says, and answers why it refused it.
func Extract(r io.Reader, dir string) error {
	tr := tar.NewReader(r)
	hdr, err := tr.Next()
	if err != nil {
		return fmt.Errorf("the stream holds no manifest: %w", err)
	}
	if hdr.Typeflag != tar.TypeReg || hdr.Name != ManifestName || hdr.Size > MaxManifestBytes {
		return errors.New("the stream's first entry is not its manifest")
	}
	lines, err := readManifest(tr, hdr.Size)
	if err != nil {
		return err
	}
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if hdr.Typeflag != tar.TypeReg {
			return fmt.Errorf("%q is not a regular file", hdr.Name)
		}
		line, ok := lines[hdr.Name]
		if !ok {
			return fmt.Errorf("%q is not in the manifest, or is there twice", hdr.Name)
		}
		delete(lines, hdr.Name)
		if hdr.Mode&^0o755 != 0 {
			return fmt.Errorf("%q has a mode beyond the executable bit", hdr.Name)
		}
		if hdr.Size != line.Size || (hdr.Mode&0o100 != 0) != line.Executable {
			return fmt.Errorf("%q is not its manifest line", hdr.Name)
		}
		if err := writeFile(dir, line, tr); err != nil {
			return err
		}
	}
	if len(lines) > 0 {
		return fmt.Errorf("%d files of the manifest are not in the stream", len(lines))
	}
	return nil
}

func readManifest(r io.Reader, size int64) (map[string]Line, error) {
	data, err := io.ReadAll(io.LimitReader(r, size))
	if err != nil {
		return nil, err
	}
	var m Manifest
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&m); err != nil || dec.More() || m.Files == nil {
		return nil, errors.New("the manifest does not read")
	}
	if len(m.Files) > MaxSetFiles {
		return nil, fmt.Errorf("the set holds %d files, past %d", len(m.Files), MaxSetFiles)
	}
	lines := make(map[string]Line, len(m.Files))
	packFiles := map[string]int{}
	packBytes := map[string]int64{}
	var setBytes int64
	for _, l := range m.Files {
		pack, err := checkPath(l.Path)
		if err != nil {
			return nil, err
		}
		if _, dup := lines[l.Path]; dup {
			return nil, fmt.Errorf("the manifest names %q twice", l.Path)
		}
		if l.Size < 0 || !strings.HasPrefix(l.SHA256, "sha256:") || !hexDigest.MatchString(l.SHA256[7:]) {
			return nil, fmt.Errorf("the manifest's line of %q does not read", l.Path)
		}
		lines[l.Path] = l
		packFiles[pack]++
		packBytes[pack] += l.Size
		setBytes += l.Size
		switch {
		case packFiles[pack] > MaxPackFiles:
			return nil, fmt.Errorf("pack %q holds more than %d files", pack, MaxPackFiles)
		case packBytes[pack] > MaxPackBytes:
			return nil, fmt.Errorf("pack %q holds more than %d bytes", pack, MaxPackBytes)
		case setBytes > MaxSetBytes:
			return nil, fmt.Errorf("the set holds more than %d bytes", MaxSetBytes)
		}
	}
	return lines, nil
}

// checkPath checks a manifest path, <pack>/<path inside the pack>, and
// answers its pack.
func checkPath(path string) (string, error) {
	if len(path) > MaxPathBytes || !utf8.ValidString(path) || strings.ContainsRune(path, 0) {
		return "", fmt.Errorf("the path %q is past %d bytes or does not read", path, MaxPathBytes)
	}
	segments := strings.Split(path, "/")
	if len(segments) < 2 {
		return "", fmt.Errorf("the path %q names no file of a pack", path)
	}
	for _, seg := range segments {
		if seg == "" || seg == "." || seg == ".." {
			return "", fmt.Errorf("the path %q has an empty, \".\" or \"..\" segment", path)
		}
	}
	if len(segments) == 2 && segments[1] == RecordName {
		return "", fmt.Errorf("the path %q is a pack's record", path)
	}
	return segments[0], nil
}

// writeFile writes one file under dir, made new, its folders made as it
// needs them, and checks its bytes against its line.
func writeFile(dir string, line Line, r io.Reader) error {
	target := filepath.Join(dir, filepath.FromSlash(line.Path))
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return fmt.Errorf("%q: %w", line.Path, err)
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(r, line.Size))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if n != line.Size || "sha256:"+hex.EncodeToString(h.Sum(nil)) != line.SHA256 {
		return fmt.Errorf("%q is not its manifest line", line.Path)
	}
	mode := os.FileMode(0o444)
	if line.Executable {
		mode = 0o555
	}
	return os.Chmod(target, mode)
}

// readOnly makes every folder under dir, dir itself among them, 0555.
func readOnly(dir string) error {
	var dirs []string
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			dirs = append(dirs, path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
	for _, d := range dirs {
		if err := os.Chmod(d, 0o555); err != nil {
			return err
		}
	}
	return nil
}

// removeTree removes path and everything under it, making each folder
// writable first, since a generation's are 0555 and a keeper that is not
// root cannot remove from them.
func removeTree(path string) error {
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return os.Chmod(p, 0o700)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return os.RemoveAll(path)
}
