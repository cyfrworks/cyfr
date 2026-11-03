// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

// Package shell is this box's own screen: the pages that set CYFR up,
// unlock it with the person's PIN (or passphrase) and lock it again, and
// confirm a sensitive change freshly, served on literal loopback to the
// screen's Chrome alone; and the certified device channel through which
// the box proves the person to their home.
//
// The PIN opens the box's key (internal/holder) and goes nowhere else: the
// home receives only signatures (C1 of the devices plan), never a PIN, a
// passphrase or anything derived from one. An unlock opens the channel,
// asks the home to reserve a session (session.unlock), signs that
// reservation and hands Chrome the home's one-time ticket in a fragment;
// the shell pre-signs the lock of exactly that session and keeps it in
// memory. A lock, from the visible Lock, five minutes without local
// input, a suspend, Chrome's exit or the shell's own, submits those
// proofs, closes the channel (which ends every session it holds at the
// home), erases the key and starts Chrome again on the lock page. A shell
// that dies without locking leaves sessions that expire within 60 seconds
// at the home, as nothing renews them.
package shell

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// Config is one box's shell.
type Config struct {
	// Address is the home's address, as its certificates name it.
	Address string
	// Client reaches the home (through the tailnet's proxy when the home
	// is reached through it).
	Client *http.Client
	// Record is the holder record's path, beside the screen's files.
	Record string
	// DataDir is the home's actual data directory, whose volume the
	// detection reads.
	DataDir string
	// Tokens reads .env's setup and restore tokens when a page needs one,
	// so neither travels in an argument.
	Tokens func() (setup, restore string)
	// Restart starts Chrome again on the lock page, after a lock.
	Restart func()
	// DisplayName is the name Devices lists this screen by.
	DisplayName string
	// Detect reads the disks; disk.Detect unless a test replaces it.
	Detect func(dataDir string) disk.Report
	// Now is the clock; time.Now unless a test replaces it.
	Now func() time.Time
	// Chip is whether this box offers a chip to hold its key;
	// holder.ChipPresent unless a test replaces it, so no test reaches the
	// machine's own TPM.
	Chip func() bool
}

// pendingConfirm is a confirmation the shell drew: the home's record and
// challenge, as fetched over the channel, and when it was drawn.
type pendingConfirm struct {
	Ref       string
	Operation string
	Preview   map[string]any
	Asker     map[string]any
	Digest    string
	drawn     time.Time
}

// Shell is the screen's state: at most one key unlocked, its channel, the
// lock proofs of the sessions it holds, and what the next page says.
type Shell struct {
	cfg Config

	mu         sync.Mutex
	rec        *holder.Record
	key        *holder.Key
	ch         *Channel
	locks      []map[string]any
	renewal    *time.Timer
	notice     string
	passphrase string
	recovery   *Recovery
	naming     string // a name cyfr.run refused or could not take yet
	confirm    *pendingConfirm
	// standingEnded is a home that refused this screen's standing at its
	// last unlock: revoked, or suspended by a declared backup restore,
	// which the recovery code can re-enable.
	standingEnded bool
}

