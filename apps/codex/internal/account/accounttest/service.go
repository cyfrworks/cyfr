// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package accounttest is a directory and its registry as the command line
// meets them, for tests: /account/config.json, the log's signed writes and
// reads, every write walked from the genesis before it is kept, and the
// handle read, claim and policy acceptance, each request's signature
// checked against the log's keys.
package accounttest

import (
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/cyfr/codex/internal/account"
)

// Service is one directory and its registry at one origin.
type Service struct {
	srv *httptest.Server

	mu       sync.Mutex
	logs     map[string][]any
	handles  map[string]string
	accepted map[string]string
	// Policy is the policy a first claim needs accepted; nil for none.
	Policy *account.Policy
	// Lose is how many writes are kept but answered 503, as an answer
	// lost on the way back.
	Lose int
	// Down answers every request 503.
	Down bool
	// Writes counts the writes kept.
	Writes int
}

// Reserved is the one name the registry keeps from every account, as
// cyfr.run keeps its own: its lookup is not found and its claim refused
// RESERVED.
const Reserved = "admin"

// New starts a service, closed when the test ends.
func New(t *testing.T) *Service {
	s := &Service{logs: map[string][]any{}, handles: map[string]string{}, accepted: map[string]string{}}
	s.srv = httptest.NewServer(http.HandlerFunc(s.serve))
	t.Cleanup(s.srv.Close)
	return s
}

// URL is the service's origin: its directory and its registry.
func (s *Service) URL() string { return s.srv.URL }

func (s *Service) host() string {
	return strings.Split(strings.TrimPrefix(s.srv.URL, "http://"), ":")[0]
}

// Log is identifier's log as kept.
func (s *Service) Log(identifier string) []any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]any(nil), s.logs[identifier]...)
}

// Holder is who holds name, "" for no one.
func (s *Service) Holder(name string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.handles[name]
}

// Hold gives name to identifier, as another account's claim does.
func (s *Service) Hold(name, identifier string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handles[name] = identifier
}

// Accepted is the policy version identifier accepted.
func (s *Service) Accepted(identifier string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accepted[identifier]
}

// Append keeps entry after identifier's head, as another device's write.
func (s *Service) Append(t *testing.T, identifier string, entry map[string]any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	raw, _ := json.Marshal(entry)
	v, _ := account.Decode(raw)
	if _, err := account.Walk(append(append([]any(nil), s.logs[identifier]...), v)); err != nil {
		t.Fatalf("the entry does not extend the log: %v", err)
	}
	s.logs[identifier] = append(s.logs[identifier], v)
}

// State is identifier's log walked.
func (s *Service) State(t *testing.T, identifier string) account.State {
	st, err := account.Walk(s.Log(identifier))
	if err != nil {
		t.Fatalf("walk %s: %v", identifier, err)
	}
	return st
}

