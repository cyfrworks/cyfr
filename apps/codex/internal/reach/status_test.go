// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// snapshot is every file under .cyfr/ and .env, for a check that nothing
// changed.
func (h *testHome) snapshot() map[string]string {
	out := map[string]string{".env": h.env()}
	filepath.WalkDir(filepath.Join(h.dir, stateDir), func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			data, _ := os.ReadFile(path)
			out[path] = string(data)
		}
		return nil
	})
	return out
}

// Status reads while another command holds the lock, takes none, writes
// nothing and runs no docker command that changes anything; it shows the
// head, its words, the containers, the unfinished operation, the newest
// receipt, and the proxy's health.
func TestStatusTakesNoLockAndChangesNothing(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	h.toTailnet(1, testKey, false)
	before := h.snapshot()
	calls := len(h.fake.calls())
	reader, err := Open(h.dir, h.fake)
	if err != nil {
		t.Fatal(err)
	}
	s, err := reader.Status(bg)
	if err != nil {
		t.Fatal(err)
	}
	if s.HeadErr != nil || s.Head.Mode != ModeTailnet || s.Words.Address != "https://cyfr.tail1234.ts.net" {
		t.Errorf("status shows %+v (%v)", s.Head, s.HeadErr)
	}
	if s.Last == nil || s.Last.Op != "switch" || s.Unfinished != nil {
		t.Errorf("status shows last %+v, unfinished %+v", s.Last, s.Unfinished)
	}
	if !slices.ContainsFunc(s.Containers, func(c Container) bool { return c.Service == "tailscale" && c.State == "running" }) {
		t.Errorf("status shows %v", s.Containers)
	}
	for _, want := range []string{"Tailscale: connected as cyfr.tail1234.ts.net (node n0001CNTRL), the machine .env names", "HTTPS certificates: on", "Serve: open", "Certificate: "} {
		if !slices.ContainsFunc(s.Health, func(l string) bool { return strings.HasPrefix(l, want) }) {
			t.Errorf("health lacks %q: %v", want, s.Health)
		}
	}
	if after := h.snapshot(); !mapsEqual(before, after) {
		t.Error("status changed a file")
	}
	for _, c := range h.fake.calls()[calls:] {
		if !slices.Contains([]string{"ps", "inspect", "exec"}, c.Args[0]) && !(c.Args[0] == "compose" && slices.Contains(c.Args, "config")) {
			t.Errorf("status ran %s", c)
		}
	}
	if reader.lockFile() != nil {
		t.Error("status took the lock")
	}
	if _, _, err := reader.Receipt("../../.env"); err == nil {
		t.Error("a receipt is read from a path an id names")
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// The preview shows both complete heads, their digests and words, and
// lists what stops working only when the address changes.
func TestPreviewShowsBothHeadsAndTheAddressChange(t *testing.T) {
	h := newHome(t)
	p := h.preview(publicTarget, "")
	if p.Old.Mode != ModeLocal || p.New.Host != "home.example.com" || p.OldDigest != h.head().Digest() || p.NewDigest != p.New.Digest() {
		t.Errorf("preview %+v", p)
	}
	if p.OldWords.Who != "only this computer" || p.NewWords.Ports != "80 and 443" || p.NewWords.Address != "https://home.example.com" {
		t.Errorf("words %+v → %+v", p.OldWords, p.NewWords)
	}
	if len(p.AddressChanges) != 4 || !strings.HasPrefix(p.AddressChanges[0], "Passkeys made at the old address stop working") {
		t.Errorf("address changes %v", p.AddressChanges)
	}
	if _, err := h.e.Switch(bg, h.request(id(1), publicTarget, "")); err != nil {
		t.Fatal(err)
	}
	email := h.preview(Target{Mode: ModePublic, Domain: "home.example.com", ACMEEmail: "ops@example.com"}, "")
	if len(email.AddressChanges) != 0 || email.OldWords.CertificateEmail != "none" || email.NewWords.CertificateEmail != "ops@example.com" {
		t.Errorf("an email-only change previews %+v", email)
	}
}

// Receipts are kept at least 24 hours and at least the newest 256: a
// receipt goes only when it is both older and outside the newest 256.
func TestReceiptRetentionKeepsBothMinimums(t *testing.T) {
	h := newHome(t)
	now := h.clock.Now()
	write := func(n int, at time.Time) {
		h.e.writeReceipt(Receipt{RequestID: id(n), Op: "switch", State: "completed", At: at})
	}
	for n := range 280 {
		write(n, now.Add(-25*time.Hour-time.Duration(n)*time.Minute))
	}
	for n := range 20 {
		write(1000+n, now.Add(-time.Duration(n)*time.Minute))
	}
	h.e.prune()
	for n := range 280 {
		_, ok, _ := h.e.readReceipt(id(n))
		if want := n < 236; ok != want {
			t.Errorf("old receipt %d kept %v, want %v", n, ok, want)
		}
	}
	for n := range 20 {
		if _, ok, _ := h.e.readReceipt(id(1000 + n)); !ok {
			t.Errorf("a receipt %d minutes old was pruned", n)
		}
	}

	// All within the day: none goes, however many.
	h2 := newHome(t)
	for n := range 300 {
		h2.e.writeReceipt(Receipt{RequestID: id(n), Op: "switch", State: "completed", At: h2.clock.Now().Add(-time.Duration(n) * time.Minute)})
	}
	h2.e.prune()
	names, _ := readDirNames(filepath.Join(h2.dir, stateDir, receiptsDir))
	if len(names) != 300 {
		t.Errorf("%d of 300 receipts within the day are kept", len(names))
	}
}

// No error, receipt or state file carries a .env value from what docker
// wrote: every diagnosis names what failed, never the text docker quoted.
func TestDockerDiagnosticsCarryNoEnvValue(t *testing.T) {
	const secret = "sentinel-secret-from-env"
	h := newHome(t)
	h.fake.startStack(t, h.head())
	writeFile(t, h.e.envPath(), []byte(h.env()+"DATABASE_URL=postgres://alice:"+secret+"@db/cyfr\n"))
	// Docker's diagnostic as compose writes it, then one no form names.
	stderr := "failed to read .env: line 7: unterminated quoted value \"postgres://alice:" + secret + "@db/cyfr\n'services[cyfr].x' parsing \"" + secret + "\": invalid syntax\n"
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		return &fakeAnswer{Stderr: stderr, Code: 1}
	}
	var texts []string
	note := func(rc Receipt, err error) {
		if err != nil {
			texts = append(texts, err.Error())
			if r, ok := err.(*Refusal); ok {
				texts = append(texts, r.Message())
			}
		}
		texts = append(texts, fmt.Sprintf("%+v", rc))
	}
	texts = append(texts, fmt.Sprint(h.e.CheckStack(bg)))
	note(h.e.Start(bg, "up"))
	note(h.e.Switch(bg, h.request(id(1), publicTarget, "")))
	note(h.e.Join(bg, JoinRequest{ID: id(2)}))
	note(h.e.Stop(bg, "down", true))
	s, err := h.e.Status(bg)
	texts = append(texts, fmt.Sprintf("%+v %v", s, err))
	_, err = h.e.ComposeArgs(bg, h.head(), "ps")
	texts = append(texts, fmt.Sprint(err))
	stderr = "error: the daemon could not use " + secret + "\n"
	texts = append(texts, fmt.Sprint(h.e.CheckStack(bg)))
	note(h.e.Start(bg, "up"))
	note(h.e.Switch(bg, h.request(id(3), publicTarget, "")))
	for path, data := range h.snapshot() {
		if path != ".env" {
			texts = append(texts, data)
		}
	}
	// A flattened configuration holds .env's values; one compose wrote
	// that does not read is said by its line. YAML quotes a short value
	// whole.
	const short = "s3cr3tVal"
	h.fake.hook = func(_ context.Context, c *fakeCall) *fakeAnswer {
		if c.Args[0] == "compose" && slices.Contains(c.Args, "config") {
			return &fakeAnswer{Stdout: "services:\n  cyfr:\n    environment: " + short + "\n"}
		}
		return nil
	}
	texts = append(texts, fmt.Sprint(h.e.CheckStack(bg)))
	for _, text := range texts {
		if strings.Contains(text, secret) || strings.Contains(text, short) {
			t.Errorf("a diagnosis carries the .env value: %s", text)
		}
	}
}
