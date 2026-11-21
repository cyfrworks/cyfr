// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// The session's own lock, its LockedHint turning true and the computer
// going to sleep lock the device; another session's lock, an unlock and
// waking do not.
func TestTheSessionLockAndSleepLock(t *testing.T) {
	const mine, other = dbus.ObjectPath("/org/freedesktop/login1/session/_32"), dbus.ObjectPath("/org/freedesktop/login1/session/_33")
	hint := func(path dbus.ObjectPath, v bool) *dbus.Signal {
		return &dbus.Signal{Path: path, Name: dbusProps + ".PropertiesChanged",
			Body: []any{login1Sess, map[string]dbus.Variant{lockedHint: dbus.MakeVariant(v)}, []string{}}}
	}
	for _, tc := range []struct {
		name  string
		sig   *dbus.Signal
		locks bool
	}{
		{"this session's lock", &dbus.Signal{Path: mine, Name: login1Sess + ".Lock"}, true},
		{"its locked hint", hint(mine, true), true},
		{"sleep", &dbus.Signal{Path: login1Path, Name: login1Seat + ".PrepareForSleep", Body: []any{true}}, true},
		{"another session's lock", &dbus.Signal{Path: other, Name: login1Sess + ".Lock"}, false},
		{"another session's hint", hint(other, true), false},
		{"an unlock", &dbus.Signal{Path: mine, Name: login1Sess + ".Unlock"}, false},
		{"the hint turning false", hint(mine, false), false},
		{"waking", &dbus.Signal{Path: login1Path, Name: login1Seat + ".PrepareForSleep", Body: []any{false}}, false},
	} {
		if got := lockSignal(tc.sig, mine) != ""; got != tc.locks {
			t.Errorf("%s: locks %v", tc.name, got)
		}
	}
	if lockSignal(&dbus.Signal{Path: mine, Name: login1Sess + ".Lock"}, "") != "" {
		t.Error("a process in no session locked on a session's signal")
	}
}

// Where the system bus cannot be reached, the app's cyfr still serves,
// and its chooser tells the person in one sentence that CYFR does not lock
// with this computer.
func TestTheChooserSaysWhenThisComputersLockIsNotHeard(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DBUS_SYSTEM_BUS_ADDRESS", "unix:path="+home+"/no-bus")
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	ended := make(chan error, 1)
	go func() { ended <- runDesktopServe(context.Background(), inR, outW); outW.Close() }()
	lines := bufio.NewScanner(outR)
	if !lines.Scan() {
		t.Fatal("cyfr said nothing")
	}
	var ready struct{ URL string }
	if err := json.Unmarshal(lines.Bytes(), &ready); err != nil {
		t.Fatal(err)
	}
	_, token, _ := strings.Cut(ready.URL, "#token=")
	req, _ := http.NewRequest(http.MethodPost, "http://127.0.0.1:7340/bootstrap/state", strings.NewReader(`{"token":"`+token+`"}`))
	req.Header.Set("Origin", "http://127.0.0.1:7340")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var state struct{ Warning string }
	err = json.NewDecoder(resp.Body).Decode(&state)
	resp.Body.Close()
	if err != nil || state.Warning != notWatched {
		t.Fatalf("the chooser says %q (%v)", state.Warning, err)
	}
	go func() { _, _ = io.Copy(io.Discard, outR) }()
	_, _ = io.WriteString(inW, `{"version":1,"type":"shutdown"}`+"\n")
	select {
	case <-ended:
	case <-time.After(10 * time.Second):
		t.Fatal("shutdown did not end cyfr")
	}
}

// Hearing the bus lost while running, a closed channel or a nil signal,
// or logind leaving it, locks and says so, and crashes nothing; another
// name leaving does nothing, and the bus closed at the end of the run
// does neither.
func TestLosingTheSystemBusLocksAndSaysSo(t *testing.T) {
	for _, lost := range []func(chan *dbus.Signal){
		func(c chan *dbus.Signal) { close(c) },
		func(c chan *dbus.Signal) { c <- nil },
	} {
		signals := make(chan *dbus.Signal, 1)
		var locked, warned []string
		lost(signals)
		watchSignals(context.Background(), signals, "", func(why string) { locked = append(locked, why) },
			func(s string) { warned = append(warned, s) })
		if len(locked) != 1 || locked[0] != watchLost || len(warned) != 1 || warned[0] != notWatched {
			t.Fatalf("locked %q, warned %q", locked, warned)
		}
	}
	signals := make(chan *dbus.Signal, 2)
	var locked, warned []string
	signals <- &dbus.Signal{Name: dbusName + ".NameOwnerChanged", Body: []any{"org.freedesktop.Accounts", ":1.4", ""}}
	signals <- &dbus.Signal{Name: dbusName + ".NameOwnerChanged", Body: []any{login1, ":1.2", ""}}
	close(signals)
	watchSignals(context.Background(), signals, "", func(why string) { locked = append(locked, why) },
		func(s string) { warned = append(warned, s) })
	if len(locked) != 1 || locked[0] != logindLost || len(warned) != 1 || warned[0] != notWatched {
		t.Fatalf("logind leaving the bus: locked %q, warned %q", locked, warned)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ended := make(chan *dbus.Signal)
	close(ended)
	watchSignals(ctx, ended, "", func(string) { t.Error("the run's end locked") }, func(string) { t.Error("the run's end warned") })
}

// fakeBus answers the session at once and sends each signal of leaving
// to the channels registered by then, at the moment the session is
// resolved.
type fakeBus struct {
	channels []chan<- *dbus.Signal
	leaving  []*dbus.Signal
}

func (b *fakeBus) Signal(ch chan<- *dbus.Signal)            { b.channels = append(b.channels, ch) }
func (b *fakeBus) AddMatchSignal(...dbus.MatchOption) error { return nil }
func (b *fakeBus) Close() error                             { return nil }
func (b *fakeBus) sessionOf(context.Context) (dbus.ObjectPath, error) {
	for _, sig := range b.leaving {
		for _, ch := range b.channels {
			ch <- sig
		}
	}
	return "/org/freedesktop/login1/session/_32", nil
}

// logind leaving between the subscription and the session's resolution is
// seen as a loss: the channel was registered before either.
func TestLogindLeavingWhileTheWatchIsSetUpIsALoss(t *testing.T) {
	b := &fakeBus{leaving: []*dbus.Signal{{Name: dbusName + ".NameOwnerChanged", Body: []any{login1, ":1.2", ""}}}}
	locked := make(chan string, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	watchBus(ctx, b, func(why string) { locked <- why }, func(string) {})
	select {
	case why := <-locked:
		if why != logindLost {
			t.Fatalf("locked: %q", why)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("logind left while the watch was set up, unseen")
	}
}
