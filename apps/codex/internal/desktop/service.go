// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package desktop

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/shell"
)

// Local is the CYFR set up in a folder on this computer as one reading of
// that folder names it, from the folder alone: what opens it uses that
// one reading, and Shell's client and Answers are bound to the CYFR it
// names (cmd readLocal).
type Local struct {
	// Shell is what that CYFR's own settings decide of the device's shell
	// there: its address, the client that reaches it, the account service
	// it names, its data directory and its setup capability.
	Shell shell.Config
	// Proxy and Resolver are the route to it, empty on this computer's own.
	Proxy, Resolver string
	// Answers is nil when that CYFR itself answers now, and otherwise why
	// it is not opened, in a sentence for the person. Asking starts
	// nothing.
	Answers func(context.Context) error
}

// Service is what the CYFR app's cyfr serves on the shell's listener: the
// chooser (/bootstrap/) until a CYFR is selected, then the device's pages
// at that CYFR. It selects one CYFR a run.
//
// The chooser's requests are JSON POSTs from the chooser's own page: the
// exact Host and Origin, application/json, and the run token main put in
// the chooser's first address, which no other page and no other program
// was given. The address of the CYFR in the folder the client record
// remembers opens that CYFR (openLocal): the folder's own settings name
// its directory, so nothing is discovered or asked (account.ServiceOf),
// and one that does not answer is named, never started. Any other CYFR's
// address is read as an https origin; its sign-in
// page names its directory (account.Discover). cyfr.run, or the
// directory approved for this CYFR before, goes on at once; any other is
// shown whole beside the CYFR's address and goes on only once the person
// approves it, and a decline contacts nothing there. Selecting sends main
// home and waits for its home-ready; only then are the device's pages,
// and the ticket they hand over, served.
type Service struct {
	// Token is the run token the chooser's requests carry.
	Token string
	// Clients is this user's client record.
	Clients shell.ClientFile
	// Record is this user's device key's record.
	Record string
	// Client reaches the CYFRs and their account services.
	Client *http.Client
	// DisplayName is the name a CYFR lists this device by.
	DisplayName string
	// Send writes a message to main.
	Send func(Message) error
	// Discover reads a CYFR's directory; account.Discover unless a test
	// replaces it.
	Discover func(ctx context.Context, client *http.Client, home string) (account.Discovered, error)
	// Local reads the CYFR set up in a folder on this computer, asking
	// Docker nothing; nil reads none.
	Local func(project string) (Local, error)
	// Shell adapts a selected CYFR's shell configuration; nil leaves it.
	Shell func(*shell.Config)
	// AccountRoad is whether the app signs in with the account's passkey
	// too (macOS and Windows), beside the device's six words.
	AccountRoad bool

	mu sync.Mutex
	// epoch counts locks. A chooser request belongs to the epoch it
	// arrived in, taken before a byte of its body is read, and publishes
	// nothing once a lock has moved it on.
	epoch uint64
	// connecting is whether a Connect (connect or approve) is in flight,
	// and stop ends it: the chooser is one page, so a second is refused.
	connecting bool
	stop       context.CancelFunc
	pending    *selection
	// ready receives main's home-ready for selecting, the CYFR being
	// selected.
	ready     chan struct{}
	selecting string
	sh        *shell.Shell
	pages     *shell.Server
	// here is the CYFR the device's pages serve when it is one on this
	// computer.
	here *Local
	// committed is the CYFR the device's pages serve, as home named it:
	// every locked names it again.
	committed Message
	// warning is what the chooser tells the person this app cannot do
	// here (Warn).
	warning string
}

// Warn has the chooser tell the person, in one sentence, what this app
// cannot do on this computer, such as lock with it.
func (s *Service) Warn(sentence string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.warning = sentence
}

type selection struct {
	home  string
	found account.Discovered
	epoch uint64
}

// NewToken is a run token: 32 random bytes, unpadded base64url.
func NewToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b) // crypto/rand.Read never fails, by its contract.
	return base64.RawURLEncoding.EncodeToString(b)
}

// ReadyURL is the chooser's address main opens first, the token in its
// fragment, which no request carries.
func (s *Service) ReadyURL() string { return shell.Origin + "/bootstrap/#token=" + s.Token }

// ServeHTTP serves the chooser under /bootstrap/ and, once a CYFR is
// selected, the device's pages; before that every other address goes to
// the chooser.
func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/bootstrap/") {
		s.bootstrap(w, r)
		return
	}
	s.mu.Lock()
	pages := s.pages
	s.mu.Unlock()
	if pages != nil {
		pages.ServeHTTP(w, r)
		return
	}
	if r.Host != shell.Listen {
		http.Error(w, "not this app's address", http.StatusMisdirectedRequest)
		return
	}
	http.Redirect(w, r, "/bootstrap/", http.StatusSeeOther)
}

