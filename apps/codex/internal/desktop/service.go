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
	// Proxy and Resolver are the engine's route to its pages, empty on
	// this computer's own.
	Proxy, Resolver string
	// Answers is nil when that CYFR itself answers now, and otherwise why
	// it is not opened, in a sentence for the person. Asking starts
	// nothing.
	Answers func(context.Context) error
	// Work is everything begun for that CYFR here. It has one holder from
	// the moment it is made until it is ended, with no gap: the one
	// holding a reading ends it on every way out, panics too, by a
	// deferred end, unless it handed the reading on (take). The service
	// takes it as it opens that CYFR, and ends it as it lets go of it,
	// when the CYFR is left or the service ends. A Local that begins
	// nothing has none.
	Work *shell.Work
}

// end ends what was begun for l, unless l was handed on.
func (l *Local) end() {
	if l != nil && l.Work != nil {
		l.Work.End()
	}
}

// take hands l on: its new holder ends it, and l's own end then ends
// nothing.
func (l *Local) take() *Local {
	taken := *l
	l.Work = nil
	return &taken
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
// home, numbered, and waits for that number's home-ready or home-failed;
// only then are the device's pages, and the ticket they hand over, served,
// and only after a home-ready. An answer to any other number is none.
//
// With a CYFR open, a Connect at that CYFR's own address is the press of
// the chooser's passkey way on or its Try again (again), and one at any
// other is refused.
//
// The road the app offers is main's alone to know (it says it in the
// chooser's address, and decides every navigation): cyfr answers every
// chooser alike. Main opens a CYFR committed at its root, and lets go of
// one by leave.
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
	// Tell gives main a message after every one given before it and
	// returns at once, waiting on main for nothing (Writer.Queue): it is
	// the one way to talk to main. Giving one under mu, where its order
	// against the state matters, writes nothing there.
	Tell func(Message)
	// Discover reads a CYFR's directory; account.Discover unless a test
	// replaces it.
	Discover func(ctx context.Context, client *http.Client, home string) (account.Discovered, error)
	// Local reads the CYFR set up in a folder on this computer, asking
	// Docker nothing; nil reads none.
	Local func(project string) (Local, error)
	// Shell adapts a selected CYFR's shell configuration; nil leaves it.
	Shell func(*shell.Config)

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
	// attempts numbers each proposal of this run. ready receives main's
	// answer to current, the one attempt that waits for it, whether it is
	// ready for the CYFR selecting; with none waiting, ready is nil and no
	// answer changes anything.
	attempts  uint64
	current   uint64
	ready     chan bool
	selecting string
	sh        *shell.Shell
	pages     *shell.Server
	// here is the CYFR the device's pages serve when it is one on this
	// computer.
	here *Local
	// committed is the CYFR the device's pages serve, as home named it:
	// every locked names it again.
	committed Message
	// began is whether a Connect began in this run: the CYFR elsewhere
	// remembered is connected by itself once, as the app starts, and
	// never again.
	began bool
	// ended is whether cyfr is ending, which main hears as its end and
	// never as a lock.
	ended bool
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
// Once the service has ended (End) it serves nothing.
func (s *Service) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	ended := s.ended
	s.mu.Unlock()
	if ended {
		http.Error(w, "This CYFR app has ended.", http.StatusServiceUnavailable)
		return
	}
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
	// noticeUncleared is the chooser's sentence for a clear that failed.
	noticeUncleared = "uncleared"
	lockedSentence  = "CYFR locked. Connect again."
	busySentence    = "This app is connecting already. Wait for it to finish."
)

