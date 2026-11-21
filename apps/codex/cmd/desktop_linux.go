// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package cmd

import (
	"context"
	"fmt"
	"os"

	"github.com/godbus/dbus/v5"
)

const (
	login1      = "org.freedesktop.login1"
	login1Path  = dbus.ObjectPath("/org/freedesktop/login1")
	login1Seat  = "org.freedesktop.login1.Manager"
	login1Sess  = "org.freedesktop.login1.Session"
	dbusProps   = "org.freedesktop.DBus.Properties"
	lockedHint  = "LockedHint"
	sessionLock = "Lock"
)

// watchSessionLock calls lock whenever this login session locks (logind's
// Lock signal, or its LockedHint turning true) or the computer is about
// to sleep (PrepareForSleep), until ctx ends. Sleep is watched on the
// system bus whatever the session; a process outside any login session
// watches sleep alone, and says so.
func watchSessionLock(ctx context.Context, lock func(why string)) error {
	conn, err := dbus.ConnectSystemBus(dbus.WithContext(ctx))
	if err != nil {
		return fmt.Errorf("the system bus cannot be reached (%v)", err)
	}
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(login1Seat), dbus.WithMatchMember("PrepareForSleep")); err != nil {
		conn.Close()
		return err
	}
	var session dbus.ObjectPath
	call := conn.Object(login1, login1Path).CallWithContext(ctx, login1Seat+".GetSessionByPID", 0, uint32(os.Getpid()))
	if call.Err == nil && call.Store(&session) == nil {
		_ = conn.AddMatchSignal(dbus.WithMatchObjectPath(session), dbus.WithMatchInterface(login1Sess), dbus.WithMatchMember(sessionLock))
		_ = conn.AddMatchSignal(dbus.WithMatchObjectPath(session), dbus.WithMatchInterface(dbusProps), dbus.WithMatchMember("PropertiesChanged"))
	} else {
		fmt.Fprintln(os.Stderr, "cyfr: this process is in no login session: only sleep locks CYFR here, not the session's lock")
	}
	signals := make(chan *dbus.Signal, 16)
	conn.Signal(signals)
	go func() {
		defer conn.Close()
		for {
			select {
			case <-ctx.Done():
				return
			case sig := <-signals:
				if why := lockSignal(sig, session); why != "" {
					lock(why)
				}
			}
		}
	}()
	return nil
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
