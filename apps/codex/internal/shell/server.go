// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"html/template"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/setup"
)

// Listen is the shell's one listener: literal loopback, never a name, so
// no other host's resolution reaches it. Prism's Lock posts to it, and its
// Confirm on this device opens /confirm?ref= in a window of its own
// (tests/fixtures/device_unlock.json, exchange.shell).
const Listen = "127.0.0.1:7340"

// Origin is the shell's own pages' origin.
const Origin = "http://" + Listen

// Server serves the shell's pages to this box's Chrome.
//
// Every request must name the listener exactly as its Host (a DNS
// rebinding names another), and every POST must come from the shell's own
// pages' Origin, or for Lock from the home's own Prism Origin, with a form
// body. A top-level navigation only opens a page: GET /confirm?ref= reads
// that confirmation from the home over the channel and draws it, which
// authorizes nothing; no GET changes anything. Every page is no-store under
// a policy that runs no script but the two fixed ones below, loads nothing,
// submits forms only here and to the home, is framed by nothing and sends
// no referrer to another origin. The shell signs nothing a page sends: it
// signs only the challenges it fetched itself, after the PIN.
type Server struct {
	Shell *Shell
	// Reachable is whether the home answers now; the pages wait while it
	// does not.
	Reachable func() bool
}

// The two scripts the pages run, each allowed by its hash alone: printing
// the recovery code, and closing a confirmation's window once answered.
const (
	printScript = `document.getElementById("print").addEventListener("click",()=>print())`
	closeScript = `setTimeout(()=>window.close(),4000)`
)

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

func (srv *Server) policy() string {
	return "default-src 'none'; script-src " + hash(printScript) + " " + hash(closeScript) +
		"; style-src " + hash(style) + "; img-src data:; form-action 'self' " + srv.homeOrigin() +
		"; frame-ancestors 'none'; base-uri 'none'"
}

func (srv *Server) homeOrigin() string {
	u, err := url.Parse(srv.Shell.cfg.Address)
	if err != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host
}

// ServeHTTP admits a request by its Host, method and Origin, then serves
// its page.
func (srv *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	// same-origin, not no-referrer: under no-referrer Chrome sends the
	// pages' own form POSTs with Origin: null, which the shell refuses; under
	// same-origin no referrer reaches the home, the ticket's redirect
	// included, and the pages' POSTs keep their Origin.
	h.Set("Referrer-Policy", "same-origin")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", srv.policy())
	if r.Host != Listen {
		http.Error(w, "not this shell's address", http.StatusMisdirectedRequest)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/" {
		srv.page(w, srv.Shell.View(), "")
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/confirm" {
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		srv.Shell.Draw(ctx, r.URL.Query().Get("ref"))
		srv.page(w, srv.Shell.View(), "")
		return
	}
	action, ok := actions[r.URL.Path]
	if !ok || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	origin := r.Header.Get("Origin")
	if origin != Origin && !(action.prism && origin == srv.homeOrigin() && origin != "") {
		http.Error(w, "not from this screen's pages", http.StatusForbidden)
		return
	}
	if mt := r.Header.Get("Content-Type"); !strings.HasPrefix(mt, "application/x-www-form-urlencoded") {
		http.Error(w, "a form is expected", http.StatusUnsupportedMediaType)
		return
	}
	form, err := readForm(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil {
		http.Error(w, "a form is expected", http.StatusBadRequest)
		return
	}
	defer form.erase()
	srv.Shell.begin()
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	action.run(ctx, srv, w, r, form)
}

// An action is one POST: whether Prism's own pages may send it, and what
// it does.
type action struct {
	prism bool
	run   func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form)
}

var actions = map[string]action{
	"/setup": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Setup(ctx, string(f.get("name")), f.get("secret"), f.get("again"))
		srv.onward(ctx, w, r)
	}},
	"/restore": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Restore(ctx, string(f.get("code")), f.get("secret"), f.get("again"))
		srv.onward(ctx, w, r)
	}},
	"/finish": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Finish(ctx, string(f.get("name")), string(f.get("code")), f.get("secret"))
		srv.onward(ctx, w, r)
	}},
	"/unlock": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Unlock(ctx, f.get("secret"))
		srv.onward(ctx, w, r)
	}},
	"/kit": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Reenable(ctx, string(f.get("code")), f.get("secret"))
		srv.onward(ctx, w, r)
	}},
	"/name": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Rename(ctx, string(f.get("name")))
		srv.onward(ctx, w, r)
	}},
	"/saved": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Saved(ctx)
		srv.onward(ctx, w, r)
	}},
	"/open": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.onward(ctx, w, r)
	}},
	"/lock": {prism: true, run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Lock("Locked.")
		http.Redirect(w, r, "/", http.StatusSeeOther)
	}},
	"/confirm/decide": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Decide(ctx, string(f.get("ref")), string(f.get("decision")) == "confirm", f.get("secret"))
		v := srv.Shell.View()
		if v.Page == PageConfirm {
			srv.page(w, v, "")
			return
		}
		srv.page(w, v, "answered")
	}},
}

