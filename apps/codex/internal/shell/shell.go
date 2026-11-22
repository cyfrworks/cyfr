// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package shell is a device of a person's account: the pages that make its
// key, make the account or add the key to one, unlock it with the person's
// PIN (or passphrase) and lock it again, confirm a sensitive change
// freshly and add a passkey a browser asks for to the account, served on
// literal loopback to a box's screen or the CYFR app. Through the device
// channel the device proves the person to a CYFR.
//
// The PIN opens the device's key (internal/holder) in this package alone
// and goes nowhere else:
// a CYFR receives only signatures, never a PIN, a passphrase or anything
// derived from one. One key serves every CYFR; each CYFR admits it once,
// by its hello, and from then the device connects under the certificate
// that CYFR issued. An unlock opens the channel, asks the CYFR to reserve
// a session (session.unlock), signs that reservation and hands the
// browser the CYFR's one-time ticket in a fragment; the shell pre-signs
// the lock of exactly that session and keeps it in memory. A lock, from
// the visible Lock, five minutes without local input, a suspend, the
// browser's exit or the shell's own, submits those proofs, closes the
// channel (which ends every session it holds at the CYFR), erases the key
// and starts the browser again on the lock page. It waits for no work in
// flight: it ends that work's generation first (generation). A shell that dies without
// locking leaves sessions that expire within 60 seconds at the CYFR, as
// nothing renews them.
package shell

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// Config is one device's shell at one CYFR.
type Config struct {
	// Address is the CYFR's origin, as its certificates name it.
	Address string
	// Client reaches the CYFR, the directory and the registry.
	Client *http.Client
	// Record is the device key's record; an account being made is kept
	// beside it until it is done.
	Record string
	// Clients keeps the client this device is at this CYFR.
	Clients ClientStore
	// Directory is the directory an account is made at and a name is
	// looked up through: cyfr.run unless CYFR_DIRECTORY_URL names another.
	Directory string
	// DataDir is the CYFR's actual data directory, whose volume the
	// detection reads.
	DataDir string
	// SetupToken answers the setup token a first hello brings, or "", so
	// it never travels in an argument, and the transport that hello goes
	// by, bound to what the token was read of (nil, Client's own). A
	// device whose .env holds the token whether or not anyone is set up (a
	// box's screen, the CYFR app at a CYFR on its own computer) answers it
	// from one reading, only while that reading says no one is set up and
	// names this shell's Address.
	// Its first hello then brings it whether the device made its account
	// here or was added to one, since the installation's first person
	// binds it whoever they are; otherwise it brings none, and the CYFR's
	// door decides. Unset, a first hello brings none.
	SetupToken func(context.Context) (token string, through http.RoundTripper)
	// Restart starts the browser again on the lock page, after a lock.
	Restart func()
	// Unwatched is set for a device that locks itself (a box's screen): why
	// it may not be unlocked now, or "" while what would lock it is known
	// to work. While it says why, nothing unlocks and the pages show that.
	Unwatched func() string
	// DisplayName is the name the CYFR lists this device by.
	DisplayName string
	// Detect reads the disks; disk.Detect unless a test replaces it.
	Detect func(dataDir string) disk.Report
	// Now is the clock; time.Now unless a test replaces it.
	Now func() time.Time
	// Chip is whether this machine offers a chip to hold its key;
	// holder.ChipPresent unless a test replaces it, so no test reaches the
	// machine's own TPM.
	Chip func() bool
}

// ClientRecord is the one CYFR this user's device connects to and its
// standing there: the CYFR selected, a remote CYFR's origin (Home) or a
// local project's absolute directory (Project), the directory URL
// approved for it, and the client that CYFR admitted this device's key as
// and the certificate it connects under there.
type ClientRecord struct {
	Home        string          `json:"home,omitempty"`
	Project     string          `json:"project,omitempty"`
	Directory   string          `json:"directory,omitempty"`
	ClientID    string          `json:"client_id,omitempty"`
	Certificate json.RawMessage `json:"certificate,omitempty"`
}

// ClientStore keeps this device's ClientRecord at one CYFR. Update reads
// the record, lets change edit it and writes it in one step, when change
// answers true, so no writer saves a copy read before another's write.
type ClientStore interface {
	Load() (ClientRecord, error)
	Update(change func(*ClientRecord) bool) error
}

// ClientFile keeps a ClientRecord in a file of its own, private to its
// owner: client.json in this user's device folder (DeviceDir).
type ClientFile string

// DeviceDir is this user's device folder, ~/.cyfr/device, made when it is
// not there and kept private to this account each time it is used
// (privateFolder): the key's record (holder.json) and the client
// record (client.json) of every road this user's CYFR app or screen
// takes, one key and one selected CYFR for the user.
func DeviceDir() (string, error) {
	dir, err := DeviceFolder()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := privateFolder(dir); err != nil {
		return "", fmt.Errorf("%s is not this account's alone (%v)", dir, err)
	}
	return dir, nil
}

// DeviceFolder is DeviceDir's path, made or not.
func DeviceFolder() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".cyfr", "device"), nil
}

// Selection is a CYFR, a remote one or a local project's, being selected
// over this account's client record. It reads as that CYFR's record, with
// the client and certificate held there when the record already selects
// it. A working client and its
// certificate are replaced only by an admission that succeeded: until the
// selected CYFR admits this device, the record changes only where it
// selects nothing at all (Commit), and every other change the shell makes
// (a refused first hello's forget among them) stays in memory.
type Selection struct {
	file ClientFile
	mu   sync.Mutex
	rec  ClientRecord
	// approved is whether the address in rec was approved in this
	// selection (or is cyfr.run), rather than taken from an approval the
	// record held, which may have ended since.
	approved bool
	// owns is whether the record is the selection's: it selected this CYFR
	// already, or this CYFR admitted the device.
	owns bool
}

// Select begins selecting home, a remote CYFR's origin, with directory the
// account service for it, approved in this selection or not; it writes
// nothing.
func (f ClientFile) Select(home, directory string, approved bool) (*Selection, error) {
	c, err := f.Load()
	if err != nil {
		return nil, err
	}
	rec := ClientRecord{Home: home, Directory: directory}
	owns := c.Home == home && c.Project == ""
	if owns {
		rec.ClientID, rec.Certificate = c.ClientID, c.Certificate
	}
	return &Selection{file: f, rec: rec, approved: approved, owns: owns}, nil
}

// SelectLocal begins selecting the CYFR in project, a local project's
// absolute directory. Its account service is that project's own setting,
// so the record keeps no approval of one; it writes nothing.
func (f ClientFile) SelectLocal(project string) (*Selection, error) {
	c, err := f.Load()
	if err != nil {
		return nil, err
	}
	rec := ClientRecord{Project: project}
	owns := c.Project == project && c.Home == ""
	if owns {
		rec.ClientID, rec.Certificate = c.ClientID, c.Certificate
	}
	return &Selection{file: f, rec: rec, approved: true, owns: owns}, nil
}

// Load is the selected CYFR's record.
func (s *Selection) Load() (ClientRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rec, nil
}

// Update applies change to the selected CYFR's record, and to the file
// once the record is the selection's, or when the change is an admission
// (a client and the certificate this CYFR issued it), which makes it so.
func (s *Selection) Update(change func(*ClientRecord) bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(&s.rec)
	return s.file.Update(func(c *ClientRecord) bool {
		switch {
		case s.owns:
			return change(c)
		case s.rec.ClientID != "" && len(s.rec.Certificate) != 0:
			*c, s.owns = s.rec, true
			return true
		}
		return false
	})
}

// Commit writes the selection once the app opened it, where the record
// selects nothing yet or this CYFR already. It writes the account
// service's address only when this selection approved it; one it took
// from the record stays as the record holds it now, ended or not.
func (s *Selection) Commit() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.file.Update(func(c *ClientRecord) bool {
		switch {
		case s.owns:
			if !s.approved || c.Directory == s.rec.Directory {
				return false
			}
			c.Directory = s.rec.Directory
			return true
		case c.Home == "" && c.Project == "" && c.ClientID == "" && len(c.Certificate) == 0 && s.approved:
			*c, s.owns = s.rec, true
			return true
		}
		return false
	})
}

// EndApproval forgets the account service approved for home unless it is
// keep, the address the CYFR names now: an approval stands only while the
// CYFR names it.
func (f ClientFile) EndApproval(home, keep string) error {
	return f.Update(func(c *ClientRecord) bool {
		if c.Home != home || c.Directory == "" || c.Directory == keep {
			return false
		}
		c.Directory = ""
		return true
	})
}

// SelectProject remembers project, a local project's absolute directory,
// as the CYFR this device connects to. A record that already selects
// another CYFR, or holds a client of one, is refused: this user's device
// connects to one CYFR.
func (f ClientFile) SelectProject(project string) error {
	var refused error
	err := f.Update(func(c *ClientRecord) bool {
		switch {
		case c.Project == project:
			return false
		case c.Home != "":
			refused = fmt.Errorf("this account's CYFR app is connected to %s, not to the CYFR in %s", c.Home, project)
			return false
		case c.Project != "" || c.ClientID != "":
			refused = fmt.Errorf("this account's device is connected to the CYFR in %s, not to the one in %s", c.Project, project)
			return false
		}
		*c = ClientRecord{Project: project}
		return true
	})
	return errors.Join(err, refused)
}

// Load reads the file; none is an empty record.
func (f ClientFile) Load() (ClientRecord, error) {
	var c ClientRecord
	raw, err := os.ReadFile(string(f))
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	return c, json.Unmarshal(raw, &c)
}

// recordLocks holds one lock a client record's path: every writer of a
// record in this process takes it, and only the process holding the
// shell's listener writes one.
var recordLocks sync.Map

// Update reads the record, lets change edit it and, when change answers
// true, writes it in one step, all under the record's one lock.
func (f ClientFile) Update(change func(*ClientRecord) bool) error {
	l, _ := recordLocks.LoadOrStore(string(f), &sync.Mutex{})
	mu := l.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()
	c, err := f.Load()
	if err != nil {
		return err
	}
	if !change(&c) {
		return nil
	}
	return writeJSON(string(f), c)
}

