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
	// Proxy is the engine's route to its pages, set on that CYFR's own
	// stores alone, empty on this computer's own.
	Proxy string
	// Answers is nil when that CYFR itself answers now, and otherwise why
	// it is not opened, in a sentence for the person. Asking starts
	// nothing.
	Answers func(context.Context) error
	// waits is whether the device's pages at that CYFR wait for it to
	// answer (shell.Server.Reachable), This box's on a box's screen
	// (Service.Box), rather than its open being refused while it does not:
	// the box's own CYFR starts as the box does.
	waits bool
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
// was given. The address of the CYFR in the folder selected last in the
// list opens that CYFR (openLocal): the folder's own settings name
// its directory, so nothing is discovered or asked (account.ServiceOf),
// and one that does not answer is named, never started. Any other CYFR's
// address is read as an https origin; its sign-in
// page names its directory (account.Discover). cyfr.run, or the
// directory approved for this CYFR before, goes on at once; any other is
// shown whole beside the CYFR's address and goes on only once the person
// approves it, and a decline contacts nothing there. Selecting sends main
// home, numbered, and waits for that number's home-ready; only then are
// the device's pages, and the ticket they hand over, served. An answer to
// any other number is none.
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
	// Token is the run token: main alone holds it, and adds it to the
	// chooser's own requests as their RunHeader.
	Token string
	// ReadToken is the rail's: it reads the list of CYFRs (rail.go) and
	// authorizes nothing else.
	ReadToken string
	// Homes is this user's list of CYFRs.
	Homes shell.Homes
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
	// Folder is where CYFR is set up on this computer until the person
	// picks another (FolderPicked): the folder cyfr setup opened the app
	// in, ~/cyfr otherwise.
	Folder string
	// Docker asks whether Docker answers this account on this computer;
	// nil asks nothing.
	Docker func(context.Context) DockerAnswer
	// Setup sets CYFR up in folder and starts it, saying each step it
	// begins; its error is the sentence for the person. nil sets up
	// nothing.
	Setup func(ctx context.Context, folder string, step func(string)) error
	// Box is the absolute folder of the CYFR a box's own screen shows,
	// This box, on that screen alone; "" on a desktop. This box is no row
	// of the list: its press (/bootstrap/box) reads that folder at the
	// press and opens the CYFR it names now, adding an entry at an address
	// the list does not hold, and the rail shows the entry it last made as
	// This box, which is never forgotten. Only This box's shell makes the
	// machine's key (shell.Config.KeyElsewhere).
	Box string
	// Hide, on a box's screen, hides what the screen shows as every lock
	// begins, with a CYFR open or none, and only then tells main, through
	// tell: the lock's locked, or, at the service's end, ending, the run's
	// last message. nil (a desktop) tells at once, and nothing at the end.
	Hide func(tell func())

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
	// began is whether a Connect began in this run: the CYFR elsewhere
	// remembered is connected by itself once, as the app starts, and
	// never again.
	began bool
	// ended is whether cyfr is ending, which main hears as its end and
	// never as a lock.
	ended bool
	// folder is the folder main's last folder-picked named, and picks
	// counts main's answers.
	folder string
	picks  uint64
	// setting is the setup on this computer begun in this run, if any,
	// which no lock ends.
	setting *SetupState
	// woken is closed and replaced at each pick answered, each step of a
	// setup and each lock, which a chooser waiting for one wakes on.
	woken chan struct{}
	// listed counts the list's changes the rail is shown (changed).
	listed uint64
	// erases is each erase asked of main and not yet answered, by its id,
	// the last given eraseID; unerased names each CYFR whose Forget an
	// erase failed for.
	erases   map[uint64]erasing
	eraseID  uint64
	unerased map[string]bool
	// over is whether ending was said (Hide): nothing is said after it.
	over bool
	// leftUnlocked, on a box's screen, is the CYFR a departure left while
	// its device was unlocked, whose own Forget, which main sends once it
	// left it, that unlock still authorizes: once, and no longer than the
	// next lock or selection.
	leftUnlocked string
}

type selection struct {
	home  string
	found account.Discovered
	epoch uint64
	from  shell.Row
}

// NewToken is a run token: 32 random bytes, unpadded base64url.
func NewToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b) // crypto/rand.Read never fails, by its contract.
	return base64.RawURLEncoding.EncodeToString(b)
}

