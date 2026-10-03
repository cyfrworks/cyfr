// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package procfs reads the parts of Linux /proc/<pid>/status the keeper
// relies on: the capability sets, the four uids and the process state.
package procfs

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Capability numbers (linux/capability.h).
const (
	CapKill   = 5
	CapSetgid = 6
	CapSetuid = 7
)

// KeeperCaps is the one capability set the keeper runs with:
// CAP_SETUID, CAP_SETGID and CAP_KILL (0xe0).
const KeeperCaps uint64 = 1<<CapKill | 1<<CapSetgid | 1<<CapSetuid

// Status is the parsed subset of a /proc/<pid>/status file.
type Status struct {
	// State is the one-letter process state (R, S, D, Z, T, ...).
	State byte
	// UIDs are the real, effective, saved and filesystem uids.
	UIDs   [4]int
	CapInh uint64
	CapPrm uint64
	CapEff uint64
	CapBnd uint64
	CapAmb uint64
	// NoNewPrivs reports the no_new_privs bit.
	NoNewPrivs bool
}

// ParseStatus parses a status file. State, Uid and the five capability
// lines are required; NoNewPrivs is read when present.
func ParseStatus(data []byte) (Status, error) {
	var st Status
	seen := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		key, value, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		var err error
		switch key {
		case "State":
			if value == "" {
				err = errors.New("empty")
			} else {
				st.State = value[0]
			}
		case "Uid":
			err = parseUIDs(value, &st.UIDs)
		case "CapInh":
			st.CapInh, err = parseCaps(value)
		case "CapPrm":
			st.CapPrm, err = parseCaps(value)
		case "CapEff":
			st.CapEff, err = parseCaps(value)
		case "CapBnd":
			st.CapBnd, err = parseCaps(value)
		case "CapAmb":
			st.CapAmb, err = parseCaps(value)
		case "NoNewPrivs":
			st.NoNewPrivs = value == "1"
		default:
			continue
		}
		if err != nil {
			return Status{}, fmt.Errorf("status %s: %w", key, err)
		}
		seen[key] = true
	}
	if err := sc.Err(); err != nil {
		return Status{}, err
	}
	for _, key := range []string{"State", "Uid", "CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb"} {
		if !seen[key] {
			return Status{}, fmt.Errorf("status: no %s line", key)
		}
	}
	return st, nil
}

func parseUIDs(value string, out *[4]int) error {
	fields := strings.Fields(value)
	if len(fields) != 4 {
		return fmt.Errorf("want 4 uids, got %d", len(fields))
	}
	for i, f := range fields {
		n, err := strconv.ParseUint(f, 10, 32)
		if err != nil {
			return err
		}
		out[i] = int(n)
	}
	return nil
}

func parseCaps(value string) (uint64, error) {
	if len(value) == 0 || len(value) > 16 {
		return 0, fmt.Errorf("capability mask %q", value)
	}
	return strconv.ParseUint(value, 16, 64)
}

// HasUID reports whether any of the process's four uids is uid. Signal
// permission and ptrace access both follow these uids.
func (s Status) HasUID(uid int) bool {
	for _, u := range s.UIDs {
		if u == uid {
			return true
		}
	}
	return false
}

// Zombie reports whether the process has exited and awaits reaping.
func (s Status) Zombie() bool { return s.State == 'Z' || s.State == 'X' }

type capSet struct {
	name string
	mask uint64
}

// sets are the five capability sets in the order /proc names them.
func (s Status) sets() []capSet {
	return []capSet{{"CapInh", s.CapInh}, {"CapPrm", s.CapPrm}, {"CapEff", s.CapEff}, {"CapBnd", s.CapBnd}, {"CapAmb", s.CapAmb}}
}

// CheckKeeperCaps refuses a capability state other than the keeper's: the
// permitted, effective and bounding sets hold exactly KeeperCaps, and the
// inheritable and ambient sets hold nothing, so no process the keeper
// executes inherits a capability through them. The error names the first
// set at fault.
func CheckKeeperCaps(s Status) error {
	for _, set := range s.sets() {
		want := KeeperCaps
		if set.name == "CapInh" || set.name == "CapAmb" {
			want = 0
		}
		if set.mask != want {
			return fmt.Errorf("%s is %016x, not %016x: the keeper runs with exactly SETUID, SETGID and KILL permitted, effective and bounding, and with no inheritable or ambient capability", set.name, set.mask, want)
		}
	}
	return nil
}

// AnyBounding lets CheckNoCaps accept whatever bounding set a process holds.
const AnyBounding = ^uint64(0)

// CheckNoCaps refuses a process about to execute a spawned command while
// it holds a capability: its inheritable, permitted, effective and ambient
// sets must be empty, no_new_privs must be set, and its bounding set must
// hold nothing outside bounding. A stage in a namespace of its own is
// checked with bounding zero, every set empty. One sharing the keeper's
// namespace cannot drop a bounding capability without CAP_SETPCAP and is
// checked with AnyBounding: its bounding set is the keeper's, which the
// keeper's own start check holds to KeeperCaps, and no_new_privs keeps
// anything it executes from raising it. The error names the first set at
// fault.
func CheckNoCaps(s Status, bounding uint64) error {
	for _, set := range s.sets() {
		allowed := uint64(0)
		if set.name == "CapBnd" {
			allowed = bounding
		}
		if extra := set.mask &^ allowed; extra != 0 {
			return fmt.Errorf("%s is %016x: capabilities %016x remain", set.name, set.mask, extra)
		}
	}
	if !s.NoNewPrivs {
		return errors.New("no_new_privs is unset")
	}
	return nil
}

// Count is the result of a uid scan.
type Count struct {
	// Live counts processes that have not exited.
	Live int
	// Zombies counts exited processes not yet reaped.
	Zombies int
}

// Total is every process found, live or awaiting reaping.
func (c Count) Total() int { return c.Live + c.Zombies }

// ScanUID counts the processes under root (a /proc mount) having uid among
// their four uids, skipping the process exclude. A process that vanishes
// during the scan is not counted.
func ScanUID(root string, uid int, exclude int) (Count, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return Count{}, err
	}
	var c Count
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 || pid == exclude {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, e.Name(), "status"))
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) || isESRCH(err) {
				continue
			}
			return Count{}, err
		}
		st, err := ParseStatus(data)
		if err != nil {
			return Count{}, fmt.Errorf("pid %d: %w", pid, err)
		}
		if !st.HasUID(uid) {
			continue
		}
		if st.Zombie() {
			c.Zombies++
		} else {
			c.Live++
		}
	}
	return c, nil
}
