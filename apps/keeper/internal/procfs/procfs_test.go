// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package procfs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A status file as a container with `cap_drop: ALL` and
// `cap_add: [SETUID, SETGID, KILL]` shows it for its root process.
const spawnerStatus = `Name:	cyfr-keeper
Umask:	0022
State:	S (sleeping)
Tgid:	7
Ngid:	0
Pid:	7
PPid:	1
TracerPid:	0
Uid:	0	0	0	0
Gid:	0	0	0	0
FDSize:	64
Groups:	0 1 2 3 4 6 10 11 20 26 27
NStgid:	7
VmRSS:	    4112 kB
Threads:	5
SigQ:	0/62540
SigBlk:	0000000000000000
SigIgn:	0000000000001000
SigCgt:	fffffffd7fc1feff
CapInh:	0000000000000000
CapPrm:	00000000000000e0
CapEff:	00000000000000e0
CapBnd:	00000000000000e0
CapAmb:	0000000000000000
NoNewPrivs:	1
Seccomp:	2
Seccomp_filters:	1
`

func withField(status, key, value string) string {
	var out []string
	for _, line := range strings.Split(status, "\n") {
		if strings.HasPrefix(line, key+":") {
			line = key + ":\t" + value
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func TestParseStatus(t *testing.T) {
	st, err := ParseStatus([]byte(spawnerStatus))
	if err != nil {
		t.Fatal(err)
	}
	if st.State != 'S' || st.UIDs != [4]int{0, 0, 0, 0} || !st.NoNewPrivs {
		t.Fatalf("status %+v", st)
	}
	if st.CapEff != 0xe0 || st.CapPrm != 0xe0 || st.CapBnd != 0xe0 || st.CapInh != 0 || st.CapAmb != 0 {
		t.Fatalf("caps %+v", st)
	}
}

func TestParseStatusRefusesMalformedOrMissingLines(t *testing.T) {
	for name, input := range map[string]string{
		"no CapEff":      strings.Replace(spawnerStatus, "CapEff:", "CapXff:", 1),
		"no Uid":         strings.Replace(spawnerStatus, "Uid:", "Uxd:", 1),
		"three uids":     withField(spawnerStatus, "Uid", "0 0 0"),
		"non-hex caps":   withField(spawnerStatus, "CapBnd", "zz"),
		"oversize caps":  withField(spawnerStatus, "CapPrm", "00000000000000000e0"),
		"negative uid":   withField(spawnerStatus, "Uid", "-1 0 0 0"),
		"empty state":    withField(spawnerStatus, "State", ""),
		"empty document": "",
	} {
		if _, err := ParseStatus([]byte(input)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestSpawnerCapsAreExactlySetuidSetgidKill(t *testing.T) {
	if SpawnerCaps != 0xe0 {
		t.Fatalf("SpawnerCaps = %#x", SpawnerCaps)
	}
	st, _ := ParseStatus([]byte(spawnerStatus))
	if err := CheckSpawnerCaps(st); err != nil {
		t.Fatalf("the container's own set was refused: %v", err)
	}

	// Docker's default set for a root process.
	docker := withField(withField(withField(spawnerStatus,
		"CapEff", "00000000a80425fb"),
		"CapPrm", "00000000a80425fb"),
		"CapBnd", "00000000a80425fb")
	for name, input := range map[string]string{
		"docker defaults":           docker,
		"extra bounding capability": withField(spawnerStatus, "CapBnd", "00000000000000e1"),
		"extra permitted":           withField(spawnerStatus, "CapPrm", "00000000000001e0"),
		"no capabilities":           withField(withField(spawnerStatus, "CapEff", "0000000000000000"), "CapPrm", "0000000000000000"),
		"without KILL":              withField(spawnerStatus, "CapEff", "00000000000000c0"),
		"full root":                 withField(withField(withField(spawnerStatus, "CapEff", "000001ffffffffff"), "CapPrm", "000001ffffffffff"), "CapBnd", "000001ffffffffff"),
	} {
		st, err := ParseStatus([]byte(input))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if err := CheckSpawnerCaps(st); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestHasUIDMatchesAnyOfTheFour(t *testing.T) {
	st := Status{UIDs: [4]int{1, 2, 3, 4}}
	for _, uid := range []int{1, 2, 3, 4} {
		if !st.HasUID(uid) {
			t.Errorf("uid %d not matched", uid)
		}
	}
	if st.HasUID(5) {
		t.Error("uid 5 matched")
	}
}

func writeProc(t *testing.T, root string, pid, state, uids string) {
	t.Helper()
	dir := filepath.Join(root, pid)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	status := withField(withField(spawnerStatus, "State", state), "Uid", uids)
	if err := os.WriteFile(filepath.Join(dir, "status"), []byte(status), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestScanUIDCountsLiveAndZombieProcesses(t *testing.T) {
	root := t.TempDir()
	writeProc(t, root, "10", "S (sleeping)", "20001\t20001\t20001\t20001")
	writeProc(t, root, "11", "Z (zombie)", "20001\t20001\t20001\t20001")
	writeProc(t, root, "12", "R (running)", "10001\t10001\t20001\t10001")
	writeProc(t, root, "13", "S (sleeping)", "20002\t20002\t20002\t20002")
	writeProc(t, root, "14", "S (sleeping)", "20001\t20001\t20001\t20001")
	if err := os.MkdirAll(filepath.Join(root, "self"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "99"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := ScanUID(root, 20001, 14)
	if err != nil {
		t.Fatal(err)
	}
	if got != (Count{Live: 2, Zombies: 1}) || got.Total() != 3 {
		t.Fatalf("count %+v", got)
	}

	none, err := ScanUID(root, 20003, 0)
	if err != nil || none.Total() != 0 {
		t.Fatalf("count for an unused uid %+v %v", none, err)
	}
}
