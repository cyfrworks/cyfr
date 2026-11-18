// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

const driverName = "cyfr-codex"

// The stops an idle names.
const (
	stopEndTurn = "end_turn"
	stopError   = "error"
)

type post struct{ id, work string }

// turn is a native turn under way: the work of the first post it holds and
// the posts it holds, as Codex names them by their uuids.
type turn struct {
	work     string
	answered []string
	seen     map[string]bool
}

// heldAsk is a call of CYFR's tool Codex holds: its request's id, which
// the answer names.
type heldAsk struct{ request json.RawMessage }

// starting is a start Codex has not answered yet, and the request of its
// handshake the driver waits on.
type starting struct {
	resume  bool
	session string
	pending []string
	system  string
	tools   []map[string]any
	stage   string
	request string
}

// waiting is the delivery the holder waits on Codex's answer for: the
// command's id, what was asked, and the request answering it.
type waiting struct {
	id      string
	kind    string
	request string
	work    string
	uuid    string
	input   []any
	listing []json.RawMessage
	pages   int
}

type driver struct {
	harnessCommand []string
	c              *brainwire.Conn
	home           string

	h        *brainwire.Process
	starting *starting
	waiting  *waiting
	gen      uint64
	session  string
	model    string
	config   brainwire.Config
	signedIn bool
	requests int
	// others is set from the first sign of a thread not the session's (a
	// sub-agent's): an event of its own, or the session's call of one.
	// Whether the session's total holds a sub-agent's counts is not
	// established, so from then on its usage is partial.
	others bool
	// resumed is set while a resumed thread has sent no usable total, one
	// that carries counts: its first is partial, since it may end a stretch
	// a sub-agent worked in whose total's event never committed, and
	// nothing of `others` outlives the process that saw it.
	resumed bool
	// What the native turns name: each post by its uuid, each turn under
	// way, the one Codex runs now, the harness's own tools running, and the
	// calls of CYFR's tools it holds, by their call ids.
	posts  map[string]post
	turns  map[string]*turn
	active string
	own    map[string]string
	asks   map[string]heldAsk
}

func newDriver(command []string, c *brainwire.Conn, home string) brainwire.Driver {
	return &driver{harnessCommand: command, c: c, home: home, posts: map[string]post{}, turns: map[string]*turn{},
		own: map[string]string{}, asks: map[string]heldAsk{}}
}

func (d *driver) Process() *brainwire.Process { return d.h }

func (d *driver) running() bool { return d.h != nil && d.starting == nil && d.session != "" }

// nextID is a request id of the driver's: unique to the process, so no
// answer is taken for another request's.
func (d *driver) nextID(what string) string {
	d.requests++
	return fmt.Sprintf("cyfr-%s-%d", what, d.requests)
}

// ---------------------------------------------------------------------------
// Commands

func (d *driver) Command(t string, members map[string]json.RawMessage) error {
	str := func(name string) string { return brainwire.Str(members, name) }
	switch t {
	case "start":
		return d.start(members, str)
	case "work":
		return d.work(str("id"))
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

// start starts Codex's app-server, and in it a new thread with the start's
// tools or the thread the start names. A configuration Codex cannot honour
// ends the driver: Codex has no permission mode of CYFR's to take, since
// the box is its one boundary, and its own tools have no switch; nor can
// it run read-only, since its read-only sandbox needs the namespaces the
// box refuses, so a read-only start starts nothing.
func (d *driver) start(members map[string]json.RawMessage, str func(string) string) error {
	if d.h != nil {
		return &brainwire.Fatal{Status: 2, Reason: "a start while the harness runs"}
	}
	var config brainwire.Config
	var pending []string
	var tools []brainwire.Tool
	_ = json.Unmarshal(members["config"], &config)
	_ = json.Unmarshal(members["gen"], &d.gen)
	if raw, ok := members["pending"]; ok {
		_ = json.Unmarshal(raw, &pending)
	}
	if raw, ok := members["tools"]; ok {
		_ = json.Unmarshal(raw, &tools)
	}
	if config.ReadOnly {
		return &brainwire.Fatal{Status: 2, Reason: "Codex cannot run read-only inside CYFR, so nothing ran."}
	}
	if config.PermissionMode != "" {
		return &brainwire.Fatal{Status: 2, Reason: "a start names a permission mode, which Codex in its box does not take"}
	}
	if config.HarnessTools != nil {
		return &brainwire.Fatal{Status: 2, Reason: "a start names the harness's own tools, which Codex has no switch for"}
	}
	session := str("session")
	resume := session != ""
	// A session that is no thread id of Codex's has no transcript.
	if resume && !brainwire.IsUUID(session) {
		return d.c.Emit(brainwire.NewEvent("gone"))
	}
	var dynamic []map[string]any
	if !resume {
		var err error
		if dynamic, err = dynamicTools(tools); err != nil {
			return &brainwire.Fatal{Status: 2, Reason: "a start whose tools Codex cannot take: " + err.Error()}
		}
	}
	h, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), appServer))
	if err != nil {
		// Spawn has said why on the driver's standard error.
		return &brainwire.Fatal{Status: 1}
	}
	d.h = h
	d.config = config
	d.starting = &starting{resume: resume, session: session, pending: pending, system: str("system"), tools: dynamic, stage: "initialize"}
	d.starting.request = d.nextID("initialize")
	return d.h.Write(initializeLine(d.starting.request))
}