// New is a shell over cfg's holder record, locked.
func New(cfg Config) (*Shell, error) {
	if cfg.Detect == nil {
		cfg.Detect = disk.Detect
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	// No request follows a redirect: the setup token, a restore's session
	// and bearer and every proof are for the home they were read for, and
	// a redirect elsewhere is refused as the home's answer.
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
	s := &Shell{cfg: cfg}
	rec, err := holder.Load(cfg.Record)
	switch {
	case err == nil:
		s.rec = rec
	case !errors.Is(err, fs.ErrNotExist):
		return nil, fmt.Errorf("the screen's key record %s cannot be read (%v)", cfg.Record, err)
	}
	return s, nil
}

func (s *Shell) binding() Binding {
	b := Binding{Home: s.cfg.Address, DeviceKey: s.rec.PublicKey}
	b.Athanor, b.ClientID = s.rec.Athanor, s.rec.ClientID
	return b
}

func (s *Shell) report() []string {
	return s.cfg.Detect(s.cfg.DataDir).Capabilities()
}

// Page names what the screen shows now.
type Page string

const (
	PageSetup    Page = "setup"
	PageRestore  Page = "restore"
	PageFinish   Page = "finish" // a key made, its enrollment not answered yet
	PageLocked   Page = "locked"
	PageRecovery Page = "recovery"
	PageName     Page = "name"
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
	Recovery   *Recovery
	Name       string
	Confirm    *pendingConfirm
	// Kit offers to re-enable this screen with the recovery code.
	Kit bool
	// Restore is a restore's enrollment to finish, which takes the
	// recovery code again.
	Restore bool
}

// View is the page the screen shows now, and the notice of the last action
// or lock, which stays until the next action: reading a page changes
// nothing.
func (s *Shell) View() View {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := View{Notice: s.notice, Storage: s.cfg.Detect(s.cfg.DataDir), Chip: s.cfg.Chip()}
	switch {
	case s.rec == nil:
		_, restore := s.cfg.Tokens()
		v.Page = PageSetup
		if restore != "" {
			v.Page = PageRestore
		}
		if !v.Chip || s.passphrase != "" {
			v.Passphrase = s.newPassphrase()
		}
	case s.key == nil && len(s.rec.Certificate) == 0:
		v.Page, v.Kind, v.Restore = PageFinish, s.rec.Kind, s.rec.Admission == "restore"
	case s.key == nil:
		v.Page, v.Kind, v.Kit = PageLocked, s.rec.Kind, s.standingEnded
	case s.confirm != nil:
		v.Page, v.Kind, v.Confirm = PageConfirm, s.rec.Kind, s.confirm
	case s.naming != "":
		v.Page, v.Name = PageName, s.naming
	case s.recovery != nil:
		v.Page, v.Recovery = PageRecovery, s.recovery
	default:
		v.Page = PageUnlocked
	}
	if v.Kind == "" && s.rec != nil {
		v.Kind = s.rec.Kind
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

// begin clears the last notice as an action starts.
func (s *Shell) begin() {
	s.mu.Lock()
	s.notice = ""
	s.mu.Unlock()
}

// say sets the sentence the next page shows.
func (s *Shell) say(format string, args ...any) { s.notice = fmt.Sprintf(format, args...) }

// sentence is what the person reads for a failure.
func sentence(err error) string {
	var intent *IntentError
	var home *HomeError
	switch {
	case errors.Is(err, holder.ErrWrongSecret):
		return "That is not this screen's PIN or passphrase. Nothing was sent anywhere."
	case errors.Is(err, holder.ErrSecretShape):
		return "That is not this screen's PIN or passphrase. Nothing was sent anywhere."
	case errors.Is(err, holder.ErrLockedOut):
		return "Too many wrong PINs: this screen's chip takes one more try every ten minutes."
	case errors.Is(err, ErrRevoked):
		return "CYFR does not take this screen any more: a restore from a backup suspended it, or it was removed. If it was suspended, your recovery code below brings it back."
	case errors.Is(err, ErrUnavailable):
		return "CYFR could not be reached. Check that it is running, then try again."
	case errors.Is(err, ErrRefused), errors.Is(err, ErrRefusedChallenge):
		return "CYFR did not accept this screen's proof. Nothing was signed for anything else."
	case errors.As(err, &intent):
		return intent.Error() + "."
	case errors.As(err, &home) && home.Code == "setup_closed":
		return "CYFR is set up already: this box cannot set it up again."
	case errors.As(err, &home) && home.RetryAfter > 0:
		return fmt.Sprintf("CYFR is still restoring. Try again in %d seconds.", home.RetryAfter)
	case errors.As(err, &home):
		return home.Error() + "."
	}
	return err.Error()
}

// Setup makes this box's key and enrolls it as the installation's first
// person, named name: the record is written before anything is sent, so a
// retry proves the same key under the same request. The PIN (or the
// generated passphrase), given twice, opens the key that signs; neither
// leaves this process.
func (s *Shell) Setup(ctx context.Context, name string, secret, again []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret, again)
	setup, _ := s.cfg.Tokens()
	if s.rec != nil || setup == "" {
		return
	}
	name = strings.TrimSpace(name)
	if name == "" {
		s.say("Enter your name: it is yours for life.")
		return
	}
	rec, err := s.newRecord("setup", secret, again)
	if err != nil {
		return
	}
	extra := map[string]any{"name": name, "recovery_secret": RecoverySecret()}
	s.enroll(ctx, rec, SetupAdmission(s.cfg.Client, setup), secret, extra, false)
}

// Restore restores the person whose recovery code this is onto this
// replacement box and enrolls a new key for its screen: a new seed under
// this box's own chip or passphrase, never the old box's.
func (s *Shell) Restore(ctx context.Context, code string, secret, again []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret, again)
	_, token := s.cfg.Tokens()
	if s.rec != nil || token == "" {
		return
	}
	// The entries are checked before the restore spends the code at the
	// home.
	if _, err := s.checkSecret(secret, again); err != nil {
		return
	}
	a, err := Restore(ctx, s.cfg.Client, s.cfg.Address, token, strings.TrimSpace(code))
	if err != nil {
		s.say("%s", restoreSentence(err))
		return
	}
	rec, err := s.newRecord("restore", secret, again)
	if err != nil {
		return
	}
	s.enroll(ctx, rec, a, secret, nil, false)
}

func restoreSentence(err error) string {
	var home *HomeError
	if errors.As(err, &home) {
		switch home.Code {
		case "setup_closed":
			return "CYFR is set up already, so this box cannot set it up again. Restore with your recovery code instead."
		case "not_a_code", "typo":
			return "That is not a recovery code, or it has a typo. Check it and try again."
		case "unknown_identity", "not_a_holder":
			return "That recovery code restores no one here."
		case "invalid_token", "restore_disabled":
			return "This box is not set up for a restore."
		}
	}
	return sentence(err)
}

// checkSecret checks the secret given twice before anything is made or
// sent: the same both times, six digits for the chip, or the passphrase the
// page showed where there is no chip. It answers whether the chip holds it.
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
		s.say("Without a chip, this screen needs the six-word passphrase shown, not a short PIN.")
		return false, err
	}
	if string(secret) != s.passphrase {
		s.say("Enter the passphrase shown above, exactly.")
		return false, errors.New("not the shown passphrase")
	}
	return false, nil
}