// Save replaces the record whole.
func (f ClientFile) Save(c ClientRecord) error {
	return f.Update(func(r *ClientRecord) bool { *r = c; return true })
}

// writeJSON replaces path in one step: a private temporary file in the
// same directory, renamed over it.
func writeJSON(path string, v any) error {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(raw)
	if err = errors.Join(err, tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// createJSON writes path only where nothing is: a private temporary file in
// the same directory, linked at path, which fails (fs.ErrExist) when path
// exists, so the first writer wins whole.
func createJSON(path string, v any) error {
	raw, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, err = tmp.Write(raw)
	if err = errors.Join(err, tmp.Sync(), tmp.Close()); err != nil {
		return err
	}
	return os.Link(tmp.Name(), path)
}

// PendingConfirm is a confirmation the shell drew: the CYFR's record, as
// fetched over the channel, and when it was drawn.
type PendingConfirm struct {
	Ref       string
	Operation string
	Preview   map[string]any
	Asker     map[string]any
	drawn     time.Time
}

// PendingPasskey is a passkey a browser asks to add to the account, as the
// shell drew it from the CYFR: its ref, the key read as the log reads one,
// the short code derived here from its kid, the digest of the whole key
// (every field its add_key holds) that the page's form carries back, and
// when it was drawn.
type PendingPasskey struct {
	Ref    string
	Key    account.Key
	Code   string
	Digest string
	drawn  time.Time
}

// keyDigest is the digest a passkey page binds its approval to: SHA-256 of
// the JCS bytes of the key's whole map, unpadded base64url.
func keyDigest(k account.Key) string {
	raw, err := account.JCS(k.Map())
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return account.B64(sum[:])
}

// making is an account being made from this device: the attempt, the
// recovery key (in memory alone), the recovery code shown until it is said
// saved, and whether its name was taken meanwhile.
type making struct {
	attempt account.Attempt
	key     ed25519.PrivateKey
	code    string
	saved   bool
	taken   bool
}

// Shell is the device's state: its key record, its client at this CYFR,
// at most one key open and its channel, the lock proofs of the sessions it
// holds, an account being made, and what the next page says.
//
// One action at a time holds mu, through whatever it asks of Docker, the
// CYFR and the account service. So neither of what never waits for one
// takes it as an action does: a page that shows only what the shell knows
// is drawn from shown, what that was as mu was last released, and a lock
// ends the generation every action in flight began in (generation) before
// it takes mu.
type Shell struct {
	cfg Config

	mu    shellLock
	shown atomic.Pointer[shownState]
	// open is whether the channel stands, read without mu: it ends as the
	// lock that closes it does.
	open atomic.Bool

	genMu sync.Mutex
	gen   *generation

	rec  *holder.Record
	here ClientRecord
	// key is the open key: unlocked while ch stands, or held from a setup
	// until its first connection.
	key        *holder.Key
	ch         *Channel
	locks      []map[string]any
	renewal    *time.Timer
	notice     string
	passphrase string
	making     *making
	// unfinished is an account being made that a run before this one
	// saved.
	unfinished *account.Attempt
	// terms is the policy a new account accepts, once the directory named
	// one; configured is whether the directory's configuration was read.
	terms      *account.Policy
	configured bool
	confirm    *PendingConfirm
	passkey    *PendingPasskey
	// proof is what the page that typed the PIN holds: 32 random bytes,
	// drawn when a typed PIN opens the key (issueProof) and replaced by the
	// next one or a lock. The ticket and the recovery code go only to a
	// request that carries it (holds).
	proof []byte
}

// shownState is what a page read draws without mu: the view as a plain
// read is shown it, so no secret, and what was read of the account
// service's configuration.
type shownState struct {
	view       View
	terms      *account.Policy
	configured bool
}

// A generation is the time between two locks. An action belongs to the one
// it began in, and changes nothing once that one ended: not the state, the
// notice, the view, the channel, a ticket or a session. It is compared
// under mu, as the action takes the shell and again after each wait before
// what the wait changes (current). What ended the action's own context,
// the person, its deadline or the lock, decides nothing there.
//
// A lock ends the generation before it takes the shell, and the next
// begins once the last lock waiting has locked, so an action begun
// meanwhile begins in one that ended.
type generation struct {
	ended context.Context
	end   context.CancelFunc
	// locks is under Shell.genMu: the locks that ended it and have not
	// locked yet.
	locks int
}

func newGeneration() *generation {
	g := &generation{}
	g.ended, g.end = context.WithCancel(context.Background())
	return g
}

func (g *generation) live() bool { return g.ended.Err() == nil }

// underway is one action: the generation it began in, and what was seen of
// its waits for the shell. took is that it took the shell for its work,
// which clearing the last notice is not (Begin): from then on its deadline
// is its work's failure, told as that, and a free shell is still its to
// say so. outwaited is that its time ran out as it waited for a shell
// another held: it takes nothing more, and is told of that wait where it
// never took the shell (waitedOut).
type underway struct {
	g               *generation
	took, outwaited bool
}

type underwayKey struct{}

func underwayOf(ctx context.Context) *underway {
	a, _ := ctx.Value(underwayKey{}).(*underway)
	return a
}

func generationOf(ctx context.Context) *generation {
	if a := underwayOf(ctx); a != nil {
		return a.g
	}
	return nil
}

// waitedOut is whether ctx's action's time ran out waiting for the shell,
// its work not begun: the one failure told as a busy device.
func waitedOut(ctx context.Context) bool {
	a := underwayOf(ctx)
	return a != nil && a.outwaited && !a.took
}

// stale is whether ctx's action began before a lock.
func stale(ctx context.Context) bool {
	g := generationOf(ctx)
	return g != nil && !g.live()
}

// shellLock is the shell's one lock. An action's wait for it ends on that
// action's own context and on the end of its generation (lockFor); a lock
// alone waits for nothing but it (Lock). It publishes what the shell knows
// each time it is released.
type shellLock struct {
	held chan struct{}
	// by is the generation of the action holding it, nil for a lock.
	by        *generation
	releasing func()
	// waiting is called as an action finds it held, for a test to see.
	waiting func()
}

func (l *shellLock) Lock() { l.held <- struct{}{} }

// errWaitedOut is a wait for the held shell that the action's deadline
// ended: no other failure says that this device was busy.
var errWaitedOut = errors.New("waited for this device past the action's time")

// lockFor takes the shell in g. It waits only where the shell is held,
// and late is an action that took it before: with its time over, that one
// still takes a free shell, which is no wait.
func (l *shellLock) lockFor(ctx context.Context, g *generation, late bool) error {
	select {
	case l.held <- struct{}{}:
	default:
		if err := ctx.Err(); err != nil {
			return err
		}
		l.waiting()
		select {
		case l.held <- struct{}{}:
		case <-ctx.Done():
			return waitEnded(ctx)
		case <-g.ended.Done():
			return errLocked
		}
		if ctx.Err() != nil {
			<-l.held
			return waitEnded(ctx)
		}
	}
	if !g.live() {
		<-l.held
		return errLocked
	}
	if err := ctx.Err(); err != nil && !late {
		<-l.held
		return err
	}
	l.by = g
	return nil
}

// waitEnded is the failure of a wait that ctx's end ended.
func waitEnded(ctx context.Context) error {
	if err := ctx.Err(); !errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	return errWaitedOut
}

func (l *shellLock) Unlock() {
	l.releasing()
	l.by = nil
	<-l.held
}

// A test stands in for these, to end a generation as either runs.
var (
	loadRecord = holder.Load
	openKey    = (*holder.Record).Open
)

// New is a shell over cfg's key record, locked.
func New(cfg Config) (*Shell, error) {
	if cfg.Detect == nil {
		cfg.Detect = disk.Detect
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	// No request follows a redirect: the setup token, every proof and
	// every signed write are for the service they were made for, and a
	// redirect elsewhere is refused as that service's answer.
	client := http.Client{}
	if cfg.Client != nil {
		client = *cfg.Client
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	cfg.Client = &client
	if cfg.DisplayName == "" {
		cfg.DisplayName = "CYFR screen"
	}
	if len(cfg.DisplayName) > 64 {
		cfg.DisplayName = strings.ToValidUTF8(cfg.DisplayName[:64], "")
	}
	if cfg.Chip == nil {
		cfg.Chip = holder.ChipPresent
	}
	if cfg.Restart == nil {
		cfg.Restart = func() {}
	}
	if cfg.Unwatched == nil {
		cfg.Unwatched = func() string { return "" }
	}
	if cfg.SetupToken == nil {
		cfg.SetupToken = func(context.Context) (string, http.RoundTripper) { return "", nil }
	}
	if cfg.Directory == "" {
		cfg.Directory = account.DefaultDirectory
	}
	if cfg.Clients == nil {
		cfg.Clients = ClientFile(filepath.Join(filepath.Dir(cfg.Record), "client.json"))
	}
	s := &Shell{cfg: cfg, gen: newGeneration()}
	s.mu.held, s.mu.releasing, s.mu.waiting = make(chan struct{}, 1), s.publish, func() {}
	rec, err := holder.Load(cfg.Record)
	switch {
	case err == nil:
		s.rec = rec
	case !errors.Is(err, fs.ErrNotExist):
		return nil, fmt.Errorf("this device's key record %s cannot be read (%v)", cfg.Record, err)
	}
	if s.here, err = cfg.Clients.Load(); err != nil {
		return nil, fmt.Errorf("this device's standing at %s cannot be read (%v)", cfg.Address, err)
	}
	if s.unfinished, err = s.readAttempt(); err != nil {
		return nil, fmt.Errorf("the account this device was making cannot be read (%v)", err)
	}
	s.publish()
	return s, nil
}

// readAttempt is the account being made that is kept beside the key, or
// nil for none.
func (s *Shell) readAttempt() (*account.Attempt, error) {
	var a account.Attempt
	raw, err := os.ReadFile(s.attemptPath())
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, nil
	case err != nil:
		return nil, err
	case json.Unmarshal(raw, &a) != nil || a.Identifier == "":
		return nil, errors.New("it is not an account being made")
	}
	return &a, nil
}

// refresh reads the key record and the account being made again before a
// first-use action, so a shell acts on what this machine keeps now:
// another first use (a restarted screen) may have
// made the key, listed it in an account or begun an account since this
// shell read them. A key it did not make is the one it uses from here,
// and what it held for another key (a key held open, an account it was
// making) is dropped. A shell whose channel stands acts on its own key.
func (s *Shell) refresh() {
	if s.ch != nil {
		return
	}
	rec, err := loadRecord(s.cfg.Record)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return
	}
	if !s.current() {
		return
	}
	if rec == nil || s.rec == nil || !bytes.Equal(rec.PublicKey, s.rec.PublicKey) {
		if s.key != nil {
			s.key.Erase()
			s.key = nil
		}
		if s.making != nil {
			clear(s.making.key)
			s.making = nil
		}
	}
	s.rec = rec
	if s.making == nil {
		if a, err := s.readAttempt(); err == nil {
			s.unfinished = a
		}
	}
}

// madeElsewhere says this shell uses the key another first use made.
func (s *Shell) madeElsewhere() {
	s.say("Another screen on this machine made its key first, and this one uses that key: unlock it with that one's PIN or passphrase.")
}

func (s *Shell) attemptPath() string {
	return filepath.Join(filepath.Dir(s.cfg.Record), "attempt.json")
}

// errOtherAttempt is an account another first use on this machine began
// making with the same key first.
var errOtherAttempt = errors.New("another account is being made with this key")

// saveAttempt keeps the account being made: its first save only where no
// attempt is kept, so two first uses never make two accounts for one key,
// and every later save over its own.
func (s *Shell) saveAttempt(a account.Attempt) error {
	if !s.current() {
		return errLocked
	}
	if s.unfinished == nil || s.unfinished.Identifier != a.Identifier {
		err := createJSON(s.attemptPath(), a)
		if errors.Is(err, fs.ErrExist) {
			if held, _ := s.readAttempt(); held == nil || held.Identifier != a.Identifier {
				return errOtherAttempt
			}
			err = writeJSON(s.attemptPath(), a)
		}
		if err != nil {
			return err
		}
		s.unfinished = &a
		return nil
	}
	if err := writeJSON(s.attemptPath(), a); err != nil {
		return err
	}
	s.unfinished = &a
	return nil
}

// issued is what this CYFR's certificate says of this device's client.
type issued struct {
	Audience   string `json:"audience"`
	Kid        string `json:"kid"`
	Identifier string `json:"identifier"`
	Athanor    string `json:"athanor"`
	ClientID   string `json:"client_id"`
	NotBefore  int64  `json:"not_before"`
	ExpiresAt  int64  `json:"expires_at"`
}

func readIssued(cert json.RawMessage) issued {
	var i issued
	_ = json.Unmarshal(cert, &i)
	return i
}

// certified is whether the certificate held here is for this CYFR's
// address, this key and this account: one issued under the address CYFR
// had before a change of address, or for a key this machine no longer
// keeps, is not used, and the device says hello again.
func (s *Shell) certified() bool {
	i := readIssued(s.here.Certificate)
	return len(s.here.Certificate) > 0 && i.Audience == s.cfg.Address &&
		i.Kid == account.Kid(s.rec.PublicKey) && i.Identifier == s.rec.Identifier &&
		i.ClientID == s.here.ClientID
}

func (s *Shell) binding() Binding {
	return Binding{Home: s.cfg.Address, Athanor: readIssued(s.here.Certificate).Athanor,
		ClientID: s.here.ClientID, DeviceKey: s.rec.PublicKey}
}

func (s *Shell) report() []string {
	return s.cfg.Detect(s.cfg.DataDir).Capabilities()
}

// Page names what the device shows now.
type Page string

const (
	// PageSetup is a device with no key.
	PageSetup Page = "setup"
	// PageEnroll is a key no account lists yet: its code, the address
	// that adds it, and the name of the account to add it to.
	PageEnroll Page = "enroll"
	// PageRecovery is an account being made, its recovery code shown
	// until it is said saved; nothing was sent yet.
	PageRecovery Page = "recovery"
	// PageAccount is an account whose submission waits: a try again.
	PageAccount Page = "account"
	// PageName is an account whose name someone took meanwhile.
	PageName Page = "name"
	// PageResume is an account an earlier run began making: its recovery
	// code, typed, finishes it.
	PageResume   Page = "resume"
	PageLocked   Page = "locked"
	PageUnlocked Page = "unlocked"
	PageConfirm  Page = "confirm"
	PagePasskey  Page = "passkey"
)

// View is what a page draws.
type View struct {
	Page    Page
	Kind    holder.Kind
	Chip    bool
	Notice  string
	Storage disk.Report
	// Passphrase is the passphrase a setup without a chip takes, and
	// Drawn whether one is drawn. A page shows it only in the answer to
	// the request that drew it (pageView).
	Passphrase string
	Drawn      bool
	// RecoveryCode is the code shown on PageRecovery, and Name the name of
	// the account being made.
	RecoveryCode string
	Name         string
	// Terms is the address of the policy a new account accepts, once the
	// directory named one, and Accept whether the account being made
	// waits for them to be accepted (again).
	Terms   string
	Accept  bool
	Confirm *PendingConfirm
	Passkey *PendingPasskey
	// Code is the key's short code while no account lists it, AddURL the
	// account page that adds it (a QR code's text), and Key its public
	// half, which that page's address carries.
	Code   string
	AddURL string
	Key    string
	// Service is the account service's origin the add page is at, which
	// the device that approves must show beside the code.
	Service string
}

// View is the page the device shows now, and the notice of the last
// action or lock, which stays until the next action. A setup without a
// chip draws its passphrase at the first View; the pages read pageView,
// which draws nothing.
func (s *Shell) View() View {
	_, give, ok := s.take(context.Background())
	if !ok {
		return s.shownView()
	}
	defer give()
	if s.rec == nil && !s.cfg.Chip() {
		s.newPassphrase()
	}
	return s.view()
}

// pageView is View as the pages draw it for a request carrying proof: the
// recovery code only when proof is the current one, compared under the
// same lock that reads the code. It is false where the action could not
// take the shell.
func (s *Shell) pageView(ctx context.Context, proof []byte) (View, bool) {
	_, give, ok := s.take(ctx)
	if !ok {
		return View{}, false
	}
	defer give()
	v := s.view()
	if !s.holds(proof) {
		v.RecoveryCode = ""
	}
	v.Passphrase, v.Confirm, v.Passkey = "", nil, nil
	return v, true
}

// shownView is pageView for a plain read, waiting for no action in
// flight: what the shell knew as it was last released.
func (s *Shell) shownView() View {
	return s.onThisMachine(s.shown.Load().view)
}

// publish keeps what a plain read is shown. The caller holds the shell.
func (s *Shell) publish() {
	v := s.known()
	v.RecoveryCode, v.Passphrase, v.Confirm, v.Passkey = "", "", nil, nil
	s.shown.Store(&shownState{view: v, terms: s.terms, configured: s.configured})
}

// confirmView is pageView for the request that names ref: a drawn
// confirmation's preview goes only to a request naming its reference, the
// one the CYFR handed the page that asked, never to a plain read.
func (s *Shell) confirmView(ctx context.Context, ref string) (View, bool) {
	_, give, ok := s.take(ctx)
	if !ok {
		return View{}, false
	}
	defer give()
	v := s.view()
	v.RecoveryCode, v.Passphrase, v.Confirm, v.Passkey = "", "", nil, nil
	if s.confirm != nil && ref != "" && s.confirm.Ref == ref {
		v.Confirm = s.confirm
	}
	return v, true
}

// passkeyView is pageView for the request that names ref: a drawn
// passkey request and its code go only to a request naming its reference,
// the one Prism opened the window with, never to a plain read.
func (s *Shell) passkeyView(ctx context.Context, ref string) (View, bool) {
	_, give, ok := s.take(ctx)
	if !ok {
		return View{}, false
	}
	defer give()
	v := s.view()
	v.RecoveryCode, v.Passphrase, v.Confirm, v.Passkey = "", "", nil, nil
	if s.passkey != nil && ref != "" && s.passkey.Ref == ref {
		v.Page, v.Passkey = PagePasskey, s.passkey
	}
	return v, true
}

// drawPassphrase draws a new passphrase for a page's setup on a machine
// without a usable chip, replacing the one drawn before, and answers it
// for that request's answer alone; "" where the setup takes a PIN, or
// there is no setup.
func (s *Shell) drawPassphrase(ctx context.Context) string {
	_, give, ok := s.take(ctx)
	if !ok {
		return ""
	}
	defer give()
	s.refresh()
	if s.rec != nil || (s.cfg.Chip() && s.passphrase == "") {
		return ""
	}
	if !s.current() {
		return ""
	}
	s.passphrase = ""
	return s.newPassphrase()
}

// issueProof draws a fresh proof, replacing any earlier one, and answers
// it as the page keeps it. The caller holds the shell.
func (s *Shell) issueProof() string {
	clear(s.proof)
	s.proof = make([]byte, 32)
	_, _ = rand.Read(s.proof) // crypto/rand.Read never fails, by its contract.
	return base64.RawURLEncoding.EncodeToString(s.proof)
}

// holds is whether proof, as a page sends it, is the current proof,
// compared in constant time. The caller holds the shell.
func (s *Shell) holds(proof []byte) bool {
	if len(s.proof) == 0 {
		return false
	}
	got := make([]byte, base64.RawURLEncoding.DecodedLen(len(proof)))
	n, err := base64.RawURLEncoding.Decode(got, proof)
	return err == nil && subtle.ConstantTimeCompare(got[:n], s.proof) == 1
}

func (s *Shell) view() View { return s.onThisMachine(s.known()) }

// onThisMachine adds to v what is read of this machine as a page is drawn.
func (s *Shell) onThisMachine(v View) View {
	v.Storage, v.Chip = s.cfg.Detect(s.cfg.DataDir), s.cfg.Chip()
	return v
}

// known is the page the shell's state gives. The caller holds the shell.
func (s *Shell) known() View {
	v := View{Notice: s.notice}
	if s.terms != nil {
		v.Terms = s.terms.URL
	}
	if s.rec != nil {
		v.Kind = s.rec.Kind
	}
	switch m := s.making; {
	case s.rec == nil:
		v.Page = PageSetup
		v.Passphrase, v.Drawn = s.passphrase, s.passphrase != ""
	case m != nil && !m.saved:
		v.Page, v.RecoveryCode, v.Name = PageRecovery, m.code, m.attempt.Name
	case m != nil && m.taken:
		v.Page, v.Name = PageName, m.attempt.Name
	case m != nil:
		v.Page, v.Name = PageAccount, m.attempt.Name
		v.Accept = s.terms != nil && m.attempt.Accepted == ""
	case s.rec.Identifier == "" && s.unfinished != nil:
		v.Page, v.Name = PageResume, s.unfinished.Name
	case s.rec.Identifier == "":
		kid := account.Kid(s.rec.PublicKey)
		v.Page, v.Code, v.Key = PageEnroll, account.ShortCode(kid), account.B64(s.rec.PublicKey)
		v.Service = account.Directory{URL: s.cfg.Directory}.Origin()
		v.AddURL = v.Service + "/account/add#key=" + v.Key +
			"&alg=ed25519&kind=device&code=" + v.Code
	case s.ch == nil:
		v.Page = PageLocked
	case s.confirm != nil:
		v.Page, v.Confirm = PageConfirm, s.confirm
	case s.passkey != nil:
		v.Page, v.Passkey = PagePasskey, s.passkey
	default:
		v.Page = PageUnlocked
	}
	return v
}

// newPassphrase is the passphrase a software setup takes, drawn when none
// is and kept in memory until the setup takes it.
func (s *Shell) newPassphrase() string {
	if s.passphrase == "" {
		p, err := holder.GeneratePassphrase()
		if err == nil {
			s.passphrase = p
		}
	}
	return s.passphrase
}

// Begin clears the last notice as an action starts, and is whether it
// could: not one begun before a lock, and not one whose wait for the shell
// ran out.
func (s *Shell) Begin(ctx context.Context) bool {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return false
	}
	defer give()
	s.notice = ""
	underwayOf(ctx).took = false // its work has not begun
	return true
}

// say sets the sentence the next page shows, for an action whose
// generation is current.
func (s *Shell) say(format string, args ...any) {
	if s.current() {
		s.notice = fmt.Sprintf(format, args...)
	}
}

// tell is say for what a page's answer found once its action was done.
func (s *Shell) tell(ctx context.Context, sentence string) {
	_, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.say("%s", sentence)
}

// sentence is what the person reads for a failure, naming this device as
// the shell's Config does.
func (s *Shell) sentence(err error) string { return sentence(err) }

// CompanySignIn is what a person reads at a CYFR that requires a company
// sign-in, which the CYFR app does not offer.
const CompanySignIn = "This CYFR requires company sign-in. Open its address in a browser to continue. " +
	"The CYFR app does not support company sign-in yet."

// Unbound is a Config.Client's refusal to connect where what it is bound
// to no longer holds: nothing was sent, and the person reads Sentence.
// Moved is the CYFR now named at another address or account service than
// this shell's, which a shell made afresh would follow.
type Unbound struct {
	Sentence string
	Moved    bool
}

func (u *Unbound) Error() string { return u.Sentence }

// sentence is what the person reads for a failure of this screen.
func sentence(err error) string {
	var locked unwatchedError
	if errors.As(err, &locked) {
		return string(locked)
	}
	var intent *IntentError
	var dir *account.DirectoryRefusal
	var refused *RefusedError
	var unbound *Unbound
	var refusing *RefusingError
	switch {
	case errors.As(err, &unbound):
		return unbound.Sentence
	case errors.As(err, &refusing):
		unit := "seconds"
		if refusing.Seconds == 1 {
			unit = "second"
		}
		return fmt.Sprintf("CYFR is refusing attempts for the moment. Try again in %d %s.", refusing.Seconds, unit)
	case errors.As(err, &refused):
		return refused.Message
	case errors.Is(err, holder.ErrWrongSecret), errors.Is(err, holder.ErrSecretShape):
		return "That is not this device's PIN or passphrase. Nothing was sent anywhere."
	case errors.Is(err, holder.ErrLockedOut):
		return "Too many wrong PINs: this device's chip takes one more try every ten minutes."
	case errors.Is(err, ErrRevoked):
		return "CYFR does not take this device now: it was removed, CYFR does not admit your account, or CYFR was restored from a backup, which suspends every device. Unlocking it again asks CYFR again."
	case errors.Is(err, ErrCompanySignIn):
		return CompanySignIn
	case errors.Is(err, ErrUnavailable):
		return "CYFR could not be reached. Check that it is running, then try again."
	case errors.Is(err, ErrRefused), errors.Is(err, ErrRefusedChallenge):
		return "CYFR did not accept this device's proof. Nothing was signed for anything else."
	case errors.Is(err, ErrRenew):
		return "This device's certificate expired, and with it its session: unlock it again to renew it."
	case errors.Is(err, account.ErrUnreachable):
		return "Your account could not be reached just now. Try again; nothing is lost."
	case errors.As(err, &dir) && dir.Code == "gone":
		return "That account was closed."
	case errors.As(err, &dir) && dir.Code == "not_found":
		return "No account is listed by that name."
	case errors.As(err, &intent):
		return intent.Error() + "."
	}
	return err.Error()
}

// checkSecret checks the secret given twice before anything is made: the
// same both times, six digits for the chip, or the passphrase the page
// showed where there is no chip. It answers whether the chip holds it.
func (s *Shell) checkSecret(secret, again []byte) (bool, error) {
	if string(secret) != string(again) {
		s.say("The two entries differ. Enter the same one twice.")
		return false, errors.New("differ")
	}
	if s.cfg.Chip() && s.passphrase == "" {
		if err := holder.CheckPIN(secret); err != nil {
			s.say("A PIN is six digits.")
			return false, err
		}
		return true, nil
	}
	if err := holder.CheckPassphrase(secret); err != nil {
		s.say("Without a chip, this device needs the six-word passphrase shown, not a short PIN.")
		return false, err
	}
	if string(secret) != s.passphrase {
		s.say("That is not the passphrase shown last. Enter it exactly as shown.")
		return false, errors.New("not the shown passphrase")
	}
	return false, nil
}

// Make makes this device's key under the PIN, or under the passphrase
// when the machine has no usable chip, given twice, and writes it before
// anything is shown or sent, so its code, a retry and a lost answer all
// name the same key.
func (s *Shell) Make(secret, again []byte) { s.makeKey(context.Background(), secret, again) }

// makeKey is Make, answering the passphrase it drew when the chip could
// not keep the PIN, or "".
func (s *Shell) makeKey(ctx context.Context, secret, again []byte) (drawn string) {
	defer erase(secret, again)
	_, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	defer s.drawnSince(s.passphrase, &drawn)
	s.refresh()
	if s.rec != nil {
		s.madeElsewhere()
		return
	}
	_, _ = s.newRecord(secret, again)
	return
}

// drawnSince sets *drawn to the passphrase drawn since it was before,
// when one was: a chip that cannot keep the PIN draws one mid-request.
// The caller holds the shell.
func (s *Shell) drawnSince(before string, drawn *string) {
	if s.passphrase != before {
		*drawn = s.passphrase
	}
}

func (s *Shell) newRecord(secret, again []byte) (*holder.Record, error) {
	chip, err := s.checkSecret(secret, again)
	if err != nil {
		return nil, err
	}
	var rec *holder.Record
	if chip {
		rec, err = holder.NewChip(secret)
	} else {
		rec, err = holder.NewSoftware(secret)
	}
	if !s.current() {
		return nil, errLocked
	}
	if chip && errors.Is(err, holder.ErrNoChip) {
		s.newPassphrase()
		s.say("This machine's chip cannot keep your PIN safely (%v). Use the passphrase below instead.", err)
		return nil, err
	}
	if err != nil {
		s.say("This device could not make its key: %v.", err)
		return nil, err
	}
	err = rec.Create(s.cfg.Record)
	if errors.Is(err, holder.ErrKeyExists) {
		s.refresh()
		s.madeElsewhere()
		return nil, err
	}
	if err != nil {
		s.say("This device could not save its key (%v). Nothing was sent anywhere.", err)
		return nil, err
	}
	s.passphrase = ""
	s.rec = rec
	return rec, nil
}

// Setup makes this device's key and an account whose first key it is,
// named name, its policy accepted when the directory names one: the key is
// written and held open, and the account's recovery code is shown, before
// anything is sent (Saved sends it). The held key opens this device's
// first connection once the account is made.
func (s *Shell) Setup(ctx context.Context, name, accepted string, secret, again []byte) {
	s.setup(ctx, name, accepted, secret, again)
}

// setup is Setup, answering the proof the opened key issues, or "" when
// the key was not opened, and the passphrase it drew when the chip could
// not keep the PIN, or "".
func (s *Shell) setup(ctx context.Context, name, accepted string, secret, again []byte) (proof, drawn string) {
	defer erase(secret, again)
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	defer s.drawnSince(s.passphrase, &drawn)
	s.refresh()
	if s.rec != nil {
		s.madeElsewhere()
		return
	}
	// The PIN or passphrase is checked before the account service is
	// asked anything, so a refused one is said even with it out of reach.
	if _, err := s.checkSecret(secret, again); err != nil {
		return
	}
	c, ok := s.checkNew(ctx, name, accepted)
	if !ok {
		return
	}
	rec, err := s.newRecord(secret, again)
	if err != nil {
		return
	}
	key, err := openKey(rec, secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	if !s.current() {
		key.Erase()
		return
	}
	s.key = key
	proof = s.issueProof()
	s.begin(c, name, accepted)
	return
}

// Create makes an account whose first key is this device's, as Setup does,
// for a key made before.
func (s *Shell) Create(ctx context.Context, name, accepted string) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.refresh()
	if s.creatable() {
		s.create(ctx, name, accepted)
	}
}

// createOpened is Create for a page, whose form carries the PIN: the PIN
// opens the key first, which issues the proof the recovery code is shown
// to, and the key is erased again. It answers that proof, or "" when the
// key was not opened, and then nothing is made.
func (s *Shell) createOpened(ctx context.Context, name, accepted string, secret []byte) string {
	defer erase(secret)
	ctx, give, ok := s.take(ctx)
	if !ok {
		return ""
	}
	defer give()
	s.refresh()
	if !s.creatable() {
		return ""
	}
	key, err := openKey(s.rec, secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return ""
	}
	key.Erase()
	if !s.current() {
		return ""
	}
	proof := s.issueProof()
	s.create(ctx, name, accepted)
	return proof
}

// creatable is whether a key made before waits for an account of its own.
func (s *Shell) creatable() bool {
	return s.rec != nil && s.rec.Identifier == "" && s.making == nil && s.unfinished == nil
}

func (s *Shell) create(ctx context.Context, name, accepted string) {
	if c, ok := s.checkNew(ctx, name, accepted); ok {
		s.begin(c, name, accepted)
	}
}

// Terms is the policy a new account accepts at this device's directory, or
// nil where its registry asks for none.
func (s *Shell) Terms(ctx context.Context) (*account.Policy, error) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return nil, errNotTaken
	}
	defer give()
	c, err := s.config(ctx)
	return c.Policy, err
}

