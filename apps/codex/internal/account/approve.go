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

// ErrUnanswered is an add_key sent whose answer did not arrive, and that
// nothing after it showed the log to hold or not to hold: the directory
// may hold it. It is also ErrUnreachable.
var ErrUnanswered = errors.New("the account's answer did not arrive")

// Approve adds key, a device key or a passkey as ReadKey reads one, to the
// account identifier names at d, signed by the listed device key signer
// (its public half) through sign: add_key after the log's head, appended.
//
// From the moment an add_key is sent and its answer lost, the entry may
// be in the log, and only an answer that shows the entry's state settles
// that: the same bytes sent again accepted or exists (the log holds it),
// duplicate_key (the log lists the key), or a log read that succeeds,
// which says whether the key is listed. A stale_head proves nothing by
// itself and is followed by that read. Every other way out while it is
// unsettled, an error, a refusal, a failed read, a timeout or a cancelled
// context, is ErrUnanswered. A lost answer sends the same bytes again
// once; a head that moved is read again and the entry composed after it,
// once. Otherwise an error means nothing was added.
func Approve(ctx context.Context, d Directory, identifier string, signer []byte, sign func([]byte) []byte, key Key, now int64) (answer error) {
	// unsettled is set where a sent add_key goes unanswered, cleared only by
	// an answer that shows the entry's state, and read here, at every return.
	unsettled := false
	defer func() {
		if unsettled {
			answer = fmt.Errorf("%w: %w (%v)", ErrUnanswered, ErrUnreachable, answer)
		}
	}()
	for range 2 {
		state, err := d.Read(ctx, identifier)
		if err != nil {
			return err
		}
		unsettled = false
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
			unsettled = true
			_, err = d.Append(ctx, identifier, entry)
		}
		var ref *DirectoryRefusal
		switch {
		case err == nil:
			unsettled = false
			return nil
		case errors.As(err, &ref) && ref.Code == "duplicate_key":
			unsettled = false
			return ErrListed
		case errors.As(err, &ref) && ref.Code == "stale_head":
			continue
		}
		return err
	}
	return errors.New("the account changed twice while this key was added: try again")
}
