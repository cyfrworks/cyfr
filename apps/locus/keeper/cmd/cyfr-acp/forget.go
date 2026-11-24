// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"errors"
	"os"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A session's files are those its profile names, each by the session's
// id, and the driver's own record of its instructions (instructions.go).
// ACP's session/delete is not what a forget rests on: a program that
// offers none (Antigravity 1.5.16) leaves the driver to remove the files,
// and one that does still leaves the files' absence to be proved.

// sessionFiles are every file of the session the forget removes.
func (d *driver) sessionFiles(session string) []string {
	return append(d.p.sessionFiles(d.home, session), instructionsFile(d.home, session))
}

// removeSession removes each of the session's files and inspects each
// again: it answers why one may remain, or nil once every one is absent.
// The words are the driver's own, since a refusal carries them to the wire.
func (d *driver) removeSession(session string) error {
	files := d.sessionFiles(session)
	for _, name := range files {
		if err := os.RemoveAll(name); err != nil {
			return errors.New("the session's files could not be removed from the folder")
		}
	}
	for _, name := range files {
		if _, err := os.Lstat(name); !brainwire.Absent(err) {
			if err == nil {
				return errors.New("the session's files are still in the folder after their removal")
			}
			return errors.New("the folder could not be read to find the session's files, so they may still be there")
		}
	}
	return nil
}

// forget removes the session `session` from the folder, and nothing else:
// another session, the program's own index of every session, and the
// sign-in stay. The session the program runs now is not removed: the
// program would go on writing it.
func (d *driver) forget(id, session string) error {
	if !brainwire.IsUUID(session) {
		return d.c.Refuse(id, "That names no session of "+d.p.title+"'s.")
	}
	if d.h != nil && (d.session == session || (d.starting != nil && d.starting.session == session)) {
		return d.c.Refuse(id, "That session runs now; it is closed before it is forgotten.")
	}
	if err := d.removeSession(session); err != nil {
		return d.c.Refuse(id, capital(err.Error())+".")
	}
	return d.c.Emit(brainwire.NewEvent("forgot").Set("id", id).Set("session", session))
}

func capital(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
