// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package shell is a device of a person's account: the pages that make its
// key, make the account or add the key to one, unlock it with the person's
// PIN (or passphrase) and lock it again, and confirm a sensitive change
// freshly, served on literal loopback to a box's screen; the same states
// drive cyfr login in a terminal. Through the device channel the device
// proves the person to a CYFR.
//
// The PIN opens the device's key (internal/holder) and goes nowhere else:
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
// and starts the browser again on the lock page. A shell that dies without
// locking leaves sessions that expire within 60 seconds at the CYFR, as
// nothing renews them.
package shell

import (
	"bytes"
	"context"
	"crypto/ed25519"
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
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// Config is one device's shell at one CYFR.
type Config struct {
	// Address is the CYFR's origin, as its certificates name it.
	Address string
	// Client reaches the CYFR, the directory and the registry (through the
	// tailnet's proxy when the CYFR is reached through it).
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
	// Tokens reads the setup token a first hello brings, when there is
	// one, so it never travels in an argument.
	Tokens func() (setup string)
	// SetupFromPage brings the setup token only with the hello that
	// follows an account this device made (a box's screen, whose .env
	// always holds the token): a device added to an account the person
	// has brings none, and the CYFR's door decides.
	SetupFromPage bool
	// Invitation is the invitation's code a first hello brings, when
	// there is one.
	Invitation string
	// Restart starts the browser again on the lock page, after a lock.
	Restart func()
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
	// Noun is what the person calls this device in a sentence: "screen"
	// for a box's own screen (the default), "command line" for cyfr login.
	Noun string
}

// ClientRecord is the client a CYFR admitted this device's key as and the
// certificate it connects under there; before the first admission,
// Admission is "setup" when this device made its account here, which a
// SetupFromPage device's first hello brings the setup token for.
type ClientRecord struct {
	ClientID    string          `json:"client_id,omitempty"`
	Certificate json.RawMessage `json:"certificate,omitempty"`
	Admission   string          `json:"admission,omitempty"`
}

// ClientStore keeps this device's ClientRecord at one CYFR.
type ClientStore interface {
	Load() (ClientRecord, error)
	Save(ClientRecord) error
}

// ClientFile keeps a ClientRecord in a file of its own, private to its
// owner: a box's screen's.
type ClientFile string

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

// Save replaces the file in one step.
func (f ClientFile) Save(c ClientRecord) error { return writeJSON(string(f), c) }

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
type Shell struct {
	cfg Config

	mu   sync.Mutex
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
}

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
	if cfg.Tokens == nil {
		cfg.Tokens = func() string { return "" }
	}
	if cfg.Noun == "" {
		cfg.Noun = "screen"
	}
	if cfg.Directory == "" {
		cfg.Directory = account.DefaultDirectory
	}
	if cfg.Clients == nil {
		cfg.Clients = ClientFile(filepath.Join(filepath.Dir(cfg.Record), "client.json"))
	}
	s := &Shell{cfg: cfg}
	rec, err := holder.Load(cfg.Record)
	switch {
	case err == nil:
		s.rec = rec
	case !errors.Is(err, fs.ErrNotExist):
		return nil, fmt.Errorf("this %s's key record %s cannot be read (%v)", cfg.Noun, cfg.Record, err)
	}
	if s.here, err = cfg.Clients.Load(); err != nil {
		return nil, fmt.Errorf("this %s's standing at %s cannot be read (%v)", cfg.Noun, cfg.Address, err)
	}
	if s.unfinished, err = s.readAttempt(); err != nil {
		return nil, fmt.Errorf("the account this %s was making cannot be read (%v)", cfg.Noun, err)
	}
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
// another first use (a second cyfr login, a restarted screen) may have
// made the key, listed it in an account or begun an account since this
// shell read them. A key it did not make is the one it uses from here,
// and what it held for another key (a key held open, an account it was
// making) is dropped. A shell whose channel stands acts on its own key.
func (s *Shell) refresh() {
	if s.ch != nil {
		return
	}
	rec, err := holder.Load(s.cfg.Record)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
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
	s.say("Another %s on this machine made its key first, and this one uses that key: unlock it with that one's PIN or passphrase.", s.cfg.Noun)
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
)

// View is what a page draws.
type View struct {
	Page       Page
	Kind       holder.Kind
	Chip       bool
	Notice     string
	Storage    disk.Report
	Passphrase string
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
	// Code is the key's short code while no account lists it, AddURL the
	// account page that adds it (a QR code's text), and Key its public
	// half as cyfr device approve takes it.
	Code   string
	AddURL string
	Key    string
}

// View is the page the device shows now, and the notice of the last
// action or lock, which stays until the next action: reading a page
// changes nothing.
func (s *Shell) View() View {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := View{Notice: s.notice, Storage: s.cfg.Detect(s.cfg.DataDir), Chip: s.cfg.Chip()}
	if s.terms != nil {
		v.Terms = s.terms.URL
	}
	if s.rec != nil {
		v.Kind = s.rec.Kind
	}
	switch m := s.making; {
	case s.rec == nil:
		v.Page = PageSetup
		if !v.Chip || s.passphrase != "" {
			v.Passphrase = s.newPassphrase()
		}
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
		v.AddURL = account.Directory{URL: s.cfg.Directory}.Origin() + "/account/add#key=" + v.Key +
			"&alg=ed25519&kind=device&code=" + v.Code
	case s.ch == nil:
		v.Page = PageLocked
	case s.confirm != nil:
		v.Page, v.Confirm = PageConfirm, s.confirm
	default:
		v.Page = PageUnlocked
	}
	return v
}

// newPassphrase is the passphrase a software setup shows, drawn once per
// shown setup page and kept in memory until the setup takes it.
func (s *Shell) newPassphrase() string {
	if s.passphrase == "" {
		p, err := holder.GeneratePassphrase()
		if err == nil {
			s.passphrase = p
		}
	}
	return s.passphrase
}

// Begin clears the last notice as an action starts.
func (s *Shell) Begin() {
	s.mu.Lock()
	s.notice = ""
	s.mu.Unlock()
}

// say sets the sentence the next page shows.
func (s *Shell) say(format string, args ...any) { s.notice = fmt.Sprintf(format, args...) }

// sentence is what the person reads for a failure, naming this device as
// the shell's Config does.
func (s *Shell) sentence(err error) string { return sentence(err, s.cfg.Noun) }

// sentence is what the person reads for a failure of the device noun
// names ("screen", "command line").
func sentence(err error, noun string) string {
	var intent *IntentError
	var home *HomeError
	var dir *account.DirectoryRefusal
	var refused *RefusedError
	switch {
	case errors.As(err, &refused):
		return refused.Message
	case errors.Is(err, holder.ErrWrongSecret), errors.Is(err, holder.ErrSecretShape):
		return "That is not this " + noun + "'s PIN or passphrase. Nothing was sent anywhere."
	case errors.Is(err, holder.ErrLockedOut):
		return "Too many wrong PINs: this " + noun + "'s chip takes one more try every ten minutes."
	case errors.Is(err, ErrRevoked):
		return "CYFR does not take this " + noun + " now: it was removed, or CYFR does not admit your account. Unlocking it again asks CYFR again."
	case errors.Is(err, ErrUnavailable):
		return "CYFR could not be reached. Check that it is running, then try again."
	case errors.Is(err, ErrRefused), errors.Is(err, ErrRefusedChallenge):
		return "CYFR did not accept this " + noun + "'s proof. Nothing was signed for anything else."
	case errors.Is(err, ErrRenew):
		return "This " + noun + "'s certificate expired, and with it its session: unlock it again to renew it."
	case errors.Is(err, account.ErrUnreachable):
		return "Your account could not be reached just now. Try again; nothing is lost."
	case errors.As(err, &dir) && dir.Code == "gone":
		return "That account was closed."
	case errors.As(err, &dir) && dir.Code == "not_found":
		return "No account is listed by that name."
	case errors.As(err, &intent):
		return intent.Error() + "."
	case errors.As(err, &home) && home.Code == "rate_limited":
		return fmt.Sprintf("CYFR is taking too many requests from here. Try again in %d seconds.", max(home.RetryAfter, 1))
	case errors.As(err, &home) && home.Code == "unavailable":
		return fmt.Sprintf("CYFR could not answer just now. Try again in %d seconds.", max(home.RetryAfter, 1))
	case errors.As(err, &home):
		return home.Error() + "."
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
		s.say("Without a chip, this %s needs the six-word passphrase shown, not a short PIN.", s.cfg.Noun)
		return false, err
	}
	if string(secret) != s.passphrase {
		s.say("Enter the passphrase shown above, exactly.")
		return false, errors.New("not the shown passphrase")
	}
	return false, nil
}

// Make makes this device's key under the PIN, or under the passphrase
// when the machine has no usable chip, given twice, and writes it before
// anything is shown or sent, so its code, a retry and a lost answer all
// name the same key.
func (s *Shell) Make(secret, again []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret, again)
	s.refresh()
	if s.rec != nil {
		s.madeElsewhere()
		return
	}
	_, _ = s.newRecord(secret, again)
}

