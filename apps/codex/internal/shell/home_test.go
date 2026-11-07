// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/account/accounttest"
)

// fakeHome is a CYFR as the shell meets it, beside the directory and
// registry its people's accounts live at (accounts): the device channel,
// which admits a device by its hello (a sign_in request answered by a key
// the account's log lists, under the setup token, an invitation or its
// door) and connects one under the certificate it issued, verifying every
// proof against the challenge it holds; and the device session's ticket.
// It records every byte it receives, so a test can show no PIN or
// passphrase reached it.
type fakeHome struct {
	t        *testing.T
	srv      *httptest.Server
	accounts *accounttest.Service

	mu         sync.Mutex
	received   bytes.Buffer
	setupToken string
	setupUsed  bool
	// invitationCode admits a new person once; openDoor admits anyone.
	invitationCode string
	openDoor       bool
	members        map[string]bool
	clients        map[string]*fakeClient // by client id
	held           map[string]map[string]any
	requests       map[string]map[string]any // a hello's sign_in request by challenge
	hellos         []map[string]any
	ops            []string
	locked         []string
	confirmed      []map[string]any
	pending        map[string]map[string]any // ref -> record
	asked          map[string]map[string]any // challenge -> the confirm request answered
	capabilities   [][]string
	unlockSeq      int
	conns          []*websocket.Conn
	closeWith      websocket.StatusCode
	stalled        chan struct{}
	sessions       map[string]string // spent ticket -> the session's bearer
	sessionFields  []string
	shapes         []string
	// stale is a certificate this CYFR will not take any more (4408).
	stale func(cert map[string]any) bool
}

// fakeClient is one device admitted here: its key and the certificate it
// connects under now.
type fakeClient struct {
	id, athanor, identifier string
	pub                     []byte
	cert                    map[string]any
	revoked                 bool
}

func newFakeHome(t *testing.T) *fakeHome {
	var v struct {
		Exchange struct {
			HTTP struct {
				DeviceSession struct {
					Request []string `json:"request"`
				} `json:"device_session"`
			} `json:"http"`
		} `json:"exchange"`
	}
	fixture(t, "device_unlock.json", &v)
	h := &fakeHome{t: t, accounts: accounttest.New(t), setupToken: strings.Repeat("ab", 32), members: map[string]bool{},
		clients: map[string]*fakeClient{}, held: map[string]map[string]any{}, requests: map[string]map[string]any{},
		pending: map[string]map[string]any{}, sessions: map[string]string{}, sessionFields: v.Exchange.HTTP.DeviceSession.Request}
	mux := http.NewServeMux()
	mux.HandleFunc("/device/websocket", h.channel)
	mux.HandleFunc("POST /device/session", h.deviceSession)
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

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func randomB64(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b64(b)
}

func (h *fakeHome) issue(m map[string]any) map[string]any {
	nonce := randomB64(32)
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
	a, _ := account.JCS(held)
	b, _ := account.JCS(without(proof, "sig"))
	key, _ := unb64(stringOf(proof, "device_key"))
	sig, _ := unb64(stringOf(proof, "sig"))
	if !bytes.Equal(a, b) || len(key) != 32 || !ed25519.Verify(key, b, sig) {
		return nil, false
	}
	return held, true
}

// certify issues c a new certificate, for a minute.
func (h *fakeHome) certify(c *fakeClient) map[string]any {
	now := time.Now().UnixMilli()
	c.cert = map[string]any{"protocol": CertificateProtocol, "kid": account.Kid(c.pub), "client_id": c.id,
		"identifier": c.identifier, "head": "sha256:" + strings.Repeat("0", 64), "athanor": c.athanor,
		"audience": h.address(), "not_before": json.Number(strconv.FormatInt(now, 10)),
		"expires_at": json.Number(strconv.FormatInt(now+60_000, 10)), "sig": randomB64(64)}
	return c.cert
}

// channel is the device channel: a hello, its sign_in request and the
// device's answer, then the admission; or a connect (or a renewal) under a
// certificate issued here; then its challenge and proof, the standing, and
// the intents the shell sends.
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
	if m != nil && m["type"] == "hello" {
		code := h.hello(m, read, send)
		if code != 0 {
			conn.Close(code, "refused")
			return
		}
		m = read()
	}
	if m == nil || (m["type"] != "connect" && m["type"] != "renew") {
		conn.Close(4400, "unauthenticated")
		return
	}
	purpose := m["type"].(string)
	cert, _ := m["certificate"].(map[string]any)
	h.mu.Lock()
	c := h.clients[stringOf(m, "client_id")]
	code := h.closeWith
	switch {
	case c == nil || c.revoked:
		code = 4403
	case purpose == "connect" && jcsString(cert) != jcsString(c.cert):
		code = 4401
	case purpose == "connect" && h.stale != nil && h.stale(cert):
		code = 4408
	}
	var challenge map[string]any
	if code == 0 {
		challenge = h.issue(map[string]any{"purpose": purpose, "athanor": c.athanor, "client_id": c.id, "device_key": b64(c.pub)})
	}
	h.mu.Unlock()
	if code != 0 {
		conn.Close(code, "refused")
		return
	}
	send(map[string]any{"type": "challenge", "challenge": challenge})
	m = read()
	h.mu.Lock()
	proof, _ := m["proof"].(map[string]any)
	_, ok := h.verify(proof, purpose)
	var renewed map[string]any
	if ok && purpose == "renew" {
		renewed = h.certify(c)
	}
	h.mu.Unlock()
	if !ok {
		conn.Close(4401, "unauthenticated")
		return
	}
	if renewed != nil {
		send(map[string]any{"type": "certificate", "certificate": renewed})
	}
	binding := map[string]any{"athanor": c.athanor, "client_id": c.id, "device_key": b64(c.pub)}
	send(map[string]any{"type": "standing", "client_id": c.id, "athanor": c.athanor, "expires_at": c.cert["expires_at"]})
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
		case "renew":
			h.mu.Lock()
			challenge := h.issue(map[string]any{"purpose": "renew", "athanor": c.athanor, "client_id": c.id, "device_key": b64(c.pub)})
			h.mu.Unlock()
			send(map[string]any{"type": "challenge", "challenge": challenge})
		case "proof":
			h.mu.Lock()
			proof, _ := m["proof"].(map[string]any)
			_, ok := h.verify(proof, "renew")
			var cert map[string]any
			if ok {
				cert = h.certify(c)
			}
			h.mu.Unlock()
			if !ok {
				conn.Close(4401, "unauthenticated")
				return
			}
			send(map[string]any{"type": "certificate", "certificate": cert})
		}
	}
}

