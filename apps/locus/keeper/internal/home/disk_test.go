// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package home

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// recordsOfMine is a kept root of the test's own uid whose records are
// read as the keeper's: the test stands in for uid 0.
func recordsOfMine(t *testing.T, size int) Kept {
	t.Helper()
	saved := keeperUID
	keeperUID = uint32(os.Getuid())
	t.Cleanup(func() { keeperUID = saved })
	return keptOfMine(t, size)
}

// A person's disk is named by the SHA-256 of their athanor's id, its homes
// under programs/ and its work folder beside them; a home is valid only on
// a disk directly under the root, with that disk's work folder.
func TestADisksPathsAreItsAthanors(t *testing.T) {
	if got := Person("ath_1"); !personPattern.MatchString(got) {
		t.Fatalf("person %q", got)
	}
	if Person("a/b") == Person("a") || strings.Contains(Person("a/b"), "/") {
		t.Fatal("an athanor with a slash names a folder of its own")
	}
	k := Kept{Root: "/k"}
	a := Person("ath_1")
	if k.DiskPath("ath_1") != "/k/"+a || k.HomePath("ath_1", "vlt_a") != "/k/"+a+"/programs/vlt_a" || k.WorkOf("ath_1") != "/k/"+a+"/work" {
		t.Fatalf("paths %s %s %s", k.DiskPath("ath_1"), k.HomePath("ath_1", "vlt_a"), k.WorkOf("ath_1"))
	}
	if err := k.ValidateHome(k.HomePath("ath_1", "vlt_a"), k.WorkOf("ath_1")); err != nil {
		t.Fatal(err)
	}
	for home, work := range map[string]string{
		"/k/vlt_a":                      k.WorkOf("ath_1"),
		k.HomePath("ath_1", "vlt_a"):    k.WorkOf("ath_2"),
		k.HomePath("ath_1", ".x"):       k.WorkOf("ath_1"),
		"/k/" + a + "/work/vlt_a":       k.WorkOf("ath_1"),
		"/k/x/programs/vlt_a":           "/k/x/work",
		"/o/" + a + "/programs/vlt_a":   "/o/" + a + "/work",
		"/k/d/" + a + "/programs/vlt_a": "/k/d/" + a + "/work",
	} {
		if err := k.ValidateHome(home, work); err == nil {
			t.Errorf("%s with %s accepted", home, work)
		}
	}
}

// A record is written whole and read back as written; its homes are kept
// in byte order, a home added once; the records' folder is the keeper's
// own, made at the first read, and what a write left half done is removed.
func TestADisksRecordIsWrittenWholeAndReadBack(t *testing.T) {
	k := recordsOfMine(t, 4)
	disks, err := k.LoadDisks()
	if err != nil || len(disks) != 0 {
		t.Fatalf("an empty root: %v %v", disks, err)
	}
	if info, err := os.Lstat(filepath.Join(k.Root, DisksDir)); err != nil || info.Mode() != DisksDirMode {
		t.Fatalf("the records' folder: %v %v", info, err)
	}
	d := Disk{Athanor: "family@example/a", Form: FormDirectory, UID: k.First + 1, Homes: []string{}}
	d = d.With("vlt_b").With("vlt_a").With("vlt_b")
	if !reflect.DeepEqual(d.Homes, []string{"vlt_a", "vlt_b"}) || !d.Holds("vlt_a") || d.Holds("vlt_c") {
		t.Fatalf("homes %v", d.Homes)
	}
	if err := k.WriteDisk(d); err != nil {
		t.Fatal(err)
	}
	if err := k.WriteDisk(Disk{Athanor: "ath_2", Form: FormDirectory, UID: k.First}); err != nil {
		t.Fatal(err)
	}
	half := filepath.Join(k.Root, DisksDir, "."+Person("ath_3")+".json.123")
	if err := os.WriteFile(half, []byte("{"), RecordMode); err != nil {
		t.Fatal(err)
	}
	disks, err = k.LoadDisks()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]*Disk{"family@example/a": &d, "ath_2": {Athanor: "ath_2", Form: FormDirectory, UID: k.First, Homes: []string{}}}
	if !reflect.DeepEqual(disks, want) {
		t.Fatalf("read %+v, want %+v", disks, want)
	}
	if _, err := os.Lstat(half); !os.IsNotExist(err) {
		t.Fatalf("a half-written record was left: %v", err)
	}
	if err := k.WriteDisk(d.Without("vlt_a")); err != nil {
		t.Fatal(err)
	}
	if disks, err = k.LoadDisks(); err != nil || !reflect.DeepEqual(disks["family@example/a"].Homes, []string{"vlt_b"}) {
		t.Fatalf("after a removal: %+v %v", disks, err)
	}
}

