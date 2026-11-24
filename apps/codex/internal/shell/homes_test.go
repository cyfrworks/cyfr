// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sameRecord is whether two records hold the same fields, the certificates
// compared as JSON.
func sameRecord(a, b ClientRecord) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

func listOf(t *testing.T, f Homes) HomeList {
	t.Helper()
	l, err := f.Load()
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func admit(t *testing.T, sel *Selection, id, cert string) {
	t.Helper()
	if err := sel.Update(func(c *ClientRecord) bool {
		c.ClientID, c.Certificate = id, json.RawMessage(cert)
		return true
	}); err != nil {
		t.Fatal(err)
	}
}

// Each CYFR of the list keeps its own standing: an entry is added only
// once the app opened its CYFR or that CYFR admitted this device, a CYFR
// opened later is the one selected last without touching another's
// client, and an address is a folder's or a CYFR elsewhere for good.
func TestTheListKeepsEachCYFRsStandingApart(t *testing.T) {
	const a, b, box = "https://a.example.com", "https://b.example.com", "http://localhost:4000"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))

	// Selecting writes nothing; nor does a refused first hello's forget.
	sel, err := f.Select(a, "https://cyfr.run", true)
	if err != nil {
		t.Fatal(err)
	}
	if err := sel.Update(func(c *ClientRecord) bool { c.Certificate = nil; return true }); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(string(f)); !os.IsNotExist(err) {
		t.Fatalf("a selection neither opened nor admitted wrote the list (%v)", err)
	}
	if err := sel.Commit(); err != nil {
		t.Fatal(err)
	}
	admit(t, sel, "pcl_a", `{"a":1}`)
	atA := ClientRecord{Directory: "https://cyfr.run", ClientID: "pcl_a", Certificate: json.RawMessage(`{"a": 1}`), Generation: 1}
	if l := listOf(t, f); !sameRecord(l.Homes[a], atA) || l.Last != a {
		t.Fatalf("the CYFR opened and admitted is %+v, last %q", l.Homes[a], l.Last)
	}

	// Another CYFR, admitted before it was opened: added by its admission,
	// and selected last once opened; the first keeps its client.
	other, _ := f.Select(b, "https://accounts.example.com", true)
	admit(t, other, "pcl_b", `{"b":1}`)
	if err := other.Commit(); err != nil {
		t.Fatal(err)
	}
	l := listOf(t, f)
	if !sameRecord(l.Homes[a], atA) || l.Homes[b].ClientID != "pcl_b" || l.Homes[b].Directory != "https://accounts.example.com" ||
		l.Homes[b].Generation != 2 || l.Last != b {
		t.Fatalf("a second CYFR made the list %+v", l)
	}

	// The same CYFR again, under a directory approved now: its client
	// stays and the directory is the new one.
	again, _ := f.Select(a, "https://accounts.example.com", true)
	if c, _ := again.Load(); c.ClientID != "pcl_a" || c.Directory != "https://accounts.example.com" {
		t.Fatalf("a new directory for the same CYFR dropped its client: %+v", c)
	}
	if err := again.Commit(); err != nil {
		t.Fatal(err)
	}
	if l := listOf(t, f); l.Homes[a].ClientID != "pcl_a" || l.Homes[a].Directory != "https://accounts.example.com" || l.Last != a {
		t.Fatalf("committed %+v", l)
	}
	if err := f.EndApproval(a, ""); err != nil {
		t.Fatal(err)
	}
	if l := listOf(t, f); l.Homes[a].Directory != "" || l.Homes[a].ClientID != "pcl_a" || l.Homes[b].Directory == "" {
		t.Fatalf("the approval did not end alone: %+v", l)
	}

	// A folder's CYFR: the address is that folder's, never a CYFR
	// elsewhere's, and never another folder's.
	here, err := f.SelectLocal(box, "/home/ada/cyfr")
	if err != nil {
		t.Fatal(err)
	}
	if err := here.Commit(); err != nil {
		t.Fatal(err)
	}
	if l := listOf(t, f); !sameRecord(l.Homes[box], ClientRecord{Project: "/home/ada/cyfr", Generation: 3}) || l.Last != box {
		t.Fatalf("the folder's CYFR is %+v", l)
	}
	if _, err := f.Select(box, "https://cyfr.run", true); err == nil || !strings.Contains(err.Error(), "/home/ada/cyfr") {
		t.Fatalf("a folder's entry was taken as a CYFR elsewhere: %v", err)
	}
	if _, err := f.SelectLocal(box, "/home/ada/other"); err == nil {
		t.Fatal("another folder took a folder's address")
	}
	if _, err := f.SelectLocal(a, "/home/ada/cyfr"); err == nil {
		t.Fatal("a folder took a CYFR elsewhere's address")
	}
}

