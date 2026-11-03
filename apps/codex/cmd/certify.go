// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/ops"
	"github.com/cyfr/codex/internal/shell"
)

// certifyAtHome is how cyfr login obtains, at the person's own CYFR, the
// certificate that a CYFR keeping none of their keys asks for, in this
// terminal and never through a browser. The person types their own CYFR's
// address (its directory names no one's CYFR), offered the one that
// certified this command line before on a re-certification. This command
// line must already be a device of theirs there: its own record for that
// CYFR is unlocked afresh by its PIN or passphrase, and person.certify,
// asked through that unlock's session, is confirmed like any change: its
// preview drawn here, then the secret asked once, or on another device of
// theirs there. The session lives in this process alone and ends, with the
// key, before the certificate is used.
func certifyAtHome(c *console) shell.CertifyCall {
	return func(ctx context.Context, asked shell.Certification) (shell.Certified, error) {
		fmt.Fprintf(c.out, "\nYour identity is kept by your own CYFR, not %s: your CYFR certifies this command line for it.\n", asked.Audience)
		address, err := askOwnHome(ctx, c, asked)
		if err != nil {
			return shell.Certified{}, err
		}
		home := deviceHome(address)
		path, err := deviceRecord(address)
		if err != nil {
			return shell.Certified{}, err
		}
		if rec, err := holder.Load(path); err != nil || len(rec.Certificate) == 0 || !sameAddress(rec.Home, home) {
			return shell.Certified{}, fmt.Errorf("This command line is not a device of yours at %s yet. Pair it there first with cyfr login --url %s, then run cyfr login again.", address, address)
		}
		dev, err := openDevice(deviceOptions{address: address})
		if err != nil {
			return shell.Certified{}, err
		}
		defer dev.Lock("")
		v := dev.View()
		if v.Page != shell.PageLocked {
			return shell.Certified{}, fmt.Errorf("This command line's key for %s is not ready to unlock: run cyfr login --url %s first.", address, address)
		}
		why := "Unlock this command line at " + address + " with its"
		var secret []byte
		if v.Kind == holder.KindChip || v.PIN {
			secret, err = c.secret(ctx, why+" PIN: ")
		} else {
			secret, err = c.secret(ctx, why+" passphrase: ")
		}
		if err != nil {
			return shell.Certified{}, err
		}
		dev.Unlock(ctx, secret)
		if !dev.Unlocked() {
			return shell.Certified{}, errors.New(dev.View().Notice)
		}
		session, err := dev.Session(ctx)
		if err != nil {
			return shell.Certified{}, fmt.Errorf("%s opened no session for this command line: %s", address, shellSentence(err))
		}
		client := mcp.NewClient(address)
		client.SessionID = session
		client.Confirm = (&confirmationWait{
			out:         c.out,
			interactive: func() bool { return true },
			lines:       c.lines,
			now:         time.Now,
			address:     address,
			device:      func(address string) deviceConfirmer { return confirmOnDeviceBy(address, session) },
		}).wait
		answer, err := client.CallTool(ctx, ops.Person, ops.PersonCertifyArgs{DeviceKey: base64.RawURLEncoding.EncodeToString(asked.DeviceKey),
			Audience: asked.Audience, Athanor: asked.Athanor, ClientId: asked.ClientID})
		if err != nil {
			return shell.Certified{}, err
		}
		cert, err := json.Marshal(answer["certificate"])
		if err != nil {
			return shell.Certified{}, err
		}
		return shell.Certified{Issuer: home, Certificate: cert}, nil
	}
}

// askOwnHome asks for the address of the person's own CYFR, once: Enter
// alone takes the one that certified this command line before. An address
// that is not a CYFR's, or is the CYFR asking, is refused.
func askOwnHome(ctx context.Context, c *console, asked shell.Certification) (string, error) {
	question := "Your own CYFR's address: "
	if asked.Issuer != "" {
		question = fmt.Sprintf("Your own CYFR's address (Enter for %s): ", asked.Issuer)
	}
	line, err := c.line(ctx, question)
	if err != nil {
		return "", err
	}
	address := strings.TrimRight(strings.TrimSpace(string(line)), "/")
	if address == "" {
		address = asked.Issuer
	}
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", fmt.Errorf("%q is not a CYFR's address: give its https:// address.", address)
	}
	if sameAddress(deviceHome(address), asked.Audience) {
		return "", fmt.Errorf("%s is the CYFR asking: give the address of the CYFR that keeps your identity.", address)
	}
	return address, nil
}
