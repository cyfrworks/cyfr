// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

const (
	driverName = "cyfr-claude-code"
	// listingWait bounds a model listing's harness.
	listingWait = 150 * time.Second
	// The stops an idle names.
	stopEndTurn = "end_turn"
	stopLimit   = "limit"
	stopError   = "error"
)

type post struct{ id, work string }

type heldAsk struct{ arguments map[string]any }

// starting is a start the harness has not answered yet.
type starting struct {
	session string
	resume  bool
	pending []string
	config  brainwire.Config
}

type driver struct {
	harnessCommand []string
	c              *brainwire.Conn
	home           string

	h        *brainwire.Process
	starting *starting
	gen      uint64
	session  string
	listing  json.RawMessage
	// What the native turns under way name: each post's line by its uuid,
	// the work of the native turn under way and its message, the
	// harness's own tools running, the asks of CYFR's tools it holds, and
	// the work each tools request was written for.
	posts    map[string]post
	turnWork string
	message  string
	errored  bool
	own      map[string]string
	asks     map[string]heldAsk
	awaiting map[string]string
	requests int
	results  int
}

func newDriver(command []string, c *brainwire.Conn, home string) brainwire.Driver {
	return &driver{
		harnessCommand: command,
		c:              c,
		home:           home,
		posts:          map[string]post{},
		own:            map[string]string{},
		asks:           map[string]heldAsk{},
		awaiting:       map[string]string{},
	}
}

// ---------------------------------------------------------------------------
// Commands

func (d *driver) Process() *brainwire.Process { return d.h }

func (d *driver) Command(t string, members map[string]json.RawMessage) error {
	str := func(name string) string { return brainwire.Str(members, name) }
	switch t {
	case "start":
		return d.start(members, str)
	case "work":
		return d.work(str("id"), members["tools"])
	case "post":
		return d.post(str("id"), str("work"), members)
	case "answer":
		var isError bool
		_ = json.Unmarshal(members["is_error"], &isError)
		return d.answer(str("id"), str("ask"), str("content"), isError)
	case "models":
		return d.models(str("id"))
	case "forget":
		return d.forget(str("id"), str("session"))
	}
	return &brainwire.Fatal{Status: 2, Reason: "a command of no kind"}
}

func (d *driver) start(members map[string]json.RawMessage, str func(string) string) error {
	// A harness that said it holds no transcript ends by itself; a start
	// after its `gone` waits for that end.
	if d.h != nil && d.h.Expected {
		d.Close()
	}
	if d.h != nil {
		return &brainwire.Fatal{Status: 2, Reason: "a start while the harness runs"}
	}
	var config brainwire.Config
	var pending []string
	var gen uint64
	_ = json.Unmarshal(members["config"], &config)
	_ = json.Unmarshal(members["gen"], &gen)
	if raw, ok := members["pending"]; ok {
		_ = json.Unmarshal(raw, &pending)
	}
	session := str("session")
	resume := session != ""
	// A session that is no session id of Claude Code's has no transcript.
	if resume && !brainwire.IsUUID(session) {
		return d.c.Emit(brainwire.NewEvent("gone"))
	}
	if !resume {
		session = brainwire.NewUUID()
	}
	h, err := brainwire.Spawn(harnessArgv(d.harnessCommand, session, resume, config), d.c.ErrOut)
	if err != nil {
		return &brainwire.Fatal{Status: 1, Reason: "the harness did not start: " + err.Error()}
	}
	d.h = h
	d.gen = gen
	d.starting = &starting{session: session, resume: resume, pending: pending, config: config}
	// A harness started to resume a session it holds no transcript of
	// says so and ends at once, perhaps before this line reached it: what
	// it wrote is read all the same, and its end decides.
	d.h.WriteUnchecked(initializeLine(str("system")))
	return nil
}

func (d *driver) running() bool { return d.h != nil && d.starting == nil && !d.h.Expected }

func (d *driver) work(id string, raw json.RawMessage) error {
	if !d.running() {
		return d.c.Refuse(id, "No harness runs: a work follows a start.")
	}
	if len(d.asks) > 0 {
		return d.c.Refuse(id, "The harness holds an ask of CYFR's: it is answered before its tools are set again.")
	}
	var tools []brainwire.Tool
	_ = json.Unmarshal(raw, &tools)
	args := make([]string, 0, len(tools))
	for _, t := range tools {
		arg, err := stubTool(t)
		if err != nil {
			return d.c.Refuse(id, fmt.Sprintf("The tool %s cannot be written for cyfr-stub.", t.Name))
		}
		if len(arg) > maxToolArgBytes {
			return d.c.Refuse(id, fmt.Sprintf("The tool %s is %d bytes as cyfr-stub's argument, past the %d one argument carries.", t.Name, len(arg), maxToolArgBytes))
		}
		args = append(args, arg)
	}
	d.requests++
	request := fmt.Sprintf("%s-%d", toolsID, d.requests)
	line := setToolsLine(request, args)
	if len(line) > brainwire.MaxLineBytes {
		return d.c.Refuse(id, fmt.Sprintf("The tools are %d bytes as one line to the harness, past the %d one line carries.", len(line), brainwire.MaxLineBytes))
	}
	d.awaiting[request] = id
	return d.h.Write(line)
}

