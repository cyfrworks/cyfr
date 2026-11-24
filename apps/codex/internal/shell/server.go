// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
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
	"sync"
	"time"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/setup"
)

// Listen is the shell's one listener: literal loopback, never a name, so
// no other host's resolution reaches it. Prism's Lock posts to it, and its
// Confirm on this device and its Approve of a passkey a browser asks for
// open /confirm?ref= and /passkey?ref= in a window of their own
// (tests/fixtures/device_unlock.json, exchange.shell).
const Listen = "127.0.0.1:7340"

// Origin is the shell's own pages' origin.
const Origin = "http://" + Listen

// Server serves the shell's pages to this box's screen, the CYFR app.
//
// Every request must name the listener exactly as its Host (a DNS
// rebinding names another), and every POST must come from the shell's own
// pages' Origin, or for Lock from the home's own Prism Origin, with a form
// body. A top-level navigation only opens a page: GET /confirm?ref= reads
// that confirmation from the home over the channel and draws it, and GET
// /passkey?ref= reads that passkey request the same way and draws it with
// the code this shell derives from its key, both of which authorize
// nothing; no GET changes anything. Every page is no-store under
// a policy that runs no script but the three fixed ones below, loads
// nothing, submits forms only here and to the home, is framed by nothing
// and sends no referrer to another origin. The shell signs nothing a page
// sends: it signs only the challenges it fetched itself, after the PIN.
//
// Host and Origin stop only web pages: any program on this machine can
// send both. What acts as the person, a ticket and the recovery code, goes
// only to the page that typed the PIN: the answer to a POST whose PIN
// opens the key (/setup, /create, /unlock) is a page carrying the proof
// that opening issued, which keepScript keeps in sessionStorage, private
// to this origin, port included, and puts in every form's proof field.
// So does what acts with what the shell holds for that page, the held key
// and an account's recovery key, its claim, its acceptance and its name:
// /saved and /name pass through Shell.asPage, and /enroll opens a first
// connection with a held key only for the proof, each checked under the
// shell's one lock where it acts. A typed recovery code is the account's
// own authority only when it derives the recovery key the pending
// attempt's genesis was made with: /resume checks that before it sends
// anything, and only then issues the proof. A drawn confirmation's
// preview goes only to the request naming its reference (GET /confirm,
// /confirm/decide), and a drawn passkey request's code likewise (GET
// /passkey, /passkey/decide), never to a plain read: the window Prism
// opens holds no proof.
// Never a cookie: 127.0.0.1's cookies go to every port on it, so another
// local listener would collect and replay one. A setup's passphrase, the
// secret-to-be on a machine without a chip, is shown only in the answer to
// the request that drew it (/passphrase, or a setup whose chip could not
// keep the PIN): a page read later shows none, so another local program
// learns none it could unlock with.
//
// On a box's screen a request is one of two kinds, the Lock apart. A page
// that shows only what the shell knows never waits: GET /, and /confirm
// and /passkey on a locked device. Every other is an action, bounded by
// its own deadline and cut short by a lock: so is a page whose content is
// CYFR's own record (/confirm and /passkey on an unlocked one), and the
// recovery code's POST.
type Server struct {
	Shell *Shell
	// Reachable is nil once the home answers now, and otherwise why not,
	// set for a box's screen. It is part of what the shell knows, so no
	// page waits for it: each shows what the last reading of it said,
	// "starting" until one said yes, or the sentence of a refusal waiting
	// does not cure (Unbound.Lasting), and starts the next (read) under
	// Work, whose end ends it.
	Reachable func(context.Context) error
	// Work is everything the pages begin for the CYFR of a folder on this
	// computer: each request's context ends with it, and each reading
	// begins under it. ServeOn makes one from its ctx where it is nil.
	Work *Work

	lastMu sync.Mutex
	// answered is what the last finished reading said, lasting its
	// lasting refusal's sentence, and reading whether one is in flight,
	// the one at a time.
	answered, reading bool
	lasting           string
}

