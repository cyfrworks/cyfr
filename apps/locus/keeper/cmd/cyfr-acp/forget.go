// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"errors"
	"os"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/homepath"
)

// A session's files are those its profile names, each by the session's
// id, and the driver's own record of its instructions (instructions.go).
// Where the program keeps its sessions in files of their own (Antigravity
// 1.5.16, which offers no session/delete), the forget removes them and
// proves them absent. Where it keeps them in a store of its own that holds
// more than them, its sign-in among it (OpenCode), the forget is the
// program's own session/delete, in a process of the driver's own, proved
// by the program's load answering it does not have the session: only then
// is it forgotten, and a delete the program refuses or does not answer is
// a forget that failed. Where its sessions are its files and its load can
// witness one absent too (Cursor), the files are removed and proved
// absent, and the program's load, in a process of the driver's own, must
// answer that it lacks the session or that it is signed out, which leaves
// the proof standing; a load that finds the session, or fails another way,
// is a forget that failed. Its record of instructions is removed either
// way, and a profile that keeps its server's name removes that record once
// the session is gone.

// sessionFiles are every file of the session the forget removes, each a
// way down internal/homepath walks following no link: the profile's, and
// the driver's record of the instructions handed. The record of a profile
// that keeps its server's name is the profile's own, removed after the
// session (removeSession).
func (d *driver) sessionFiles(session string) ([]homepath.Path, error) {
	files, err := d.p.sessionFiles(d.home, session)
	if err != nil {
		return nil, err
	}
	return append(files, instructionsPath(d.home, session)), nil
}

var (
	errLinked = errors.New("a folder on the way to the session's files, or one of them, is a link or no folder of this user's own, which CYFR does not follow, so nothing was removed")
	errUnread = errors.New("the folder could not be read to find the session's files, so they may still be there")
)

// present says whether the file is there, in the driver's words.
func present(f homepath.Path) (bool, error) {
	ok, err := homepath.Present(f)
	switch {
	case homepath.Refused(err):
		return false, errLinked
	case err != nil:
		return false, errUnread
	}
	return ok, nil
}

// removeSession removes the session: through the program where it deletes
// its own, then its files. It answers why some of it may remain, or nil.
// The words are the driver's own, since a refusal carries them to the
// wire.
func (d *driver) removeSession(session string) error {
	if d.p.deletes {
		o, err := d.openOneOff()
		if err != nil {
			return errors.New(d.p.title + " did not start to delete the session: " + err.Error())
		}
		err = d.deleteIn(o, session)
		o.close()
		if err != nil {
			return err
		}
	}
	if err := d.removeFiles(session); err != nil {
		return err
	}
	if d.p.forgetLoads {
		o, err := d.openOneOff()
		if err != nil {
			return errors.New(d.p.title + " did not start to show the session gone: " + err.Error())
		}
		err = d.loadsNone(o, session, true)
		o.close()
		if err != nil {
			return err
		}
	}
	if d.p.namesOnce {
		// The session is gone; its server's name is no reason to say it is
		// not, and one left is never read for another session.
		_ = homepath.Remove(serverPath(d.home, session))
	}
	return nil
}

// deleteIn asks the program o runs to delete the session, then to load it:
// only its not-found answer to the load proves the session gone.
func (d *driver) deleteIn(o *oneOff, session string) error {
	answer, err := o.call("session/delete", map[string]any{"sessionId": session})
	switch {
	case err != nil:
		return errors.New(d.p.title + " did not answer the session's deletion, so it may still be there")
	case answer.Error != nil:
		return errors.New(d.p.title + " refused to delete the session, so it is still there")
	}
	if d.loadsNone(o, session, false) != nil {
		return errors.New(d.p.title + " did not show the session gone after deleting it, so it may still be there")
	}
	return nil
}

// loadsNone asks the program o runs to load the session: its not-found
// answer shows the session gone, and, where the session's files were proved
// absent already (filesProved), so does its signed-out answer, which says
// nothing of the session; any other answer is a forget that failed.
func (d *driver) loadsNone(o *oneOff, session string, filesProved bool) error {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = d.home
	}
	answer, err := o.call("session/load", map[string]any{"sessionId": session, "cwd": cwd, "mcpServers": []any{}})
	switch {
	case err != nil || answer.Error == nil:
	case d.p.loadNotFound(answer.Error, session):
		return nil
	case filesProved && answer.Error.Code == d.p.signedOut:
		return nil
	}
	return errors.New(d.p.title + " did not show the session gone after its files were removed, so it may still be there")
}

// removeFiles removes each of the session's files, once every one was
// looked at and none is reached through a link, and looks at each again:
// it answers why one may remain, or nil once every one is absent.
func (d *driver) removeFiles(session string) error {
	files, err := d.sessionFiles(session)
	if err != nil {
		return err
	}
	var there []homepath.Path
	for _, f := range files {
		ok, err := present(f)
		if err != nil {
			return err
		}
		if ok {
			there = append(there, f)
		}
	}
	for _, f := range there {
		if err := homepath.RemoveAll(f); err != nil {
			if homepath.Refused(err) {
				return errLinked
			}
			return errors.New("the session's files could not be removed from the folder")
		}
	}
	for _, f := range files {
		ok, err := present(f)
		if err != nil {
			return err
		}
		if ok {
			return errors.New("the session's files are still in the folder after their removal")
		}
	}
	return nil
}

// forget removes the session `session` from the folder, and nothing else:
// another session, the program's own index of every session, and the
// sign-in stay. The session the program runs now is not removed: the
// program would go on writing it.
func (d *driver) forget(id, session string) error {
	if !d.p.sessionID(session) {
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
