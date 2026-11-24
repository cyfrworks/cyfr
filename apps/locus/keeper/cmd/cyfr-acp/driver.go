// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// defaultStub is CYFR's MCP server in the image.
const defaultStub = "/opt/cyfr/bin/cyfr-stub"

const (
	// answerWait bounds each answer of a start's, and of a one-off
	// program's: a first start may fetch the program.
	answerWait = 150 * time.Second
	// listWait bounds the stub's listing of the tools once the session
	// answered.
	listWait = 30 * time.Second
)

// The stops an idle names.
const (
	stopEndTurn = "end_turn"
	stopLimit   = "limit"
	stopError   = "error"
)

// A start's stages, one answer awaited at a time, then the listing.
const (
	stageInitialize = "initialize"
	stageSession    = "session"
	stageLoad       = "load"
	stageConfig     = "config"
	stageListing    = "listing"
)

// starting is a start not yet answered `started`.
type starting struct {
	resume  bool
	session string
	system  string
	stage   string
	request string
	due     time.Time
	// steps are the config options still to set, in order.
	steps []configStep
	what  string
}

type configStep struct{ category, value, words string }

// prompt is one session/prompt the driver wrote: its request id, and the
// post it carried.
type prompt struct {
	id   int
	post string
}

// nativeTurn is a native turn under way: the work of its first post, its
// prompts not yet answered, oldest first, and every post its prompts
// carried, in order.
type nativeTurn struct {
	work  string
	open  []*prompt
	posts []string
}

// steer is a post written as a second prompt, whose answer waits on the
// program's confirmation.
type steer struct {
	post   string
	prompt *prompt
}

type driver struct {
	p              *profile
	harnessCommand []string
	c              *brainwire.Conn
	home           string
	// socketName is the tool socket's name, and stub CYFR's MCP server.
	socketName, stub string
	// answerWait and listWait are the driver's bounds (the constants).
	answerWait, listWait time.Duration

	inbox chan func() error
	sock  *toolSocket

	h         *brainwire.Process
	starting  *starting
	gen       uint64
	config    brainwire.Config
	access    nativeAccess
	tools     []brainwire.Tool
	listed    bool
	cwd       string
	session   string
	signedOut bool
	caps      agentCapabilities
	// meta is the sessions' `_meta`, the instructions in the profile's own
	// place, or nil; handing the instructions a prompt still leads with
	// (instructions.go).
	meta    map[string]any
	handing string
	// answer is the session's last session/new, resume or load answer, and
	// model the model its usage is counted under.
	answer   sessionAnswer
	model    string
	requests int
	prompts  map[string]*prompt
	turn     *nativeTurn
	steer    *steer
	message  string
	text     strings.Builder
	own      map[string]*ownCall
	// unclaimed are the arguments of the turn's socket calls no tool_call
	// update was matched to yet (own.go).
	unclaimed []any
}

func newDriver(p *profile, command []string, c *brainwire.Conn, home string) *driver {
	return &driver{p: p, harnessCommand: command, c: c, home: home, socketName: toolsock.Name, stub: defaultStub,
		answerWait: answerWait, listWait: listWait, inbox: make(chan func() error), prompts: map[string]*prompt{}, own: map[string]*ownCall{}}
}

func (d *driver) Process() *brainwire.Process { return d.h }

func (d *driver) Inbox() <-chan func() error { return d.inbox }

// Deadline is when the start's awaited answer, or the stub's listing, is
// overdue.
func (d *driver) Deadline() <-chan time.Time {
	if d.starting == nil {
		return nil
	}
	return time.After(time.Until(d.starting.due))
}

// Expired ends a start the program did not answer in time, or whose stub
// did not list CYFR's tools in time.
func (d *driver) Expired() error {
	s := d.starting
	if s == nil || time.Now().Before(s.due) {
		return nil
	}
	if s.stage == stageListing {
		return &brainwire.Fatal{Status: 1, Reason: fmt.Sprintf("CYFR's tools did not reach %s: its server for them listed none within %s", d.p.title, d.listWait)}
	}
	return &brainwire.Fatal{Status: 1, Reason: fmt.Sprintf("%s did not answer its start in time (%s)", d.p.title, d.answerWait)}
}

func (d *driver) running() bool { return d.h != nil && d.starting == nil && d.session != "" }