func (s *Shell) config(ctx context.Context) (account.Config, error) {
	c, err := s.directoryConfig(ctx)
	if err == nil && s.current() {
		s.terms, s.configured = c.Policy, true
	}
	return c, err
}

func (s *Shell) directoryConfig(ctx context.Context) (account.Config, error) {
	return account.Directory{URL: s.cfg.Directory, Client: s.cfg.Client}.Config(ctx)
}

// readTerms reads the directory's configuration once, so a page that
// makes an account shows the terms it accepts before it is submitted. It
// holds the shell only to keep what it read, in the generation it began
// reading in.
func (s *Shell) readTerms(parent context.Context) {
	if s.shown.Load().configured {
		return
	}
	ctx, done := s.act(parent)
	defer done()
	c, err := s.directoryConfig(ctx)
	if err != nil {
		return
	}
	_, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	if !s.configured {
		s.terms, s.configured = c.Policy, true
	}
}

// checkNew reads the directory's configuration and checks a new account's
// name and acceptance before anything is made.
func (s *Shell) checkNew(ctx context.Context, name, accepted string) (account.Config, bool) {
	c, err := s.config(ctx)
	if err != nil {
		s.say("The account service could not be reached (%v). Nothing was made; try again.", err)
		return c, false
	}
	if c.Policy != nil && accepted != c.Policy.Version {
		s.say("To make your account, accept the terms at %s.", c.Policy.URL)
		return c, false
	}
	switch err := account.CheckName(ctx, account.Registry{Origin: c.Registry, Client: s.cfg.Client}, name); {
	case err == nil:
		return c, true
	case errors.Is(err, account.ErrNameTaken):
		s.say("Someone holds the name @%s. Choose another.", name)
	case !account.IsHandle(name):
		s.say("A name is 1 to 39 of a-z, 0-9 and single hyphens inside it.")
	default:
		s.say("The name could not be checked (%s). Nothing was made; try again.", s.sentence(err))
	}
	return c, false
}

