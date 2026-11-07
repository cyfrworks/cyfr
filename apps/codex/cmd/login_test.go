// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cyfr/codex/internal/account"
	"github.com/cyfr/codex/internal/config"
	"github.com/cyfr/codex/internal/confirmation"
	"github.com/cyfr/codex/internal/holder"
	"github.com/cyfr/codex/internal/mcp"
	"github.com/cyfr/codex/internal/shell"
)

// fakeDevice stands in for this command line's device: the views it
// shows, each action recorded with what it was given and moving to the
// view next answers for it.
type fakeDevice struct {
	mu      sync.Mutex
	view    shell.View
	calls   []string
	secrets map[string][]byte // the secret each action was given, copied
	given   map[string]string
	next    func(call string, d *fakeDevice)
	locks   int
	session string
	terms   *account.Policy
}

func newFakeDevice(view shell.View, next func(string, *fakeDevice)) *fakeDevice {
	return &fakeDevice{view: view, next: next, secrets: map[string][]byte{}, given: map[string]string{}, session: "TOKEN-1"}
}

func (d *fakeDevice) did(call string, secret []byte, given ...string) {
	d.mu.Lock()
	d.calls = append(d.calls, call)
	if secret != nil {
		d.secrets[call] = bytes.Clone(secret)
	}
	d.given[call] = strings.Join(given, "|")
	next := d.next
	d.mu.Unlock()
	if next != nil {
		next(call, d)
	}
}

func (d *fakeDevice) View() shell.View { d.mu.Lock(); defer d.mu.Unlock(); return d.view }
func (d *fakeDevice) Begin()           { d.mu.Lock(); d.view.Notice = ""; d.mu.Unlock() }
func (d *fakeDevice) Make(secret, again []byte) {
	d.did("make", secret, string(again))
	clear(secret)
	clear(again)
}
func (d *fakeDevice) Setup(_ context.Context, name, accepted string, secret, again []byte) {
	d.did("setup", secret, name, accepted)
	clear(secret)
	clear(again)
}
func (d *fakeDevice) Create(_ context.Context, name, accepted string) {
	d.did("create", nil, name, accepted)
}
func (d *fakeDevice) Terms(context.Context) (*account.Policy, error) { return d.terms, nil }
func (d *fakeDevice) Enroll(_ context.Context, name string, _ time.Duration) {
	d.did("enroll", nil, name)
}
func (d *fakeDevice) CheckListed(context.Context)              { d.did("check", nil) }
func (d *fakeDevice) Saved(_ context.Context, accepted string) { d.did("saved", nil, accepted) }
func (d *fakeDevice) Resume(_ context.Context, code string)    { d.did("resume", []byte(code)) }
func (d *fakeDevice) Unlock(_ context.Context, secret []byte)  { d.did("unlock", secret); clear(secret) }
func (d *fakeDevice) Rename(_ context.Context, name string)    { d.did("rename", nil, name) }
func (d *fakeDevice) Session(context.Context) (string, error) {
	d.did("session", nil)
	return d.session, nil
}
func (d *fakeDevice) Draw(_ context.Context, ref string) { d.did("draw", nil, ref) }
func (d *fakeDevice) Decide(_ context.Context, ref string, confirm bool, secret []byte) {
	d.did("decide", secret, ref, strconv.FormatBool(confirm))
	clear(secret)
}
func (d *fakeDevice) Unlocked() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.view.Page == shell.PageUnlocked || d.view.Page == shell.PageConfirm
}
func (d *fakeDevice) Lock(string) { d.mu.Lock(); d.locks++; d.mu.Unlock() }

func (d *fakeDevice) set(v shell.View) { d.mu.Lock(); d.view = v; d.mu.Unlock() }

// typed is a console the person types lines into, its output kept.
func typed(lines ...string) (*console, *bytes.Buffer) {
	ch := make(chan []byte, len(lines))
	for _, l := range lines {
		ch <- []byte(l)
	}
	close(ch)
	out := &bytes.Buffer{}
	quiet := 0
	return &console{out: out, lines: func() <-chan []byte { return ch },
		quiet: func() func() { quiet++; return func() {} }}, out
}