// work begins a work: Codex takes its tools at a thread's start only, and a
// resumed thread keeps its own, so nothing is written to it. A tool the
// work adds is not one Codex can call; an ask of a tool the work lacks is
// still shown, for CYFR's gate to refuse.
func (d *driver) work(id string) error {
	if !d.running() {
		return d.c.Refuse(id, "No harness runs: a work follows a start.")
	}
	return d.c.Accept(id)
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
	input, err := inputItems(append(context, content...))
	if err != nil {
		return d.c.Refuse(id, fmt.Sprintf("OpenAI Codex takes text and images; %s is not written to it.", err.Error()))
	}
	w := &waiting{id: id, kind: "post", work: work, uuid: brainwire.PostUUID(id), input: input}
	d.waiting = w
	if !d.signedIn {
		// Codex was signed out when it started: the sign-in is read again,
		// since the person may have signed in on the terminal since.
		w.kind = "post-account"
		w.request = d.nextID("account")
		return d.h.Write(request(w.request, "account/read", map[string]any{}))
	}
	return d.deliver(w)
}

// deliver writes the post: into the native turn under way (`turn/steer`),
// or as a turn of its own. The post is `accepted` once Codex answers its
// request; one Codex refuses is not written.
func (d *driver) deliver(w *waiting) error {
	d.posts[w.uuid] = post{id: w.id, work: w.work}
	if d.active != "" {
		w.kind = "steer"
		w.request = d.nextID("steer")
		return d.h.Write(turnSteer(w.request, d.session, d.active, w.input, w.uuid))
	}
	w.kind = "turn"
	w.request = d.nextID("turn")
	return d.h.Write(turnStart(w.request, d.session, w.input, w.uuid, d.config))
}

func (d *driver) answer(id, ask, content string, isError bool) error {
	held, ok := d.asks[ask]
	if !ok || !d.running() {
		return d.c.Refuse(id, "The harness holds no ask of that id.")
	}
	delete(d.asks, ask)
	if err := d.h.Write(toolAnswer(held.request, content, !isError)); err != nil {
		return err
	}
	return d.c.Accept(id)
}

// models answers Codex's model listing: from the running app-server, or
// from one of its own, started and closed for it, when none runs.
func (d *driver) models(id string) error {
	if d.h != nil && !d.running() {
		return d.c.Refuse(id, "The harness is starting: its models are listed once it has started.")
	}
	if d.h == nil {
		listing, err := d.listOnce()
		if err != nil {
			return d.c.Refuse(id, "OpenAI Codex did not list its models: "+err.Error()+".")
		}
		return d.listed(id, listing)
	}
	d.waiting = &waiting{id: id, kind: "models", request: d.nextID("models")}
	return d.h.Write(request(d.waiting.request, "model/list", map[string]any{}))
}

// listed answers a listing: each model as Codex names it, with the efforts
// any of them takes, in the listing's order.
func (d *driver) listed(id string, listing []json.RawMessage) error {
	models := []map[string]string{}
	efforts := []string{}
	seen := map[string]bool{}
	for _, raw := range listing {
		var entry struct {
			ID          string `json:"id"`
			DisplayName string `json:"displayName"`
			Efforts     []struct {
				Effort string `json:"reasoningEffort"`
			} `json:"supportedReasoningEfforts"`
		}
		if json.Unmarshal(raw, &entry) != nil || !brainwire.IsID(entry.ID) || len(models) >= brainwire.MaxList {
			continue
		}
		models = append(models, map[string]string{"id": entry.ID, "name": entry.DisplayName})
		for _, level := range entry.Efforts {
			if level.Effort != "" && !seen[level.Effort] && len(efforts) < brainwire.MaxList {
				seen[level.Effort] = true
				efforts = append(efforts, level.Effort)
			}
		}
	}
	return d.c.Emit(brainwire.NewEvent("models").Set("id", id).Set("models", models).Set("efforts", efforts))
}