// begin draws the recovery secret and composes the account with this
// device's key its first key, and shows the recovery code.
func (s *Shell) begin(c account.Config, name, accepted string) {
	a, secret, key, err := account.Begin(c, name, accepted, s.rec.PublicKey, s.cfg.Now().UnixMilli())
	if err != nil {
		s.say("Your account could not be composed: %v.", err)
		return
	}
	code, err := account.EncodeRecoveryCode(a.Identifier, secret)
	clear(secret)
	if err != nil {
		s.say("Your account could not be composed: %v.", err)
		return
	}
	if !s.current() {
		return
	}
	s.making = &making{attempt: a, key: key, code: code}
}

// asPage runs act for a page's request only when it carries the current
// proof, compared under the shell's one lock, which act then runs under:
// every page action that acts with what the shell holds for the page that
// typed the PIN (the held key, an account's recovery key, its claim, its
// acceptance, its name) passes through here. Without the proof nothing is
// done, and the page says so.
func (s *Shell) asPage(ctx context.Context, proof []byte, act func(context.Context)) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	if !s.holds(proof) {
		s.say("Only the page this device's PIN or passphrase was typed on can do that. Nothing was sent.")
		return
	}
	act(ctx)
}

// saved says the recovery code is saved and submits the account (register,
// append, then the name), or submits it again after an answer that did
// not come; accepted is the policy version accepted again when the
// registry asked for a newer one. Done, the key's record names the account,
// and a key held from a setup opens this device's first connection. The
// page reaches it under the lock, through asPage.
func (s *Shell) saved(ctx context.Context, accepted string) {
	s.refresh()
	if !s.current() {
		return
	}
	m := s.making
	if m == nil || m.taken || s.listedElsewhere(m) {
		return
	}
	if !m.saved {
		err := s.saveAttempt(m.attempt)
		if errors.Is(err, errOtherAttempt) {
			clear(m.key)
			s.making = nil
			s.refresh()
			s.say("Another screen on this machine began an account with this key first: finish it with its recovery code. Nothing was sent for the one shown here.")
			return
		}
		if err != nil {
			s.say("This device could not keep the account it is making (%v). Nothing was sent.", err)
			return
		}
		m.saved, m.code = true, ""
	}
	if accepted != "" && accepted != m.attempt.Accepted {
		m.attempt.Accepted, m.attempt.AcceptDone = accepted, false
	}
	s.submit(ctx)
}