// read starts the next reading, unless one is in flight, and answers what
// the last one said. A page that makes an account has the account
// service's terms read in it first, so that a first form shows them.
func (srv *Server) read(page Page) (answered bool, lasting string) {
	srv.lastMu.Lock()
	defer srv.lastMu.Unlock()
	if srv.reading {
		return srv.answered, srv.lasting
	}
	work := srv.Work.Context()
	reading := func() {
		if page == PageSetup || page == PageEnroll {
			ctx, cancel := context.WithTimeout(work, termsWithin)
			srv.Shell.readTerms(ctx)
			cancel()
		}
		err := srv.Reachable(work)
		var unbound *Unbound
		why := ""
		if errors.As(err, &unbound) && unbound.Lasting {
			why = unbound.Sentence
		}
		srv.lastMu.Lock()
		srv.answered, srv.lasting, srv.reading = err == nil, why, false
		srv.lastMu.Unlock()
	}
	// After the Work ended no reading begins, and the pages show the last.
	if srv.Work.Start(work, func() error { go reading(); return nil }) == nil {
		srv.reading = true
	}
	return srv.answered, srv.lasting
}

// termsWithin bounds one reading of the account service's terms.
const termsWithin = 3 * time.Second

// The three scripts the pages run, each allowed by its hash alone:
// printing the recovery code, closing a confirmation's window once
// answered, and keeping the proof: kept from the answer that hands it
// over, put in every form, then on to the ticket that answer carries, or
// the recovery page's code fetched by a POST with it.
const (
	printScript = `document.getElementById("print").addEventListener("click",()=>print())`
	closeScript = `setTimeout(()=>window.close(),4000)`
	keepScript  = `const m=document.querySelector("main").dataset,s=sessionStorage;if(m.proof)s.setItem("proof",m.proof);const p=s.getItem("proof")||"";for(const e of document.getElementsByName("proof"))e.value=p;const r=document.getElementById("reveal");if(m.to)location.replace(m.to);else if(p&&r)r.submit()`
)

func hash(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "'sha256-" + base64.StdEncoding.EncodeToString(sum[:]) + "'"
}

