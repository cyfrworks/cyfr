// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"os"

	"github.com/godbus/dbus/v5"
)

const (
	login1      = "org.freedesktop.login1"
	login1Path  = dbus.ObjectPath("/org/freedesktop/login1")
	login1Seat  = "org.freedesktop.login1.Manager"
	login1Sess  = "org.freedesktop.login1.Session"
	dbusProps   = "org.freedesktop.DBus.Properties"
	dbusName    = "org.freedesktop.DBus"
	lockedHint  = "LockedHint"
	sessionLock = "Lock"
)

// The sentences the chooser shows where this computer's lock is not
// heard, and the lock's when hearing it stops.
const (
	notWatched     = "CYFR cannot tell when this computer locks or sleeps here, so it does not lock when the computer does."
	sessionUnheard = "CYFR cannot tell when this computer locks here, only when it sleeps, so it does not lock when the computer locks."
	watchLost      = "Locked: CYFR stopped hearing this computer's lock."
	logindLost     = "Locked: this computer's login manager stopped, so CYFR stopped hearing its lock."
)

// watchSessionLock calls lock whenever this login session locks (logind's
// Lock signal, or its LockedHint turning true) or the computer is about
// to sleep (PrepareForSleep), until ctx ends. It fails closed and never
// silently: what it cannot watch from the start it tells warn, in the
// sentence the chooser shows, and losing the system bus, or logind
// leaving it, while running locks and tells warn too.
func watchSessionLock(ctx context.Context, lock func(why string), warn func(sentence string)) {
	conn, err := dbus.ConnectSystemBus(dbus.WithContext(ctx))
	if err != nil {
		warn(notWatched)
		return
	}
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(login1Seat), dbus.WithMatchMember("PrepareForSleep")); err != nil ||
		conn.AddMatchSignal(dbus.WithMatchSender(dbusName), dbus.WithMatchInterface(dbusName),
			dbus.WithMatchMember("NameOwnerChanged"), dbus.WithMatchArg(0, login1)) != nil {
		conn.Close()
		warn(notWatched)
		return
	}
	var session dbus.ObjectPath
	call := conn.Object(login1, login1Path).CallWithContext(ctx, login1Seat+".GetSessionByPID", 0, uint32(os.Getpid()))
	if call.Err != nil || call.Store(&session) != nil ||
		conn.AddMatchSignal(dbus.WithMatchObjectPath(session), dbus.WithMatchInterface(login1Sess), dbus.WithMatchMember(sessionLock)) != nil ||
		conn.AddMatchSignal(dbus.WithMatchObjectPath(session), dbus.WithMatchInterface(dbusProps), dbus.WithMatchMember("PropertiesChanged")) != nil {
		session = ""
		warn(sessionUnheard)
	}
	signals := make(chan *dbus.Signal, 16)
	conn.Signal(signals)
	go func() {
		defer conn.Close()
		watchSignals(ctx, signals, session, lock, warn)
	}()
}

// watchSignals locks on each of signals that locks this session (or any
// session's sleep), until ctx ends. A channel that closes, or a nil
// signal, while ctx runs is the bus lost, and logind's name losing its
// owner is logind gone: either locks and warns.
func watchSignals(ctx context.Context, signals <-chan *dbus.Signal, session dbus.ObjectPath, lock func(string), warn func(string)) {
	for {
		select {
		case <-ctx.Done():
			return
		case sig, ok := <-signals:
			if !ok || sig == nil {
				if ctx.Err() == nil {
					warn(notWatched)
					lock(watchLost)
				}
				return
			}
			if logindGone(sig) {
				warn(notWatched)
				lock(logindLost)
				return
			}
			if why := lockSignal(sig, session); why != "" {
				lock(why)
			}
		}
	}
}

// logindGone is whether sig says logind's name lost its owner.
func logindGone(sig *dbus.Signal) bool {
	return sig.Name == dbusName+".NameOwnerChanged" && len(sig.Body) == 3 &&
		sig.Body[0] == login1 && sig.Body[2] == ""
}

// lockSignal is why sig locks the device, or "".
func lockSignal(sig *dbus.Signal, session dbus.ObjectPath) string {
	switch {
	case sig.Name == login1Seat+".PrepareForSleep" && len(sig.Body) == 1 && sig.Body[0] == true:
		return "Locked as the computer went to sleep."
	case session == "" || sig.Path != session:
		return ""
	case sig.Name == login1Sess+"."+sessionLock:
		return "Locked with this computer."
	case sig.Name == dbusProps+".PropertiesChanged" && len(sig.Body) >= 2:
		if changed, ok := sig.Body[1].(map[string]dbus.Variant); ok {
			if v, ok := changed[lockedHint]; ok && v.Value() == true {
				return "Locked with this computer."
			}
		}
	}
	return ""
}