// ---------------------------------------------------------------------------
// Codex's lines

func (d *driver) Line(line []byte) error {
	if line == nil {
		return &brainwire.Fatal{Status: 1, Reason: "a line of the harness's past its bound"}
	}
	var m rpc
	if json.Unmarshal(line, &m) != nil {
		return nil
	}
	switch {
	case m.Method == "" && len(m.ID) > 0:
		var id string
		_ = json.Unmarshal(m.ID, &id)
		return d.response(id, m)
	case m.Method != "" && len(m.ID) > 0:
		return d.request(m)
	case m.Method != "":
		return d.notification(m.Method, m.Params)
	}
	return nil
}

// response is Codex's answer to a request of the driver's: a step of the
// start, or the answer to the command the holder waits on.
func (d *driver) response(id string, m rpc) error {
	if s := d.starting; s != nil && id == s.request {
		return d.startStep(s, m)
	}
	w := d.waiting
	if w == nil || id != w.request {
		return nil
	}
	switch w.kind {
	case "post-account":
		if m.Error == nil && signedIn(m.Result) {
			d.signedIn = true
			return d.deliver(w)
		}
		d.waiting = nil
		return d.c.Refuse(w.id, errorSentence("authentication"))
	case "steer":
		if m.Error == nil {
			d.waiting = nil
			return d.c.Accept(w.id)
		}
		// The turn it named ended meanwhile: the post was not taken, and
		// starts a turn of its own.
		w.kind = "turn"
		w.request = d.nextID("turn")
		return d.h.Write(turnStart(w.request, d.session, w.input, w.uuid, d.config))
	case "turn":
		d.waiting = nil
		if m.Error != nil {
			return d.c.Refuse(w.id, "OpenAI Codex did not take the post.")
		}
		var r struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		}
		_ = json.Unmarshal(m.Result, &r)
		if r.Turn.ID != "" && d.active == "" {
			d.active = r.Turn.ID
		}
		return d.c.Accept(w.id)
	case "models":
		var page struct {
			Data       []json.RawMessage `json:"data"`
			NextCursor *string           `json:"nextCursor"`
		}
		if m.Error != nil || json.Unmarshal(m.Result, &page) != nil {
			d.waiting = nil
			return d.c.Refuse(w.id, "OpenAI Codex did not list its models.")
		}
		w.listing = append(w.listing, page.Data...)
		w.pages++
		if page.NextCursor != nil && *page.NextCursor != "" && w.pages < listingPages {
			w.request = d.nextID("models")
			return d.h.Write(request(w.request, "model/list", map[string]any{"cursor": *page.NextCursor}))
		}
		d.waiting = nil
		return d.listed(w.id, w.listing)
	}
	return nil
}

// signedIn reads `account/read`'s answer: no account, when Codex needs
// one, is a program with no sign-in. Nothing of the account is kept.
func signedIn(result json.RawMessage) bool {
	var r struct {
		Account  json.RawMessage `json:"account"`
		Requires *bool           `json:"requiresOpenaiAuth"`
	}
	if json.Unmarshal(result, &r) != nil {
		return false
	}
	none := len(r.Account) == 0 || string(r.Account) == "null"
	return !none || (r.Requires != nil && !*r.Requires)
}

// startStep is the start's handshake, one answer at a time: `initialize`,
// then the sign-in read, then the thread started or resumed.
func (d *driver) startStep(s *starting, m rpc) error {
	switch s.stage {
	case "initialize":
		if m.Error != nil {
			return &brainwire.Fatal{Status: 1, Reason: "OpenAI Codex refused to start its app-server"}
		}
		if err := d.h.Write(initializedLine()); err != nil {
			return err
		}
		s.stage = "account"
		s.request = d.nextID("account")
		return d.h.Write(request(s.request, "account/read", map[string]any{}))
	case "account":
		d.signedIn = m.Error == nil && signedIn(m.Result)
		s.stage = "thread"
		s.request = d.nextID("thread")
		if s.resume {
			return d.h.Write(threadResume(s.request, s.session, s.system, d.config))
		}
		return d.h.Write(threadStart(s.request, s.system, s.tools, d.config))
	case "thread":
		if m.Error != nil {
			// A thread the folder holds no rollout of is gone: nothing ran.
			if s.resume && strings.HasPrefix(m.Error.Message, noRolloutWords) {
				d.starting = nil
				d.Close()
				return d.c.Emit(brainwire.NewEvent("gone"))
			}
			return &brainwire.Fatal{Status: 1, Reason: "OpenAI Codex refused to start the session"}
		}
		var r struct {
			Model  string `json:"model"`
			Thread struct {
				ID string `json:"id"`
			} `json:"thread"`
		}
		_ = json.Unmarshal(m.Result, &r)
		if !brainwire.IsUUID(r.Thread.ID) || (s.resume && r.Thread.ID != s.session) {
			return &brainwire.Fatal{Status: 1, Reason: "OpenAI Codex started no thread the driver can name"}
		}
		d.starting = nil
		d.session = r.Thread.ID
		d.model = r.Model
		d.resumed = s.resume
		// `held` is delivery evidence and no more: the pending posts the
		// thread's rollout was read to hold. A pending post it leaves out is
		// not established, never proved absent.
		held := []string{}
		if s.resume && len(s.pending) > 0 {
			held, _ = heldPosts(d.home, d.session, s.pending)
		}
		return d.c.Emit(brainwire.NewEvent("started").Set("session", d.session).Set("fresh", !s.resume).Set("held", held))
	}
	return nil
}

