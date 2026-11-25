// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/scrolls"
)

// The athanor's scrolls among Codex's own skills. The scrolls a start is
// handed (`scroll`, before its `start`) are written into the driver's own
// folder in its session's /tmp (internal/scrolls), whose `skills/` is
// named to Codex as an extra root (`skills/extraRoots/set`), which lasts
// that process alone and writes no configuration (P8.2). Codex lists them
// by name beside its own: the person's, a repository's and the ones built
// into it, which stay as they are.
//
// A person's own always wins a name, so before it places anything the
// driver asks Codex for the skills it has (`skills/list`), and a scroll
// named like one of them yields (own). Each scroll written is placed only
// as Codex is seen to list it: the driver asks again, and a scroll Codex
// does not list from the folder, one past the 64 characters its names
// take among them, is taken back and yields quietly. Not knowing is not
// none: a listing with no list, one that carries errors, or one not
// answered within its bound yields that scroll and the rest of the
// start's (unread), and the start goes on. The listing needs the
// app-server, so the start's first scroll starts it, and the start goes
// on in that process.

// maxSkillName is the longest name Codex 0.169.0 lists a skill by.
const maxSkillName = 64

// skillsWait bounds each of the listing's answers.
var skillsWait = 30 * time.Second

// listing is what the app-server says of its skills for the coming start:
// the step awaited and its request, when its answer is overdue, the names
// it has of its own, whether it said nothing usable, whether the folder is
// its extra root yet, and the scroll waiting on it.
type listing struct {
	stage   string
	request string
	due     time.Time
	names   map[string]bool
	unread  bool
	rooted  bool
	held    *heldScroll
}

type heldScroll struct{ id, name, description, body string }

// Scroll places one scroll of the coming start, or yields it.
func (d *driver) Scroll(id, name, description, body string) error {
	if d.starting != nil || d.session != "" {
		return brainwire.Fail(2, brainwire.WhyBroken, "a scroll while the harness runs")
	}
	held := &heldScroll{id: id, name: name, description: description, body: body}
	if d.listing != nil && d.listing.stage != "" {
		return brainwire.Fail(2, brainwire.WhyBroken, "a scroll before the last was answered")
	}
	if d.listing != nil {
		return d.place(held)
	}
	d.listing = &listing{held: held}
	if d.h != nil {
		return d.ask("list")
	}
	h, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), appServer))
	if err != nil {
		// Spawn has said why on the driver's standard error.
		return brainwire.Fail(1, brainwire.WhyUnrunnable, "")
	}
	d.h = h
	return d.ask("initialize")
}

// ask writes the listing's step `stage`, its answer due within its bound.
func (d *driver) ask(stage string) error {
	l := d.listing
	l.stage = stage
	l.due = time.Now().Add(skillsWait)
	switch stage {
	case "initialize":
		l.request = d.nextID("initialize")
		return d.h.Write(initializeLine(l.request))
	case "roots":
		l.request = d.nextID("roots")
		return d.h.Write(extraRootsLine(l.request, []string{d.folder.Root()}))
	}
	cwd, _ := os.Getwd()
	l.request = d.nextID("skills")
	return d.h.Write(request(l.request, "skills/list", map[string]any{"cwds": []string{cwd}, "forceReload": true}))
}

// listed is a skill as `skills/list` answers it.
type listedSkill struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// skillsOf reads a `skills/list` answer: its skills, or false for one with
// no list or one that carries errors.
func skillsOf(m rpc) ([]listedSkill, bool) {
	if m.Error != nil {
		return nil, false
	}
	var r struct {
		Data *[]struct {
			Errors []json.RawMessage `json:"errors"`
			Skills *[]listedSkill    `json:"skills"`
		} `json:"data"`
	}
	if json.Unmarshal(m.Result, &r) != nil || r.Data == nil {
		return nil, false
	}
	var skills []listedSkill
	for _, entry := range *r.Data {
		if len(entry.Errors) > 0 || entry.Skills == nil {
			return nil, false
		}
		skills = append(skills, *entry.Skills...)
	}
	return skills, true
}

// listStep is the listing's handshake, one answer at a time: `initialize`
// and the skills Codex has, then for each scroll written its root once and
// the skills again.
func (d *driver) listStep(m rpc) error {
	l := d.listing
	stage := l.stage
	l.stage = ""
	switch stage {
	case "initialize":
		if m.Error != nil {
			// An app-server that did not answer its `initialize` is not one
			// a start goes on in.
			d.dropListing()
			return d.answerHeld()
		}
		if err := d.h.Write(initializedLine()); err != nil {
			return err
		}
		return d.ask("list")
	case "list":
		skills, ok := skillsOf(m)
		if !ok {
			l.unread = true
			return d.answerHeld()
		}
		l.names = map[string]bool{}
		for _, skill := range skills {
			l.names[strings.ToLower(skill.Name)] = true
		}
		return d.answerHeld()
	case "roots":
		if m.Error != nil {
			l.unread = true
			return d.verified(l.held, nil, false)
		}
		l.rooted = true
		return d.ask("verify")
	case "verify":
		skills, ok := skillsOf(m)
		return d.verified(l.held, skills, ok)
	}
	return nil
}

