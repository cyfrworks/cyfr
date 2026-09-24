// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package procfs reads the parts of Linux /proc/<pid>/status the spawner
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

// SpawnerCaps is the one capability set the spawner runs with:
// CAP_SETUID, CAP_SETGID and CAP_KILL (0xe0).
const SpawnerCaps uint64 = 1<<CapKill | 1<<CapSetgid | 1<<CapSetuid

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

// CheckSpawnerCaps refuses a capability state other than the spawner's:
// the effective, permitted and bounding sets must each hold nothing outside
// SpawnerCaps, and the effective set must hold all of it.
func CheckSpawnerCaps(s Status) error {
	for _, set := range []struct {
		name string
		mask uint64
	}{{"CapEff", s.CapEff}, {"CapPrm", s.CapPrm}, {"CapBnd", s.CapBnd}} {
		if extra := set.mask &^ SpawnerCaps; extra != 0 {
			return fmt.Errorf("%s %016x holds capabilities outside SETUID, SETGID and KILL (%016x); run with every other capability dropped", set.name, set.mask, extra)
		}
	}
	if missing := SpawnerCaps &^ s.CapEff; missing != 0 {
		return fmt.Errorf("CapEff %016x lacks %016x; the spawner needs SETUID, SETGID and KILL", s.CapEff, missing)
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
