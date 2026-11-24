// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/scrolls"
)

// The athanor's scrolls among Codex's own skills. The scrolls a start is
// handed (`scroll`, before its `start`) are written into the driver's own
// folder (internal/scrolls), whose `skills/` the start names to Codex as
// an extra root (`skills/extraRoots/set`, after `initialize`, before the
// thread starts or resumes), which lasts that process alone and writes no
// configuration (P8.2). Codex lists them by name beside its own: the
// person's, a repository's and the ones built into it, which stay as they
// are. Two skills of one name are both listed, so before it places
// anything the driver asks Codex for the skills it has (`skills/list`),
// and a scroll named like one of them, or every scroll when the listing
// does not answer, is answered `yielded` and keeps the model's harness's
// way. The listing needs the app-server, so the start's first scroll
// starts it, and the start goes on in that process.

// listing is the app-server's answer to what skills it has, asked at a
// start's first scroll: the request awaited, the names it answered, or
// that it did not answer, and the scroll waiting for it.
type listing struct {
	stage   string
	request string
	names   map[string]bool
	unread  bool
	held    *heldScroll
}

type heldScroll struct{ id, name, description, body string }

// Scroll places one scroll of the coming start, or yields it, once Codex
// has said what skills it has.
func (d *driver) Scroll(id, name, description, body string) error {
	if d.starting != nil || d.session != "" {
		return brainwire.Fail(2, brainwire.WhyBroken, "a scroll while the harness runs")
	}
	held := &heldScroll{id: id, name: name, description: description, body: body}
	if d.listing != nil && d.listing.stage == "" {
		return d.place(held)
	}
	if d.listing != nil {
		return brainwire.Fail(2, brainwire.WhyBroken, "a scroll before the last was answered")
	}
	d.listing = &listing{held: held}
	if d.h != nil {
		return d.list()
	}
	h, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), appServer))
	if err != nil {
		// Spawn has said why on the driver's standard error.
		return brainwire.Fail(1, brainwire.WhyUnrunnable, "")
	}
	d.h = h
	d.listing.stage = "initialize"
	d.listing.request = d.nextID("initialize")
	return d.h.Write(initializeLine(d.listing.request))
}

// list asks the app-server for its skills, forced to read them again.
func (d *driver) list() error {
	cwd, _ := os.Getwd()
	d.listing.stage = "list"
	d.listing.request = d.nextID("skills")
	return d.h.Write(request(d.listing.request, "skills/list", map[string]any{"cwds": []string{cwd}, "forceReload": true}))
}

// listStep is the listing's handshake, one answer at a time; an error at
// either step is a listing that did not answer.
func (d *driver) listStep(m rpc) error {
	l := d.listing
	switch {
	case l.stage == "initialize" && m.Error == nil:
		if err := d.h.Write(initializedLine()); err != nil {
			return err
		}
		return d.list()
	case l.stage == "list" && m.Error == nil:
		var r struct {
			Data []struct {
				Skills []struct {
					Name string `json:"name"`
				} `json:"skills"`
			} `json:"data"`
		}
		if json.Unmarshal(m.Result, &r) != nil {
			l.unread = true
			break
		}
		l.names = map[string]bool{}
		for _, entry := range r.Data {
			for _, skill := range entry.Skills {
				l.names[strings.ToLower(skill.Name)] = true
			}
		}
	default:
		l.unread = true
	}
	// An app-server that did not answer its `initialize` is not one a
	// start goes on in.
	if l.stage == "initialize" {
		d.h.Stop()
		d.h = nil
	}
	l.stage = ""
	held := l.held
	l.held = nil
	return d.place(held)
}

// place writes one scroll and answers it: yielded when Codex has a skill
// of its name, ignoring case, which errs toward Codex's own, or did not
// say what it has.
func (d *driver) place(s *heldScroll) error {
	if d.listing.unread || d.listing.names[strings.ToLower(s.name)] {
		return d.c.Yielded(s.id)
	}
	if d.folder == nil {
		folder, err := scrolls.Open(d.home, d.c.Boot)
		if err != nil {
			return d.c.Refuse(s.id, unplacedSentence)
		}
		d.folder = folder
	}
	if err := d.folder.Put(s.name, s.description, s.body); err != nil {
		return d.c.Refuse(s.id, unplacedSentence)
	}
	return d.c.Placed(s.id, s.name)
}

// unplacedSentence refuses a scroll the driver could not write; the
// holder names the scroll and starts nothing.
const unplacedSentence = "The scroll could not be written where OpenAI Codex reads its skills."

// placed closes the coming start's set: the root to name with
// `skills/extraRoots/set`, or none when no scroll was placed.
func (d *driver) placed() string {
	d.listing = nil
	if d.folder == nil {
		return ""
	}
	names, err := d.folder.Start()
	if err != nil || len(names) == 0 {
		return ""
	}
	return d.folder.Root()
}

// Unplace removes the driver's folder and its lock as it ends.
func (d *driver) Unplace() {
	if d.folder != nil {
		_ = d.folder.Close()
		d.folder = nil
	}
}

// extraRootsLine names the start's folder to Codex for this process.
func extraRootsLine(id, root string) []byte {
	return request(id, "skills/extraRoots/set", map[string]any{"extraRoots": []string{root}})
}