// newRecord checks the secret given twice and makes the key under the
// chip, or under the passphrase when the box has no usable chip, and
// writes it.
func (s *Shell) newRecord(admission string, secret, again []byte) (*holder.Record, error) {
	chip, err := s.checkSecret(secret, again)
	if err != nil {
		return nil, err
	}
	var rec *holder.Record
	if chip {
		rec, err = holder.NewChip(s.cfg.Address, RequestID(), admission, secret)
		if errors.Is(err, holder.ErrNoChip) {
			s.newPassphrase()
			s.say("This box's chip cannot keep your PIN safely (%v). Use the passphrase below instead.", err)
			return nil, err
		}
	} else {
		rec, err = holder.NewSoftware(s.cfg.Address, RequestID(), admission, secret)
	}
	if err != nil {
		s.say("This screen could not make its key: %v.", err)
		return nil, err
	}
	if err := rec.Save(s.cfg.Record); err != nil {
		s.say("This screen could not save its key (%v). Nothing was sent to CYFR.", err)
		return nil, err
	}
	s.passphrase = ""
	s.rec = rec
	return rec, nil
}

// Finish completes an enrollment a previous run began: the same key,
// opened by its PIN, proven under the same request, through resume first.
//
// A restore's enrollment is admitted by the restore session, which no file
// keeps: Finish asks for the recovery code again and proves it through the
// restore ingress (a completed restore answers by its reproof) before
// proving the same key.
func (s *Shell) Finish(ctx context.Context, name, code string, secret []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
	if s.rec == nil || len(s.rec.Certificate) != 0 {
		return
	}
	setup, restore := s.cfg.Tokens()
	var a Admission
	var extra map[string]any
	switch {
	case s.rec.Admission == "setup" && setup != "":
		a = SetupAdmission(s.cfg.Client, setup)
		// A setup whose complete never arrived needs its name again: the
		// home recorded none, so the page asks for it with the PIN.
		extra = map[string]any{"name": strings.TrimSpace(name), "recovery_secret": RecoverySecret()}
	case s.rec.Admission == "restore" && restore != "":
		var err error
		if a, err = Restore(ctx, s.cfg.Client, s.cfg.Address, restore, strings.TrimSpace(code)); err != nil {
			s.say("%s", restoreSentence(err))
			return
		}
	default:
		s.say("This screen cannot finish setting up: .env holds no token for it.")
		return
	}
	s.enroll(ctx, s.rec, a, secret, extra, true)
}

