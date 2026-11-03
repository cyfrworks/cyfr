// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"context"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cyfr/codex/internal/disk"
	"github.com/cyfr/codex/internal/holder"
)

// pinLine is a command line without a chip at a home on another machine,
// whose pin.enroll is the fake home's; here makes the home this machine.
func pinLine(t *testing.T, home *fakeHome, dir string, here bool) *Shell {
	t.Helper()
	path := filepath.Join(dir, "device.json")
	sh, err := New(Config{
		Address: home.address(), Client: home.srv.Client(), Record: path, DataDir: dir,
		Detect:    func(string) disk.Report { return disk.Report{} },
		Chip:      func() bool { return false },
		Noun:      "command line",
		Pair:      home.pair,
		HomeHere:  here,
		EnrollPIN: func(context.Context) (string, error) { return home.pin.enroll(path) },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sh.Lock("") })
	return sh
}

// pinned is a paired command line switched to the PIN 123456, locked.
func pinned(t *testing.T, home *fakeHome, dir string) (*Shell, []byte) {
	t.Helper()
	sh := pinLine(t, home, dir, false)
	pass := pairOnBox(t, home, sh)
	if !sh.Unlocked() {
		t.Fatalf("not paired: %q", sh.View().Notice)
	}
	sh.SetPIN(t.Context(), []byte("123456"), []byte("123456"))
	if !strings.Contains(sh.View().Notice, "now kept under your six-digit PIN") {
		t.Fatalf("SetPIN: %q", sh.View().Notice)
	}
	sh.Lock("")
	return sh, pass
}

func record(t *testing.T, dir string) *holder.Record {
	t.Helper()
	rec, err := holder.Load(filepath.Join(dir, "device.json"))
	if err != nil {
		t.Fatal(err)
	}
	return rec
}

// A paired command line keeps its key under a six-digit PIN once the home
// names an evaluator: the record holds the PIN blob in place of the
// passphrase's, one evaluation was charged and then reset by the opened
// key. Each unlock after is one evaluation and one reset; the passphrase
// opens nothing any more, and no byte the home received holds the PIN.
func TestSetPIN_KeepsTheKeyUnderAPINTheHomeCounts(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh, pass := pinned(t, home, dir)
	rec := record(t, dir)
	if rec.PIN == nil || rec.Software != nil || rec.PIN.Evaluator != "dpe_1" || rec.Kind != holder.KindSoftware {
		t.Fatalf("record after SetPIN: %+v", rec)
	}
	if home.pin.charged != 1 || len(home.pin.resets) != 1 {
		t.Fatalf("enrollment: charged %d, resets %v", home.pin.charged, home.pin.resets)
	}

	sh.Unlock(t.Context(), []byte("123456"))
	if !sh.Unlocked() || home.pin.charged != 2 || len(home.pin.resets) != 2 {
		t.Fatalf("unlock: %v, charged %d, resets %v, notice %q", sh.Unlocked(), home.pin.charged, home.pin.resets, sh.View().Notice)
	}
	if attempts, _, _ := home.pin.state("dpe_1"); attempts != 0 {
		t.Fatalf("a successful unlock left %d attempts counted", attempts)
	}
	sh.Lock("")
	sh.Unlock(t.Context(), pass)
	if sh.Unlocked() || home.pin.charged != 2 {
		t.Fatalf("the passphrase still opens: %v, charged %d", sh.Unlocked(), home.pin.charged)
	}
	if strings.Contains(home.received.String(), "123456") {
		t.Fatal("the home received the PIN")
	}
}

