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

// awaited is a work whose tools request the harness has not answered: the
// work's id, and when its answer is overdue.
type awaited struct {
	id  string
	due time.Time
}

// starting is a start the harness has not answered yet: its `initialize`
// answer, once read (`initialized`), waits for its `mcp_status` answer.
type starting struct {
	session     string
	resume      bool
	pending     []string
	config      brainwire.Config
	initialized bool
	answer      json.RawMessage
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
	// server is the name CYFR's server takes in the harness that runs.
	server string
	// What the native turns under way name: each post's line by its uuid,
	// the work of the native turn under way and its message, the
	// harness's own tools running, the asks of CYFR's tools it holds, and
	// the work each tools request was written for.
	posts    map[string]post
	turnWork string
	message  string
	errored  bool
	// errKind is the type of the errored message of the turn under way, and
	// reached when the limit the harness last said rejected lifts, in Unix
	// seconds, or 0.
	errKind string
	reached int64
	// startDue is when the start's answer is overdue, zero when none is
	// awaited; each tools request awaited has its own (awaited).
	startDue time.Time
	own      map[string]string
	asks     map[string]heldAsk
	awaiting map[string]awaited
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
		awaiting:       map[string]awaited{},
	}
}

// ---------------------------------------------------------------------------
// Commands

func (d *driver) Process() *brainwire.Process { return d.h }

// Deadline is when the first answer the driver awaits is overdue: the
// start's, or a work's tools request's, each its own (answerWait), or nil
// when it awaits none.
func (d *driver) Deadline() <-chan time.Time {
	first := d.startDue
	for _, a := range d.awaiting {
		if first.IsZero() || a.due.Before(first) {
			first = a.due
		}
	}
	if first.IsZero() {
		return nil
	}
	return time.After(time.Until(first))
}

// Expired ends a start the harness did not answer in time, and refuses
// each work whose tools it did not start in time; a late answer is then
// read as one of no request.
// Inbox is none: Claude Code's calls of CYFR's tools come on its own output.
func (d *driver) Inbox() <-chan func() error { return nil }

func (d *driver) Expired() error {
	now := time.Now()
	if !d.startDue.IsZero() && !now.Before(d.startDue) {
		return brainwire.Fail(1, brainwire.WhyUnanswered, fmt.Sprintf("Claude Code did not answer its start in time (%s)", answerWait))
	}
	for request, a := range d.awaiting {
		if now.Before(a.due) {
			continue
		}
		delete(d.awaiting, request)
		if err := d.c.Refuse(a.id, toolsLateSentence()); err != nil {
			return err
		}
	}
	return nil
}

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
	return brainwire.Fail(2, brainwire.WhyBroken, "a command of no kind")
}

