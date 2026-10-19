// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package reach

import (
	"context"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

func (e *Engine) resume(ctx context.Context) ([]Receipt, error) {
	if err := e.requireLock(); err != nil {
		return nil, err
	}
	ctx = context.WithoutCancel(ctx)
	j, err := e.readJournal()
	if err != nil {
		return nil, err
	}
	e.sweepStrays(j)
	if _, err := e.readEnv(); err != nil && j == nil {
		// Nothing to stop: a .env compose would misread is refused
		// before any docker call.
		return nil, err
	}
	var out []Receipt
	if j != nil {
		rc, done, err := e.recoverOp(ctx, j)
		if done || rc.Code != "" {
			out = append(out, rc)
		}
		if err != nil && rc.Code == "" {
			return out, err
		}
	}
	j, _ = e.readJournal()
	if err := e.reapJoins(ctx, j); err != nil {
		return out, err
	}
	e.prune()
	return out, nil
}

// recoverOp finishes the journal's operation. done is false while it is
// still unfinished: uncertain, or a join still waiting.
func (e *Engine) recoverOp(ctx context.Context, j *journal) (Receipt, bool, error) {
	// A receipt already durable means the operation completed: only its
	// journal and files remain to remove, and no effect is replayed.
	if r, ok, err := e.readReceipt(j.RequestID); err == nil && ok && r.RequestDigest == j.RequestDigest {
		if err := e.dropFiles(j.Files, true); err != nil {
			return r, true, err
		}
		return r, true, e.removeDurable(e.path(journalFile))
	}
	switch j.Op {
	case "switch":
		rc, err := e.recoverSwitch(ctx, j)
		return rc, rc.State == "completed", err
	case "join", "cancel":
		return e.recoverJoin(ctx, j)
	}
	return Receipt{}, false, nil
}

// recoverSwitch converges an unfinished switch through stopped: every
// branch first stops and verifies cyfr and both heads' reach services,
// then compares .env with the journal's two heads. The old head: the
// commit did not happen, so the old head starts again if it was running
// (not_applied). The new head: the switch rolls forward from its start.
// Neither, .env having been edited meanwhile: what .env holds starts if
// it validates and the stack was running, and the switch failed
// (reach_env_edited, saying which).
func (e *Engine) recoverSwitch(ctx context.Context, j *journal) (Receipt, error) {
	services := slices.Clone(j.Services)
	for _, name := range j.Files {
		content, err := os.ReadFile(filepath.Join(e.dir, filepath.FromSlash(name)))
		if err != nil {
			continue
		}
		c, err := parseConfig(content)
		if err != nil {
			continue
		}
		for _, h := range []*Head{j.OldHead, j.NewHead} {
			if h != nil && strings.Contains(name, strings.TrimPrefix(h.Digest(), "sha256:")) {
				services = union(services, reachServices(c, *h))
			}
		}
	}
	// With a COMPOSE_* setting in .env no compose call is made: the
	// journal's services and its kept files name what to stop.
	if names, err := e.everyReachService(ctx); err == nil {
		services = union(services, names)
	}
	j.Services = union(services, []string{cyfrService})
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	st, err := e.readState()
	var ref *Refusal
	if errors.As(err, &ref) && ref.Code == "compose_env_refused" {
		// Stopped and verified without compose, which would read the
		// setting; the switch stays unfinished until .env reads.
		return Receipt{}, ref
	}
	held := keysOf(Head{})
	if err == nil {
		held = st.heldKeys()
	}
	// A .env that holds no coherent head is the person's edit, kept as
	// it is: only one still incoherent with the head keys it held when
	// the switch began, incoherent then too, is .env unchanged. One that
	// was incoherent then and holds a head now was corrected meanwhile,
	// whatever its head keys, and is resolved afresh as an edit.
	switch {
	case err == nil && j.OldHead == nil && st.headErr != nil && maps.Equal(held, j.OldKeys):
		return e.recoverOld(ctx, j)
	case err != nil || st.headErr != nil:
	case maps.Equal(held, j.NewKeys) && (j.Reopen || !maps.Equal(held, j.OldKeys)):
		if err := e.setPhase(j, "committed"); err != nil {
			return e.outcomeUnknown(j, err)
		}
		return e.startTarget(ctx, j)
	case j.OldHead != nil && maps.Equal(held, j.OldKeys):
		return e.recoverOld(ctx, j)
	}
	// .env was edited meanwhile: the switch failed, and the home is
	// started as .env now says, when it can be.
	edited := func(then string, final *Head) Receipt {
		payload := map[string]string{"then": then}
		if then != "incoherent" {
			payload["env"] = st.words()
		}
		return e.completed(j, "failed", Refuse("reach_env_edited", payload), final)
	}
	switch {
	case err != nil || st.headErr != nil:
		return e.finishAnswer(j, edited("incoherent", nil))
	case !j.Running:
		return e.finishAnswer(j, edited("not_running", &st.head))
	}
	s := e.startHead(ctx, st.head, j, false, HealthDeadline)
	switch {
	case s.ok:
		return e.finishAnswer(j, edited("started", &st.head))
	case s.local != nil:
		return e.finishAnswer(j, e.completed(j, "started_local", s.local, &st.head))
	}
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	return e.finishAnswer(j, edited("failed", nil))
}

// recoverOld finishes a switch whose commit did not happen, or whose
// rollback had put .env back: the old head starts again if the stack was
// running. A rollback's receipt says why the new head did not start.
func (e *Engine) recoverOld(ctx context.Context, j *journal) (Receipt, error) {
	notApplied := e.completed(j, "not_applied", nil, j.OldHead)
	if j.Reason != "" && j.OldHead != nil {
		notApplied = e.completed(j, "rolled_back", Refuse("reach_rolled_back", map[string]string{
			"new": wordsText(Describe(*j.NewHead)), "old": wordsText(Describe(*j.OldHead)), "reason": j.Reason,
		}), j.OldHead)
	}
	if !j.Running || j.OldHead == nil {
		return e.finishAnswer(j, notApplied)
	}
	s := e.startHead(ctx, *j.OldHead, j, false, HealthDeadline)
	switch {
	case s.ok:
		return e.finishAnswer(j, notApplied)
	case s.local != nil && j.Reason != "":
		return e.finishAnswer(j, e.completed(j, "rolled_back", rolledBackLocal(j, j.Reason, s.local), j.OldHead))
	case s.local != nil:
		return e.finishAnswer(j, e.completed(j, "started_local", s.local, j.OldHead))
	}
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	return e.finishAnswer(j, e.failed(j, map[string]string{"new": wordsText(Describe(*j.NewHead)), "env": wordsText(Describe(*j.OldHead))}))
}
