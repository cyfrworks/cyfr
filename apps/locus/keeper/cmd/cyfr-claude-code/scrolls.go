// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/homepath"
	"github.com/cyfr/locus/keeper/internal/scrolls"
)

// The athanor's scrolls among Claude Code's own skills. The scrolls a
// start is handed (`scroll`, before its `start`) are written into the
// driver's own folder in its session's /tmp (internal/scrolls), a plugin
// named `cyfr`, which the start names with `--plugin-dir` for that process
// alone: Claude Code lists its skills as `cyfr:<name>` beside the person's
// own and its bundled ones, which stay as they are (P8.1).
//
// A person's own always wins a name. A `--plugin-dir` plugin replaces, for
// its process, a plugin of the person's of its name, so when the person
// has a plugin named `cyfr`, or the places the driver looks cannot be read,
// it places none and every scroll of that start yields. The driver looks
// at names alone, in the program's own places, walked from the home: the
// plugins its plugins record names (`<config>/plugins/installed_plugins.json`,
// the part of each key before `@`) and the plugins' folders
// (`<config>/plugins/cache/<marketplace>/<plugin>`), `<config>` being
// CLAUDE_CONFIG_DIR, inside the home, or `.claude`. An installed plugin
// counts whether it is switched on or off, so no settings file is opened,
// nor anything that may hold a sign-in or a key, nor a skill's or a
// plugin's content; what it reads goes nowhere: not the wire and not the
// log. Every step goes through internal/homepath, which follows no link.
//
// A skill of the person's can take the very name CYFR's is listed by (a
// skill or command named `cyfr:<name>`, or any under a `cyfr` commands
// folder), and Claude Code then lists the person's under it, alone or
// beside CYFR's (measured on 2.1.323). So each scroll, once written, is
// placed only as its program is seen to list it: a listing process, the
// program started as a model listing starts it with the folder named,
// answers `initialize` with the skills it lists, each with its source
// (`(cyfr)` opening the line of the plugin's, 2.1.323). A scroll listed
// once, from the folder, is placed; one listed under its name from
// anywhere else yields (own) and is taken back; one not listed at all,
// past the name the program takes, yields quietly. A listing that does
// not answer, or answers no list, yields that scroll and the rest of the
// start's (unread).

// pluginsRecordBytes bounds the plugins record the driver reads names
// from: one past it is a place it cannot read.
const pluginsRecordBytes = 4 << 20

// skillsWait bounds one listing process's answer.
var skillsWait = 30 * time.Second

// placing is the set of scrolls a coming start is handed: begun with its
// first scroll, and why every scroll of it yields when one does.
type placing struct {
	begun bool
	// yield is why every scroll yields: brainwire.YieldOwn or
	// brainwire.YieldUnread, or empty while each is placed or not on its
	// own.
	yield string
}

// Scroll places one scroll of the coming start, or yields it.
func (d *driver) Scroll(id, name, description, body string) error {
	if d.h != nil && d.h.Expected {
		d.Close()
	}
	if d.h != nil {
		return brainwire.Fail(2, brainwire.WhyBroken, "a scroll while the harness runs")
	}
	if !d.placing.begun {
		theirs, err := ownPlugin(d.home, scrolls.PluginName)
		d.placing = placing{begun: true}
		switch {
		case err != nil:
			d.placing.yield = brainwire.YieldUnread
		case theirs:
			d.placing.yield = brainwire.YieldOwn
		}
	}
	if d.placing.yield != "" {
		return d.c.Yielded(id, d.placing.yield)
	}
	listedAs := scrolls.PluginName + ":" + name
	// A name past what the wire carries is not one CYFR can say it placed.
	if !brainwire.IsID(listedAs) {
		return d.c.Yielded(id, "")
	}
	if d.folder == nil {
		folder, err := scrolls.Open()
		if err != nil {
			return d.c.Refuse(id, unplacedSentence)
		}
		d.folder = folder
	}
	if err := d.folder.Put(name, description, body); err != nil {
		return d.c.Refuse(id, unplacedSentence)
	}
	rows, err := d.listedSkills()
	if err != nil {
		d.placing.yield = brainwire.YieldUnread
	}
	why := d.placing.yield
	if why == "" {
		why = seen(rows, listedAs, description)
	}
	if why == "placed" {
		return d.c.Placed(id, listedAs)
	}
	if err := d.folder.TakeBack(name); err != nil {
		return d.c.Refuse(id, unplacedSentence)
	}
	return d.c.Yielded(id, why)
}

// listedSkill is one row of a listing's `initialize` answer.
type listedSkill struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// seen says how the listing shows the scroll listed as `as`: "placed" for
// one row of that name, the folder's (its line opening `(cyfr)`); own for
// any row of the name from elsewhere; quietly not placed ("") for none.
func seen(rows []listedSkill, as, description string) string {
	var named []listedSkill
	for _, row := range rows {
		if strings.EqualFold(row.Name, as) {
			named = append(named, row)
		}
	}
	switch {
	case len(named) == 0:
		return ""
	case len(named) == 1 && named[0].Name == as && fromFolder(named[0].Description, description):
		return "placed"
	}
	return brainwire.YieldOwn
}

// fromFolder is a listed line that is the folder's scroll's: the plugin's
// source, then its description.
func fromFolder(line, description string) bool {
	if description == "" {
		return line == "("+scrolls.PluginName+")" || line == "("+scrolls.PluginName+") "
	}
	return line == "("+scrolls.PluginName+") "+description
}

