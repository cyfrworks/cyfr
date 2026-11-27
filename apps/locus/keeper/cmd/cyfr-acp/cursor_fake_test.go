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

// fakeCursor stands in for Cursor's `agent acp` as 2026.11.22-e9042b2 was
// probed (Q3, /var/tmp/cyfr/aq-mp-cursor/): an initialize naming no
// version and no resume; UUID sessions kept as folders
// `acp-sessions/<id>/` (`store.db`, `meta.json`) under its configuration
// folder; -32000 signed out; a load of a session it lacks answered -32602
// "Invalid params" with `Session "<id>" not found` in its data, and a
// load's replay before its answer; the servers handed listing their tools
// at the session's first prompt, not before; a server's call announced
// kind other with an empty rawInput, then updated to
// {providerIdentifier, toolName, args}, and asked with
// session/request_permission; no usage on any prompt's answer; no
// session/close and no session/delete. Initialized with
// `clientCapabilities._meta.parameterizedModelPicker`, as F3 probed it, its
// `model` option lists base models and the current model's own options
// follow it, a setter answering the options of the model then set and
// refusing -32602 an option or value that model lacks; without, one value
// a model fixes its parameters in. `cursor/list_available_models` gives
// every model's own options with no session. Every listing of `mcp list`,
// load, cancel, setter and handed server is logged in `$HOME/fake-acp.log`.
// A prompt's last text picks what the turn does:
//
//	fail        writes the chunk the probe saw on a dead network, alone, then end_turn
//	unauth      writes its unauthenticated failure alone
//	signin      writes its sign-in sentence alone
//	exhausted   writes a failure of another code alone
//	saidfirst   says a word, then the failure
//	thoughtfirst  thinks, then the failure
//	callfirst   runs a tool of its own, then the failure
//	failthen    writes the failure, then a word more
//	askfirst    calls CYFR's `files`, then writes the failure
//	imagefirst  writes an image chunk, then the failure
//	emptyfirst  writes an empty text chunk, then the failure
//	samecall    calls CYFR's `files`, then shows a person's server's call of
//	            the same arguments before CYFR's
//	lookalike   writes a chunk of nearly the failure's form
//	call        calls CYFR's `files` as Cursor does, after its permission question
//	theirs      calls a person's server `notes`, its tool `echo`
//	slow        says a word and waits for a second prompt, which cancels it
//	servers     replies with the servers' names it was handed
//	question    asks the person in its reply (fakeQuestion), after its own
//	            tool's permission, and takes the session's next prompt as
//	            the answer, replying "A1: " and its words; it keeps the
//	            capabilities initialize named and the driver's whole answer
//	            to the permission in `$HOME/fake-question.json`
//
// FAKE_SIGNED_OUT answers sessions -32000; FAKE_NO_LIST never lists;
// FAKE_NO_LOAD offers no load; FAKE_LOAD_STILL answers a load of a session
// whose files are gone as found; FAKE_LOAD_ERROR answers every load -32603; FAKE_HOLD keeps running after its input
// ends, until a TERM. Run with `mcp list` it prints FAKE_SERVERS as Cursor
// does, a comma between each, and FAKE_SERVERS_FAIL prints nothing.
func fakeCursor() int {
	args := os.Args[1:]
	home := os.Getenv("HOME")
	logLine := func(what string) {
		f, err := os.OpenFile(filepath.Join(home, "fake-acp.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err == nil {
			fmt.Fprintln(f, what)
			f.Close()
		}
	}
	if words := " " + strings.Join(args, " "); strings.HasSuffix(words, " mcp list") {
		logLine("list")
		if os.Getenv("FAKE_SERVERS_FAIL") != "" {
			return 0
		}
		listed := os.Getenv("FAKE_SERVERS")
		if listed == "" {
			fmt.Println(cursorNone)
			return 0
		}
		for _, n := range strings.Split(listed, ",") {
			fmt.Printf("%s: ready\n", n)
		}
		return 0
	}
	if len(args) == 0 || args[len(args)-1] != "acp" {
		fmt.Fprintln(os.Stderr, "fake-cursor: not started as acp:", args)
		return 2
	}
	fmt.Fprintln(os.Stderr, stderrCanary)
	if os.Getenv("FAKE_HOLD") != "" {
		terms := make(chan os.Signal, 1)
		signal.Notify(terms, syscall.SIGTERM)
		go func() {
			<-terms
			logLine("term")
			os.Exit(143)
		}()
	}
	// Its configuration folder, as Cursor finds it, through any link.
	config := filepath.Join(home, ".cursor")
	if dir := os.Getenv("CURSOR_CONFIG_DIR"); strings.TrimSpace(dir) != "" {
		config = dir
	} else if dir := os.Getenv("XDG_CONFIG_HOME"); strings.TrimSpace(dir) != "" {
		config = filepath.Join(dir, "cursor")
	}
	sessions := filepath.Join(config, "acp-sessions")

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
	failWith := func(id json.RawMessage, code int, message string, data any) {
		e := map[string]any{"code": code, "message": message}
		if data != nil {
			e["data"] = data
		}
		write(map[string]any{"jsonrpc": "2.0", "id": id, "error": e})
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
		session, socket, server string
		handed                  []string
		listed                  bool
		active                  json.RawMessage
		cancel                  chan struct{}
	}
	update := func(u map[string]any) {
		write(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"sessionId": state.session, "update": u}})
	}
	chunk := func(text string) {
		update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}})
	}
	finish := func(stop string) {
		state.Lock()
		id := state.active
		state.active = nil
		state.Unlock()
		if id != nil {
			answer(id, map[string]any{"stopReason": stop})
		}
	}
	mode := map[string]any{"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "agent", "options": []any{
		map[string]any{"value": "agent", "name": "Agent"}, map[string]any{"value": "plan", "name": "Plan"}, map[string]any{"value": "ask", "name": "Ask"}}}
	selectOf := func(id, name, category, current string, values ...string) map[string]any {
		choices := []any{}
		for _, v := range values {
			choices = append(choices, map[string]any{"value": v, "name": strings.ToUpper(v[:1]) + v[1:]})
		}
		return map[string]any{"id": id, "name": name, "category": category, "type": "select", "currentValue": current, "options": choices}
	}
	// Each base model and its own options, as F3's list_available_models
	// gave them: Auto none, one an effort, one a thinking switch beside its
	// effort in the same category, and a context of its own.
	models := []struct {
		value, name string
		options     []any
	}{
		{"default", "Auto", []any{}},
		{"claude-opus-5-5", "Claude Opus 5.5", []any{selectOf("effort", "Effort", "thought_level", "medium", "low", "medium", "high", "xhigh", "max")}},
		{"claude-opus-5", "Claude Opus 5", []any{selectOf("thinking", "Thinking", "thought_level", "true", "false", "true"),
			selectOf("effort", "Effort", "thought_level", "high", "low", "medium", "high"), selectOf("context", "Context", "model_config", "300k", "300k", "1m")}},
	}
	var picker bool
	// The capabilities initialize named, for `question`.
	var capabilities map[string]any
	current := "default"
	ownOptions := func() []any {
		for _, m := range models {
			if m.value == current {
				return m.options
			}
		}
		return nil
	}
	options := func() []any {
		if !picker {
			return []any{mode, map[string]any{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "default[]", "options": []any{
				map[string]any{"value": "default[]", "name": "Auto"},
				map[string]any{"value": "claude-opus-5-5[context=300k,effort=medium,fast=false]", "name": "claude-opus-5-5"}}}}
		}
		base := []any{}
		for _, m := range models {
			base = append(base, map[string]any{"value": m.value, "name": m.name})
		}
		return append([]any{mode, map[string]any{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": current, "options": base}}, ownOptions()...)
	}
	// set is a setter's refusal as Cursor words it, or "" once it is set.
	set := func(id, value string) string {
		switch {
		case !picker || id == "mode":
			return ""
		case id == "model":
			for _, m := range models {
				if m.value == value {
					current = value
					return ""
				}
			}
			return "Invalid value for model: " + value
		}
		for _, o := range ownOptions() {
			if o.(map[string]any)["id"] == id {
				for _, c := range o.(map[string]any)["options"].([]any) {
					if c.(map[string]any)["value"] == value {
						return ""
					}
				}
				return "Invalid value for " + id + ": " + value
			}
		}
		return "Unknown model config option: " + id
	}
	sessionResult := func(id string) map[string]any {
		r := map[string]any{"modes": map[string]any{"currentModeId": "agent", "availableModes": []any{}}, "configOptions": options(),
			"models": map[string]any{"currentModelId": "default[]", "availableModels": []any{map[string]any{"modelId": "default[]", "name": "Auto"}}}}
		if id != "" {
			r["sessionId"] = id
		}
		return r
	}
	// opened takes the servers a session is handed, as Cursor starts them
	// with it; they list at its first prompt.
	opened := func(params map[string]any) {
		servers, _ := params["mcpServers"].([]any)
		var names []string
		for _, s := range servers {
			entry, _ := s.(map[string]any)
			names = append(names, fmt.Sprint(entry["name"]))
			argv, _ := entry["args"].([]any)
			if len(argv) == 2 && argv[0] == "--socket" {
				state.socket, state.server = fmt.Sprint(argv[1]), fmt.Sprint(entry["name"])
			}
		}
		state.handed = names
		logLine("servers " + strings.Join(names, ","))
	}
	exists := func(id string) bool {
		_, err := os.Stat(filepath.Join(sessions, id, "store.db"))
		return err == nil
	}
	failure := "\n\nError: RetriableError: [unavailable] getaddrinfo EAI_AGAIN agentn.global.api5.cursor.sh"

	runTurn := func(words string) {
		state.Lock()
		if !state.listed && state.socket != "" && os.Getenv("FAKE_NO_LIST") == "" {
			var listing toolsock.Listing
			if toolsock.Ask(state.socket, toolsock.Request{Op: "list"}, &listing) == nil {
				state.listed = true
			}
		}
		state.Unlock()
		ownCall := func(id, kind string) {
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": id, "title": "Read File", "kind": kind, "status": "pending", "rawInput": map[string]any{}})
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"})
		}
		// A prompt after the session's question is its answer.
		asked := filepath.Join(home, "fake-asked-"+state.session)
		if _, err := os.Stat(asked); err == nil {
			_ = os.Remove(asked)
			chunk("A1: " + words)
			finish("end_turn")
			return
		}
		switch {
		case words == "question":
			// As Cursor asks with CYFR's initialize, which offers its model no
			// question tool (S1 F2): in its reply, after its own tool's
			// permission.
			id := "call-q\nfc_q"
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": id, "title": "Edit File", "kind": "edit", "status": "pending", "rawInput": map[string]any{}})
			permission := ask("q2", "session/request_permission", map[string]any{"sessionId": state.session, "toolCall": map[string]any{"toolCallId": id,
				"title": "Edit export.sql", "kind": "edit", "status": "pending"},
				"options": []any{map[string]any{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
					map[string]any{"optionId": "allow-always", "name": "Allow always", "kind": "allow_always"},
					map[string]any{"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}}})
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"})
			line, _ := json.Marshal(map[string]any{"capabilities": capabilities, "permission": permission})
			_ = os.WriteFile(filepath.Join(home, "fake-question.json"), line, 0o600)
			_ = os.WriteFile(asked, nil, 0o600)
			chunk(fakeQuestion)
		case words == "fail":
			chunk(failure)
		case words == "unauth":
			chunk("\n\nError: [unauthenticated] Backend rejected authentication. Verify this is a User API Key for the same endpoint/environment, then rerun with --debug for request-level auth logs.")
		case words == "signin":
			chunk("\n\nPlease sign in to continue")
		case words == "exhausted":
			chunk("\n\nError: ConnectError: [resource_exhausted] HARNESS-WORDS too many requests")
		case words == "saidfirst":
			chunk("Looking. ")
			chunk(failure)
		case words == "thoughtfirst":
			update(map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "thinking"}})
			chunk(failure)
		case words == "callfirst":
			ownCall("call_read", "read")
			chunk(failure)
		case words == "failthen":
			chunk(failure)
			chunk(" and more")
		case words == "askfirst":
			var result toolsock.Result
			_ = toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"a"}`)}, &result)
			chunk(failure)
		case words == "emptyfirst":
			chunk("")
			chunk(failure)
		case words == "samecall":
			// CYFR's call reaches the socket first, then a call of the
			// person's server with the same arguments is shown before
			// Cursor updates CYFR's: Sol's order. The person's call waits
			// for the test to have read the ask ($HOME/go-on).
			results := make(chan toolsock.Result, 1)
			go func() {
				var result toolsock.Result
				_ = toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: "files", Arguments: json.RawMessage(`{"path":"a"}`)}, &result)
				results <- result
			}()
			for i := 0; i < 500; i++ {
				if _, err := os.Stat(filepath.Join(home, "go-on")); err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond) // sleep-ok: a bounded wait for the test's own file, read by a poll
			}
			for _, c := range []struct{ id, server string }{{"call-notes", "notes"}, {"call-cyfr", state.server}} {
				update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": c.id, "title": "MCP: tool", "kind": "other", "status": "pending", "rawInput": map[string]any{}})
				update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": c.id, "title": c.server + ": files",
					"rawInput": map[string]any{"providerIdentifier": c.server, "toolName": "files", "args": map[string]any{"path": "a"}}})
			}
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-notes", "status": "completed"})
			result := <-results
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "call-cyfr", "status": "completed"})
			chunk("the tool answered " + result.Text)
		case words == "imagefirst":
			update(map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}})
			chunk(failure)
		case words == "lookalike":
			chunk("\n\nError: a plain sentence of the model's")
		case words == "call" || words == "theirs":
			server, tool, arguments := state.server, "files", map[string]any{"path": "notes.txt"}
			if words == "theirs" {
				server, tool, arguments = "notes", "echo", map[string]any{"text": "two"}
			}
			id := "call-1\nfc_1"
			update(map[string]any{"sessionUpdate": "tool_call", "toolCallId": id, "title": "MCP: tool", "kind": "other", "status": "pending", "rawInput": map[string]any{}})
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "title": server + ": " + tool,
				"rawInput": map[string]any{"providerIdentifier": server, "toolName": tool, "args": arguments}})
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress"})
			ask("0", "session/request_permission", map[string]any{"sessionId": state.session, "toolCall": map[string]any{"toolCallId": id,
				"title": server + "-" + tool + ": " + tool, "kind": "other", "status": "pending"},
				"options": []any{map[string]any{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
					map[string]any{"optionId": "allow-always", "name": "Allow always", "kind": "allow_always"},
					map[string]any{"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}}})
			text := "their server answered"
			if words == "call" {
				var result toolsock.Result
				raw, _ := json.Marshal(arguments)
				if toolsock.Ask(state.socket, toolsock.Request{Op: "call", Name: tool, Arguments: raw}, &result) != nil {
					result.Text = "unreachable"
				}
				text = "the tool answered " + result.Text
			}
			update(map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "rawOutput": map[string]any{"success": true}})
			chunk(text)
		case words == "slow":
			chunk("Starting. ")
			state.Lock()
			cancel := state.cancel
			state.Unlock()
			select {
			case <-cancel:
				return
			case <-time.After(2 * time.Second):
			}
			chunk("no second prompt came")
		case words == "servers":
			chunk("handed " + strings.Join(state.handed, ","))
		default:
			chunk("ok")
		}
		finish("end_turn")
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
				capabilities, _ = m.Params["clientCapabilities"].(map[string]any)
				meta, _ := capabilities["_meta"].(map[string]any)
				picker = meta["parameterizedModelPicker"] == true
				answer(m.ID, map[string]any{"protocolVersion": 1, "agentCapabilities": map[string]any{"loadSession": os.Getenv("FAKE_NO_LOAD") == "",
					"mcpCapabilities": map[string]any{"http": true, "sse": true}, "promptCapabilities": map[string]any{"audio": false, "embeddedContext": false, "image": true},
					"sessionCapabilities": map[string]any{"list": map[string]any{}}},
					"authMethods": []any{map[string]any{"id": "cursor_login", "name": "Cursor Login"}}})
			case signedOut && (m.Method == "session/new" || m.Method == "session/load" || m.Method == "session/list"):
				if m.Method == "session/load" {
					logLine("load " + str("sessionId"))
				}
				failWith(m.ID, -32000, "Authentication required", map[string]any{"message": "Authentication required. Please run 'agent login' first."})
			case m.Method == "session/new":
				id := brainwire.NewUUID()
				_ = os.MkdirAll(filepath.Join(sessions, id), 0o700)
				_ = os.WriteFile(filepath.Join(sessions, id, "store.db"), []byte("FAKE-STORE"), 0o600)
				_ = os.WriteFile(filepath.Join(sessions, id, "meta.json"), []byte(`{"schemaVersion":1,"cwd":"x","title":"FAKE-TITLE"}`), 0o600)
				state.Lock()
				state.session = id
				state.Unlock()
				opened(m.Params)
				answer(m.ID, sessionResult(id))
			case m.Method == "session/load" && os.Getenv("FAKE_LOAD_ERROR") != "":
				logLine("load " + str("sessionId"))
				failWith(m.ID, -32603, "Internal error", map[string]any{"message": "HARNESS-WORDS the store is locked"})
			case m.Method == "session/load":
				id := str("sessionId")
				logLine("load " + id)
				if !exists(id) && os.Getenv("FAKE_LOAD_STILL") == "" {
					failWith(m.ID, -32602, "Invalid params", map[string]any{"message": `Session "` + id + `" not found`})
					continue
				}
				state.Lock()
				state.session = id
				state.Unlock()
				opened(m.Params)
				update(map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "REPLAYED-USER"}})
				chunk("REPLAYED-CANARY")
				answer(m.ID, sessionResult(""))
			case m.Method == "session/set_config_option":
				logLine("set " + str("configId") + " " + str("value"))
				if refused := set(str("configId"), str("value")); refused != "" {
					failWith(m.ID, -32602, "Invalid params", map[string]any{"message": refused})
					continue
				}
				answer(m.ID, map[string]any{"configOptions": options()})
			case m.Method == "cursor/list_available_models":
				listed := []any{}
				for _, m := range models {
					listed = append(listed, map[string]any{"value": m.value, "name": m.name, "configOptions": m.options})
				}
				answer(m.ID, map[string]any{"models": listed})
			case m.Method == "session/prompt":
				words := ""
				prompt, _ := m.Params["prompt"].([]any)
				for _, b := range prompt {
					if block, _ := b.(map[string]any); block["type"] == "text" {
						words = fmt.Sprint(block["text"])
					}
				}
				state.Lock()
				if earlier := state.active; earlier != nil {
					// A prompt mid-turn cancels the running one (Cursor's
					// handlePrompt).
					close(state.cancel)
					answer(earlier, map[string]any{"stopReason": "cancelled"})
				}
				state.active = m.ID
				state.cancel = make(chan struct{})
				state.Unlock()
				go runTurn(words)
			case m.Method == "session/cancel":
				logLine("cancel")
				finish("cancelled")
			case len(m.ID) > 0:
				failWith(m.ID, -32601, `"Method not found": `+m.Method, map[string]any{"method": m.Method})
			}
		}
		if err != nil {
			if os.Getenv("FAKE_HOLD") != "" {
				time.Sleep(time.Hour) // sleep-ok: Cursor does not end when its input does, until its TERM
			}
			return 0
		}
	}
}