// onward is where a page goes after its action: into Prism through the
// home's ticket once the box is unlocked and set up, else back to the
// shell's page, which says what happened.
func (srv *Server) onward(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	if srv.Shell.View().Page == PageUnlocked {
		to, err := srv.Shell.Ticket(ctx)
		if err == nil {
			// The ticket travels in the fragment of a redirect: no request
			// carries it, and the same-origin policy keeps this page's
			// address out of the home's.
			w.Header().Set("Location", to)
			w.WriteHeader(http.StatusSeeOther)
			return
		}
		srv.Shell.mu.Lock()
		srv.Shell.say("%s", sentence(err))
		srv.Shell.mu.Unlock()
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

type pageData struct {
	View
	Waiting bool
	Answer  string
	Warn    []string
	QR      template.HTML
	Digits  bool
	Print   template.JS
	Close   template.JS
	Fields  [][2]string
}

func (srv *Server) page(w http.ResponseWriter, v View, answer string) {
	d := pageData{View: v, Answer: answer, Print: template.JS(printScript), Close: template.JS(closeScript)}
	d.Digits = v.Kind == holder.KindChip || (v.Kind == "" && v.Chip && v.Passphrase == "")
	if (v.Page == PageSetup || v.Page == PageRestore || v.Page == PageLocked) && srv.Reachable != nil && !srv.Reachable() {
		d.Waiting = true
	}
	d.Warn = warnings(v.Storage)
	if v.Recovery != nil {
		if qr, err := setup.QRSVG(v.Recovery.Code); err == nil {
			d.QR = template.HTML(qr)
		}
	}
	if v.Confirm != nil {
		for _, k := range slices.Sorted(maps.Keys(v.Confirm.Preview)) {
			d.Fields = append(d.Fields, [2]string{k, display(v.Confirm.Preview[k])})
		}
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_ = pages.Execute(w, d)
}

// warnings are the sentences D3 shows for each volume that is not
// encrypted, or whose protection could not be determined; never a claim
// of encryption it did not find.
func warnings(r disk.Report) []string {
	var out []string
	for _, v := range []struct {
		name  string
		state disk.State
	}{{"system disk", r.Root}, {"CYFR data volume", r.Data}} {
		switch v.state {
		case disk.Unencrypted:
			out = append(out, "This box keeps its data unencrypted, whoever takes it reads everything: its "+v.name+" is not encrypted.")
		case disk.Unknown:
			out = append(out, "Whether this box's "+v.name+" is encrypted could not be determined.")
		}
	}
	return out
}

func display(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case nil:
		return ""
	}
	raw, _ := Canonical(v)
	return string(raw)
}

// form is a POST body's fields as bytes, so the secret ones can be erased
// once used.
type form map[string][]byte

func (f form) get(k string) []byte { return f[k] }

func (f form) erase() {
	for _, v := range f {
		clear(v)
	}
}

// readForm parses an urlencoded body into bytes, never strings, so no copy
// of a PIN outlives the request.
func readForm(r io.Reader) (form, error) {
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	defer clear(body)
	f := form{}
	for pair := range strings.SplitSeq(string(body), "&") {
		if pair == "" {
			continue
		}
		k, v, _ := strings.Cut(pair, "=")
		key, err := unescape([]byte(k))
		if err != nil {
			return nil, err
		}
		val, err := unescape([]byte(v))
		if err != nil {
			return nil, err
		}
		if _, dup := f[string(key)]; dup {
			return nil, errors.New("a field given twice")
		}
		f[string(key)] = val
	}
	return f, nil
}

func unescape(s []byte) ([]byte, error) {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '+':
			out = append(out, ' ')
		case '%':
			if i+2 >= len(s) {
				return nil, errors.New("a bad escape")
			}
			n, err := strconv.ParseUint(string(s[i+1:i+3]), 16, 8)
			if err != nil {
				return nil, errors.New("a bad escape")
			}
			out = append(out, byte(n))
			i += 2
		default:
			out = append(out, c)
		}
	}
	return out, nil
}

// Serve serves the pages on Listen until ctx ends.
func (srv *Server) Serve(ctx context.Context) error {
	ln, err := net.Listen("tcp4", Listen)
	if err != nil {
		return err
	}
	hs := &http.Server{Handler: srv, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
	}()
	if err := hs.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
