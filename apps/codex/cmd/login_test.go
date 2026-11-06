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
func (d *fakeDevice) Setup(_ context.Context, name string, secret, again []byte) {
	d.did("setup", secret, name, string(again))
	clear(secret)
	clear(again)
}
func (d *fakeDevice) Join(_ context.Context, invitation, name string, secret, again []byte) {
	d.did("join", secret, invitation, name)
	clear(secret)
	clear(again)
}
func (d *fakeDevice) Prepare(secret, again []byte) {
	d.did("prepare", secret, string(again))
	clear(again)
}
func (d *fakeDevice) Pair(_ context.Context, link string, secret []byte) {
	d.did("pair", secret, link)
	clear(secret)
}
func (d *fakeDevice) Finish(_ context.Context, name, code string, secret []byte) {
	d.did("finish", secret, name, code)
	clear(secret)
}
func (d *fakeDevice) Unlock(_ context.Context, secret []byte) { d.did("unlock", secret); clear(secret) }
func (d *fakeDevice) Saved(context.Context)                   { d.did("saved", nil) }
func (d *fakeDevice) Rename(_ context.Context, name string)   { d.did("rename", nil, name) }
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
func (d *fakeDevice) SetPIN(_ context.Context, pin, again []byte) {
	d.did("setpin", pin, string(again))
	clear(pin)
	clear(again)
}

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
// passphrase it shows, typed twice, before anything is sent; then shows
// the approve address as a QR code, the address and the key's code a
// person types on a device without a camera, takes the link pasted, and
// completes the pairing with that link and the same passphrase, which
// it never prints and erases once used.
func TestLoginDriver_PairShowsTheApprovalAndTakesTheLink(t *testing.T) {
	const digest = "sv5QHby2ooLrBWLs_JOrjk8goRiwYWrrCDbE2RuiE0o"
	dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
		switch call {
		case "prepare":
			d.set(shell.View{Page: shell.PageFinish, Admission: "pair", Digest: digest, Kind: holder.KindSoftware})
		case "pair":
			d.set(shell.View{Page: shell.PageUnlocked})
		}
	})
	c, out := typed(passphrase, passphrase, "https://alice.example/pair#code=CODE")
	d := &loginDriver{sh: dev, c: c, mode: "pair", home: "https://alice.example"}
	if err := d.run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"prepare", "pair"}) {
		t.Fatalf("calls %v", dev.calls)
	}
	if string(dev.secrets["prepare"]) != passphrase || string(dev.secrets["pair"]) != passphrase ||
		dev.given["pair"] != "https://alice.example/pair#code=CODE" {
		t.Errorf("prepared with %q, paired with %q and %q", dev.secrets["prepare"], dev.secrets["pair"], dev.given["pair"])
	}
	printed := out.String()
	for _, want := range []string{passphrase, "https://alice.example/devices/add", shell.KeyCode(digest), "▀", "Link or code: "} {
		if !strings.Contains(printed, want) {
			t.Errorf("the output lacks %q:\n%s", want, printed)
		}
	}
	if strings.Count(printed, passphrase) != 1 {
		t.Errorf("the passphrase was printed more than the once it is shown:\n%s", printed)
	}
	if d.held != nil {
		t.Error("the passphrase is held after the pairing")
	}
}

// A key made by an earlier run whose pairing did not finish is paired by
// a later one with the code alone, typed on a machine without a camera,
// and the PIN asked once: the key is not made again.
func TestLoginDriver_ALaterRunFinishesThePairingWithATypedCode(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageFinish, Admission: "pair", Digest: "DIGEST", Kind: holder.KindChip},
		func(call string, d *fakeDevice) {
			if call == "pair" {
				d.set(shell.View{Page: shell.PageUnlocked})
			}
		})
	c, out := typed("7Kq2 pX9a bC3d eF4g hI", "123456")
	d := &loginDriver{sh: dev, c: c, mode: "pair", home: "https://alice.example"}
	if err := d.run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"pair"}) || dev.given["pair"] != "7Kq2 pX9a bC3d eF4g hI" || string(dev.secrets["pair"]) != "123456" {
		t.Fatalf("calls %v, given %q, secret %q", dev.calls, dev.given["pair"], dev.secrets["pair"])
	}
	if !strings.Contains(out.String(), "PIN: ") {
		t.Errorf("no PIN asked:\n%s", out)
	}
}