// An entry gone from the list stays gone: a selection bound to it, writing
// late, recreates nothing, and its commit is refused.
func TestAWriterOfAnEntryGoneWritesNothing(t *testing.T) {
	const a = "https://a.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	sel, _ := f.Select(a, "https://cyfr.run", true)
	if err := sel.Commit(); err != nil {
		t.Fatal(err)
	}
	admit(t, sel, "pcl_a", `{"a":1}`)
	if err := f.Update(func(l *HomeList) bool {
		delete(l.Homes, a)
		l.Last = ""
		return true
	}); err != nil {
		t.Fatal(err)
	}
	admit(t, sel, "pcl_a", `{"a":2}`)
	if err := sel.Commit(); err == nil {
		t.Fatal("a selection of an entry gone committed")
	}
	if l := listOf(t, f); len(l.Homes) != 0 || l.Last != "" {
		t.Fatalf("a late writer recreated the entry: %+v", l)
	}
}

// A file that is not this list is refused whole and left as it is.
func TestAListItCannotReadIsRefusedAndKept(t *testing.T) {
	for name, raw := range map[string]string{
		"not JSON":              `{"homes":`,
		"another version":       `{"version":2,"homes":{},"generations":0}`,
		"an unknown field":      `{"version":1,"homes":{},"generations":0,"why":1}`,
		"an address unspelled":  `{"version":1,"homes":{"https://A.example.com/":{"generation":1}},"generations":1}`,
		"an entry unnumbered":   `{"version":1,"homes":{"https://a.example.com":{}},"generations":1}`,
		"a number never given":  `{"version":1,"homes":{"https://a.example.com":{"generation":2}},"generations":1}`,
		"a folder from nowhere": `{"version":1,"homes":{"http://localhost:4000":{"project":"cyfr","generation":1}},"generations":1}`,
		"a last it lacks":       `{"version":1,"homes":{},"last":"https://a.example.com","generations":0}`,
	} {
		t.Run(name, func(t *testing.T) {
			f := Homes(filepath.Join(t.TempDir(), "homes.json"))
			if err := os.WriteFile(string(f), []byte(raw), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := f.Load(); err == nil {
				t.Fatal("read")
			}
			sel, _ := f.Select("https://b.example.com", "https://cyfr.run", true)
			if sel != nil {
				t.Fatal("a selection over a list it cannot read")
			}
			err := f.Update(func(l *HomeList) bool { return true })
			if after, _ := os.ReadFile(string(f)); err == nil || string(after) != raw {
				t.Fatalf("the list was written over (%v): %s", err, after)
			}
		})
	}
}

// Two writers of an entry lose neither change: an approval ending while
// the shell, holding its copy of the record, renews the certificate.
func TestAnApprovalEndingAndARenewalBothStand(t *testing.T) {
	const a = "https://cyfr.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	first, _ := f.Select(a, "https://accounts.example.com", true)
	if err := first.Commit(); err != nil {
		t.Fatal(err)
	}
	admit(t, first, "pcl_1", `{"n":1}`)
	sel, err := f.Select(a, "https://accounts.example.com", false)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.EndApproval(a, "https://elsewhere.example.com"); err != nil {
		t.Fatal(err)
	}
	if err := sel.Update(func(c *ClientRecord) bool { c.Certificate = json.RawMessage(`{"n":2}`); return true }); err != nil {
		t.Fatal(err)
	}
	if c := listOf(t, f).Homes[a]; c.Directory != "" || !strings.Contains(string(c.Certificate), `"n": 2`) {
		t.Fatalf("a change was lost: %+v", c)
	}
}