// send writes a request of the driver's and answers its key.
func (d *driver) send(method string, params any) (string, error) {
	d.requests++
	return strconv.Itoa(d.requests), d.h.Write(request(d.requests, method, params))
}

// ---------------------------------------------------------------------------
// Commands

func (d *driver) Command(t string, members map[string]json.RawMessage) error {
	str := func(name string) string { return brainwire.Str(members, name) }
	switch t {
	case "start":
		return d.start(members, str)
	case "work":
		if !d.running() {
			return d.c.Refuse(str("id"), "No harness runs: a work follows a start.")
		}
		// The program takes servers only when a session is made or goes
		// on, so the tools are the start's.
		return d.c.Accept(str("id"))
	case "post":
		return d.post(str("id"), str("work"), members)
	case "answer":
		var isError bool
		_ = json.Unmarshal(members["is_error"], &isError)
		held, written := d.answerAsk(str("ask"), str("content"), isError)
		switch {
		case !held:
			return d.c.Refuse(str("id"), "The harness holds no ask of that id.")
		case !written:
			return d.c.Refuse(str("id"), d.p.title+" no longer waits on that call.")
		}
		return d.c.Accept(str("id"))
	case "models":
		return d.models(str("id"))
	case "forget":
		return d.forget(str("id"), str("session"))
	}
	return &brainwire.Fatal{Status: 2, Reason: "a command of no kind"}
}

// unlistedAccess ends the driver on a start naming an access it does not
// list.
func (d *driver) unlistedAccess() string {
	return "The crew member's access is not one CYFR runs " + d.p.title + " with, so nothing ran."
}

// start binds the tool socket, starts the program and in it the session.
// A configuration the program cannot honour ends the driver: an access the
// driver does not list, the harness's own tools, which ACP has no switch
// for, and a model or effort the session does not offer.
func (d *driver) start(members map[string]json.RawMessage, str func(string) string) error {
	if d.h != nil {
		return &brainwire.Fatal{Status: 2, Reason: "a start while the harness runs"}
	}
	var config brainwire.Config
	var tools []brainwire.Tool
	_ = json.Unmarshal(members["config"], &config)
	_ = json.Unmarshal(members["gen"], &d.gen)
	if raw, ok := members["tools"]; ok {
		_ = json.Unmarshal(raw, &tools)
	}
	access, listed := brainwire.Choose(d.p.access, config.Access)
	if !listed {
		return &brainwire.Fatal{Status: 2, Reason: d.unlistedAccess()}
	}
	if config.HarnessTools != nil {
		return &brainwire.Fatal{Status: 2, Reason: "a start names the harness's own tools, which " + d.p.title + " has no switch for"}
	}
	session := str("session")
	resume := session != ""
	// A session that is no session id of the program's has no transcript.
	if resume && !brainwire.IsUUID(session) {
		return d.c.Emit(brainwire.NewEvent("gone"))
	}
	cwd, err := os.Getwd()
	if err != nil {
		return &brainwire.Fatal{Status: 1, Reason: "the driver has no working folder: " + err.Error()}
	}
	if err := d.listen(); err != nil {
		return &brainwire.Fatal{Status: 1, Reason: "CYFR's tool socket could not be bound: " + err.Error()}
	}
	h, err := d.c.Spawn(append(append([]string{}, d.harnessCommand...), d.p.args...))
	if err != nil {
		// Spawn has said why on the driver's standard error.
		d.closeSocket()
		return &brainwire.Fatal{Status: 1}
	}
	d.h, d.config, d.access, d.tools, d.cwd = h, config, access.Native, tools, cwd
	d.starting = &starting{resume: resume, session: session, system: str("system")}
	return d.ask(d.starting, stageInitialize, "initialize", initializeParams())
}

// ask writes the start's next request and waits on its answer.
func (d *driver) ask(s *starting, stage, method string, params any) error {
	key, err := d.send(method, params)
	s.stage, s.request, s.due = stage, key, time.Now().Add(d.answerWait)
	return err
}

// sessionParams are a session's: the working folder, CYFR's server, the
// same at every start, and the instructions where the program takes them.
func (d *driver) sessionParams(session string) map[string]any {
	params := map[string]any{"cwd": d.cwd, "mcpServers": []any{map[string]any{
		"name": relayServer, "command": d.stub, "args": []string{"--socket", d.socketName}, "env": []any{},
	}}}
	if session != "" {
		params["sessionId"] = session
	}
	if d.meta != nil {
		params["_meta"] = d.meta
	}
	return params
}