func (d *driver) start(members map[string]json.RawMessage, str func(string) string) error {
	// A harness that said it holds no transcript ends by itself; a start
	// after its `gone` waits for that end.
	if d.h != nil && d.h.Expected {
		d.Close()
	}
	if d.h != nil {
		return brainwire.Fail(2, brainwire.WhyBroken, "a start while the harness runs")
	}
	var config brainwire.Config
	var pending []string
	var gen uint64
	_ = json.Unmarshal(members["config"], &config)
	_ = json.Unmarshal(members["gen"], &gen)
	if raw, ok := members["pending"]; ok {
		_ = json.Unmarshal(raw, &pending)
	}
	access, listed := brainwire.Choose(accessChoices, config.Access)
	if !listed {
		return brainwire.Fail(2, brainwire.WhyUnfit, unlistedAccess)
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
	h, err := d.c.Spawn(harnessArgv(d.harnessCommand, brainwire.Packs(), session, resume, config, access.Native))
	if err != nil {
		// Spawn has said why on the driver's standard error.
		return brainwire.Fail(1, brainwire.WhyUnrunnable, "")
	}
	d.h = h
	d.gen = gen
	d.starting = &starting{session: session, resume: resume, pending: pending, config: config}
	// A harness started to resume a session it holds no transcript of
	// says so and ends at once, perhaps before this line reached it: what
	// it wrote is read all the same, and its end decides.
	d.startDue = time.Now().Add(answerWait)
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
	line := setToolsLine(request, d.server, args)
	if len(line) > brainwire.MaxLineBytes {
		return d.c.Refuse(id, fmt.Sprintf("The tools are %d bytes as one line to the harness, past the %d one line carries.", len(line), brainwire.MaxLineBytes))
	}
	d.awaiting[request] = awaited{id: id, due: time.Now().Add(answerWait)}
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
// session's `initialize` gave, which reads no account and so says none, or
// from a harness of its own, started and closed for it, when none runs.
// That one-off listing says the account it read (`account`) and is refused
// in `signedOutSentence` while the harness has no sign-in, so a person
// setting the brain up reads that it is still to sign in.
func (d *driver) models(id string) error {
	listing := d.listing
	var account string
	if d.h != nil && !d.running() {
		return d.c.Refuse(id, "The harness is starting: its models are listed once it has started.")
	}
	if d.h == nil {
		var err error
		if listing, account, err = d.listOnce(); err != nil {
			return d.c.Refuse(id, "Claude Code did not list its models: "+err.Error()+".")
		}
		if account == brainwire.SignedOut {
			return d.c.RefuseSignedOut(id, signedOutSentence)
		}
	}
	var entries []struct {
		Value       string   `json:"value"`
		DisplayName string   `json:"displayName"`
		Efforts     []string `json:"supportedEffortLevels"`
	}
	_ = json.Unmarshal(listing, &entries)
	models := []brainwire.Model{}
	for _, entry := range entries {
		models = brainwire.AppendModel(models, entry.Value, entry.DisplayName, entry.Efforts)
	}
	return d.c.Emit(brainwire.NewEvent("models").Set("id", id).Set("models", models).Set("access", accessChoices).
		SetOptional("account", account))
}

// unlistedAccess ends the driver on a start naming an access it does not
// list.
const unlistedAccess = "The crew member's access is not one CYFR runs Claude Code with, so nothing ran."

// signedOutSentence refuses a one-off listing while Claude Code has no
// sign-in and no key it can run with, as its `initialize` answer says.
const signedOutSentence = "Claude Code has no sign-in or key it can use; sign it in on the program's terminal, or set a key in its settings."

// providers are the providers Claude Code names as its `apiProvider`:
// firstParty, Anthropic's own, and the others it runs on.
var providers = map[string]bool{
	"firstParty": true, "bedrock": true, "vertex": true, "foundry": true, "anthropicAws": true,
	"anthropicGoogleCloud": true, "mantle": true, "gateway": true,
}

// account is what an `initialize` answer's `account` says. The answer has
// one shape: an object whose `apiProvider` is one of providers and whose
// `subscriptionType`, `tokenSource` and `apiKeySource` are each absent or
// a string that is not empty, the members spelled exactly so. Anything
// else is not known, and says nothing, so a sign-in in a shape not yet
// seen never reads signed out.
//
// In that shape signed out is only what Claude Code 2.1.323 answered with
// no sign-in and no key on an empty folder (`tokenSource` "none",
// "firstParty", the other two absent). Signed in is only what it names: a
// plan (all a plan's sign-in names), a token source, a key source, a dead
// key's among them, or another provider. Nothing of the account is kept
// but that word.
func account(response json.RawMessage) string {
	var answer, members map[string]json.RawMessage
	if json.Unmarshal(response, &answer) != nil || json.Unmarshal(answer["account"], &members) != nil {
		return ""
	}
	read := map[string]string{}
	for _, name := range []string{"apiProvider", "subscriptionType", "tokenSource", "apiKeySource"} {
		if raw, present := members[name]; present {
			var value *string
			if json.Unmarshal(raw, &value) != nil || value == nil || *value == "" {
				return ""
			}
			read[name] = *value
		}
	}
	provider := read["apiProvider"]
	if !providers[provider] {
		return ""
	}
	if provider != "firstParty" {
		return brainwire.SignedIn
	}
	for _, name := range []string{"subscriptionType", "tokenSource", "apiKeySource"} {
		if value, present := read[name]; present && value != "none" {
			return brainwire.SignedIn
		}
	}
	if len(read) == 2 && read["tokenSource"] == "none" {
		return brainwire.SignedOut
	}
	return ""
}

// listOnce starts a harness only to ask its `initialize` answer, and
// closes it: the models it lists, and what it says of its account
// (`account`). Its errors are the driver's own sentences, never the
// harness's or the system's words, since a refusal carries them to the
// wire.
func (d *driver) listOnce() (json.RawMessage, string, error) {
	h, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), baseArgv...))
	if err != nil {
		return nil, "", err
	}
	defer h.Stop()
	if err := h.Write(initializeLine("")); err != nil {
		return nil, "", errors.New("it ended before it was asked")
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
				return nil, "", errors.New("it refused to start")
			}
			var response struct {
				Models json.RawMessage `json:"models"`
			}
			_ = json.Unmarshal(answer.Response, &response)
			return response.Models, account(answer.Response), nil
		case <-h.Done:
			return nil, "", errors.New("it ended before it answered")
		case <-deadline:
			return nil, "", errors.New("it did not answer in time")
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
		return brainwire.Fail(1, brainwire.WhyUnreadable, "a line of the harness's past its bound")
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
	case "rate_limit_event":
		d.reached = rejectedUntil(l.RateLimitInfo)
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
	if answer.RequestID == initID && d.starting != nil && !d.starting.initialized {
		if answer.Subtype != "success" {
			return brainwire.Fail(1, brainwire.WhyRefused, "Claude Code refused to start the session")
		}
		// CYFR's server is named once the person's own are known.
		d.starting.initialized = true
		d.starting.answer = answer.Response
		return d.h.Write(statusLine())
	}
	if answer.RequestID == statusID && d.starting != nil && d.starting.initialized {
		// Without the person's servers listed, no name for CYFR's is known
		// not to replace one of theirs, so nothing is set.
		listed, ok := listedServers(answer.Response)
		if answer.Subtype != "success" || !ok {
			return brainwire.Fail(1, brainwire.WhyServersUnlisted, "Claude Code did not list its MCP servers, so no name for CYFR's could be chosen beside the person's own")
		}
		d.server = serverFor(listed)
		d.startDue = time.Time{}
		var response struct {
			Models json.RawMessage `json:"models"`
		}
		s := d.starting
		_ = json.Unmarshal(s.answer, &response)
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
		return d.c.Emit(brainwire.NewEvent("started").Set("session", s.session).Set("fresh", !s.resume).Set("held", held).
			SetOptional("account", account(s.answer)))
	}
	if a, ok := d.awaiting[answer.RequestID]; ok {
		id := a.id
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
		Server    struct {
			Name   string `json:"name"`
			Source string `json:"source"`
		} `json:"mcp_server"`
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
	if request.ToolName == questionTool {
		// The harness's own question is declined: in CYFR the model asks in
		// its reply, and its model reads why as the tool's error.
		return d.h.Write(denyLine(l.RequestID, brainwire.QuestionsDeclined))
	}
	// An ask is CYFR's only when the harness names CYFR's server as the
	// one it set; every other tool, a server's of the person's own among
	// them, is the harness's own. This is the one decision of whose a call
	// is: a tool named with CYFR's prefix is shown as the harness's own only
	// here, once this says so (assistant waits for it).
	name, prefixed := strings.CutPrefix(request.ToolName, toolPrefix(d.server))
	if !prefixed || request.Server.Name != d.server || request.Server.Source != "dynamic" {
		// The harness's own tool runs in its box: allowed, and shown by name
		// only, from its tool_use (assistant) or, named as CYFR's are, from
		// here, until its result or its turn's end. One named as CYFR's that
		// asks nothing, as a tool the person allowed beforehand need not, is
		// not shown at all.
		if prefixed && request.ToolUseID != "" {
			if _, shown := d.own[request.ToolUseID]; !shown {
				own := ownName(request.ToolName)
				d.own[request.ToolUseID] = own
				input, _ := brainwire.Marshal(request.Input)
				if err := d.startOwn(request.ToolUseID, own, input); err != nil {
					return err
				}
			}
		}
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
			Type     string `json:"type"`
			Text     string `json:"text"`
			Thinking string `json:"thinking"`
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
	case e.Type == "content_block_delta" && e.Delta.Type == "thinking_delta" && e.Delta.Thinking != "":
		// The model's reasoning, never part of what it said: the whole
		// message's thinking block is not said either (assistant).
		return d.c.EmitText(brainwire.NewEvent("thought").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("message", d.messageID("")), "delta", e.Delta.Thinking)
	}
	return nil
}

