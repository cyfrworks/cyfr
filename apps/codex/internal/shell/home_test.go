// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeHome is a home as the shell meets it: the enrollment entries, the
// restore ingress and the device channel, each verifying every proof it
// is given against the challenge it holds, and recording every byte it
// receives so a test can show no PIN or passphrase reached it.
type fakeHome struct {
	t   *testing.T
	srv *httptest.Server

	mu           sync.Mutex
	received     bytes.Buffer
	setupToken   string
	restoreToken string
	held         map[string]map[string]any // by nonce
	enrolled     map[string]*enrollment    // by request id
	completes    int
	resumes      int
	// dropComplete commits the next complete and loses its answer;
	// downComplete refuses to reach it, committing nothing.
	dropComplete, downComplete bool
	recordPath                 string
	recordAtChallenge          []bool
	taken                      map[string]bool
	registryDown               int
	ops                        []string
	locked                     []string
	confirmed                  []map[string]any
	pending                    map[string]map[string]any // ref -> record
	capabilities               [][]string
	unlockSeq                  int
	conns                      []*websocket.Conn
	closeWith                  websocket.StatusCode
	stalled                    chan struct{}
	fields                     httpFields
	kitPublic                  []byte // the recovering person's recovery key
	kitHeld                    map[string]string
	reenabled                  []string
	restores                   int
	shapes                     []string            // entries whose fields were not the fixture's
	invitationCode             string              // the invitation a new person joins by
	openDoor                   bool                // whether the open door admits
	sessions                   map[string]string   // spent ticket -> the session's bearer
	pairings                   map[string]*pairing // by invitation secret
	dropPair                   bool                // commits the next pairing and loses its answer
	pairArgs                   []map[string]any
	pairFields                 [][]string // pairing.complete's args, without and with the proof
	pin                        *pinHome   // the PIN evaluators (pin_home_test.go)
}

// pairing is one invitation a confirmed addition opened: the key it names
// and the client it reserves; committed once a proof of that key
// completes it.
type pairing struct {
	digest    string
	athanor   string
	client    string
	committed []byte // the key it paired
}

type enrollment struct {
	key       []byte
	admission string
	client    string
	athanor   string
	name      any
	recovery  *Recovery
	saved     bool
}

// httpFields is the fixture's exchange.http: each entry's exact request
// fields.
type httpFields struct {
	Challenge struct {
		Request []string `json:"request"`
	} `json:"enrollment_challenge"`
	Complete struct {
		Request map[string][]string `json:"request"`
	} `json:"enrollment_complete"`
	Resume []struct {
		Request []string `json:"request"`
	} `json:"enrollment_resume"`
	DeviceSession struct {
		Request []string `json:"request"`
	} `json:"device_session"`
}

// exact is whether m names exactly fields.
func exact(m map[string]any, fields []string) bool {
	if len(m) != len(fields) {
		return false
	}
	for _, f := range fields {
		if _, ok := m[f]; !ok {
			return false
		}
	}
	return true
}

func newFakeHome(t *testing.T) *fakeHome {
	var v struct {
		Exchange struct {
			HTTP       httpFields `json:"http"`
			Operations struct {
				PairingComplete []struct {
					Args []string `json:"args"`
				} `json:"pairing.complete"`
			} `json:"operations"`
		} `json:"exchange"`
	}
	fixture(t, "device_unlock.json", &v)
	h := &fakeHome{t: t, fields: v.Exchange.HTTP, setupToken: "setup-token-1", held: map[string]map[string]any{},
		enrolled: map[string]*enrollment{}, taken: map[string]bool{}, pending: map[string]map[string]any{},
		sessions: map[string]string{}, pairings: map[string]*pairing{}}
	for _, call := range v.Exchange.Operations.PairingComplete {
		h.pairFields = append(h.pairFields, call.Args)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /device/enrollment/challenge", h.challengeEntry(false))
	mux.HandleFunc("POST /device/enrollment/complete", h.complete)
	mux.HandleFunc("POST /device/enrollment/resume", h.resumeEntry)
	mux.HandleFunc("POST /restore", h.restore)
	mux.HandleFunc("POST /restore/kit/challenge", h.kitChallenge)
	mux.HandleFunc("POST /restore/kit", h.kitProof)
	mux.HandleFunc("POST /restore/kit/reenable", h.kitReenable)
	mux.HandleFunc("/device/websocket", h.channel)
	mux.HandleFunc("POST /device/session", h.deviceSession)
	h.pin = newPINHome(h, mux)
	h.srv = httptest.NewServer(mux)
	t.Cleanup(h.srv.Close)
	t.Cleanup(func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		for _, s := range h.shapes {
			t.Errorf("an entry's fields are not the fixture's: %s", s)
		}
	})
	return h
}