// A wrong PIN is one charged evaluation and says so; a try before the
// home's next_allowed_at is refused with the one sentence naming that
// time, and nothing is retried by itself.
func TestPIN_AWrongPINIsChargedAndTheWaitIsSaid(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	before := home.pin.charged
	sh.Unlock(t.Context(), []byte("654321"))
	if v := sh.View(); sh.Unlocked() || v.Notice != "That is not this command line's PIN. CYFR counted the try: each wrong one makes the next wait longer." {
		t.Fatalf("wrong PIN: unlocked %v, notice %q", sh.Unlocked(), v.Notice)
	}
	if home.pin.charged != before+1 || len(home.pin.resets) != 1 {
		t.Fatalf("wrong PIN: charged %d, resets %v", home.pin.charged-before, home.pin.resets)
	}
	sh.Unlock(t.Context(), []byte("123456"))
	home.mu.Lock()
	next := home.pin.evaluators["dpe_1"].next
	home.mu.Unlock()
	want := "Too many wrong PINs: CYFR takes this command line's next try at " + next.Local().Format("15:04:05") + "."
	if v := sh.View(); sh.Unlocked() || v.Notice != want || home.pin.charged != before+1 {
		t.Fatalf("within the wait: unlocked %v, notice %q (want %q), charged %d", sh.Unlocked(), v.Notice, want, home.pin.charged-before)
	}
	home.pin.allow()
	sh.Unlock(t.Context(), []byte("123456"))
	if attempts, _, _ := home.pin.state("dpe_1"); !sh.Unlocked() || attempts != 0 {
		t.Fatalf("after the wait: unlocked %v, attempts %d", sh.Unlocked(), attempts)
	}
}

// An evaluation whose answer is lost stays charged: the unlock fails as
// CYFR not reached, sends nothing more, and the next explicit try is
// charged again before its reset starts the count anew.
func TestPIN_ADroppedAnswerIsChargedAndNeverRetried(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	before := home.pin.charged
	home.pin.set(func(p *pinHome) { p.dropEvaluate = true })
	sh.Unlock(t.Context(), []byte("123456"))
	if v := sh.View(); sh.Unlocked() || !strings.Contains(v.Notice, "could not be reached") {
		t.Fatalf("dropped answer: unlocked %v, notice %q", sh.Unlocked(), v.Notice)
	}
	if attempts, _, _ := home.pin.state("dpe_1"); home.pin.charged != before+1 || home.pin.evaluations != before+1 || attempts != 1 {
		t.Fatalf("dropped answer: charged %d, asked %d, attempts %d", home.pin.charged-before, home.pin.evaluations-before, attempts)
	}
	home.pin.allow()
	sh.Unlock(t.Context(), []byte("123456"))
	if attempts, _, _ := home.pin.state("dpe_1"); !sh.Unlocked() || home.pin.charged != before+2 || attempts != 0 {
		t.Fatalf("next try: unlocked %v, charged %d, attempts %d", sh.Unlocked(), home.pin.charged-before, attempts)
	}
}

// After a reboot the device has its record alone: with the home out of
// reach the PIN opens nothing, since no key or evaluation outlives the
// process; once the home answers, the same PIN unlocks.
func TestPIN_AfterARebootTheFirstUnlockNeedsTheHome(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	first, _ := pinned(t, home, dir)
	first.Lock("")
	rebooted := pinLine(t, home, dir, false)
	home.pin.set(func(p *pinHome) { p.down = true })
	rebooted.Unlock(t.Context(), []byte("123456"))
	if v := rebooted.View(); rebooted.Unlocked() || v.Page != PageLocked || !strings.Contains(v.Notice, "could not be reached") {
		t.Fatalf("home away: unlocked %v, page %s, notice %q", rebooted.Unlocked(), v.Page, v.Notice)
	}
	home.pin.set(func(p *pinHome) { p.down = false })
	rebooted.Unlock(t.Context(), []byte("123456"))
	if !rebooted.Unlocked() {
		t.Fatalf("home back: %q", rebooted.View().Notice)
	}
}

