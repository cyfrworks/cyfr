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
	exchange   pinExchange
	evaluators map[string]*pinEvaluator
	byNonce    map[string]string // a reset challenge's nonce -> its evaluator
	ids        []string          // the evaluators, in the order enrolled
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
	// tamper edits the next reset challenge before it is sent; answer
	// edits the next evaluation's answer.
	tamper, answer func(map[string]any)
}

type pinEvaluator struct {
	server          oprf.Server
	client, athanor string
	key             string
	attempts        int
	revision        int
	next            time.Time
	suspended       bool
	everReset       bool
	destroyed       bool
}

// pinExchange is tests/fixtures/device_pin.json's exchange: each entry's
// exact request and answer fields, and the refusals' codes.
type pinExchange struct {
	Evaluate struct {
		Path    string   `json:"path"`
		Request []string `json:"request"`
		Answer  []string `json:"answer"`
	} `json:"evaluate"`
	Reset struct {
		Path    string   `json:"path"`
		Request []string `json:"request"`
		Answer  []string `json:"answer"`
	} `json:"reset"`
	Refusals struct {
		Codes   map[string]int `json:"codes"`
		PINWait []string       `json:"pin_wait"`
	} `json:"refusals"`
}

func newPINHome(h *fakeHome, mux *http.ServeMux) *pinHome {
	var v struct {
		Exchange pinExchange `json:"exchange"`
	}
	fixture(h.t, "device_pin.json", &v)
	p := &pinHome{h: h, exchange: v.Exchange, evaluators: map[string]*pinEvaluator{}, byNonce: map[string]string{}}
	mux.HandleFunc("POST "+p.exchange.Evaluate.Path, p.evaluate)
	mux.HandleFunc("POST "+p.exchange.Reset.Path, p.reset)
	return p
}

// enroll is pin.enroll for the device whose record is at path: a new
// evaluator beside the device's others until its first reset, which
// destroys them; an earlier one never reset is removed now.
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
	id := "pev_" + b64(random(32))
	for _, other := range p.evaluators {
		if other.client == rec.ClientID && !other.everReset {
			other.destroyed = true
		}
	}
	p.evaluators[id] = &pinEvaluator{server: oprf.NewServer(oprf.SuiteRistretto255, k), client: rec.ClientID,
		athanor: rec.Athanor, key: b64(rec.PublicKey)}
	p.ids = append(p.ids, id)
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
	if !exact(m, p.exchange.Evaluate.Request) {
		p.h.shapes = append(p.h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
		reply(w, p.exchange.Refusals.Codes["bad_request"], map[string]any{"error": "bad_request"})
		return
	}
	id := stringOf(m, "evaluator")
	ev := p.evaluators[id]
	if ev == nil || ev.suspended || ev.destroyed {
		reply(w, p.exchange.Refusals.Codes["not_found"], map[string]any{"error": "not_found"})
		return
	}
	p.evaluations++
	now := time.Now()
	if now.Before(ev.next) {
		w.Header().Set("Retry-After", strconv.Itoa(int(ev.next.Sub(now).Seconds())+1))
		reply(w, p.exchange.Refusals.Codes["pin_wait"], map[string]any{"error": "pin_wait", "next_allowed_at": ev.next.UnixMilli()})
		return
	}
	raw, err := unb64(stringOf(m, "blinded"))
	el := oprf.SuiteRistretto255.Group().NewElement()
	if err != nil || len(raw) != holder.ElementSize || el.UnmarshalBinary(raw) != nil || el.IsIdentity() {
		reply(w, p.exchange.Refusals.Codes["bad_request"], map[string]any{"error": "bad_request"})
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
	answer := map[string]any{"evaluated": b64(out), "reset": c}
	if !exact(answer, p.exchange.Evaluate.Answer) {
		p.h.shapes = append(p.h.shapes, fmt.Sprintf("the evaluate answer %v", answer))
	}
	if p.answer != nil {
		p.answer(answer)
		p.answer = nil
	}
	reply(w, 200, answer)
}

// reset consumes a reset proof once: bound to its evaluation's nonce and
// the count's current revision, it starts the count again and retires the
// evaluator the new one replaces; a stale one changes nothing.
func (p *pinHome) reset(w http.ResponseWriter, r *http.Request) {
	m := p.h.body(r)
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	proof, _ := m["proof"].(map[string]any)
	if !exact(m, p.exchange.Reset.Request) {
		p.h.shapes = append(p.h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
	}
	nonce := stringOf(proof, "nonce")
	id := p.byNonce[nonce]
	delete(p.byNonce, nonce)
	held, ok := p.h.verify(proof, "pin_reset")
	ev := p.evaluators[id]
	if !ok || ev == nil || fmt.Sprint(held["revision"]) != strconv.Itoa(ev.revision) {
		p.staleResets++
		reply(w, p.exchange.Refusals.Codes["proof_refused"], map[string]any{"error": "proof_refused"})
		return
	}
	ev.attempts, ev.next, ev.everReset = 0, time.Time{}, true
	p.resets = append(p.resets, ev.revision)
	ev.revision++
	for _, other := range p.evaluators {
		if other != ev && other.client == ev.client {
			other.destroyed = true
		}
	}
	reply(w, 200, map[string]any{"reset": true})
}

// state is one evaluator's count, its revision and whether it evaluates.
func (p *pinHome) state(id string) (attempts, revision int, live bool) {
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	ev := p.evaluators[id]
	return ev.attempts, ev.revision, !ev.suspended && !ev.destroyed
}

// id is the nth evaluator enrolled.
func (p *pinHome) id(n int) string {
	p.h.mu.Lock()
	defer p.h.mu.Unlock()
	return p.ids[n]
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