func (h *fakeHome) address() string { return h.srv.URL }

func (h *fakeHome) body(r *http.Request) map[string]any {
	raw, _ := io.ReadAll(r.Body)
	h.mu.Lock()
	h.received.Write(raw)
	h.received.WriteString(r.Header.Get("Authorization"))
	h.mu.Unlock()
	var m map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&m)
	return m
}

func (h *fakeHome) admitted(r *http.Request, admission string, resume bool) bool {
	switch admission {
	case "setup":
		return r.Header.Get("X-Cyfr-Setup-Token") == h.setupToken
	case "restore":
		if resume {
			return r.Header.Get("Authorization") == "Bearer "+h.restoreToken
		}
		c, err := r.Cookie("restore_session")
		return err == nil && c.Value == "restored"
	case "invitation":
		return h.invitationCode != "" && r.Header.Get("X-Cyfr-Invitation") == h.invitationCode
	case "open":
		return h.openDoor && r.Header.Get("X-Cyfr-Invitation") == "" && r.Header.Get("X-Cyfr-Setup-Token") == ""
	}
	return false
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (h *fakeHome) issue(m map[string]any) map[string]any {
	nonce := b64(random(32))
	c := map[string]any{"protocol": ProofProtocol, "home": h.address(), "nonce": nonce,
		"expires_at": json.Number(strconv.FormatInt(time.Now().Add(time.Minute).UnixMilli(), 10))}
	for k, v := range m {
		c[k] = v
	}
	h.held[nonce] = c
	return c
}

// verify holds proof to the challenge held under its nonce, once: the same
// fields, and a signature by the key it names.
func (h *fakeHome) verify(proof map[string]any, purpose string) (map[string]any, bool) {
	h.t.Helper()
	var held map[string]any
	if purpose == "lock" {
		held = without(proof, "sig")
	} else {
		nonce, _ := proof["nonce"].(string)
		held = h.held[nonce]
		delete(h.held, nonce)
	}
	if held == nil || held["purpose"] != purpose {
		return nil, false
	}
	a, _ := Canonical(held)
	b, _ := Canonical(without(proof, "sig"))
	key, _ := unb64(stringOf(proof, "device_key"))
	sig, _ := unb64(stringOf(proof, "sig"))
	if !bytes.Equal(a, b) || len(key) != 32 || !ed25519.Verify(key, b, sig) {
		return nil, false
	}
	return held, true
}

func (h *fakeHome) challengeEntry(resume bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		m := h.body(r)
		h.mu.Lock()
		defer h.mu.Unlock()
		admission, request := stringOf(m, "admission"), stringOf(m, "request_id")
		want := h.fields.Challenge.Request
		if resume {
			want = h.fields.Resume[0].Request
		}
		if !exact(m, want) {
			h.shapes = append(h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
		}
		if !h.admitted(r, admission, resume) {
			reply(w, 401, map[string]any{"error": "invalid_token"})
			return
		}
		if h.recordPath != "" {
			_, err := os.Stat(h.recordPath)
			h.recordAtChallenge = append(h.recordAtChallenge, err == nil)
		}
		e := h.enrolled[request]
		if resume && (e == nil || stringOf(m, "device_key") != b64(e.key)) {
			reply(w, 404, map[string]any{"error": "not_found"})
			return
		}
		athanor, client := "ath_01a09fee-045b-770b-b745-a62792bb8798", "pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f80"+fmt.Sprintf("%02d", len(h.enrolled)+10)
		if e != nil {
			athanor, client = e.athanor, e.client
		}
		reply(w, 200, map[string]any{"challenge": h.issue(map[string]any{"purpose": "enroll", "athanor": athanor,
			"client_id": client, "device_key": stringOf(m, "device_key"), "admission": admission, "request_id": request})})
	}
}

func (h *fakeHome) certificate(e *enrollment) map[string]any {
	now := time.Now().UnixMilli()
	return map[string]any{"protocol": "cyfr-device-cert/v1", "athanor": e.athanor, "client_id": e.client,
		"device_key": b64(e.key), "audience": h.address(), "issuer": h.address(), "not_before": now, "expires_at": now + 3_600_000,
		"subject": map[string]any{"kind": "local", "user_id": "usr_1"}}
}

func (h *fakeHome) complete(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	if h.downComplete {
		h.downComplete = false
		h.mu.Unlock()
		hijackClose(w)
		return
	}
	proof, _ := m["proof"].(map[string]any)
	held, ok := h.verify(proof, "enroll")
	if !exact(m, h.fields.Complete.Request[stringOf(held, "admission")]) {
		h.shapes = append(h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
	}
	if !ok || !h.admitted(r, stringOf(held, "admission"), false) {
		h.mu.Unlock()
		reply(w, 401, map[string]any{"error": "proof_refused"})
		return
	}
	h.completes++
	e := &enrollment{key: mustKey(stringOf(held, "device_key")), admission: stringOf(held, "admission"),
		client: stringOf(held, "client_id"), athanor: stringOf(held, "athanor"), name: m["name"]}
	if e.admission != "restore" {
		e.recovery = &Recovery{AttemptID: "att_1", Code: "CYFR-TEST-RECOVERY-CODE", Identifier: "per_1", Name: stringOf(m, "name")}
	}
	h.enrolled[stringOf(held, "request_id")] = e
	drop := h.dropComplete
	h.dropComplete = false
	h.mu.Unlock()
	if drop {
		hijackClose(w)
		return
	}
	reply(w, 200, map[string]any{"certificate": h.certificate(e), "recovery": e.recovery})
}

func (h *fakeHome) resumeEntry(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	r.Body = io.NopCloser(bytes.NewReader(raw))
	if !bytes.Contains(raw, []byte(`"proof"`)) {
		h.challengeEntry(true)(w, r)
		return
	}
	m := h.body(r)
	h.mu.Lock()
	defer h.mu.Unlock()
	proof, _ := m["proof"].(map[string]any)
	if !exact(m, h.fields.Resume[1].Request) {
		h.shapes = append(h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
	}
	held, ok := h.verify(proof, "enroll")
	e := h.enrolled[stringOf(held, "request_id")]
	if !ok || e == nil || !h.admitted(r, e.admission, true) {
		reply(w, 401, map[string]any{"error": "proof_refused"})
		return
	}
	h.resumes++
	var rec *Recovery
	if !e.saved {
		rec = e.recovery
	}
	reply(w, 200, map[string]any{"certificate": h.certificate(e), "recovery": rec})
}

func (h *fakeHome) restore(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	h.restores++
	h.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+h.restoreToken || h.restoreToken == "" {
		reply(w, 401, map[string]any{"error": "invalid_token"})
		return
	}
	if stringOf(m, "recovery_code") != "CYFR-RIGHT-CODE" {
		reply(w, 422, map[string]any{"error": "not_a_holder"})
		return
	}
	http.SetCookie(w, &http.Cookie{Name: "restore_session", Value: "restored", Path: "/", HttpOnly: true})
	reply(w, 200, map[string]any{"status": "completed", "identifier": "per_1"})
}

func mustKey(s string) []byte { k, _ := unb64(s); return k }

func hijackClose(w http.ResponseWriter) {
	conn, _, err := w.(http.Hijacker).Hijack()
	if err == nil {
		conn.Close()
	}
}

// channel is the device channel: connect, its challenge and proof, then
// standing; then the intents the shell sends.
func (h *fakeHome) channel(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	h.mu.Lock()
	h.conns = append(h.conns, conn)
	h.mu.Unlock()
	ctx := context.Background()
	read := func() map[string]any {
		_, raw, err := conn.Read(ctx)
		if err != nil {
			return nil
		}
		h.mu.Lock()
		h.received.Write(raw)
		h.mu.Unlock()
		var m map[string]any
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		_ = dec.Decode(&m)
		return m
	}
	send := func(m map[string]any) {
		m["protocol"] = DeviceProtocol
		raw, _ := json.Marshal(m)
		_ = conn.Write(ctx, websocket.MessageText, raw)
	}
	m := read()
	if m == nil || m["type"] != "connect" {
		conn.Close(4400, "unauthenticated")
		return
	}
	cert, _ := m["certificate"].(map[string]any)
	h.mu.Lock()
	code := h.closeWith
	c := h.issue(map[string]any{"purpose": "connect", "athanor": cert["athanor"], "client_id": cert["client_id"], "device_key": cert["device_key"]})
	h.mu.Unlock()
	if code != 0 {
		conn.Close(code, "refused")
		return
	}
	send(map[string]any{"type": "challenge", "challenge": c})
	m = read()
	h.mu.Lock()
	proof, _ := m["proof"].(map[string]any)
	_, ok := h.verify(proof, "connect")
	h.mu.Unlock()
	if !ok {
		conn.Close(4401, "unauthenticated")
		return
	}
	binding := map[string]any{"athanor": cert["athanor"], "client_id": cert["client_id"], "device_key": cert["device_key"]}
	send(map[string]any{"type": "standing", "client_id": cert["client_id"], "athanor": cert["athanor"], "expires_at": cert["expires_at"]})
	for {
		h.mu.Lock()
		stalled := h.stalled
		h.mu.Unlock()
		if stalled != nil {
			// A link the network silently drops: the connection stays open
			// and nothing is read, so no pong answers the shell's ping.
			<-stalled
			return
		}
		m := read()
		if m == nil {
			return
		}
		switch m["type"] {
		case "capabilities":
			var caps []string
			for _, c := range m["capabilities"].([]any) {
				caps = append(caps, c.(string))
			}
			h.mu.Lock()
			h.capabilities = append(h.capabilities, caps)
			h.mu.Unlock()
		case "intent":
			result, refusal := h.intent(stringOf(m, "operation"), m["args"].(map[string]any), binding)
			answer := map[string]any{"type": "answer", "id": m["id"]}
			if refusal != nil {
				answer["error"] = refusal
			} else {
				answer["result"] = result
			}
			send(answer)
		}
	}
}

func (h *fakeHome) intent(op string, args, binding map[string]any) (any, any) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ops = append(h.ops, op)
	bound := func(purpose string, extra map[string]any) map[string]any {
		m := map[string]any{"purpose": purpose}
		for k, v := range binding {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return h.issue(m)
	}
	switch op {
	case "session.unlock":
		if proof, ok := args["proof"].(map[string]any); ok {
			held, ok := h.verify(proof, "unlock")
			if !ok {
				return nil, map[string]any{"class": "unauthenticated"}
			}
			return map[string]any{"ticket": "TICKET-" + stringOf(held, "session_id"), "session_id": held["session_id"], "expires_at": 1}, nil
		}
		h.unlockSeq++
		return map[string]any{"challenge": bound("unlock", map[string]any{"session_id": "ses_" + strconv.Itoa(h.unlockSeq)})}, nil
	case "session.lock":
		proof, _ := args["proof"].(map[string]any)
		if held, ok := h.verify(proof, "lock"); ok && held["client_id"] == binding["client_id"] {
			h.locked = append(h.locked, stringOf(held, "session_id"))
			return map[string]any{"locked": true}, nil
		}
		return nil, map[string]any{"class": "unauthenticated"}
	case "registry.register":
		if h.registryDown > 0 {
			h.registryDown--
			// As the device channel answers a refusal: its class and
			// sentence, no reason.
			return nil, map[string]any{"class": "unavailable", "message": "cyfr.run did not answer. Try again."}
		}
		name, _ := args["name"].(string)
		if name == "" {
			for _, e := range h.enrolled {
				name = e.recovery.Name
			}
		}
		if h.taken[name] {
			return nil, map[string]any{"class": "conflict", "reason": "name_taken"}
		}
		return map[string]any{"name": name}, nil
	case "person.recovery_code_saved":
		for _, e := range h.enrolled {
			if e.recovery != nil && e.recovery.AttemptID == args["attempt_id"] {
				e.saved = true
				return map[string]any{"attempt_id": e.recovery.AttemptID, "phase": "completed"}, nil
			}
		}
		return nil, map[string]any{"class": "not_found"}
	case "confirmation.pending":
		ref, _ := args["request"].(string)
		rec := h.pending[ref]
		if rec == nil {
			return map[string]any{"confirmations": []any{}}, nil
		}
		digest, _ := Digest(rec)
		entry := map[string]any{"ref": ref, "operation": rec["operation"], "preview": rec["preview"],
			"asker": map[string]any{"name": "Prism"}, "challenge": bound("confirm", map[string]any{"ref": ref, "digest": digest})}
		return map[string]any{"confirmations": []any{entry}}, nil
	case "confirmation.confirm":
		proof, _ := args["device_proof"].(map[string]any)
		held, ok := h.verify(proof, "confirm")
		if !ok || held["ref"] != args["ref"] {
			return nil, map[string]any{"class": "unauthenticated", "message": "That proof does not confirm this change"}
		}
		h.confirmed = append(h.confirmed, held)
		return map[string]any{"ref": args["ref"], "state": "confirmed"}, nil
	}
	return nil, map[string]any{"class": "unknown"}
}

// closeChannels closes every open channel with code, as the home ends a
// client's standing.
// stall makes every open channel stop reading without closing, as a link
// the network drops does; the handlers return when the test ends.
func (h *fakeHome) stall(t *testing.T) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.stalled == nil {
		h.stalled = make(chan struct{})
		stalled := h.stalled
		t.Cleanup(func() { close(stalled) })
	}
}

func (h *fakeHome) closeChannels(code websocket.StatusCode) {
	h.mu.Lock()
	conns := h.conns
	h.conns = nil
	h.mu.Unlock()
	for _, c := range conns {
		c.Close(code, "standing ended")
	}
}

// heard is whether the home received s anywhere: a body, a header it
// reads, or a frame.
func (h *fakeHome) heard(s string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return strings.Contains(h.received.String(), s)
}

func (h *fakeHome) opsSeen() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.ops...)
}