// Where the chip keeps the key, a six-digit PIN is asked twice; a chip
// that cannot protect it makes the device show a passphrase instead,
// which is asked for next, and the run goes on with it.
func TestLoginDriver_ARefusedChipOffersThePassphrase(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageSetup, Chip: true}, nil)
	dev.next = func(call string, d *fakeDevice) {
		if call != "prepare" {
			if call == "pair" {
				d.set(shell.View{Page: shell.PageUnlocked})
			}
			return
		}
		if string(d.secrets["prepare"]) == "123456" {
			d.set(shell.View{Page: shell.PageSetup, Chip: true, Passphrase: passphrase,
				Notice: "This box's chip cannot keep your PIN safely (lockout). Use the passphrase below instead."})
			return
		}
		d.set(shell.View{Page: shell.PageFinish, Admission: "pair", Digest: "DIGEST", Kind: holder.KindSoftware})
	}
	c, out := typed("123456", "123456", passphrase, passphrase, "CODE")
	d := &loginDriver{sh: dev, c: c, mode: "pair", home: "https://alice.example"}
	if err := d.run(t.Context()); err != nil {
		t.Fatalf("run: %v\n%s", err, out)
	}
	if !slices.Equal(dev.calls, []string{"prepare", "prepare", "pair"}) || string(dev.secrets["pair"]) != passphrase {
		t.Fatalf("calls %v, paired with %q", dev.calls, dev.secrets["pair"])
	}
	for _, want := range []string{"six-digit PIN", "cannot keep your PIN safely", passphrase} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("the output lacks %q:\n%s", want, out)
		}
	}
}

// --setup and --join make a person with this device: the name and the
// secret go to the device's admission, the recovery code is shown, as a
// QR code and as text, until Enter says it was saved, and a name taken
// is asked again.
func TestLoginDriver_ANewPersonSavesTheRecoveryCode(t *testing.T) {
	for _, mode := range []string{"setup", "join"} {
		dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
			switch call {
			case "setup", "join":
				d.set(shell.View{Page: shell.PageName, Name: "mira", Notice: "Someone holds the name mira, or cyfr.run keeps it. Choose another."})
			case "rename":
				d.set(shell.View{Page: shell.PageRecovery, Recovery: &shell.Recovery{Code: "CYFR-RECOVERY-CODE", Name: "mira2"}})
			case "saved":
				d.set(shell.View{Page: shell.PageUnlocked})
			}
		})
		c, out := typed(passphrase, passphrase, "@mira2", "")
		d := &loginDriver{sh: dev, c: c, mode: mode, name: "mira", invitation: "INVITE", home: "https://alice.example"}
		if err := d.run(t.Context()); err != nil {
			t.Fatalf("%s: %v\n%s", mode, err, out)
		}
		if !slices.Equal(dev.calls, []string{mode, "rename", "saved"}) || dev.given["rename"] != "mira2" {
			t.Fatalf("%s: calls %v, renamed %q", mode, dev.calls, dev.given["rename"])
		}
		if mode == "join" && dev.given["join"] != "INVITE|mira" {
			t.Errorf("joined with %q", dev.given["join"])
		}
		for _, want := range []string{"CYFR-RECOVERY-CODE", "▀", "Press Enter once you saved it", "Choose another"} {
			if !strings.Contains(out.String(), want) {
				t.Errorf("%s: the output lacks %q:\n%s", mode, want, out)
			}
		}
	}
}