const passphrase = "abandon ability able about above absent"

// cyfr login on a machine without a chip makes the key under the
// passphrase it shows, typed twice, before anything is shown or sent;
// then shows the key's code, the QR code of the account page that adds
// it, that address and the command that adds it from a terminal, asks the
// name and waits for the account to list it; the first unlock takes the
// passphrase chosen, which it never prints again and erases once used.
func TestLoginDriver_EnrollShowsTheCodeAndWaits(t *testing.T) {
	const addURL = "https://cyfr.run/account/add#key=KEY&alg=ed25519&kind=device&code=0123456789abcdef"
	enroll := shell.View{Page: shell.PageEnroll, Code: "0123456789abcdef", AddURL: addURL, Key: "KEY", Kind: holder.KindSoftware}
	dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
		switch call {
		case "make":
			d.set(enroll)
		case "enroll":
			d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindSoftware})
		case "unlock":
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out := typed(passphrase, passphrase, "@mira")
	d := &loginDriver{sh: dev, c: c, mode: "login", home: "https://alice.example"}
	if err := d.run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"make", "enroll", "unlock"}) || dev.given["enroll"] != "mira" {
		t.Fatalf("calls %v, enrolled %q", dev.calls, dev.given["enroll"])
	}
	if string(dev.secrets["make"]) != passphrase || string(dev.secrets["unlock"]) != passphrase {
		t.Errorf("made with %q, unlocked with %q", dev.secrets["make"], dev.secrets["unlock"])
	}
	printed := out.String()
	for _, want := range []string{passphrase, "0123456789abcdef", addURL, "cyfr device approve KEY", "▀", "Your name: @", "Waiting until your account lists"} {
		if !strings.Contains(printed, want) {
			t.Errorf("the output lacks %q:\n%s", want, printed)
		}
	}
	if strings.Count(printed, passphrase) != 1 {
		t.Errorf("the passphrase was printed more than the once it is shown:\n%s", printed)
	}
	if d.held != nil {
		t.Error("the passphrase is held after the unlock")
	}
}

// A key an earlier run made, no account listing it yet, is added by a
// later one, and the PIN asked once: the key is not made again; a key not
// approved within the wait ends the run with the device's sentence.
func TestLoginDriver_ALaterRunAddsTheKeyAndAsksThePIN(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageEnroll, Code: "c", AddURL: "https://cyfr.run/account/add#key=K", Key: "K", Kind: holder.KindChip},
		func(call string, d *fakeDevice) {
			switch call {
			case "enroll":
				d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindChip})
			case "unlock":
				d.set(shell.View{Page: shell.PageUnlocked})
			}
		})
	c, out := typed("mira", "123456")
	if err := (&loginDriver{sh: dev, c: c, mode: "login"}).run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"enroll", "check", "unlock"}) || string(dev.secrets["unlock"]) != "123456" || !strings.Contains(out.String(), "PIN: ") {
		t.Fatalf("calls %v, secret %q\n%s", dev.calls, dev.secrets["unlock"], out)
	}

	waits := newFakeDevice(shell.View{Page: shell.PageEnroll, Code: "c", AddURL: "u", Key: "K"}, func(call string, d *fakeDevice) {
		v := d.View()
		v.Notice = "This command line is not on @mira's account yet. Approve it on a device of yours, then try again."
		d.set(v)
	})
	c, _ = typed("mira")
	err := (&loginDriver{sh: waits, c: c, mode: "login"}).run(t.Context())
	if err == nil || !strings.Contains(err.Error(), "not on @mira's account yet") || !strings.Contains(err.Error(), "Run cyfr login to go on") || waits.locks != 1 {
		t.Fatalf("an unapproved key: %v, locks %d", err, waits.locks)
	}
}

