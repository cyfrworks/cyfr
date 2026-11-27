// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"bytes"
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
	"slices"
	"strings"
	"syscall"
)

// A person's disk is one folder under the kept-homes root, <root>/<a>,
// where <a> is Person of the athanor's id (the id's grammar allows a
// slash): `programs/<row>` is each program's home, its HOME, and `work` is
// the /work every program of the person shares. The disk, its two folders
// and every home are 0700 and the disk's uid's, which it holds for the
// disk's life; no event retires a disk. The keeper never walks inside a
// disk: which homes a disk holds, its form and its uid are its record,
// <root>/.disks/<a>.json, which only the keeper writes.
const (
	// DisksDir is the folder of the disks' records under the kept-homes
	// root: the keeper's own, 0700.
	DisksDir = ".disks"
	// DisksDirMode is the records' folder's mode.
	DisksDirMode = fs.ModeDir | 0o700
	// RecordMode is a record's mode.
	RecordMode = 0o600
	// ProgramsDir is the folder of a disk's homes.
	ProgramsDir = "programs"
	// WorkDir is a disk's shared folder, bound at WorkPath.
	WorkDir = "work"
	// WorkPath is where a session sees its person's work folder.
	WorkPath = "/work"
	// FormDirectory is a disk that is a folder of the kept volume, the one
	// form there is until a person's machine gives the image form.
	FormDirectory = "directory"
	// maxRecordBytes bounds one record: its athanor and up to MaxDiskHomes
	// ids.
	maxRecordBytes = 1 << 20
	// MaxDiskHomes bounds the homes one disk records: the programs of one
	// owner are bounded far below it.
	MaxDiskHomes = 4096
)

var personPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// keeperUID owns the records' folder and every record: the keeper's, uid
// 0. A variable so a test runs as its own uid.
var keeperUID uint32

// Person is an athanor's folder name: the SHA-256 of its id in lowercase
// hex. A person's disk and their packs are named by it.
func Person(athanor string) string {
	sum := sha256.Sum256([]byte(athanor))
	return hex.EncodeToString(sum[:])
}

// Disk is a person's disk as its record says: whose, its form, its uid and
// the id of every home it holds, in byte order.
type Disk struct {
	Athanor string   `json:"athanor"`
	Form    string   `json:"form"`
	UID     int      `json:"uid"`
	Homes   []string `json:"homes"`
}

// Holds reports whether the disk records the home id.
func (d *Disk) Holds(id string) bool {
	_, found := slices.BinarySearch(d.Homes, id)
	return found
}

// With is the disk recording the home id beside its others.
func (d Disk) With(id string) Disk {
	i, found := slices.BinarySearch(d.Homes, id)
	if !found {
		d.Homes = slices.Insert(slices.Clone(d.Homes), i, id)
	}
	return d
}

// Without is the disk no longer recording the home id.
func (d Disk) Without(id string) Disk {
	if i, found := slices.BinarySearch(d.Homes, id); found {
		d.Homes = slices.Delete(slices.Clone(d.Homes), i, i+1)
	}
	return d
}

// DiskPath is the disk of athanor, <root>/<a>.
func (k Kept) DiskPath(athanor string) string { return filepath.Join(k.Root, Person(athanor)) }

// HomePath is the home id on the disk of athanor.
func (k Kept) HomePath(athanor, id string) string {
	return filepath.Join(k.DiskPath(athanor), ProgramsDir, id)
}

// WorkOf is the work folder of the disk of athanor.
func (k Kept) WorkOf(athanor string) string { return filepath.Join(k.DiskPath(athanor), WorkDir) }

// ValidateHome checks that home is a home of a disk directly under the
// root, <root>/<a>/programs/<id>, and work that disk's work folder.
func (k Kept) ValidateHome(home, work string) error {
	disk := filepath.Dir(filepath.Dir(home))
	switch {
	case filepath.Clean(home) != home || filepath.Base(filepath.Dir(home)) != ProgramsDir || !ValidID(filepath.Base(home)):
		return fmt.Errorf("kept home %q is not <disk>/%s/<id>", home, ProgramsDir)
	case filepath.Dir(disk) != k.Root || !personPattern.MatchString(filepath.Base(disk)):
		return fmt.Errorf("kept home %q is not on a disk directly under %s", home, k.Root)
	case work != filepath.Join(disk, WorkDir):
		return fmt.Errorf("work %q is not the work folder of %s", work, disk)
	}
	return nil
}

// recordPath is the record of the disk named a.
func (k Kept) recordPath(a string) string { return filepath.Join(k.Root, DisksDir, a+".json") }

// ErrBadRecord is a record that is not one the keeper wrote.
var ErrBadRecord = errors.New("not a disk's record")