// A confirmation on an unlocked device evaluates the PIN again: the key
// this unlock holds signs nothing for it, and a wrong PIN signs nothing.
func TestPIN_AConfirmationEvaluatesThePINAgain(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	sh.Unlock(t.Context(), []byte("123456"))
	home.pending["cnr_1"] = map[string]any{"ref": "cnr_1", "operation": "pairing.begin", "preview": map[string]any{"key_digest": "D1"}}
	before := home.pin.charged

	sh.Draw(t.Context(), "cnr_1")
	sh.Decide(t.Context(), "cnr_1", true, []byte("111111"))
	if len(home.confirmed) != 0 || home.pin.charged != before+1 {
		t.Fatalf("a wrong PIN: confirmed %d, charged %d, notice %q", len(home.confirmed), home.pin.charged-before, sh.View().Notice)
	}
	home.pin.allow()
	sh.Draw(t.Context(), "cnr_1")
	sh.Decide(t.Context(), "cnr_1", true, []byte("123456"))
	if len(home.confirmed) != 1 || home.pin.charged != before+2 {
		t.Fatalf("confirmed %d, charged %d, notice %q", len(home.confirmed), home.pin.charged-before, sh.View().Notice)
	}
}

// The terminal's confirmation (ConfirmDrawn) evaluates too.
func TestPIN_ATerminalConfirmationEvaluatesThePIN(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	home.pending["cnr_1"] = map[string]any{"ref": "cnr_1", "operation": "pairing.begin", "preview": map[string]any{"key_digest": "D1"}}
	before := home.pin.charged
	sh.ConfirmDrawn(t.Context(), PendingConfirm{Ref: "cnr_1", Operation: "pairing.begin", Preview: map[string]any{"key_digest": "D1"}}, []byte("123456"))
	if len(home.confirmed) != 1 || home.pin.charged != before+1 || sh.Unlocked() {
		t.Fatalf("confirmed %d, charged %d, unlocked %v, notice %q", len(home.confirmed), home.pin.charged-before, sh.Unlocked(), sh.View().Notice)
	}
}

// Where the home is this same machine, no PIN is set up and none is
// sent: the sentence says why and what a self-contained box uses.
func TestPIN_RefusedWhereTheHomeIsThisMachine(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh := pinLine(t, home, dir, true)
	pairOnBox(t, home, sh)
	sh.SetPIN(t.Context(), []byte("123456"), []byte("123456"))
	if v := sh.View(); home.pin.enrolls != 0 || record(t, dir).PIN != nil || !strings.Contains(v.Notice, "CYFR runs on this machine") ||
		!strings.Contains(v.Notice, "A self-contained box keeps its key under its chip's PIN or a passphrase.") {
		t.Fatalf("enrolls %d, notice %q", home.pin.enrolls, v.Notice)
	}

	// A PIN record moved onto the home's own machine opens nothing either.
	other := t.TempDir()
	pinned(t, home, other)
	here := pinLine(t, home, other, true)
	before := home.pin.evaluations
	here.Unlock(t.Context(), []byte("123456"))
	if here.Unlocked() || home.pin.evaluations != before || !strings.Contains(here.View().Notice, "CYFR runs on this machine") {
		t.Fatalf("a PIN record here: unlocked %v, asked %d", here.Unlocked(), home.pin.evaluations-before)
	}
}

// The reset is signed only when its challenge is this device's: one
// naming another client is not signed, the count stays charged, and the
// unlock itself still holds.
func TestPIN_AResetNamingAnotherDeviceIsNotSigned(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	home.pin.set(func(p *pinHome) { p.tamper = func(c map[string]any) { c["client_id"] = "pcl_someone_else" } })
	sh.Unlock(t.Context(), []byte("123456"))
	if attempts, _, _ := home.pin.state("dpe_1"); !sh.Unlocked() || attempts != 1 || len(home.pin.resets) != 1 || home.pin.staleResets != 0 {
		t.Fatalf("unlocked %v, attempts %d, resets %v, stale %d", sh.Unlocked(), attempts, home.pin.resets, home.pin.staleResets)
	}
}

