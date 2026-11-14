// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package account

import (
	"context"
	"errors"
	"fmt"
)

// ErrListed is a key the account lists already.
var ErrListed = errors.New("listed")

// ErrNotListed is a signer the account does not list (any more).
var ErrNotListed = errors.New("not listed")

// ErrUnanswered is an add_key sent whose answer did not arrive, even once
// sent again: the directory may hold it. It is also ErrUnreachable.
var ErrUnanswered = errors.New("the account's answer did not arrive")

// Approve adds key, a device key or a passkey as ReadKey reads one, to the
// account identifier names at d, signed by the listed device key signer
// (its public half) through sign: add_key after the log's head, appended.
// A lost answer sends the same bytes again once, and exists is success;
// a second lost answer is ErrUnanswered, since the entry may have landed.
// A head that moved meanwhile is read again and the entry composed after
// it, once. Any other error is answered before an entry was sent, or is
// the directory's refusal of it: nothing was added.
func Approve(ctx context.Context, d Directory, identifier string, signer []byte, sign func([]byte) []byte, key Key, now int64) error {
	for range 2 {
		state, err := d.Read(ctx, identifier)
		if err != nil {
			return err
		}
		if _, listed := state.Key(key.Kid); listed {
			return ErrListed
		}
		if k, listed := state.Key(Kid(signer)); !listed || k.Alg != "ed25519" {
			return ErrNotListed
		}
		entry, err := SignedBy(Next(state, "add_key", map[string]any{"key": key.Map()}, now, Kid(signer)), sign)
		if err != nil {
			return err
		}
		_, err = d.Append(ctx, identifier, entry)
		if errors.Is(err, ErrUnreachable) {
			_, err = d.Append(ctx, identifier, entry)
		}
		if errors.Is(err, ErrUnreachable) {
			return fmt.Errorf("%w: %w", ErrUnanswered, err)
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
	return errors.New("the account changed twice while this key was added: try again")
}
