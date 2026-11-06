// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"context"
	"errors"
)

// ErrListed is a device key the account lists already.
var ErrListed = errors.New("listed")

// ErrNotListed is a signer the account does not list (any more).
var ErrNotListed = errors.New("not listed")

// Approve adds the device key pub to the account identifier names at d,
// signed by the listed device key signer (its public half) through sign:
// add_key after the log's head, appended. A lost answer sends the same
// bytes again once, and exists is success; a head that moved meanwhile is
// read again and the entry composed after it, once.
func Approve(ctx context.Context, d Directory, identifier string, signer []byte, sign func([]byte) []byte, pub []byte, now int64) error {
	for range 2 {
		state, err := d.Read(ctx, identifier)
		if err != nil {
			return err
		}
		if _, listed := state.Key(Kid(pub)); listed {
			return ErrListed
		}
		if k, listed := state.Key(Kid(signer)); !listed || k.Alg != "ed25519" {
			return ErrNotListed
		}
		entry, err := SignedBy(Next(state, "add_key", map[string]any{"key": DeviceKey(pub).Map()}, now, Kid(signer)), sign)
		if err != nil {
			return err
		}
		_, err = d.Append(ctx, identifier, entry)
		if errors.Is(err, ErrUnreachable) {
			_, err = d.Append(ctx, identifier, entry)
		}
		var ref *DirectoryRefusal
		switch {
		case errors.As(err, &ref) && ref.Code == "stale_head":
			continue
		case errors.As(err, &ref) && ref.Code == "duplicate_key":
			return ErrListed
		}
		return err
	}
	return errors.New("the account changed twice while this device was added: try again")
}
