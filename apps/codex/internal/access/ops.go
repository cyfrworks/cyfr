// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"errors"
	"fmt"
	"time"
)

func (e *Engine) doStart(ctx context.Context, cause string, health time.Duration) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	// The start a hold owes is this one: the hold closes once it has
	// answered, whatever it answered, and stays for recovery only if the
	// process dies inside it.
	defer e.closeHold()
	r := Receipt{Op: "start", State: "completed"}
	if _, err := e.readEnv(); err != nil {
		return Receipt{}, err
	}
	if rc, blocked, err := e.unfinished(); blocked {
		return rc, err
	}
	h, err := e.envHead()
	if err != nil {
		var ref *Refusal
		if errors.As(err, &ref) {
			r.State, r.Code, r.Payload = "rejected", ref.Code, ref.Payload
			return r, ref
		}
		return Receipt{}, err
	}
	defer e.dropFiles(nil, false)
	s := e.startHead(context.WithoutCancel(ctx), h, nil, true, health)
	r.FinalHead = &h
	r.At = e.now()
	switch {
	case s.ok:
		r.Outcome = "ok"
		return r, nil
	case s.local != nil:
		r.Outcome = "started_local"
		r.Code, r.Payload = s.local.Code, s.local.Payload
		return r, s.local
	case s.refused != nil:
		r.State, r.Code, r.Payload, r.FinalHead = "rejected", s.refused.Code, s.refused.Payload, nil
		return r, s.refused
	}
	r.Outcome = "failed"
	return r, errors.New("cyfr " + cause + ": the stack did not start: " + s.why)
}

// unfinished blocks Start while the journal holds an operation Resume
// could not finish, since only a reconciliation makes it terminal, and
// while a join waits for its approval: its container runs on the state
// volume the tailscale service would start on. update and restore cancel
// the waiting join first.
func (e *Engine) unfinished() (Receipt, bool, error) {
	j, err := e.readJournal()
	if err != nil {
		return Receipt{}, true, err
	}
	if j == nil {
		return Receipt{}, false, nil
	}
	if j.Op == holdOp {
		return Receipt{}, false, nil
	}
	if j.Op == "join" && j.Join != nil && j.Join.State == "waiting" {
		ref := joinBusy(j.Join.JoinID, j.Join.Deadline)
		return Receipt{Op: "start", State: "rejected", Code: ref.Code, Payload: ref.Payload, At: e.now()}, true, ref
	}
	rc := j.receipt()
	if rc.Code == "" {
		rc.Code, rc.Payload = "access_outcome_unknown", map[string]string{"reason": "the " + j.Op + " " + j.RequestID + " is unfinished"}
	}
	r, err := answer(rc)
	return r, true, err
}

// holdOp is the journal's kind for a stop that owes a start (Hold): its
// Cause names the command, so a new command holds the stack with no change
// here.
const holdOp = "hold"

func (e *Engine) hold(cause string) error {
	if err := e.requireLock(); err != nil {
		return err
	}
	j, err := e.readJournal()
	if err != nil {
		return err
	}
	if j != nil {
		return fmt.Errorf("access: the %s %s is unfinished", j.Op, j.RequestID)
	}
	h := &journal{Op: holdOp, RequestID: newRequestID(), RequestDigest: requestDigest(map[string]any{"op": holdOp, "cause": cause}), Cause: cause}
	return e.setPhase(h, "held")
}

// closeHold removes a hold from the journal, no receipt written: the
// command that held the stack reports its own start, and a removal that
// fails leaves recovery a start that is safe to run again.
func (e *Engine) closeHold() error {
	if err := e.requireLock(); err != nil {
		return err
	}
	j, err := e.readJournal()
	if err != nil || j == nil || j.Op != holdOp {
		return err
	}
	return e.removeDurable(e.path(journalFile))
}

func (e *Engine) doStop(ctx context.Context, cause string, all bool) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	ctx = context.WithoutCancel(ctx)
	r := Receipt{Op: "stop", State: "completed", Outcome: "ok"}
	if err := e.closeServe(); err != nil {
		return Receipt{}, err
	}
	if err := e.cancelWaitingJoin(ctx); err != nil {
		return Receipt{}, err
	}
	defer e.dropFiles(nil, false)
	services := []string{cyfrService}
	j, _ := e.readJournal()
	if j != nil {
		services = union(services, j.Services)
	}
	h, headErr := e.envHead()
	if names, err := e.everyAccessService(ctx); err == nil {
		services = union(services, names)
	}
	// compose reads COMPOSE_* from .env and cannot name the access
	// services under one that sets any: every container goes.
	if _, err := e.readEnv(); all || err != nil {
		services = nil
		if headErr == nil && all {
			// Compose stops services in dependency order; the sweep removes
			// every project container, including orphans, and keeps networks.
			// A release that changes a network's subnet needs its own teardown.
			if args, err := e.composeArgsFor(ctx, h, "stop"); err == nil {
				e.docker.Run(ctx, Call{Args: args, Deadline: StopDeadline})
			}
		}
	}
	s := e.stopAndVerify(ctx, services)
	r.At = e.now()
	if !s.ok {
		r.State, r.Phase, r.Outcome = "accepted", "uncertain", ""
		r.Code, r.Payload, r.Observed = "access_uncertain", map[string]string{"observed": observedText(s.observed)}, s.observed
		return answer(r)
	}
	return r, nil
}
