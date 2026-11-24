// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
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
	sel, err := f.Select(a, "https://cyfr.run", true, Typed)
	if err != nil {
		t.Fatal(err)
	}
	if err := sel.Update(func(c *ClientRecord) bool { c.Certificate = nil; return true }); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(string(f)); !os.IsNotExist(err) {
		t.Fatalf("a selection neither opened nor admitted wrote the list (%v)", err)
	}
	if err := sel.Commit(""); err != nil {
		t.Fatal(err)
	}
	admit(t, sel, "pcl_a", `{"a":1}`)
	atA := ClientRecord{Directory: "https://cyfr.run", ClientID: "pcl_a", Certificate: json.RawMessage(`{"a": 1}`), Generation: 2}
	if l := listOf(t, f); !sameRecord(l.Homes[a], atA) || l.Last != a {
		t.Fatalf("the CYFR opened and admitted is %+v, last %q", l.Homes[a], l.Last)
	}

	// Another CYFR, admitted before it was opened: added by its admission,
	// and selected last once opened; the first keeps its client.
	other, _ := f.Select(b, "https://accounts.example.com", true, Typed)
	admit(t, other, "pcl_b", `{"b":1}`)
	if err := other.Commit(""); err != nil {
		t.Fatal(err)
	}
	l := listOf(t, f)
	if !sameRecord(l.Homes[a], atA) || l.Homes[b].ClientID != "pcl_b" || l.Homes[b].Directory != "https://accounts.example.com" ||
		l.Homes[b].Generation != 3 || l.Last != b {
		t.Fatalf("a second CYFR made the list %+v", l)
	}

	// The same CYFR again, under a directory approved now: its client
	// stays and the directory is the new one.
	again, _ := f.Select(a, "https://accounts.example.com", true, Typed)
	if c, _ := again.Load(); c.ClientID != "pcl_a" || c.Directory != "https://accounts.example.com" {
		t.Fatalf("a new directory for the same CYFR dropped its client: %+v", c)
	}
	if err := again.Commit(""); err != nil {
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
	here, err := f.SelectLocal(box, "/home/ada/cyfr", Typed)
	if err != nil {
		t.Fatal(err)
	}
	if err := here.Commit(""); err != nil {
		t.Fatal(err)
	}
	if l := listOf(t, f); !sameRecord(l.Homes[box], ClientRecord{Project: "/home/ada/cyfr", Generation: 4}) || l.Last != box {
		t.Fatalf("the folder's CYFR is %+v", l)
	}
	if _, err := f.Select(box, "https://cyfr.run", true, Typed); err == nil || !strings.Contains(err.Error(), "/home/ada/cyfr") {
		t.Fatalf("a folder's entry was taken as a CYFR elsewhere: %v", err)
	}
	if _, err := f.SelectLocal(box, "/home/ada/other", Typed); err == nil {
		t.Fatal("another folder took a folder's address")
	}
	if _, err := f.SelectLocal(a, "/home/ada/cyfr", Typed); err == nil {
		t.Fatal("a folder took a CYFR elsewhere's address")
	}
}

// An entry gone from the list stays gone: a selection bound to it, writing
// late, recreates nothing, and its commit is refused.
func TestAWriterOfAnEntryGoneWritesNothing(t *testing.T) {
	const a = "https://a.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	sel, _ := f.Select(a, "https://cyfr.run", true, Typed)
	if err := sel.Commit(""); err != nil {
		t.Fatal(err)
	}
	admit(t, sel, "pcl_a", `{"a":1}`)
	removeAt(t, f, a)
	admit(t, sel, "pcl_a", `{"a":2}`)
	if err := sel.Commit(""); err == nil {
		t.Fatal("a selection of an entry gone committed")
	}
	if l := listOf(t, f); len(l.Homes) != 0 || l.Last != "" {
		t.Fatalf("a late writer recreated the entry: %+v", l)
	}
}

// removeAt takes the entry at home out of f, as a Forget's end does.
func removeAt(t *testing.T, f Homes, home string) {
	t.Helper()
	if err := f.Update(func(l *HomeList) bool { l.remove(home); return true }); err != nil {
		t.Fatal(err)
	}
}