// Resume finishes an account an earlier run began making, with its
// recovery code, which re-derives the recovery key.
func (s *Shell) Resume(ctx context.Context, code string) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.resume(ctx, code)
}

// resumeByPage is Resume for a page: the recovery code typed is the
// account's own authority, so a code that re-derives the account's key
// issues the proof, which the account's later steps (a name, the terms)
// take. It answers that proof, or "".
func (s *Shell) resumeByPage(ctx context.Context, code string) string {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return ""
	}
	defer give()
	if !s.resume(ctx, code) || !s.current() {
		return ""
	}
	return s.issueProof()
}

// resume answers whether code re-derived the account's recovery key.
func (s *Shell) resume(ctx context.Context, code string) bool {
	s.refresh()
	if s.unfinished == nil || s.making != nil || s.rec == nil || s.rec.Identifier != "" {
		return false
	}
	identifier, secret, err := account.DecodeRecoveryCode(code)
	switch {
	case errors.Is(err, account.ErrTypo):
		s.say("That recovery code has a typo. Check it and type it again.")
		return false
	case err != nil:
		s.say("That is not a recovery code.")
		return false
	case identifier != s.unfinished.Identifier:
		clear(secret)
		s.say("That is another account's recovery code.")
		return false
	}
	key := account.RecoveryKey(secret)
	clear(secret)
	// The code is the account's authority only when its key is the
	// recovery key the attempt's genesis was made with: a code's checksum
	// anyone can compute, and its identifier is no secret. Checked before
	// anything is sent, and before the proof is issued.
	if !madeWith(s.unfinished.Genesis, s.unfinished.Identifier, key) {
		clear(key)
		s.say("That recovery code is not this account's.")
		return false
	}
	if !s.current() {
		return false
	}
	s.making = &making{attempt: *s.unfinished, key: key, saved: true}
	s.submit(ctx)
	return true
}

// madeWith is whether genesis, signed and naming identifier, lists key's
// public half among its recovery keys.
func madeWith(genesis map[string]any, identifier string, key ed25519.PrivateKey) bool {
	state, err := account.Walk([]any{genesis})
	if err != nil || state.Identifier != identifier {
		return false
	}
	pub := key.Public().(ed25519.PublicKey)
	for _, listed := range state.Recovery {
		if bytes.Equal(listed, pub) {
			return true
		}
	}
	return false
}

// Rename takes another name for the account being made, whose name
// someone took meanwhile or the registry keeps reserved.
func (s *Shell) Rename(ctx context.Context, name string) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.rename(ctx, name)
}

func (s *Shell) rename(ctx context.Context, name string) {
	s.refresh()
	if !s.current() {
		return
	}
	m := s.making
	if m == nil || !m.taken || s.listedElsewhere(m) {
		return
	}
	name = strings.TrimPrefix(strings.TrimSpace(name), "@")
	if !account.IsHandle(name) {
		s.say("A name is 1 to 39 of a-z, 0-9 and single hyphens inside it.")
		return
	}
	m.attempt.Name, m.taken = name, false
	s.submit(ctx)
}

// listedElsewhere is whether the key is listed in another account than
// the one m makes, which another first use finished meanwhile: m is
// dropped, and nothing more of it is sent.
func (s *Shell) listedElsewhere(m *making) bool {
	if s.rec == nil || s.rec.Identifier == "" || s.rec.Identifier == m.attempt.Identifier {
		return false
	}
	clear(m.key)
	s.making = nil
	s.say("This machine's key is on an account already, made or added by another screen here: unlock it with its PIN or passphrase.")
	return true
}