func (d *driver) post(id, work string, members map[string]json.RawMessage) error {
	if !d.running() {
		return d.c.Refuse(id, "No harness runs: a post follows a start.")
	}
	var content, context []brainwire.Block
	_ = json.Unmarshal(members["content"], &content)
	if raw, ok := members["context"]; ok {
		_ = json.Unmarshal(raw, &context)
	}
	uuid := brainwire.PostUUID(id)
	d.posts[uuid] = post{id: id, work: work}
	blocks := append(harnessBlocks(context), harnessBlocks(content)...)
	if err := d.h.Write(userLine(blocks, uuid)); err != nil {
		return err
	}
	return d.c.Accept(id)
}

func (d *driver) answer(id, ask, content string, isError bool) error {
	held, ok := d.asks[ask]
	if !ok || !d.running() {
		return d.c.Refuse(id, "The harness holds no ask of that id.")
	}
	delete(d.asks, ask)
	if err := d.h.Write(allowLine(ask, answeredInput(held.arguments, content, isError))); err != nil {
		return err
	}
	return d.c.Accept(id)
}

// models answers the harness's model listing: from the answer its running
// session's `initialize` gave, or from a harness of its own, started and
// closed for it, when none runs.
func (d *driver) models(id string) error {
	listing := d.listing
	if d.h != nil && !d.running() {
		return d.c.Refuse(id, "The harness is starting: its models are listed once it has started.")
	}
	if d.h == nil {
		var err error
		if listing, err = d.listOnce(); err != nil {
			return d.c.Refuse(id, "Claude Code did not list its models: "+err.Error())
		}
	}
	var entries []struct {
		Value       string   `json:"value"`
		DisplayName string   `json:"displayName"`
		Efforts     []string `json:"supportedEffortLevels"`
	}
	_ = json.Unmarshal(listing, &entries)
	models := []map[string]string{}
	efforts := []string{}
	seen := map[string]bool{}
	for _, entry := range entries {
		if !brainwire.IsID(entry.Value) || len(models) >= brainwire.MaxList {
			continue
		}
		models = append(models, map[string]string{"id": entry.Value, "name": entry.DisplayName})
		for _, level := range entry.Efforts {
			if !seen[level] && len(efforts) < brainwire.MaxList {
				seen[level] = true
				efforts = append(efforts, level)
			}
		}
	}
	return d.c.Emit(brainwire.NewEvent("models").Set("id", id).Set("models", models).Set("efforts", efforts))
}

// listOnce starts a harness only to ask its `initialize` answer, and
// closes it.
func (d *driver) listOnce() (json.RawMessage, error) {
	h, err := brainwire.Spawn(append(append([]string{}, d.harnessCommand...), baseArgv...), d.c.ErrOut)
	if err != nil {
		return nil, err
	}
	defer h.Stop()
	if err := h.Write(initializeLine("")); err != nil {
		return nil, errors.New("it ended before it was asked")
	}
	deadline := time.After(listingWait)
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
			if answer.Subtype != "success" {
				return nil, errors.New("it refused to start")
			}
			var response struct {
				Models json.RawMessage `json:"models"`
			}
			_ = json.Unmarshal(answer.Response, &response)
			return response.Models, nil
		case <-h.Done:
			return nil, errors.New("it ended before it answered")
		case <-deadline:
			return nil, errors.New("it did not answer in time")
		}
	}
}

// ---------------------------------------------------------------------------
// The harness's lines

type control struct {
	Subtype   string          `json:"subtype"`
	RequestID string          `json:"request_id"`
	Response  json.RawMessage `json:"response"`
}

func controlAnswer(raw json.RawMessage) (control, bool) {
	var c control
	return c, json.Unmarshal(raw, &c) == nil
}