// A key the account's log no longer lists is said so before any PIN is
// asked: the same key's code, the QR code of the account page that adds
// it, that address and the command that adds it from a terminal are shown
// again, the name asked and the log waited on as a first enrollment does;
// once listed, the log is read again and the PIN unlocks it.
func TestLoginDriver_AKeyTheLogNoLongerListsIsAddedAgain(t *testing.T) {
	const addURL = "https://cyfr.run/account/add#key=KEY&alg=ed25519&kind=device&code=0123456789abcdef"
	checks := 0
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, func(call string, d *fakeDevice) {
		switch {
		case call == "check" && checks == 0:
			checks++
			d.set(shell.View{Page: shell.PageEnroll, Code: "0123456789abcdef", AddURL: addURL, Key: "KEY", Kind: holder.KindChip,
				Notice: "Your account no longer lists this command line's key. Add the same key to your account again to go on."})
		case call == "enroll":
			d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindChip})
		case call == "unlock":
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out := typed("@mira", "123456")
	if err := (&loginDriver{sh: dev, c: c, mode: "login"}).run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"check", "enroll", "check", "unlock"}) || dev.given["enroll"] != "mira" || string(dev.secrets["unlock"]) != "123456" {
		t.Fatalf("calls %v, enrolled %q, unlocked with %q", dev.calls, dev.given["enroll"], dev.secrets["unlock"])
	}
	printed := out.String()
	said := strings.Index(printed, "Your account no longer lists this command line's key.")
	code := strings.Index(printed, "Its code is 0123456789abcdef.")
	if said < 0 || code < said || strings.Index(printed, "PIN: ") < code {
		t.Errorf("the sentence, then the code, then the PIN, not:\n%s", printed)
	}
	for _, want := range []string{addURL, "cyfr device approve KEY", "▀", "Your name: @", "Waiting until your account lists"} {
		if !strings.Contains(printed, want) {
			t.Errorf("the output lacks %q:\n%s", want, printed)
		}
	}
}

// A key the account's log still lists goes straight to the PIN: no code,
// no name, no wait.
func TestLoginDriver_AListedKeyGoesStraightToThePIN(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, func(call string, d *fakeDevice) {
		if call == "unlock" {
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out := typed("123456")
	if err := (&loginDriver{sh: dev, c: c, mode: "login"}).run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"check", "unlock"}) || strings.Contains(out.String(), "code is") || strings.Contains(out.String(), "Your name") {
		t.Fatalf("calls %v\n%s", dev.calls, out)
	}
}

// Where the chip keeps the key, a six-digit PIN is asked twice; a chip
// that cannot protect it makes the device show a passphrase instead,
// which is asked for next, and the run goes on with it.
func TestLoginDriver_ARefusedChipOffersThePassphrase(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageSetup, Chip: true}, nil)
	dev.next = func(call string, d *fakeDevice) {
		switch {
		case call == "make" && string(d.secrets["make"]) == "123456":
			d.set(shell.View{Page: shell.PageSetup, Chip: true, Passphrase: passphrase,
				Notice: "This machine's chip cannot keep your PIN safely (lockout). Use the passphrase below instead."})
		case call == "make":
			d.set(shell.View{Page: shell.PageEnroll, Code: "c", AddURL: "u", Key: "K", Kind: holder.KindSoftware})
		case call == "enroll":
			d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindSoftware})
		case call == "unlock":
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	}
	c, out := typed("123456", "123456", passphrase, passphrase, "mira")
	d := &loginDriver{sh: dev, c: c, mode: "login", home: "https://alice.example"}
	if err := d.run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"make", "make", "enroll", "unlock"}) || string(dev.secrets["unlock"]) != passphrase {
		t.Fatalf("calls %v, unlocked with %q", dev.calls, dev.secrets["unlock"])
	}
	for _, want := range []string{"six-digit PIN", "cannot keep your PIN safely", passphrase} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