// A renewal that arrives after the CYFR admitted this device anew, under
// another client, leaves the new admission's certificate as it is.
func TestALateRenewalLeavesANewerAdmission(t *testing.T) {
	const a = "https://a.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	first, _ := f.Select(a, "https://cyfr.run", true, Typed)
	if err := first.Commit(""); err != nil {
		t.Fatal(err)
	}
	old, _ := f.Select(a, "https://cyfr.run", true, Typed)
	replacement, _ := f.Select(a, "https://cyfr.run", true, Typed)
	admit(t, replacement, "pcl_new", `{"client":"new"}`)
	if err := old.Update(func(c *ClientRecord) bool { c.Certificate = json.RawMessage(`{"client":"old"}`); return true }); err != nil {
		t.Fatal(err)
	}
	if c := listOf(t, f).Homes[a]; c.ClientID != "pcl_new" || !strings.Contains(string(c.Certificate), `"new"`) {
		t.Fatalf("a late renewal replaced the newer admission: %+v", c)
	}
	// Its own renewal, the same client's next certificate, still lands.
	if err := replacement.Update(func(c *ClientRecord) bool { c.Certificate = json.RawMessage(`{"client":"new","n":2}`); return true }); err != nil {
		t.Fatal(err)
	}
	if c := listOf(t, f).Homes[a]; !strings.Contains(string(c.Certificate), `"n": 2`) {
		t.Fatalf("the admission's own renewal was lost: %+v", c)
	}
}

// A selection begun where the list held nothing adds nothing once an entry
// came and went there meanwhile.
func TestASelectionOfAnAddressThatCameAndWentAddsNothing(t *testing.T) {
	const a = "https://a.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	pending, _ := f.Select(a, "https://cyfr.run", true, Typed)
	added, _ := f.Select(a, "https://cyfr.run", true, Typed)
	if err := added.Commit(""); err != nil {
		t.Fatal(err)
	}
	removeAt(t, f, a)
	admit(t, pending, "pcl_late", `{"client":"late"}`)
	if err := pending.Commit(""); err == nil {
		t.Fatal("a selection of an address that came and went committed")
	}
	if l := listOf(t, f); len(l.Homes) != 0 || l.Last != "" {
		t.Fatalf("a late writer recreated the entry: %+v", l)
	}
	// A selection begun after, of the same address, adds it.
	again, _ := f.Select(a, "https://cyfr.run", true, Typed)
	if err := again.Commit(""); err != nil {
		t.Fatal(err)
	}
	if l := listOf(t, f); l.Last != a || len(l.Gone) != 0 {
		t.Fatalf("the address added again is %+v", l)
	}
}

// A selection begun from a row (a press of one, or of the last one opened)
// updates that row alone: it is refused once the list no longer holds the
// same entry, whether a Forget ended before it began, between its start
// and its commit, or before an admission it writes, and it adds none on any
// of them; one the list still holds commits as any other.
func TestASelectionBegunFromARowAddsNoCYFR(t *testing.T) {
	const a = "https://a.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	if _, err := f.Row(a); !IsUnkept(err) {
		t.Fatalf("a row the list does not hold was taken: %v", err)
	}
	keep := func() Row {
		sel, _ := f.Select(a, "https://cyfr.run", true, Typed)
		if err := sel.Commit(""); err != nil {
			t.Fatal(err)
		}
		row, err := f.Row(a)
		if err != nil {
			t.Fatal(err)
		}
		return row
	}
	forget := func() {
		rec, _, _ := f.Forgetting(a)
		if err := f.Forgotten(a, rec.Generation); err != nil {
			t.Fatal(err)
		}
	}
	unheld := func(road string) {
		t.Helper()
		if l := listOf(t, f); len(l.Homes) != 0 || l.Last != "" {
			t.Fatalf("%s added the CYFR forgotten: %+v", road, l)
		}
	}

	row := keep()
	forget()
	if _, err := f.Select(a, "https://cyfr.run", true, row); !IsUnkept(err) {
		t.Fatalf("a row forgotten before its selection began was selected: %v", err)
	}
	if _, err := f.SelectLocal(a, "/home/ada/cyfr", row); !IsUnkept(err) {
		t.Fatalf("a row forgotten before its folder's selection began was selected: %v", err)
	}
	unheld("a selection of a row forgotten")

	sel, err := f.Select(a, "https://cyfr.run", true, keep())
	if err != nil {
		t.Fatal(err)
	}
	forget()
	if err := sel.Commit(""); err == nil {
		t.Fatal("a commit of a row forgotten meanwhile was taken")
	}
	unheld("a commit")

	sel, _ = f.Select(a, "https://cyfr.run", true, keep())
	forget()
	if err := sel.Update(func(r *ClientRecord) bool {
		r.ClientID, r.Certificate = "pcl_a", json.RawMessage(`{"a": 1}`)
		return true
	}); err != nil {
		t.Fatal(err)
	}
	unheld("an admission")

	kept, err := f.Select(a, "https://cyfr.run", true, keep())
	if err != nil {
		t.Fatal(err)
	}
	if err := kept.Commit(""); err != nil {
		t.Fatalf("a CYFR the list holds was refused: %v", err)
	}
	if l := listOf(t, f); l.Last != a || len(l.Homes) != 1 {
		t.Fatalf("the list is %+v", l)
	}
}

