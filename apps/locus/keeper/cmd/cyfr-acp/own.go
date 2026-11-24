// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"reflect"
	"regexp"
	"sort"
)

// The program's own tool calls, as its tool_call updates show them. A call
// is CYFR's only by the driver's own record: the arguments of a call that
// reached its socket while the update was open, or before the update was
// first seen, equal to an argument object the update shows
// (profile.callArguments), and no other open update's. Nothing the program
// names or titles makes a call CYFR's, so a person's server named as
// CYFR's is shown as theirs. Since the socket call comes after the update
// opens, only a call of a kind the program gives a stub server's call
// (profile.stubKinds) can be CYFR's, and only its end says whether it was:
// such a call is shown, start and end, once it ends unmatched, and one
// still open when the native turn ends is shown then. A call of any other
// kind is the program's own, shown from its start while it runs. A call
// that cannot be told apart from another is shown as the program's own, so
// none of a person's is ever hidden. A tool of the person's that shows the
// same arguments just before a call of CYFR's can be shown in that call's
// place: that is the activity shown alone, since the gated call goes
// through the socket whatever is shown.
//
// Nothing of this grows through a turn: a call is dropped when it ends, a
// call of CYFR's keeps nothing but its id once matched, until its end, and
// the turn's end drops the rest. A call still open when the turn ends, the
// session closes or the program dies is shown as the program's own first,
// so nothing that ran is missing from the activity.

// ownCall is one of the program's tool calls, by its call id.
type ownCall struct {
	name      string
	seen      int
	arguments []any
	// waits is a call of a stub server's kind, shown only at its end;
	// started one shown from its start.
	waits, started bool
	cyfr           bool
}

// acpKinds are the tool kinds ACP names; any other is shown as other.
var acpKinds = map[string]bool{"read": true, "edit": true, "delete": true, "move": true, "search": true,
	"execute": true, "think": true, "fetch": true, "switch_mode": true, "other": true}

// mcpPart is a server's or a tool's name as an own call shows it.
var mcpPart = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// ownName is what is shown of a call: an MCP call's `mcp:<server>/<tool>`,
// each part a bounded name of a few characters; the program's own name of
// the tool, where the profile reads its calls' names and it is one such;
// or else its ACP kind, never a title, which may carry a folder's path.
func (d *driver) ownName(kind, name string, rawInput json.RawMessage) string {
	if server, tool, ok := d.p.mcpCall(rawInput); ok && mcpPart.MatchString(server) && mcpPart.MatchString(tool) {
		return "mcp:" + server + "/" + tool
	}
	if d.p.namesTools && mcpPart.MatchString(name) {
		return name
	}
	if acpKinds[kind] {
		return kind
	}
	return "other"
}

// decoded is a JSON value as compared: its numbers as written.
func decoded(raw json.RawMessage) (any, bool) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var v any
	if decoder.Decode(&v) != nil {
		return nil, false
	}
	return v, true
}

func (d *driver) ownUpdate(callID, status, kind, name string, rawInput json.RawMessage) error {
	if callID == "" {
		return nil
	}
	call, seen := d.own[callID]
	if !seen {
		call = &ownCall{name: d.ownName(kind, name, rawInput), seen: len(d.own), waits: kind == "" || d.p.stubKinds[kind]}
		if !call.waits {
			call.started = true
			if err := d.c.Emit(d.event("own").Set("name", call.name).Set("phase", "start")); err != nil {
				return err
			}
		}
		d.own[callID] = call
		d.learn(call, rawInput)
	} else if call.waits && !call.cyfr && len(rawInput) > 0 {
		// A call first announced with less than its input (Cursor's, empty)
		// is read again from each update that shows more.
		if server, tool, ok := d.p.mcpCall(rawInput); ok && mcpPart.MatchString(server) && mcpPart.MatchString(tool) {
			call.name = "mcp:" + server + "/" + tool
		}
		d.learn(call, rawInput)
	}
	if status != "completed" && status != "failed" {
		return nil
	}
	delete(d.own, callID)
	return d.showOwn(call)
}

// learn keeps the argument objects a waiting call's input shows, each
// once, and matches it to a socket call that came before its update
// showed them.
func (d *driver) learn(call *ownCall, rawInput json.RawMessage) {
	if d.p.callArguments == nil || !call.waits || call.cyfr {
		return
	}
	for _, raw := range d.p.callArguments(rawInput) {
		if v, ok := decoded(raw); ok && !call.shows(v) {
			call.arguments = append(call.arguments, v)
		}
	}
	for i, arguments := range d.unclaimed {
		if call.shows(arguments) {
			call.cyfr = true
			call.arguments = nil
			d.unclaimed = append(d.unclaimed[:i:i], d.unclaimed[i+1:]...)
			return
		}
	}
}

func (c *ownCall) shows(arguments any) bool {
	for _, a := range c.arguments {
		if reflect.DeepEqual(a, arguments) {
			return true
		}
	}
	return false
}

// claim matches a call on the socket to the one open update that shows
// its arguments; with none, it waits for an update first seen after it,
// and with more than one it is matched to none.
func (d *driver) claim(arguments json.RawMessage) {
	if d.p.callArguments == nil {
		// The program never shows a call of CYFR's in a form to match.
		return
	}
	v, ok := decoded(arguments)
	if !ok {
		return
	}
	var open []*ownCall
	for _, call := range d.own {
		if call.waits && !call.cyfr && call.shows(v) {
			open = append(open, call)
		}
	}
	switch len(open) {
	case 0:
		d.unclaimed = append(d.unclaimed, v)
	case 1:
		open[0].cyfr = true
		open[0].arguments = nil
	}
}

func (d *driver) showOwn(call *ownCall) error {
	if call.cyfr {
		return nil
	}
	if !call.started {
		call.started = true
		if err := d.c.Emit(d.event("own").Set("name", call.name).Set("phase", "start")); err != nil {
			return err
		}
	}
	return d.c.Emit(d.event("own").Set("name", call.name).Set("phase", "end"))
}

// flushOwn shows each own call still open, in the order they were first
// seen, and drops everything held of the turn's calls.
func (d *driver) flushOwn() error {
	defer func() {
		d.own = map[string]*ownCall{}
		d.unclaimed = nil
	}()
	open := make([]*ownCall, 0, len(d.own))
	for _, call := range d.own {
		open = append(open, call)
	}
	sort.Slice(open, func(i, j int) bool { return open[i].seen < open[j].seen })
	for _, call := range open {
		if err := d.showOwn(call); err != nil {
			return err
		}
	}
	return nil
}
