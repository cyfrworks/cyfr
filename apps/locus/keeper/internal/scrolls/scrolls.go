// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Package scrolls is where a brain driver puts the athanor's scrolls for
// its program to find among the program's own skills: a folder of the
// driver's own in its session's own /tmp (TMPDIR), made 0700 under a name
// of its own for the driver's life and removed at its end. A session's
// /tmp is its own, seen by no other session of the same home and gone
// with the session, so one session's turn never changes another's
// scrolls, and nothing of them is left in the home.
//
// The folder is one layout for every program: a Claude Code plugin named
// `cyfr` (`.claude-plugin/plugin.json`) whose `skills/` is also the root
// Codex is given, each scroll at `skills/<name>/SKILL.md`. It holds one
// start's set alone: the first scroll a start is handed empties it.
// Inside it every step goes through internal/homepath, so no link is
// followed.
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
)

// PluginName is the name the folder's plugin manifest gives it, which
// Claude Code lists its skills under (`cyfr:<name>`).
const PluginName = "cyfr"

// scrollName is a scroll's name as CYFR stores one
// (`Compendium.AquaPath`'s grammar).
var scrollName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

// ErrName is a scroll's name of another grammar.
var ErrName = errors.New("is not a scroll's name")

// Folder is the driver's folder.
type Folder struct {
	dir *homepath.Dir
	// begun says a scroll of the coming start was written, so the folder
	// already holds that start's set alone; names are the scrolls placed.
	begun bool
	names []string
}

// Open makes the driver's folder in its session's /tmp, 0700 and named
// for it alone, holding the plugin's manifest and an empty skills/.
func Open() (*Folder, error) {
	path, err := os.MkdirTemp("", "cyfr-scrolls-")
	if err != nil {
		return nil, err
	}
	dir, err := homepath.Root(path)
	if err != nil {
		_ = os.RemoveAll(path)
		return nil, err
	}
	f := &Folder{dir: dir}
	if err := f.manifest(); err != nil {
		_ = f.Close()
		return nil, err
	}
	if err := f.empty(); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

// Path is the folder's absolute path: Claude Code's plugin folder.
func (f *Folder) Path() string { return f.dir.Path() }

// Root is the folder that holds a skill a folder: Codex's extra root.
func (f *Folder) Root() string { return filepath.Join(f.Path(), "skills") }

// Put writes one scroll as `skills/<name>/SKILL.md`, its frontmatter the
// scroll's own name and description and its body as handed. The first of
// a start empties the folder's skills first, so it holds that start's set
// alone.
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
	skills, err := f.dir.Folder("skills", false)
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
	if err := write(dir, "SKILL.md", skillFile(name, description, body)); err != nil {
		return err
	}
	f.names = append(f.names, name)
	return nil
}

// TakeBack removes the scroll `name` the coming start was written: its
// program did not list it from the folder.
func (f *Folder) TakeBack(name string) error {
	skills, err := f.dir.Folder("skills", false)
	if err != nil {
		return err
	}
	defer skills.Close()
	if err := skills.RemoveAll(name); err != nil {
		return err
	}
	kept := f.names[:0]
	for _, n := range f.names {
		if n != name {
			kept = append(kept, n)
		}
	}
	f.names = kept
	return nil
}

// Start ends the set the coming start is handed and answers the names
// placed: none when it was handed none, the skills then emptied. The next
// start's first scroll empties them again.
func (f *Folder) Start() ([]string, error) {
	names := f.names
	f.names = nil
	if !f.begun {
		return nil, f.empty()
	}
	f.begun = false
	return names, nil
}

// Close removes the folder and all it holds, following no link.
func (f *Folder) Close() error {
	path := f.dir.Path()
	f.dir.Close()
	return os.RemoveAll(path)
}

// manifest writes the plugin's manifest, which names it `cyfr`.
func (f *Folder) manifest() error {
	plugin, err := f.dir.Folder(".claude-plugin", true)
	if err != nil {
		return err
	}
	defer plugin.Close()
	pluginJSON, _ := json.Marshal(map[string]string{
		"name":        PluginName,
		"version":     "0.0.0",
		"description": "The athanor's scrolls, placed by CYFR for this start.",
	})
	return write(plugin, "plugin.json", pluginJSON)
}

// empty makes the folder's skills/ anew and empty.
func (f *Folder) empty() error {
	if err := f.dir.RemoveAll("skills"); err != nil {
		return err
	}
	skills, err := f.dir.Folder("skills", true)
	if err != nil {
		return err
	}
	return skills.Close()
}

// skillFile is a SKILL.md: the name and description as YAML's
// double-quoted scalars (JSON's strings are), then the body.
func skillFile(name, description, body string) []byte {
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