func (s *Service) bootstrap(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	epoch := s.epoch
	s.mu.Unlock()
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Content-Security-Policy", bootstrapPolicy)
	if r.Host != shell.Listen {
		http.Error(w, "not this app's address", http.StatusMisdirectedRequest)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/bootstrap/" {
		h.Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, bootstrapPage)
		return
	}
	act, ok := map[string]func(context.Context, uint64, request) answer{
		"/bootstrap/state":   s.state,
		"/bootstrap/connect": s.connect,
		"/bootstrap/approve": s.approve,
	}[r.URL.Path]
	if !ok || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if r.Header.Get("Origin") != shell.Origin {
		http.Error(w, "not from this app's pages", http.StatusForbidden)
		return
	}
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "JSON is expected", http.StatusUnsupportedMediaType)
		return
	}
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(10 * time.Second))
	var req request
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	dec.DisallowUnknownFields()
	if dec.Decode(&req) != nil || dec.More() {
		http.Error(w, "JSON is expected", http.StatusBadRequest)
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Token), []byte(s.Token)) != 1 {
		http.Error(w, "not this app's page", http.StatusForbidden)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	h.Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(act(ctx, epoch, req))
}

const (
	lockedSentence = "CYFR locked. Connect again."
	busySentence   = "This app is connecting already. Wait for it to finish."
)

// begin takes the one Connect a time for a request of epoch, or answers
// why not; run ends at the next lock, and finish must follow.
func (s *Service) begin(ctx context.Context, epoch uint64) (context.Context, *answer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.epoch != epoch:
		return nil, &answer{Error: lockedSentence}
	case s.connecting:
		return nil, &answer{Error: busySentence}
	case s.pages != nil:
		return nil, &answer{Error: "This app is connected to a CYFR already. Quit it and open it again to connect to another."}
	}
	run, stop := context.WithCancel(ctx)
	s.connecting, s.stop = true, stop
	return run, nil
}

// finish ends the Connect in flight, whatever its exit: unless it opened
// its CYFR, the service takes the next as if it never ran.
func (s *Service) finish() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stop()
	s.connecting, s.stop = false, nil
	if s.pages == nil {
		s.ready, s.selecting = nil, ""
	}
}

// request is a chooser's request: the token, and the address typed or the
// directory approved.
type request struct {
	Token     string `json:"token"`
	Address   string `json:"address,omitempty"`
	Home      string `json:"home,omitempty"`
	Directory string `json:"directory,omitempty"`
}

