// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package setup serves the pages `cyfr setup` shows on a device's own
// screen before its CYFR starts: the start, then the setup link. The pages
// are plain HTML and a little JavaScript embedded in the program; the run
// they drive is the Session, which is cyfr init's own sequence and cyfr
// up's start.
//
// Only this machine reaches the pages: the listener binds 127.0.0.1, every
// request must name this listener as its Host (no other name resolving to
// loopback, as a DNS rebinding makes one), every /api request carries the
// run's token, which only the address the program prints holds (in its
// fragment, which no request carries), and every POST comes from the
// pages' own origin with a JSON body.
package setup

import (
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
)

// The phases of a run, as State.Phase names them.
const (
	// PhaseReady is before the start: the pages show their welcome.
	PhaseReady = "ready"
	// PhaseRunning is a step of the run under way (State.Step).
	PhaseRunning = "running"
	// PhaseProblem is a step that failed, State.Sentence saying why and
	// State.Offers what the person can choose.
	PhaseProblem = "problem"
	// PhaseDone is CYFR up at State.Address, its setup link State.SetupURL.
	PhaseDone = "done"
	// PhaseFailed is a run that ended without CYFR up, State.Sentence
	// saying why.
	PhaseFailed = "failed"
)

// OfferRetry is a problem's offer, as State.Offers names it and Choose
// takes it: the failed step again.
const OfferRetry = "retry"

// State is where a run stands, as the pages read it.
type State struct {
	Phase string `json:"phase"`
	// Steps are the run's steps in order, and Step the one under way.
	Steps []string `json:"steps,omitempty"`
	Step  string   `json:"step,omitempty"`
	// Sentence is why a step failed, in the command line's words.
	Sentence string   `json:"sentence,omitempty"`
	Offers   []string `json:"offers,omitempty"`
	// Address is CYFR's address once done. SetupURL is its setup link, the
	// setup page at that address with the setup token in its fragment,
	// which sets up CYFR's first person; the pages move the browser there.
	Address  string `json:"address,omitempty"`
	SetupURL string `json:"setup_url,omitempty"`
}

// Final reports whether the run has ended, done or failed.
func (s State) Final() bool { return s.Phase == PhaseDone || s.Phase == PhaseFailed }

// ErrNotNow is the refusal of a request the run's phase does not take.
var ErrNotNow = errors.New("setup is not at that step")

// Session is the run the pages drive. Each method's error is a sentence
// the pages show as it is; one wrapping ErrNotNow is a request the phase
// does not take.
type Session interface {
	State() State
	// Start begins the run.
	Start() error
	// Choose takes one of a problem's offers.
	Choose(offer string) error
}

//go:embed assets
var assets embed.FS

// pages are the files the server serves, by path, with their types.
var pages = map[string]struct{ file, kind string }{
	"/":          {"assets/index.html", "text/html; charset=utf-8"},
	"/setup.js":  {"assets/setup.js", "text/javascript; charset=utf-8"},
	"/setup.css": {"assets/setup.css", "text/css; charset=utf-8"},
	"/logo.png":  {"assets/logo.png", "image/png"},
}

// tokenHeader carries the run's token on every /api request.
const tokenHeader = "X-Cyfr-Setup"

// maxBody bounds a POST's body.
const maxBody = 4096

// NewToken mints a run's token: 32 random bytes, in hexadecimal.
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Listen binds the pages' listener on 127.0.0.1:port, a free port when
// port is 0.
func Listen(port int) (net.Listener, error) {
	return net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
}

// Address is the address the pages are opened at, its fragment the token.
func Address(l net.Listener, token string) string {
	return fmt.Sprintf("http://127.0.0.1:%d/#%s", l.Addr().(*net.TCPAddr).Port, token)
}

// Server serves the pages and their API for one session.
type Server struct {
	session Session
	token   string
	hosts   map[string]bool
	origins map[string]bool

	final     chan struct{}
	finalOnce sync.Once
}

// NewServer serves session's pages on the listener at port, its /api
// requiring token.
func NewServer(session Session, token string, port int) *Server {
	p := strconv.Itoa(port)
	return &Server{
		session: session,
		token:   token,
		hosts:   map[string]bool{"127.0.0.1:" + p: true, "localhost:" + p: true},
		origins: map[string]bool{"http://127.0.0.1:" + p: true, "http://localhost:" + p: true},
		final:   make(chan struct{}),
	}
}

// Final is closed once a page has read the run's end, done or failed, so
// it needs the server no more.
func (s *Server) Final() <-chan struct{} { return s.final }

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cache-Control", "no-store")
	if !s.hosts[r.Host] {
		http.Error(w, "This address does not serve cyfr setup.", http.StatusMisdirectedRequest)
		return
	}
	if page, ok := pages[r.URL.Path]; ok {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "Only GET is served here.", http.StatusMethodNotAllowed)
			return
		}
		data, err := assets.ReadFile(page.file)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		h.Set("Content-Type", page.kind)
		w.Write(data)
		return
	}
	if !s.authorized(r) {
		http.Error(w, "This request does not carry this run's token.", http.StatusForbidden)
		return
	}
	if r.URL.Path == "/api/state" {
		if r.Method != http.MethodGet {
			http.Error(w, "Only GET is served here.", http.StatusMethodNotAllowed)
			return
		}
		s.writeState(w)
		return
	}
	act, ok := s.actions()[r.URL.Path]
	if !ok {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Only POST is served here.", http.StatusMethodNotAllowed)
		return
	}
	if !s.origins[r.Header.Get("Origin")] {
		http.Error(w, "This request does not come from the setup pages.", http.StatusForbidden)
		return
	}
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "The body must be JSON.", http.StatusUnsupportedMediaType)
		return
	}
	var body struct {
		Offer string `json:"offer,omitempty"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil || dec.Decode(&struct{}{}) != io.EOF {
		http.Error(w, "The body is not one JSON object of this request's fields.", http.StatusBadRequest)
		return
	}
	if err := act(body.Offer); err != nil {
		status := http.StatusUnprocessableEntity
		if errors.Is(err, ErrNotNow) {
			status = http.StatusConflict
		}
		writeJSON(w, status, map[string]string{"sentence": err.Error()})
		return
	}
	s.writeState(w)
}

// actions are the POST requests, each taking the fields it reads.
func (s *Server) actions() map[string]func(offer string) error {
	return map[string]func(string) error{
		"/api/start":  func(string) error { return s.session.Start() },
		"/api/choose": s.session.Choose,
	}
}

// authorized reports whether r carries the run's token.
func (s *Server) authorized(r *http.Request) bool {
	got := r.Header.Get(tokenHeader)
	return got != "" && subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) == 1
}

// writeState answers the session's state, and marks the run's end read
// once a final state is answered.
func (s *Server) writeState(w http.ResponseWriter) {
	st := s.session.State()
	writeJSON(w, http.StatusOK, st)
	if st.Final() {
		s.finalOnce.Do(func() { close(s.final) })
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
