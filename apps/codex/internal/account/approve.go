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

// ErrUnanswered is an add_key sent whose answer did not arrive, and whose
// sending again answered nothing that shows whether the log holds it: the
// directory may hold it. It is also ErrUnreachable.
var ErrUnanswered = errors.New("the account's answer did not arrive")

// Approve adds key, a device key or a passkey as ReadKey reads one, to the
// account identifier names at d, signed by the listed device key signer
// (its public half) through sign: add_key after the log's head, appended.
// A lost answer sends the same bytes again once. Only an answer to that
// second send that shows the entry's state settles it: accepted or exists
// (the log holds the entry), duplicate_key (the log lists the key), or
// stale_head (the head moved, so the log is read again and its keys say
// whether the first send landed). Any other answer to it, a rate limit,
// a server error or another refusal, may come before the directory looked
// at the log, so the entry may have landed: ErrUnanswered. A head that
// moved meanwhile is read again and the entry composed after it, once.
// Any other error is answered before an entry was sent, or is the
// directory's refusal of a first send: nothing was added.
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
		var ref *DirectoryRefusal
		if errors.Is(err, ErrUnreachable) {
			_, err = d.Append(ctx, identifier, entry)
			shows := err == nil || (errors.As(err, &ref) && (ref.Code == "duplicate_key" || ref.Code == "stale_head"))
			if !shows {
				return fmt.Errorf("%w: %w (%v)", ErrUnanswered, ErrUnreachable, err)
			}
		}
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
