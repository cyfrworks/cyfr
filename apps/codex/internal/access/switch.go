// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// IdentityUnchanged closes the list of what changes with the address.
const IdentityUnchanged = "Your CYFR identity does not change."

// addressChanges is what stops working when the home's address changes,
// shown before the change is made.
var addressChanges = []string{
	"Passkeys made at the old address stop working. Each person registers one at the new address, which an administrator authorizes as today.",
	"Pair every device again.",
	"Update the redirect address in OAuth apps you registered (vault credentials, an OIDC issuer), the URL your webhook senders call, CLI contexts and MCP clients.",
	"Every other CYFR and device that saved the old address needs the new one.",
}

// envState is .env as an operation reads it: the head it holds, or the
// boot refusal that says why it holds none, and what a new head keeps of
// it.
type envState struct {
	env     *dotenv
	head    Head
	headErr error
	cur     Current
	curErr  *Refusal
}

func (e *Engine) readState() (envState, error) {
	env, err := e.readEnv()
	if err != nil {
		return envState{}, err
	}
	st := envState{env: env}
	values := map[string]string{}
	if env != nil {
		values = env.values()
	}
	st.head, st.headErr = headOf(values)
	st.cur.BuildsURL = strings.TrimSpace(values["CYFR_LOCUS_BUILDS_URL"])
	switch port := strings.TrimSpace(values["CYFR_PORT"]); {
	case st.headErr == nil:
		st.cur.Port = st.head.Port
	case port == "":
		st.cur.Port = 4000
	default:
		if n, err := strconv.Atoi(port); err == nil && digits.MatchString(port) && n >= 1 && n <= 65535 {
			st.cur.Port = n
		} else {
			st.curErr = settingInvalid("CYFR_PORT", port)
		}
	}
	return st, nil
}

// headOf is the head a .env's own read holds, as a release would boot it.
func headOf(values map[string]string) (Head, error) {
	b, err := ResolveBoot(BootInput{File: values, Process: values, Release: true})
	if err != nil {
		return Head{}, err
	}
	return b.Head, nil
}

func (e *Engine) envHead() (Head, error) {
	st, err := e.readState()
	if err != nil {
		return Head{}, err
	}
	return st.head, st.headErr
}

// digest is .env's head's digest, "" when it holds none.
func (st envState) digest() string {
	if st.headErr != nil {
		return ""
	}
	return st.head.Digest()
}

// words is how .env's head reads, or the refusal that says it holds
// none.
func (st envState) words() string {
	if st.headErr != nil {
		var r *Refusal
		if errors.As(st.headErr, &r) {
			return r.Message()
		}
		return st.headErr.Error()
	}
	return wordsText(Describe(st.head))
}

// heldKeys are .env's head keys now, "" for each it does not assign.
func (st envState) heldKeys() map[string]string {
	if st.env == nil {
		return keysOf(Head{})
	}
	return st.env.heldKeys()
}

// wordsText is a head's words in one line, as a refusal names it.
func wordsText(w Words) string {
	text := w.Who + ", at " + w.Address
	if w.CertificateEmail != "none" {
		text += ", certificate email " + w.CertificateEmail
	}
	return text
}

// tailnetActive reports whether .env's head is tailnet and its machine is
// served: Serve open, which only a validated start writes, and the
// tailscale service running.
func (e *Engine) tailnetActive(ctx context.Context, st envState) bool {
	if st.headErr != nil || st.head.Mode != ModeTailnet || !e.serveIsOpen() {
		return false
	}
	cs, err := e.observe(ctx)
	return err == nil && slices.ContainsFunc(cs, func(c Container) bool { return c.Service == serveService && running(c.State) })
}

func (e *Engine) preview(ctx context.Context, t Target, joinID string) (Preview, error) {
	st, err := e.readState()
	if err != nil {
		return Preview{}, err
	}
	if t.Mode == ModeTailnet && joinID == "" && e.tailnetActive(ctx, st) {
		return Preview{}, Refuse("tailnet_active", map[string]string{"name": st.head.Host})
	}
	d, err := e.derive(ctx, st, t, joinID)
	if err != nil {
		return Preview{}, err
	}
	p := Preview{New: d.Head, NewDigest: d.Head.Digest(), NewWords: Describe(d.Head), OldDigest: st.digest()}
	if st.headErr == nil {
		p.Old, p.OldWords = st.head, Describe(st.head)
		if p.OldDigest == p.NewDigest {
			if !e.reopens(ctx, st) {
				return Preview{}, Refuse("access_unchanged", map[string]string{"address": st.head.origin()})
			}
			p.Reopen = true
			return p, nil
		}
	}
	if st.headErr != nil || st.head.origin() != d.Head.origin() {
		p.AddressChanges = slices.Clone(addressChanges)
	}
	return p, nil
}