func (d *driver) post(id, work string, members map[string]json.RawMessage) error {
	if !d.running() {
		return d.c.Refuse(id, "No harness runs: a post follows a start.")
	}
	if d.signedOut {
		return d.c.RefuseSignedOut(id, d.p.signedOutSentence)
	}
	var content, context []brainwire.Block
	_ = json.Unmarshal(members["content"], &content)
	if raw, ok := members["context"]; ok {
		_ = json.Unmarshal(raw, &context)
	}
	blocks := append(context, content...)
	if d.turn != nil {
		// A held ask's answer comes after the post's (main.go).
		if !d.p.steers || (d.sock != nil && len(d.sock.held) > 0) {
			return d.c.Later(id)
		}
		p, refused, err := d.writePrompt(id, blocks)
		if p == nil {
			return firstOf(err, d.refusal(id, refused))
		}
		d.steer = &steer{post: id, prompt: p}
		return nil
	}
	d.turn = &nativeTurn{work: work}
	p, refused, err := d.writePrompt(id, blocks)
	if p == nil {
		d.turn = nil
		return firstOf(err, d.refusal(id, refused))
	}
	return d.c.Accept(id)
}

func firstOf(err error, then func() error) error {
	if err != nil {
		return err
	}
	return then()
}

func (d *driver) refusal(id, reason string) func() error {
	return func() error { return d.c.Refuse(id, reason) }
}

// unrecordedSentence refuses a post whose instructions the folder cannot
// record as withdrawn: the stale record would hide them.
func (d *driver) unrecordedSentence() string {
	return d.p.title + "'s instructions could not be recorded in its folder, so the post was not written; check that the program's folder can be written."
}

// writePrompt writes the post as a prompt of the turn under way, led by the
// instructions it still hands, with the post's uuid in its `_meta`. It
// answers the prompt, or nil with the reason it was not written.
func (d *driver) writePrompt(id string, blocks []brainwire.Block) (*prompt, string, error) {
	content := []any{}
	handing := d.handing
	if handing != "" {
		if !clearHanded(d.home, d.session) {
			return nil, d.unrecordedSentence(), nil
		}
		content = append(content, textBlock(replacingWords+handing))
	}
	content = append(content, promptContent(blocks, d.caps, d.p.title)...)
	key, err := d.send("session/prompt", map[string]any{"sessionId": d.session, "prompt": content,
		"_meta": map[string]any{"cyfr": map[string]any{"post": brainwire.PostUUID(id)}}})
	if err != nil {
		return nil, "", err
	}
	if handing != "" {
		recordHanded(d.home, d.session, handing)
		d.handing = ""
	}
	p := &prompt{id: d.requests, post: id}
	d.prompts[key] = p
	d.turn.open = append(d.turn.open, p)
	d.turn.posts = append(d.turn.posts, id)
	return p, "", nil
}

// models lists the running session's models, or those of a listing
// session of the driver's own when none runs (listing.go).
func (d *driver) models(id string) error {
	if d.h != nil && !d.running() {
		return d.c.Refuse(id, "The harness is starting: its models are listed once it has started.")
	}
	answer := d.answer
	if d.h == nil {
		var account string
		var err error
		answer, account, err = d.listOnce()
		if err != nil {
			return d.c.Refuse(id, d.p.title+" did not list its models: "+err.Error()+".")
		}
		if account == brainwire.SignedOut {
			return d.c.RefuseSignedOut(id, d.p.signedOutSentence)
		}
	} else if d.signedOut {
		return d.c.RefuseSignedOut(id, d.p.signedOutSentence)
	}
	choices := make([]brainwire.Choice, 0, len(d.p.access))
	for _, a := range d.p.access {
		choices = append(choices, a.Choice)
	}
	return d.c.Emit(brainwire.NewEvent("models").Set("id", id).Set("models", listedModels(answer)).Set("access", choices).
		Set("account", brainwire.SignedIn))
}

// ---------------------------------------------------------------------------
// The program's lines

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
		return d.response(idKey(m.ID), m)
	case m.Method != "" && len(m.ID) > 0:
		if m.Method == "session/request_permission" {
			return d.h.Write(answerLine(m.ID, allowOption(m.Params)))
		}
		return d.h.Write(refuseLine(m.ID, m.Method))
	case m.Method == "session/update":
		return d.update(m.Params)
	}
	return nil
}