func (s *Shell) submit(ctx context.Context) {
	m := s.making
	now := func() int64 { return s.cfg.Now().UnixMilli() }
	a := m.attempt // Submit changes it as it goes
	err := account.Submit(ctx, &a, m.key, now, s.cfg.Client, s.saveAttempt)
	if !s.current() {
		return
	}
	m.attempt = a
	switch {
	case errors.Is(err, account.ErrNameTaken):
		m.taken = true
		s.say("Someone holds the name @%s. Choose another: your account is made, and takes a name once one is free.", m.attempt.Name)
		return
	case errors.Is(err, account.ErrNameReserved):
		m.taken = true
		s.say("The name @%s is reserved. Choose another: your account is made, and takes a name once one is free.", m.attempt.Name)
		return
	case errors.Is(err, account.ErrPolicyChanged):
		m.attempt.Accepted = ""
		c, _ := s.config(ctx)
		url := "the account service"
		if c.Policy != nil {
			url = c.Policy.URL
		}
		s.say("The account service's terms changed: accept the terms at %s to finish.", url)
		return
	case err != nil:
		s.say("Your account is not finished: %s", s.sentence(err))
		return
	}
	s.rec.Identifier, s.rec.Directory = m.attempt.Identifier, m.attempt.Directory
	if err := s.rec.Save(s.cfg.Record); err != nil {
		s.say("This device could not save its account (%v). Try again.", err)
		return
	}
	clear(m.key)
	s.making, s.unfinished = nil, nil
	_ = os.Remove(s.attemptPath())
	s.firstConnection(ctx)
}

// firstConnection opens the key held since a setup, once its account
// lists it, or leaves the device locked for its PIN.
func (s *Shell) firstConnection(ctx context.Context) {
	if s.key == nil {
		return
	}
	if err := s.connect(ctx, s.key); err != nil && s.current() {
		s.key.Erase()
		s.key = nil
		s.say("%s", s.sentence(err))
	}
}

// pollEvery is how often an enrollment reads the account's log.
var pollEvery = 2 * time.Second

// enrollByPage adds this device to the account named name, once a device
// of the person's approves it: the name is resolved at the registry the
// directory names, and that account's log is read every pollEvery, for at
// most wait, until it lists this key. Reading the account's public log and
// keeping which account lists this key needs no authority; opening the
// first connection with a key held since a setup does, so only a request
// carrying the current proof, compared under this lock, opens it, and any
// other leaves the device locked for its PIN.
func (s *Shell) enrollByPage(ctx context.Context, name string, wait time.Duration, proof []byte) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.enroll(ctx, name, wait, s.holds(proof))
}

// enroll is enrollByPage's, under the lock; useHeld is whether the first
// connection may open with a key held since a setup.
func (s *Shell) enroll(ctx context.Context, name string, wait time.Duration, useHeld bool) {
	s.refresh()
	if s.rec == nil || s.rec.Identifier != "" || s.making != nil || s.unfinished != nil {
		return
	}
	name = strings.TrimPrefix(strings.TrimSpace(name), "@")
	if !account.IsHandle(name) {
		s.say("A name is 1 to 39 of a-z, 0-9 and single hyphens inside it.")
		return
	}
	c, err := s.config(ctx)
	if err != nil {
		s.say("The account service could not be reached (%v). Try again.", err)
		return
	}
	found, err := account.Registry{Origin: c.Registry, Client: s.cfg.Client}.Handle(ctx, name)
	var ref *account.Refusal
	switch {
	case errors.As(err, &ref) && ref.Reason == "handle_not_found":
		s.say("No account is called @%s.", name)
		return
	case err != nil:
		s.say("The name could not be looked up (%s).", s.sentence(err))
		return
	case found.Directory != s.cfg.Directory:
		// The account service this CYFR uses is the one approved for it;
		// another the registry names is never contacted.
		s.say("@%s's account is at the account service %s, not at %s, which this CYFR uses, so nothing was sent there. "+
			"Add this device to an account at %s.", name, found.Directory, s.cfg.Directory, s.cfg.Directory)
		return
	}
	d := account.Directory{URL: found.Directory, Client: s.cfg.Client}
	kid := account.Kid(s.rec.PublicKey)
	waiting, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	for {
		state, err := d.Read(waiting, found.Identifier)
		if err == nil {
			if _, listed := state.Key(kid); listed {
				break
			}
		}
		var dir *account.DirectoryRefusal
		if errors.As(err, &dir) && dir.Code == "gone" {
			s.say("%s", s.sentence(err))
			return
		}
		select {
		case <-waiting.Done():
			s.say("This device is not on @%s's account yet. Approve it on another device of yours, then try again.", name)
			return
		case <-time.After(pollEvery):
		}
	}
	pub := s.rec.PublicKey
	s.refresh()
	if !s.current() {
		return
	}
	switch {
	case s.rec == nil || !bytes.Equal(s.rec.PublicKey, pub):
		return
	case s.rec.Identifier == found.Identifier:
		if useHeld {
			s.firstConnection(ctx)
		}
		return
	case s.rec.Identifier != "":
		s.say("This machine's key is on another account already, added by another screen here.")
		return
	}
	s.rec.Identifier, s.rec.Directory = found.Identifier, found.Directory
	if err := s.rec.Save(s.cfg.Record); err != nil {
		s.say("This device could not save its account (%v). Try again.", err)
		return
	}
	if useHeld {
		s.firstConnection(ctx)
	}
}

// CheckListed reads the log of the account the key's record names, before
// an unlock asks for the PIN, as Enroll reads it. A log that no longer
// lists the key (removed from the account, or replaced along with every
// other key by a recovery) makes the record name no account and drops
// the certificate held here, which that removal retired at this CYFR: the device shows its code again and waits to be approved as a
// first enrollment does, with the same key, and says hello once listed.
// A log that cannot be read, or an account that is gone, changes nothing:
// the unlock goes on and the CYFR decides.
func (s *Shell) CheckListed(ctx context.Context) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	s.refresh()
	if s.rec == nil || s.rec.Identifier == "" || s.ch != nil || s.making != nil {
		return
	}
	directory := s.rec.Directory
	if directory == "" {
		directory = s.cfg.Directory
	}
	state, err := account.Directory{URL: directory, Client: s.cfg.Client}.Read(ctx, s.rec.Identifier)
	if err != nil {
		return
	}
	if _, listed := state.Key(account.Kid(s.rec.PublicKey)); listed {
		return
	}
	if !s.current() {
		return
	}
	unlisted := *s.rec
	unlisted.Identifier, unlisted.Directory = "", ""
	if err := unlisted.Save(s.cfg.Record); err != nil {
		s.say("Your account no longer lists this device's key, and this device could not keep that (%v). Try again.", err)
		return
	}
	s.rec = &unlisted
	if len(s.here.Certificate) > 0 {
		s.forget()
	}
	s.say("Your account no longer lists this device's key. Add the same key to your account again to go on.")
}

// Unlock opens the key with the PIN (or passphrase) and opens the channel.
// A wrong PIN is said and never retried.
func (s *Shell) Unlock(ctx context.Context, secret []byte) { s.unlock(ctx, secret) }

// unlock is Unlock, answering the proof the opened key issues, or "" when
// the key was not opened.
func (s *Shell) unlock(ctx context.Context, secret []byte) string {
	defer erase(secret)
	ctx, give, ok := s.take(ctx)
	if !ok {
		return ""
	}
	defer give()
	s.refresh()
	if s.rec == nil || s.rec.Identifier == "" || s.ch != nil || !s.current() {
		return ""
	}
	if s.key != nil {
		s.key.Erase()
		s.key = nil
	}
	key, err := openKey(s.rec, secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return ""
	}
	if !s.current() {
		key.Erase()
		return ""
	}
	proof := s.issueProof()
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.say("%s", s.sentence(err))
	}
	return proof
}

// connect opens the channel under key and holds both: the device is
// unlocked from here until a lock. A device this CYFR has not certified
// says hello first, dropping a certificate it holds that it will not
// present; one whose standing ended here keeps no certificate, so its
// next unlock says hello again.
func (s *Shell) connect(ctx context.Context, key *holder.Key) error {
	if err := s.watched(); err != nil {
		return err
	}
	if !s.current() {
		return errLocked
	}
	began := s.mu.by
	renewed := func(cert json.RawMessage) { s.renewed(began, cert) }
	d := Dialer{Address: s.cfg.Address, Client: s.cfg.Client}
	var ch *Channel
	var err error
	if s.certified() {
		ch, err = d.Open(ctx, Device{Binding: s.binding(), Certificate: s.here.Certificate}, key, s.report, renewed)
	} else {
		if len(s.here.Certificate) > 0 {
			s.forget()
		}
		admission, through := s.admission(ctx)
		if through != nil {
			// Client as it is, following no redirect, over that transport.
			bound := *s.cfg.Client
			bound.Transport = through
			d.Client = &bound
		}
		h := Hello{Key: s.rec.PublicKey, Identifier: s.rec.Identifier, HolderKind: string(s.rec.Kind),
			DisplayName: s.cfg.DisplayName, Admission: admission}
		ch, err = d.Hello(ctx, h, key, s.admitted, s.report, renewed)
	}
	// The handshake's last write can be out as a lock ends the generation.
	// What began before that lock opens nothing.
	if !s.current() {
		if ch != nil {
			ch.drop()
		}
		return errLocked
	}
	if errors.Is(err, ErrRevoked) {
		s.forget()
	}
	if err != nil {
		return err
	}
	s.key, s.ch = key, ch
	s.open.Store(true)
	s.scheduleRenewal(began)
	go s.watch(ch, began)
	return nil
}

// admission is the capability a first hello brings and the transport it
// goes by: none once this CYFR admitted this device (the door decides),
// else the setup token, where SetupToken answers one.
func (s *Shell) admission(ctx context.Context) (map[string]any, http.RoundTripper) {
	if s.here.ClientID != "" {
		return nil, nil
	}
	if t, through := s.cfg.SetupToken(ctx); t != "" {
		return map[string]any{"setup": t}, through
	}
	return nil, nil
}

// admitted keeps the client and certificate a hello was answered before
// the connection goes on.
func (s *Shell) admitted(a Admitted) error {
	if !s.current() {
		return errLocked
	}
	s.here.ClientID, s.here.Certificate = a.ClientID, a.Certificate
	return s.cfg.Clients.Update(func(c *ClientRecord) bool {
		c.ClientID, c.Certificate = a.ClientID, a.Certificate
		return true
	})
}