// enroll opens rec's key, enrolls it under a and, admitted, records the
// certificate before anything else, then opens the channel.
func (s *Shell) enroll(ctx context.Context, rec *holder.Record, a Admission, secret []byte, extra map[string]any, resumed bool) {
	key, err := rec.Open(secret)
	if err != nil {
		s.say("%s", sentence(err))
		return
	}
	b := Binding{Home: s.cfg.Address, DeviceKey: rec.PublicKey}
	d := Holder{RequestID: rec.RequestID, Kind: string(rec.Kind), DisplayName: s.cfg.DisplayName}
	got, err := Enroll(ctx, s.cfg.Address, a, b, d, key, extra, resumed)
	if err != nil {
		key.Erase()
		s.say("Setting up did not finish: %s Your key is kept, so trying again proves the same one.", sentence(err))
		return
	}
	var cert struct {
		Athanor  string `json:"athanor"`
		ClientID string `json:"client_id"`
	}
	if json.Unmarshal(got.Certificate, &cert) != nil || cert.ClientID == "" {
		key.Erase()
		s.say("CYFR answered no certificate. Try again.")
		return
	}
	rec.Certificate, rec.ClientID, rec.Athanor = got.Certificate, cert.ClientID, cert.Athanor
	if got.Recovery == nil {
		rec.RequestID = ""
	}
	if err := rec.Save(s.cfg.Record); err != nil {
		key.Erase()
		s.say("This screen could not save its certificate (%v). Try again: CYFR answers the same one.", err)
		return
	}
	s.recovery = got.Recovery
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.say("%s", sentence(err))
		return
	}
	if s.recovery != nil {
		s.register(ctx, s.recovery.Name)
	}
}

// connect opens the certified channel under key and holds both: the box is
// unlocked from here until a lock.
func (s *Shell) connect(ctx context.Context, key *holder.Key) error {
	device := Device{Binding: s.binding(), Certificate: s.rec.Certificate}
	ch, err := Dialer{Address: s.cfg.Address, Client: s.cfg.Client}.Open(ctx, device, key, s.report, s.renewed)
	if err != nil {
		return err
	}
	s.key, s.ch = key, ch
	s.scheduleRenewal()
	go s.watch(ch)
	return nil
}

// renewed persists a certificate the home issued. It arrives on the
// channel's own goroutine, or during a connect whose caller holds the
// shell, so it takes the shell's lock on a goroutine of its own. A box that
// dies before it is written still holds the old certificate, which locates
// the client for the next renewal.
func (s *Shell) renewed(cert json.RawMessage) {
	go func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.rec != nil {
			s.rec.Certificate = cert
			_ = s.rec.Save(s.cfg.Record)
		}
	}()
}

// scheduleRenewal renews the certificate over the channel at half its life.
func (s *Shell) scheduleRenewal() {
	var cert struct {
		NotBefore int64 `json:"not_before"`
		ExpiresAt int64 `json:"expires_at"`
	}
	if json.Unmarshal(s.rec.Certificate, &cert) != nil || cert.ExpiresAt <= cert.NotBefore {
		return
	}
	at := time.UnixMilli(cert.NotBefore + (cert.ExpiresAt-cert.NotBefore)/2)
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

// watch locks the box when its channel ends under it: a revoked pairing
// or a home gone away ends the unlock, with the reason on the lock page.
func (s *Shell) watch(ch *Channel) {
	<-ch.Done()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch != ch {
		return
	}
	s.lock(sentence(ch.Err()))
}

// register takes the person's name at cyfr.run (registry.register), the
// one the attempt holds first. A name held by someone else asks for
// another; cyfr.run not answering asks to try again. Neither enrolls
// anyone again.
func (s *Shell) register(ctx context.Context, name string) {
	args := map[string]any{}
	if s.recovery == nil || name != s.recovery.Name {
		args["name"] = name
	}
	got, err := s.ch.Call(ctx, "registry.register", args)
	var intent *IntentError
	switch {
	case err == nil:
		var answer struct {
			Name string `json:"name"`
		}
		_ = json.Unmarshal(got, &answer)
		if answer.Name == "" {
			answer.Name = name
		}
		s.naming = ""
		if s.recovery != nil {
			s.recovery.Name = answer.Name
		}
	case errors.As(err, &intent) && intent.says("name_taken", "name_reserved"):
		s.naming = name
		s.say("Someone holds the name %s, or cyfr.run keeps it. Choose another.", name)
	case errors.As(err, &intent) && intent.says("directory_unavailable", "registry_unavailable"):
		s.naming = name
		s.say("cyfr.run did not answer. Try again in a moment; you are set up already.")
	default:
		s.naming = name
		s.say("%s", sentence(err))
	}
}

// Rename asks cyfr.run for name.
func (s *Shell) Rename(ctx context.Context, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch == nil || s.naming == "" {
		return
	}
	s.register(ctx, strings.TrimSpace(name))
}

// Saved records the recovery code saved (person.recovery_code_saved),
// erases it here and finishes setup.
func (s *Shell) Saved(ctx context.Context) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch == nil || s.recovery == nil || s.naming != "" {
		return
	}
	if _, err := s.ch.Call(ctx, "person.recovery_code_saved", map[string]any{"attempt_id": s.recovery.AttemptID}); err != nil {
		s.say("%s", sentence(err))
		return
	}
	s.recovery = nil
	s.rec.RequestID = ""
	if err := s.rec.Save(s.cfg.Record); err != nil {
		s.say("This screen could not save that setup finished (%v).", err)
	}
}