func (h *fakeHome) kitChallenge(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.kitPublic == nil {
		reply(w, 404, map[string]any{"error": "not_recovering"})
		return
	}
	c := b64(random(32))
	if h.kitHeld == nil {
		h.kitHeld = map[string]string{}
	}
	h.kitHeld[c] = stringOf(m, "identifier")
	reply(w, 200, map[string]any{"challenge": c, "restore_id": "rst_1", "expires_at": 1})
}

func (h *fakeHome) kitProof(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	defer h.mu.Unlock()
	proof, _ := m["proof"].(map[string]any)
	c := stringOf(proof, "challenge")
	id, held := h.kitHeld[c]
	delete(h.kitHeld, c)
	msg, _ := Canonical(without(proof, "sig"))
	sig, _ := unb64(stringOf(proof, "sig"))
	if !held || id != stringOf(proof, "identifier") || proof["protocol"] != kitProtocol || !ed25519.Verify(h.kitPublic, msg, sig) {
		reply(w, 409, map[string]any{"error": "not_a_holder"})
		return
	}
	reply(w, 200, map[string]any{"credential": "cred_1", "expires_at": 1})
}

func (h *fakeHome) kitReenable(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	defer h.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer cred_1" || m["operation"] != "pairing.reenable" {
		reply(w, 401, map[string]any{"error": "invalid_credential"})
		return
	}
	h.reenabled = append(h.reenabled, stringOf(m, "client_id"))
	h.pin.reauthorize(stringOf(m, "client_id"))
	h.closeWith = 0
	reply(w, 200, map[string]any{"reenabled": m["client_id"]})
}