// RunHeader is the header that carries the run token on the chooser's
// requests, which main adds to those of the chooser's own top document
// alone (desktop/src/app.js): the page holds the token nowhere, and a
// request that names it in its body is refused as one with an unknown
// field.
const RunHeader = "Cyfr-Run"

// ReadyURL is ready's address of the chooser, the run token in its
// fragment, which no request carries: main takes the token from it and
// opens the chooser without it.
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
	if strings.HasPrefix(r.URL.Path, "/rail/") {
		s.rail(w, r)
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
	// Admitted, with its epoch, in the one hold that decides whether the
	// service has ended: a request that lost the race with End answers
	// 503 and never parks.
	s.mu.Lock()
	epoch, ended := s.epoch, s.ended
	s.mu.Unlock()
	if ended {
		http.Error(w, "This CYFR app has ended.", http.StatusServiceUnavailable)
		return
	}
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
	route, ok := chooserRoutes[r.URL.Path]
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
	if subtle.ConstantTimeCompare([]byte(r.Header.Get(RunHeader)), []byte(s.Token)) != 1 {
		http.Error(w, "not this app's page", http.StatusForbidden)
		return
	}
	if route.carries != 0 {
		// A request that acts belongs to the time since the last lock that
		// the page was shown in, which it says: one from before a lock,
		// however late it arrives, acts in none.
		epoch = req.Epoch
	}
	req.carries = route.carries
	// A pick waits on the person at the system's dialog, and a setup's
	// step on Docker, unbounded; every other request is bounded.
	ctx, cancel := r.Context(), context.CancelFunc(func() {})
	if r.URL.Path != "/bootstrap/folder" && r.URL.Path != "/bootstrap/setup" {
		ctx, cancel = context.WithTimeout(ctx, chooserBound)
	}
	defer cancel()
	a := route.act(s, ctx, epoch, req)
	if a.ended {
		http.Error(w, "This CYFR app has ended.", http.StatusServiceUnavailable)
		return
	}
	if a.Folder != "" {
		a.Found = s.found(a.Folder)
	}
	h.Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(a)
}

// found is whether a CYFR is set up in folder already, as the app reads a
// folder (Local), asking Docker nothing.
func (s *Service) found(folder string) bool {
	if s.Local == nil {
		return false
	}
	l, err := s.Local(folder)
	if err != nil {
		return false
	}
	l.end()
	return true
}

// chooserRoutes is every request of the chooser's: what answers it, and
// what of the page's it carries where it acts, changing what the app
// holds or does. One that acts is refused, changing nothing, unless all it
// carries is still so (stale).
var chooserRoutes = map[string]struct {
	act     func(*Service, context.Context, uint64, request) answer
	carries generation
}{
	"/bootstrap/state":   {(*Service).state, 0},
	"/bootstrap/connect": {(*Service).connect, carriesEpoch},
	"/bootstrap/approve": {(*Service).approve, carriesEpoch},
	"/bootstrap/folder":  {(*Service).awaitFolder, 0},
	"/bootstrap/docker":  {(*Service).docker, 0},
	"/bootstrap/start":   {(*Service).start, carriesEpoch | carriesPicks | carriesRun},
	"/bootstrap/setup":   {(*Service).awaitSetup, 0},
	"/bootstrap/open":    {(*Service).openFolder, carriesEpoch | carriesPicks | carriesRun},
	"/bootstrap/box":     {(*Service).box, carriesEpoch},
}

// mainCarries is what each message of main's that answers something
// carries of what it answers, as chooserRoutes says it of a request: the
// folder-picked answer to the pick the chooser asked for, home-ready to
// the proposal waiting. A lock, a leave and a shutdown
// answer nothing, and always act.
var mainCarries = map[string]generation{
	TypeFolderPicked: carriesEpoch | carriesPicks,
	TypeHomeReady:    carriesAttempt,
}

// generation names what a request or message carries of what it was
// issued under: the epoch its page was shown in, the picks answered
// before it, the setup it showed, or the proposal it answers.
type generation uint8

const (
	carriesEpoch generation = 1 << iota
	carriesPicks
	carriesRun
	carriesAttempt
)