func (d *driver) Line(line []byte) error {
	if line == nil {
		return &brainwire.Fatal{Status: 1, Reason: "a line of the harness's past its bound"}
	}
	var l harnessLine
	if json.Unmarshal(line, &l) != nil {
		return nil
	}
	switch l.Type {
	case "control_response":
		return d.controlResponse(l)
	case "control_request":
		return d.controlRequest(l)
	case "system":
		if l.Subtype == "init" || (l.Subtype == "status" && l.Status == "requesting") {
			d.turnWork = d.workOf(l.UserMessageIDs)
		}
	case "stream_event":
		if l.main() {
			return d.streamEvent(l.Event)
		}
	case "assistant":
		if l.main() {
			return d.assistant(l)
		}
	case "user":
		if l.main() {
			return d.toolResults(l.Message)
		}
	case "result":
		return d.result(l)
	}
	return nil
}

func (d *driver) controlResponse(l harnessLine) error {
	answer, ok := controlAnswer(l.Response)
	if !ok {
		return nil
	}
	if answer.RequestID == initID && d.starting != nil {
		if answer.Subtype != "success" {
			return &brainwire.Fatal{Status: 1, Reason: "Claude Code refused to start the session"}
		}
		var response struct {
			Models json.RawMessage `json:"models"`
		}
		_ = json.Unmarshal(answer.Response, &response)
		s := d.starting
		d.starting = nil
		d.session = s.session
		d.listing = response.Models
		// `held` is delivery evidence and no more: the pending posts the
		// transcript was read to hold. A pending post it leaves out is not
		// established, never proved absent.
		held := []string{}
		if s.resume && len(s.pending) > 0 {
			held = heldPosts(d.home, s.session, s.pending)
		}
		return d.c.Emit(brainwire.NewEvent("started").Set("session", s.session).Set("fresh", !s.resume).Set("held", held))
	}
	if id, ok := d.awaiting[answer.RequestID]; ok {
		delete(d.awaiting, answer.RequestID)
		var response struct {
			Errors map[string]any `json:"errors"`
		}
		_ = json.Unmarshal(answer.Response, &response)
		if answer.Subtype != "success" || len(response.Errors) > 0 {
			return d.c.Refuse(id, "Claude Code could not start CYFR's tools.")
		}
		return d.c.Accept(id)
	}
	return nil
}

func (d *driver) controlRequest(l harnessLine) error {
	var request struct {
		Subtype   string         `json:"subtype"`
		ToolName  string         `json:"tool_name"`
		Input     map[string]any `json:"input"`
		ToolUseID string         `json:"tool_use_id"`
	}
	// A call's numbers are passed on as the model wrote them.
	decoder := json.NewDecoder(bytes.NewReader(l.Request))
	decoder.UseNumber()
	_ = decoder.Decode(&request)
	if request.Subtype != "can_use_tool" {
		return d.h.Write(unansweredLine(l.RequestID, request.Subtype))
	}
	if request.Input == nil {
		request.Input = map[string]any{}
	}
	name, ours := strings.CutPrefix(request.ToolName, toolPrefix)
	if !ours {
		// The harness's own tool runs in its box: allowed, and shown by its
		// tool_use (assistant) by name only.
		return d.h.Write(allowLine(l.RequestID, request.Input))
	}
	arguments := callArguments(request.Input)
	if !brainwire.IsID(l.RequestID) {
		return d.h.Write(allowLine(l.RequestID, answeredInput(arguments, "CYFR could not hold this call: its ask names no id CYFR takes.", true)))
	}
	e := brainwire.NewEvent("ask").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("ask", l.RequestID).Set("name", name).Set("arguments", arguments)
	if line, err := brainwire.EncodeEvent(e); err != nil || len(line) >= brainwire.MaxLineBytes {
		// A call CYFR cannot be shown in one line is refused to the harness,
		// which reads why.
		return d.h.Write(allowLine(l.RequestID, answeredInput(arguments, "This call's arguments are past what CYFR takes in one call; make it smaller.", true)))
	}
	d.asks[l.RequestID] = heldAsk{arguments: arguments}
	return d.c.Emit(e)
}

func (d *driver) streamEvent(raw json.RawMessage) error {
	var e struct {
		Type    string `json:"type"`
		Message struct {
			ID string `json:"id"`
		} `json:"message"`
		Delta struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"delta"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return nil
	}
	switch {
	case e.Type == "message_start" && brainwire.IsID(e.Message.ID):
		d.message = e.Message.ID
	case e.Type == "content_block_delta" && e.Delta.Type == "text_delta" && e.Delta.Text != "":
		return d.c.EmitText(brainwire.NewEvent("text").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("message", d.messageID("")), "delta", e.Delta.Text)
	}
	return nil
}

// messageID is a native message's id, or the driver's own name for one
// the harness named none for.
func (d *driver) messageID(id string) string {
	if brainwire.IsID(id) {
		return id
	}
	if brainwire.IsID(d.message) {
		return d.message
	}
	return "message-" + d.c.Boot
}

