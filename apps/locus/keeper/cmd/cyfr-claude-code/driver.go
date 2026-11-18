// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	// maxHarnessLineBytes bounds one line of the harness's output: a tool's
	// result in a user line, the largest it writes, and room beyond.
	maxHarnessLineBytes = 64 << 20
	// closeWait bounds the harness's own end after its input closes or it
	// is told to stop, before it is killed.
	closeWait = 5 * time.Second
	// listingWait bounds a model listing's harness.
	listingWait = 150 * time.Second
	// The stops an idle names.
	stopEndTurn = "end_turn"
	stopLimit   = "limit"
	stopError   = "error"
)

var errLineTooLong = errors.New("a line past its bound")

// lineReader reads newline-ended lines of at most max bytes.
type lineReader struct {
	r   *bufio.Reader
	max int
}

func newLineReader(r io.Reader, max int) *lineReader {
	return &lineReader{r: bufio.NewReaderSize(r, 64<<10), max: max}
}

// next is the next line without its newline: a last line with none is a
// line, and one past the bound is errLineTooLong.
func (l *lineReader) next() ([]byte, error) {
	var line []byte
	for {
		chunk, err := l.r.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > l.max+1 {
			return nil, errLineTooLong
		}
		switch {
		case err == nil:
			return bytes.TrimSuffix(line, []byte("\n")), nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case len(line) > 0:
			return line, err
		default:
			return nil, err
		}
	}
}

// harness is one running harness process.
type harness struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	lines chan []byte
	// done is closed once the process has ended, its status in status.
	done   chan struct{}
	status int
	// expected is set once the harness said it will end (it holds no
	// transcript of the session named): its end ends nothing more.
	expected bool
}

type post struct{ id, work string }

type heldAsk struct{ arguments map[string]any }

// starting is a start the harness has not answered yet.
type starting struct {
	session string
	resume  bool
	pending []string
	config  startConfig
}