// request is a request of Codex's: a call of CYFR's tool, held and shown
// as an ask; an approval, allowed; any other, refused.
func (d *driver) request(m rpc) error {
	if m.Method != "item/tool/call" {
		if answer, ok := allowed(m.Method, m.Params, time.Now().Unix()); ok {
			return d.h.Write(answerLine(m.ID, answer))
		}
		return d.h.Write(refuseLine(m.ID, m.Method))
	}
	var call struct {
		ThreadID  string          `json:"threadId"`
		TurnID    string          `json:"turnId"`
		CallID    string          `json:"callId"`
		Tool      string          `json:"tool"`
		Arguments json.RawMessage `json:"arguments"`
	}
	_ = json.Unmarshal(m.Params, &call)
	switch {
	case !d.running() || call.ThreadID != d.session:
		return d.h.Write(toolAnswer(m.ID, "CYFR runs no call of a thread but its session's.", false))
	case !brainwire.IsID(call.CallID):
		return d.h.Write(toolAnswer(m.ID, "CYFR could not hold this call: its call id is none CYFR takes.", false))
	case !isObject(call.Arguments):
		return d.h.Write(toolAnswer(m.ID, "CYFR takes a call's arguments as one object.", false))
	}
	e := brainwire.NewEvent("ask").Set("gen", d.gen).SetOptional("work", d.workOf(call.TurnID)).
		Set("ask", call.CallID).Set("name", call.Tool).Set("arguments", call.Arguments)
	if line, err := brainwire.EncodeEvent(e); err != nil || len(line) >= brainwire.MaxLineBytes {
		// A call CYFR cannot be shown in one line is refused to Codex, which
		// reads why.
		return d.h.Write(toolAnswer(m.ID, "This call's arguments are past what CYFR takes in one call; make it smaller.", false))
	}
	d.asks[call.CallID] = heldAsk{request: m.ID}
	return d.c.Emit(e)
}

func isObject(raw json.RawMessage) bool {
	var m map[string]json.RawMessage
	return json.Unmarshal(raw, &m) == nil && m != nil
}

// workOf is the work of the native turn `id`: the work of the first post
// Codex named in it, or none for a turn no post started.
func (d *driver) workOf(id string) string {
	if t, ok := d.turns[id]; ok {
		return t.work
	}
	return ""
}

// turnOf is the native turn `id` under way.
func (d *driver) turnOf(id string) *turn {
	t, ok := d.turns[id]
	if !ok {
		t = &turn{seen: map[string]bool{}}
		d.turns[id] = t
	}
	return t
}