// listedSkills starts the harness, as a model listing does, with the
// folder named, only to ask its `initialize` answer for the skills it
// lists, and closes it.
func (d *driver) listedSkills() ([]listedSkill, error) {
	argv := append(append(append([]string{}, d.harnessCommand...), baseArgv...), "--plugin-dir", d.folder.Path())
	h, err := d.c.Spawn(argv)
	if err != nil {
		return nil, err
	}
	defer h.Stop()
	if err := h.Write(initializeLine("")); err != nil {
		return nil, errors.New("it ended before it was asked")
	}
	deadline := time.After(skillsWait)
	for {
		select {
		case line := <-h.Lines:
			var l harnessLine
			if json.Unmarshal(line, &l) != nil || l.Type != "control_response" {
				continue
			}
			answer, ok := controlAnswer(l.Response)
			if !ok || answer.RequestID != initID {
				continue
			}
			var response struct {
				Commands *[]listedSkill `json:"commands"`
			}
			if answer.Subtype != "success" || json.Unmarshal(answer.Response, &response) != nil || response.Commands == nil {
				return nil, errors.New("it listed no skills")
			}
			return *response.Commands, nil
		case <-h.Done:
			return nil, errors.New("it ended before it answered")
		case <-deadline:
			return nil, errors.New("it did not answer in time")
		}
	}
}

// unplacedSentence refuses a scroll the driver could not write; the
// holder names the scroll and starts nothing.
const unplacedSentence = "The scroll could not be written where Claude Code reads its skills."

// placed closes the coming start's set: the plugin folder to name with
// `--plugin-dir`, or none when no scroll was placed.
func (d *driver) placed() string {
	d.placing = placing{}
	if d.folder == nil {
		return ""
	}
	names, err := d.folder.Start()
	if err != nil || len(names) == 0 {
		return ""
	}
	return d.folder.Path()
}

// Unplace removes the driver's folder as it ends.
func (d *driver) Unplace() {
	if d.folder != nil {
		_ = d.folder.Close()
		d.folder = nil
	}
}

// errConfigFolder is Claude Code's configuration folder outside the home,
// which the driver does not walk.
var errConfigFolder = errors.New("Claude Code's configuration folder is not inside the home")

// configPath is the way to Claude Code's configuration folder's `rel`,
// from the home: CLAUDE_CONFIG_DIR when it is set, else the home's
// `.claude`, as Claude Code finds it. One not inside the home is refused.
func configPath(home, rel string) (homepath.Path, error) {
	folder := filepath.Join(home, ".claude")
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); strings.TrimSpace(dir) != "" {
		folder = dir
	}
	if !filepath.IsAbs(folder) {
		folder = filepath.Join(home, folder)
	}
	inside, err := filepath.Rel(filepath.Clean(home), filepath.Clean(folder))
	if err != nil || !filepath.IsLocal(inside) && inside != "." {
		return homepath.Path{}, errConfigFolder
	}
	return homepath.Path{Root: home, Rel: filepath.Join(inside, rel)}, nil
}

// ownPlugin says whether the person's Claude Code has a plugin named
// `name` of its own, installed, by the names its places hold; an error is
// a place it could not read. A name is compared ignoring case, which errs
// toward the person's.
func ownPlugin(home, name string) (bool, error) {
	way, err := configPath(home, "plugins")
	if err != nil {
		return false, err
	}
	plugins, err := homepath.Walk(way.Root, way.Rel, false)
	if homepath.Absent(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer plugins.Close()
	recorded, err := recordedPlugins(plugins)
	if err != nil {
		return false, err
	}
	cached, err := cachedPlugins(plugins)
	if err != nil {
		return false, err
	}
	for _, plugin := range append(recorded, cached...) {
		if strings.EqualFold(plugin, name) {
			return true, nil
		}
	}
	return false, nil
}

// recordedPlugins are the plugins the record names, each key's part
// before `@`; the values are never looked at.
func recordedPlugins(plugins *homepath.Dir) ([]string, error) {
	f, err := plugins.Open("installed_plugins.json", os.O_RDONLY, 0)
	if homepath.Absent(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, pluginsRecordBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > pluginsRecordBytes {
		return nil, errors.New("the plugins record is past its bound")
	}
	var record struct {
		Plugins *map[string]json.RawMessage `json:"plugins"`
	}
	// A record that does not name its plugins is not one of none.
	if err := json.Unmarshal(raw, &record); err != nil || record.Plugins == nil || *record.Plugins == nil {
		return nil, errors.New("the plugins record does not read")
	}
	names := make([]string, 0, len(*record.Plugins))
	for key := range *record.Plugins {
		plugin, _, _ := strings.Cut(key, "@")
		names = append(names, plugin)
	}
	return names, nil
}

// cachedPlugins are the names of the plugins' folders,
// `cache/<marketplace>/<plugin>`.
func cachedPlugins(plugins *homepath.Dir) ([]string, error) {
	cache, err := plugins.Folder("cache", false)
	if homepath.Absent(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer cache.Close()
	marketplaces, err := cache.Names()
	if err != nil {
		return nil, err
	}
	var names []string
	for _, marketplace := range marketplaces {
		info, err := cache.Lstat(marketplace)
		if err != nil {
			return nil, err
		}
		// A file there holds no plugin; a link is not looked through.
		if info.Mode.IsRegular() {
			continue
		}
		dir, err := cache.Folder(marketplace, false)
		if err != nil {
			return nil, err
		}
		held, err := dir.Names()
		dir.Close()
		if err != nil {
			return nil, err
		}
		names = append(names, held...)
	}
	return names, nil
}
