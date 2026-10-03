// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package home names and checks the per-spawn home directories under the
// home root. A home is `<root>/<uid>-<32 hex digits>`, created 0700 by the
// spawned uid itself and removed by that uid at retirement with the rest of
// what it owns (package residue).
package home

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"
)

// RootMode is the mode the home root must have: sticky, and writable and
// searchable but not listable by the pool uids.
const RootMode = fs.ModeDir | fs.ModeSticky | 0o733

var namePattern = regexp.MustCompile(`^([1-9][0-9]{0,9})-[0-9a-f]{32}$`)

// NewName returns a fresh home name for uid with 128 random bits.
func NewName(uid int) (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return strconv.Itoa(uid) + "-" + hex.EncodeToString(nonce[:]), nil
}

// Validate checks that home is a direct child of root named for uid.
func Validate(root, home string, uid int) error {
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return fmt.Errorf("home root %q must be a clean absolute path", root)
	}
	if filepath.Clean(home) != home || filepath.Dir(home) != root {
		return fmt.Errorf("home %q must be directly under %s", home, root)
	}
	m := namePattern.FindStringSubmatch(filepath.Base(home))
	if m == nil || m[1] != strconv.Itoa(uid) {
		return fmt.Errorf("home %q is not named for uid %d", home, uid)
	}
	return nil
}

// CheckRoot verifies that root is a directory owned by uid 0 with RootMode.
func CheckRoot(root string) error {
	info, err := os.Lstat(root)
	if err != nil {
		return err
	}
	if info.Mode() != RootMode {
		return fmt.Errorf("home root %s has mode %s, want %s (a tmpfs mounted with mode=1733)", root, info.Mode(), RootMode)
	}
	if st, ok := info.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 {
		return fmt.Errorf("home root %s must be owned by uid 0", root)
	}
	return nil
}