func (d *driver) response(key string, m rpc) error {
	if s := d.starting; s != nil && key == s.request {
		return d.startStep(s, m)
	}
	if p, ok := d.prompts[key]; ok {
		delete(d.prompts, key)
		return d.answered(p, m)
	}
	return nil
}

// startStep is the start, one answer at a time: initialize; the session
// made, resumed or loaded; its config options set; then the listing.
func (d *driver) startStep(s *starting, m rpc) error {
	switch s.stage {
	case stageInitialize:
		var init initialized
		if m.Error != nil || json.Unmarshal(m.Result, &init) != nil {
			return &brainwire.Fatal{Status: 1, Reason: d.p.title + " refused to start its ACP server"}
		}
		d.caps = agentCapabilities{}
		_ = json.Unmarshal(init.Capabilities, &d.caps)
		if why := qualify(d.p, init, d.caps); why != "" {
			return &brainwire.Fatal{Status: 1, Reason: why}
		}
		d.meta = nil
		if s.system != "" && d.p.appends != nil && d.p.appends(init.Capabilities) {
			d.meta = d.p.instructionsMeta(s.system)
		}
		if s.resume {
			return d.ask(s, stageSession, "session/resume", d.sessionParams(s.session))
		}
		return d.ask(s, stageSession, "session/new", d.sessionParams(""))
	case stageSession, stageLoad:
		if m.Error != nil {
			switch {
			case m.Error.Code == d.p.signedOut:
				return d.startedSignedOut(s)
			case s.stage == stageSession && s.resume && d.p.resumeNotFound(m.Error):
				return d.ask(s, stageLoad, "session/load", d.sessionParams(s.session))
			case s.stage == stageLoad && d.p.loadNotFound(m.Error):
				// The folder holds no such session: nothing ran.
				d.starting = nil
				d.Close()
				return d.c.Emit(brainwire.NewEvent("gone"))
			}
			return &brainwire.Fatal{Status: 1, Reason: d.p.title + " refused to start the session"}
		}
		var answer sessionAnswer
		_ = json.Unmarshal(m.Result, &answer)
		switch {
		case !s.resume && !brainwire.IsUUID(answer.SessionID):
			return &brainwire.Fatal{Status: 1, Reason: d.p.title + " started no session the driver can name"}
		case s.resume && answer.SessionID != "" && answer.SessionID != s.session:
			return &brainwire.Fatal{Status: 1, Reason: d.p.title + " went on with another session than the one named"}
		}
		d.session = s.session
		if !s.resume {
			d.session = answer.SessionID
		}
		d.taken(answer)
		if d.meta == nil && s.system != "" && (!s.resume || !wasHanded(d.home, d.session, s.system)) {
			d.handing = s.system
		}
		s.steps = nil
		if d.config.Model != "" {
			s.steps = append(s.steps, configStep{"model", d.config.Model, "model"})
		}
		if d.config.Effort != "" {
			s.steps = append(s.steps, configStep{"thought_level", d.config.Effort, "effort"})
		}
		if d.access.mode != "" {
			s.steps = append(s.steps, configStep{"mode", d.access.mode, "access"})
		}
		return d.configure(s)
	case stageConfig:
		if m.Error != nil {
			return &brainwire.Fatal{Status: 1, Reason: fmt.Sprintf("%s refused the crew member's %s", d.p.title, s.what)}
		}
		var answer sessionAnswer
		if json.Unmarshal(m.Result, &answer) == nil && answer.Options != nil {
			d.answer.Options = answer.Options
			d.taken(d.answer)
		}
		return d.configure(s)
	}
	return nil
}

// taken keeps a session's answer and the model it counts under.
func (d *driver) taken(answer sessionAnswer) {
	d.answer = answer
	d.model = answer.Models.Current
	if o := option(answer.Options, "model"); o != nil && o.Current != "" {
		d.model = o.Current
	}
}