// stale is why what req carries of what its page showed is no longer so,
// under s.mu, or nil while all of it is: the one rule every request and
// message that acts is refused by, before it changes anything. What it
// answers is what is so now, for the page to show.
func (s *Service) stale(req request) *answer {
	folder, picks := s.folderNow()
	var run uint64
	if s.setting != nil {
		run = s.setting.Run
	}
	now := answer{Folder: folder, Picks: picks, Setup: s.settingNow()}
	switch {
	case req.carries&carriesEpoch != 0 && req.Epoch != s.epoch:
		return &answer{Error: lockedSentence}
	case req.carries&carriesPicks != 0 && req.Picks != picks:
		now.Error = "The folder changed to " + folder + ". Check it, then press again."
		return &now
	case req.carries&carriesRun != 0 && req.Run != run:
		// A setup begun since the page was shown: what it shows now.
		return &now
	case req.carries&carriesAttempt != 0 && (s.ready == nil || s.pages != nil || req.Attempt != s.current || req.Home != s.selecting):
		// An answer to a proposal that is not the one waiting.
		return &answer{}
	}
	return nil
}

// chooserBound bounds each chooser request but a pick's wait.
var chooserBound = 60 * time.Second

const (
	lockedSentence = "CYFR locked. Connect again."
	busySentence   = "This app is connecting already. Wait for it to finish."
)

