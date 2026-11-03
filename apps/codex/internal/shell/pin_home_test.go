// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/cloudflare/circl/oprf"
	"github.com/cyfr/codex/internal/holder"
)

// pinHome is the fake home's PIN evaluators: one OPRF key (circl's
// server) per evaluator, a charged count with its revision and the time
// the next evaluation is taken, as the plan's S3 describes the home.
type pinHome struct {
	h          *fakeHome
	evaluators map[string]*pinEvaluator
	byNonce    map[string]string // a reset challenge's nonce -> its evaluator
	// evaluations counts every evaluation request that reached a known
	// evaluator, charged or refused; charged only those charged.
	evaluations, charged int
	resets               []int // the revisions reset
	staleResets          int
	enrolls              int
	// dropEvaluate charges the next evaluation and loses its answer.
	dropEvaluate bool
	// down refuses to reach the evaluation at all, charging nothing.
	down bool
	// tamper edits the next reset challenge before it is sent.
	tamper func(map[string]any)
}

type pinEvaluator struct {
	server          oprf.Server
	client, athanor string
	key             string
	attempts        int
	revision        int
	next            time.Time
	suspended       bool
	replaces        string
	destroyed       bool
}

func newPINHome(h *fakeHome, mux *http.ServeMux) *pinHome {
	p := &pinHome{h: h, evaluators: map[string]*pinEvaluator{}, byNonce: map[string]string{}}
	mux.HandleFunc("POST /device/pin/evaluate", p.evaluate)
	mux.HandleFunc("POST /device/pin/reset", p.reset)
	return p
}

// enroll is pin.enroll for the device whose record is at path: a new
// evaluator, replacing (once its first reset arrives) the one the device
// held.
func (p *pinHome) enroll(path string) (string, error) {
	rec, err := holder.Load(path)
	if err != nil {
		return "", err
	}
	k, err := oprf.GenerateKey(oprf.SuiteRistretto255, rand.Reader)
	if err != nil {
		return "", err
	}
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	p.enrolls++
	id := fmt.Sprintf("dpe_%d", p.enrolls)
	ev := &pinEvaluator{server: oprf.NewServer(oprf.SuiteRistretto255, k), client: rec.ClientID,
		athanor: rec.Athanor, key: b64(rec.PublicKey)}
	if rec.PIN != nil {
		ev.replaces = rec.PIN.Evaluator
	}
	p.evaluators[id] = ev
	return id, nil
}

// reauthorize is the recovery code re-enabling client: its suspended
// evaluators evaluate again.
func (p *pinHome) reauthorize(client string) {
	for _, ev := range p.evaluators {
		if ev.client == client {
			ev.suspended = false
		}
	}
}

func (p *pinHome) evaluate(w http.ResponseWriter, r *http.Request) {
	m := p.h.body(r)
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	if p.down {
		hijackClose(w)
		return
	}
	if !exact(m, []string{"evaluator", "blinded"}) {
		p.h.shapes = append(p.h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
		reply(w, 400, map[string]any{"error": "bad_request"})
		return
	}
	id := stringOf(m, "evaluator")
	ev := p.evaluators[id]
	if ev == nil || ev.suspended || ev.destroyed {
		reply(w, 404, map[string]any{"error": "not_found"})
		return
	}
	p.evaluations++
	now := time.Now()
	if now.Before(ev.next) {
		w.Header().Set("Retry-After", strconv.Itoa(int(ev.next.Sub(now).Seconds())+1))
		reply(w, 429, map[string]any{"error": "pin_wait", "next_allowed_at": ev.next.UnixMilli()})
		return
	}
	raw, err := unb64(stringOf(m, "blinded"))
	el := oprf.SuiteRistretto255.Group().NewElement()
	if err != nil || len(raw) != holder.ElementSize || el.UnmarshalBinary(raw) != nil {
		reply(w, 400, map[string]any{"error": "bad_request"})
		return
	}
	// Charged before the answer: a lost answer stays charged.
	p.charged++
	ev.attempts++
	ev.revision++
	ev.next = now.Add(time.Duration(min(1<<min(ev.attempts-1, 12), 3600)) * time.Second)
	got, err := ev.server.Evaluate(&oprf.EvaluationRequest{Elements: []oprf.Blinded{el}})
	if err != nil {
		reply(w, 400, map[string]any{"error": "bad_request"})
		return
	}
	out, _ := got.Elements[0].MarshalBinaryCompress()
	if p.dropEvaluate {
		p.dropEvaluate = false
		hijackClose(w)
		return
	}
	c := p.h.issue(map[string]any{"purpose": "pin_reset", "athanor": ev.athanor, "client_id": ev.client,
		"device_key": ev.key, "revision": json.Number(strconv.Itoa(ev.revision))})
	p.byNonce[stringOf(c, "nonce")] = id
	if p.tamper != nil {
		p.tamper(c)
		p.tamper = nil
	}
	reply(w, 200, map[string]any{"evaluated": b64(out), "reset": c})
}

// reset consumes a reset proof once: bound to its evaluation's nonce and
// the count's current revision, it starts the count again and retires the
// evaluator the new one replaces; a stale one changes nothing.
func (p *pinHome) reset(w http.ResponseWriter, r *http.Request) {
	m := p.h.body(r)
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	proof, _ := m["proof"].(map[string]any)
	if !exact(m, []string{"proof"}) {
		p.h.shapes = append(p.h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
	}
	nonce := stringOf(proof, "nonce")
	id := p.byNonce[nonce]
	delete(p.byNonce, nonce)
	held, ok := p.h.verify(proof, "pin_reset")
	ev := p.evaluators[id]
	if !ok || ev == nil || fmt.Sprint(held["revision"]) != strconv.Itoa(ev.revision) {
		p.staleResets++
		reply(w, 409, map[string]any{"error": "stale"})
		return
	}
	ev.attempts, ev.next = 0, time.Time{}
	p.resets = append(p.resets, ev.revision)
	if old := p.evaluators[ev.replaces]; old != nil {
		old.destroyed = true
	}
	ev.replaces = ""
	reply(w, 200, map[string]any{"reset": true})
}

// state is one evaluator's count, its revision and whether it evaluates.
func (p *pinHome) state(id string) (attempts, revision int, live bool) {
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	ev := p.evaluators[id]
	return ev.attempts, ev.revision, !ev.suspended && !ev.destroyed
}

// set changes the fake's settings under its lock.
func (p *pinHome) set(f func(*pinHome)) {
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	f(p)
}

// allow lifts the wait on every evaluator.
func (p *pinHome) allow() {
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	for _, ev := range p.evaluators {
		ev.next = time.Time{}
	}
}
