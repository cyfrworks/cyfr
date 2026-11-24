// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Package scrolls is where a brain driver puts the athanor's scrolls for
// its program to find among the program's own skills: a folder of the
// driver's own, <home>/.cyfr/scrolls/<boot>/, which it holds by an
// exclusive lock on <home>/.cyfr/scrolls/<boot>.lock for its life and
// removes at its end. The lock is the kernel's (flock), close-on-exec so
// the program the driver starts never holds it, and names no pid or age: a
// killed driver's lock goes with it, and a start's sweep removes another
// boot's folder only when it can take that folder's lock, so a live
// driver's stays.
//
// The folder is one layout for every program: a Claude Code plugin named
// `cyfr` (`.claude-plugin/plugin.json`) whose `skills/` is also the root
// Codex is given, each scroll at `skills/<name>/SKILL.md`. It is written
// whole for each start: the first scroll a start is handed empties it.
// Everything is reached through internal/homepath, so no link is followed
// and nothing not the person's own is written or removed; only names of a
// boot's shape are ever swept.
package scrolls

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/cyfr/locus/keeper/internal/homepath"
	"golang.org/x/sys/unix"
)

// Place is the folder every boot's folder sits in, under the home.
const Place = ".cyfr/scrolls"

// PluginName is the name the folder's plugin manifest gives it, which
// Claude Code lists its skills under (`cyfr:<name>`).
const PluginName = "cyfr"

const lockSuffix = ".lock"

// bootName is a boot's shape (brainwire.RandomHex(16)): only a name of it
// is ever swept, so nothing else in the place is touched.
var bootName = regexp.MustCompile(`^[0-9a-f]{32}$`)

// scrollName is a scroll's name as CYFR stores one
// (`Compendium.AquaPath`'s grammar).
var scrollName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

// ErrName is a scroll's name of another grammar.
var ErrName = errors.New("is not a scroll's name")

// Folder is one boot's folder, held.
type Folder struct {
	boot  string
	place *homepath.Dir
	lock  *os.File
	// begun says a scroll of the coming start was written, so the folder
	// already holds that start's set alone; names are the scrolls placed.
	begun bool
	names []string
}

// Open takes the boot's folder under `home`: the lock first, then a sweep
// of every other boot's folder whose lock it can take.
func Open(home, boot string) (*Folder, error) {
	if !bootName.MatchString(boot) {
		return nil, fmt.Errorf("%q is not a boot", boot)
	}
	place, err := homepath.Walk(home, Place, true)
	if err != nil {
		return nil, err
	}
	lock, err := hold(place, boot+lockSuffix)
	if err != nil {
		place.Close()
		return nil, err
	}
	f := &Folder{boot: boot, place: place, lock: lock}
	f.sweep()
	return f, nil
}

// hold opens `name` and takes its lock, then checks that the name still
// names the file locked: a sweep that took the lock between the open and
// the lock has removed it, and the lock is taken again on a new file.
func hold(place *homepath.Dir, name string) (*os.File, error) {
	for {
		lock, err := place.Open(name, os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			return nil, err
		}
		if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
			lock.Close()
			return nil, fmt.Errorf("the lock %s is held: %w", lock.Name(), err)
		}
		if same(place, name, lock) {
			return lock, nil
		}
		lock.Close()
	}
}

func same(place *homepath.Dir, name string, f *os.File) bool {
	var held, named unix.Stat_t
	if unix.Fstat(int(f.Fd()), &held) != nil {
		return false
	}
	if unix.Fstatat(int(place.Fd()), name, &named, unix.AT_SYMLINK_NOFOLLOW) != nil {
		return false
	}
	return held.Dev == named.Dev && held.Ino == named.Ino
}

// sweep removes each other boot's folder, and its lock, whose lock it can
// take: a driver that ended without removing its own. A lock is taken, or
// made and taken, for each boot a name of the place shows, its folder's or
// its lock's, so a folder whose lock is held is a live driver's and stays.
// What cannot be removed stays for a later sweep.
func (f *Folder) sweep() {
	names, err := f.place.Names()
	if err != nil {
		return
	}
	boots := map[string]bool{}
	for _, name := range names {
		boot, _ := strings.CutSuffix(name, lockSuffix)
		if boot != f.boot && bootName.MatchString(boot) {
			boots[boot] = true
		}
	}
	for boot := range boots {
		lock, err := f.place.Open(boot+lockSuffix, os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			continue
		}
		if unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB) == nil && same(f.place, boot+lockSuffix, lock) {
			if f.place.RemoveAll(boot) == nil {
				_ = f.place.Remove(boot + lockSuffix)
			}
		}
		lock.Close()
	}
}

