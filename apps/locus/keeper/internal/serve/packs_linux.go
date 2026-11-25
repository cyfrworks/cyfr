// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package serve

import (
	"errors"

	"github.com/cyfr/locus/keeper/internal/packview"
	"github.com/cyfr/locus/keeper/internal/protocol"
)

// handlePacks answers a packs_hold or a packs_put of the kept role, which
// alone keeps homes and so packs: another role's, a keeper given no
// --kept-homes, and a put whose store's folder cannot be made, are refused
// as CodeUnavailable, as is a put begun while one of its athanor, or
// packview.MaxPuts, are under way. A put is its client's: the client's end
// drops every put it had in progress and refuses every later one
// (endClient).
func (s *server) handlePacks(c *client, req *protocol.Request) {
	if s.keepsNoHomes(c, req) {
		return
	}
	if s.clientEnded(c) {
		return
	}
	switch req.Type {
	case protocol.TypePacksHold:
		held, err := s.packs.Hold(req.Athanor, req.Lifetime, req.Digest)
		if err != nil {
			s.log.Error("packs_hold %s: %v", req.ID, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
			return
		}
		state := protocol.PacksMissing
		if held {
			state = protocol.PacksHeld
		}
		s.send(c, protocol.NewPacksReply(req.ID, state))
	case protocol.TypePacksPut:
		state, err := s.packs.Put(&c.packs, req.Athanor, req.Lifetime, req.Digest, *req.Seq, *req.Last, req.Part())
		switch {
		case errors.Is(err, packview.ErrNoStore):
			s.log.Error("packs_put %s refused: %v", req.ID, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
		case errors.Is(err, packview.ErrBusy):
			s.log.Warn("packs_put %s refused: %v", req.ID, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeUnavailable))
		case errors.Is(err, packview.ErrRefused):
			s.log.Warn("packs_put %s refused at part %d", req.ID, *req.Seq)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodePacksRefused))
		case err != nil:
			s.log.Error("packs_put %s: %v", req.ID, err)
			s.send(c, protocol.NewError(req.ID, "", protocol.CodeInternal))
		default:
			s.send(c, protocol.NewPacksReply(req.ID, state))
		}
	}
}
