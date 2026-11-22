// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/account/accounttest"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/holder/holdertest"
	"github.com/cyfr/codex/internal/shell"
)

// A computer with a usable chip makes the device's key there on its first
// use of the device road, under a six-digit PIN the chip checks, as the
// device's own screen does; one without a chip uses six words.
func TestTheDeviceRoadMakesItsKeyOnTheChipWhereThereIsOne(t *testing.T) {
	tpm := holdertest.New(t)
	t.Cleanup(holder.UseTPM(tpm.Sock()))
	tpm.Start(t)
	accounts := accounttest.New(t)
	dir := t.TempDir()
	a := newApp(t, dir, nil)
	a.directory.Store(accounts.URL())
	a.Shell = func(c *shell.Config) {
		c.Detect = func(string) disk.Report { return disk.Report{Root: disk.Unknown, Data: disk.Unknown} }
	}
	a.post(t, "/bootstrap/connect", map[string]string{"address": "cyfr.example.com"})
	done := a.connect(t, "/bootstrap/approve", map[string]string{"home": "https://cyfr.example.com", "directory": accounts.URL()})
	a.next(t)
	a.ready("https://cyfr.example.com")
	answered(t, done)

	if page := a.get("/").Body.String(); !strings.Contains(page, "Choose a six-digit PIN") || strings.Contains(page, "Show the passphrase") {
		t.Fatalf("a computer with a chip was not asked for a PIN:\n%s", page)
	}
	setup := a.form("/setup", url.Values{"name": {"alice"}, "secret": {"135790"}, "again": {"135790"}})
	if setup.Code != http.StatusOK || proofShape.FindString(setup.Body.String()) == "" {
		t.Fatalf("setup with a PIN answered %d:\n%s", setup.Code, setup.Body)
	}
	raw, err := os.ReadFile(a.Record)
	var rec struct {
		Kind string `json:"kind"`
	}
	if err != nil || json.Unmarshal(raw, &rec) != nil || rec.Kind != string(holder.KindChip) {
		t.Fatalf("the key is not the chip's: %s (%v)", raw, err)
	}
}