// configure sets the start's next config option, each one the session
// offers; a model or effort it does not offer ends the driver before
// anything is asked of the session, and an access's mode is set only where
// it differs. With none left the start waits for the listing.
func (d *driver) configure(s *starting) error {
	for len(s.steps) > 0 {
		step := s.steps[0]
		s.steps = s.steps[1:]
		o := option(d.answer.Options, step.category)
		if step.category == "mode" {
			if o == nil || o.Current == step.value {
				continue
			}
		}
		if o == nil || !o.offers(step.value) {
			return &brainwire.Fatal{Status: 2, Reason: fmt.Sprintf("The crew member's %s is not one %s offers, so nothing ran.", step.words, d.p.title)}
		}
		s.what = step.words
		return d.ask(s, stageConfig, "session/set_config_option", map[string]any{"sessionId": d.session, "configId": o.ID, "value": step.value})
	}
	s.stage, s.request, s.due = stageListing, "", time.Now().Add(d.listWait)
	if d.listed {
		return d.started(s)
	}
	return nil
}

// started answers the start once the session answered and the stub listed
// CYFR's tools: a session the program answered is its positive sign-in
// answer. A load's replay is never passed on, so `held` names none.
func (d *driver) started(s *starting) error {
	d.starting = nil
	return d.c.Emit(brainwire.NewEvent("started").Set("session", d.session).Set("fresh", !s.resume).Set("held", []string{}).
		Set("account", brainwire.SignedIn))
}

// startedSignedOut answers a start the program refused for want of a
// sign-in: the process stays, and every post is refused as signed out
// until the next start.
func (d *driver) startedSignedOut(s *starting) error {
	d.starting = nil
	d.signedOut = true
	d.session = s.session
	if !s.resume {
		d.session = brainwire.NewUUID()
	}
	return d.c.Emit(brainwire.NewEvent("started").Set("session", d.session).Set("fresh", !s.resume).Set("held", []string{}).
		Set("account", brainwire.SignedOut))
}

// update is one session/update of the running session's, read while a
// prompt runs: every update before it, a load's replay among them, is
// dropped, as is each kind the driver does not use.
func (d *driver) update(params json.RawMessage) error {
	var n struct {
		SessionID string          `json:"sessionId"`
		Update    json.RawMessage `json:"update"`
	}
	if !d.running() || d.turn == nil || json.Unmarshal(params, &n) != nil || n.SessionID != d.session {
		return nil
	}
	var u struct {
		Kind    string `json:"sessionUpdate"`
		Message string `json:"messageId"`
		// A message chunk's content is one block, a tool call's a list of
		// them: read as the kind says.
		Content  json.RawMessage `json:"content"`
		CallID   string          `json:"toolCallId"`
		Status   string          `json:"status"`
		ToolKind string          `json:"kind"`
		RawInput json.RawMessage `json:"rawInput"`
	}
	if json.Unmarshal(n.Update, &u) != nil {
		return nil
	}
	switch u.Kind {
	case "agent_message_chunk":
		var block struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal(u.Content, &block) != nil || block.Type != "text" || block.Text == "" {
			return nil
		}
		id := u.Message
		if !brainwire.IsID(id) {
			id = d.message
			if id == "" && len(d.turn.open) > 0 {
				id = fmt.Sprintf("%s-%d", d.c.Boot, d.turn.open[len(d.turn.open)-1].id)
			}
			if id == "" {
				id = d.c.Boot
			}
		}
		if d.message != "" && id != d.message {
			if err := d.said(); err != nil {
				return err
			}
		}
		d.message = id
		d.text.WriteString(block.Text)
		return d.c.EmitText(d.event("text").Set("message", id), "delta", block.Text)
	case "tool_call", "tool_call_update":
		return d.ownUpdate(u.CallID, u.Status, u.ToolKind, u.RawInput)
	}
	return nil
}

// event is an event of the native turn under way.
func (d *driver) event(t string) *brainwire.Event {
	work := ""
	if d.turn != nil {
		work = d.turn.work
	}
	return brainwire.NewEvent(t).Set("gen", d.gen).SetOptional("work", work)
}

// said says the message under way whole.
func (d *driver) said() error {
	if d.message == "" {
		return nil
	}
	id, text := d.message, d.text.String()
	d.message = ""
	d.text.Reset()
	return d.c.EmitText(d.event("said").Set("message", id), "text", text)
}