func (s *Shell) newRecord(secret, again []byte) (*holder.Record, error) {
	chip, err := s.checkSecret(secret, again)
	if err != nil {
		return nil, err
	}
	var rec *holder.Record
	if chip {
		rec, err = holder.NewChip(secret)
		if errors.Is(err, holder.ErrNoChip) {
			s.newPassphrase()
			s.say("This machine's chip cannot keep your PIN safely (%v). Use the passphrase below instead.", err)
			return nil, err
		}
	} else {
		rec, err = holder.NewSoftware(secret)
	}
	if err != nil {
		s.say("This %s could not make its key: %v.", s.cfg.Noun, err)
		return nil, err
	}
	err = rec.Create(s.cfg.Record)
	if errors.Is(err, holder.ErrKeyExists) {
		s.refresh()
		s.madeElsewhere()
		return nil, err
	}
	if err != nil {
		s.say("This %s could not save its key (%v). Nothing was sent anywhere.", s.cfg.Noun, err)
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
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret, again)
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
	key, err := rec.Open(secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	s.key = key
	s.begin(c, name, accepted)
}

// Create makes an account whose first key is this device's, as Setup does,
// for a key made before.
func (s *Shell) Create(ctx context.Context, name, accepted string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refresh()
	if s.rec == nil || s.rec.Identifier != "" || s.making != nil || s.unfinished != nil {
		return
	}
	if c, ok := s.checkNew(ctx, name, accepted); ok {
		s.begin(c, name, accepted)
	}
}

// Terms is the policy a new account accepts at this device's directory, or
// nil where its registry asks for none.
func (s *Shell) Terms(ctx context.Context) (*account.Policy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, err := s.config(ctx)
	return c.Policy, err
}

func (s *Shell) config(ctx context.Context) (account.Config, error) {
	c, err := account.Directory{URL: s.cfg.Directory, Client: s.cfg.Client}.Config(ctx)
	if err == nil {
		s.terms, s.configured = c.Policy, true
	}
	return c, err
}

// readTerms reads the directory's configuration once, so a page that
// makes an account shows the terms it accepts before it is submitted.
func (s *Shell) readTerms(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.configured {
		_, _ = s.config(ctx)
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
	s.making = &making{attempt: a, key: key, code: code}
}

// Saved says the recovery code is saved and submits the account (register,
// append, then the name), or submits it again after an answer that did
// not come; accepted is the policy version accepted again when the
// registry asked for a newer one. Done, the key's record names the account,
// and a key held from a setup opens this device's first connection.
func (s *Shell) Saved(ctx context.Context, accepted string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refresh()
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
			s.say("Another %s on this machine began an account with this key first: finish it with its recovery code. Nothing was sent for the one shown here.", s.cfg.Noun)
			return
		}
		if err != nil {
			s.say("This %s could not keep the account it is making (%v). Nothing was sent.", s.cfg.Noun, err)
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
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refresh()
	if s.unfinished == nil || s.making != nil || s.rec == nil || s.rec.Identifier != "" {
		return
	}
	identifier, secret, err := account.DecodeRecoveryCode(code)
	switch {
	case errors.Is(err, account.ErrTypo):
		s.say("That recovery code has a typo. Check it and type it again.")
		return
	case err != nil:
		s.say("That is not a recovery code.")
		return
	case identifier != s.unfinished.Identifier:
		clear(secret)
		s.say("That is another account's recovery code.")
		return
	}
	s.making = &making{attempt: *s.unfinished, key: account.RecoveryKey(secret), saved: true}
	clear(secret)
	s.submit(ctx)
}

// Rename takes another name for the account being made, whose name
// someone took meanwhile.
func (s *Shell) Rename(ctx context.Context, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.refresh()
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
	s.say("This machine's key is on an account already, made or added by another %s here: unlock it with its PIN or passphrase.", s.cfg.Noun)
	return true
}

func (s *Shell) submit(ctx context.Context) {
	m := s.making
	now := func() int64 { return s.cfg.Now().UnixMilli() }
	err := account.Submit(ctx, &m.attempt, m.key, now, s.cfg.Client, s.saveAttempt)
	switch {
	case errors.Is(err, account.ErrNameTaken):
		m.taken = true
		s.say("Someone holds the name @%s. Choose another: your account is made, and takes a name once one is free.", m.attempt.Name)
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
		s.say("This %s could not save its account (%v). Try again.", s.cfg.Noun, err)
		return
	}
	clear(m.key)
	s.making, s.unfinished = nil, nil
	_ = os.Remove(s.attemptPath())
	if s.here.ClientID == "" {
		s.here.Admission = "setup"
		if err := s.cfg.Clients.Save(s.here); err != nil {
			s.say("This %s could not keep that it made your account here (%v). Try again.", s.cfg.Noun, err)
			return
		}
	}
	s.firstConnection(ctx)
}

// firstConnection opens the key held since a setup, once its account
// lists it, or leaves the device locked for its PIN.
func (s *Shell) firstConnection(ctx context.Context) {
	if s.key == nil {
		return
	}
	if err := s.connect(ctx, s.key); err != nil {
		s.key.Erase()
		s.key = nil
		s.say("%s", s.sentence(err))
	}
}

// pollEvery is how often an enrollment reads the account's log.
var pollEvery = 2 * time.Second

// Enroll adds this device to the account named name, once a device of the
// person's approves it: the name is resolved at the registry the
// directory names, and that account's log is read every pollEvery, for at
// most wait, until it lists this key. Listed, the key's record names the
// account.
func (s *Shell) Enroll(ctx context.Context, name string, wait time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
			s.say("This %s is not on @%s's account yet. Approve it on a device of yours, then try again.", s.cfg.Noun, name)
			return
		case <-time.After(pollEvery):
		}
	}
	pub := s.rec.PublicKey
	s.refresh()
	switch {
	case s.rec == nil || !bytes.Equal(s.rec.PublicKey, pub):
		return
	case s.rec.Identifier == found.Identifier:
		s.firstConnection(ctx)
		return
	case s.rec.Identifier != "":
		s.say("This machine's key is on another account already, added by another %s here.", s.cfg.Noun)
		return
	}
	s.rec.Identifier, s.rec.Directory = found.Identifier, found.Directory
	if err := s.rec.Save(s.cfg.Record); err != nil {
		s.say("This %s could not save its account (%v). Try again.", s.cfg.Noun, err)
		return
	}
	s.firstConnection(ctx)
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
	s.mu.Lock()
	defer s.mu.Unlock()
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
	unlisted := *s.rec
	unlisted.Identifier, unlisted.Directory = "", ""
	if err := unlisted.Save(s.cfg.Record); err != nil {
		s.say("Your account no longer lists this %s's key, and this %s could not keep that (%v). Try again.", s.cfg.Noun, s.cfg.Noun, err)
		return
	}
	s.rec = &unlisted
	if len(s.here.Certificate) > 0 {
		s.forget()
	}
	s.say("Your account no longer lists this %s's key. Add the same key to your account again to go on.", s.cfg.Noun)
}