// startOwn shows the start of the harness's own tool, the run `id`, with
// what its input shows it runs. Only its input is read: its result can
// carry whole files (`tool_use_result`), so an end says nothing more.
func (d *driver) startOwn(id, name string, input json.RawMessage) error {
	return d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("call", brainwire.CallID(id)).
		Set("name", name).Set("phase", "start").SetOptional("detail", brainwire.InputDetail(input)))
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
			Type  string          `json:"type"`
			Text  string          `json:"text"`
			ID    string          `json:"id"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
	}
	_ = json.Unmarshal(l.Message, &message)
	if l.Error != nil {
		// An errored message is the harness's own words about its account
		// or its provider, a sign-in prompt among them: none of its text is
		// passed on. Its type is kept for the result that ends the turn,
		// which says it with what the result adds (failure).
		d.errored = true
		d.errKind = errorKind(*l.Error)
		// The error ends the turn for its holder, and its own tools with it.
		d.own = map[string]string{}
		return nil
	}
	var text strings.Builder
	for _, block := range message.Content {
		switch {
		case block.Type == "text":
			text.WriteString(block.Text)
		// A tool named with CYFR's prefix may still be a server's of the
		// person's: its permission says whose it is (controlRequest).
		case block.Type == "tool_use" && !strings.HasPrefix(block.Name, toolPrefix(d.server)) && block.Name != "":
			name := ownName(block.Name)
			d.own[block.ID] = name
			if err := d.startOwn(block.ID, name, block.Input); err != nil {
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
		if err := d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", d.turnWork).Set("call", brainwire.CallID(block.ToolUseID)).
			Set("name", name).Set("phase", "end")); err != nil {
			return err
		}
	}
	return nil
}

func (d *driver) result(l harnessLine) error {
	if d.starting != nil && l.noTranscript() {
		d.h.Expected = true
		d.starting = nil
		d.startDue = time.Time{}
		return d.c.Emit(brainwire.NewEvent("gone"))
	}
	work := d.workOf(l.UserMessageIDs)
	// The native turn ended: none of its own tools runs any more, those it
	// gave no result for among them, which Aqua settles at the idle.
	d.own = map[string]string{}
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
	case failed || d.errored || l.StopReason == "refusal" || (l.Subtype != "success" && l.Subtype != ""):
		stop = stopError
		kind, message := d.failure(l)
		if err := d.c.Emit(brainwire.NewEvent("error").Set("gen", d.gen).SetOptional("work", work).Set("type", kind).Set("message", message)); err != nil {
			return err
		}
	}
	d.errored = false
	d.errKind = ""
	answered := []string{}
	seen := map[string]bool{}
	for _, uuid := range l.UserMessageIDs {
		if p, ok := d.posts[uuid]; ok && !seen[p.id] && len(answered) < brainwire.MaxList {
			seen[p.id] = true
			answered = append(answered, p.id)
		}
	}
	if err := d.c.Emit(brainwire.NewEvent("idle").Set("gen", d.gen).SetOptional("work", work).Set("answered", answered).Set("stop", stop)); err != nil {
		return err
	}
	if stop == stopError && unsendable(l) {
		return d.dropSession()
	}
	return nil
}

// dropSession ends a session the model's API refuses for a message of its
// own history, which every later turn of it would meet: the harness is
// stopped, the session's transcript and plan files are removed as forget
// removes them (removeSession), nothing else of the folder, and the driver
// ends. The next start of the session finds no transcript and answers
// `gone`, so Aqua forgets the session and starts the thread over from its
// posts. Claude Code's own copy of that history is lost; the thread keeps
// every post.
func (d *driver) dropSession() error {
	session := d.session
	d.h.Stop()
	d.h = nil
	if reason := removeSession(d.home, session); reason != "" {
		return brainwire.Fail(1, brainwire.WhyEnded, "a session the model's API refuses could not be removed: "+reason)
	}
	return brainwire.Fail(1, brainwire.WhyEnded, "the model's API refuses this session's history, so it was removed")
}

// failure is the type and the driver's words of a turn that ended in
// error, as its result says it (Claude Code 2.1.323, measured): a stop of
// `refusal` is the model's refusal it kept to after its retry, whatever
// the message's type; then the HTTP status the request ended with, which
// types a 429 and a 529 when the message's type does not (a 529's is
// `server_error`); a 400 the API gave for a message of the session's own
// history (unsendableWords, in the failed result's own text alone); then
// the errored message's own type; else the
// provider's error. A rate limit says when it lifts once the harness said
// (`rate_limit_event`).
func (d *driver) failure(l harnessLine) (string, string) {
	if l.StopReason == "refusal" {
		return "invalid_request", refusalSentence
	}
	if unsendable(l) {
		return "invalid_request", unsendableSentence
	}
	kind := d.errKind
	if l.APIErrorStatus != nil {
		switch *l.APIErrorStatus {
		case 429:
			kind = "rate_limited"
		case 529:
			kind = "overloaded"
		}
	}
	if kind == "" {
		kind = "provider_error"
	}
	if kind == "rate_limited" {
		return kind, limitSentence(d.reached)
	}
	return kind, errorSentence(kind)
}

// unsendable is a failed result the model's API gave for a message of the
// session's own history: a 400 whose result's own text, and nothing the
// model said, names unsendableWords.
func unsendable(l harnessLine) bool {
	var said string
	return l.APIErrorStatus != nil && *l.APIErrorStatus == 400 && json.Unmarshal(l.Result, &said) == nil && strings.Contains(said, unsendableWords)
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
	d.server = ""
	d.reached = 0
	d.startDue = time.Time{}
	d.own = map[string]string{}
	d.asks = map[string]heldAsk{}
	d.awaiting = map[string]awaited{}
	if expected {
		return nil
	}
	if status == 0 {
		status = 1
	}
	return brainwire.Fail(status, brainwire.WhyEnded, "the harness ended")
}

// Close closes the harness, if one runs.
func (d *driver) Close() {
	if d.h != nil {
		d.h.Stop()
		d.h = nil
	}
	d.own = map[string]string{}
}