// A file that is not this list is refused whole and left as it is.
func TestAListItCannotReadIsRefusedAndKept(t *testing.T) {
	for name, raw := range map[string]string{
		"not JSON":               `{"homes":`,
		"cut short":              `{"version":1,"homes":{"https://a.example.com":{"generation":1}},"generati`,
		"a brace after it":       `{"version":1,"homes":{},"generations":0}}`,
		"a second list after it": `{"version":1,"homes":{},"generations":0}{"version":1,"homes":{},"generations":0}`,
		"a gone entry held":      `{"version":1,"homes":{"https://a.example.com":{"generation":1}},"generations":2,"gone":{"https://a.example.com":2}}`,
		"another version":        `{"version":2,"homes":{},"generations":0}`,
		"an unknown field":       `{"version":1,"homes":{},"generations":0,"why":1}`,
		"an address unspelled":   `{"version":1,"homes":{"https://A.example.com/":{"generation":1}},"generations":1}`,
		"an entry unnumbered":    `{"version":1,"homes":{"https://a.example.com":{}},"generations":1}`,
		"a number never given":   `{"version":1,"homes":{"https://a.example.com":{"generation":2}},"generations":1}`,
		"a folder from nowhere":  `{"version":1,"homes":{"http://localhost:4000":{"project":"cyfr","generation":1}},"generations":1}`,
		"a last it lacks":        `{"version":1,"homes":{},"last":"https://a.example.com","generations":0}`,
	} {
		t.Run(name, func(t *testing.T) {
			f := Homes(filepath.Join(t.TempDir(), "homes.json"))
			if err := os.WriteFile(string(f), []byte(raw), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := f.Load(); err == nil {
				t.Fatal("read")
			}
			sel, _ := f.Select("https://b.example.com", "https://cyfr.run", true, Typed)
			if sel != nil {
				t.Fatal("a selection over a list it cannot read")
			}
			err := f.Update(func(l *HomeList) bool { return true })
			if after, _ := os.ReadFile(string(f)); err == nil || string(after) != raw {
				t.Fatalf("the list was written over (%v): %s", err, after)
			}
			// Nor does a selection begun before the file went bad write it.
			sound := Homes(filepath.Join(t.TempDir(), "homes.json"))
			early, err := sound.Select("https://b.example.com", "https://cyfr.run", true, Typed)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(string(sound), []byte(raw), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := early.Commit(""); err == nil {
				t.Fatal("a commit over a file that is not a list went on")
			}
			if after, _ := os.ReadFile(string(sound)); string(after) != raw {
				t.Fatalf("a commit wrote over the file: %s", after)
			}
		})
	}
}

// Two writers of an entry lose neither change: an approval ending while
// the shell, holding its copy of the record, renews the certificate.
func TestAnApprovalEndingAndARenewalBothStand(t *testing.T) {
	const a = "https://cyfr.example.com"
	f := Homes(filepath.Join(t.TempDir(), "homes.json"))
	first, _ := f.Select(a, "https://accounts.example.com", true, Typed)
	if err := first.Commit(""); err != nil {
		t.Fatal(err)
	}
	admit(t, first, "pcl_1", `{"n":1}`)
	sel, err := f.Select(a, "https://accounts.example.com", false, Typed)
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

// A write that failed leaves the selection bound as it was: an admission
// the list's folder refused to save fails and says so, and its retry,
// once the folder takes it, is saved.
func TestAFailedWriteIsWrittenByItsRetry(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("the folder's mode refuses no write here")
	}
	const home = "https://a.example.com"
	dir := t.TempDir()
	f := Homes(filepath.Join(dir, "homes.json"))
	sel, err := f.Select(home, "https://cyfr.run", true, Typed)
	if err != nil {
		t.Fatal(err)
	}
	if err := sel.Commit(""); err != nil {
		t.Fatal(err)
	}
	set := func() error {
		return sel.Update(func(c *ClientRecord) bool {
			c.ClientID, c.Certificate = "admitted", json.RawMessage(`{"expires_at":100}`)
			return true
		})
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	if set() == nil {
		t.Fatal("an admission the folder refused to save answered that it was saved")
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := listOf(t, f).Homes[home]; got.ClientID != "" {
		t.Fatalf("the refused admission is on disk: %+v", got)
	}
	if err := set(); err != nil {
		t.Fatal(err)
	}
	got := listOf(t, f).Homes[home]
	var cert struct {
		ExpiresAt int `json:"expires_at"`
	}
	if got.ClientID != "admitted" || json.Unmarshal(got.Certificate, &cert) != nil || cert.ExpiresAt != 100 {
		t.Fatalf("the retry saved %+v", got)
	}
}