// Unlock opens the key with the PIN (or passphrase) and opens the channel.
// A wrong PIN is said and never retried.
func (s *Shell) Unlock(ctx context.Context, secret []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
	s.refresh()
	if s.rec == nil || s.rec.Identifier == "" || s.ch != nil {
		return
	}
	if s.key != nil {
		s.key.Erase()
		s.key = nil
	}
	key, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.say("%s", s.sentence(err))
	}
}

// connect opens the channel under key and holds both: the device is
// unlocked from here until a lock. A device this CYFR has not certified
// says hello first, dropping a certificate it holds that it will not
// present; one whose standing ended here keeps no certificate, so its
// next unlock says hello again.
func (s *Shell) connect(ctx context.Context, key *holder.Key) error {
	d := Dialer{Address: s.cfg.Address, Client: s.cfg.Client}
	var ch *Channel
	var err error
	if s.certified() {
		ch, err = d.Open(ctx, Device{Binding: s.binding(), Certificate: s.here.Certificate}, key, s.report, s.renewed)
	} else {
		if len(s.here.Certificate) > 0 {
			s.forget()
		}
		h := Hello{Key: s.rec.PublicKey, Identifier: s.rec.Identifier, HolderKind: string(s.rec.Kind),
			DisplayName: s.cfg.DisplayName, Admission: s.admission()}
		ch, err = d.Hello(ctx, h, key, s.admitted, s.report, s.renewed)
	}
	if errors.Is(err, ErrRevoked) {
		s.forget()
	}
	if err != nil {
		return err
	}
	s.key, s.ch = key, ch
	s.scheduleRenewal()
	go s.watch(ch)
	return nil
}