// LoadDisks makes the records' folder if it is absent and reads every
// record in it, by athanor. A folder or a record that is not the keeper's
// (owner uid 0, its mode, no link), a record that does not read, names
// another athanor than its file, a form other than FormDirectory, a uid
// outside the range or a home id twice, or two records holding one home or
// one uid, is an error: the keeper does not start over a record it cannot
// trust. What a write left half done (a `.<a>.json.*` temporary) is
// removed.
func (k Kept) LoadDisks() (map[string]*Disk, error) {
	dir := filepath.Join(k.Root, DisksDir)
	if err := os.Mkdir(dir, DisksDirMode.Perm()); err != nil && !errors.Is(err, fs.ErrExist) {
		return nil, err
	}
	if err := checkKeepers(dir, DisksDirMode); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	disks := map[string]*Disk{}
	homes := map[string]string{}
	uids := map[int]string{}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") && strings.Contains(name, ".json.") {
			if err := os.Remove(filepath.Join(dir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return nil, err
			}
			continue
		}
		a, ok := strings.CutSuffix(name, ".json")
		if !ok || !personPattern.MatchString(a) {
			return nil, fmt.Errorf("%s: %w", filepath.Join(dir, name), ErrBadRecord)
		}
		d, err := k.readRecord(a)
		if err != nil {
			return nil, err
		}
		file := k.recordPath(a)
		if other, taken := uids[d.UID]; taken {
			return nil, fmt.Errorf("%s and %s both record uid %d: %w", other, file, d.UID, ErrBadRecord)
		}
		uids[d.UID] = file
		for _, id := range d.Homes {
			if other, taken := homes[id]; taken {
				return nil, fmt.Errorf("%s and %s both record home %s: %w", other, file, id, ErrBadRecord)
			}
			homes[id] = file
		}
		disks[d.Athanor] = d
	}
	return disks, nil
}

// ReadDisk reads the record of athanor's disk as LoadDisks reads it, an
// absent one as fs.ErrNotExist.
func (k Kept) ReadDisk(athanor string) (*Disk, error) {
	return k.readRecord(Person(athanor))
}

// readRecord reads the record of the disk named a.
func (k Kept) readRecord(a string) (*Disk, error) {
	path := k.recordPath(a)
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if err := checkKeepers(path, RecordMode); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(f, maxRecordBytes+1))
	if err != nil {
		return nil, err
	}
	var d Disk
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if len(data) > maxRecordBytes || dec.Decode(&d) != nil || dec.More() {
		return nil, fmt.Errorf("%s does not read: %w", path, ErrBadRecord)
	}
	switch {
	case Person(d.Athanor) != a:
		return nil, fmt.Errorf("%s names another athanor: %w", path, ErrBadRecord)
	case d.Form != FormDirectory:
		return nil, fmt.Errorf("%s has form %q: %w", path, d.Form, ErrBadRecord)
	case !k.Contains(d.UID):
		return nil, fmt.Errorf("%s records uid %d, outside %d-%d: %w", path, d.UID, k.First, k.Last, ErrBadRecord)
	case d.Homes == nil || len(d.Homes) > MaxDiskHomes || !slices.IsSorted(d.Homes):
		return nil, fmt.Errorf("%s records its homes out of order or past %d: %w", path, MaxDiskHomes, ErrBadRecord)
	}
	for i, id := range d.Homes {
		if !ValidID(id) || (i > 0 && d.Homes[i-1] == id) {
			return nil, fmt.Errorf("%s records home %q twice or by an invalid id: %w", path, id, ErrBadRecord)
		}
	}
	return &d, nil
}

// WriteDisk writes d's record whole or not at all: a temporary of the
// keeper's own, synced, renamed over the record and the folder synced, so
// a keeper killed at any moment leaves the record before or after. An error
// after the rename leaves the new record in place: what is on disk is then
// read again (ReadDisk).
func (k Kept) WriteDisk(d Disk) error {
	if d.Homes == nil {
		d.Homes = []string{}
	}
	data, err := json.Marshal(d)
	if err != nil {
		return err
	}
	a := Person(d.Athanor)
	dir := filepath.Join(k.Root, DisksDir)
	tmp, err := os.CreateTemp(dir, "."+a+".json.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, werr := tmp.Write(data)
	if werr == nil {
		werr = tmp.Sync()
	}
	if cerr := tmp.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return werr
	}
	if err := os.Rename(tmp.Name(), k.recordPath(a)); err != nil {
		return err
	}
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

// checkKeepers checks that path, read without following a link, has mode
// and is the keeper's (keeperUID).
func checkKeepers(path string, mode fs.FileMode) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode() != mode || st.Uid != keeperUID {
		return fmt.Errorf("%s is not uid 0's with mode %s: %w", path, mode, ErrBadRecord)
	}
	return nil
}