// The keeper does not start over a record it cannot trust, and says which
// file it is: one of another
// mode, a link, one naming another athanor than its name, of another form,
// of a uid outside the range, with its homes out of order, or two records
// sharing a home or a uid.
func TestARecordTheKeeperCannotTrustIsRefused(t *testing.T) {
	cases := map[string]func(k Kept, dir string) error{
		"another mode": func(k Kept, dir string) error {
			return os.Chmod(k.recordPath(Person("ath_1")), 0o644)
		},
		"a link": func(k Kept, dir string) error {
			p := k.recordPath(Person("ath_1"))
			if err := os.Rename(p, p+"x"); err != nil {
				return err
			}
			return os.Symlink(p+"x", p)
		},
		"another athanor's name": func(k Kept, dir string) error {
			return os.Rename(k.recordPath(Person("ath_1")), k.recordPath(Person("ath_9")))
		},
		"a name that is no athanor's": func(k Kept, dir string) error {
			return os.WriteFile(filepath.Join(dir, "x.json"), []byte("{}"), RecordMode)
		},
		"another form": func(k Kept, dir string) error {
			return os.WriteFile(k.recordPath(Person("ath_1")), []byte(`{"athanor":"ath_1","form":"volume","uid":`+itoa(k.First)+`,"homes":[]}`), RecordMode)
		},
		"a uid outside the range": func(k Kept, dir string) error {
			return os.WriteFile(k.recordPath(Person("ath_1")), []byte(`{"athanor":"ath_1","form":"directory","uid":`+itoa(k.Last+1)+`,"homes":[]}`), RecordMode)
		},
		"homes out of order": func(k Kept, dir string) error {
			return os.WriteFile(k.recordPath(Person("ath_1")), []byte(`{"athanor":"ath_1","form":"directory","uid":`+itoa(k.First)+`,"homes":["b","a"]}`), RecordMode)
		},
		"an unknown member": func(k Kept, dir string) error {
			return os.WriteFile(k.recordPath(Person("ath_1")), []byte(`{"athanor":"ath_1","form":"directory","uid":`+itoa(k.First)+`,"homes":[],"x":1}`), RecordMode)
		},
		"a home on two disks": func(k Kept, dir string) error {
			return k.WriteDisk(Disk{Athanor: "ath_2", Form: FormDirectory, UID: k.First + 1, Homes: []string{"vlt_a"}})
		},
		"a uid of two disks": func(k Kept, dir string) error {
			return k.WriteDisk(Disk{Athanor: "ath_2", Form: FormDirectory, UID: k.First, Homes: []string{}})
		},
	}
	for name, spoil := range cases {
		t.Run(name, func(t *testing.T) {
			k := recordsOfMine(t, 4)
			if _, err := k.LoadDisks(); err != nil {
				t.Fatal(err)
			}
			if err := k.WriteDisk(Disk{Athanor: "ath_1", Form: FormDirectory, UID: k.First, Homes: []string{"vlt_a"}}); err != nil {
				t.Fatal(err)
			}
			if err := spoil(k, filepath.Join(k.Root, DisksDir)); err != nil {
				t.Fatal(err)
			}
			disks, err := k.LoadDisks()
			if err == nil {
				t.Fatalf("read %+v", disks)
			}
			// The refusal names the record's file, which its operator removes.
			if !strings.Contains(err.Error(), filepath.Join(k.Root, DisksDir)+"/") {
				t.Fatalf("the refusal names no record's file: %v", err)
			}
		})
	}
	// A records' folder that is not the keeper's own is refused too.
	k := recordsOfMine(t, 1)
	if err := os.Mkdir(filepath.Join(k.Root, DisksDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(k.Root, DisksDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := k.LoadDisks(); !errors.Is(err, ErrBadRecord) {
		t.Fatalf("a records' folder of mode 0755: %v", err)
	}
}

func itoa(n int) string { return strconv.Itoa(n) }
