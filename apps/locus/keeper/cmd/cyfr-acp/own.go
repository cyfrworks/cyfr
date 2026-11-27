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

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// The program's own tool calls, as its tool_call updates show them. A call
// is CYFR's only by the driver's own record: the arguments of a call that
// reached its socket while the update was open, or before the update was
// first seen, equal to an argument object the update shows
// (profile.callArguments), and no other open update's; where the program
// names a call's server, only a call of the server named as CYFR's own was
// named in this session, which no server of the person's has (relay.go).
// Nothing else the program names or titles makes a call CYFR's, so a
// person's server named as CYFR's is shown as theirs. Since the socket call comes after the update
// opens, only a call of a kind the program gives a stub server's call
// (profile.stubKinds) can be CYFR's, and only its end says whether it was:
// such a call is shown, start and end, once it ends unmatched, and one
// still open when the native turn ends is shown then. A call of any other
// kind is the program's own, shown from the update that has it run
// (in_progress), by when its input shows what it runs, until its end, or
// else at its end, start and end together. A call that cannot be told
// apart from another is shown as the program's own, so none of a person's
// is ever hidden. Where the program names no server, a
// tool of the person's that shows the same arguments just before a call of
// CYFR's can be shown in that call's place: that is the activity shown
// alone, since the gated call goes through the socket whatever is shown.
//
// Nothing of this grows through a turn: a call is dropped when it ends, a
// call of CYFR's keeps nothing but its id once matched, until its end, and
// the turn's end drops the rest. A call still open when the turn ends, the
// session closes or the program dies is shown as the program's own first,
// so nothing that ran is missing from the activity.

// ownCall is one of the program's tool calls, by its call id, the `call`
// its start and end carry. Its detail is the input it last showed, what it
// runs, and at its end the change it shows, what it did.
type ownCall struct {
	id        string
	name      string
	seen      int
	input     json.RawMessage
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

// ownUpdate reads one tool_call update. A call of the program's own is
// shown from the first update that has it run (in_progress), by when its
// input shows what it runs, or else at its end, start and end together.
func (d *driver) ownUpdate(callID, status, kind, name string, rawInput, content json.RawMessage) error {
	if callID == "" {
		return nil
	}
	call, seen := d.own[callID]
	if !seen {
		call = &ownCall{id: callID, name: d.ownName(kind, name, rawInput), seen: len(d.own), waits: kind == "" || d.p.stubKinds[kind]}
		d.own[callID] = call
	} else if call.waits && !call.cyfr && len(rawInput) > 0 {
		// A call first announced with less than its input (Cursor's, empty)
		// is read again from each update that shows more.
		if server, tool, ok := d.p.mcpCall(rawInput); ok && mcpPart.MatchString(server) && mcpPart.MatchString(tool) {
			call.name = "mcp:" + server + "/" + tool
		}
	}
	// A call that names its server, and names one other than the name CYFR
	// gave its own, is the program's own whatever its arguments: it is
	// shown from now.
	if server, _, ok := d.p.mcpCall(rawInput); ok && call.waits && !call.cyfr && server != d.server {
		call.waits, call.arguments = false, nil
	}
	if brainwire.InputDetail(rawInput) != "" {
		call.input = rawInput
	}
	if !call.waits && !call.started && status == "in_progress" {
		if err := d.startOwn(call); err != nil {
			return err
		}
	}
	d.learn(call, rawInput)
	if status != "completed" && status != "failed" {
		return nil
	}
	delete(d.own, callID)
	return d.showOwn(call, changes(content))
}

// changes are the file changes a tool call's content shows, its diffs.
func changes(content json.RawMessage) []brainwire.Change {
	var blocks []struct {
		Type    string `json:"type"`
		Path    string `json:"path"`
		OldText string `json:"oldText"`
		NewText string `json:"newText"`
	}
	_ = json.Unmarshal(content, &blocks)
	var out []brainwire.Change
	for _, b := range blocks {
		if b.Type == "diff" {
			out = append(out, brainwire.Change{Path: b.Path, Old: b.OldText, New: b.NewText})
		}
	}
	return out
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

// startOwn shows a call's start, with what its input shows it runs.
func (d *driver) startOwn(call *ownCall) error {
	call.started = true
	return d.c.Emit(d.event("own").Set("call", brainwire.CallID(call.id)).Set("name", call.name).Set("phase", "start").
		SetOptional("detail", brainwire.InputDetail(call.input)))
}

// showOwn shows a call's end, and its start first if it was not shown, the
// end with the changes it made.
func (d *driver) showOwn(call *ownCall, made []brainwire.Change) error {
	if call.cyfr {
		return nil
	}
	if !call.started {
		if err := d.startOwn(call); err != nil {
			return err
		}
	}
	detail := ""
	if len(made) > 0 {
		detail = brainwire.ChangeDetail(made)
	}
	return d.c.Emit(d.event("own").Set("call", brainwire.CallID(call.id)).Set("name", call.name).Set("phase", "end").
		SetOptional("detail", detail))
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
		if err := d.showOwn(call, nil); err != nil {
			return err
		}
	}
	return nil
}