// forget drops the certificate of a standing that ended here, keeping the
// client id, so the next unlock says hello without a capability.
func (s *Shell) forget() {
	s.here.Certificate = nil
	_ = s.cfg.Clients.Update(func(c *ClientRecord) bool { c.Certificate = nil; return true })
}

// renewed persists a certificate the CYFR issued to a channel of g. It
// arrives on the channel's own goroutine, or during a connect whose caller
// holds the shell, so it takes the shell on a goroutine of its own, while
// g is current, and answers a channel closed as that goroutine ends. A
// device that dies, or locks, before it is written still holds the old
// certificate, which locates the client for the next renewal.
func (s *Shell) renewed(g *generation, cert json.RawMessage) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		if s.mu.lockFor(g.ended, g, false) != nil {
			return
		}
		defer s.mu.Unlock()
		s.here.Certificate = cert
		_ = s.cfg.Clients.Update(func(c *ClientRecord) bool { c.Certificate = cert; return true })
	}()
	return done
}

// scheduleRenewal renews the certificate over the channel of g at half its
// life.
func (s *Shell) scheduleRenewal(g *generation) {
	i := readIssued(s.here.Certificate)
	if i.ExpiresAt <= i.NotBefore {
		return
	}
	at := time.UnixMilli(i.NotBefore + (i.ExpiresAt-i.NotBefore)/2)
	wait := max(at.Sub(s.cfg.Now()), time.Second)
	ch := s.ch
	s.renewal = time.AfterFunc(wait, func() {
		// Not g's: a write cancelled would close the channel under the
		// lock's proofs (Channel.Call). The lock's close ends it.
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = ch.Renew(ctx)
		if s.mu.lockFor(g.ended, g, false) != nil {
			return
		}
		defer s.mu.Unlock()
		if s.ch == ch {
			s.scheduleRenewal(g)
		}
	})
}

// watch locks the device when its channel ends under it: an ended
// standing or a CYFR gone away ends the unlock, with the reason on the
// lock page.
func (s *Shell) watch(ch *Channel, g *generation) {
	<-ch.Done()
	// A lock that ended g locks, and is why, also where what it cut short
	// is what ended the channel.
	locked, first := s.end(g)
	if !first {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	defer locked()
	if s.ch != ch {
		return
	}
	err := ch.Err()
	if errors.Is(err, ErrRevoked) {
		s.forget()
	}
	s.lock(s.sentence(err))
}

// errNoProof is a request for a ticket without the current proof.
var errNoProof = errors.New("not the page that unlocked")

// Ticket reserves one session at the CYFR (reserve) for a request carrying
// the current proof, checked under the same lock, and answers where the
// browser goes: the CYFR's completion page with the ticket in its
// fragment, which no request carries.
func (s *Shell) Ticket(ctx context.Context, proof []byte) (string, error) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return "", errNotTaken
	}
	defer give()
	if !s.holds(proof) {
		return "", errNoProof
	}
	ticket, err := s.reserve(ctx)
	if err != nil {
		return "", err
	}
	return strings.TrimRight(s.cfg.Address, "/") + "/auth/device/complete#" + ticket, nil
}

// reserve asks the CYFR for one session (session.unlock), signs that
// reservation, pre-signs the lock of exactly that session and keeps it,
// and answers the CYFR's one-time ticket for it. The caller holds the
// shell.
func (s *Shell) reserve(ctx context.Context) (string, error) {
	if s.ch == nil {
		return "", errors.New("locked")
	}
	if err := s.watched(); err != nil {
		return "", err
	}
	raw, err := s.ch.Call(ctx, "session.unlock", nil)
	if err != nil {
		return "", err
	}
	var asked struct {
		Challenge json.RawMessage `json:"challenge"`
	}
	if err := json.Unmarshal(raw, &asked); err != nil {
		return "", ErrRefused
	}
	c, err := Challenge(asked.Challenge, "unlock", s.binding())
	if err != nil {
		return "", err
	}
	session := c["session_id"].(string)
	proof, err := Prove(c, s.key)
	if err != nil {
		return "", err
	}
	lock, err := LockProof(s.binding(), session, s.key)
	if err != nil {
		return "", err
	}
	if !s.current() {
		return "", errLocked
	}
	// The lock is kept before the reservation is spent: a lock from here
	// on retires it, redeemed or not.
	s.locks = append(s.locks, lock)
	raw, err = s.ch.Call(ctx, "session.unlock", map[string]any{"proof": proof})
	if err != nil {
		return "", err
	}
	var got struct {
		Ticket    string `json:"ticket"`
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(raw, &got); err != nil || got.SessionID != session || got.Ticket == "" {
		return "", ErrRefused
	}
	if !s.current() {
		return "", errLocked
	}
	return got.Ticket, nil
}

// Lock locks the device, why saying what the lock page tells the person.
// It ends the generation before it takes the shell, so it waits for no
// action, and once it returns none begun before it changes or opens
// anything. What takes no context is finished first: a key made or opened
// under a passphrase (Argon2id, two of them in a setup) or by the chip.
func (s *Shell) Lock(why string) {
	locked, _ := s.end(nil)
	s.mu.Lock()
	defer s.mu.Unlock()
	defer locked()
	s.lock(why)
}

// errLocked is an action's end by a lock, and why a lock's own close ended
// the channel.
var errLocked = errors.New("locked")

// errNotTaken is an action that could not take the shell, whatever ended
// it: no sentence says it (Server.gaveUp).
var errNotTaken = errors.New("this device was not taken for the action")

// end ends the current generation for a lock, which calls locked once it
// has locked and before it gives the shell up. With only, it ends that one
// alone, and is false where a lock ended it first.
func (s *Shell) end(only *generation) (locked func(), ok bool) {
	s.genMu.Lock()
	defer s.genMu.Unlock()
	g := s.gen
	if only != nil && (g != only || !g.live()) {
		return nil, false
	}
	g.locks++
	g.end()
	return func() {
		s.genMu.Lock()
		defer s.genMu.Unlock()
		if g.locks--; g.locks == 0 {
			s.gen = newGeneration()
		}
	}, true
}

// act begins an action in the current generation, until done: its context
// ends with parent's and with that generation.
func (s *Shell) act(parent context.Context) (ctx context.Context, done func()) {
	s.genMu.Lock()
	g := s.gen
	s.genMu.Unlock()
	ctx, stop := context.WithCancelCause(context.WithValue(parent, underwayKey{}, &underway{g: g}))
	unhook := context.AfterFunc(g.ended, func() { stop(errLocked) })
	if !g.live() {
		stop(errLocked)
	}
	return ctx, func() {
		unhook()
		stop(nil)
	}
}

// take takes the shell for ctx's action, or for one begun now where ctx
// has none, until give. It is false once that action's generation ended,
// once a wait of it for the shell ran out, and once its context ended,
// but where it took the shell before and finds it free (underway).
func (s *Shell) take(ctx context.Context) (held context.Context, give func(), ok bool) {
	done := func() {}
	if underwayOf(ctx) == nil {
		ctx, done = s.act(ctx)
	}
	a := underwayOf(ctx)
	if a.outwaited {
		done()
		return ctx, nil, false
	}
	if err := s.mu.lockFor(ctx, a.g, a.took); err != nil {
		a.outwaited = errors.Is(err, errWaitedOut)
		done()
		return ctx, nil, false
	}
	a.took = true
	return ctx, func() {
		s.mu.Unlock()
		done()
	}, true
}

// current is whether the action holding the shell may still change it: its
// generation has not ended. The caller holds the shell; holding it by no
// action, it may not.
func (s *Shell) current() bool { return s.mu.by != nil && s.mu.by.live() }

// lock submits each held session's lock proof, closes the channel, erases
// the key and every secret the shell held, an account's recovery key
// among them, and starts the browser again on the lock page, in that
// order: the sessions end at the CYFR before the page that used them is
// gone.
func (s *Shell) lock(why string) {
	if s.renewal != nil {
		s.renewal.Stop()
		s.renewal = nil
	}
	ch := s.ch
	if ch != nil {
		// A page drawn while the CYFR is told is the lock page already.
		s.ch, s.confirm, s.passkey = nil, nil, nil
		if why != "" {
			s.notice = why
		}
		s.publish()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		for _, proof := range s.locks {
			_, _ = ch.Call(ctx, "session.lock", map[string]any{"proof": proof})
		}
		cancel()
		ch.Close()
	}
	if s.key != nil {
		s.key.Erase()
	}
	if s.making != nil {
		clear(s.making.key)
	}
	clear(s.proof)
	s.key, s.locks, s.making, s.confirm, s.passkey, s.passphrase, s.proof = nil, nil, nil, nil, nil, "", nil
	if ch != nil {
		s.cfg.Restart()
		s.open.Store(false)
	}
}

// Unlocked is whether the channel stands, until the lock that closes it
// is done. It waits for nothing.
func (s *Shell) Unlocked() bool { return s.open.Load() }

// unwatchedError refuses an unlock, saying what the page says.
type unwatchedError string

func (e unwatchedError) Error() string { return string(e) }

// watched refuses while the device is not known to lock itself. A lock
// follows each such loss (Config.Unwatched), so a caller that saw none
// lost is ended by it.
func (s *Shell) watched() error {
	if why := s.cfg.Unwatched(); why != "" {
		return unwatchedError(why)
	}
	return nil
}

// What a locked device says where it is asked to confirm or approve.
const (
	unlockToConfirm = "Unlock this device first, then confirm the change again from the page that asked."
	unlockToApprove = "Unlock this device first, then approve the passkey again from Your devices."
)

// confirmWindow is how long a drawn confirmation or passkey request may
// wait for the PIN.
const confirmWindow = 60 * time.Second

// Draw fetches the confirmation ref names from the CYFR over the channel
// (confirmation.pending), its preview, and shows it on this device's own
// page. Nothing a browser sent is drawn but the ref.
func (s *Shell) Draw(ctx context.Context, ref string) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	if s.ch == nil {
		s.say(unlockToConfirm)
		return
	}
	p, err := s.pending(ctx, ref)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	if !s.current() {
		return
	}
	s.confirm = p
}

