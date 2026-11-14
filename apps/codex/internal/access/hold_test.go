// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package access

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// heldAndStopped holds the running stack for cause and stops all of it,
// as a command that stops the stack itself does, then ends the process
// there: the lock's descriptor closed, nothing else cleaned up, and the
// home opened by a new engine, as the next command.
func heldAndStopped(t *testing.T, h *testHome, cause string) {
	t.Helper()
	h.fake.startStack(t, h.head())
	if err := h.e.Hold(cause); err != nil {
		t.Fatal(err)
	}
	if _, err := h.e.Stop(bg, cause, true); err != nil {
		t.Fatal(err)
	}
	if running := h.fake.runningServices(); len(running) != 0 {
		t.Fatalf("%v still run after the stop", running)
	}
	h.crash()
	h.open()
}

// holdJournal is the hold the journal holds, failing when it holds none.
func holdJournal(t *testing.T, h *testHome) journal {
	t.Helper()
	j, err := h.e.readJournal()
	if err != nil || j == nil {
		t.Fatalf("the journal holds %+v (%v), want the hold", j, err)
	}
	return *j
}

// A command that dies after it held and stopped the running stack, under
// any cause, a cause the engine has never named included, leaves the start
// it owed to the next command's recovery: .env's head starts as Start
// starts it, and the hold's receipt, durable, names the cause; nothing of
// the hold is left and the start after the recovery runs.
func TestRecoveryStartsTheStackADeadCommandHeld(t *testing.T) {
	for _, cause := range []string{"backup", "update", "a-command-not-yet-written"} {
		t.Run(cause, func(t *testing.T) {
			h := newHome(t)
			heldAndStopped(t, h, cause)
			j := holdJournal(t, h)
			wantDigest := requestDigest(map[string]any{"op": "hold", "cause": cause})
			if j.Op != "hold" || j.Cause != cause || j.Phase != "held" || len(j.RequestID) != 32 || j.RequestDigest != wantDigest {
				t.Errorf("the hold is %+v", j)
			}
			receipts, err := h.e.Resume(bg)
			if err != nil {
				t.Fatal(err)
			}
			head := h.head()
			want := Receipt{RequestID: j.RequestID, RequestDigest: wantDigest, Op: "hold", Cause: cause, State: "completed", Outcome: "ok", FinalHead: &head}
			if len(receipts) != 1 {
				t.Fatalf("recovery answered %+v, want the hold's receipt", receipts)
			}
			got := receipts[0]
			got.At = want.At
			if !reflect.DeepEqual(got, want) {
				t.Errorf("recovery answered %+v, want %+v", got, want)
			}
			durable, ok, err := h.e.readReceipt(j.RequestID)
			durable.At = want.At
			if err != nil || !ok || !reflect.DeepEqual(durable, want) {
				t.Errorf("the durable receipt is %+v (found %v, %v)", durable, ok, err)
			}
			h.assertConverged(baseStack...)
			if rc, err := h.e.Start(bg, "up"); err != nil || rc.Outcome != "ok" {
				t.Errorf("the start after recovery answered %+v, %v", rc, err)
			}
			if again, err := h.e.Resume(bg); err != nil || len(again) != 0 {
				t.Errorf("a second recovery answered %+v, %v", again, err)
			}
		})
	}
}

// A hold strands no start: Start while the journal holds it is not
// refused, and it closes the hold with no receipt of its own, the command
// that held the stack reporting its start; nothing is left for recovery.
func TestTheHoldersStartClosesTheHold(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	if err := h.e.Hold("backup"); err != nil {
		t.Fatal(err)
	}
	j := holdJournal(t, h)
	if _, err := h.e.Stop(bg, "backup", true); err != nil {
		t.Fatal(err)
	}
	if rc, err := h.e.StartWithin(bg, "backup", HealthDeadline); err != nil || rc.Outcome != "ok" {
		t.Fatalf("the holder's start answered %+v, %v", rc, err)
	}
	h.assertConverged(baseStack...)
	if _, ok, err := h.e.readReceipt(j.RequestID); ok || err != nil {
		t.Errorf("the closed hold wrote a receipt (%v)", err)
	}
	h.crash()
	h.open()
	if receipts, err := h.e.Resume(bg); err != nil || len(receipts) != 0 {
		t.Errorf("recovery after the holder's start answered %+v, %v", receipts, err)
	}
}