// admission is the capability a first hello brings: none once this CYFR
// admitted this device (the door decides), else the setup token (for a
// SetupFromPage device, only after it made its account here), else the
// invitation's code.
func (s *Shell) admission() map[string]any {
	if s.here.ClientID != "" {
		return nil
	}
	if t := s.cfg.Tokens(); t != "" && (!s.cfg.SetupFromPage || s.here.Admission == "setup") {
		return map[string]any{"setup": t}
	}
	if s.cfg.Invitation != "" {
		return map[string]any{"invitation": s.cfg.Invitation}
	}
	return nil
}

// admitted keeps the client and certificate a hello was answered before
// the connection goes on.
func (s *Shell) admitted(a Admitted) error {
	s.here = ClientRecord{ClientID: a.ClientID, Certificate: a.Certificate}
	return s.cfg.Clients.Save(s.here)
}

// forget drops the certificate of a standing that ended here, keeping the
// client id, so the next unlock says hello without a capability.
func (s *Shell) forget() {
	s.here.Certificate = nil
	_ = s.cfg.Clients.Save(s.here)
}

// renewed persists a certificate the CYFR issued. It arrives on the
// channel's own goroutine, or during a connect whose caller holds the
// shell, so it takes the shell's lock on a goroutine of its own. A device
// that dies before it is written still holds the old certificate, which
// locates the client for the next renewal.
func (s *Shell) renewed(cert json.RawMessage) {
	go func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		s.here.Certificate = cert
		_ = s.cfg.Clients.Save(s.here)
	}()
}