// begin takes the one Connect a time for req at home, or answers why not,
// changing nothing: what req carries is no longer so (stale), or with a
// CYFR open, only that CYFR's own home is taken.
// run ends at the next lock, and finish must follow.
func (s *Service) begin(ctx context.Context, req request, home string) (context.Context, *answer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if a := s.stale(req); a != nil {
		return nil, a
	}
	switch {
	case s.connecting:
		return nil, &answer{Error: busySentence}
	case s.pages != nil && home != s.committed.Home:
		return nil, &answer{Error: "This app is connected to a CYFR already. Quit it and open it again to connect to another."}
	}
	run, stop := context.WithCancel(ctx)
	s.connecting, s.stop, s.began = true, stop, true
	s.leftUnlocked = ""
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

// request is a chooser's request: the address typed, the
// directory approved, or the picks it has seen answered. Epoch is the time
// since a lock the page was shown in, Picks the pick its folder is, and Run
// the setup it shows (none 0): a request that acts says what the page
// showed, and is refused where that is no longer so.
type request struct {
	Epoch   uint64 `json:"epoch,omitempty"`
	Run     uint64 `json:"run,omitempty"`
	Address string `json:"address,omitempty"`
	// Kept is a press of a CYFR this computer keeps (a row of the rail, or
	// the last one opened): it selects one that is listed and adds none.
	Kept      bool   `json:"kept,omitempty"`
	Home      string `json:"cyfr,omitempty"`
	Directory string `json:"directory,omitempty"`
	Picks     uint64 `json:"picks,omitempty"`
	Seen      uint64 `json:"seen,omitempty"`
	// Attempt is a main's answer's proposal (mainCarries), never a
	// chooser's.
	Attempt uint64 `json:"-"`
	// carries is what of the above its route carries (chooserRoutes).
	carries generation
}

// answer is what the chooser does next: show a sentence, ask to approve a
// directory for a CYFR, or go to the device's pages.
//
// Once a CYFR is open, Next is the device's pages. Resume, before any
// Connect of this run, is the CYFR selected last, elsewhere or a folder's,
// which the chooser presses by itself once.
// Folder is where CYFR would be set up on this computer, after
// Picks of main's answers to a pick, Found whether a CYFR is set up there
// already, and Docker whether Docker answers there.
type answer struct {
	Epoch   uint64        `json:"epoch,omitempty"`
	Docker  *DockerAnswer `json:"docker,omitempty"`
	Setup   *SetupState   `json:"setup,omitempty"`
	Folder  string        `json:"folder,omitempty"`
	Picks   uint64        `json:"picks,omitempty"`
	Found   bool          `json:"found,omitempty"`
	Home    string        `json:"cyfr,omitempty"`
	Confirm string        `json:"confirm,omitempty"`
	Next    string        `json:"next,omitempty"`
	Resume  string        `json:"resume,omitempty"`
	// ResumeBox, on a box's screen with no CYFR selected last, is This
	// box, which the chooser presses by itself once in its place.
	ResumeBox bool   `json:"resume_box,omitempty"`
	Error     string `json:"error,omitempty"`
	// ended is the service's end, met by a wait: answered 503.
	ended bool
}

// DockerAnswer is whether Docker answers this account on this computer,
// and, where it does not, the sentence why and what would make it: the
// commands to run as root, or the page a person installs it from. The app
// runs none of them.
type DockerAnswer struct {
	Ready    bool     `json:"ready,omitempty"`
	Sentence string   `json:"sentence,omitempty"`
	Commands []string `json:"commands,omitempty"`
	Page     string   `json:"page,omitempty"`
}

// docker is the chooser's question of Docker, asked again at each Check
// again; a lock meanwhile answers locked.
func (s *Service) docker(ctx context.Context, epoch uint64, _ request) answer {
	if s.Docker == nil {
		return answer{Error: "This app cannot set CYFR up on this computer."}
	}
	d := s.Docker(ctx)
	if !s.live(epoch) {
		return answer{Error: lockedSentence}
	}
	return answer{Docker: &d}
}

// opened is the answer for the CYFR open at home.
func (s *Service) opened(home string) answer {
	return answer{Home: home, Next: "/"}
}

func (s *Service) state(_ context.Context, epoch uint64, _ request) answer {
	a := s.shown()
	a.Epoch = epoch
	return a
}

// shown is what the chooser shows now.
func (s *Service) shown() answer {
	list, err := s.Homes.Load()
	if err != nil {
		return answer{Error: "This computer's list of CYFRs could not be read (" + err.Error() + ")."}
	}
	s.mu.Lock()
	open, began, home := s.pages != nil, s.began, s.committed.Home
	folder, picks := s.folderNow()
	setting := s.settingNow()
	s.mu.Unlock()
	if open {
		return s.opened(home)
	}
	// The last selected, a folder's too, is pressed by the chooser once in
	// a run; the list's read asks no folder, network or Docker anything.
	a := answer{Folder: folder, Picks: picks, Setup: setting, Home: list.Last}
	if !began {
		a.Resume = list.Last
		a.ResumeBox = list.Last == "" && s.Box != ""
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
	run, refused := s.begin(ctx, req, home)
	if refused != nil {
		return *refused
	}
	defer s.finish()
	if a, open := s.again(run, epoch); open {
		return a
	}
	from := shell.Typed
	if req.Kept {
		row, a, unkept := s.row(home)
		if unkept {
			return a
		}
		from = row
	}
	if a, folder := s.folderRow(run, epoch, home, from); folder {
		return a
	}
	if !ok {
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
	if err := s.Homes.EndApproval(home, found.Directory); err != nil {
		return answer{Error: "This computer could not forget the account service it approved before (" + err.Error() + ")."}
	}
	list, err := s.Homes.Load()
	if err != nil {
		return answer{Error: "This computer's list of CYFRs could not be read (" + err.Error() + ")."}
	}
	c, held := list.Homes[home]
	switch {
	case found.Directory == account.DefaultDirectory:
		return s.selectRemote(run, epoch, home, found, true, from)
	case held && c.Project == "" && c.Directory == found.Directory:
		return s.selectRemote(run, epoch, home, found, false, from)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.epoch != epoch {
		return answer{Error: lockedSentence}
	}
	s.pending = &selection{home: home, found: found, epoch: epoch, from: from}
	return answer{Home: home, Confirm: found.Directory}
}

func (s *Service) approve(ctx context.Context, epoch uint64, req request) answer {
	run, refused := s.begin(ctx, req, "")
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
	return s.selectRemote(run, epoch, p.home, p.found, true, p.from)
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

// row is the row a press of a CYFR this computer keeps (request.Kept) began
// from (shell.Row), or its answer when the list holds it no more, or holds
// it being forgotten: a row the rail showed before its Forget ended,
// pressed after, adds nothing. Connect is the one way to add a CYFR.
func (s *Service) row(home string) (shell.Row, answer, bool) {
	row, err := s.Homes.Row(home)
	switch {
	case shell.IsUnkept(err):
		return row, answer{Error: fmt.Sprintf("This computer no longer keeps %s. Choose a CYFR on the left, or connect to it to add it again.", home)}, true
	case err != nil:
		return row, answer{Error: "This computer cannot open " + home + ": " + err.Error() + "."}, true
	}
	return row, answer{}, false
}

// live is whether no lock came since epoch.
func (s *Service) live(epoch uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.epoch == epoch
}

// folderRow opens the CYFR of the folder the list keeps at home, whatever
// press, retry or start asked: that folder alone is read, and opened only
// while its reading still names home. A folder that cannot be read, or
// names another address now, is said; nothing starts Docker, and nothing
// connects to home as a CYFR elsewhere. false where the list keeps no
// folder at home.
func (s *Service) folderRow(run context.Context, epoch uint64, home string, from shell.Row) (answer, bool) {
	list, err := s.Homes.Load()
	if err != nil {
		return answer{Error: "This computer's list of CYFRs could not be read (" + err.Error() + ")."}, true
	}
	c, held := list.Homes[home]
	if !held || c.Project == "" {
		return answer{}, false
	}
	if s.Local == nil {
		return answer{Error: "This app reads no folder on this computer, so it cannot open the CYFR in " + c.Project + "."}, true
	}
	l, err := s.Local(c.Project)
	// This holds the reading until the service takes it as it opens.
	defer l.end()
	switch {
	case err != nil:
		return answer{Error: fmt.Sprintf("The app cannot read the CYFR in %s (%v).", c.Project, err)}, true
	case l.Shell.Address != home:
		return answer{Error: fmt.Sprintf("The CYFR in %s is at %s now, not %s. Connect to %s to add it.",
			c.Project, l.Shell.Address, home, l.Shell.Address)}, true
	}
	return s.openLocal(run, epoch, c.Project, &l, from), true
}

// openLocal selects the CYFR l, set up in project on this computer, with
// the account service its own settings name: every open of a folder's
// CYFR, whichever press or start led to it. The service takes l as it
// opens it (selectHome), and l's holder ends it otherwise. While no one is
// set up there, the folder's reading offers its setup token, which main is
// told with the CYFR: on the passkey road its first person is made at the
// CYFR's setup page, on the six-word road at the device's pages.
func (s *Service) openLocal(run context.Context, epoch uint64, project string, l *Local, from shell.Row) answer {
	home := l.Shell.Address
	found, ok := account.ServiceOf(home, l.Shell.Directory)
	if !ok {
		return answer{Error: fmt.Sprintf("The CYFR in %s names %s as its account service. The app takes an https address, "+
			"or a plain http one only at a CYFR's own address on this computer.", project, l.Shell.Directory)}
	}
	l.waits = s.Box != "" && project == s.Box
	if err := l.Answers(run); err != nil && !l.waits {
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: err.Error()}
	}
	sel, err := s.Homes.SelectLocal(home, project, from)
	if err != nil {
		return answer{Error: "This computer cannot open the CYFR in " + project + ": " + err.Error() + "."}
	}
	// This box's first person is made at the device's pages, which read
	// the token themselves at their first hello: its proposal carries none,
	// and its press asks nothing of the CYFR or Docker.
	setup := ""
	if l.Shell.SetupToken != nil && !l.waits {
		setup, _ = l.Shell.SetupToken(run)
	}
	cfg := l.Shell
	cfg.KeyElsewhere = s.keyElsewhere(project)
	return s.selectHome(run, epoch, sel, cfg, l,
		Message{Type: TypeHome, Home: home, Account: found.Origin, Proxy: l.Proxy, Setup: setup})
}

// selectRemote selects the CYFR elsewhere at home, with the account
// service found for it, approved in this selection or not.
func (s *Service) selectRemote(run context.Context, epoch uint64, home string, found account.Discovered, approved bool, from shell.Row) answer {
	sel, err := s.Homes.Select(home, found.Directory, approved, from)
	if err != nil {
		return answer{Error: "This computer cannot open " + home + ": " + err.Error() + "."}
	}
	return s.selectHome(run, epoch, sel, shell.Config{Address: home, Client: s.Client, Directory: found.Directory, Detect: remoteDisks,
		KeyElsewhere: s.keyElsewhere("")}, nil,
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
	if s.Box != "" {
		// The rail offers Forget only while the box is unlocked (railNow).
		cfg.Opened = func() {
			s.mu.Lock()
			s.changed()
			s.mu.Unlock()
		}
	}
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
	s.attempts++
	proposal.Attempt = s.attempts
	s.ready, s.selecting, s.current = ready, home, s.attempts
	s.Tell(proposal)
	s.mu.Unlock()
	select {
	case <-ready:
	case <-run.Done():
		if !s.live(epoch) {
			return answer{Error: lockedSentence}
		}
		return answer{Error: "The app did not get ready to open " + home + ". Connect again."}
	}
	// Whether the selection is still wanted is read in the hold that
	// commits it, its request's end beside the lock's and the service's:
	// a home-ready and an end both pending commit nothing.
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.epoch != epoch || s.ended {
		return answer{Error: lockedSentence}
	}
	if run.Err() != nil {
		return answer{Error: "The app did not get ready to open " + home + ". Connect again."}
	}
	if err := sel.Commit(proposal.Account); err != nil {
		return answer{Error: "This computer could not remember the CYFR (" + err.Error() + ")."}
	}
	var work *shell.Work
	if l != nil {
		s.here = l.take()
		work = s.here.Work
	}
	s.sh, s.pages = sh, &shell.Server{Shell: sh, Work: work}
	// Its readings run under the CYFR's Work, which its end ends.
	if work != nil && s.here.waits {
		s.pages.Reachable = s.here.Answers
	}
	s.Tell(Message{Type: TypeOpened, Home: home, Attempt: proposal.Attempt})
	s.committed = proposal
	s.changed()
	return s.opened(home)
}

// keyElsewhere is the sentence a shell at a CYFR other than This box's,
// the CYFR in project ("" for one elsewhere), shows where the machine has
// no key yet, on a box's screen: the key is made at This box alone. ""
// lets the shell make it, This box's and every one on a desktop.
func (s *Service) keyElsewhere(project string) string {
	if s.Box == "" || project == s.Box {
		return ""
	}
	return "This box makes its key at its own CYFR first: choose This box on the left, make the key there, then come back here and unlock with it."
}

// box opens This box (Box): the CYFR its folder names now, read at the
// press, whatever the list holds, on a first start with no entry too. An
// address the list does not hold yet is added as an entry of its own, with
// an admission and storage of its own; an entry an earlier reading made is
// left as it is, opened by nothing here, and forgotten apart.
func (s *Service) box(ctx context.Context, epoch uint64, req request) answer {
	run, refused := s.begin(ctx, req, "")
	if refused != nil {
		return *refused
	}
	defer s.finish()
	if s.Box == "" || s.Local == nil {
		return answer{Error: "This app shows no box's own CYFR."}
	}
	l, err := s.Local(s.Box)
	// This holds the reading until the service takes it as it opens.
	defer l.end()
	if err != nil {
		return answer{Error: fmt.Sprintf("This box cannot read the CYFR in %s (%v).", s.Box, err)}
	}
	return s.openLocal(run, epoch, s.Box, &l, shell.Typed)
}

// boxHome is the entry of list This box shows (Box): of those set up in
// its folder, the one made or admitted last, "" where none is or this is
// no box's screen.
func (s *Service) boxHome(list shell.HomeList) string {
	home, at := "", uint64(0)
	if s.Box == "" {
		return ""
	}
	for h, rec := range list.Homes {
		if rec.Project == s.Box && (home == "" || rec.Generation > at) {
			home, at = h, rec.Generation
		}
	}
	return home
}

// remoteDisks is what a device of a remote CYFR reports: its own system
// disk, and its CYFR's data, which is elsewhere, as unknown.
func remoteDisks(string) disk.Report {
	r := disk.Detect("/")
	r.Data = disk.Unknown
	return r
}

// folderNow is the folder and the picks answered, under s.mu.
func (s *Service) folderNow() (string, uint64) {
	if s.folder == "" {
		return s.Folder, s.picks
	}
	return s.folder, s.picks
}

// wake ends every wait for a pick's answer or a setup's step, under s.mu.
func (s *Service) wake() {
	if s.woken != nil {
		close(s.woken)
	}
	s.woken = make(chan struct{})
}

// waitWoken is the channel the next wake closes, under s.mu.
func (s *Service) waitWoken() chan struct{} {
	if s.woken == nil {
		s.woken = make(chan struct{})
	}
	return s.woken
}

// awaitFolder answers the folder once main answered more picks than the
// chooser has seen: its Change… asks here before main is asked, so the
// answer is never missed. A lock ends the wait.
func (s *Service) awaitFolder(ctx context.Context, epoch uint64, req request) answer {
	for {
		s.mu.Lock()
		if s.ended {
			s.mu.Unlock()
			return answer{ended: true}
		}
		if s.epoch != epoch {
			s.mu.Unlock()
			return answer{Error: lockedSentence}
		}
		folder, picks := s.folderNow()
		if picks != req.Picks {
			s.mu.Unlock()
			return answer{Folder: folder, Picks: picks}
		}
		woken := s.waitWoken()
		s.mu.Unlock()
		select {
		case <-woken:
		case <-ctx.Done():
			return answer{Error: "The app's connection stopped. Quit it and open it again."}
		}
	}
}

// FolderPicked is main's folder-picked m: the folder the person picked,
// or nil for none, which leaves the folder as it was. It answers the pick
// the chooser asked for now alone: one from before a lock, or one answered
// already, changes nothing (stale).
func (s *Service) FolderPicked(m Message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stale(request{Epoch: m.Epoch, Picks: m.Pick, carries: mainCarries[TypeFolderPicked]}) != nil {
		return
	}
	if m.Path != nil {
		s.folder = *m.Path
	}
	s.picks++
	s.wake()
}

// SetupState is the setup on this computer begun in this run: its folder,
// the steps it began, and its end, Done or the Error sentence. Run numbers
// the setups of this run from 1, and Seq counts the changes of them all.
type SetupState struct {
	Run    uint64   `json:"run"`
	Folder string   `json:"folder"`
	Steps  []string `json:"steps"`
	Done   bool     `json:"done,omitempty"`
	Error  string   `json:"error,omitempty"`
	Seq    uint64   `json:"seq"`
}

// settingNow is a copy of the setup begun, or nil, under s.mu.
func (s *Service) settingNow() *SetupState {
	if s.setting == nil {
		return nil
	}
	c := *s.setting
	c.Steps = append([]string{}, c.Steps...)
	return &c
}

// start begins setting CYFR up in the folder the page shows, the person's
// press of Set up and start: one at a time, again after one failed, and
// only while all the page showed is so (stale); otherwise it answers what
// is now, and a press again for a setup running or done does nothing. It
// runs to its end whatever the chooser or a lock does, records the folder
// as it ends (remember), and opens nothing (openFolder).
func (s *Service) start(_ context.Context, _ uint64, req request) answer {
	if s.Setup == nil {
		return answer{Error: "This app cannot set CYFR up on this computer."}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if a := s.stale(req); a != nil {
		return *a
	}
	folder, picks := s.folderNow()
	if s.setting != nil && s.setting.Error == "" {
		return answer{Folder: folder, Picks: picks, Setup: s.settingNow()}
	}
	seq, run := uint64(1), uint64(1)
	if s.setting != nil {
		seq, run = s.setting.Seq+1, s.setting.Run+1
	}
	s.setting = &SetupState{Run: run, Folder: folder, Steps: []string{}, Seq: seq}
	cur := s.setting
	s.wake()
	go func() {
		err := s.Setup(context.Background(), folder, func(step string) {
			s.mu.Lock()
			defer s.mu.Unlock()
			cur.Steps = append(cur.Steps, step)
			cur.Seq++
			s.wake()
		})
		// The folder set up is recorded as the setup ends, before anything
		// can start the app again: the chooser then offers it.
		if err == nil {
			err = s.remember(folder)
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if err != nil {
			cur.Error = err.Error()
		} else {
			cur.Done = true
		}
		cur.Seq++
		s.wake()
	}()
	return answer{Setup: s.settingNow()}
}

// awaitSetup answers the setup begun once it changed past the chooser's
// seen, or at once with none begun. A lock ends the wait.
func (s *Service) awaitSetup(ctx context.Context, epoch uint64, req request) answer {
	for {
		s.mu.Lock()
		if s.ended {
			s.mu.Unlock()
			return answer{ended: true}
		}
		if s.epoch != epoch {
			s.mu.Unlock()
			return answer{Error: lockedSentence}
		}
		if s.setting == nil || s.setting.Seq != req.Seen {
			a := answer{Setup: s.settingNow()}
			s.mu.Unlock()
			return a
		}
		woken := s.waitWoken()
		s.mu.Unlock()
		select {
		case <-woken:
		case <-ctx.Done():
			return answer{Error: "The app's connection stopped. Quit it and open it again."}
		}
	}
}

// remember adds the CYFR set up in folder to the list, at the address its
// reading names, as the one selected last, as opening it does
// (shell.Selection): the chooser then offers it. An app that reads no
// folder (Local nil) remembers none.
func (s *Service) remember(folder string) error {
	if s.Local == nil {
		return nil
	}
	l, err := s.Local(folder)
	defer l.end()
	var sel *shell.Selection
	if err == nil {
		sel, err = s.Homes.SelectLocal(l.Shell.Address, folder, shell.Typed)
	}
	if err == nil {
		err = sel.Commit("")
	}
	if err != nil {
		return fmt.Errorf("CYFR is set up in %s, but this computer could not remember it (%v)", folder, err)
	}
	s.mu.Lock()
	s.changed()
	s.mu.Unlock()
	return nil
}

// openFolder opens the CYFR set up in the folder the page shows, the
// person's press of Open CYFR, or the chooser that pressed Set up and
// start, at its end: only while all the page showed is so (stale), and
// never while a setup there is still running.
func (s *Service) openFolder(ctx context.Context, epoch uint64, req request) answer {
	run, refused := s.begin(ctx, req, "")
	if refused != nil {
		return *refused
	}
	defer s.finish()
	s.mu.Lock()
	folder, _ := s.folderNow()
	setting := s.settingNow()
	s.mu.Unlock()
	if setting != nil && setting.Folder == folder && !setting.Done && setting.Error == "" {
		return answer{Setup: setting, Error: "CYFR is still being set up here."}
	}
	if s.Local == nil {
		return answer{Error: "CYFR is not set up in " + folder + "."}
	}
	l, err := s.Local(folder)
	if err != nil {
		return answer{Error: fmt.Sprintf("The app cannot read the CYFR in %s (%v).", folder, err)}
	}
	// This holds the reading until the service takes it as it opens.
	defer l.end()
	return s.openLocal(run, epoch, folder, &l, shell.Typed)
}

// HomeReady is main's home-ready for an attempt at home: the one waiting,
// or nothing.
func (s *Service) HomeReady(home string, attempt uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stale(request{Home: home, Attempt: attempt, carries: mainCarries[TypeHomeReady]}) != nil {
		return
	}
	select {
	case s.ready <- struct{}{}:
	default:
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
	// Ended and woken in one hold: a wait checks ended in the hold it
	// parks in, so none parks past it.
	s.mu.Lock()
	s.ended = true
	s.wake()
	s.mu.Unlock()
	s.lock("", false)
}

// Leave is main's leave numbered id: the device locks and lets go of the
// CYFR open, every session of the device's there ended, and only then is
// main told left, with id.
func (s *Service) Leave(id uint64) {
	s.lock("", true)
	s.mu.Lock()
	ended := s.ended
	s.mu.Unlock()
	if !ended {
		s.Tell(Message{Type: TypeLeft, ID: id})
	}
}

// lock is Lock, which lets go of the CYFR open as well when leave says to
// (main's leave): the list stays as it is.
func (s *Service) lock(why string, leave bool) {
	s.mu.Lock()
	sh, here, letGo := s.sh, s.here, leave || s.ended
	// Read before the lock below locks it: the one fact a departure leaves.
	s.leftUnlocked = ""
	if leave && !s.ended && s.Box != "" && sh != nil && unlocked(sh) {
		s.leftUnlocked = s.committed.Home
	}
	if s.Box != "" {
		s.changed()
	}
	if leave {
		s.sh, s.pages, s.here, s.committed = nil, nil, nil, Message{}
		s.changed()
	}
	s.epoch++
	if s.stop != nil {
		s.stop()
	}
	s.pending = nil
	if s.pages == nil {
		s.ready, s.selecting, s.current = nil, "", 0
	}
	s.wake()
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

// sayLocked tells main the device locked, naming the CYFR committed, every
// lock's message; on a box's screen once its hide began (Hide), and at the
// service's end there it says ending, once, in its place.
func (s *Service) sayLocked() {
	s.mu.Lock()
	m, ended, over := s.committed, s.ended, s.over
	if ended && s.Hide != nil {
		s.over = true
	}
	s.mu.Unlock()
	m.Type = TypeLocked
	switch {
	case ended && (s.Hide == nil || over):
	case ended:
		s.Hide(func() { s.Tell(Message{Type: TypeEnding}) })
	case s.Hide != nil:
		s.Hide(func() { s.Tell(m) })
	default:
		s.Tell(m)
	}
}

// Run reads main's messages from in until shutdown or the end of in,
// which end it (End); a line that is not one of main's messages ends it
// with its refusal.
func (s *Service) Run(in io.Reader) error {
	s.resumeForgets()
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
		case TypeLock:
			s.Lock("Locked.")
		case TypeLeave:
			s.Leave(m.ID)
		case TypeShutdown:
			s.End()
			return nil
		case TypeFolderPicked:
			s.FolderPicked(m)
		case TypeForget:
			s.Forget(m.Home)
		case TypeErased:
			s.Erased(m.ID, m.OK)
		}
	}
	s.End()
	if err := lines.Err(); err != nil {
		return errors.Join(refuse("size"), err)
	}
	return nil
}
