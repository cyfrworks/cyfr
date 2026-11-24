// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/homepath"
	"github.com/cyfr/locus/keeper/internal/scrolls"
)

// The athanor's scrolls among Claude Code's own skills. The scrolls a
// start is handed (`scroll`, before its `start`) are written into the
// driver's own folder (internal/scrolls), a plugin named `cyfr`, which the
// start names with `--plugin-dir` for that process alone: Claude Code
// lists its skills as `cyfr:<name>` beside the person's own and its
// bundled ones, which stay as they are (P8.1). A `--plugin-dir` plugin
// replaces, for its process, a plugin of the person's of its name, whose
// skills then leave the listing; so before it places anything the driver
// looks for one, and when the person has a plugin named `cyfr`, or the
// places it looks cannot be read, it places none and every scroll of that
// start is answered `yielded`, keeping the model's harness's way. A skill
// of the person's named like a scroll is no conflict: it is listed as
// itself beside `cyfr:<name>` (P8.6).
//
// The driver looks at names alone, in the program's own places: the
// plugins its plugins record names (`<config>/plugins/installed_plugins.json`,
// the part of each key before `@`), and the plugins' folders
// (`<config>/plugins/cache/<marketplace>/<plugin>`). An installed plugin
// counts whether it is switched on or off, so no settings file is opened,
// nor anything that may hold a sign-in or a key, nor a skill's or a
// plugin's content; what it reads goes nowhere: not the wire and not the
// log. Every step goes through internal/homepath, which follows no link.

// pluginsRecordBytes bounds the plugins record the driver reads names
// from: one past it is a place it cannot read.
const pluginsRecordBytes = 4 << 20

// placing is the set of scrolls a coming start is handed: begun with its
// first scroll, whether every scroll yields, and closed by the start.
type placing struct {
	begun bool
	yield bool
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
		d.placing = placing{begun: true, yield: theirs || err != nil}
	}
	if d.placing.yield {
		return d.c.Yielded(id)
	}
	if d.folder == nil {
		folder, err := scrolls.Open(d.home, d.c.Boot)
		if err != nil {
			return d.c.Refuse(id, unplacedSentence)
		}
		d.folder = folder
	}
	if err := d.folder.Put(name, description, body); err != nil {
		return d.c.Refuse(id, unplacedSentence)
	}
	return d.c.Placed(id, scrolls.PluginName+":"+name)
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

// Unplace removes the driver's folder and its lock as it ends.
func (d *driver) Unplace() {
	if d.folder != nil {
		_ = d.folder.Close()
		d.folder = nil
	}
}

// ownPlugin says whether the person's Claude Code has a plugin named
// `name` of its own, installed, by the names its places hold; an error is
// a place it could not read. A name is compared ignoring case, which errs
// toward the person's.
func ownPlugin(home, name string) (bool, error) {
	root, rel := home, ".claude/plugins"
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		root, rel = dir, "plugins"
	}
	plugins, err := homepath.Walk(root, rel, false)
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
		Plugins map[string]json.RawMessage `json:"plugins"`
	}
	if err := json.Unmarshal(raw, &record); err != nil {
		return nil, errors.New("the plugins record does not read")
	}
	names := make([]string, 0, len(record.Plugins))
	for key := range record.Plugins {
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
