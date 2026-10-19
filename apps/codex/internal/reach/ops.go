// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"errors"
)

func (e *Engine) doStart(ctx context.Context, cause string) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	r := Receipt{Op: "start", State: "completed"}
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
	s := e.startHead(context.WithoutCancel(ctx), h, nil, true)
	r.FinalHead = &h
	r.At = e.now()
	switch {
	case s.ok:
		r.Outcome = "ok"
		return r, nil
	case s.mismatch != nil:
		r.Outcome = "ok"
		r.Code, r.Payload = s.mismatch.Code, s.mismatch.Payload
		return r, s.mismatch
	}
	r.Outcome = "failed"
	return r, errors.New("cyfr " + cause + ": the stack did not start: " + s.why)
}

// unfinished blocks Start while the journal holds an operation Resume
// could not finish: only a reconciliation makes it terminal.
func (e *Engine) unfinished() (Receipt, bool, error) {
	j, err := e.readJournal()
	if err != nil {
		return Receipt{}, true, err
	}
	if j == nil || j.Op == "join" && j.Join != nil && j.Join.State == "waiting" {
		return Receipt{}, false, nil
	}
	rc := j.receipt()
	if rc.Code == "" {
		rc.Code, rc.Payload = "reach_outcome_unknown", map[string]string{"reason": "the " + j.Op + " " + j.RequestID + " is unfinished"}
	}
	r, err := answer(rc)
	return r, true, err
}

func (e *Engine) doStop(ctx context.Context, cause string, all bool) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	ctx = context.WithoutCancel(ctx)
	r := Receipt{Op: "stop", State: "completed", Outcome: "ok"}
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
	if headErr == nil {
		if names, err := e.servicesOf(ctx, h, nil); err == nil {
			services = union(services, names)
		}
	}
	if all {
		services = nil
		if headErr == nil {
			// compose down removes the project's networks as well;
			// whatever it leaves running the sweep below stops.
			if args, err := e.composeArgsFor(ctx, h, "down", "--remove-orphans"); err == nil {
				e.docker.Run(ctx, Call{Args: args, Deadline: StopDeadline})
			}
		}
	}
	s := e.stopAndVerify(ctx, services)
	r.At = e.now()
	if !s.ok {
		r.State, r.Phase, r.Outcome = "accepted", "uncertain", ""
		r.Code, r.Payload, r.Observed = "reach_uncertain", map[string]string{"observed": observedText(s.observed)}, s.observed
		return answer(r)
	}
	return r, nil
}