// --setup and --join make the account here: the terms the account service
// names are accepted first, then the name and the secret go to the
// device, the recovery code is shown, as a QR code and as text, until
// Enter says it was saved, which sends it; a name taken meanwhile is
// asked again. Without an answer to the terms nothing is made.
func TestLoginDriver_ANewAccountSavesTheRecoveryCode(t *testing.T) {
	for _, mode := range []string{"setup", "join"} {
		dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
			switch call {
			case "setup":
				d.set(shell.View{Page: shell.PageRecovery, RecoveryCode: "CYFR-RECOVERY-CODE", Name: "mira"})
			case "saved":
				d.set(shell.View{Page: shell.PageName, Name: "mira", Notice: "Someone holds the name @mira. Choose another: your account is made, and takes a name once one is free."})
			case "rename":
				d.set(shell.View{Page: shell.PageUnlocked})
			}
		})
		dev.terms = &account.Policy{Version: "2026-10", URL: "https://cyfr.run/terms"}
		c, out := typed("yes", passphrase, passphrase, "", "@mira2")
		d := &loginDriver{sh: dev, c: c, mode: mode, name: "mira", invitation: "INVITE", home: "https://alice.example"}
		if err := d.run(t.Context()); err != nil {
			t.Fatalf("%s: %v\n%s", mode, err, out)
		}
		if !slices.Equal(dev.calls, []string{"setup", "saved", "rename"}) || dev.given["setup"] != "mira|2026-10" || dev.given["rename"] != "mira2" {
			t.Fatalf("%s: calls %v, given %v", mode, dev.calls, dev.given)
		}
		for _, want := range []string{"https://cyfr.run/terms", "CYFR-RECOVERY-CODE", "▀", "Press Enter once you saved it", "Choose another"} {
			if !strings.Contains(out.String(), want) {
				t.Errorf("%s: the output lacks %q:\n%s", mode, want, out)
			}
		}
	}
	dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, nil)
	dev.terms = &account.Policy{Version: "2026-10", URL: "https://cyfr.run/terms"}
	c, _ := typed("no")
	if err := (&loginDriver{sh: dev, c: c, mode: "setup", name: "mira"}).run(t.Context()); err == nil || len(dev.calls) != 0 {
		t.Fatalf("declined terms: %v, calls %v", err, dev.calls)
	}
}

// A key that exists already makes the account with --setup, never again a
// key; an account an earlier run began is finished with its recovery
// code.
func TestLoginDriver_AnExistingKeyMakesTheAccountOrFinishesIt(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageEnroll, Code: "c", AddURL: "u", Key: "K"}, func(call string, d *fakeDevice) {
		if call == "create" {
			d.set(shell.View{Page: shell.PageRecovery, RecoveryCode: "CYFR-CODE", Name: "mira"})
		}
		if call == "saved" {
			d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindChip})
		}
		if call == "unlock" {
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out := typed("", "123456")
	if err := (&loginDriver{sh: dev, c: c, mode: "setup", name: "mira"}).run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"create", "saved", "check", "unlock"}) || dev.given["create"] != "mira|" {
		t.Fatalf("calls %v, given %v", dev.calls, dev.given)
	}

	resume := newFakeDevice(shell.View{Page: shell.PageResume, Name: "mira"}, func(call string, d *fakeDevice) {
		if call == "resume" {
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out = typed("CYFR-CODE")
	if err := (&loginDriver{sh: resume, c: c, mode: "login"}).run(t.Context()); err != nil {
		t.Fatalf("resume: %v\n%s", err, out)
	}
	if string(resume.secrets["resume"]) != "CYFR-CODE" || !strings.Contains(out.String(), "@mira") || strings.Contains(out.String(), "CYFR-CODE") {
		t.Fatalf("resumed with %q\n%s", resume.secrets["resume"], out)
	}
}

// An action that leaves its page as it was ends the run with the
// device's sentence and locks it: a wrong PIN is said, never tried again
// by itself; input that ends before an answer ends the run too.
func TestLoginDriver_AFailureEndsWithItsSentenceAndLocks(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, func(call string, d *fakeDevice) {
		if call == "unlock" {
			d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindChip, Notice: "That is not this command line's PIN or passphrase. Nothing was sent anywhere."})
		}
	})
	c, _ := typed("000000", "123456")
	d := &loginDriver{sh: dev, c: c, mode: "login", home: "https://alice.example"}
	err := d.run(t.Context())
	if err == nil || !strings.Contains(err.Error(), "not this command line's PIN") || !slices.Equal(dev.calls, []string{"check", "unlock"}) || dev.locks != 1 {
		t.Fatalf("run: %v, calls %v, locks %d", err, dev.calls, dev.locks)
	}

	ended := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, nil)
	c, _ = typed()
	if err := (&loginDriver{sh: ended, c: c, mode: "login"}).run(t.Context()); !errors.Is(err, errInputEnded) || !slices.Equal(ended.calls, []string{"check"}) {
		t.Fatalf("ended input: %v, calls %v", err, ended.calls)
	}
}