// closedTailnet reports whether .env's head is tailnet with Serve closed:
// a start found its machine not ready to serve, or the home is stopped.
func (e *Engine) closedTailnet(st envState) bool {
	return st.headErr == nil && st.head.Mode == ModeTailnet && !e.serveIsOpen()
}

// reopens reports whether a switch to .env's own head is a reopen: a
// tailnet home whose Serve is closed while its cyfr runs. A stopped one
// is unchanged: its next start validates the machine and opens Serve.
func (e *Engine) reopens(ctx context.Context, st envState) bool {
	if !e.closedTailnet(st) {
		return false
	}
	cs, err := e.observe(ctx)
	return err == nil && cyfrRunning(cs)
}

// servesHead reports whether Serve's configuration is the one the
// flattened configuration content names, forwarding to its proxy port,
// and cyfr runs.
func (e *Engine) servesHead(ctx context.Context, content []byte) bool {
	c, err := parseConfig(content)
	if err != nil || !equalBytes(e.servePath(), []byte(serveOpen(proxyPort(c)))) {
		return false
	}
	cs, err := e.observe(ctx)
	return err == nil && cyfrRunning(cs)
}

// derive is the head t makes from .env's settings and, for tailnet, the
// machine: the one join joinID froze, or with no join id the machine
// this home has now (machine).
func (e *Engine) derive(ctx context.Context, st envState, t Target, joinID string) (Derivation, error) {
	if st.curErr != nil {
		return Derivation{}, st.curErr
	}
	var join *Join
	switch {
	case t.Mode != ModeTailnet:
	case joinID != "":
		rec, err := e.readJoin()
		if err != nil {
			return Derivation{}, err
		}
		if rec != nil && rec.JoinID == joinID {
			if ref := rec.refusal(); ref != nil && rec.State != "https_off" {
				return Derivation{}, ref
			}
			join = &Join{Name: rec.Name, NodeID: rec.NodeID}
		} else if join = e.joinReceiptFor(joinID); join == nil {
			return Derivation{}, Refuse("tailnet_join_not_current", nil)
		}
	default:
		var err error
		if join, err = e.machine(ctx); err != nil {
			return Derivation{}, err
		}
	}
	return Derive(t, st.cur, join)
}

// machine is this home's tailnet machine, nil when it has none: the one
// the running tailscale service reports, which is the state volume's
// own, else the machine the latest completed join froze (HTTPS off
// included: the start checks HTTPS before Serve opens). A running
// service whose state holds no login has none.
func (e *Engine) machine(ctx context.Context) (*Join, error) {
	cs, err := e.observe(ctx)
	if err != nil {
		return nil, err
	}
	for _, c := range cs {
		if c.Service != serveService || !running(c.State) {
			continue
		}
		if s, ok := e.statusOnce(ctx, []string{"exec", c.Name, "tailscale", "status", "--json"}); ok {
			if s.BackendState != "Running" {
				return nil, nil
			}
			return &Join{Name: s.name(), NodeID: s.id()}, nil
		}
	}
	rec, err := e.readJoin()
	if err != nil || rec == nil || rec.State != "joined" && rec.State != "https_off" {
		return nil, err
	}
	return &Join{Name: rec.Name, NodeID: rec.NodeID}, nil
}

// contentDigest is a switch's content in the request digest's form.
func contentDigest(c RequestContent) string {
	return requestDigest(map[string]any{
		"op": "switch", "mode": c.Mode, "domain": c.Domain, "acme_email": c.ACMEEmail,
		"hostname": c.Hostname, "new_node": c.NewNode, "auth_key_fingerprint": c.AuthKeyFingerprint,
	})
}