// answered is a prompt's answer. A steer waits on it: the earlier prompt's
// answer once the later was written is the program's confirmation, and the
// later's error before it is its refusal. A prompt answered while a later
// one of its turn is open was steered into, and the turn goes on; the last
// one's answer ends the native turn.
func (d *driver) answered(p *prompt, m rpc) error {
	t := d.turn
	if t == nil {
		return nil
	}
	for i, open := range t.open {
		if open == p {
			t.open = append(t.open[:i:i], t.open[i+1:]...)
			break
		}
	}
	if st := d.steer; st != nil {
		d.steer = nil
		if st.prompt == p && m.Error != nil {
			for i, id := range t.posts {
				if id == st.post {
					t.posts = append(t.posts[:i:i], t.posts[i+1:]...)
					break
				}
			}
			if err := d.c.Refuse(st.post, d.p.title+" did not take the message sent during its turn."); err != nil {
				return err
			}
			return d.ended(t, p, m)
		}
		if err := d.c.Accept(st.post); err != nil {
			return err
		}
	}
	return d.ended(t, p, m)
}

type promptResult struct {
	StopReason string          `json:"stopReason"`
	Usage      json.RawMessage `json:"usage"`
}

// ended passes a prompt's answer on: its usage, where it carries any, and,
// for the turn's last open prompt, its message said whole, its error and
// its `idle` naming every post the turn's prompts carried.
func (d *driver) ended(t *nativeTurn, p *prompt, m rpc) error {
	var result promptResult
	if m.Error == nil {
		_ = json.Unmarshal(m.Result, &result)
	}
	last := len(t.open) == 0
	if len(result.Usage) > 0 || (last && m.Error == nil) {
		usage := d.event("usage").Set("result", fmt.Sprintf("%s-%d", d.c.Boot, p.id))
		accounting, models := promptUsage(result.Usage, d.model, d.p.counted)
		usage.Set("accounting", accounting)
		if accounting != "unavailable" {
			usage.Set("models", models)
		}
		if err := d.c.Emit(usage); err != nil {
			return err
		}
	}
	if !last {
		return nil
	}
	if err := d.flushOwn(); err != nil {
		return err
	}
	if err := d.said(); err != nil {
		return err
	}
	stop, kind, words := stopEndTurn, "", ""
	switch {
	case m.Error != nil:
		kind = errorKind(d.p, m.Error)
		words = errorSentence(d.p, kind)
	case result.StopReason == "end_turn":
	case result.StopReason == "max_tokens" || result.StopReason == "max_turn_requests":
		stop = stopLimit
	case result.StopReason == "refusal":
		kind = "invalid_request"
		words = errorSentence(d.p, kind)
	default:
		// A cancel CYFR sends only as Stop's farewell, whose answer is never
		// read: any other is the program's own.
		kind = "provider_error"
		words = strayStopSentence(d.p)
	}
	if kind != "" {
		stop = stopError
		if err := d.c.Emit(d.event("error").Set("type", kind).Set("message", words)); err != nil {
			return err
		}
	}
	idle := d.event("idle").Set("answered", t.posts).Set("stop", stop)
	d.turn = nil
	d.own = map[string]*ownCall{}
	d.unclaimed = nil
	return d.c.Emit(idle)
}

func (d *driver) Ended() error {
	status := d.h.Status
	d.h = nil
	if status == 0 {
		status = 1
	}
	return &brainwire.Fatal{Status: status, Reason: "the harness ended"}
}

// Close closes the program, if one runs: the session is the program's to
// keep in its folder, and the next start goes on with it. A prompt open is
// first cancelled in ACP's way, Stop's last line, written after its bounds
// are armed, so a program that does not read holds neither; then its input
// closes, and Stop asks it to end and kills it at the bound. The tool
// socket closes after the program has ended.
func (d *driver) Close() {
	if d.turn != nil {
		// Shown before the program is stopped, whatever it writes after.
		_ = d.flushOwn()
	}
	if d.h != nil {
		var farewell [][]byte
		if d.turn != nil && len(d.turn.open) > 0 && d.session != "" {
			farewell = append(farewell, notification("session/cancel", map[string]any{"sessionId": d.session}))
		}
		d.h.Stop(farewell...)
		d.h = nil
	}
	d.closeSocket()
	d.starting = nil
	d.session = ""
	d.signedOut = false
	d.listed = false
	d.meta = nil
	d.handing = ""
	d.answer = sessionAnswer{}
	d.model = ""
	d.prompts = map[string]*prompt{}
	d.turn = nil
	d.steer = nil
	d.message = ""
	d.text.Reset()
	d.own = map[string]*ownCall{}
	d.unclaimed = nil
}