// deviceSession is POST /device/session: the unlock's ticket spent once
// for the session's bearer, with no cookie and no CSRF.
func (h *fakeHome) deviceSession(w http.ResponseWriter, r *http.Request) {
	m := h.body(r)
	h.mu.Lock()
	defer h.mu.Unlock()
	if !exact(m, h.fields.DeviceSession.Request) {
		h.shapes = append(h.shapes, fmt.Sprintf("%s %v", r.URL.Path, m))
	}
	ticket := stringOf(m, "ticket")
	if _, spent := h.sessions[ticket]; spent || !strings.HasPrefix(ticket, "TICKET-") || r.Header.Get("Cookie") != "" {
		reply(w, 403, map[string]any{"error": "ticket_refused"})
		return
	}
	h.sessions[ticket] = "TOKEN-" + strings.TrimPrefix(ticket, "TICKET-")
	reply(w, 200, map[string]any{"session_token": h.sessions[ticket], "expires_at": time.Now().Add(time.Minute).UnixMilli()})
}

// invite opens a pairing for key digest, as a confirmed addition does,
// and answers its secret.
func (h *fakeHome) invite(digest string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	secret := b64(random(16))
	h.pairings[secret] = &pairing{digest: digest, athanor: "ath_01a09fee-045b-770b-b745-a62792bb8798",
		client: fmt.Sprintf("pcl_01a09fee-7c1d-7e2f-8a3b-4c5d6e7f80%02d", len(h.pairings)+50)}
	return secret
}