// cyfr login refuses, before any key is made or anything sent, what it
// cannot hold: off a terminal (unattended work uses an API key), flags
// that do not go together, and a terminal it unlocked already.
func TestLogin_RefusesWhatItCannotHold(t *testing.T) {
	home, reached := countingHome(t)
	withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	opened := 0
	previous := openDevice
	openDevice = func(o deviceOptions) (device, error) { opened++; return previous(o) }
	t.Cleanup(func() { openDevice = previous })

	for args, want := range map[string]string{
		"login":                            "on a terminal",
		"login --setup --join":             "use one of them",
		"login --setup --invitation CODE":  "use one of them",
		"login --name mira":                "use it with one of them",
		"login --join --name mira --token": "",
	} {
		if want == "" {
			continue
		}
		_, err := runCommand(t, t.Context(), strings.Fields(args)...)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %q", args, err, want)
		}
	}
	t.Setenv(sessionHomeEnv, home.URL)
	if _, err := runCommand(t, t.Context(), "login"); err == nil || !strings.Contains(err.Error(), "unlocked by cyfr login already") {
		t.Errorf("a login shell's login: %v", err)
	}
	if opened != 0 || reached.Load() != 0 {
		t.Errorf("refused logins opened the device %d times and asked the home %d things", opened, reached.Load())
	}
	entries, _ := os.ReadDir(filepath.Join(os.Getenv("HOME"), ".cyfr", "device"))
	if len(entries) != 0 {
		t.Errorf("a refused login made a key: %v", entries)
	}
}

// A command sends the session of cyfr login's shell only to that shell's
// home, and an API key given by --token or CYFR_TOKEN before it; nothing
// stored sends a credential.
func TestClientAt_TheShellsSessionGoesToItsHomeAlone(t *testing.T) {
	withContexts(t, "home", map[string]*config.Context{"home": {URL: "https://alice.example"}})
	t.Setenv(sessionEnv, "TOKEN-1")
	t.Setenv(sessionHomeEnv, "https://ALICE.example/")
	if got := clientAt("https://alice.example").SessionID; got != "TOKEN-1" {
		t.Errorf("the shell's home was sent %q", got)
	}
	for _, other := range []string{"https://mallory.example", "http://alice.example", "https://alice.example/other"} {
		if got := clientAt(other).SessionID; got != "" {
			t.Errorf("%s was sent %q", other, got)
		}
	}
	t.Setenv("CYFR_TOKEN", "cyfr_key")
	if got := clientAt("https://alice.example").SessionID; got != "cyfr_key" {
		t.Errorf("CYFR_TOKEN did not come first: %q", got)
	}
}

// A sign-in an earlier command line saved under a context is deleted from
// the config at the first command that reads it, which says once to run
// cyfr login; it is never sent to the home.
func TestOldSignIn_IsDeletedAndNeverSent(t *testing.T) {
	var auth []string
	var mu sync.Mutex
	home := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("Authorization"))
		mu.Unlock()
		http.Error(w, "no", http.StatusUnauthorized)
	}))
	t.Cleanup(home.Close)
	path := withContexts(t, "home", map[string]*config.Context{"home": {URL: home.URL}})
	raw, _ := json.Marshal(map[string]any{"current_context": "home",
		"contexts": map[string]any{"home": map[string]any{"url": home.URL, "token": "an-old-cli-session"}}})
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	stderr, _ := runCommand(t, t.Context(), "whoami")
	if !strings.Contains(stderr, "The sign-in this command line saved for home was deleted") || !strings.Contains(stderr, "Run cyfr login") {
		t.Errorf("no sentence:\n%s", stderr)
	}
	after, _ := os.ReadFile(path)
	if bytes.Contains(after, []byte("an-old-cli-session")) || bytes.Contains(after, []byte(`"token"`)) {
		t.Errorf("the old sign-in is still stored:\n%s", after)
	}
	for _, a := range auth {
		if strings.Contains(a, "an-old-cli-session") {
			t.Errorf("the old sign-in was sent: %q", a)
		}
	}
	if again, _ := runCommand(t, t.Context(), "whoami"); strings.Contains(again, "was deleted") {
		t.Errorf("said twice:\n%s", again)
	}
}