// hello answers a hello: a sign_in request held for the key it names,
// which the account's log must list, then the device's answer verified
// over the request's digest, the person admitted (the setup token once, an
// invitation's code once, a member, or the open door), and the client
// paired or certified again. It answers the close code of a refusal.
func (h *fakeHome) hello(m map[string]any, read func() map[string]any, send func(map[string]any)) websocket.StatusCode {
	h.mu.Lock()
	h.hellos = append(h.hellos, m)
	h.mu.Unlock()
	identifier, kid := stringOf(m, "identifier"), stringOf(m, "kid")
	allowed := []string{"type", "protocol", "kid", "identifier", "holder_kind", "display_name", "admission"}
	for k := range m {
		if !contains(allowed, k) {
			return 4400
		}
	}
	if holder := stringOf(m, "holder_kind"); holder != "chip" && holder != "software" {
		return 4400
	}
	log := h.accounts.Log(identifier)
	state, err := account.Walk(log)
	if err != nil {
		return 4401
	}
	key, listed := state.Key(kid)
	if !listed || key.Alg != "ed25519" {
		return 4401
	}
	challenge := randomB64(32)
	request := map[string]any{"protocol": account.SignInProtocol, "purpose": "sign_in", "audience": h.address(),
		"challenge": challenge, "expires_at": time.Now().Add(5 * time.Minute).UnixMilli(), "return": h.address() + "/login"}
	send(map[string]any{"type": "sign_in_request", "request": request})
	answer := read()
	a, _ := answer["answer"].(map[string]any)
	r, _ := account.ReadRequest(request)
	digest, _ := r.Digest()
	sig, _ := unb64(stringOf(a, "sig"))
	if answer["type"] != "sign_in_answer" || a["challenge"] != challenge || a["kid"] != kid || !ed25519.Verify(key.Pub, digest, sig) {
		return 4401
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	admission, _ := m["admission"].(map[string]any)
	switch {
	case admission["setup"] != nil:
		if admission["setup"] != h.setupToken || h.setupUsed {
			return 4403
		}
		h.setupUsed = true
	case admission["invitation"] != nil:
		if h.invitationCode == "" || admission["invitation"] != h.invitationCode {
			// As the CYFR tells a refused hello its sentence before the
			// close (device.json's refused vector).
			send(map[string]any{"type": "refused", "error": map[string]any{"class": "unauthenticated",
				"message": "This invitation can no longer be used. Ask whoever invited you for a new one."}})
			return 4403
		}
		h.invitationCode = ""
	case !h.members[identifier] && !h.openDoor:
		return 4403
	}
	h.members[identifier] = true
	var c *fakeClient
	for _, existing := range h.clients {
		if existing.identifier == identifier && bytes.Equal(existing.pub, key.Pub) && !existing.revoked {
			c = existing
		}
	}
	if c == nil {
		c = &fakeClient{id: fmt.Sprintf("pcl_%d", len(h.clients)+1), athanor: "ath_" + identifier[4:12], identifier: identifier, pub: key.Pub}
		h.clients[c.id] = c
	}
	cert := h.certify(c)
	send(map[string]any{"type": "admitted", "client_id": c.id, "certificate": cert,
		"standing": map[string]any{"client_id": c.id, "athanor": c.athanor, "expires_at": cert["expires_at"]}})
	return 0
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func jcsString(v any) string {
	raw, _ := json.Marshal(v)
	d, _ := account.Decode(raw)
	out, _ := account.JCS(d)
	return string(out)
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
	case "confirmation.pending":
		ref, _ := args["request"].(string)
		rec := h.pending[ref]
		if rec == nil {
			return map[string]any{"confirmations": []any{}}, nil
		}
		entry := map[string]any{"ref": ref, "operation": rec["operation"], "preview": rec["preview"],
			"asker": map[string]any{"name": "Prism"}}
		return map[string]any{"confirmations": []any{entry}}, nil
	case "confirmation.request":
		ref, _ := args["ref"].(string)
		rec := h.pending[ref]
		if rec == nil {
			return nil, map[string]any{"class": "not_found"}
		}
		raw, _ := account.JCS(rec)
		sum := sha256.Sum256(raw)
		challenge := b64([]byte(fmt.Sprintf("%032d", len(h.asked)+1)))
		request := map[string]any{"protocol": account.SignInProtocol, "purpose": "confirm",
			"audience": h.srv.URL, "challenge": challenge, "expires_at": time.Now().Add(time.Minute).UnixMilli(),
			"return": h.srv.URL + "/login", "subject": "sha256:" + hex.EncodeToString(sum[:])}
		if h.asked == nil {
			h.asked = map[string]map[string]any{}
		}
		h.asked[challenge] = map[string]any{"ref": ref, "request": request}
		return map[string]any{"request": request}, nil
	case "confirmation.confirm":
		answer, _ := args["answer"].(map[string]any)
		challenge, _ := answer["challenge"].(string)
		held := h.asked[challenge]
		delete(h.asked, challenge)
		if held == nil || held["ref"] != args["ref"] || !h.answered(held["request"].(map[string]any), answer, binding) {
			return nil, map[string]any{"class": "unauthenticated", "message": "That answer does not confirm this change"}
		}
		h.confirmed = append(h.confirmed, map[string]any{"ref": args["ref"]})
		return map[string]any{"ref": args["ref"], "state": "confirmed"}, nil
	}
	return nil, map[string]any{"class": "unknown"}
}

// answered is whether answer is the device's signature, by the key the
// channel's binding names, over request's digest (Prima.SignIn).
func (h *fakeHome) answered(request, answer, binding map[string]any) bool {
	r, err := account.ReadRequest(request)
	if err != nil {
		return false
	}
	digest, _ := r.Digest()
	key, err := unb64(stringOf(binding, "device_key"))
	if err != nil || len(key) != ed25519.PublicKeySize {
		return false
	}
	sig, err := unb64(stringOf(answer, "sig"))
	if err != nil {
		return false
	}
	return answer["kid"] == account.Kid(key) && ed25519.Verify(ed25519.PublicKey(key), digest, sig)
}

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

// closeChannels closes every open channel with code, as the CYFR ends a
// client's standing.
func (h *fakeHome) closeChannels(code websocket.StatusCode) {
	h.mu.Lock()
	conns := h.conns
	h.conns = nil
	h.mu.Unlock()
	for _, c := range conns {
		c.Close(code, "standing ended")
	}
}

// revoke ends every client's standing here, as a revocation does.
func (h *fakeHome) revoke() {
	h.mu.Lock()
	for _, c := range h.clients {
		c.revoked = true
	}
	h.mu.Unlock()
	h.closeChannels(4403)
}

// heard is whether the CYFR received s anywhere: a body, a header it
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

func (h *fakeHome) hellosSeen() []map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]map[string]any(nil), h.hellos...)
}

