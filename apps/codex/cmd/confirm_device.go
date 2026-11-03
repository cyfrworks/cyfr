// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/shell"
)

// confirmOutcome is how a confirmation offered on this command line ended.
type confirmOutcome int

const (
	// confirmedHere: the device's proof confirmed it; the call repeats.
	confirmedHere confirmOutcome = iota
	// confirmedElsewhere: the person pressed Enter, having confirmed it
	// on another device; the call repeats.
	confirmedElsewhere
	// failedHere: the device drew it, and its confirmation failed (a
	// wrong PIN, a change that moved); the call repeats and asks again.
	failedHere
	// notHere: the device could not draw it (its sentence says why); the
	// wait goes on as without a device.
	notHere
)

// deviceConfirmer offers to confirm the pending change ref on this
// command line's own device, asking on c, in C4's order: the home's
// preview drawn first, then the PIN or passphrase, asked once, which opens
// the key afresh to sign that change's challenge. An error is a failed
// confirmation (failedHere), its text the sentence, or why the device
// could not draw it (notHere).
type deviceConfirmer func(ctx context.Context, ref string, c *console) (confirmOutcome, error)

// confirmOnDevice is the confirmer of this command line's device paired
// with the home at address, or nil when it holds none there.
var confirmOnDevice = func(address string) deviceConfirmer { return confirmOnDeviceBy(address, "") }

// confirmOnDeviceBy is confirmOnDevice reading the change through session,
// or through cyfr login's shell's when session is empty.
func confirmOnDeviceBy(address, session string) deviceConfirmer {
	path, err := deviceRecord(address)
	if err != nil {
		return nil
	}
	rec, err := holder.Load(path)
	if err != nil || len(rec.Certificate) == 0 || !sameAddress(rec.Home, deviceHome(address)) {
		return nil
	}
	return func(ctx context.Context, ref string, c *console) (confirmOutcome, error) {
		dev, err := openDevice(deviceOptions{address: address, session: session})
		if err != nil {
			return notHere, err
		}
		defer dev.Lock("")
		dev.Draw(ctx, ref)
		v := dev.View()
		if v.Page != shell.PageConfirm || v.Confirm == nil {
			return notHere, errors.New(v.Notice)
		}
		fmt.Fprintf(c.out, "CYFR asks to confirm %s:\n", v.Confirm.Operation)
		for _, f := range shell.PreviewFields(v.Confirm.Preview) {
			fmt.Fprintf(c.out, "  %s: %s\n", f[0], f[1])
		}
		secret, err := c.secret(ctx, "  To confirm it here, type this command line's PIN or passphrase; press Enter once you confirmed it elsewhere: ")
		if err != nil {
			return notHere, err
		}
		if len(secret) == 0 {
			dev.Decide(ctx, ref, false, nil)
			return confirmedElsewhere, nil
		}
		dev.Decide(ctx, ref, true, secret)
		if notice := dev.View().Notice; !strings.HasPrefix(notice, "Confirmed") {
			return failedHere, errors.New(notice)
		}
		return confirmedHere, nil
	}
}

// sessionDevice is this command line's device as cyfr login's shell
// confirms with it: the change is read from the home through the shell's
// session (confirmation.pending, which the session reads as the person
// does) and drawn, and once the person typed the secret after it, the
// device's key, opened afresh, confirms it on a channel of its own
// (shell.Shell.ConfirmDrawn). Everything else is the shell's.
type sessionDevice struct {
	*shell.Shell
	// session reads the change: the shell's session, or nil outside
	// cyfr login's shell, where nothing is drawn.
	session *mcp.Client
	drawn   *shell.PendingConfirm
	notice  string
}

// Draw reads the change ref names through the session and keeps it drawn.
func (d *sessionDevice) Draw(ctx context.Context, ref string) {
	d.drawn, d.notice = nil, ""
	if d.session == nil {
		d.notice = "This command line confirms a change in the shell cyfr login started."
		return
	}
	answer, err := d.session.CallTool(ctx, ops.Confirmation, ops.ConfirmationPendingArgs{Request: ops.Value(ref)})
	if err != nil {
		d.notice = "CYFR could not show the change here: " + err.Error()
		return
	}
	raw, _ := json.Marshal(answer["confirmations"])
	var held []struct {
		Ref       string         `json:"ref"`
		Operation string         `json:"operation"`
		Preview   map[string]any `json:"preview"`
		Asker     map[string]any `json:"asker"`
	}
	if json.Unmarshal(raw, &held) != nil || len(held) != 1 || held[0].Ref != ref {
		d.notice = "CYFR holds no open confirmation by that name."
		return
	}
	d.drawn = &shell.PendingConfirm{Ref: ref, Operation: held[0].Operation, Preview: held[0].Preview, Asker: held[0].Asker}
}

// View is the drawn change while one is, else the shell's page.
func (d *sessionDevice) View() shell.View {
	if d.drawn != nil {
		return shell.View{Page: shell.PageConfirm, Confirm: d.drawn}
	}
	v := d.Shell.View()
	if d.notice != "" {
		v.Notice = d.notice
	}
	return v
}

// Decide confirms the drawn change with secret (ConfirmDrawn), or leaves
// it unsigned.
func (d *sessionDevice) Decide(ctx context.Context, ref string, confirm bool, secret []byte) {
	drawn := d.drawn
	d.drawn = nil
	if !confirm || drawn == nil || drawn.Ref != ref {
		clear(secret)
		d.notice = "Nothing was confirmed."
		return
	}
	d.Shell.ConfirmDrawn(ctx, *drawn, secret)
	d.notice = d.Shell.View().Notice
}