// Path is the folder's absolute path: Claude Code's plugin folder.
func (f *Folder) Path() string { return filepath.Join(f.place.Path(), f.boot) }

// Root is the folder that holds a skill a folder: Codex's extra root.
func (f *Folder) Root() string { return filepath.Join(f.Path(), "skills") }

// Put writes one scroll as `skills/<name>/SKILL.md`, its frontmatter the
// scroll's own name and description and its body as handed. The first of
// a start empties the folder first, so it holds that start's set alone.
func (f *Folder) Put(name, description, body string) error {
	if !scrollName.MatchString(name) {
		return fmt.Errorf("%q %w", name, ErrName)
	}
	if !f.begun {
		if err := f.empty(); err != nil {
			return err
		}
		f.begun = true
	}
	skills, err := f.skills()
	if err != nil {
		return err
	}
	defer skills.Close()
	if err := skills.RemoveAll(name); err != nil {
		return err
	}
	dir, err := skills.Folder(name, true)
	if err != nil {
		return err
	}
	defer dir.Close()
	if err := write(dir, "SKILL.md", manifest(name, description, body)); err != nil {
		return err
	}
	f.names = append(f.names, name)
	return nil
}

// Start ends the set the coming start is handed and answers the names
// placed: none when it was handed none, the folder then emptied. The next
// start's first scroll empties it again.
func (f *Folder) Start() ([]string, error) {
	names := f.names
	f.names = nil
	if !f.begun {
		if err := f.place.RemoveAll(f.boot); err != nil {
			return nil, err
		}
		return nil, nil
	}
	f.begun = false
	return names, nil
}

// skills opens the folder's skills/ from the place, step by step.
func (f *Folder) skills() (*homepath.Dir, error) {
	dir, err := f.place.Folder(f.boot, false)
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	return dir.Folder("skills", false)
}

// Close removes the folder, then its lock, and lets the lock go.
func (f *Folder) Close() error {
	err := f.place.RemoveAll(f.boot)
	if err == nil {
		err = f.place.Remove(f.boot + lockSuffix)
	}
	f.lock.Close()
	f.place.Close()
	return err
}

// empty makes the folder anew: the plugin's manifest and an empty skills/.
func (f *Folder) empty() error {
	if err := f.place.RemoveAll(f.boot); err != nil {
		return err
	}
	dir, err := f.place.Folder(f.boot, true)
	if err != nil {
		return err
	}
	defer dir.Close()
	plugin, err := dir.Folder(".claude-plugin", true)
	if err != nil {
		return err
	}
	defer plugin.Close()
	pluginJSON, _ := json.Marshal(map[string]string{
		"name":        PluginName,
		"version":     "0.0.0",
		"description": "The athanor's scrolls, placed by CYFR for this start.",
	})
	if err := write(plugin, "plugin.json", pluginJSON); err != nil {
		return err
	}
	skills, err := dir.Folder("skills", true)
	if err != nil {
		return err
	}
	return skills.Close()
}

// manifest is a SKILL.md: the name and description as YAML's
// double-quoted scalars (JSON's strings are), then the body.
func manifest(name, description, body string) []byte {
	n, _ := json.Marshal(name)
	d, _ := json.Marshal(description)
	return []byte(fmt.Sprintf("---\nname: %s\ndescription: %s\n---\n\n%s\n", n, d, strings.TrimRight(body, "\n")))
}

// write writes `name` in dir whole through a new file renamed over it.
func write(dir *homepath.Dir, name string, data []byte) error {
	tmp, tmpName, err := dir.CreateTemp("." + name + ".")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = dir.Rename(tmpName, name)
	}
	if werr != nil {
		_ = dir.Remove(tmpName)
	}
	return werr
}
