// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package vm

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"hash"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"

	"golang.org/x/sys/unix"
)

// DigestUsage is `cyfr-locus image-digest`'s command line: the image's
// build runs it last of every step and writes what it prints to DigestFile.
const DigestUsage = "cyfr-locus image-digest"

// DigestMain prints ImageDigest of the root, leaving DigestFile out.
func DigestMain(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "usage: "+DigestUsage)
		return CheckUsageE
	}
	digest, err := ImageDigest("/", DigestFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "image-digest: %v\n", err)
		return CheckFailed
	}
	fmt.Println(digest)
	return CheckPassed
}

// ImageDigest is the image's identity, which names the machines' device
// made from it, so a new image makes a new one (Programs): a sha256 over
// every path of root's own filesystem but skip, in the walk's lexical order,
// entering no other mount. Each path is one record of five fields, each
// preceded by its length: the path below root, its mode (its type and
// permission bits), its owner and group, its link's target, and, for a
// regular file of root's own filesystem, its contents' sha256. No field
// runs into the next, so two trees whose records differ never hash alike:
// a link named "link -> middle" to "target" is not a link named "link" to
// "middle -> target". A mount point is recorded and not entered; a file
// bound from another filesystem has its record without its contents.
func ImageDigest(root, skip string) (string, error) {
	var top unix.Stat_t
	if err := unix.Lstat(root, &top); err != nil {
		return "", err
	}
	sum := sha256.New()
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == skip {
			return nil
		}
		var st unix.Stat_t
		if err := unix.Lstat(path, &st); err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		target, contents := "", ""
		switch st.Mode & unix.S_IFMT {
		case unix.S_IFLNK:
			if target, err = os.Readlink(path); err != nil {
				return err
			}
		case unix.S_IFREG:
			if st.Dev == top.Dev {
				if contents, err = fileSum(path); err != nil {
					return err
				}
			}
		}
		record(sum, filepath.Join("/", rel), strconv.FormatUint(uint64(st.Mode), 8),
			strconv.FormatUint(uint64(st.Uid), 10)+":"+strconv.FormatUint(uint64(st.Gid), 10), target, contents)
		if d.IsDir() && st.Dev != top.Dev {
			return filepath.SkipDir
		}
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("the image's digest: %w", err)
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// record writes each field to h, its length first.
func record(h hash.Hash, fields ...string) {
	var n [8]byte
	for _, f := range fields {
		binary.BigEndian.PutUint64(n[:], uint64(len(f)))
		_, _ = h.Write(n[:])
		_, _ = io.WriteString(h, f)
	}
}

// fileSum is the sha256 of a regular file's contents, opened without
// following a link.
func fileSum(path string) (string, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
