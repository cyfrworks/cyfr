// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package shell

import (
	"net/http"
	"sync"
	"testing"
	"time"
)

// heldAt is what the shell holds, told and stored at one moment of a lock.
type heldAt struct {
	open                           bool
	key, making, passphrase, proof bool
	// told is how many sessions the CYFR heard locked; certified whether
	// the stored record still holds its certificate.
	told      int
	certified bool
}

// heldNow reads it; at the hide, the shell is held by the lock reading it.
func heldNow(b *box) heldAt {
	b.home.mu.Lock()
	told := len(b.home.locked)
	b.home.mu.Unlock()
	s := b.shell
	return heldAt{open: s.Unlocked(), key: s.key != nil, making: s.making != nil, passphrase: s.passphrase != "",
		proof: s.proof != nil, told: told, certified: len(b.client().Certificate) > 0}
}

// Every way a lock begins goes through its one entry, whose first two acts
// are locked and the hide: at the hide the shell says locked, and nothing
// it held is erased, no session is told and no record is written yet. Only
// then are the sessions told, the key and every secret erased, and a
// revoked channel's record written. Every lock hides, whatever the screen
// showed: the lock page's form may hold what a person typed there.
func TestLock_EveryRoadIsLockedThenHiddenBeforeAnythingElse(t *testing.T) {
	open := func(t *testing.T) *box {
		home := newFakeHome(t)
		b := newBox(t, home, t.TempDir())
		setUpAndOpen(t, home, b)
		return b
	}
	drawn := func(t *testing.T) *box {
		_, b := aBox(t, func(*Config) {})
		b.shown()
		return b
	}
	recovery := func(t *testing.T) *box {
		_, b := aBox(t, func(*Config) {})
		b.setUp("alice")
		return b
	}
	unwatched := func(t *testing.T) *box {
		_, b := aBox(t, func(c *Config) { c.Unwatched = func() string { return "This screen cannot tell when to lock." } })
		return b
	}
	locked := func(t *testing.T) *box {
		b := open(t)
		b.shell.Lock("")
		return b
	}
	lock := func(why string) func(*box) { return func(b *box) { b.shell.Lock(why) } }
	for _, c := range []struct {
		name string
		made func(*testing.T) *box
		lock func(*box)
		// tells is whether the CYFR still hears the channel, so it is told
		// each session's lock.
		tells bool
	}{
		{"Prism's Lock", open, func(b *box) { b.do(http.MethodPost, "/lock", b.home.address(), nil) }, true},
		{"five minutes without input", open, lock("Locked after five minutes without use."), true},
		{"a suspend", open, lock(suspendedHere), true},
		{"a watch lost", open, lock(""), true},
		{"the browser's or the app's end", open, lock("Locked because the browser closed."), true},
		{"the shell's own end", open, lock(""), true},
		{"a dropped channel", open, func(b *box) { b.home.closeChannels(1011) }, false},
		{"a revoked channel", open, func(b *box) { b.home.revoke() }, false},
		{"setup's passphrase on the screen", drawn, lock(""), false},
		{"a recovery code on the screen", recovery, lock(""), false},
		{"a watch lost, the screen locked", unwatched, lock(""), false},
		// The lock page's form may hold what a person typed there.
		{"five minutes without input on the lock page", locked, lock("Locked after five minutes without use."), false},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := c.made(t)
			before := heldNow(b)
			var at heldAt
			var first sync.Once
			hid := make(chan struct{})
			b.shell.cfg.Restart = func() {
				first.Do(func() {
					at = heldNow(b)
					close(hid)
				})
			}
			c.lock(b)
			select {
			case <-hid:
			case <-time.After(10 * time.Second):
				t.Fatal("the lock never hid the screen")
			}
			// The lock runs on to its end before anything is read after it.
			b.shell.Lock("")
			want := before
			want.open = false
			if at != want {
				t.Fatalf("at the hide the shell held %+v, want %+v: locked, and nothing else changed", at, want)
			}
			after := heldNow(b)
			if after.key || after.making || after.passphrase || after.proof || after.open {
				t.Fatalf("after the lock the shell still held %+v", after)
			}
			if c.tells && after.told == before.told {
				t.Fatal("the lock told the CYFR no session")
			}
			if c.name == "a revoked channel" && after.certified {
				t.Fatal("the revoked channel's record kept its certificate")
			}
		})
	}
}