// pairedRecord writes this machine's key, listed in an account, and a
// client at address in its context, as cyfr login leaves them.
func pairedRecord(t *testing.T, address string) {
	t.Helper()
	path, err := deviceKey()
	if err != nil {
		t.Fatal(err)
	}
	rec, err := holder.NewSoftware([]byte(passphrase))
	if err != nil {
		t.Fatal(err)
	}
	rec.Identifier, rec.Directory = "per_"+strings.Repeat("a", 64), "https://cyfr.run"
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := rec.Save(path); err != nil {
		t.Fatal(err)
	}
	if err := (contextClients{address: address}).Save(shell.ClientRecord{ClientID: "pcl_1", Certificate: json.RawMessage(`{"client_id":"pcl_1"}`)}); err != nil {
		t.Fatal(err)
	}
}

// A change answered confirmation_required on a command line paired with
// the home is offered for confirmation here, in C4's order: the home's
// preview for exactly the pending ref is drawn first, then the PIN or
// passphrase is asked once, after it, and that secret confirms the drawn
// change; the device is locked again. Enter alone repeats the call once
// confirmed elsewhere, signing nothing; a wrong secret is said and the
// call repeats; a device that cannot draw the change leaves the plain
// wait.
func TestConfirmationWait_ConfirmsOnThisDevice(t *testing.T) {
	withContexts(t, "home", map[string]*config.Context{"home": {URL: "https://alice.example"}})
	pairedRecord(t, "https://alice.example")
	var dev *fakeDevice
	previous := openDevice
	openDevice = func(o deviceOptions) (device, error) {
		if o.address != "https://alice.example" {
			t.Errorf("opened the device of %s", o.address)
		}
		return dev, nil
	}
	t.Cleanup(func() { openDevice = previous })
	const id = "cfm_secret-id"
	pending := &mcp.ConsentError{Tag: "confirmation_required", Payload: map[string]any{"id": id, "operation": "pairing.begin"}}
	device := func(drawn bool, notice string) *fakeDevice {
		return newFakeDevice(shell.View{Page: shell.PageLocked}, func(call string, d *fakeDevice) {
			switch {
			case call == "draw" && drawn:
				d.set(shell.View{Page: shell.PageConfirm, Confirm: &shell.PendingConfirm{Ref: confirmation.Ref(id),
					Operation: "pairing.begin", Preview: map[string]any{"key_digest": "THE-DIGEST"}}})
			case call == "draw":
				d.set(shell.View{Page: shell.PageLocked, Notice: "This command line confirms a change in the shell cyfr login started."})
			case call == "decide":
				d.set(shell.View{Page: shell.PageLocked, Notice: notice})
			}
		})
	}
	run := func(lines ...string) (error, string) {
		ch := make(chan []byte, len(lines))
		for _, l := range lines {
			ch <- []byte(l)
		}
		out := &bytes.Buffer{}
		w := &confirmationWait{out: out, interactive: func() bool { return true }, now: time.Now,
			lines: func() <-chan []byte { return ch }, address: "https://alice.example", device: confirmOnDevice}
		return w.wait(t.Context(), pending, false), out.String()
	}

	dev = device(true, "Confirmed on this command line.")
	err, out := run(passphrase)
	if err != nil || strings.Index(out, "THE-DIGEST") > strings.Index(out, "PIN or passphrase") || strings.Index(out, "THE-DIGEST") < 0 {
		t.Fatalf("confirmed: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"draw", "decide"}) || dev.given["draw"] != confirmation.Ref(id) ||
		dev.given["decide"] != confirmation.Ref(id)+"|true" || string(dev.secrets["decide"]) != passphrase || dev.locks != 1 {
		t.Fatalf("calls %v, given %v, locks %d", dev.calls, dev.given, dev.locks)
	}

	dev = device(true, "")
	if err, _ := run(""); err != nil || dev.given["decide"] != confirmation.Ref(id)+"|false" {
		t.Fatalf("Enter alone: %v, %v", err, dev.given)
	}

	dev = device(true, "That is not this command line's PIN or passphrase. Nothing was sent anywhere. Nothing was signed.")
	if err, out := run("000000"); err != nil || !strings.Contains(out, "not this command line's PIN") {
		t.Fatalf("a wrong secret: %v\n%s", err, out)
	}

	dev = device(false, "")
	if err, out := run(""); err != nil || !slices.Equal(dev.calls, []string{"draw"}) || !strings.Contains(out, "Press Enter once confirmed") ||
		!strings.Contains(out, "in the shell cyfr login started") {
		t.Fatalf("no drawing: %v, calls %v\n%s", err, dev.calls, out)
	}
}

// captureStderr runs fn with standard error captured.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = w
	out := make(chan []byte)
	go func() {
		var b bytes.Buffer
		_, _ = b.ReadFrom(r)
		out <- b.Bytes()
	}()
	fn()
	os.Stderr = saved
	w.Close()
	return string(<-out)
}

// cyfr login's console reads one line per question and nothing past it:
// what is typed after its last answer stays for the shell it starts.
func TestAskedLine_TakesNothingPastItsLine(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })
	if _, err := w.WriteString("the link\r\ncyfr whoami\n"); err != nil {
		t.Fatal(err)
	}
	line, open := <-askedLine(r)
	if !open || string(line) != "the link" {
		t.Fatalf("asked line %q, %v", line, open)
	}
	w.Close()
	rest, _ := io.ReadAll(r)
	if string(rest) != "cyfr whoami\n" {
		t.Errorf("the shell would read %q", rest)
	}
	if _, open := <-askedLine(r); open {
		t.Error("an ended input answered a line")
	}
}