// scheduleRenewal renews the certificate over the channel at half its life.
func (s *Shell) scheduleRenewal() {
	i := readIssued(s.here.Certificate)
	if i.ExpiresAt <= i.NotBefore {
		return
	}
	at := time.UnixMilli(i.NotBefore + (i.ExpiresAt-i.NotBefore)/2)
	wait := max(at.Sub(s.cfg.Now()), time.Second)
	ch := s.ch
	s.renewal = time.AfterFunc(wait, func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		_ = ch.Renew(ctx)
		s.mu.Lock()
		if s.ch == ch {
			s.scheduleRenewal()
		}
		s.mu.Unlock()
	})
}

// watch locks the device when its channel ends under it: an ended
// standing or a CYFR gone away ends the unlock, with the reason on the
// lock page.
func (s *Shell) watch(ch *Channel) {
	<-ch.Done()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch != ch {
		return
	}
	if errors.Is(ch.Err(), ErrRevoked) {
		s.forget()
	}
	s.lock(s.sentence(ch.Err()))
}

// Ticket reserves one session at the CYFR (reserve) and answers where the
// browser goes: the CYFR's completion page with the ticket in its
// fragment, which no request carries.
func (s *Shell) Ticket(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ticket, err := s.reserve(ctx)
	if err != nil {
		return "", err
	}
	return strings.TrimRight(s.cfg.Address, "/") + "/auth/device/complete#" + ticket, nil
}

