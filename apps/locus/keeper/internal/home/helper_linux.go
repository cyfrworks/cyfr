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

// HelperSpec is what the keeper hands `cyfr-locus home`: the op, the kept
// home's path and the uid it runs as, which is the home's.
type HelperSpec struct {
	Op   string `json:"op"`
	Path string `json:"path"`
	UID  int    `json:"uid"`
}

// Validate checks a known op, a clean absolute path other than "/" whose
// name is a kept home's id, and a non-root uid.
func (s HelperSpec) Validate() error {
	if s.Op != OpMake && s.Op != OpMeasure {
		return fmt.Errorf("op %q is not %s or %s", s.Op, OpMake, OpMeasure)
	}
	if !filepath.IsAbs(s.Path) || filepath.Clean(s.Path) != s.Path || s.Path == "/" || !ValidID(filepath.Base(s.Path)) {
		return fmt.Errorf("path %q is not a kept home", s.Path)
	}
	if s.UID <= 0 {
		return errors.New("uid must be non-zero")
	}
	return nil
}

// HelperMain runs `cyfr-locus home` as the home's uid: `make` makes the
// home 0700 with its tmp directory, and is done when the home is already
// the uid's; `measure` writes the bytes the home holds to the result pipe,
// counting each entry's allocated blocks and never following a symbolic
// link. Nothing it reads is logged.
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
	switch spec.Op {
	case OpMake:
		if err := Make(spec.Path, spec.UID); err != nil {
			log.Error("home: make uid %d: %v", spec.UID, err)
			return ExitFailed
		}
	case OpMeasure:
		bytes, err := Measure(spec.Path)
		if err != nil {
			log.Error("home: measure uid %d: %v", spec.UID, err)
			return ExitFailed
		}
		if _, err := io.WriteString(result, strconv.FormatUint(bytes, 10)); err != nil {
			return ExitFailed
		}
	}
	return ExitDone
}

// Make makes the home at path 0700, and its tmp directory, as the calling
// uid; a home that is already the uid's is made, and its tmp directory is
// made again if it is gone.
func Make(path string, uid int) error {
	syscall.Umask(0o077)
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	if err := CheckKeptHome(path, uid); err != nil {
		return err
	}
	tmp := filepath.Join(path, "tmp")
	if err := os.Mkdir(tmp, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
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
