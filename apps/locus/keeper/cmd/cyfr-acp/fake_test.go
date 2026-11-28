// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/toolsock"
)

// The test binary is also a stand-in for Antigravity's ACP server when
// CYFR_FAKE_ACP is set: it speaks the shapes `agy acp` 1.5.16 was probed
// writing (initialize's capabilities, session/new's config options and
// model variants, -32000 signed out, the resume's and load's not-found
// answers, a load's replay before its answer, a steer answered by the
// earlier prompt's bare end_turn, a CYFR call titled "Run mcp_cyfr_…" and
// asked with session/request_permission id "1", and usage on the prompt's
// answer). It reaches CYFR's tools as Antigravity's server would, through
// the socket its session's `cyfr` entry names (`--socket NAME`), listing
// once a session answered, and keeps each session's files under its
// GEMINI_HOME, `.gemini` in the home: `brain/<id>/`, its database by its id
// and `annotations/<id>.pbtxt`, with each id added to the one index of
// every session (antigravity_words.go). A prompt's last text picks
// what the turn does:
//
//	slow      streams a first part, waits for a second prompt, then replies naming it
//	read      calls CYFR's `files` through the socket after its permission question
//	tools     replies with the names the socket listed to this process
//	params    replies with what the session, its config options and the prompt were given
//	own       runs its own tools, a person's server's, and two of CYFR's that are not asks
//	twice     replies in two messages, each with its own messageId
//	around    says words in two chunks, runs a tool of its own, then says more:
//	          with no messageId, as agy 1.5.16 writes its chunks (F4), and
//	          for OpenCode under a messageId of each model step's, as 2.4.1
//	          names them (F5)
//	strange   sends updates of kinds the driver does not use, another session's text
//	          and a request of its own, then replies with that request's answer code
//	missing   answers with a usage missing a count
//	nousage   answers with no usage
//	stop:R    answers with the stop reason R
//	rpcerr:C:M  answers with the JSON-RPC error C, its message M after a canary
//	die       ends the process with status 3
//	many      opens and ends forty calls of its own, then waits a moment before it replies
//	hang      opens two calls that never end
//	running   runs its own command and a person's server named cyfr, saying so while they run
//	callsteer opens a call of CYFR's, takes a steer while it is open, then calls the socket
//	agyfail:S writes the one chunk agy writes when its model service failed with status S, then end_turn
//	agyfailthen writes that chunk for UNAVAILABLE, then a word more
//	agyquoted writes the 503 chunk the probe recorded with words quoted before its close, then end_turn
//	activity  thinks between the reply's words under one message id, runs two
//	          commands of one name that end in reverse order and an edit whose
//	          change is past a detail's bound (fakeBigText), and starts a
//	          sub-agent: OpenCode passes on its child's words, reasoning and
//	          tool, each marked `_meta["opencode/child-session"]`, as 2.4.1
//	          does (S3 F5); Antigravity's child runs apart and shows nothing
//	          but the call that started it (S3, sub-agents)
//	pendingcall  runs a call it leaves pending at the turn's end, then replies
//	pendingdone  completes that call in this later prompt, then replies
//	question  asks the person in its reply (fakeQuestion), after its own
//	          tool's permission, as agy 1.5.16 and OpenCode 2.4.1 ask with no
//	          form capability advertised (S1 F1), and takes the session's
//	          next prompt as the answer, replying "A1: " and its words. It
//	          keeps the capabilities initialize named and the driver's whole
//	          answer to the permission in `$HOME/fake-question.json`
//
// It writes a canary to its standard error and its tier, which the driver
// must never pass on. FAKE_SIGNED_OUT answers every session and prompt
// -32000; FAKE_NEW_FAIL answers session/new -32603 in words naming a
// sign-in; FAKE_RESUME_OTHER answers a resume -32603 in other words;
// FAKE_RESUME_MISSING answers a resume as of a missing session even where
// it has one; FAKE_LOAD_OTHER answers a load -32603; FAKE_VERSION,
// FAKE_NO_RESUME and FAKE_NO_LOAD change initialize's answer, and
// FAKE_NO_APPEND drops its systemPrompt place; FAKE_MODE is the session's
// mode; FAKE_NO_LIST never lists; FAKE_STEER_FAIL answers a second prompt
// -32603 at once, and FAKE_CONFIRM_LATE confirms a steer only after the
// turn's call reached the socket; FAKE_BAD_SESSION answers session/new with
// no session id it could name; FAKE_HOLD keeps running after its input ends, until a
// TERM. Each cancel and TERM is logged in `$HOME/fake-acp.log`.
//
// FAKE_CURSOR makes it Cursor's (cursor_fake_test.go).
//
// FAKE_OPENCODE makes it OpenCode's ACP server instead, as `opencode acp`
// 2.4.1 was probed: its initialize, `ses_` session ids kept in one store of
// its own (`$HOME/.local/share/opencode/fake.db`, a line an id), a resume
// answered without the session's id, -32602 "Invalid params: session not
// found" for a resume and a load of a session it lacks, session/delete
// answered {} whether it had the session or not, the model's efforts
// offered only once it is selected, a second prompt mid-turn refused and a
// steer taken by `_session/steering` (`injected`, or `promptRequired` when
// no turn runs), usage with no cache writes and its output without its
// thoughts, and each tool call named. Its turns add:
//
//	execute   calls CYFR's `files` from inside its own tool `execute`
//	retry     says it retries its provider twice, then replies
//
//	executes  calls CYFR's `files` three times from inside one `execute`
//
// FAKE_DELETE_FAIL refuses a delete, FAKE_DELETE_KEEPS answers one {} and
// keeps the session, FAKE_NOTFOUND_OTHER answers a load with the not-found
// of another session, FAKE_STEER_NO_TURN answers every steer
// `promptRequired`, FAKE_CONFIRM_LATE answers a steer only after the
// turn's prompt, and FAKE_SILENT_SELECT and FAKE_SILENT_CLOSE never answer
// a model's selection or a close.
//
// Either way, run with its program's own words for its MCP servers
// (Antigravity's `mcp list`, OpenCode's `debug config --standalone`) it
// prints the servers FAKE_SERVERS names, a comma between each, as the
// program prints them, and FAKE_SERVERS_FAIL prints what is no listing.
const fakeEnv = "CYFR_FAKE_ACP"