// answer is what the chooser does next: show a sentence, ask to approve a
// directory for a CYFR, or go to the device's pages.
//
// Once a CYFR is open, Next is the device's pages and, where the app signs
// in with the account's passkey (AccountRoad), Passkey is that CYFR's own
// sign-in page, which the page offers first.
type answer struct {
	Home    string `json:"home,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	Next    string `json:"next,omitempty"`
	Passkey string `json:"passkey,omitempty"`
	Error   string `json:"error,omitempty"`
	// Warning is what this app cannot do on this computer (Warn), which
	// the chooser shows whatever else it shows.
	Warning string `json:"warning,omitempty"`
}

// opened is the answer for the CYFR open at home.
func (s *Service) opened(home string) answer {
	a := answer{Home: home, Next: "/"}
	if s.AccountRoad {
		a.Passkey = home + "/login"
	}
	return a
}

func (s *Service) state(ctx context.Context, _ uint64, _ request) answer {
	c, err := s.Clients.Load()
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	s.mu.Lock()
	open, home, here, warning := s.pages != nil, s.committed.Home, s.here, s.warning
	s.mu.Unlock()
	a := answer{Home: c.Home}
	switch {
	case open:
		// The CYFR open, which the record selects only once it admitted
		// this device.
		a = s.opened(home)
		// The passkey's way on is the CYFR's own page, loaded with no
		// connection of the shell's: it is offered again only while that
		// CYFR still answers. The device's pages ask as they connect.
		if here != nil && a.Passkey != "" && here.Answers(ctx) != nil {
			a.Passkey = ""
		}
	case c.Project != "" && s.Local != nil:
		if l, err := s.Local(c.Project); err != nil {
			a.Error = fmt.Sprintf("The app cannot read the CYFR in %s (%v).", c.Project, err)
		} else {
			a.Home = l.Shell.Address
		}
	}
	a.Warning = warning
	return a
}

// homeOf reads a typed address as a CYFR's origin in its one spelling
// (account.CanonicalHome, as a folder's is read) and whether that is an
// https one, as a CYFR elsewhere must be: a bare name is taken as
// https://name.
func homeOf(address string) (string, bool) {
	a := strings.TrimRight(strings.TrimSpace(address), "/")
	if !strings.Contains(a, "://") {
		a = "https://" + a
	}
	home, ok := account.CanonicalHome(a)
	if !ok {
		return "", false
	}
	return home, strings.HasPrefix(home, "https://")
}

func (s *Service) connect(ctx context.Context, epoch uint64, req request) answer {
	run, refused := s.begin(ctx, epoch)
	if refused != nil {
		return *refused
	}
	defer s.finish()
	home, ok := homeOf(req.Address)
	project, l, remembered := s.remembered()
	if remembered && l.Shell.Address == home {
		return s.openLocal(run, epoch, project, l)
	}
	if !ok {
		if remembered && home != "" {
			// The folder's address changed since the chooser showed it, or
			// another of this computer's was typed.
			return answer{Error: fmt.Sprintf("The CYFR in %s is at %s. Connect to that address.", project, l.Shell.Address)}
		}
		return answer{Error: "Type the CYFR's address, such as https://cyfr.example.com."}
	}
	discover := s.Discover
	if discover == nil {
		discover = account.Discover
	}
	found, err := discover(run, s.Client, home)
	if err != nil {
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: fmt.Sprintf("%s did not answer as a CYFR (%v).", home, err)}
	}
	// An approval stands only while the CYFR names the address approved:
	// naming anything else, cyfr.run included, ends it now, whatever the
	// person or a lock does next.
	if err := s.Clients.EndApproval(home, found.Directory); err != nil {
		return answer{Error: "This computer could not forget the account service it approved before (" + err.Error() + ")."}
	}
	c, err := s.Clients.Load()
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	switch {
	case found.Directory == account.DefaultDirectory:
		return s.selectRemote(run, epoch, home, found, true)
	case c.Home == home && c.Directory == found.Directory:
		return s.selectRemote(run, epoch, home, found, false)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.epoch != epoch {
		return answer{Error: lockedSentence}
	}
	s.pending = &selection{home: home, found: found, epoch: epoch}
	return answer{Home: home, Confirm: found.Directory}
}

func (s *Service) approve(ctx context.Context, epoch uint64, req request) answer {
	run, refused := s.begin(ctx, epoch)
	if refused != nil {
		return *refused
	}
	defer s.finish()
	s.mu.Lock()
	p := s.pending
	s.pending = nil
	s.mu.Unlock()
	if p == nil || p.epoch != epoch || p.home != req.Home || p.found.Directory != req.Directory {
		return answer{Error: "That is not the account service this app asked about. Connect again."}
	}
	return s.selectRemote(run, epoch, p.home, p.found, true)
}

// live is whether no lock came since epoch.
func (s *Service) live(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.epoch == epoch
}

// remembered is the folder the client record selects and the CYFR there,
// when there is one the app can read.
func (s *Service) remembered() (string, Local, bool) {
	c, err := s.Clients.Load()
	if err != nil || c.Project == "" || s.Local == nil {
		return "", Local{}, false
	}
	l, err := s.Local(c.Project)
	return c.Project, l, err == nil
}

// openLocal selects the CYFR l, set up in project on this computer, with
// the account service its own settings name.
func (s *Service) openLocal(run context.Context, epoch uint64, project string, l Local) answer {
	home := l.Shell.Address
	found, ok := account.ServiceOf(home, l.Shell.Directory)
	if !ok {
		return answer{Error: fmt.Sprintf("The CYFR in %s names %s as its account service. The app takes an https address, "+
			"or a plain http one only at a CYFR's own address on this computer.", project, l.Shell.Directory)}
	}
	if err := l.Answers(run); err != nil {
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: err.Error()}
	}
	sel, err := s.Clients.SelectLocal(project)
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	a := s.selectHome(run, epoch, sel, l.Shell,
		Message{Type: TypeHome, Home: home, Account: found.Origin, Proxy: l.Proxy, Resolver: l.Resolver})
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pages != nil {
		s.here = &l
	}
	return a
}

// selectRemote selects the CYFR elsewhere at home, with the account
// service found for it, approved in this selection or not.
func (s *Service) selectRemote(run context.Context, epoch uint64, home string, found account.Discovered, approved bool) answer {
	sel, err := s.Clients.Select(home, found.Directory, approved)
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	return s.selectHome(run, epoch, sel, shell.Config{Address: home, Client: s.Client, Directory: found.Directory, Detect: remoteDisks},
		Message{Type: TypeHome, Home: home, Account: found.Origin})
}

// selectHome makes the device's shell at the CYFR cfg reaches, over the
// selection (shell.Selection), and sends main proposal, its home; once
// main answers home-ready for it, the selection is remembered and the
// device's pages are served. Each step that publishes does so under s.mu while the epoch it
// arrived in still runs, so a lock ends it unopened.
func (s *Service) selectHome(run context.Context, epoch uint64, sel *shell.Selection, cfg shell.Config, proposal Message) answer {
	home := proposal.Home
	cfg.DisplayName, cfg.Record, cfg.Clients, cfg.Restart = s.DisplayName, s.Record, sel, s.sayLocked
	if s.Shell != nil {
		s.Shell(&cfg)
	}
	sh, err := shell.New(cfg)
	if err != nil {
		return answer{Error: err.Error()}
	}
	ready := make(chan struct{}, 1)
	s.mu.Lock()
	if s.epoch != epoch {
		s.mu.Unlock()
		return answer{Error: lockedSentence}
	}
	s.ready, s.selecting = ready, home
	err = s.Send(proposal)
	s.mu.Unlock()
	if err != nil {
		return answer{Error: "The app did not take the CYFR (" + err.Error() + ")."}
	}
	select {
	case <-ready:
	case <-run.Done():
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: "The app did not get ready to open " + home + ". Connect again."}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.epoch != epoch {
		return answer{Error: lockedSentence}
	}
	if err := sel.Commit(); err != nil {
		return answer{Error: "This computer could not remember the CYFR (" + err.Error() + ")."}
	}
	// The device's pages are served only once main was told home opened:
	// a write that failed opens nothing.
	if err := s.Send(Message{Type: TypeOpened, Home: home}); err != nil {
		return answer{Error: "The app did not take the CYFR (" + err.Error() + ")."}
	}
	s.sh, s.pages = sh, &shell.Server{Shell: sh}
	s.committed = proposal
	return s.opened(home)
}

// remoteDisks is what a device of a remote CYFR reports: its own system
// disk, and its CYFR's data, which is elsewhere, as unknown.
func remoteDisks(string) disk.Report {
	r := disk.Detect("/")
	r.Data = disk.Unknown
	return r
}

// HomeReady is main's home-ready for home: the CYFR being selected, or
// nothing.
func (s *Service) HomeReady(home string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ready != nil && s.pages == nil && home == s.selecting {
		select {
		case s.ready <- struct{}{}:
		default:
		}
	}
}

// Lock locks the device in whatever state it is and says so to main:
// the shell erases its key and every proof a page holds, open channel or
// not, and the time since the last lock ends, so every chooser request
// begun in it, in discovery, awaiting approval or awaiting main's
// home-ready, publishes nothing more.
func (s *Service) Lock(why string) {
	s.mu.Lock()
	sh := s.sh
	s.epoch++
	if s.stop != nil {
		s.stop()
	}
	s.pending = nil
	if s.pages == nil {
		s.ready, s.selecting = nil, ""
	}
	s.mu.Unlock()
	if sh != nil {
		wasOpen := sh.Unlocked()
		sh.Lock(why)
		if wasOpen {
			// The shell said locked as it restarted the pages.
			return
		}
	}
	s.sayLocked()
}

// sayLocked tells main the device locked, naming the CYFR committed.
func (s *Service) sayLocked() {
	s.mu.Lock()
	m := s.committed
	s.mu.Unlock()
	m.Type = TypeLocked
	_ = s.Send(m)
}

// Run reads main's messages from in until shutdown or the end of in,
// which lock first; a line that is not one of main's messages locks and
// ends the run with its refusal.
func (s *Service) Run(in io.Reader) error {
	lines := bufio.NewScanner(in)
	lines.Buffer(make([]byte, 0, 4096), MaxLine+1)
	for lines.Scan() {
		m, err := ReadFromMain(lines.Bytes())
		if err != nil {
			s.Lock("")
			return err
		}
		switch m.Type {
		case TypeHomeReady:
			s.HomeReady(m.Home)
		case TypeLock:
			s.Lock("Locked.")
		case TypeShutdown:
			s.Lock("")
			return nil
		case TypeFolderPicked:
			// No folder is asked for yet; an answer to none is ignored.
		}
	}
	s.Lock("")
	if err := lines.Err(); err != nil {
		return errors.Join(refuse("size"), err)
	}
	return nil
}