// The console cyfr login asks on leaves the terminal unread once its last
// question is answered: the line typed next, the first command in the
// shell it starts, reaches that shell.
func TestLoginConsole_LeavesTheNextLineToTheShell(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { r.Close(); w.Close() })
	saved := os.Stdin
	os.Stdin = r
	t.Cleanup(func() { os.Stdin = saved })
	if _, err := w.WriteString("https://alice.example/pair#code=CODE\n"); err != nil {
		t.Fatal(err)
	}
	c := newConsole(io.Discard)
	c.quiet = func() func() { return func() {} }
	if line, err := c.line(t.Context(), "Link or code: "); err != nil || string(line) != "https://alice.example/pair#code=CODE" {
		t.Fatalf("answered %q, %v", line, err)
	}
	time.Sleep(50 * time.Millisecond)
	if _, err := w.WriteString("cyfr whoami\n"); err != nil {
		t.Fatal(err)
	}
	w.Close()
	got := make(chan []byte, 1)
	go func() { rest, _ := io.ReadAll(r); got <- rest }()
	select {
	case rest := <-got:
		if string(rest) != "cyfr whoami\n" {
			t.Errorf("the shell would read %q", rest)
		}
	case <-time.After(2 * time.Second):
		t.Error("the shell's first line was taken")
	}
}

