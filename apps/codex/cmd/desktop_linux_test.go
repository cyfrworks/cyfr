// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"testing"

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