// pending reads ref's record from the CYFR: what this device draws
// before it signs.
func (s *Shell) pending(ctx context.Context, ref string) (*PendingConfirm, error) {
	raw, err := s.ch.Call(ctx, "confirmation.pending", map[string]any{"request": ref})
	if err != nil {
		return nil, err
	}
	var got struct {
		Confirmations []struct {
			Ref       string         `json:"ref"`
			Operation string         `json:"operation"`
			Preview   map[string]any `json:"preview"`
			Asker     map[string]any `json:"asker"`
		} `json:"confirmations"`
	}
	if err := json.Unmarshal(raw, &got); err != nil || len(got.Confirmations) != 1 || got.Confirmations[0].Ref != ref {
		return nil, errors.New("CYFR holds no open confirmation by that name")
	}
	r := got.Confirmations[0]
	return &PendingConfirm{Ref: ref, Operation: r.Operation, Preview: r.Preview, Asker: r.Asker,
		drawn: s.cfg.Now()}, nil
}

// answer confirms the record ref by key (Prima.SignIn): the CYFR's
// confirm request for it, asked on this device's channel
// (confirmation.request), held to this CYFR and the confirm purpose, its
// digest signed by key, and the answer {challenge, kid, sig} presented
// (confirmation.confirm).
func (s *Shell) answer(ctx context.Context, ref string, key Signer) error {
	raw, err := s.ch.Call(ctx, "confirmation.request", map[string]any{"ref": ref})
	if err != nil {
		return err
	}
	var got struct {
		Request any `json:"request"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		return errors.New("CYFR answered no request to sign")
	}
	r, err := account.ReadRequest(got.Request)
	if err != nil || r.Purpose != "confirm" || r.Audience != s.cfg.Address {
		return errors.New("CYFR answered no request to sign")
	}
	answer, err := r.Answer(account.Kid(s.rec.PublicKey), key.Sign)
	if err != nil {
		return err
	}
	_, err = s.ch.Call(ctx, "confirmation.confirm", map[string]any{"ref": ref, "answer": answer})
	return err
}

// Decide answers the drawn confirmation: cancelled, timed out or changed
// at the CYFR since it was drawn, nothing is signed. Otherwise the PIN
// opens the key afresh (the chip authorizes again; a passphrase decrypts
// again), never the key this unlock holds, and that key signs the CYFR's
// request, which confirmation.confirm presents. The page says what the
// CYFR answered.
func (s *Shell) Decide(ctx context.Context, ref string, confirm bool, secret []byte) {
	defer erase(secret)
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	drawn := s.confirm
	if drawn == nil || drawn.Ref != ref || s.ch == nil {
		return
	}
	switch {
	case !confirm:
		s.confirm = nil
		s.say("Nothing was confirmed.")
		return
	case s.cfg.Now().Sub(drawn.drawn) >= confirmWindow:
		s.confirm = nil
		s.say("That confirmation waited too long, so nothing was signed. Ask again from the page that asked.")
		return
	}
	now, err := s.pending(ctx, ref)
	if !s.current() {
		return
	}
	if err != nil {
		s.confirm = nil
		s.say("%s Nothing was signed.", s.sentence(err))
		return
	}
	if !same(now, drawn) {
		s.confirm = nil
		s.say("The change CYFR holds is not the one shown, so nothing was signed.")
		return
	}
	fresh, err := openKey(s.rec, secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	if !s.current() {
		fresh.Erase()
		return
	}
	err = s.answer(ctx, ref, fresh)
	fresh.Erase()
	if !s.current() {
		return
	}
	s.confirm = nil
	if err != nil {
		s.say("CYFR did not take the confirmation: %s", s.sentence(err))
		return
	}
	s.say("Confirmed on this device. The page that asked finishes the change and shows its result.")
}

// errNotWaiting is a passkey request the CYFR does not hold: none by that
// ref, or one whose key is not a passkey as the log reads one.
var errNotWaiting = errors.New("CYFR holds no passkey request by that name")

// DrawPasskey fetches the passkey request ref names from the CYFR over the
// channel (pairing.waiting) and shows it on this device's own page, with
// the short code derived here from its key. Nothing a browser sent is
// drawn but the ref, and the code the CYFR names is not read: the person
// compares the one this device derives with the one the asking browser
// shows.
func (s *Shell) DrawPasskey(ctx context.Context, ref string) {
	ctx, give, ok := s.take(ctx)
	if !ok {
		return
	}
	defer give()
	if s.ch == nil {
		s.say(unlockToApprove)
		return
	}
	p, err := s.waiting(ctx, ref)
	if !s.current() {
		return
	}
	if err != nil {
		if s.passkey != nil && s.passkey.Ref == ref {
			s.passkey = nil
		}
		s.say("%s", s.waitingSentence(err))
		return
	}
	s.passkey = p
}

// waiting reads ref's passkey request from the CYFR: what this device
// draws before it signs. The key is read as the log reads one and must be
// a passkey.
func (s *Shell) waiting(ctx context.Context, ref string) (*PendingPasskey, error) {
	if ref == "" {
		return nil, errNotWaiting
	}
	raw, err := s.ch.Call(ctx, "pairing.waiting", map[string]any{"ref": ref})
	if err != nil {
		return nil, err
	}
	var got struct {
		Waiting []struct {
			Ref string `json:"ref"`
			Key any    `json:"key"`
		} `json:"waiting"`
	}
	if err := json.Unmarshal(raw, &got); err != nil || len(got.Waiting) != 1 || got.Waiting[0].Ref != ref {
		return nil, errNotWaiting
	}
	key, ok := account.ReadKey(got.Waiting[0].Key)
	if !ok || key.Kind != "passkey" {
		return nil, errNotWaiting
	}
	digest := keyDigest(key)
	if digest == "" {
		return nil, errNotWaiting
	}
	return &PendingPasskey{Ref: ref, Key: key, Code: account.ShortCode(key.Kid), Digest: digest, drawn: s.cfg.Now()}, nil
}

// waitingSentence is what the person reads when a passkey request could
// not be read from the CYFR.
func (s *Shell) waitingSentence(err error) string {
	if errors.Is(err, errNotWaiting) {
		return "CYFR no longer holds that request, so nothing was added."
	}
	return s.sentence(err) + " Nothing was added."
}

// DecidePasskey answers the drawn passkey request from the page that
// showed the key whose whole digest is digest (keyDigest): a page whose
// key is no longer the one drawn under ref (drawn again since, with a key
// that differs in any field, or not drawn any more), cancelled, timed out
// or changed at the CYFR since it was drawn (read again by its ref, the
// same whole key), signs nothing, and each is decided before the PIN is
// opened.
// Otherwise the PIN opens the key afresh, never the key this unlock holds,
// and that key signs the add_key entry adding the key the page showed to
// the account's log at its directory. The shell's one lock is held from
// the check to the signature, so no draw lands between them. The page
// says what happened. It answers whether the request is settled: the
// account lists the passkey now, or the person cancelled it.
func (s *Shell) DecidePasskey(ctx context.Context, ref, digest string, approve bool, secret []byte) bool {
	defer erase(secret)
	ctx, give, ok := s.take(ctx)
	if !ok {
		return false
	}
	defer give()
	if s.ch == nil {
		s.say(unlockToApprove)
		return false
	}
	drawn := s.passkey
	switch {
	case drawn == nil || drawn.Ref != ref || digest == "" ||
		subtle.ConstantTimeCompare([]byte(drawn.Digest), []byte(digest)) != 1:
		s.say("That request changed since this window showed its code, so nothing was added. Approve it again from Your devices.")
		return false
	case !approve:
		s.passkey = nil
		s.say("Nothing was added.")
		return true
	case s.cfg.Now().Sub(drawn.drawn) >= confirmWindow:
		s.passkey = nil
		s.say("That request waited too long, so nothing was added. Approve it again from Your devices.")
		return false
	}
	now, err := s.waiting(ctx, ref)
	if !s.current() {
		return false
	}
	if err == nil && now.Digest != drawn.Digest {
		err = errNotWaiting
	}
	if err != nil {
		s.passkey = nil
		s.say("%s", s.waitingSentence(err))
		return false
	}
	fresh, err := openKey(s.rec, secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return false
	}
	if !s.current() {
		fresh.Erase()
		return false
	}
	directory := s.rec.Directory
	if directory == "" {
		directory = s.cfg.Directory
	}
	d := account.Directory{URL: directory, Client: s.cfg.Client}
	err = account.Approve(ctx, d, s.rec.Identifier, s.rec.PublicKey, fresh.Sign, drawn.Key, s.cfg.Now().UnixMilli())
	fresh.Erase()
	if !s.current() {
		return false
	}
	s.passkey = nil
	switch {
	case err == nil:
		s.say("Added to your account. The browser that asked signs in with its passkey now.")
		return true
	case errors.Is(err, account.ErrListed):
		s.say("Your account lists that passkey already.")
		return true
	case errors.Is(err, account.ErrNotListed):
		s.say("Your account does not list this device any more, so it cannot add a passkey.")
	case errors.Is(err, account.ErrUnanswered):
		s.say("Your account's answer did not arrive, so this device does not know whether the passkey was added. " +
			"Sign in with it in the browser that asked, or look at your account's devices page, which lists every key.")
	case errors.Is(err, account.ErrUnreachable):
		s.say("Your account could not be reached just now. Nothing was added; approve it again from Your devices.")
	default:
		s.say("The passkey was not added: %s", s.sentence(err))
	}
	return false
}

// same is whether the confirmation at the CYFR is still the one drawn:
// its operation and preview.
func same(a, b *PendingConfirm) bool {
	return a.Operation == b.Operation && reflect.DeepEqual(a.Preview, b.Preview)
}

func erase(bufs ...[]byte) {
	for _, b := range bufs {
		clear(b)
	}
}