// begin takes the one Connect a time for a request of epoch at home, or
// answers why not: with a CYFR open, only that CYFR's own home is taken.
// run ends at the next lock, and finish must follow.
func (s *Service) begin(ctx context.Context, epoch uint64, home string) (context.Context, *answer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.epoch != epoch:
		return nil, &answer{Error: lockedSentence}
	case s.connecting:
		return nil, &answer{Error: busySentence}
	case s.pages != nil && home != s.committed.Home:
		return nil, &answer{Error: "This app is connected to a CYFR already. Quit it and open it again to connect to another."}
	}
	run, stop := context.WithCancel(ctx)
	s.connecting, s.stop, s.began = true, stop, true
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
		s.ready, s.selecting, s.current = nil, "", 0
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
// Once a CYFR is open, Next is the device's pages. Resume, before any
// Connect of this run, is the remembered CYFR elsewhere, which a chooser
// on the passkey road connects by itself; a folder's is never Resume.
// Notice names a sentence of the chooser's own, the one main's notices
// name.
type answer struct {
	Home    string `json:"home,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	Next    string `json:"next,omitempty"`
	Resume  string `json:"resume,omitempty"`
	Notice  string `json:"notice,omitempty"`
	Error   string `json:"error,omitempty"`
}

// opened is the answer for the CYFR open at home.
func (s *Service) opened(home string) answer {
	return answer{Home: home, Next: "/"}
}

func (s *Service) state(context.Context, uint64, request) answer {
	c, err := s.Clients.Load()
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	s.mu.Lock()
	open, began, home := s.pages != nil, s.began, s.committed.Home
	s.mu.Unlock()
	if open {
		// The CYFR open, which the record may not name: it keeps another's
		// client, or a folder, until this CYFR admitted the device.
		return s.opened(home)
	}
	a := answer{Home: c.Home}
	if !began {
		a.Resume = c.Home
	}
	if c.Project != "" && s.Local != nil {
		// A folder's CYFR fills the field and is never Resume: one press
		// opens it.
		l, err := s.Local(c.Project)
		defer l.end()
		if err != nil {
			a.Error = fmt.Sprintf("The app cannot read the CYFR in %s (%v).", c.Project, err)
		} else {
			a.Home = l.Shell.Address
		}
	}
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
	home, ok := homeOf(req.Address)
	run, refused := s.begin(ctx, epoch, home)
	if refused != nil {
		return *refused
	}
	defer s.finish()
	if a, open := s.again(run, epoch); open {
		return a
	}
	project, l, remembered := s.remembered()
	defer l.end()
	if remembered && l.Shell.Address == home {
		return s.openLocal(run, epoch, project, &l)
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
	run, refused := s.begin(ctx, epoch, "")
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

// again answers a Connect at the CYFR open, which the chooser's passkey
// way on and its Try again press before either loads that CYFR's own page,
// a load that takes the kept sign-in along on no connection of the shell's. A folder's CYFR
// is asked at the press, so that whatever took a stopped one's port is
// given none.
func (s *Service) again(run context.Context, epoch uint64) (answer, bool) {
	s.mu.Lock()
	here, home, open := s.here, s.committed.Home, s.pages != nil
	s.mu.Unlock()
	if !open {
		return answer{}, false
	}
	var err error
	if here != nil {
		err = here.Answers(run)
	}
	switch {
	case !s.live(epoch):
		return answer{Error: lockedSentence}, true
	case err != nil:
		return answer{Home: home, Error: err.Error()}, true
	}
	return s.opened(home), true
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
// the account service its own settings name; the service takes l as it
// opens it (selectHome), and l's holder ends it otherwise.
func (s *Service) openLocal(run context.Context, epoch uint64, project string, l *Local) answer {
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
	return s.selectHome(run, epoch, sel, l.Shell, l,
		Message{Type: TypeHome, Home: home, Account: found.Origin, Proxy: l.Proxy, Resolver: l.Resolver})
}

// selectRemote selects the CYFR elsewhere at home, with the account
// service found for it, approved in this selection or not.
func (s *Service) selectRemote(run context.Context, epoch uint64, home string, found account.Discovered, approved bool) answer {
	sel, err := s.Clients.Select(home, found.Directory, approved)
	if err != nil {
		return answer{Error: "This computer's CYFR record could not be read (" + err.Error() + ")."}
	}
	return s.selectHome(run, epoch, sel, shell.Config{Address: home, Client: s.Client, Directory: found.Directory, Detect: remoteDisks}, nil,
		Message{Type: TypeHome, Home: home, Account: found.Origin})
}

// selectHome makes the device's shell at the CYFR cfg reaches, over the
// selection (shell.Selection), and tells main proposal, its home; once
// main answers home-ready for it, the selection is remembered, main is
// told opened and the device's pages are served, under l's Work where the
// CYFR is a folder's on this computer (l): the service takes l as it
// publishes the pages, before main is told opened, and an ended service
// takes nothing. Each step that publishes does so under s.mu while the
// epoch it arrived in still runs, so a lock ends it unopened, and gives
// main its message there, to the queue (Tell): a lock's locked, given
// after it moved the epoch on, follows it, and nothing waits on main
// under s.mu.
func (s *Service) selectHome(run context.Context, epoch uint64, sel *shell.Selection, cfg shell.Config, l *Local, proposal Message) answer {
	home := proposal.Home
	cfg.DisplayName, cfg.Record, cfg.Clients, cfg.Restart = s.DisplayName, s.Record, sel, s.sayLocked
	if s.Shell != nil {
		s.Shell(&cfg)
	}
	sh, err := shell.New(cfg)
	if err != nil {
		return answer{Error: err.Error()}
	}
	ready := make(chan bool, 1)
	s.mu.Lock()
	if s.epoch != epoch {
		s.mu.Unlock()
		return answer{Error: lockedSentence}
	}
	s.attempts++
	proposal.Attempt = s.attempts
	s.ready, s.selecting, s.current = ready, home, s.attempts
	s.Tell(proposal)
	s.mu.Unlock()
	select {
	case ok := <-ready:
		if !ok {
			return answer{Home: home, Notice: noticeUncleared}
		}
	case <-run.Done():
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: "The app did not get ready to open " + home + ". Connect again."}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.epoch != epoch || s.ended {
		return answer{Error: lockedSentence}
	}
	if err := sel.Commit(); err != nil {
		return answer{Error: "This computer could not remember the CYFR (" + err.Error() + ")."}
	}
	var work *shell.Work
	if l != nil {
		s.here = l.take()
		work = s.here.Work
	}
	s.sh, s.pages = sh, &shell.Server{Shell: sh, Work: work}
	s.Tell(Message{Type: TypeOpened, Home: home})
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

// HomeReady is main's home-ready for an attempt at home: the one waiting,
// or nothing.
func (s *Service) HomeReady(home string, attempt uint64) { s.answered(home, attempt, true) }

// HomeFailed is main's home-failed for an attempt at home: the one waiting
// ends unopened, with no lock, or nothing.
func (s *Service) HomeFailed(home string, attempt uint64) { s.answered(home, attempt, false) }

func (s *Service) answered(home string, attempt uint64, ready bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ready != nil && s.pages == nil && attempt == s.current && home == s.selecting {
		select {
		case s.ready <- ready:
		default:
		}
	}
}

// Lock locks the device in whatever state it is and says so to main:
// the shell erases its key and every proof a page holds, open channel or
// not, and the time since the last lock ends, so every chooser request
// begun in it, in discovery, awaiting approval or awaiting main's
// home-ready, publishes nothing more.
func (s *Service) Lock(why string) { s.lock(why, false) }

// End locks as cyfr ends, whatever ends it, and says nothing to main,
// which hears the end itself: an end is no lock of the person's, and main
// forgets a sign-in at none.
func (s *Service) End() {
	s.mu.Lock()
	s.ended = true
	s.mu.Unlock()
	s.lock("", false)
}

// lock is Lock, which lets go of the CYFR open as well when leave says to
// (main's leave): the client record stays as it is until the next CYFR is
// opened (shell.Selection).
func (s *Service) lock(why string, leave bool) {
	s.mu.Lock()
	sh, here, letGo := s.sh, s.here, leave || s.ended
	if leave {
		s.sh, s.pages, s.here, s.committed = nil, nil, nil, Message{}
	}
	s.epoch++
	if s.stop != nil {
		s.stop()
	}
	s.pending = nil
	if s.pages == nil {
		s.ready, s.selecting, s.current = nil, "", 0
	}
	s.mu.Unlock()
	// Everything begun for the CYFR here ends as the app lets go of it,
	// once the lock's one entry has run (locked, hidden, the CYFR told),
	// and on a panic in it too: the lock holds it from here.
	if letGo {
		defer here.end()
	}
	if sh != nil {
		// The shell says locked as it hides the screen (sayLocked), which
		// every lock does.
		sh.Lock(why)
	} else {
		s.sayLocked()
	}
}

// sayLocked tells main the device locked, naming the CYFR committed.
func (s *Service) sayLocked() {
	s.mu.Lock()
	m, ended := s.committed, s.ended
	s.mu.Unlock()
	if ended {
		return
	}
	m.Type = TypeLocked
	s.Tell(m)
}

// Run reads main's messages from in until shutdown or the end of in,
// which end it (End); a line that is not one of main's messages ends it
// with its refusal.
func (s *Service) Run(in io.Reader) error {
	lines := bufio.NewScanner(in)
	lines.Buffer(make([]byte, 0, 4096), MaxLine+1)
	for lines.Scan() {
		m, err := ReadFromMain(lines.Bytes())
		if err != nil {
			s.End()
			return err
		}
		switch m.Type {
		case TypeHomeReady:
			s.HomeReady(m.Home, m.Attempt)
		case TypeHomeFailed:
			s.HomeFailed(m.Home, m.Attempt)
		case TypeLock:
			s.Lock("Locked.")
		case TypeLeave:
			s.lock("", true)
		case TypeShutdown:
			s.End()
			return nil
		case TypeFolderPicked:
			// No folder is asked for yet; an answer to none is ignored.
		}
	}
	s.End()
	if err := lines.Err(); err != nil {
		return errors.Join(refuse("size"), err)
	}
	return nil
}