// Unlock opens the key with the PIN (or passphrase), opens the channel
// and, for a setup whose recovery code was not said saved yet, fetches it
// again by resume. A wrong PIN is said and never retried.
func (s *Shell) Unlock(ctx context.Context, secret []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
	if s.rec == nil || len(s.rec.Certificate) == 0 || s.key != nil {
		return
	}
	key, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s", sentence(err))
		return
	}
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.standingEnded = errors.Is(err, ErrRevoked)
		s.say("%s", sentence(err))
		return
	}
	s.standingEnded = false
	if s.rec.RequestID != "" {
		setup, _ := s.cfg.Tokens()
		got, err := resume(ctx, s.cfg.Address, SetupAdmission(s.cfg.Client, setup), s.binding(), s.rec.RequestID, key)
		switch {
		case err == nil && got.Recovery != nil:
			s.recovery = got.Recovery
			s.register(ctx, got.Recovery.Name)
		case err == nil:
			s.rec.RequestID = ""
			_ = s.rec.Save(s.cfg.Record)
		default:
			s.say("CYFR could not show your recovery code again: %s", sentence(err))
		}
	}
}

// Reenable brings this screen back after a declared backup restore
// suspended it: the PIN opens its key here first, then the recovery code's
// own key proves the person to the home (POST /restore/kit) and
// pairing.reenable restores this screen's client, and the screen unlocks.
// A screen the home revoked stays revoked: the re-enable refuses it.
func (s *Shell) Reenable(ctx context.Context, code string, secret []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	defer erase(secret)
	if s.rec == nil || s.rec.ClientID == "" || s.key != nil || !s.standingEnded {
		return
	}
	key, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s", sentence(err))
		return
	}
	if err := reenable(ctx, s.cfg.Client, s.cfg.Address, strings.TrimSpace(code), s.rec.ClientID); err != nil {
		key.Erase()
		s.say("%s", kitSentence(err))
		return
	}
	if err := s.connect(ctx, key); err != nil {
		key.Erase()
		s.say("%s", sentence(err))
		return
	}
	s.standingEnded = false
}

func kitSentence(err error) string {
	var home *HomeError
	switch {
	case errors.Is(err, ErrNotACode), errors.Is(err, ErrTypo):
		return "That is not a recovery code, or it has a typo. Check it and try again."
	case errors.As(err, &home) && home.Code == "not_recovering":
		return "CYFR is not recovering from a backup, so this screen was removed, not suspended: set it up again."
	case errors.As(err, &home) && home.Code == "not_a_holder":
		return "That recovery code is not yours here."
	}
	return "This screen could not be brought back: " + sentence(err)
}

// Ticket reserves one session at the home (session.unlock), signs that
// reservation, pre-signs the lock of exactly that session and keeps it,
// and answers where Chrome goes: the home's completion page with the
// ticket in its fragment, which no request carries.
func (s *Shell) Ticket(ctx context.Context) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch == nil || s.recovery != nil || s.naming != "" {
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
	c, err := Challenge(asked.Challenge, "unlock", s.binding(), nil)
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
	return strings.TrimRight(s.cfg.Address, "/") + "/auth/device/complete#" + got.Ticket, nil
}