// notification is one of Codex's of the session's own thread: another
// thread's (a sub-agent's) is not the session's, and nothing of it is
// passed on.
func (d *driver) notification(method string, params json.RawMessage) error {
	if !d.running() {
		return nil
	}
	var n notice
	ok := json.Unmarshal(params, &n) == nil
	if ok && n.ThreadID != "" && n.ThreadID != d.session {
		d.others = true
	}
	if !ok || n.ThreadID != d.session {
		if method == "serverRequest/resolved" {
			d.resolved(params)
		}
		return nil
	}
	work := d.workOf(n.TurnID)
	switch method {
	case "turn/started":
		d.turnOf(n.Turn.ID)
		if d.active == "" {
			d.active = n.Turn.ID
		}
	case "item/started":
		if n.Item.Type == subAgentCall {
			d.others = true
		}
		switch {
		case n.Item.Type == "userMessage":
			d.holds(n.TurnID, n.Item.ClientID)
		case ownTools[n.Item.Type]:
			d.own[n.Item.ID] = n.Item.Type
			return d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", work).Set("name", n.Item.Type).Set("phase", "start"))
		}
	case "item/agentMessage/delta":
		if n.Delta != "" {
			return d.c.EmitText(brainwire.NewEvent("text").Set("gen", d.gen).SetOptional("work", work).Set("message", d.messageID(n.ItemID)), "delta", n.Delta)
		}
	case "item/completed":
		switch {
		case n.Item.Type == "userMessage":
			d.holds(n.TurnID, n.Item.ClientID)
		case n.Item.Type == "agentMessage" && n.Item.Text != "":
			return d.c.EmitText(brainwire.NewEvent("said").Set("gen", d.gen).SetOptional("work", work).Set("message", d.messageID(n.Item.ID)), "text", n.Item.Text)
		default:
			if name, ok := d.own[n.Item.ID]; ok {
				delete(d.own, n.Item.ID)
				return d.c.Emit(brainwire.NewEvent("own").Set("gen", d.gen).SetOptional("work", work).Set("name", name).Set("phase", "end"))
			}
		}
	case "thread/tokenUsage/updated":
		usage := brainwire.NewEvent("usage").Set("gen", d.gen).SetOptional("work", work).Set("total", d.session)
		read, models := threadTotal(n.TokenUsage, d.model)
		usable := read == "complete"
		if usable && (d.others || d.resumed) {
			read = "partial"
		}
		if usable {
			d.resumed = false
		}
		usage.Set("accounting", read)
		if read != "unavailable" {
			usage.Set("models", models)
		}
		return d.c.Emit(usage)
	case "model/rerouted":
		if brainwire.IsID(n.ToModel) {
			d.model = n.ToModel
		}
	case "serverRequest/resolved":
		d.resolved(params)
	case "turn/completed":
		return d.completed(n)
	}
	return nil
}

// holds records that the native turn `turnID` holds the post whose uuid
// Codex names: its first known post gives the turn its work.
func (d *driver) holds(turnID, uuid string) {
	p, ok := d.posts[uuid]
	if !ok || turnID == "" {
		return
	}
	t := d.turnOf(turnID)
	if t.work == "" {
		t.work = p.work
	}
	if !t.seen[p.id] && len(t.answered) < brainwire.MaxList {
		t.seen[p.id] = true
		t.answered = append(t.answered, p.id)
	}
}

// resolved forgets a held call Codex no longer waits on: its answer would
// reach nothing.
func (d *driver) resolved(params json.RawMessage) {
	var r struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(params, &r) != nil {
		return
	}
	for ask, held := range d.asks {
		if string(held.request) == string(r.RequestID) {
			delete(d.asks, ask)
		}
	}
}

func (d *driver) completed(n notice) error {
	id := n.Turn.ID
	work := d.workOf(id)
	t := d.turnOf(id)
	stop := stopEndTurn
	if n.Turn.Status != "completed" {
		stop = stopError
		kind := "provider_error"
		if n.Turn.Status == "failed" {
			kind = errorKind(n.Turn.Error)
		}
		if err := d.c.Emit(brainwire.NewEvent("error").Set("gen", d.gen).SetOptional("work", work).Set("type", kind).Set("message", errorSentence(kind))); err != nil {
			return err
		}
	}
	delete(d.turns, id)
	if d.active == id {
		d.active = ""
	}
	answered := t.answered
	if answered == nil {
		answered = []string{}
	}
	return d.c.Emit(brainwire.NewEvent("idle").Set("gen", d.gen).SetOptional("work", work).Set("answered", answered).Set("stop", stop))
}

// messageID is a native message's id, or the driver's own name for one
// Codex named none the wire takes.
func (d *driver) messageID(id string) string {
	if brainwire.IsID(id) {
		return id
	}
	return "message-" + d.c.Boot
}

func (d *driver) Ended() error {
	status := d.h.Status
	d.h = nil
	if status == 0 {
		status = 1
	}
	return &brainwire.Fatal{Status: status, Reason: "the harness ended"}
}

// Close closes the harness, if one runs: the thread is Codex's to keep in
// its folder, and the next start resumes it.
func (d *driver) Close() {
	if d.h != nil {
		d.h.Stop()
		d.h = nil
	}
	d.starting = nil
	d.waiting = nil
	d.session = ""
	d.others = false
	d.resumed = false
	d.active = ""
	d.turns = map[string]*turn{}
	d.own = map[string]string{}
	d.asks = map[string]heldAsk{}
}
