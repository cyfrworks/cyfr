// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/shell"
)

func TestConfirmationWait_ShowsSuccessfulConfirmationResetWarning(t *testing.T) {
	const home = "https://alice.example"
	const warning = "CYFR did not take this unlock's reset, so the tries it counted stay counted until an unlock it takes."
	withContexts(t, "home", map[string]*config.Context{"home": {URL: home}})
	pairedRecord(t, home)
	dev := newFakeDevice(shell.View{Page: shell.PageLocked}, func(call string, d *fakeDevice) {
		switch call {
		case "draw":
			d.set(shell.View{Page: shell.PageConfirm, Confirm: &shell.PendingConfirm{
				Ref: "cnr_1", Operation: "pairing.begin", Preview: map[string]any{"key_digest": "D1"}}})
		case "decide":
			d.set(shell.View{Page: shell.PageLocked, Notice: "Confirmed on this command line. " + warning})
		}
	})
	previous := openDevice
	openDevice = func(deviceOptions) (device, error) { return dev, nil }
	t.Cleanup(func() { openDevice = previous })
	c, out := typed("123456")
	w := &confirmationWait{out: out, interactive: func() bool { return true }, now: time.Now,
		lines: c.lines, address: home, device: confirmOnDevice}
	pending := &mcp.ConsentError{Tag: "confirmation_required", Payload: map[string]any{"id": "cfm_secret-id", "operation": "pairing.begin"}}
	if err := w.wait(t.Context(), pending, false); err != nil {
		t.Fatalf("a confirmed change with a reset warning was not treated as success: %v", err)
	}
	if !strings.Contains(out.String(), warning) {
		t.Fatalf("the terminal discarded the successful confirmation's reset warning: %q", out.String())
	}
}