// A start that fails closes the hold too: the command reports it, and the
// next command does not start the stack again on the hold's account.
func TestAFailedStartOfTheHolderClosesTheHold(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	if err := h.e.Hold("backup"); err != nil {
		t.Fatal(err)
	}
	h.fake.mu.Lock()
	h.fake.st.Health = "unhealthy"
	h.fake.mu.Unlock()
	if _, err := h.e.StartWithin(bg, "backup", HealthDeadline); err == nil || !strings.Contains(err.Error(), "health check failed") {
		t.Fatalf("the unhealthy start answered %v", err)
	}
	if j, err := h.e.readJournal(); j != nil || err != nil {
		t.Errorf("the journal holds %+v (%v) after the holder's start", j, err)
	}
}

// Release closes the hold with nothing started: a command that dies after
// it, as an update after its switch, leaves the stack stopped, and the
// next command's recovery starts nothing and answers no receipt.
func TestAReleasedHoldStartsNothing(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	if err := h.e.Hold("update"); err != nil {
		t.Fatal(err)
	}
	if _, err := h.e.Stop(bg, "update", true); err != nil {
		t.Fatal(err)
	}
	if err := h.e.Release(); err != nil {
		t.Fatal(err)
	}
	h.crash()
	h.open()
	before := len(h.fake.calls())
	receipts, err := h.e.Resume(bg)
	if err != nil || len(receipts) != 0 {
		t.Errorf("recovery after the release answered %+v, %v", receipts, err)
	}
	for _, c := range h.fake.calls()[before:] {
		if strings.Contains(" "+c.String()+" ", " up ") {
			t.Errorf("recovery after the release started %s", c)
		}
	}
	h.assertConverged()
	if err := h.e.Release(); err != nil {
		t.Errorf("a release with no hold answered %v", err)
	}
}

// A dead holder's start that fails in recovery is told, its reason in the
// receipt, and the hold is finished, so no later command starts it again
// on the hold's account.
func TestRecoveryOfAHoldWhoseStartFailsFinishesIt(t *testing.T) {
	h := newHome(t)
	heldAndStopped(t, h, "backup")
	j := holdJournal(t, h)
	h.fake.mu.Lock()
	h.fake.st.Health = "unhealthy"
	h.fake.mu.Unlock()
	receipts, err := h.e.Resume(bg)
	if err != nil {
		t.Fatal(err)
	}
	want := Receipt{RequestID: j.RequestID, RequestDigest: j.RequestDigest, Op: "hold", Cause: "backup", State: "completed", Outcome: "failed",
		Payload: map[string]string{"reason": "cyfr's health check failed"}}
	if len(receipts) != 1 {
		t.Fatalf("recovery answered %+v", receipts)
	}
	got := receipts[0]
	got.At = want.At
	if !reflect.DeepEqual(got, want) {
		t.Errorf("recovery answered %+v, want %+v", got, want)
	}
	if j, err := h.e.readJournal(); j != nil || err != nil {
		t.Errorf("the journal holds %+v (%v) after recovery", j, err)
	}
}

// A hold is refused while the journal holds another operation, which it
// leaves as it was, and without the lock.
func TestHoldRefusesOverAnotherOperationAndWithoutTheLock(t *testing.T) {
	h := newHome(t)
	h.fake.startStack(t, h.head())
	r := h.request(id(1), publicTarget, "")
	if !h.killAt("journal:switch:stopped", func(e *Engine) { e.Switch(bg, r) }) {
		t.Fatal("the switch never stopped")
	}
	journalPath := filepath.Join(h.dir, stateDir, journalFile)
	before, _ := os.ReadFile(journalPath)
	if err := h.e.Hold("backup"); err == nil || err.Error() != "access: the switch "+id(1)+" is unfinished" {
		t.Errorf("a hold over an unfinished switch answered %v", err)
	}
	if after, _ := os.ReadFile(journalPath); string(after) != string(before) {
		t.Errorf("the refused hold changed the journal:\n%s", after)
	}

	other := newHome(t)
	e, err := Open(other.dir, other.fake)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Hold("backup"); err == nil {
		t.Error("a hold without the lock was taken")
	}
}

// A hold whose recovery cannot read .env stays for the next command, and
// recovery answers the error with no receipt.
func TestAHoldStaysWhileEnvCannotBeRead(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads any file")
	}
	h := newHome(t)
	heldAndStopped(t, h, "backup")
	j := holdJournal(t, h)
	env := filepath.Join(h.dir, ".env")
	if err := os.Chmod(env, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(env, 0o600) })
	receipts, err := h.e.Resume(bg)
	if err == nil || len(receipts) != 0 {
		t.Errorf("recovery over an unreadable .env answered %+v, %v", receipts, err)
	}
	if after := holdJournal(t, h); after.RequestID != j.RequestID {
		t.Errorf("the hold became %+v", after)
	}
}