func reply(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func refuse(w http.ResponseWriter, status int, code string) {
	reply(w, status, map[string]any{"errors": []any{map[string]any{"code": code, "message": code}}})
}

func (s *Service) serve(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.Down {
		reply(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
		return
	}
	body, _ := io.ReadAll(r.Body)
	path := r.URL.Path
	switch {
	case r.Method == http.MethodGet && path == "/account/config.json":
		var policy any
		if s.Policy != nil {
			policy = map[string]any{"version": s.Policy.Version, "url": s.Policy.URL}
		}
		reply(w, http.StatusOK, map[string]any{"directory": s.srv.URL, "registry": s.srv.URL, "policy": policy})
	case r.Method == http.MethodPost && path == "/directory/v1/register":
		s.write(w, body, "")
	case r.Method == http.MethodPost && strings.HasSuffix(path, "/append"):
		s.write(w, body, strings.TrimSuffix(strings.TrimPrefix(path, "/directory/v1/"), "/append"))
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/directory/v1/"):
		s.read(w, r, strings.TrimPrefix(path, "/directory/v1/"))
	case r.Method == http.MethodGet && strings.HasPrefix(path, "/v1/handles/"):
		name := strings.TrimPrefix(path, "/v1/handles/")
		id, ok := s.handles[name]
		if !ok {
			refuse(w, http.StatusNotFound, "HANDLE_NOT_FOUND")
			return
		}
		reply(w, http.StatusOK, map[string]any{"protocol": "cyfr-handle/v1", "registry": s.host(), "handle": name,
			"identifier": id, "directory": s.srv.URL})
	case r.Method == http.MethodPost && (path == "/v1/namespaces/personal/claim" || path == "/v1/legal/accept"):
		s.registry(w, path, body)
	default:
		http.NotFound(w, r)
	}
}

// write keeps a genesis (identifier "") or an entry after its log's
// head, walked first; the same bytes again are exists.
func (s *Service) write(w http.ResponseWriter, body []byte, identifier string) {
	v, err := account.Decode(body)
	entry, ok := v.(map[string]any)
	if err != nil || !ok {
		reply(w, http.StatusBadRequest, map[string]any{"error": "invalid"})
		return
	}
	hash, _ := account.Hash(entry)
	if identifier == "" {
		st, err := account.Walk([]any{entry})
		if err != nil {
			reply(w, http.StatusUnprocessableEntity, map[string]any{"error": "unverified", "reason": err.Error()})
			return
		}
		identifier = st.Identifier
		if len(s.logs[identifier]) > 0 {
			reply(w, http.StatusOK, map[string]any{"identifier": identifier, "seq": 0, "entry_hash": hash, "result": "exists", "head": s.head(identifier)})
			return
		}
		s.keep(w, identifier, entry, hash, "created")
		return
	}
	log := s.logs[identifier]
	for _, e := range log {
		if h, _ := account.Hash(e.(map[string]any)); h == hash {
			reply(w, http.StatusOK, map[string]any{"identifier": identifier, "entry_hash": hash, "result": "exists", "head": s.head(identifier)})
			return
		}
	}
	if entry["prev"] != s.head(identifier) {
		reply(w, http.StatusConflict, map[string]any{"error": "stale_head", "head": s.head(identifier)})
		return
	}
	if _, err := account.Walk(append(append([]any(nil), log...), entry)); err != nil {
		if ref, ok := err.(*account.Refusal); ok && ref.Reason == "duplicate_key" {
			reply(w, http.StatusConflict, map[string]any{"error": "duplicate_key"})
			return
		}
		reply(w, http.StatusUnprocessableEntity, map[string]any{"error": "unverified", "reason": err.Error()})
		return
	}
	s.keep(w, identifier, entry, hash, "accepted")
}

func (s *Service) keep(w http.ResponseWriter, identifier string, entry map[string]any, hash, result string) {
	s.logs[identifier] = append(s.logs[identifier], entry)
	s.Writes++
	if s.Lose > 0 {
		s.Lose--
		reply(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
		return
	}
	reply(w, http.StatusOK, map[string]any{"identifier": identifier, "seq": len(s.logs[identifier]) - 1, "entry_hash": hash, "result": result})
}

func (s *Service) head(identifier string) string {
	log := s.logs[identifier]
	if len(log) == 0 {
		return ""
	}
	h, _ := account.Hash(log[len(log)-1].(map[string]any))
	return h
}

func (s *Service) read(w http.ResponseWriter, r *http.Request, identifier string) {
	log, ok := s.logs[identifier]
	if !ok {
		reply(w, http.StatusNotFound, map[string]any{"error": "not_found"})
		return
	}
	after, _ := strconv.Atoi(r.URL.Query().Get("after"))
	from := after + 1
	if r.URL.Query().Get("after") == "" {
		from = 0
	}
	entries := []any{}
	if from < len(log) {
		entries = log[from:]
	}
	reply(w, http.StatusOK, map[string]any{"identifier": identifier, "from": from, "next": nil,
		"head": s.head(identifier), "length": len(log), "entries": entries})
}

// registry takes a signed claim or acceptance: the request's signer a key
// or recovery key its account's log lists, its signature over the JCS
// bytes without sig.
func (s *Service) registry(w http.ResponseWriter, path string, body []byte) {
	v, err := account.Decode(body)
	req, ok := v.(map[string]any)
	if err != nil || !ok {
		refuse(w, http.StatusBadRequest, "REQUEST_MALFORMED")
		return
	}
	identifier, _ := req["identifier"].(string)
	st, err := account.Walk(s.logs[identifier])
	if err != nil {
		refuse(w, http.StatusNotFound, "UNKNOWN_IDENTITY")
		return
	}
	signer, _ := req["signer"].(string)
	var pub []byte
	if k, listed := st.Key(signer); listed && k.Alg == "ed25519" {
		pub = k.Pub
	}
	for _, r := range st.Recovery {
		if account.RecoverySigner(r) == signer {
			pub = r
		}
	}
	sig, _ := account.UnB64(req["sig"], 64, 64)
	msg, _ := account.SigningBytes(req)
	if pub == nil || req["registry"] != s.host() || !ed25519.Verify(pub, msg, sig) {
		refuse(w, http.StatusUnauthorized, "BAD_SIGNATURE")
		return
	}
	b, _ := req["body"].(map[string]any)
	if path == "/v1/legal/accept" {
		s.accepted[identifier], _ = b["policy_version"].(string)
		s.Writes++
		reply(w, http.StatusOK, map[string]any{"accepted": true})
		return
	}
	name, _ := b["handle"].(string)
	if name == Reserved {
		refuse(w, http.StatusBadRequest, "RESERVED")
		return
	}
	if s.Policy != nil && s.accepted[identifier] != s.Policy.Version {
		refuse(w, http.StatusForbidden, "POLICY_ACCEPTANCE_REQUIRED")
		return
	}
	if held, taken := s.handles[name]; taken && held != identifier {
		refuse(w, http.StatusConflict, "SLUG_TAKEN")
		return
	}
	s.handles[name] = identifier
	s.Writes++
	if s.Lose > 0 {
		s.Lose--
		reply(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
		return
	}
	reply(w, http.StatusOK, map[string]any{"handle": name})
}