func (srv *Server) policy() string {
	return "default-src 'none'; script-src " + hash(printScript) + " " + hash(closeScript) + " " + hash(keepScript) +
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
	if srv.Work != nil {
		ctx, stop := srv.Work.Join(r.Context())
		defer stop()
		r = r.WithContext(ctx)
	}
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	// same-origin, not no-referrer: under no-referrer the engine sends the
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
	if read, ok := reads[r.URL.Path]; ok && r.Method == http.MethodGet {
		read(srv, w, r)
		return
	}
	action, ok := actions[r.URL.Path]
	if !ok || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	origin := r.Header.Get("Origin")
	if origin != Origin && !(action.prism && origin == srv.homeOrigin() && origin != "") {
		http.Error(w, "not from this device's pages", http.StatusForbidden)
		return
	}
	if mt := r.Header.Get("Content-Type"); !strings.HasPrefix(mt, "application/x-www-form-urlencoded") {
		http.Error(w, "a form is expected", http.StatusUnsupportedMediaType)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	// An action begins here, before its form is read. Prism's Lock is none:
	// beginning would wait for the action it is to cut short.
	if !action.prism {
		var done func()
		ctx, done = srv.Shell.act(ctx)
		defer done()
	}
	form, err := readForm(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil {
		http.Error(w, "a form is expected", http.StatusBadRequest)
		return
	}
	defer form.erase()
	if !action.prism && !srv.Shell.Begin(ctx) {
		srv.gaveUp(ctx, w, r)
		return
	}
	action.run(ctx, srv, w, r, form)
}

// reads are the GETs: each a page that shows only what the shell knows, an
// action, or the Lock.
var reads = map[string]func(srv *Server, w http.ResponseWriter, r *http.Request){
	"/": func(srv *Server, w http.ResponseWriter, r *http.Request) {
		v := srv.Shell.shownView()
		if srv.Reachable == nil && (v.Page == PageSetup || v.Page == PageEnroll) {
			// Reading the account service's configuration changes nothing:
			// it names the terms the page asks to be accepted. A screen's
			// page leaves it to its reading (read).
			ctx, cancel := context.WithTimeout(r.Context(), termsWithin)
			srv.Shell.readTerms(ctx)
			cancel()
			v = srv.Shell.shownView()
		}
		srv.page(w, pageData{View: v, Reveal: true})
	},
	// Prism's Lock is a top-level navigation here, not a form post, since a
	// form from an https Prism to this plain-http loopback meets the engine's
	// insecure-form interstitial. Locking is the one GET that changes
	// anything: it is the safe direction, it ends only the sessions this
	// screen opened, and repeating it is a harmless success.
	"/lock": func(srv *Server, w http.ResponseWriter, r *http.Request) {
		srv.Shell.Lock("Locked.")
		http.Redirect(w, r, "/", http.StatusSeeOther)
	},
	"/confirm": func(srv *Server, w http.ResponseWriter, r *http.Request) {
		if !srv.Shell.Unlocked() {
			srv.pageLocked(w, unlockToConfirm)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		ctx, done := srv.Shell.act(ctx)
		defer done()
		ref := r.URL.Query().Get("ref")
		srv.Shell.Draw(ctx, ref)
		v, ok := srv.Shell.confirmView(ctx, ref)
		if !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		srv.page(w, pageData{View: v})
	},
	"/passkey": func(srv *Server, w http.ResponseWriter, r *http.Request) {
		if !srv.Shell.Unlocked() {
			srv.pageLocked(w, unlockToApprove)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		ctx, done := srv.Shell.act(ctx)
		defer done()
		ref := r.URL.Query().Get("ref")
		srv.Shell.DrawPasskey(ctx, ref)
		v, ok := srv.Shell.passkeyView(ctx, ref)
		if !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		srv.page(w, pageData{View: v})
	},
}

// An action is one POST: whether Prism's own pages may send it, as they
// may its Lock alone, and what it does.
type action struct {
	prism bool
	run   func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form)
}

var actions = map[string]action{
	"/passphrase": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.drawn(ctx, w, r, srv.Shell.drawPassphrase(ctx))
	}},
	"/setup": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		proof, drawn := srv.Shell.setup(ctx, string(f.get("name")), srv.accepted(f), f.get("secret"), f.get("again"))
		if drawn != "" {
			srv.drawn(ctx, w, r, drawn)
			return
		}
		srv.onward(ctx, w, r, f, proof)
	}},
	"/make": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		if drawn := srv.Shell.makeKey(ctx, f.get("secret"), f.get("again")); drawn != "" {
			srv.drawn(ctx, w, r, drawn)
			return
		}
		srv.onward(ctx, w, r, f, "")
	}},
	"/create": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		proof := srv.Shell.createOpened(ctx, string(f.get("name")), srv.accepted(f), f.get("secret"))
		srv.onward(ctx, w, r, f, proof)
	}},
	"/enroll": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.enrollByPage(ctx, string(f.get("name")), enrollWait, f.get("proof"))
		srv.onward(ctx, w, r, f, "")
	}},
	"/saved": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		accepted := srv.accepted(f)
		srv.Shell.asPage(ctx, f.get("proof"), func(ctx context.Context) { srv.Shell.saved(ctx, accepted) })
		srv.onward(ctx, w, r, f, "")
	}},
	"/resume": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.onward(ctx, w, r, f, srv.Shell.resumeByPage(ctx, string(f.get("code"))))
	}},
	// The account's log is read before the key is opened: a key the log
	// no longer lists shows its code again, and
	// the PIN typed is erased unused.
	"/unlock": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.CheckListed(ctx)
		proof := ""
		if v, ok := srv.Shell.pageView(ctx, nil); ok && v.Page == PageLocked && v.Notice == "" {
			proof = srv.Shell.unlock(ctx, f.get("secret"))
		}
		srv.onward(ctx, w, r, f, proof)
	}},
	"/name": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.asPage(ctx, f.get("proof"), func(ctx context.Context) { srv.Shell.rename(ctx, string(f.get("name"))) })
		srv.onward(ctx, w, r, f, "")
	}},
	"/open": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.onward(ctx, w, r, f, "")
	}},
	// The recovery page's code, for the page holding the proof; any other
	// request is shown the page without it, and with no form that would
	// ask again.
	"/recovery": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		v, ok := srv.Shell.pageView(ctx, f.get("proof"))
		if !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		srv.page(w, pageData{View: v})
	}},
	"/lock": {prism: true, run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Lock("Locked.")
		http.Redirect(w, r, "/", http.StatusSeeOther)
	}},
	"/confirm/decide": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		srv.Shell.Decide(ctx, string(f.get("ref")), string(f.get("decision")) == "confirm", f.get("secret"))
		v, ok := srv.Shell.confirmView(ctx, string(f.get("ref")))
		if !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		if v.Page == PageConfirm {
			srv.page(w, pageData{View: v})
			return
		}
		srv.page(w, pageData{View: v, Answer: "answered"})
	}},
	// A request still drawn (a wrong PIN) is shown again; a settled one
	// closes its window; any other says what happened and stays open, so
	// the person reads why nothing was added.
	"/passkey/decide": {run: func(ctx context.Context, srv *Server, w http.ResponseWriter, r *http.Request, f form) {
		ref := string(f.get("ref"))
		settled := srv.Shell.DecidePasskey(ctx, ref, string(f.get("key")), string(f.get("decision")) == "approve", f.get("secret"))
		v, ok := srv.Shell.passkeyView(ctx, ref)
		if !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		switch {
		case v.Passkey != nil:
			srv.page(w, pageData{View: v})
		case settled:
			srv.page(w, pageData{View: v, Answer: "answered"})
		default:
			srv.page(w, pageData{View: v, Answer: "ended"})
		}
	}},
}

