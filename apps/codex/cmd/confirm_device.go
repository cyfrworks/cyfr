// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/shell"
)

// deviceConfirmer confirms the pending change ref on this command line's
// own device, with the PIN or passphrase the person typed (secret, which
// it erases), asking on c: confirmed, declined (false, nil), or why it
// could not (an error whose text is the sentence).
type deviceConfirmer func(ctx context.Context, ref string, secret []byte, c *console) (bool, error)

// confirmOnDevice is the confirmer of this command line's device paired
// with the home at address, or nil when it holds none there.
//
// The secret opens the key afresh and proves this device on a channel of
// its own (shell.Shell.Unlock), whatever session another shell of this
// command line holds; the home's preview and challenge for ref are read
// over that channel and drawn here; the person says yes; the key is
// opened afresh once more by the same secret and signs that challenge
// alone (shell.Shell.Decide), and the channel closes. Nothing a page or
// the asking command supplied is signed.
var confirmOnDevice = func(address string) deviceConfirmer {
	path, err := deviceRecord(address)
	if err != nil {
		return nil
	}
	rec, err := holder.Load(path)
	if err != nil || len(rec.Certificate) == 0 || !sameAddress(rec.Home, address) {
		return nil
	}
	return func(ctx context.Context, ref string, secret []byte, c *console) (bool, error) {
		again := bytes.Clone(secret)
		defer clear(again)
		sh, err := openDevice(deviceOptions{address: address})
		if err != nil {
			clear(secret)
			return false, err
		}
		sh.Unlock(ctx, secret)
		defer sh.Lock("")
		if !sh.Unlocked() {
			return false, errors.New(sh.View().Notice)
		}
		sh.Draw(ctx, ref)
		v := sh.View()
		if v.Page != shell.PageConfirm {
			return false, errors.New(v.Notice)
		}
		fmt.Fprintf(c.out, "CYFR asks to confirm %s:\n", v.Confirm.Operation)
		for _, f := range shell.PreviewFields(v.Confirm.Preview) {
			fmt.Fprintf(c.out, "  %s: %s\n", f[0], f[1])
		}
		answer, err := c.line(ctx, "Confirm it on this command line? [y/N] ")
		if err != nil {
			return false, err
		}
		if yes := strings.ToLower(strings.TrimSpace(string(answer))); yes != "y" && yes != "yes" {
			sh.Decide(ctx, ref, false, nil)
			return false, nil
		}
		sh.Decide(ctx, ref, true, again)
		if v := sh.View(); !strings.HasPrefix(v.Notice, "Confirmed") {
			return false, errors.New(v.Notice)
		}
		return true, nil
	}
}