const stderrCanary = "FAKE-STDERR-CANARY Antigravity writes this to its stderr"

// fakeBigText is the new text of the stand-ins' `activity` edit, 3,000
// bytes of three-byte characters: its change is past a detail's bound.
var fakeBigText = strings.Repeat("€", 1000)

// fakeQuestion is a stand-in's question asked in its reply, with its choices.
const fakeQuestion = "Which database should the export target?\n\n- [1] PostgreSQL\n- [2] SQLite"

func fakeACP() int {
	if os.Getenv("FAKE_CURSOR") != "" {
		return fakeCursor()
	}
	args := os.Args[1:]
	if words := " " + strings.Join(args, " "); strings.HasSuffix(words, " mcp list") || strings.HasSuffix(words, " debug config --standalone") {
		return fakeServers(strings.HasSuffix(words, " debug config --standalone"))
	}
	if len(args) == 0 || args[len(args)-1] != "acp" {
		fmt.Fprintln(os.Stderr, "fake-acp: not started as acp:", args)
		return 2
	}
	fmt.Fprintln(os.Stderr, stderrCanary)
	home := os.Getenv("HOME")
	oc := os.Getenv("FAKE_OPENCODE") != ""
	store := filepath.Join(home, ".local", "share", "opencode", "fake.db")
	if oc {
		_ = os.MkdirAll(filepath.Dir(store), 0o700)
	}
	cli := filepath.Join(geminiHome(home), "antigravity-cli")
	for _, dir := range []string{"brain", agySessionDatabases, "annotations"} {
		_ = os.MkdirAll(filepath.Join(cli, dir), 0o700)
	}
	logLine := func(what string) {
		f, err := os.OpenFile(filepath.Join(home, "fake-acp.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintln(f, what)
			f.Close()
		}
	}
	hold := os.Getenv("FAKE_HOLD") != ""
	if hold {
		terms := make(chan os.Signal, 1)
		signal.Notify(terms, syscall.SIGTERM)
		go func() {
			<-terms
			logLine("term")
			os.Exit(0)
		}()
	}

	out := bufio.NewWriter(os.Stdout)
	var mu sync.Mutex
	write := func(v any) {
		line, _ := json.Marshal(v)
		mu.Lock()
		defer mu.Unlock()
		out.Write(append(line, '\n'))
		out.Flush()
	}
	answer := func(id json.RawMessage, result any) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	failWith := func(id json.RawMessage, code int, message string) {
		write(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": code, "message": message}})
	}
	answers := map[string]chan json.RawMessage{}
	var answersMu sync.Mutex
	ask := func(id, method string, params any) json.RawMessage {
		ch := make(chan json.RawMessage, 1)
		answersMu.Lock()
		answers[id] = ch
		answersMu.Unlock()
		write(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
		return <-ch
	}

	var state struct {
		sync.Mutex
		session, socket string
		listed          []string
		opened          map[string]any
		set             []any
		current         map[string]string
		active          json.RawMessage
		steered         chan string
		callOpen        bool
		unconfirmed     json.RawMessage
		capabilities    map[string]any
	}
	state.current = map[string]string{"model": "fake-neon", "thought_level": "high", "mode": "default"}
	if oc {
		state.current = map[string]string{"model": "opencode/big-pickle", "effort": "default", "mode": "build"}
	}
	if mode := os.Getenv("FAKE_MODE"); mode != "" {
		state.current["mode"] = mode
	}
	update := func(u map[string]any) {
		write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": state.session, "update": u}})
	}
	chunk := func(text string) {
		update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}})
	}
	usage := map[string]any{"inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 30, "cachedWriteTokens": 0, "thoughtTokens": 5, "totalTokens": 150}
	if oc {
		usage = map[string]any{"inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 30, "thoughtTokens": 5, "totalTokens": 155}
	}
	// finish answers the prompt open now: a steer has moved it to the later.
	finish := func(result map[string]any) {
		state.Lock()
		id := state.active
		state.active = nil
		state.Unlock()
		if id != nil {
			answer(id, result)
		}
	}
	reply := func(text string) {
		half := len(text) / 2
		chunk(text[:half])
		chunk(text[half:])
		finish(map[string]any{"stopReason": "end_turn", "usage": usage})
	}
	options := func() []any {
		option := func(id, name string, values ...string) map[string]any {
			choices := []any{}
			for _, v := range values {
				choices = append(choices, map[string]any{"value": v, "name": strings.ToUpper(v[:1]) + v[1:]})
			}
			return map[string]any{"id": id, "name": name, "category": id, "type": "select", "currentValue": state.current[id], "options": choices}
		}
		if oc {
			model := option("model", "Model", "opencode/big-pickle", "probe/think")
			mode := option("mode", "Session Mode", "build", "plan")
			if state.current["model"] != "probe/think" {
				return []any{model, mode}
			}
			effort := option("effort", "Effort", "low", "high", "default")
			effort["category"] = "thought_level"
			return []any{model, effort, mode}
		}
		return []any{option("model", "Model", "fake-neon", "fake-flash"), option("thought_level", "Thinking Level", "low", "medium", "high", "xhigh"),
			option("mode", "Mode", "default", "accept-edits", "auto", "plan")}
	}
	sessionResult := func() map[string]any {
		if oc {
			return map[string]any{"sessionId": state.session, "configOptions": options()}
		}
		available := []any{}
		for _, id := range []string{"fake-neon-high", "fake-neon-xhigh", "fake-neon-low", "fake-flash"} {
			available = append(available, map[string]any{"modelId": id, "name": id})
		}
		return map[string]any{"sessionId": state.session, "models": map[string]any{"availableModels": available, "currentModelId": "fake-neon-high"},
			"configOptions": options(), "_meta": map[string]any{"antigravity": map[string]any{"tier": map[string]any{"name": "FAKE-TIER-CANARY"}}}}
	}
	// listSoon lists the socket's tools once the session has answered, as
	// Antigravity's server for it does.
	listSoon := func(params map[string]any) {
		servers, _ := params["mcpServers"].([]any)
		for _, s := range servers {
			entry, _ := s.(map[string]any)
			argv, _ := entry["args"].([]any)
			if len(argv) == 2 && argv[0] == "--socket" {
				state.socket = fmt.Sprint(argv[1])
			}
		}
		if os.Getenv("FAKE_NO_LIST") != "" || state.socket == "" {
			return
		}
		socket := state.socket
		go func() {
			time.Sleep(20 * time.Millisecond) // sleep-ok: the listing comes after the session's answer, as Antigravity's does
			var listing toolsock.Listing
			if toolsock.Ask(socket, toolsock.Request{Op: "list"}, &listing) == nil {
				state.Lock()
				state.listed = nil
				for _, t := range listing.Tools {
					state.listed = append(state.listed, t.Name)
				}
				state.Unlock()
			}
		}()
	}
	var files func(id string)
	files = func(id string) {
		_ = os.MkdirAll(filepath.Join(cli, "brain", id, ".system_generated", "logs"), 0o700)
		_ = os.WriteFile(filepath.Join(cli, "brain", id, ".system_generated", "logs", "transcript.jsonl"), []byte("FAKE-TRANSCRIPT\n"), 0o600)
		_ = os.WriteFile(filepath.Join(cli, agySessionDatabases, id+".db"), []byte("FAKE-DB"), 0o600)
		_ = os.WriteFile(filepath.Join(cli, "annotations", id+".pbtxt"), []byte("FAKE-ANNOTATION"), 0o600)
		index, _ := os.OpenFile(filepath.Join(cli, agySummaryIndex), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		fmt.Fprintln(index, id)
		index.Close()
	}
	stored := func() []string {
		held, _ := os.ReadFile(store)
		return strings.Fields(string(held))
	}
	exists := func(id string) bool {
		if oc {
			for _, held := range stored() {
				if held == id {
					return true
				}
			}
			return false
		}
		_, err := os.Stat(filepath.Join(cli, agySessionDatabases, id+".db"))
		return err == nil
	}
	if oc {
		files = func(id string) {
			f, _ := os.OpenFile(store, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
			fmt.Fprintln(f, id)
			f.Close()
		}
	}
	notFound := func(id json.RawMessage, session string) {
		if oc {
			failWith(id, -32602, "Invalid params: session not found: "+session)
			return
		}
		failWith(id, -32002, "Session not found: "+session)
	}

	runTurn := func(words string, params map[string]any) {
		// A prompt after the session's question is its answer, as agy reads
		// it (F1).
		asked := filepath.Join(home, "fake-asked-"+state.session)
		if _, err := os.Stat(asked); err == nil {
			_ = os.Remove(asked)
			reply("A1: " + words)
			return
		}
		switch {
		case strings.Contains(words, "question"):
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_write", "title": "Write export.sql", "kind": "edit", "status": "pending"}
			update(call)
			permission := ask("q2", "session/request_permission", map[string]any{"sessionId": state.session, "toolCall": call,
				"options": []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}, map[string]any{"optionId": "deny", "name": "Deny", "kind": "reject_once"}}})
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call_write", "status": "completed"})
			_ = os.WriteFile(asked, nil, 0o600)
			state.Lock()
			line, _ := json.Marshal(map[string]any{"capabilities": state.capabilities, "permission": permission})
			state.Unlock()
			_ = os.WriteFile(filepath.Join(home, "fake-question.json"), line, 0o600)
			reply(fakeQuestion)
		case strings.HasPrefix(words, "agyfail:"):
			// As agy 1.5.16 ends a turn its model service failed, on the
			// API-key path: one chunk, then end_turn with no usage.
			chunk(agyFailureText(strings.TrimPrefix(words, "agyfail:")))
			finish(map[string]any{"stopReason": "end_turn"})
		case words == "agyquoted":
			chunk(strings.Replace(agyRecorded503, "[]\n", "[] [quoted for context]\n", 1))
			finish(map[string]any{"stopReason": "end_turn"})
		case words == "agyfailthen":
			chunk(agyFailureText("UNAVAILABLE"))
			chunk(" and more")
			finish(map[string]any{"stopReason": "end_turn", "usage": usage})
		case oc && strings.Contains(words, "executes"):
			// Three calls of CYFR's, one after another, inside one execute.
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_execs", "name": "execute", "title": "execute", "status": "in_progress",
				"kind": "other", "rawInput": map[string]any{"code": "for (const n of [1, 2, 3]) await tools.cyfr.files({n})"}})
			answers := []string{}
			for n := 1; n <= 3; n++ {
				var result toolsock.Result
				if toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(fmt.Sprintf(`{"n":%d}`, n))}, &result) != nil {
					result.Text = "unreachable"
				}
				answers = append(answers, result.Text)
			}
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call_execs", "status": "completed"})
			reply("answered " + strings.Join(answers, ","))
		case oc && strings.Contains(words, "execute"):
			// OpenCode calls an MCP server's tool only from JavaScript inside
			// its own tool `execute`, which it shows with its code.
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_exec", "name": "execute", "title": "execute", "status": "pending",
				"kind": "other", "rawInput": map[string]any{}}
			update(call)
			call["sessionUpdate"], call["status"] = "tool_call_update", "in_progress"
			call["rawInput"] = map[string]any{"code": "return await tools.cyfr.files({path: 'notes.txt'})"}
			update(call)
			var result toolsock.Result
			if err := toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"notes.txt"}`)}, &result); err != nil {
				result.Text = "unreachable"
			}
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call_exec", "status": "completed"})
			reply(fmt.Sprintf("the tool answered %q, error %v", result.Text, result.IsError))
		case oc && strings.Contains(words, "retry"):
			for attempt := 2; attempt <= 3; attempt++ {
				update(map[string]any{"sessionUpdate": "session_info_update", "_meta": map[string]any{"opencode/retry": nil}})
				update(map[string]any{"sessionUpdate": "session_info_update", "_meta": map[string]any{"opencode/retry": map[string]any{"attempt": attempt,
					"error": map[string]any{"type": "provider.transport", "message": "RETRY-CANARY Can't reach the provider"}}}})
			}
			reply("reached it")
		case strings.Contains(words, "pendingcall"), strings.Contains(words, "pendingdone"):
			// As agy 1.5.16 left its ask_question on the account path (S1
			// F1): the call runs, is left pending at the turn's end, and is
			// completed in the next prompt.
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_pending", "name": "ask_question", "kind": "other",
				"title": "Run ask_question", "status": "in_progress", "rawInput": map[string]any{"questions": []any{"Which database?"}}}
			if strings.Contains(words, "pendingcall") {
				update(call)
				call["sessionUpdate"], call["status"] = "tool_call_update", "pending"
				update(call)
				reply("Which database should the export target?")
				break
			}
			call["sessionUpdate"] = "tool_call_update"
			update(call)
			call["status"] = "completed"
			update(call)
			reply("I will target PostgreSQL.")
		case strings.Contains(words, "activity"):
			say := func(kind, text string) {
				update(map[string]any{"sessionUpdate": kind, "messageId": "m_act", "content": map[string]any{"type": "text", "text": text}})
			}
			say("agent_thought_chunk", "THINK-ONE ")
			say("agent_message_chunk", "The member ")
			say("agent_thought_chunk", "THINK-TWO")
			run := func(id, command string) map[string]any {
				call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": id, "name": "shell", "title": "shell", "kind": "execute",
					"status": "pending", "rawInput": map[string]any{}}
				update(call)
				// Antigravity's run_command names it CommandLine, with a
				// toolSummary of its own (F4); OpenCode's shell `command`.
				input := map[string]any{"command": command, "cwd": home}
				if !oc {
					input = map[string]any{"CommandLine": command, "WaitMsBeforeAsync": 3000, "toolSummary": "Run it"}
				}
				call["sessionUpdate"], call["status"], call["rawInput"] = "tool_call_update", "in_progress", input
				update(call)
				return call
			}
			first, second := run("call_twin_a", "echo A"), run("call_twin_b", "echo B")
			for _, call := range []map[string]any{second, first} {
				call["status"] = "completed"
				update(call)
			}
			edit := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_edit", "name": "edit", "title": "edit", "kind": "edit",
				"status": "in_progress", "rawInput": map[string]any{"path": "big.txt"}}
			update(edit)
			edit["sessionUpdate"], edit["status"] = "tool_call_update", "completed"
			edit["content"] = []any{map[string]any{"type": "diff", "path": "big.txt", "oldText": "", "newText": fakeBigText}}
			update(edit)
			if oc {
				task := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_task", "name": "subagent", "title": "subagent", "kind": "think",
					"status": "pending", "rawInput": map[string]any{}}
				update(task)
				task["sessionUpdate"], task["status"] = "tool_call_update", "in_progress"
				task["rawInput"] = map[string]any{"agent": "general", "description": "child", "prompt": "CHILD-PROMPT"}
				update(task)
				mark := map[string]any{"opencode/child-session": map[string]any{"id": "ses_child", "parentID": state.session, "depth": 1, "title": "child"}}
				for _, u := range []map[string]any{
					{"sessionUpdate": "agent_thought_chunk", "messageId": "m_child", "content": map[string]any{"type": "text", "text": "CHILD-THOUGHT"}},
					{"sessionUpdate": "tool_call", "toolCallId": "ses_child:call_c", "name": "shell", "title": "child: shell", "kind": "execute",
						"status": "in_progress", "rawInput": map[string]any{"command": "echo CHILD-RAN"}},
					{"sessionUpdate": "tool_call_update", "toolCallId": "ses_child:call_c", "status": "completed",
						"content": []any{map[string]any{"type": "diff", "path": "child.txt", "oldText": "", "newText": "CHILD-CHANGE"}}},
					{"sessionUpdate": "agent_message_chunk", "messageId": "m_child", "content": map[string]any{"type": "text", "text": "CHILD-WORDS"}},
				} {
					u["_meta"] = mark
					update(u)
				}
				task["status"] = "completed"
				task["content"] = []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "CHILD-RESULT"}}}
				update(task)
			} else {
				task := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_task", "name": "invoke_subagent", "title": "Run invoke_subagent",
					"kind": "other", "status": "in_progress", "rawInput": map[string]any{"Prompt": "CHILD-PROMPT", "Role": "Reader", "TypeName": "research"}}
				update(task)
				task["sessionUpdate"], task["status"] = "tool_call_update", "completed"
				update(task)
			}
			say("agent_message_chunk", "said its own words.")
			finish(map[string]any{"stopReason": "end_turn", "usage": usage})
		case strings.Contains(words, "slow"):
			chunk("Starting. ")
			select {
			case steered := <-state.steered:
				reply("Read the steer: " + steered)
			case <-time.After(3 * time.Second):
				reply("no steer came")
			}
		case strings.Contains(words, "read"):
			// Antigravity shows the call's arguments with a toolSummary of its
			// own, which it drops before it calls the server.
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_1", "name": "mcp_cyfr_files", "status": "in_progress",
				"kind": "other", "title": "Run mcp_cyfr_files", "rawInput": json.RawMessage(`{"path":"notes.txt","count":12345678901234567890,"toolSummary":"Read notes"}`)}
			update(call)
			call["sessionUpdate"], call["status"] = "tool_call_update", "pending"
			update(call)
			permission := ask("1", "session/request_permission", map[string]any{"sessionId": state.session, "toolCall": call,
				"options": []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}, map[string]any{"optionId": "deny", "name": "Deny", "kind": "reject_once"}}})
			var p struct {
				Result struct {
					Outcome struct {
						Outcome  string `json:"outcome"`
						OptionID string `json:"optionId"`
					} `json:"outcome"`
				} `json:"result"`
			}
			_ = json.Unmarshal(permission, &p)
			var result toolsock.Result
			if err := toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"notes.txt","count":12345678901234567890}`)}, &result); err != nil {
				result.Text = "unreachable"
			}
			call["status"] = "completed"
			update(call)
			reply(fmt.Sprintf("permission %s %s; the tool answered %q, error %v", p.Result.Outcome.Outcome, p.Result.Outcome.OptionID, result.Text, result.IsError))
		case strings.Contains(words, "callsteer"):
			// A call of CYFR's opens, and a steer comes while it is open: the
			// call is open before the text, so a steer sent once the text is
			// read finds it open.
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_2", "name": "mcp_cyfr_files", "status": "in_progress",
				"kind": "other", "title": "Run mcp_cyfr_files", "rawInput": json.RawMessage(`{"path":"a.txt","toolSummary":"Read a"}`)}
			update(call)
			state.Lock()
			state.callOpen = true
			state.Unlock()
			chunk("Starting. ")
			var steer string
			select {
			case steer = <-state.steered:
			case <-time.After(5 * time.Second):
			}
			results := make(chan toolsock.Result, 1)
			go func() {
				var result toolsock.Result
				if toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"a.txt"}`)}, &result) != nil {
					result.Text = "unreachable"
				}
				results <- result
			}()
			state.Lock()
			late := state.unconfirmed
			state.unconfirmed = nil
			state.Unlock()
			if late != nil {
				time.Sleep(200 * time.Millisecond) // sleep-ok: the call reaches the driver before the steer is confirmed
				answer(late, map[string]any{"stopReason": "end_turn"})
			}
			result := <-results
			state.Lock()
			state.callOpen = false
			state.Unlock()
			call["sessionUpdate"], call["status"] = "tool_call_update", "completed"
			update(call)
			reply(fmt.Sprintf("Read the steer: %s; the tool answered %q", steer, result.Text))
		case strings.Contains(words, "tools"):
			state.Lock()
			listed := strings.Join(state.listed, ",")
			state.Unlock()
			reply("listed " + listed)
		case strings.Contains(words, "params"):
			state.Lock()
			given, _ := json.Marshal(map[string]any{"session": state.opened, "set": state.set, "prompt": params})
			state.Unlock()
			reply(string(given))
		case strings.Contains(words, "many"):
			// Forty calls of its own, half of a kind a stub server's call
			// takes, each opened and ended.
			for i := 0; i < 40; i++ {
				kind := "execute"
				if i%2 == 1 {
					kind = "other"
				}
				call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": fmt.Sprintf("call_many_%d", i), "status": "in_progress",
					"kind": kind, "title": "Run x", "rawInput": map[string]any{"n": i, "toolSummary": "x"}}
				update(call)
				call["sessionUpdate"], call["status"] = "tool_call_update", "completed"
				update(call)
			}
			chunk("calls done. ")
			time.Sleep(500 * time.Millisecond) // sleep-ok: the turn stays open while the test looks at what the driver holds
			reply("done")
		case strings.Contains(words, "hang"):
			// Two calls that never end: its own command and one of a stub
			// server's kind.
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_hang_run", "status": "in_progress", "kind": "execute", "title": "Run x", "rawInput": map[string]any{}})
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_hang_other", "status": "in_progress", "kind": "other", "title": "Run y", "rawInput": map[string]any{"y": 1}})
			chunk("hanging. ")
			time.Sleep(5 * time.Second) // sleep-ok: a turn whose calls are still open when the session closes
			reply("done")
		case strings.Contains(words, "running"):
			// Its own command, and a person's server named cyfr through its
			// own call_mcp_tool, each running while the turn says so.
			calls := []map[string]any{
				{"sessionUpdate": "tool_call", "toolCallId": "call_run", "status": "in_progress", "kind": "execute", "title": "Run ls /home/x", "rawInput": map[string]any{"CommandLine": "ls"}},
				{"sessionUpdate": "tool_call", "toolCallId": "call_theirs", "status": "in_progress", "kind": "execute", "title": "MCP Tool files",
					"rawInput": map[string]any{"ServerName": "cyfr", "ToolName": "files", "Arguments": map[string]any{"path": "x"}}},
			}
			for _, call := range calls {
				update(call)
			}
			chunk("running. ")
			for _, call := range calls {
				call["sessionUpdate"], call["status"] = "tool_call_update", "completed"
				update(call)
			}
			reply("done")
		case strings.Contains(words, "own"):
			for _, call := range []map[string]any{
				{"toolCallId": "call_read", "kind": "read", "title": "File notes.md", "rawInput": map[string]any{"Path": "/home/x/notes.md"}},
				{"toolCallId": "call_mine", "kind": "execute", "title": "MCP Tool reverse_text", "rawInput": map[string]any{"ServerName": "mine", "ToolName": "reverse_text"}},
				{"toolCallId": "call_other", "kind": "other", "title": "Run mine_tool", "rawInput": map[string]any{}},
				{"toolCallId": "call_cyfr", "kind": "other", "title": "Run mcp_cyfr_files", "rawInput": map[string]any{"path": "x"}},
				{"toolCallId": "call_cyfr_by_name", "kind": "execute", "title": "MCP Tool files", "rawInput": map[string]any{"ServerName": "cyfr", "ToolName": "files"}},
				{"toolCallId": "call_odd", "kind": "execute", "title": "MCP Tool /home/x/secret", "rawInput": map[string]any{"ServerName": "../home x", "ToolName": "t"}},
				{"toolCallId": "call_path", "kind": "/home/x/folder", "title": "File /home/x/folder/notes.md", "rawInput": map[string]any{}},
			} {
				call["sessionUpdate"], call["status"] = "tool_call", "in_progress"
				update(call)
				call["sessionUpdate"], call["status"] = "tool_call_update", "pending"
				update(call)
				call["status"] = "in_progress"
				update(call)
				// Antigravity ends a call with its content, a list.
				call["status"] = "completed"
				call["content"] = []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "done"}}}
				update(call)
			}
			// A call first seen already failed, its content given.
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_failed", "status": "failed", "kind": "other",
				"title": "Run broken_tool", "rawInput": map[string]any{},
				"content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "it failed"}}}})
			reply("ran them")
		case strings.Contains(words, "around"):
			say := func(step, text string) {
				u := map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}}
				if oc {
					u["messageId"] = step
				}
				update(u)
			}
			say("msg_step_1", "Before ")
			say("msg_step_1", "the tool.")
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_around", "title": "read", "kind": "read",
				"status": "pending", "rawInput": map[string]any{}}
			update(call)
			call["sessionUpdate"], call["status"], call["rawInput"] = "tool_call_update", "in_progress", map[string]any{"path": "a.txt"}
			update(call)
			call["status"] = "completed"
			update(call)
			say("msg_step_2", "After it.")
			finish(map[string]any{"stopReason": "end_turn", "usage": usage})
		case strings.Contains(words, "twice"):
			update(map[string]any{"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": map[string]any{"type": "text", "text": "One."}})
			update(map[string]any{"sessionUpdate": "agent_message_chunk", "messageId": "m2", "content": map[string]any{"type": "text", "text": "Two."}})
			finish(map[string]any{"stopReason": "end_turn", "usage": usage})
		case strings.Contains(words, "strange"):
			update(map[string]any{"sessionUpdate": "plan", "entries": []any{map[string]any{"content": "PLAN-CANARY"}}})
			update(map[string]any{"sessionUpdate": "some_new_kind", "text": "NEW-KIND-CANARY"})
			update(map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "THOUGHT-CANARY"}})
			update(map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "USER-CANARY"}})
			write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": "00000000-0000-4000-8000-000000000000",
				"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "OTHER-SESSION-CANARY"}}}})
			write(map[string]any{"jsonrpc": "2.0", "method": "some/notice", "params": map[string]any{}})
			fs := ask("7", "fs/read_text_file", map[string]any{"sessionId": state.session, "path": "/etc/passwd"})
			var a struct {
				Error struct {
					Code int `json:"code"`
				} `json:"error"`
			}
			_ = json.Unmarshal(fs, &a)
			reply(fmt.Sprintf("fs answered %d", a.Error.Code))
		case strings.Contains(words, "missing"):
			chunk("one count missing")
			finish(map[string]any{"stopReason": "end_turn", "usage": map[string]any{"inputTokens": 100, "outputTokens": 20, "cachedReadTokens": 30}})
		case strings.Contains(words, "nousage"):
			chunk("none counted")
			finish(map[string]any{"stopReason": "end_turn"})
		case strings.HasPrefix(words, "stop:"):
			chunk("stopping")
			finish(map[string]any{"stopReason": strings.TrimPrefix(words, "stop:"), "usage": usage})
		case strings.HasPrefix(words, "rpcerr:"):
			parts := strings.SplitN(words, ":", 3)
			var code int
			fmt.Sscan(parts[1], &code)
			state.Lock()
			id := state.active
			state.active = nil
			state.Unlock()
			failWith(id, code, "HARNESS-WORDS "+parts[2])
		default:
			reply("ok")
		}
	}

	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	for {
		line, err := in.ReadBytes('\n')
		if len(line) > 0 {
			var m struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
				Params map[string]any  `json:"params"`
			}
			if json.Unmarshal(line, &m) != nil {
				continue
			}
			str := func(name string) string { s, _ := m.Params[name].(string); return s }
			signedOut := os.Getenv("FAKE_SIGNED_OUT") != ""
			if m.Method == "initialize" {
				state.Lock()
				state.capabilities, _ = m.Params["clientCapabilities"].(map[string]any)
				state.Unlock()
			}
			switch {
			case m.Method == "" && len(m.ID) > 0:
				answersMu.Lock()
				ch := answers[idKey(m.ID)]
				delete(answers, idKey(m.ID))
				answersMu.Unlock()
				if ch != nil {
					ch <- json.RawMessage(line)
				}
			case m.Method == "initialize" && os.Getenv("FAKE_INIT_UNREADABLE") != "":
				answer(m.ID, "ready")
			case m.Method == "initialize" && oc:
				version := "2.4.1"
				if v := os.Getenv("FAKE_VERSION"); v != "" {
					version = v
				}
				answer(m.ID, map[string]any{"protocolVersion": 1, "agentCapabilities": map[string]any{"loadSession": true,
					"mcpCapabilities":     map[string]any{"http": true, "sse": false},
					"promptCapabilities":  map[string]any{"embeddedContext": true, "image": true},
					"sessionCapabilities": map[string]any{"close": map[string]any{}, "delete": map[string]any{}, "list": map[string]any{}, "resume": map[string]any{}}},
					"authMethods": []any{map[string]any{"id": "opencode-login", "name": "Login with opencode"}},
					"_meta":       map[string]any{"steering": map[string]any{"supported": true}},
					"agentInfo":   map[string]any{"name": "OpenCode", "version": version}})
			case m.Method == "initialize":
				version := "1.5.16"
				if v := os.Getenv("FAKE_VERSION"); v != "" {
					version = v
				}
				sessionCaps := map[string]any{"close": map[string]any{}, "load": map[string]any{}, "list": map[string]any{}}
				if os.Getenv("FAKE_NO_RESUME") == "" {
					sessionCaps["resume"] = map[string]any{}
				}
				caps := map[string]any{"loadSession": os.Getenv("FAKE_NO_LOAD") == "", "promptCapabilities": map[string]any{"image": true, "audio": false, "embeddedContext": true},
					"sessionCapabilities": sessionCaps, "auth": map[string]any{"logout": map[string]any{}},
					"_meta": map[string]any{"antigravity": map[string]any{"tier": true, "systemPrompt": map[string]any{"append": os.Getenv("FAKE_NO_APPEND") == ""}}}}
				answer(m.ID, map[string]any{"protocolVersion": 1, "agentCapabilities": caps,
					"agentInfo":   map[string]any{"name": "Antigravity ACP Server", "version": version},
					"authMethods": []any{map[string]any{"id": "oauth-personal", "name": "Log in with Google"}}})
			case signedOut && strings.HasPrefix(m.Method, "session/") && m.Method != "session/cancel":
				failWith(m.ID, -32000, "Authentication required")
			case m.Method == "session/new":
				if os.Getenv("FAKE_NEW_FAIL") != "" {
					failWith(m.ID, -32603, "HARNESS-WORDS Authentication required: the sign-in could not be refreshed")
					continue
				}
				state.Lock()
				state.session = brainwire.NewUUID()
				if oc {
					state.session = "ses_" + strings.ReplaceAll(brainwire.NewUUID(), "-", "")[:26]
				}
				state.opened = m.Params
				state.Unlock()
				files(state.session)
				if os.Getenv("FAKE_BAD_SESSION") != "" {
					result := sessionResult()
					result["sessionId"] = "session one"
					answer(m.ID, result)
					continue
				}
				answer(m.ID, sessionResult())
				listSoon(m.Params)
			case m.Method == "session/resume":
				id := str("sessionId")
				switch {
				case os.Getenv("FAKE_RESUME_OTHER") != "":
					failWith(m.ID, -32603, "Internal error")
				case oc && !exists(id):
					notFound(m.ID, id)
				case !exists(id) || os.Getenv("FAKE_RESUME_MISSING") != "":
					failWith(m.ID, -32603, "Failed to read session "+id+"; retry, or load it with session/load")
				default:
					state.Lock()
					state.session, state.opened = id, m.Params
					state.Unlock()
					result := sessionResult()
					if oc {
						delete(result, "sessionId")
					}
					answer(m.ID, result)
					listSoon(m.Params)
				}
			case m.Method == "session/load":
				id := str("sessionId")
				switch {
				case os.Getenv("FAKE_NOTFOUND_OTHER") != "":
					notFound(m.ID, "ses_"+strings.Repeat("z", 26))
				case os.Getenv("FAKE_LOAD_OTHER") != "":
					failWith(m.ID, -32603, "Internal error")
				case !exists(id):
					notFound(m.ID, id)
				default:
					state.Lock()
					state.session, state.opened = id, m.Params
					state.Unlock()
					update(map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "REPLAYED-USER"}})
					update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "REPLAYED-CANARY"}})
					update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_old", "status": "completed", "kind": "read", "title": "File old.md"})
					answer(m.ID, sessionResult())
					update(map[string]any{"sessionUpdate": "session_info_update", "title": "a title"})
					listSoon(m.Params)
				}
			case m.Method == "session/set_config_option" && os.Getenv("FAKE_SILENT_SELECT") != "" && str("configId") == "model":
			case m.Method == "session/close" && os.Getenv("FAKE_SILENT_CLOSE") != "":
			case m.Method == "session/set_config_option":
				id, value := str("configId"), str("value")
				state.Lock()
				state.set = append(state.set, map[string]any{"configId": id, "value": value})
				state.current[id] = value
				state.Unlock()
				answer(m.ID, map[string]any{"configOptions": options()})
			case m.Method == "session/delete" && oc:
				id := str("sessionId")
				switch {
				case os.Getenv("FAKE_DELETE_FAIL") != "":
					failWith(m.ID, -32603, "HARNESS-WORDS Internal error: the store is locked")
				case os.Getenv("FAKE_DELETE_KEEPS") != "":
					answer(m.ID, map[string]any{})
				default:
					kept := []string{}
					for _, held := range stored() {
						if held != id {
							kept = append(kept, held)
						}
					}
					_ = os.WriteFile(store, []byte(strings.Join(kept, "\n")+"\n"), 0o600)
					logLine("delete " + id)
					answer(m.ID, map[string]any{})
				}
			case m.Method == "_session/steering" && oc:
				words := ""
				prompt, _ := m.Params["prompt"].([]any)
				for _, b := range prompt {
					if block, _ := b.(map[string]any); block["type"] == "text" {
						words = fmt.Sprint(block["text"])
					}
				}
				state.Lock()
				running := state.active != nil
				steered := state.steered
				state.Unlock()
				switch {
				case os.Getenv("FAKE_STEER_FAIL") != "":
					failWith(m.ID, -32603, "HARNESS-WORDS the steer was not taken")
				case !running || os.Getenv("FAKE_STEER_NO_TURN") != "":
					answer(m.ID, map[string]any{"outcome": "promptRequired", "reason": "noRunningTurn"})
				case os.Getenv("FAKE_CONFIRM_LATE") != "":
					// The steer is taken, and said so only once the turn's
					// prompt has been answered.
					id := m.ID
					steered <- words
					go func() {
						for {
							state.Lock()
							done := state.active == nil
							state.Unlock()
							if done {
								break
							}
							time.Sleep(10 * time.Millisecond) // sleep-ok: the stand-in's own wait for its turn's end, read by a bounded poll
						}
						answer(id, map[string]any{"outcome": "injected"})
					}()
				default:
					answer(m.ID, map[string]any{"outcome": "injected"})
					steered <- words
				}
			case m.Method == "session/prompt":
				words := ""
				prompt, _ := m.Params["prompt"].([]any)
				for _, b := range prompt {
					if block, _ := b.(map[string]any); block["type"] == "text" {
						words = fmt.Sprint(block["text"])
					}
				}
				if words == "die" {
					return 3
				}
				state.Lock()
				earlier := state.active
				if earlier != nil && oc {
					state.Unlock()
					failWith(m.ID, -32603, "Internal error: Session already has an active ACP prompt: "+state.session)
					continue
				}
				if earlier != nil {
					if os.Getenv("FAKE_STEER_FAIL") != "" {
						state.Unlock()
						failWith(m.ID, -32603, "HARNESS-WORDS the steer was not taken")
						continue
					}
					// The earlier prompt answers at once, with the counts so far
					// while a call is open and none otherwise, as Antigravity
					// 1.5.16 was measured answering; this one carries the turn
					// on. FAKE_CONFIRM_LATE confirms only once the turn's call
					// has reached the driver, an order the driver must take
					// though Antigravity was not seen to make it.
					state.active = m.ID
					open := state.callOpen
					late := os.Getenv("FAKE_CONFIRM_LATE") != ""
					if late {
						state.unconfirmed = earlier
					}
					state.Unlock()
					switch {
					case late:
					case open:
						answer(earlier, map[string]any{"stopReason": "end_turn", "usage": map[string]any{"inputTokens": 98, "outputTokens": 9,
							"cachedReadTokens": 3, "cachedWriteTokens": 0, "thoughtTokens": 2, "totalTokens": 110}})
					default:
						answer(earlier, map[string]any{"stopReason": "end_turn"})
					}
					state.steered <- words
					continue
				}
				state.active = m.ID
				state.steered = make(chan string, 1)
				state.Unlock()
				params := m.Params
				go runTurn(words, params)
			case m.Method == "session/cancel":
				logLine("cancel")
				finish(map[string]any{"stopReason": "cancelled"})
			case m.Method == "session/close":
				answer(m.ID, map[string]any{})
			case len(m.ID) > 0:
				failWith(m.ID, -32601, "Method not found: "+m.Method)
			}
		}
		if err != nil {
			if hold {
				time.Sleep(time.Hour) // sleep-ok: a program that does not end when its input does, until its TERM
			}
			return 0
		}
	}
}

// geminiHome is where the stand-in, as Antigravity, keeps its sessions and its sign-in.
func geminiHome(home string) string {
	if dir := os.Getenv("GEMINI_HOME"); dir != "" {
		return dir
	}
	return filepath.Join(home, ".gemini")
}

// fakeServers prints the servers FAKE_SERVERS names as the program lists
// its own: OpenCode's configuration documents (`debug config`), or
// Antigravity's table (`mcp list`).
func fakeServers(openCode bool) int {
	if os.Getenv("FAKE_SERVERS_FAIL") != "" {
		fmt.Println("something that is no listing")
		return 0
	}
	var names []string
	if listed := os.Getenv("FAKE_SERVERS"); listed != "" {
		names = strings.Split(listed, ",")
	}
	if openCode {
		servers := map[string]any{}
		for _, n := range names {
			servers[n] = map[string]any{"type": "local", "command": []string{"x"}, "environment": map[string]any{"TOKEN": "***"}}
		}
		docs := []any{map[string]any{"type": "document", "path": "/home/x/.config/opencode/opencode.json", "info": map[string]any{"mcp": map[string]any{"servers": servers}}},
			map[string]any{"type": "directory", "path": "/home/x/.config/opencode"}}
		line, _ := json.MarshalIndent(docs, "", "  ")
		fmt.Println(string(line))
		return 0
	}
	if len(names) == 0 {
		fmt.Println("No MCP servers configured.")
		return 0
	}
	fmt.Println("NAME  TYPE   STATUS   COMMAND/URL")
	for _, n := range names {
		fmt.Printf("%s  stdio  enabled  node /x\n", n)
	}
	return 0
}

// agyFailureText is the chunk agy 1.5.16 writes for a model request that
// failed with status, as the probe saw it for 429, 503, 401 and 500.
func agyFailureText(status string) string {
	return "\n⚠ agent executor error: generating and executing: Error 503, Message: HARNESS-WORDS The model is overloaded. Please try again later., Status: " + status + ", Details: []\n"
}

// agyRecorded503 is the chunk agy 1.5.16 wrote for a 503, as the probe
// recorded it (antigravity/f6/).
const agyRecorded503 = "\n⚠ agent executor error: generating and executing: Error 503, Message: The model is overloaded. Please try again later., Status: UNAVAILABLE, Details: []\n"