// Session reserves one session at the CYFR for this device's own
// requests (reserve) and spends its ticket for the session's bearer
// token (POST /device/session), which only the device channel that
// reserved it keeps alive and whose lock this shell holds. The token is
// held by the caller in memory alone.
func (s *Shell) Session(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ticket, err := s.reserve(ctx)
	if err != nil {
		return "", err
	}
	var got struct {
		SessionToken string `json:"session_token"`
	}
	if err := post(ctx, s.cfg.Client, s.cfg.Address, "/device/session", nil, map[string]any{"ticket": ticket}, &got); err != nil {
		return "", err
	}
	if got.SessionToken == "" {
		return "", ErrRefused
	}
	return got.SessionToken, nil
}

// reserve asks the CYFR for one session (session.unlock), signs that
// reservation, pre-signs the lock of exactly that session and keeps it,
// and answers the CYFR's one-time ticket for it. The caller holds the
// shell.
func (s *Shell) reserve(ctx context.Context) (string, error) {
	if s.ch == nil {
		return "", errors.New("locked")
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
	return got.Ticket, nil
}

// Lock locks the device, why saying what the lock page tells the person.
func (s *Shell) Lock(why string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lock(why)
}

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
	if s.ch != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		for _, proof := range s.locks {
			_, _ = s.ch.Call(ctx, "session.lock", map[string]any{"proof": proof})
		}
		cancel()
		s.ch.Close()
	}
	if s.key != nil {
		s.key.Erase()
	}
	if s.making != nil {
		clear(s.making.key)
	}
	wasOpen := s.ch != nil
	s.ch, s.key, s.locks, s.making, s.confirm, s.passphrase = nil, nil, nil, nil, nil, ""
	if wasOpen {
		if why != "" {
			s.notice = why
		}
		s.cfg.Restart()
	}
}

// Unlocked is whether the channel stands.
func (s *Shell) Unlocked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ch != nil
}

// confirmWindow is how long a drawn confirmation may wait for the PIN.
const confirmWindow = 60 * time.Second

// Draw fetches the confirmation ref names from the CYFR over the channel
// (confirmation.pending), its preview, and shows it on this device's own
// page. Nothing a browser sent is drawn but the ref.
func (s *Shell) Draw(ctx context.Context, ref string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch == nil {
		s.say("Unlock this %s first, then confirm the change again from the page that asked.", s.cfg.Noun)
		return
	}
	p, err := s.pending(ctx, ref)
	if err != nil {
		s.say("%s", s.sentence(err))
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
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
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
	fresh, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s", s.sentence(err))
		return
	}
	err = s.answer(ctx, ref, fresh)
	fresh.Erase()
	s.confirm = nil
	if err != nil {
		s.say("CYFR did not take the confirmation: %s", s.sentence(err))
		return
	}
	s.say("Confirmed on this %s. The page that asked finishes the change and shows its result.", s.cfg.Noun)
}

// ConfirmDrawn confirms the change drawn, read from the CYFR through
// another credential of this device's (the command line's session) and
// shown before the secret was asked: the secret, asked after it, opens
// the key afresh, which proves this device on a channel of its own; the
// CYFR's confirm request for that ref is read there, and only when the
// record behind it is still the one drawn (its operation and preview) is
// that request answered (confirmation.confirm). The channel is closed and
// the key erased whatever the outcome; the notice says it.
func (s *Shell) ConfirmDrawn(ctx context.Context, drawn PendingConfirm, secret []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
	if s.rec == nil || s.rec.Identifier == "" || s.ch != nil {
		return
	}
	key, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s Nothing was signed.", s.sentence(err))
		return
	}
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.say("%s Nothing was signed.", s.sentence(err))
		return
	}
	notice := ""
	defer func() { s.lock(""); s.notice = notice }()
	now, err := s.pending(ctx, drawn.Ref)
	if err != nil {
		notice = s.sentence(err) + " Nothing was signed."
		return
	}
	if !same(now, &drawn) {
		notice = "The change CYFR holds is not the one shown, so nothing was signed."
		return
	}
	if err := s.answer(ctx, drawn.Ref, s.key); err != nil {
		notice = "CYFR did not take the confirmation: " + s.sentence(err)
		return
	}
	notice = "Confirmed on this " + s.cfg.Noun + "."
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