// A replacement that cannot be written keeps the old record, which still
// opens under the old PIN: the home keeps the old evaluator until the new
// one's first reset, which is sent only after the record is written. A
// replacement that is written retires the old evaluator.
func TestSetPIN_AReplacementNotWrittenKeepsTheOldEvaluator(t *testing.T) {
	home := newFakeHome(t)
	dir := t.TempDir()
	sh, _ := pinned(t, home, dir)
	sh.Unlock(t.Context(), []byte("123456"))
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	sh.SetPIN(t.Context(), []byte("222222"), []byte("222222"))
	_ = os.Chmod(dir, 0o700)
	if rec := record(t, dir); rec.PIN.Evaluator != "dpe_1" || !strings.Contains(sh.View().Notice, "could not save") {
		t.Fatalf("record %s, notice %q", rec.PIN.Evaluator, sh.View().Notice)
	}
	if _, _, live := home.pin.state("dpe_1"); !live {
		t.Fatal("the old evaluator was retired before the new record was written")
	}
	sh.Lock("")
	sh.Unlock(t.Context(), []byte("123456"))
	if !sh.Unlocked() {
		t.Fatalf("the old PIN no longer opens: %q", sh.View().Notice)
	}

	sh.SetPIN(t.Context(), []byte("222222"), []byte("222222"))
	if rec := record(t, dir); rec.PIN.Evaluator != "dpe_3" {
		t.Fatalf("replaced under %s", rec.PIN.Evaluator)
	}
	if _, _, live := home.pin.state("dpe_1"); live {
		t.Fatal("the old evaluator outlived the new one's reset")
	}
	sh.Lock("")
	sh.Unlock(t.Context(), []byte("222222"))
	if !sh.Unlocked() {
		t.Fatalf("the new PIN does not open: %q", sh.View().Notice)
	}
}

// An evaluator the home does not know (removed, or suspended by a backup
// restore) says so without naming why, and offers the recovery code; the
// code re-enables the device first, then the PIN is evaluated.
func TestPIN_ASuspendedEvaluatorComesBackWithTheRecoveryCode(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	home.mu.Lock()
	home.pin.evaluators["dpe_1"].suspended = true
	home.mu.Unlock()
	sh.Unlock(t.Context(), []byte("123456"))
	v := sh.View()
	if sh.Unlocked() || !v.Kit || !strings.Contains(v.Notice, "does not take this command line's PIN") {
		t.Fatalf("suspended: unlocked %v, kit %v, notice %q", sh.Unlocked(), v.Kit, v.Notice)
	}
	var kit struct {
		Kit struct{ Seed, Public string } `json:"kit"`
	}
	fixture(t, "restore_kit.json", &kit)
	seed, _ := unb64(kit.Kit.Seed)
	home.mu.Lock()
	home.kitPublic, _ = unb64(kit.Kit.Public)
	home.mu.Unlock()
	before := home.pin.evaluations
	sh.Reenable(t.Context(), encodeRecoveryCode(make([]byte, 32), seed), []byte("123456"))
	if !sh.Unlocked() || len(home.reenabled) != 1 || home.pin.evaluations != before+1 {
		t.Fatalf("re-enabled %v, unlocked %v, asked %d, notice %q", home.reenabled, sh.Unlocked(), home.pin.evaluations-before, sh.View().Notice)
	}
}

// The lock page of a key under a PIN asks six digits, and after a wrong
// PIN within the wait says the same sentence the terminal says.
func TestPIN_TheLockPageAsksThePINAndSaysTheWait(t *testing.T) {
	home := newFakeHome(t)
	sh, _ := pinned(t, home, t.TempDir())
	b := &box{t: t, home: home, shell: sh, srv: &Server{Shell: sh}}
	if page := b.page(); !strings.Contains(page, `inputmode="numeric" maxlength="6"`) {
		t.Fatalf("the lock page does not ask six digits:\n%s", page)
	}
	b.post("/unlock", url.Values{"secret": {"654321"}})
	b.post("/unlock", url.Values{"secret": {"123456"}})
	home.mu.Lock()
	next := home.pin.evaluators["dpe_1"].next
	home.mu.Unlock()
	want := "Too many wrong PINs: CYFR takes this command line's next try at " + next.Local().Format("15:04:05") + "."
	if page := b.page(); !strings.Contains(page, want) || sh.Unlocked() {
		t.Fatalf("the lock page does not say %q:\n%s", want, page)
	}
}