// pair is pairing.complete, as the command line's anonymous client asks
// it: the pair challenge for the invitation's key, then the proof, which
// commits the client; a repeat with the same secret and key after it
// committed answers that client again, any other key is refused.
func (h *fakeHome) pair(_ context.Context, args map[string]any) (map[string]any, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.pairArgs = append(h.pairArgs, args)
	_, proven := args["proof"]
	want := h.pairFields[0]
	if proven {
		want = h.pairFields[1]
	}
	if !exact(args, want) {
		h.shapes = append(h.shapes, fmt.Sprintf("pairing.complete %v", args))
	}
	p := h.pairings[stringOf(args, "invitation_secret")]
	key := mustKey(stringOf(args, "device_key"))
	if p == nil || KeyDigest(key) != p.digest || stringOf(args, "key_digest") != p.digest ||
		(p.committed != nil && !bytes.Equal(p.committed, key)) {
		return nil, fmt.Errorf("That pairing code is not valid")
	}
	if kind := stringOf(args, "holder_kind"); kind != "chip" && kind != "software" {
		return nil, fmt.Errorf("A protected device names its holder")
	}
	if !proven {
		return map[string]any{"challenge": h.issue(map[string]any{"purpose": "pair", "athanor": p.athanor,
			"client_id": p.client, "device_key": stringOf(args, "device_key")})}, nil
	}
	proof, _ := args["proof"].(map[string]any)
	if _, ok := h.verify(proof, "pair"); !ok {
		return nil, fmt.Errorf("That proof does not pair this device")
	}
	p.committed = key
	if h.dropPair {
		h.dropPair = false
		return nil, fmt.Errorf("%w (the answer was lost)", ErrUnavailable)
	}
	e := &enrollment{key: key, client: p.client, athanor: p.athanor}
	return map[string]any{"client_id": p.client, "certificate": h.certificate(e)}, nil
}