// answerHeld places or yields the scroll that waited on the listing.
func (d *driver) answerHeld() error {
	held := d.listing.held
	d.listing.held = nil
	return d.place(held)
}

// dropListing ends an app-server the listing cannot go on in; the start
// starts its own.
func (d *driver) dropListing() {
	if d.h != nil {
		d.h.Stop()
		d.h = nil
	}
	d.listing.unread = true
	d.listing.stage = ""
	d.listing.rooted = false
}

// place writes one scroll and asks Codex whether it lists it, or yields
// it: one Codex has a skill of its own by its name, ignoring case, which
// errs toward Codex's own, yields (own); one past the names Codex takes
// yields quietly; every one does when Codex did not say what it has.
func (d *driver) place(s *heldScroll) error {
	l := d.listing
	switch {
	case l.unread:
		return d.c.Yielded(s.id, brainwire.YieldUnread)
	case l.names[strings.ToLower(s.name)]:
		return d.c.Yielded(s.id, brainwire.YieldOwn)
	case len(s.name) > maxSkillName:
		return d.c.Yielded(s.id, "")
	}
	if d.folder == nil {
		folder, err := scrolls.Open()
		if err != nil {
			return d.c.Refuse(s.id, unplacedSentence)
		}
		d.folder = folder
	}
	if err := d.folder.Put(s.name, s.description, s.body); err != nil {
		return d.c.Refuse(s.id, unplacedSentence)
	}
	l.held = s
	if !l.rooted {
		return d.ask("roots")
	}
	return d.ask("verify")
}

// verified answers the scroll written last as Codex lists it now: placed
// when it lists the scroll by its name from the folder; else taken back,
// yielded quietly when Codex lists none of its name and (own) when one
// from elsewhere; every one unread when Codex did not say.
func (d *driver) verified(s *heldScroll, skills []listedSkill, ok bool) error {
	d.listing.held = nil
	if !ok {
		d.listing.unread = true
	}
	why := brainwire.YieldUnread
	if ok {
		why = ""
		for _, skill := range skills {
			if !strings.EqualFold(skill.Name, s.name) {
				continue
			}
			if skill.Name == s.name && filepath.Dir(filepath.Dir(skill.Path)) == d.folder.Root() {
				return d.c.Placed(s.id, s.name)
			}
			why = brainwire.YieldOwn
		}
	}
	if err := d.folder.TakeBack(s.name); err != nil {
		return d.c.Refuse(s.id, unplacedSentence)
	}
	return d.c.Yielded(s.id, why)
}

// listingDue is when the listing's answer is overdue, zero for none.
func (d *driver) listingDue() time.Time {
	if d.listing == nil || d.listing.stage == "" {
		return time.Time{}
	}
	return d.listing.due
}

// listingExpired yields what waited on a listing Codex did not answer in
// time, and every scroll of the start after it; the app-server is ended
// and the start starts its own.
func (d *driver) listingExpired() error {
	held := d.listing.held
	d.dropListing()
	d.listing.held = nil
	if held == nil {
		return nil
	}
	if d.folder != nil {
		_ = d.folder.TakeBack(held.name)
	}
	return d.c.Yielded(held.id, brainwire.YieldUnread)
}

// unplacedSentence refuses a scroll the driver could not write; the
// holder names the scroll and starts nothing.
const unplacedSentence = "The scroll could not be written where OpenAI Codex reads its skills."

// placed closes the coming start's set: the roots to name with
// `skills/extraRoots/set`, the folder's or none, and whether they must be
// named, since the app-server the scrolls were listed in holds the folder
// already.
func (d *driver) placed() ([]string, bool) {
	rooted := d.listing != nil && d.listing.rooted
	d.listing = nil
	if d.folder == nil {
		return nil, false
	}
	names, err := d.folder.Start()
	if err != nil || len(names) == 0 {
		return []string{}, rooted
	}
	return []string{d.folder.Root()}, true
}

// Unplace removes the driver's folder as it ends.
func (d *driver) Unplace() {
	if d.folder != nil {
		_ = d.folder.Close()
		d.folder = nil
	}
}

// extraRootsLine names the start's roots to Codex for this process.
func extraRootsLine(id string, roots []string) []byte {
	return request(id, "skills/extraRoots/set", map[string]any{"extraRoots": roots})
}