// In cyfr login's shell the change to confirm is read through the shell's
// session, the ref alone asked for, and drawn as the home answered it;
// outside that shell nothing is drawn and the sentence says where it is.
func TestSessionDevice_DrawsTheChangeThroughTheSession(t *testing.T) {
	var auth string
	srv := newCLIServer(t, "", `{"confirmations":[{"ref":"cnr_1","operation":"pairing.begin","preview":{"key_digest":"D1"},"asker":{"name":"cyfr on box"}}]}`)
	inner := srv.Config.Handler
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		inner.ServeHTTP(w, r)
	})
	session := mcp.NewClient(srv.URL)
	session.SessionID = "TOKEN-1"
	d := &sessionDevice{session: session}
	d.Draw(t.Context(), "cnr_1")
	v := d.View()
	if v.Page != shell.PageConfirm || v.Confirm.Operation != "pairing.begin" || v.Confirm.Preview["key_digest"] != "D1" || auth != "Bearer TOKEN-1" {
		t.Fatalf("drawn %+v, auth %q", v, auth)
	}
	if name, args := srv.call(0); name != "confirmation" || args["action"] != "pending" || args["request"] != "cnr_1" {
		t.Errorf("asked %s %v", name, args)
	}

	outside := &sessionDevice{}
	outside.Draw(t.Context(), "cnr_1")
	if outside.drawn != nil || !strings.Contains(outside.notice, "in the shell cyfr login started") {
		t.Errorf("outside the shell: %+v, %q", outside.drawn, outside.notice)
	}
}

// An account whose submission got no answer is tried once more, then the
// run ends, locked, saying which command finishes it, and asks for no
// other name.
func TestLoginDriver_AnAnswerThatDoesNotComeEndsTheRunToFinishLater(t *testing.T) {
	for mode, again := range map[string]string{"setup": "cyfr login --setup", "join": "cyfr login --join --invitation CODE"} {
		dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
			switch call {
			case "setup":
				d.set(shell.View{Page: shell.PageRecovery, RecoveryCode: "CYFR-CODE", Name: "proof"})
			case "saved":
				d.set(shell.View{Page: shell.PageAccount, Name: "proof",
					Notice: "Your account is not finished: Your account could not be reached just now. Try again; nothing is lost."})
			}
		})
		c, out := typed(passphrase, passphrase, "")
		err := (&loginDriver{sh: dev, c: c, mode: mode, name: "proof", invitation: "INVITE", home: "https://alice.example"}).run(t.Context())
		if err == nil || !strings.HasSuffix(err.Error(), "Run "+again+" to go on.") || dev.locks != 1 ||
			!slices.Equal(dev.calls, []string{"setup", "saved", "saved"}) {
			t.Fatalf("%s: %v, calls %v, locks %d\n%s", mode, err, dev.calls, dev.locks, out)
		}
	}
}

// The local context cyfr init saves names CYFR by its loopback IP, while
// CYFR names itself localhost in what its devices sign: the command line's
// device is CYFR's own address. One key serves every address, kept under
// ~/.cyfr/device, and the client each CYFR admits it as is kept in that
// CYFR's context, a new one named by its host where none is at it.
func TestDeviceShell_OneKeyAndAClientPerContext(t *testing.T) {
	path := withContexts(t, "local", map[string]*config.Context{"local": {URL: "http://127.0.0.1:4000"}})
	for address, want := range map[string]string{
		"http://127.0.0.1:4000":     "http://localhost:4000",
		"http://[::1]:4000":         "http://localhost:4000",
		"https://home.example":      "https://home.example",
		"https://home.example:8443": "https://home.example:8443",
	} {
		if got := deviceHome(address); got != want {
			t.Errorf("%s: %s, want %s", address, got, want)
		}
	}
	key, _ := deviceKey()
	if key != filepath.Join(filepath.Dir(path), "device", "key.json") {
		t.Errorf("the key is at %s", key)
	}
	for address, id := range map[string]string{"http://127.0.0.1:4000/": "pcl_local", "https://home.example": "pcl_home"} {
		if err := (contextClients{address: address}).Save(shell.ClientRecord{ClientID: id, Certificate: json.RawMessage(`{"a":1}`)}); err != nil {
			t.Fatal(err)
		}
	}
	cfg, _ := config.LoadFrom(path)
	if cfg.Contexts["local"].ClientID != "pcl_local" || cfg.Contexts["home.example"] == nil || cfg.Contexts["home.example"].ClientID != "pcl_home" {
		t.Fatalf("contexts %+v", cfg.Contexts)
	}
	if got, _ := (contextClients{address: "https://HOME.example"}).Load(); got.ClientID != "pcl_home" {
		t.Errorf("the client at home.example is %+v", got)
	}
}