// Lock locks the box, why saying what the lock page tells the person.
func (s *Shell) Lock(why string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lock(why)
}

// lock submits each held session's lock proof, closes the channel, erases
// the key and every secret the shell held, and starts Chrome again on the
// lock page, in that order: the sessions end at the home before the page
// that used them is gone.
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
	wasOpen := s.ch != nil
	s.ch, s.key, s.locks, s.recovery, s.naming, s.confirm, s.passphrase = nil, nil, nil, nil, "", nil, ""
	if wasOpen {
		if why != "" {
			s.notice = why
		}
		s.cfg.Restart()
	}
}

// Unlocked is whether a key is open.
func (s *Shell) Unlocked() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.key != nil
}

// confirmWindow is how long a drawn confirmation may wait for the PIN.
const confirmWindow = 60 * time.Second

// Draw fetches the confirmation ref names from the home over the channel
// (confirmation.pending), its preview and its confirm challenge, and
// shows them on this screen's own page. Nothing a browser sent is drawn
// but the ref.
func (s *Shell) Draw(ctx context.Context, ref string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ch == nil {
		s.say("Unlock this screen first, then confirm the change again from the page that asked.")
		return
	}
	p, _, err := s.pending(ctx, ref)
	if err != nil {
		s.say("%s", sentence(err))
		return
	}
	s.confirm = p
}

// pending reads ref's record and challenge from the home and checks the
// challenge is for this ref, this device and this home.
func (s *Shell) pending(ctx context.Context, ref string) (*pendingConfirm, map[string]any, error) {
	raw, err := s.ch.Call(ctx, "confirmation.pending", map[string]any{"request": ref})
	if err != nil {
		return nil, nil, err
	}
	var got struct {
		Confirmations []struct {
			Ref       string          `json:"ref"`
			Operation string          `json:"operation"`
			Preview   map[string]any  `json:"preview"`
			Asker     map[string]any  `json:"asker"`
			Challenge json.RawMessage `json:"challenge"`
		} `json:"confirmations"`
	}
	if err := json.Unmarshal(raw, &got); err != nil || len(got.Confirmations) != 1 || got.Confirmations[0].Ref != ref {
		return nil, nil, errors.New("CYFR holds no open confirmation by that name")
	}
	r := got.Confirmations[0]
	c, err := Challenge(r.Challenge, "confirm", s.binding(), Expect{"ref": ref})
	if err != nil {
		return nil, nil, err
	}
	return &pendingConfirm{Ref: ref, Operation: r.Operation, Preview: r.Preview, Asker: r.Asker,
		Digest: c["digest"].(string), drawn: s.cfg.Now()}, c, nil
}

// Decide answers the drawn confirmation: cancelled, timed out or changed
// at the home since it was drawn, nothing is signed. Otherwise the PIN
// opens the key afresh (the chip authorizes again; a passphrase decrypts
// again), never the key this unlock holds, and that key signs the home's
// challenge, which confirmation.confirm presents. The page says what the
// home answered.
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
	now, challenge, err := s.pending(ctx, ref)
	if err != nil {
		s.confirm = nil
		s.say("%s Nothing was signed.", sentence(err))
		return
	}
	if !same(now, drawn) {
		s.confirm = nil
		s.say("The change CYFR holds is not the one shown, so nothing was signed.")
		return
	}
	fresh, err := s.rec.Open(secret)
	if err != nil {
		s.say("%s", sentence(err))
		return
	}
	proof, err := Prove(challenge, fresh)
	fresh.Erase()
	if err != nil {
		s.confirm = nil
		s.say("%s", sentence(err))
		return
	}
	s.confirm = nil
	if _, err := s.ch.Call(ctx, "confirmation.confirm", map[string]any{"ref": ref, "device_proof": proof}); err != nil {
		s.say("CYFR did not take the confirmation: %s", sentence(err))
		return
	}
	s.say("Confirmed on this screen. The page that asked finishes the change and shows its result.")
}

// same is whether the confirmation at the home is still the one drawn:
// its operation, preview and the digest its challenge binds.
func same(a, b *pendingConfirm) bool {
	pa, _ := Canonical(a.Preview)
	pb, _ := Canonical(b.Preview)
	return a.Operation == b.Operation && a.Digest == b.Digest && string(pa) == string(pb)
}

func erase(bufs ...[]byte) {
	for _, b := range bufs {
		clear(b)
	}
}