// switchDigest binds a switch's id to the whole request, its content
// included, so a resend with other content is access_request_reused
// whatever the first answer was.
func switchDigest(r SwitchRequest) string {
	return requestDigest(map[string]any{
		"op": "switch", "mode": r.Target.Mode, "domain": r.Target.Domain, "acme_email": r.Target.ACMEEmail,
		"join_id": r.JoinID, "old_digest": r.OldDigest, "new_digest": r.NewDigest,
		"content_digest": contentDigest(r.Content),
	})
}

func (e *Engine) doSwitch(ctx context.Context, r SwitchRequest) (Receipt, error) {
	if err := e.requireLock(); err != nil {
		return Receipt{}, err
	}
	if _, err := e.readEnv(); err != nil {
		return Receipt{}, err
	}
	digest := switchDigest(r)
	if rc, ok, err := e.lookup(r.ID, digest); err != nil || ok {
		if err != nil {
			return Receipt{}, err
		}
		return answer(rc)
	}
	content := contentDigest(r.Content)
	if rc, blocked, err := e.blocked(r.ID, digest, "switch", content); blocked || err != nil {
		return rc, err
	}
	refuse := func(err error) (Receipt, error) {
		var ref *Refusal
		if errors.As(err, &ref) {
			return e.rejectContent(r.ID, digest, content, "switch", ref)
		}
		return Receipt{}, err
	}
	st, err := e.readState()
	if err != nil {
		return refuse(err)
	}
	if r.Target.Mode == ModeTailnet {
		if ref, err := e.nameChanged(ctx, r.JoinID); err != nil || ref != nil {
			if err != nil {
				return Receipt{}, err
			}
			return refuse(ref)
		}
	}
	d, err := e.derive(ctx, st, r.Target, r.JoinID)
	if err != nil {
		return refuse(err)
	}
	if st.digest() != r.OldDigest || d.Head.Digest() != r.NewDigest {
		return refuse(Refuse("access_stale", map[string]string{"words": st.words()}))
	}
	reopen := st.headErr == nil && st.head.Digest() == d.Head.Digest()
	switch {
	case reopen && !e.closedTailnet(st):
		return refuse(Refuse("access_unchanged", map[string]string{"address": st.head.origin()}))
	case reopen && !e.reopens(ctx, st):
		// The preview was a reopen of a running home, which has stopped
		// since: nothing would open Serve.
		return refuse(Refuse("access_stale", map[string]string{"words": st.words()}))
	}
	cs, err := e.observe(ctx)
	var js []joinContainer
	if err == nil {
		js, err = e.observeJoins(ctx)
	}
	if err != nil {
		return refuse(Refuse("docker_unavailable", map[string]string{"reason": err.Error()}))
	}
	if reopen && !cyfrRunning(cs) {
		// The home stopped since the check above: a reopen it accepted
		// would record a stopped stack and open nothing.
		return refuse(Refuse("access_stale", map[string]string{"words": st.words()}))
	}

	j := &journal{
		Op: "switch", RequestID: r.ID, RequestDigest: digest, ContentDigest: content,
		NewHead: &d.Head, OldKeys: st.heldKeys(), NewKeys: keysOf(d.Head),
		Running: cyfrRunning(cs), Services: []string{cyfrService}, Reopen: reopen,
	}
	if st.headErr == nil {
		j.OldHead = &st.head
	}
	if anyRunning(cs, js) {
		// The access services, named from the access modes' profiles: a
		// stopped stack needs none, and makes no compose call.
		if _, err := e.checkProvenance(); err != nil {
			return Receipt{}, err
		}
		// Every access mode's services, so one an incoherent old head
		// cannot name, or a leftover no head selects, is stopped too.
		names, err := e.everyAccessService(ctx)
		if err != nil {
			return refuse(Refuse("docker_unavailable", map[string]string{"reason": err.Error()}))
		}
		j.Services = union(j.Services, names)
	}
	if err := e.setPhase(j, "accepted"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.runSwitch(context.WithoutCancel(ctx), j)
}

// runSwitch carries an accepted switch through: stop and verify, commit
// .env, start what was running.
func (e *Engine) runSwitch(ctx context.Context, j *journal) (Receipt, error) {
	if j.Reopen {
		// .env holds the head already: only the start path runs.
		if err := e.setPhase(j, "committed"); err != nil {
			return e.outcomeUnknown(j, err)
		}
		return e.startTarget(ctx, j)
	}
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	if err := e.setPhase(j, "stopped"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	if err := e.writeEnvKeys(j.NewKeys); err != nil {
		return e.outcomeUnknown(j, err)
	}
	e.reached("env:commit")
	if err := e.setPhase(j, "committed"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return e.startTarget(ctx, j)
}

// startTarget starts the committed head if the stack was running, and
// rolls back when it cannot. A machine that is another than the head's
// leaves the head committed and cyfr running with Serve closed
// (started_local); one that has not joined, or has HTTPS off, is a start
// that failed, but for a reopen, which only ever reopened Serve.
func (e *Engine) startTarget(ctx context.Context, j *journal) (Receipt, error) {
	done := Receipt{RequestID: j.RequestID, RequestDigest: j.RequestDigest, ContentDigest: j.ContentDigest, Op: j.Op, State: "completed", Outcome: "ok", FinalHead: j.NewHead}
	if !j.Running {
		return e.finishAnswer(j, done)
	}
	s := e.startHead(ctx, *j.NewHead, j, false, HealthDeadline)
	switch {
	case s.ok && j.Reopen && !e.servesHead(ctx, s.content):
		// A reopen is done only while the home runs with Serve as the
		// head names it. One that stopped, or whose Serve changed, once
		// Serve opened has Serve closed again and nothing more started.
		if err := e.closeServe(); err != nil {
			return e.outcomeUnknown(j, err)
		}
		return e.finishAnswer(j, e.completed(j, "not_applied", Refuse("access_stale", map[string]string{"words": wordsText(Describe(*j.NewHead))}), j.NewHead))
	case s.ok:
		return e.finishAnswer(j, done)
	case s.identityMismatch() || j.Reopen && s.local != nil:
		return e.finishAnswer(j, e.completed(j, "started_local", s.local, j.NewHead))
	}
	why := s.why
	if s.local != nil {
		why = s.local.Message()
	}
	return e.rollback(ctx, j, why, s.content)
}

// rollback stops and verifies everything the target started, its proxy
// and cyfr included; only then does .env get the old head back, and the
// old head start. A stop that cannot be verified starts nothing and
// leaves the journal unfinished.
func (e *Engine) rollback(ctx context.Context, j *journal, why string, content []byte) (Receipt, error) {
	j.Reason = why
	if content != nil {
		if c, err := parseConfig(content); err == nil {
			j.Services = union(j.Services, accessServices(c, *j.NewHead))
		}
	}
	if err := e.setPhase(j, "rolling_back"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	if err := e.writeEnvKeys(j.OldKeys); err != nil {
		return e.outcomeUnknown(j, err)
	}
	e.reached("env:rollback")
	if err := e.setPhase(j, "restored"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	newWords := wordsText(Describe(*j.NewHead))
	if j.OldHead == nil {
		st, _ := e.readState()
		return e.finishAnswer(j, e.failed(j, map[string]string{"new": newWords, "env": st.words()}))
	}
	oldWords := wordsText(Describe(*j.OldHead))
	s := e.startHead(ctx, *j.OldHead, j, false, HealthDeadline)
	switch {
	case s.ok:
		return e.finishAnswer(j, e.completed(j, "rolled_back", Refuse("access_rolled_back", map[string]string{"new": newWords, "old": oldWords, "reason": why}), j.OldHead))
	case s.local != nil:
		return e.finishAnswer(j, e.completed(j, "rolled_back", rolledBackLocal(j, why, s.local), j.OldHead))
	}
	if s := e.stopAndVerify(ctx, j.Services); !s.ok {
		return e.uncertain(j, s)
	}
	return e.finishAnswer(j, e.failed(j, map[string]string{"new": newWords, "env": oldWords}))
}

// rolledBackLocal is access_rolled_back for a rollback whose old head
// answers on this machine only: the change that failed, its reason, and
// why the old head serves no further.
func rolledBackLocal(j *journal, why string, local *Refusal) *Refusal {
	return Refuse("access_rolled_back", map[string]string{
		"new": wordsText(Describe(*j.NewHead)), "old": wordsText(Describe(*j.OldHead)), "reason": why, "local": local.Code,
	})
}

func (e *Engine) completed(j *journal, outcome string, ref *Refusal, final *Head) Receipt {
	r := Receipt{RequestID: j.RequestID, RequestDigest: j.RequestDigest, ContentDigest: j.ContentDigest, Op: j.Op, State: "completed", Outcome: outcome, FinalHead: final}
	if ref != nil {
		r.Code, r.Payload = ref.Code, ref.Payload
	}
	return r
}

// failed is a switch that ended with nothing running: access_failed.
func (e *Engine) failed(j *journal, payload map[string]string) Receipt {
	return e.completed(j, "failed", Refuse("access_failed", payload), nil)
}

func (e *Engine) finishAnswer(j *journal, r Receipt) (Receipt, error) {
	r, err := e.finish(j, r)
	if err != nil {
		return e.outcomeUnknown(j, err)
	}
	return answer(r)
}

// uncertain leaves the operation unfinished in phase uncertain, with what
// its stop and verify saw: nothing more is started, and Resume retries.
func (e *Engine) uncertain(j *journal, s stopped) (Receipt, error) {
	j.Observed, j.Why = s.observed, s.why
	if err := e.setPhase(j, "uncertain"); err != nil {
		return e.outcomeUnknown(j, err)
	}
	return answer(j.receipt())
}

// outcomeUnknown answers an operation that lost track of itself after
// its acceptance: its journal stands as far as it was written, and
// Resume finishes it.
func (e *Engine) outcomeUnknown(j *journal, err error) (Receipt, error) {
	r := j.receipt()
	if r.Code == "" {
		r.Code, r.Payload = "access_outcome_unknown", map[string]string{"reason": err.Error()}
	}
	return answer(r)
}

// blocked answers a mutating method while the journal holds another
// operation: an uncertain one with its receipt, a waiting join with
// access_busy naming it, anything else as unfinished.
func (e *Engine) blocked(id, digest, op, content string) (Receipt, bool, error) {
	j, err := e.readJournal()
	if err != nil || j == nil {
		return Receipt{}, false, err
	}
	switch {
	case j.Phase == "uncertain":
		rc, err := answer(j.receipt())
		return rc, true, err
	case j.Op == "join" && j.Join != nil && j.Join.State == "waiting":
		rc, err := e.rejectContent(id, digest, content, op, joinBusy(j.Join.JoinID, j.Join.Deadline))
		return rc, true, err
	}
	rc, err := answer(Receipt{RequestID: id, RequestDigest: digest, ContentDigest: content, Op: op, State: "rejected", Code: "access_outcome_unknown",
		Payload: map[string]string{"reason": "the " + j.Op + " " + j.RequestID + " is unfinished"}})
	return rc, true, err
}

// writeEnvKeys writes .env with the head keys want names, every other
// line as it was.
func (e *Engine) writeEnvKeys(want map[string]string) error {
	path := e.envPath()
	if target, err := filepath.EvalSymlinks(path); err == nil {
		path = target
	}
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	edited, err := editHeadKeys(data, want)
	if err != nil {
		return err
	}
	return e.writeDurable(path, edited, e.envMode())
}

// nameChanged refuses a tailnet switch whose machine is no longer the
// one its join froze: a newer join, or the running tailscale service,
// now names another.
func (e *Engine) nameChanged(ctx context.Context, joinID string) (*Refusal, error) {
	if joinID == "" {
		return nil, nil
	}
	cur, err := e.readJoin()
	if err != nil {
		return nil, err
	}
	frozen := e.frozenJoin(joinID, cur)
	if frozen == nil {
		return nil, nil
	}
	now := frozen
	if cur != nil && cur.JoinID != joinID && cur.Name != "" {
		now = &Join{Name: cur.Name, NodeID: cur.NodeID}
	}
	if cs, err := e.observe(ctx); err == nil {
		if name, ok := containerOf(cs, serveService); ok && slices.ContainsFunc(cs, func(c Container) bool { return c.Name == name && running(c.State) }) {
			if s, ok := e.statusOnce(ctx, []string{"exec", name, "tailscale", "status", "--json"}); ok && s.BackendState == "Running" {
				now = &Join{Name: s.name(), NodeID: s.id()}
			}
		}
	}
	if *now == *frozen {
		return nil, nil
	}
	withID := now.Name == frozen.Name
	return Refuse("tailnet_name_changed", map[string]string{"frozen": identity(frozen.Name, frozen.NodeID, withID), "now": identity(now.Name, now.NodeID, withID)}), nil
}

func union(a, b []string) []string {
	out := slices.Concat(a, b)
	slices.Sort(out)
	return slices.Compact(out)
}