type driver struct {
	harnessCommand []string
	out            io.Writer
	errOut         io.Writer
	home           string
	boot           string

	h        *harness
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

func newDriver(command []string, out, errOut io.Writer, home string) *driver {
	return &driver{
		harnessCommand: command,
		out:            out,
		errOut:         errOut,
		home:           home,
		boot:           randomHex(16),
		posts:          map[string]post{},
		own:            map[string]string{},
		asks:           map[string]heldAsk{},
		awaiting:       map[string]string{},
	}
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// errFatal ends the driver with a status: the protocol was broken, or the
// harness ended.
type errFatal struct {
	status int
	reason string
}

func (e *errFatal) Error() string { return e.reason }

// serve speaks the wire on in and d.out until in ends, the harness ends,
// or stop.
func (d *driver) serve(in io.Reader, stop <-chan os.Signal) int {
	if err := d.emit(newEvent("hello").set("v", wireVersion).set("driver", driverName).set("boot", d.boot)); err != nil {
		return 1
	}
	commands := make(chan []byte)
	go readCommands(in, commands)
	for {
		var lines chan []byte
		var exited chan struct{}
		if d.h != nil {
			lines, exited = d.h.lines, d.h.done
		}
		var err error
		select {
		case line, ok := <-commands:
			if !ok {
				d.closeHarness()
				return 0
			}
			err = d.command(line)
		case line := <-lines:
			err = d.harnessLine(line)
		case <-exited:
			err = d.harnessEnded()
		case <-stop:
			d.closeHarness()
			return 0
		}
		var fatal *errFatal
		if errors.As(err, &fatal) {
			if fatal.reason != "" {
				fmt.Fprintln(d.errOut, "cyfr-claude-code:", fatal.reason)
			}
			d.closeHarness()
			return fatal.status
		}
	}
}

// emit writes one event, once it reads as the wire's.
func (d *driver) emit(e *event) error {
	line, err := encodeEvent(e)
	if err != nil {
		return &errFatal{1, err.Error()}
	}
	if _, err := d.out.Write(append(line, '\n')); err != nil {
		return &errFatal{1, "its output: " + err.Error()}
	}
	return nil
}

// emitText writes an event carrying text, cut to fit one line when it
// would not, with a note saying so.
func (d *driver) emitText(e *event, name, text string) error {
	full := *e
	full.members = append(append([]member{}, e.members...), member{name, text})
	if line, err := encodeEvent(&full); err == nil && len(line) < maxLineBytes {
		return d.emit(&full)
	}
	const note = "…[CYFR cut this text to fit one line of the wire.]"
	room := maxLineBytes/2 - len(note)
	cut := []rune(text)
	for len(string(cut)) > room {
		cut = cut[:len(cut)*3/4]
	}
	return d.emit(e.set(name, string(cut)+note))
}

func (d *driver) refuse(id, reason string) error {
	return d.emit(newEvent("refused").set("id", id).set("reason", reason))
}

func (d *driver) accept(id string) error { return d.emit(newEvent("accepted").set("id", id)) }

// write writes one line to the harness: a harness that does not take it
// has ended, which its end says.
func (d *driver) write(line []byte) error {
	if _, err := d.h.stdin.Write(append(line, '\n')); err != nil {
		return &errFatal{1, "the harness's input: " + err.Error()}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Commands

func (d *driver) command(line []byte) error {
	if line == nil {
		return &errFatal{2, "a command past the wire's bound"}
	}
	t, members, err := readLine(line, commands)
	if err != nil {
		return &errFatal{2, fmt.Sprintf("a command the wire does not read (%v)", err)}
	}
	str := func(name string) string {
		var s string
		_ = json.Unmarshal(members[name], &s)
		return s
	}
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
	return &errFatal{2, "a command of no kind"}
}

func (d *driver) start(members map[string]json.RawMessage, str func(string) string) error {
	// A harness that said it holds no transcript ends by itself; a start
	// after its `gone` waits for that end.
	if d.h != nil && d.h.expected {
		d.closeHarness()
	}
	if d.h != nil {
		return &errFatal{2, "a start while the harness runs"}
	}
	var config startConfig
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
	if resume && !isUUID(session) {
		return d.emit(newEvent("gone"))
	}
	if !resume {
		session = newUUID()
	}
	h, err := d.spawn(harnessArgv(d.harnessCommand, session, resume, config))
	if err != nil {
		return &errFatal{1, "the harness did not start: " + err.Error()}
	}
	d.h = h
	d.gen = gen
	d.starting = &starting{session: session, resume: resume, pending: pending, config: config}
	// A harness started to resume a session it holds no transcript of
	// says so and ends at once, perhaps before this line reached it: what
	// it wrote is read all the same, and its end decides.
	_, _ = d.h.stdin.Write(append(initializeLine(str("system")), '\n'))
	return nil
}

func (d *driver) running() bool { return d.h != nil && d.starting == nil && !d.h.expected }

func (d *driver) work(id string, raw json.RawMessage) error {
	if !d.running() {
		return d.refuse(id, "No harness runs: a work follows a start.")
	}
	if len(d.asks) > 0 {
		return d.refuse(id, "The harness holds an ask of CYFR's: it is answered before its tools are set again.")
	}
	var tools []tool
	_ = json.Unmarshal(raw, &tools)
	args := make([]string, 0, len(tools))
	for _, t := range tools {
		arg, err := stubTool(t)
		if err != nil {
			return d.refuse(id, fmt.Sprintf("The tool %s cannot be written for cyfr-stub.", t.Name))
		}
		if len(arg) > maxToolArgBytes {
			return d.refuse(id, fmt.Sprintf("The tool %s is %d bytes as cyfr-stub's argument, past the %d one argument carries.", t.Name, len(arg), maxToolArgBytes))
		}
		args = append(args, arg)
	}
	d.requests++
	request := fmt.Sprintf("%s-%d", toolsID, d.requests)
	line := setToolsLine(request, args)
	if len(line) > maxLineBytes {
		return d.refuse(id, fmt.Sprintf("The tools are %d bytes as one line to the harness, past the %d one line carries.", len(line), maxLineBytes))
	}
	d.awaiting[request] = id
	return d.write(line)
}

func (d *driver) post(id, work string, members map[string]json.RawMessage) error {
	if !d.running() {
		return d.refuse(id, "No harness runs: a post follows a start.")
	}
	var content, context []wireBlock
	_ = json.Unmarshal(members["content"], &content)
	if raw, ok := members["context"]; ok {
		_ = json.Unmarshal(raw, &context)
	}
	uuid := postUUID(id)
	d.posts[uuid] = post{id: id, work: work}
	blocks := append(harnessBlocks(context), harnessBlocks(content)...)
	if err := d.write(userLine(blocks, uuid)); err != nil {
		return err
	}
	return d.accept(id)
}

func (d *driver) answer(id, ask, content string, isError bool) error {
	held, ok := d.asks[ask]
	if !ok || !d.running() {
		return d.refuse(id, "The harness holds no ask of that id.")
	}
	delete(d.asks, ask)
	if err := d.write(allowLine(ask, answeredInput(held.arguments, content, isError))); err != nil {
		return err
	}
	return d.accept(id)
}

// models answers the harness's model listing: from the answer its running
// session's `initialize` gave, or from a harness of its own, started and
// closed for it, when none runs.
func (d *driver) models(id string) error {
	listing := d.listing
	if d.h != nil && !d.running() {
		return d.refuse(id, "The harness is starting: its models are listed once it has started.")
	}
	if d.h == nil {
		var err error
		if listing, err = d.listOnce(); err != nil {
			return d.refuse(id, "Claude Code did not list its models: "+err.Error())
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
		if !isID(entry.Value) || len(models) >= maxList {
			continue
		}
		models = append(models, map[string]string{"id": entry.Value, "name": entry.DisplayName})
		for _, level := range entry.Efforts {
			if !seen[level] && len(efforts) < maxList {
				seen[level] = true
				efforts = append(efforts, level)
			}
		}
	}
	return d.emit(newEvent("models").set("id", id).set("models", models).set("efforts", efforts))
}

// listOnce starts a harness only to ask its `initialize` answer, and
// closes it.
func (d *driver) listOnce() (json.RawMessage, error) {
	h, err := d.spawn(append(append([]string{}, d.harnessCommand...), baseArgv...))
	if err != nil {
		return nil, err
	}
	defer stopHarness(h)
	if _, err := h.stdin.Write(append(initializeLine(""), '\n')); err != nil {
		return nil, errors.New("it ended before it was asked")
	}
	deadline := time.After(listingWait)
	for {
		select {
		case line := <-h.lines:
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
		case <-h.done:
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

func (d *driver) harnessLine(line []byte) error {
	if line == nil {
		return &errFatal{1, "a line of the harness's past its bound"}
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
			return &errFatal{1, "Claude Code refused to start the session"}
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
		return d.emit(newEvent("started").set("session", s.session).set("fresh", !s.resume).set("held", held))
	}
	if id, ok := d.awaiting[answer.RequestID]; ok {
		delete(d.awaiting, answer.RequestID)
		var response struct {
			Errors map[string]any `json:"errors"`
		}
		_ = json.Unmarshal(answer.Response, &response)
		if answer.Subtype != "success" || len(response.Errors) > 0 {
			return d.refuse(id, "Claude Code could not start CYFR's tools.")
		}
		return d.accept(id)
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
		return d.write(unansweredLine(l.RequestID, request.Subtype))
	}
	if request.Input == nil {
		request.Input = map[string]any{}
	}
	name, ours := strings.CutPrefix(request.ToolName, toolPrefix)
	if !ours {
		// The harness's own tool runs in its box: allowed, and shown by its
		// tool_use (assistant) by name only.
		return d.write(allowLine(l.RequestID, request.Input))
	}
	arguments := callArguments(request.Input)
	if !isID(l.RequestID) {
		return d.write(allowLine(l.RequestID, answeredInput(arguments, "CYFR could not hold this call: its ask names no id CYFR takes.", true)))
	}
	e := newEvent("ask").set("gen", d.gen).setOptional("work", d.turnWork).set("ask", l.RequestID).set("name", name).set("arguments", arguments)
	if line, err := encodeEvent(e); err != nil || len(line) >= maxLineBytes {
		// A call CYFR cannot be shown in one line is refused to the harness,
		// which reads why.
		return d.write(allowLine(l.RequestID, answeredInput(arguments, "This call's arguments are past what CYFR takes in one call; make it smaller.", true)))
	}
	d.asks[l.RequestID] = heldAsk{arguments: arguments}
	return d.emit(e)
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
	case e.Type == "message_start" && isID(e.Message.ID):
		d.message = e.Message.ID
	case e.Type == "content_block_delta" && e.Delta.Type == "text_delta" && e.Delta.Text != "":
		return d.emitText(newEvent("text").set("gen", d.gen).setOptional("work", d.turnWork).set("message", d.messageID("")), "delta", e.Delta.Text)
	}
	return nil
}

// messageID is a native message's id, or the driver's own name for one
// the harness named none for.
func (d *driver) messageID(id string) string {
	if isID(id) {
		return id
	}
	if isID(d.message) {
		return d.message
	}
	return "message-" + d.boot
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
		return d.emit(newEvent("error").set("gen", d.gen).setOptional("work", d.turnWork).set("type", kind).set("message", errorSentence(kind)))
	}
	var text strings.Builder
	for _, block := range message.Content {
		switch {
		case block.Type == "text":
			text.WriteString(block.Text)
		case block.Type == "tool_use" && !strings.HasPrefix(block.Name, toolPrefix) && block.Name != "":
			name := ownName(block.Name)
			d.own[block.ID] = name
			if err := d.emit(newEvent("own").set("gen", d.gen).setOptional("work", d.turnWork).set("name", name).set("phase", "start")); err != nil {
				return err
			}
		}
	}
	if text.Len() == 0 {
		return nil
	}
	return d.emitText(newEvent("said").set("gen", d.gen).setOptional("work", d.turnWork).set("message", d.messageID(message.ID)), "text", text.String())
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
		if err := d.emit(newEvent("own").set("gen", d.gen).setOptional("work", d.turnWork).set("name", name).set("phase", "end")); err != nil {
			return err
		}
	}
	return nil
}

func (d *driver) result(l harnessLine) error {
	if d.starting != nil && l.noTranscript() {
		d.h.expected = true
		d.starting = nil
		return d.emit(newEvent("gone"))
	}
	work := d.workOf(l.UserMessageIDs)
	d.results++
	result := l.UUID
	if !isID(result) {
		result = fmt.Sprintf("result-%s-%d", d.boot, d.results)
	}
	usage := newEvent("usage").set("gen", d.gen).setOptional("work", work).set("result", result)
	read, models := accounting(l.ModelUsage)
	usage.set("accounting", read)
	if read != "unavailable" {
		usage.set("models", models)
	}
	if err := d.emit(usage); err != nil {
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
			if err := d.emit(newEvent("error").set("gen", d.gen).setOptional("work", work).set("type", "provider_error").set("message", errorSentence("provider_error"))); err != nil {
				return err
			}
		}
	}
	d.errored = false
	answered := []string{}
	seen := map[string]bool{}
	for _, uuid := range l.UserMessageIDs {
		if p, ok := d.posts[uuid]; ok && !seen[p.id] && len(answered) < maxList {
			seen[p.id] = true
			answered = append(answered, p.id)
		}
	}
	return d.emit(newEvent("idle").set("gen", d.gen).setOptional("work", work).set("answered", answered).set("stop", stop))
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

func (d *driver) harnessEnded() error {
	expected, status := d.h.expected, d.h.status
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
	return &errFatal{status, "the harness ended"}
}

// ---------------------------------------------------------------------------
// The harness's process

func (d *driver) spawn(argv []string) (*harness, error) {
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(path, argv[1:]...)
	cmd.Args = argv
	// The harness's standard error is the driver's, which the box keeps
	// for the person and never hands a thread.
	cmd.Stderr = d.errOut
	// Its own process group, so a server it starts ends with it, and it
	// ends with the driver.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	h := &harness{cmd: cmd, stdin: stdin, lines: make(chan []byte), done: make(chan struct{})}
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		reader := newLineReader(stdout, maxHarnessLineBytes)
		for {
			line, err := reader.next()
			if line != nil || errors.Is(err, errLineTooLong) {
				h.lines <- line
			}
			if err != nil {
				return
			}
		}
	}()
	go func() {
		<-stopped
		if err := cmd.Wait(); err != nil {
			h.status = 1
			var exit *exec.ExitError
			if errors.As(err, &exit) && exit.ExitCode() > 0 {
				h.status = exit.ExitCode()
			}
		}
		close(h.done)
	}()
	return h, nil
}

func (d *driver) closeHarness() {
	if d.h != nil {
		stopHarness(d.h)
		d.h = nil
	}
}

// stopHarness closes the harness's input and waits for its end, then
// ends its process group, so a server it started ends with it.
func stopHarness(h *harness) {
	_ = h.stdin.Close()
	pgid := h.cmd.Process.Pid
	deadline := time.After(closeWait)
	for {
		select {
		case <-h.lines:
		case <-h.done:
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
			return
		case <-deadline:
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		}
	}
}
