// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/shell"
)

func TestReviewConfirmationAsksForUnlockAfterShowingThePreview(t *testing.T) {
	withContexts(t, "home", map[string]*config.Context{"home": {URL: "https://alice.example"}})
	pairedRecord(t, "https://alice.example")
	const preview = "SERVER-APPROVED-KEY-DIGEST"
	dev := newFakeDevice(shell.View{Page: shell.PageLocked}, func(call string, d *fakeDevice) {
		switch call {
		case "unlock":
			d.set(shell.View{Page: shell.PageUnlocked})
		case "draw":
			d.set(shell.View{Page: shell.PageConfirm, Confirm: &shell.PendingConfirm{Operation: "pairing.begin", Preview: map[string]any{"key_digest": preview}}})
		case "decide":
			d.set(shell.View{Page: shell.PageUnlocked, Notice: "Confirmed on this command line."})
		}
	})
	previous := openDevice
	openDevice = func(deviceOptions) (device, error) { return dev, nil }
	t.Cleanup(func() { openDevice = previous })
	out := &bytes.Buffer{}
	unlockAfterPreview := false
	reads := 0
	previousOutput := 0
	lines := func() <-chan []byte {
		reads++
		if reads > 4 {
			t.Fatal("confirmation asked too many questions")
		}
		text := out.String()
		prompt := text[previousOutput:]
		previousOutput = len(text)
		answer := "y"
		if strings.Contains(strings.ToLower(prompt), "pin") || strings.Contains(strings.ToLower(prompt), "passphrase") {
			answer = passphrase
			if strings.Contains(text, preview) {
				unlockAfterPreview = true
			}
		}
		ch := make(chan []byte, 1)
		ch <- []byte(answer)
		return ch
	}
	w := &confirmationWait{out: out, interactive: func() bool { return true }, now: time.Now, lines: lines, address: "https://alice.example", device: confirmOnDevice}
	pending := &mcp.ConsentError{Tag: "confirmation_required", Payload: map[string]any{"id": "cfm_secret-id", "operation": "pairing.begin"}}
	if err := w.wait(t.Context(), pending, false); err != nil {
		t.Fatal(err)
	}
	if !unlockAfterPreview {
		t.Fatalf("confirmation reused an unlock entered before the preview; terminal dialogue:\n%s", out)
	}
}
