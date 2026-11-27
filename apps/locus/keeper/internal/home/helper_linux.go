// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package home

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/cyfr/locus/keeper/internal/logx"
	"github.com/cyfr/locus/keeper/internal/residue"
)

// File descriptors of `cyfr-locus home`; 0-2 are /dev/null, /dev/null and
// the keeper's stderr.
const (
	// HelperSpecFD is the read end of the spec pipe.
	HelperSpecFD = 3
	// HelperResultFD is the write end of the result pipe: a measure
	// writes its bytes there, in decimal.
	HelperResultFD = 4
)

// Ops of `cyfr-locus home`.
const (
	OpMake    = "make"
	OpMeasure = "measure"
	OpReset   = "reset"
	OpRemove  = "remove"
)

// Exit statuses of `cyfr-locus home`.
const (
	ExitDone    = 0
	ExitFailed  = 1
	ExitInvalid = 3
)

// maxMeasured bounds the entries one measure walks: a home past it is not
// measured at all (ErrUnmeasured), since a partial total could miss what
// the rest of the tree holds and let it pass its bound. A variable so a
// test can lower it.
var maxMeasured = 2_000_000

// ErrUnmeasured is a walk that stopped short of the whole home.
var ErrUnmeasured = errors.New("the home was not walked whole")

// HelperSpec is what the keeper hands `cyfr-locus home`: the op, the path
// of a home on a person's disk (<root>/<a>/programs/<id>) and the uid it
// runs as, which is the disk's.
type HelperSpec struct {
	Op   string `json:"op"`
	Path string `json:"path"`
	UID  int    `json:"uid"`
}

// Validate checks a known op, a clean absolute path of a home on a disk,
// and a non-root uid.
func (s HelperSpec) Validate() error {
	if s.Op != OpMake && s.Op != OpMeasure && s.Op != OpReset && s.Op != OpRemove {
		return fmt.Errorf("op %q is not %s, %s, %s or %s", s.Op, OpMake, OpMeasure, OpReset, OpRemove)
	}
	if !filepath.IsAbs(s.Path) || filepath.Clean(s.Path) != s.Path {
		return fmt.Errorf("path %q is not clean and absolute", s.Path)
	}
	disk := filepath.Dir(filepath.Dir(s.Path))
	if err := (Kept{Root: filepath.Dir(disk)}).ValidateHome(s.Path, filepath.Join(disk, WorkDir)); err != nil || filepath.Dir(disk) == "/" {
		return fmt.Errorf("path %q is not a home on a disk", s.Path)
	}
	if s.UID <= 0 {
		return errors.New("uid must be non-zero")
	}
	return nil
}

// HelperMain runs `cyfr-locus home` as the disk's uid: `make` makes the
// disk, its work folder and the home, each 0700, with the home's tmp
// directory, and is done when each is already the uid's; `measure` writes
// the bytes the home holds to the result pipe, counting each entry's
// allocated blocks and never following a symbolic link, zero for a home
// not made; `reset` removes the home and makes it again empty; `remove`
// removes the home. Neither of the last two touches the disk's other homes
// or its work folder. Nothing it reads is logged.
func HelperMain() int {
	log := logx.New("cyfr-locus")
	data, err := io.ReadAll(io.LimitReader(os.NewFile(HelperSpecFD, "spec"), 4096))
	if err != nil {
		log.Error("home: spec: %v", err)
		return ExitInvalid
	}
	var spec HelperSpec
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&spec); err != nil {
		log.Error("home: spec: undecodable")
		return ExitInvalid
	}
	if err := spec.Validate(); err != nil {
		log.Error("home: spec: %v", err)
		return ExitInvalid
	}
	ruid, euid, suid := unix.Getresuid()
	if ruid != spec.UID || euid != spec.UID || suid != spec.UID {
		log.Error("home: running as uid %d/%d/%d, not %d", ruid, euid, suid, spec.UID)
		return ExitInvalid
	}
	result := os.NewFile(HelperResultFD, "result")
	defer result.Close()
	if err := run(spec, result); err != nil {
		log.Error("home: %s uid %d: %v", spec.Op, spec.UID, err)
		return ExitFailed
	}
	return ExitDone
}

// run applies a valid spec as the calling uid, a measure writing its bytes
// to result.
func run(spec HelperSpec, result io.Writer) error {
	switch spec.Op {
	case OpMake:
		return Make(spec.Path, spec.UID)
	case OpReset, OpRemove:
		if err := residue.RemovePath(spec.Path, spec.UID); err != nil {
			return err
		}
		if spec.Op == OpReset {
			return Make(spec.Path, spec.UID)
		}
		return nil
	default:
		bytes, err := Measure(spec.Path)
		if errors.Is(err, fs.ErrNotExist) {
			bytes, err = 0, nil
		}
		if err != nil {
			return err
		}
		_, err = io.WriteString(result, strconv.FormatUint(bytes, 10))
		return err
	}
}

// Make makes, as the calling uid, the disk the home at path is on, the
// disk's homes' folder and its work folder, then the home and its tmp
// directory, each 0700. The disk, its homes' folder and the home must then
// be the uid's with that mode, and the work folder a folder of the uid's,
// read without following a link: one some other uid made, a link or a file
// refuses the make, so a disk or a home another uid made is never used. A
// session sees its home and the work folder alone, and may change their
// modes; what it does inside them is its own.
func Make(path string, uid int) error {
	syscall.Umask(0o077)
	disk := filepath.Dir(filepath.Dir(path))
	work := filepath.Join(disk, WorkDir)
	for _, dir := range []string{disk, filepath.Join(disk, ProgramsDir), work, path} {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
		check := CheckKeptHome
		if dir == work {
			check = CheckWork
		}
		if err := check(dir, uid); err != nil {
			return err
		}
	}
	if err := os.Mkdir(filepath.Join(path, "tmp"), 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	return nil
}

// CheckWork reports whether path is a directory owned by uid, of any
// mode, read without following a symbolic link: a disk's work folder.
func CheckWork(path string, uid int) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || !info.IsDir() || int(st.Uid) != uid {
		return fmt.Errorf("%s: %w", path, ErrNotKeptHome)
	}
	return nil
}

// Measure answers the bytes allocated to everything under path, the
// directory itself included, without following a symbolic link or leaving
// its filesystem. An entry that vanishes while it walks is not counted. A
// walk that cannot finish, past maxMeasured entries or at a directory it
// cannot read, is an error and never a partial total.
func Measure(path string) (uint64, error) {
	var root unix.Stat_t
	if err := unix.Lstat(path, &root); err != nil {
		return 0, err
	}
	var total uint64
	visited := 0
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if visited++; visited > maxMeasured {
			return ErrUnmeasured
		}
		var st unix.Stat_t
		if err := unix.Lstat(p, &st); err != nil {
			if errors.Is(err, unix.ENOENT) {
				return nil
			}
			return err
		}
		if st.Dev != root.Dev {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		total += uint64(st.Blocks) * 512
		return nil
	})
	if err != nil {
		return 0, err
	}
	return total, nil
}