// deviceSession is POST /device/session: the unlock's ticket spent once
// for the session's bearer, with no cookie and no CSRF.
func (h *fakeHome) deviceSession(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	h.mu.Lock()
	defer h.mu.Unlock()
	h.received.Write(raw)
	if len(m) != len(h.sessionFields) || (len(h.sessionFields) > 0 && m[h.sessionFields[0]] == nil) {
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

// account makes an account at the CYFR's directory with one device key
// of its own, named name, and answers its identifier, that device's
// private key and the recovery key.
func (h *fakeHome) account(t *testing.T, name string) (string, ed25519.PrivateKey, ed25519.PrivateKey) {
	t.Helper()
	_, dev, _ := ed25519.GenerateKey(nil)
	c, err := account.Directory{URL: h.accounts.URL()}.Config(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	a, _, key, err := account.Begin(c, name, "", dev.Public().(ed25519.PublicKey), time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if err := account.Submit(context.Background(), &a, key, func() int64 { return time.Now().UnixMilli() }, nil,
		func(account.Attempt) error { return nil }); err != nil {
		t.Fatal(err)
	}
	return a.Identifier, dev, key
}

// approve adds pub to identifier's account, signed by dev, a device the
// account lists, as another device of the person's does.
func (h *fakeHome) approve(t *testing.T, identifier string, dev ed25519.PrivateKey, pub []byte) {
	t.Helper()
	err := account.Approve(context.Background(), account.Directory{URL: h.accounts.URL()}, identifier,
		dev.Public().(ed25519.PublicKey), func(m []byte) []byte { return ed25519.Sign(dev, m) }, pub, time.Now().UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
}