// enrollWait is how long one press of "I approved it" waits for the
// account's log to list this box, inside a request's minute.
var enrollWait = 45 * time.Second

// accepted is the version of the terms the page showed, when the person
// ticked their acceptance.
func (srv *Server) accepted(f form) string {
	if string(f.get("accept")) != "yes" {
		return ""
	}
	terms := srv.Shell.shown.Load().terms
	if terms == nil {
		return ""
	}
	return terms.Version
}

// drawn answers the setup page showing the passphrase this request drew,
// the one answer that carries it, or the page, when it drew none.
func (srv *Server) drawn(ctx context.Context, w http.ResponseWriter, r *http.Request, passphrase string) {
	v, ok := srv.Shell.pageView(ctx, nil)
	if !ok || stale(ctx) {
		srv.gaveUp(ctx, w, r)
		return
	}
	if passphrase == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if v.Page != PageSetup {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	v.Passphrase = passphrase
	srv.page(w, pageData{View: v})
}

// onward is where a page goes after its action. Once the box is unlocked
// and set up, a request carrying the current proof goes into Prism through
// the home's ticket. An action whose PIN just opened the key (fresh, its
// proof) answers a page that hands the proof over, with the ticket when
// one was issued and the recovery code when one is shown. Anything else
// goes back to the shell's page, which says what happened.
func (srv *Server) onward(ctx context.Context, w http.ResponseWriter, r *http.Request, f form, fresh string) {
	proof := f.get("proof")
	if fresh != "" {
		proof = []byte(fresh)
	}
	v, ok := srv.Shell.pageView(ctx, proof)
	if !ok {
		srv.gaveUp(ctx, w, r)
		return
	}
	to := ""
	if v.Page == PageUnlocked {
		ticket, err := srv.Shell.Ticket(ctx, proof)
		if stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		switch {
		case err == nil && fresh == "":
			// The ticket travels in the fragment of a redirect: no request
			// carries it, and the same-origin policy keeps this page's
			// address out of the home's.
			w.Header().Set("Location", ticket)
			w.WriteHeader(http.StatusSeeOther)
			return
		case err == nil:
			to = ticket
		case errors.Is(err, errNotTaken):
			srv.gaveUp(ctx, w, r)
			return
		case errors.Is(err, errNoProof):
			srv.Shell.tell(ctx, "Only the page this device was unlocked on opens CYFR: lock it, then unlock it here.")
		default:
			srv.Shell.tell(ctx, srv.Shell.sentence(err))
		}
	}
	if fresh != "" {
		if v, ok = srv.Shell.pageView(ctx, proof); !ok || stale(ctx) {
			srv.gaveUp(ctx, w, r)
			return
		}
		srv.page(w, pageData{View: v, Proof: fresh, To: to})
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// stillBusy is told of a wait for the shell that outlasted its action's
// time before that action's work began (waitedOut), and of nothing else.
const stillBusy = "This device did not get to that in time, because it was busy with what was asked before. Try again in a moment."

// gaveUp answers an action that could not go on. Only that wait is told
// here. Any other goes back to the shell's page, which says what the
// action's own failure said, and of one begun before a lock nothing.
func (srv *Server) gaveUp(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	if stale(ctx) || !waitedOut(ctx) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	v := srv.Shell.shownView()
	v.Notice = stillBusy
	srv.page(w, pageData{View: v})
}

// pageLocked is what a locked device shows where it is asked to confirm or
// approve: only what the shell knows, so it fetches nothing and never waits.
func (srv *Server) pageLocked(w http.ResponseWriter, why string) {
	v := srv.Shell.shownView()
	v.Notice = why
	srv.page(w, pageData{View: v})
}

type pageData struct {
	View
	Waiting bool
	// Lasting is why the home cannot answer until the person acts, said
	// in place of "starting".
	Lasting string
	// Unwatched is why the device may not be unlocked now.
	Unwatched string
	Answer    string
	Warn      []string
	QR        template.HTML
	Digits    bool
	Print     template.JS
	Close     template.JS
	Keep      template.JS
	Fields    [][2]string
	// Proof is the proof this answer hands its page, To the ticket's
	// address it goes on to, and Reveal whether a recovery page without its
	// code asks for it with the proof the page keeps.
	Proof  string
	To     string
	Reveal bool
}

func (srv *Server) page(w http.ResponseWriter, d pageData) {
	v := d.View
	d.Print, d.Close, d.Keep = template.JS(printScript), template.JS(closeScript), template.JS(keepScript)
	d.Digits = v.Kind == holder.KindChip || (v.Kind == "" && v.Chip && !v.Drawn)
	d.Unwatched = srv.Shell.cfg.Unwatched()
	if srv.Reachable != nil && (v.Page == PageSetup || v.Page == PageEnroll || v.Page == PageLocked) {
		answered, lasting := srv.read(v.Page)
		d.Waiting = !answered && v.Page != PageEnroll
		if d.Waiting {
			d.Lasting = lasting
		}
	}
	d.Warn = warnings(v.Storage)
	if srv.Shell.cfg.Warning != nil {
		if warning := srv.Shell.cfg.Warning(); warning != "" {
			d.Warn = append(d.Warn, warning)
		}
	}
	qr := v.RecoveryCode
	if v.Page == PageEnroll {
		qr = v.AddURL
	}
	if qr != "" {
		if svg, err := setup.QRSVG(qr); err == nil {
			d.QR = template.HTML(svg)
		}
	}
	if v.Confirm != nil {
		d.Fields = PreviewFields(v.Confirm.Preview)
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
			out = append(out, "This device keeps its data unencrypted, whoever takes it reads everything: its "+v.name+" is not encrypted. "+
				"Keep this device where only people you trust can reach it, or install its system again with disk encryption turned on.")
		case disk.Unknown:
			out = append(out, "Whether this device's "+v.name+" is encrypted could not be determined.")
		}
	}
	return out
}

// PreviewFields is a confirmation's preview as the shell draws it: each
// field and its value as text, in the fields' order.
func PreviewFields(preview map[string]any) [][2]string {
	var fields [][2]string
	for _, k := range slices.Sorted(maps.Keys(preview)) {
		fields = append(fields, [2]string{k, display(preview[k])})
	}
	return fields
}

func display(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case nil:
		return ""
	case map[string]any:
		parts := make([]string, 0, len(x))
		for _, k := range slices.Sorted(maps.Keys(x)) {
			parts = append(parts, k+": "+display(x[k]))
		}
		return strings.Join(parts, "; ")
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = display(e)
		}
		return strings.Join(parts, ", ")
	}
	raw, _ := json.Marshal(v)
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
	ln, err := ListenLoopback()
	if err != nil {
		return err
	}
	return srv.ServeOn(ctx, ln)
}

// ListenLoopback takes the shell's one listener, Listen, for this process
// alone. It is what cyfr gives the commands that serve the shell.
func ListenLoopback() (net.Listener, error) { return ListenAt(Listen) }

// ListenAt takes address for this process alone: on Windows no other
// socket may bind the same address beside it (exclusiveAddress). A test
// gives those commands an address of its own with it, so that none binds
// Listen, which a CYFR app or a proof on the same machine may hold.
func ListenAt(address string) (net.Listener, error) {
	return (&net.ListenConfig{Control: exclusiveAddress}).Listen(context.Background(), "tcp4", address)
}

// ServeOn serves the pages on ln, the shell's listener, until ctx ends,
// which ends their Work (one of its own where Work is nil) before the
// listener closes.
func (srv *Server) ServeOn(ctx context.Context, ln net.Listener) error {
	if srv.Work == nil {
		srv.Work = NewWork(ctx)
	}
	hs := &http.Server{Handler: srv, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		srv.Work.End()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hs.Shutdown(sctx)
	}()
	if err := hs.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