// An action that leaves its page as it was ends the run with the
// device's sentence and locks it: a wrong PIN is said, never tried again
// by itself; input that ends before an answer ends the run too.
func TestLoginDriver_AFailureEndsWithItsSentenceAndLocks(t *testing.T) {
	dev := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, func(call string, d *fakeDevice) {
		d.set(shell.View{Page: shell.PageLocked, Kind: holder.KindChip, Notice: "That is not this command line's PIN or passphrase. Nothing was sent anywhere."})
	})
	c, _ := typed("000000", "123456")
	d := &loginDriver{sh: dev, c: c, mode: "pair", home: "https://alice.example"}
	err := d.run(t.Context())
	if err == nil || !strings.Contains(err.Error(), "not this command line's PIN") || len(dev.calls) != 1 || dev.locks != 1 {
		t.Fatalf("run: %v, calls %v, locks %d", err, dev.calls, dev.locks)
	}

	ended := newFakeDevice(shell.View{Page: shell.PageLocked, Kind: holder.KindChip}, nil)
	c, _ = typed()
	if err := (&loginDriver{sh: ended, c: c, mode: "pair"}).run(t.Context()); !errors.Is(err, errInputEnded) || len(ended.calls) != 0 {
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
	entries, _ := os.ReadDir(filepath.Join(os.Getenv("HOME"), ".cyfr", "devices"))
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

// pairedRecord writes a paired device record for address, as cyfr login
// leaves one.
func pairedRecord(t *testing.T, address string) {
	t.Helper()
	path, err := deviceRecord(address)
	if err != nil {
		t.Fatal(err)
	}
	rec, err := holder.NewSoftware(address, "", "pair", []byte(passphrase))
	if err != nil {
		t.Fatal(err)
	}
	rec.ClientID, rec.Athanor, rec.Certificate = "pcl_1", "ath_1", json.RawMessage(`{"client_id":"pcl_1"}`)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := rec.Save(path); err != nil {
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

// A person made while cyfr.run does not answer has their name waiting for
// it, not for another: cyfr login ends, locked, saying which command
// finishes it, and asks for no other name.
func TestLoginDriver_ASilentCyfrRunEndsTheRunToFinishLater(t *testing.T) {
	for mode, again := range map[string]string{"setup": "cyfr login --setup", "join": "cyfr login --join --invitation CODE"} {
		dev := newFakeDevice(shell.View{Page: shell.PageSetup, Passphrase: passphrase}, func(call string, d *fakeDevice) {
			if call == mode {
				d.set(shell.View{Page: shell.PageName, Name: "proof", NameWaits: true,
					Notice: "cyfr.run did not answer. Try again in a moment; you are set up already."})
			}
		})
		c, out := typed(passphrase, passphrase)
		err := (&loginDriver{sh: dev, c: c, mode: mode, name: "proof", invitation: "INVITE", home: "https://alice.example"}).run(t.Context())
		if err == nil || err.Error() != "cyfr.run did not answer. Run "+again+" again to finish." || dev.locks != 1 ||
			slices.Contains(dev.calls, "rename") || strings.Contains(out.String(), "Your name, yours for life") {
			t.Fatalf("%s: %v, calls %v, locks %d\n%s", mode, err, dev.calls, dev.locks, out)
		}
	}
}

// The local context cyfr init saves names the home by its loopback IP,
// while the home names itself localhost in what its devices sign: the
// command line's device is the home's own address, so its key record and
// every challenge it checks say localhost; any other address is kept.
func TestDeviceShell_ALoopbackContextIsTheHomesLocalhost(t *testing.T) {
	withContexts(t, "local", map[string]*config.Context{"local": {URL: "http://127.0.0.1:4000"}})
	saved := deviceChip
	deviceChip = func() bool { return false }
	t.Cleanup(func() { deviceChip = saved })
	for address, want := range map[string]string{
		"http://127.0.0.1:4000":     "http://localhost:4000",
		"http://[::1]:4000":         "http://localhost:4000",
		"https://home.example":      "https://home.example",
		"https://home.example:8443": "https://home.example:8443",
	} {
		sh, err := deviceShell(deviceOptions{address: address})
		if err != nil {
			t.Fatal(err)
		}
		p := sh.View().Passphrase
		sh.Prepare([]byte(p), []byte(p))
		path, _ := deviceRecord(address)
		rec, err := holder.Load(path)
		if err != nil || rec.Home != want {
			t.Errorf("%s: the key is for %v (%v), want %s", address, rec, err, want)
		}
		_ = os.Remove(path)
	}
}
