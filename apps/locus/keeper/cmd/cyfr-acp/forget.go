// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A session's files are those its profile names, each by the session's
// id, and the driver's own record of its instructions (instructions.go).
// ACP's session/delete is not what a forget rests on: a program that
// offers none (Antigravity 1.5.16) leaves the driver to remove the files,
// and one that does still leaves the files' absence to be proved.

// rooted is a file of a session's, under the folder it is looked for from.
type rooted struct{ root, path string }

// sessionFiles are every file of the session the forget removes.
func (d *driver) sessionFiles(session string) []rooted {
	var files []rooted
	root := d.p.sessionRoot(d.home)
	for _, name := range d.p.sessionFiles(d.home, session) {
		files = append(files, rooted{root, name})
	}
	return append(files, rooted{driverFolder(d.home), instructionsFile(d.home, session)})
}

var (
	errLinked = errors.New("a folder on the way to the session's files, or one of them, is a link or no folder, which CYFR does not follow, so nothing was removed")
	errUnread = errors.New("the folder could not be read to find the session's files, so they may still be there")
)

// present says whether the file is there, each step from its root down
// looked at itself (Lstat): the root and every folder on the way must be a
// folder, and the file no link, so nothing is reached through a link. A
// step that is absent makes the file absent.
func present(f rooted) (bool, error) {
	rel, err := filepath.Rel(f.root, f.path)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return false, errLinked
	}
	steps := strings.Split(rel, string(filepath.Separator))
	at := f.root
	for i := -1; i < len(steps); i++ {
		if i >= 0 {
			at = filepath.Join(at, steps[i])
		}
		info, err := os.Lstat(at)
		switch {
		case brainwire.Absent(err):
			return false, nil
		case err != nil:
			return false, errUnread
		case i < len(steps)-1 && !info.IsDir():
			return false, errLinked
		case i == len(steps)-1 && info.Mode()&os.ModeSymlink != 0:
			return false, errLinked
		}
	}
	return true, nil
}

// removeSession removes each of the session's files, once every one was
// looked at and none is reached through a link, and looks at each again:
// it answers why one may remain, or nil once every one is absent. The
// words are the driver's own, since a refusal carries them to the wire.
func (d *driver) removeSession(session string) error {
	files := d.sessionFiles(session)
	var there []rooted
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
		if err := os.RemoveAll(f.path); err != nil {
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