func (d *driver) assistant(l harnessLine) error {
	var message struct {
		ID      string `json:"id"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"content"`
	}
	_ = json.Unmarshal(l.Message, &message)
	if l.Error != nil {
		// An errored message is the harness's own words about its account
		// or its provider, a sign-in prompt among them: none of its text is
		// passed on, only its type in the driver's words.
		kind := errorKind(*l.Error)
		d.errored = true
		return d.c.Emit(brainwire.NewEvent("error").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("type", kind).Set("message", errorSentence(kind)))
	}
	var text strings.Builder
	for _, block := range message.Content {
		switch {
		case block.Type == "text":
			text.WriteString(block.Text)
		case block.Type == "tool_use" && !strings.HasPrefix(block.Name, toolPrefix) && block.Name != "":
			name := ownName(block.Name)
			d.own[block.ID] = name
			if err := d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("name", name).Set("phase", "start")); err != nil {
				return err
			}
		}
	}
	if text.Len() == 0 {
		return nil
	}
	return d.c.EmitText(brainwire.NewEvent("said").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("message", d.messageID(message.ID)), "text", text.String())
}

// toolResults ends each own tool a user line carries the result of.
func (d *driver) toolResults(raw json.RawMessage) error {
	var message struct {
		Content []struct {
			Type      string `json:"type"`
			ToolUseID string `json:"tool_use_id"`
		} `json:"content"`
	}
	if json.Unmarshal(raw, &message) != nil {
		return nil
	}
	for _, block := range message.Content {
		name, ok := d.own[block.ToolUseID]
		if block.Type != "tool_result" || !ok {
			continue
		}
		delete(d.own, block.ToolUseID)
		if err := d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("name", name).Set("phase", "end")); err != nil {
			return err
		}
	}
	return nil
}

func (d *driver) result(l harnessLine) error {
	if d.starting != nil && l.noTranscript() {
		d.h.Expected = true
		d.starting = nil
		return d.c.Emit(brainwire.NewEvent("gone"))
	}
	work := d.workOf(l.UserMessageIDs)
	d.results++
	result := l.UUID
	if !brainwire.IsID(result) {
		result = fmt.Sprintf("result-%s-%d", d.c.Boot, d.results)
	}
	usage := brainwire.NewEvent("usage").Set("gen", d.gen).SetOptional("work", work).Set("result", result)
	read, models := accounting(l.ModelUsage)
	usage.Set("accounting", read)
	if read != "unavailable" {
		usage.Set("models", models)
	}
	if err := d.c.Emit(usage); err != nil {
		return err
	}
	stop := stopEndTurn
	failed := l.IsError != nil && *l.IsError
	switch {
	case strings.HasPrefix(l.Subtype, "error_max_"):
		stop = stopLimit
	case failed || (l.Subtype != "success" && l.Subtype != ""):
		stop = stopError
		if !d.errored {
			if err := d.c.Emit(brainwire.NewEvent("error").Set("gen", d.gen).SetOptional("work", work).Set("type", "provider_error").Set("message", errorSentence("provider_error"))); err != nil {
				return err
			}
		}
	}
	d.errored = false
	answered := []string{}
	seen := map[string]bool{}
	for _, uuid := range l.UserMessageIDs {
		if p, ok := d.posts[uuid]; ok && !seen[p.id] && len(answered) < brainwire.MaxList {
			seen[p.id] = true
			answered = append(answered, p.id)
		}
	}
	return d.c.Emit(brainwire.NewEvent("idle").Set("gen", d.gen).SetOptional("work", work).Set("answered", answered).Set("stop", stop))
}

// workOf is the work of the first post a line's uuids name, or none.
func (d *driver) workOf(uuids []string) string {
	for _, uuid := range uuids {
		if p, ok := d.posts[uuid]; ok {
			return p.work
		}
	}
	return ""
}

// ownName is the harness's own tool's name, at most 128 bytes of it.
func ownName(name string) string {
	if len(name) <= 128 {
		return name
	}
	cut := []rune(name)
	for len(string(cut)) > 128 {
		cut = cut[:len(cut)-1]
	}
	return string(cut)
}

func (d *driver) Ended() error {
	expected, status := d.h.Expected, d.h.Status
	d.h = nil
	d.starting = nil
	d.listing = nil
	d.asks = map[string]heldAsk{}
	d.awaiting = map[string]string{}
	if expected {
		return nil
	}
	if status == 0 {
		status = 1
	}
	return &brainwire.Fatal{Status: status, Reason: "the harness ended"}
}

// Close closes the harness, if one runs.
func (d *driver) Close() {
	if d.h != nil {
		d.h.Stop()
		d.h = nil
	}
}
