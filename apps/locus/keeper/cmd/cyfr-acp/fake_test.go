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
// GEMINI_HOME, `.gemini` in the home: `brain/<id>/`, `conversations/<id>.db`
// and `annotations/<id>.pbtxt`, with each id added to the one index of
// every session, `conversation_summaries.db`. A prompt's last text picks
// what the turn does:
//
//	slow      streams a first part, waits for a second prompt, then replies naming it
//	read      calls CYFR's `files` through the socket after its permission question
//	tools     replies with the names the socket listed to this process
//	params    replies with what the session, its config options and the prompt were given
//	own       runs its own tools, a person's server's, and two of CYFR's that are not asks
//	twice     replies in two messages, each with its own messageId
//	strange   sends updates of kinds the driver does not use, another session's text
//	          and a request of its own, then replies with that request's answer code
//	missing   answers with a usage missing a count
//	nousage   answers with no usage
//	stop:R    answers with the stop reason R
//	rpcerr:C:M  answers with the JSON-RPC error C, its message M after a canary
//	die       ends the process with status 3
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
// -32603 at once; FAKE_HOLD keeps running after its input ends, until a
// TERM. Each cancel and TERM is logged in `$HOME/fake-acp.log`.
const fakeEnv = "CYFR_FAKE_ACP"

const stderrCanary = "FAKE-STDERR-CANARY Antigravity writes this to its stderr"

func fakeACP() int {
	args := os.Args[1:]
	if len(args) == 0 || args[len(args)-1] != "acp" {
		fmt.Fprintln(os.Stderr, "fake-acp: not started as acp:", args)
		return 2
	}
	fmt.Fprintln(os.Stderr, stderrCanary)
	home := os.Getenv("HOME")
	cli := filepath.Join(geminiHome(home), "antigravity-cli")
	for _, dir := range []string{"brain", "conversations", "annotations"} {
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
	}
	state.current = map[string]string{"model": "fake-neon", "thought_level": "high", "mode": "default"}
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
		return []any{option("model", "Model", "fake-neon", "fake-flash"), option("thought_level", "Thinking Level", "low", "medium", "high", "xhigh"),
			option("mode", "Mode", "default", "accept-edits", "auto", "plan")}
	}
	sessionResult := func() map[string]any {
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
			if entry["name"] == "cyfr" && len(argv) == 2 {
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
	files := func(id string) {
		_ = os.MkdirAll(filepath.Join(cli, "brain", id, ".system_generated", "logs"), 0o700)
		_ = os.WriteFile(filepath.Join(cli, "brain", id, ".system_generated", "logs", "transcript.jsonl"), []byte("FAKE-TRANSCRIPT\n"), 0o600)
		_ = os.WriteFile(filepath.Join(cli, "conversations", id+".db"), []byte("FAKE-DB"), 0o600)
		_ = os.WriteFile(filepath.Join(cli, "annotations", id+".pbtxt"), []byte("FAKE-ANNOTATION"), 0o600)
		index, _ := os.OpenFile(filepath.Join(cli, "conversation_summaries.db"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		fmt.Fprintln(index, id)
		index.Close()
	}
	exists := func(id string) bool {
		_, err := os.Stat(filepath.Join(cli, "conversations", id+".db"))
		return err == nil
	}

	runTurn := func(words string, params map[string]any) {
		switch {
		case strings.Contains(words, "slow"):
			chunk("Starting. ")
			select {
			case steered := <-state.steered:
				reply("Read the steer: " + steered)
			case <-time.After(3 * time.Second):
				reply("no steer came")
			}
		case strings.Contains(words, "read"):
			call := map[string]any{"sessionUpdate": "tool_call", "toolCallId": "call_1", "name": "mcp_cyfr_files", "status": "in_progress",
				"kind": "other", "title": "Run mcp_cyfr_files", "rawInput": map[string]any{"path": "notes.txt", "toolSummary": "Read notes"}}
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
		case strings.Contains(words, "own"):
			for _, call := range []map[string]any{
				{"toolCallId": "call_read", "kind": "read", "title": "File notes.md", "rawInput": map[string]any{"Path": "/home/x/notes.md"}},
				{"toolCallId": "call_mine", "kind": "execute", "title": "MCP Tool reverse_text", "rawInput": map[string]any{"ServerName": "mine", "ToolName": "reverse_text"}},
				{"toolCallId": "call_other", "kind": "other", "title": "Run mine_tool", "rawInput": map[string]any{}},
				{"toolCallId": "call_cyfr", "kind": "other", "title": "Run mcp_cyfr_files", "rawInput": map[string]any{"path": "x"}},
				{"toolCallId": "call_cyfr_by_name", "kind": "execute", "title": "MCP Tool files", "rawInput": map[string]any{"ServerName": "cyfr", "ToolName": "files"}},
			} {
				call["sessionUpdate"], call["status"] = "tool_call", "in_progress"
				update(call)
				call["sessionUpdate"], call["status"] = "tool_call_update", "pending"
				update(call)
				call["status"] = "in_progress"
				update(call)
				call["status"] = "completed"
				update(call)
			}
			reply("ran them")
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
			switch {
			case m.Method == "" && len(m.ID) > 0:
				answersMu.Lock()
				ch := answers[idKey(m.ID)]
				delete(answers, idKey(m.ID))
				answersMu.Unlock()
				if ch != nil {
					ch <- json.RawMessage(line)
				}
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
				state.opened = m.Params
				state.Unlock()
				files(state.session)
				answer(m.ID, sessionResult())
				listSoon(m.Params)
			case m.Method == "session/resume":
				id := str("sessionId")
				switch {
				case os.Getenv("FAKE_RESUME_OTHER") != "":
					failWith(m.ID, -32603, "Internal error")
				case !exists(id) || os.Getenv("FAKE_RESUME_MISSING") != "":
					failWith(m.ID, -32603, "Failed to read session "+id+"; retry, or load it with session/load")
				default:
					state.Lock()
					state.session, state.opened = id, m.Params
					state.Unlock()
					answer(m.ID, sessionResult())
					listSoon(m.Params)
				}
			case m.Method == "session/load":
				id := str("sessionId")
				switch {
				case os.Getenv("FAKE_LOAD_OTHER") != "":
					failWith(m.ID, -32603, "Internal error")
				case !exists(id):
					failWith(m.ID, -32002, "Session not found: "+id)
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
			case m.Method == "session/set_config_option":
				id, value := str("configId"), str("value")
				state.Lock()
				state.set = append(state.set, map[string]any{"configId": id, "value": value})
				state.current[id] = value
				state.Unlock()
				answer(m.ID, map[string]any{"configOptions": options()})
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
				if earlier != nil {
					if os.Getenv("FAKE_STEER_FAIL") != "" {
						state.Unlock()
						failWith(m.ID, -32603, "HARNESS-WORDS the steer was not taken")
						continue
					}
					// The earlier prompt answers at once; this one carries
					// the turn on.
					state.active = m.ID
					state.Unlock()
					answer(earlier, map[string]any{"stopReason": "end_turn"})
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
