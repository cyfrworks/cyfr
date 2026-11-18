// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// The test binary is also a stand-in for Codex's app-server when
// CYFR_FAKE_CODEX is set: it speaks the JSON-RPC shapes Codex 0.169.0's
// app-server was driven to write (codex.go), keeps each thread's rollout
// in `$CODEX_HOME/sessions/2026/11/18/rollout-<time>-<thread>.jsonl` with
// each user message Codex records as an `item_completed` naming its
// `client_id`, and a shell snapshot per thread, and turns a user message's
// last text into a turn:
//
//	hello     replies naming the thread's policy, tools, model, effort and instructions
//	slow      streams a first part, waits for a steer, then replies naming what it read
//	read      calls CYFR's `files` and replies with the answer and whether it ran
//	own       runs its own command, its output a canary, then replies
//	fail      fails on a 401, its error in the harness's own words
//	late      replies, then runs a turn of its own that no post started
//	counts    sends a total missing a count, one with none, a reroute, then a whole one
//	other     asks for the user's input and for an approval, then replies with the answers
//	stranger  calls CYFR's tool from another thread, then replies with the answer
//	child     a sub-agent's thread starts a turn and counts its usage, then it replies
//	agent     calls a sub-agent, with no line of the sub-agent's own, then replies
//	none      sends usage with no total, then replies
//	missing   sends a total missing a count, then replies
//	big       replies with 2 MiB of text
//	die       ends the process with status 3
//
// It refuses to start without `app-server` last, answers nothing before
// `initialize`, writes a canary to its standard error, which the driver
// must never pass on, and keeps a sign-in, `auth.json`, while
// FAKE_SIGNED_OUT is unset. A resume sends the thread's last total again
// unless FAKE_NO_REPEAT is set.
const fakeEnv = "CYFR_FAKE_CODEX"

const stderrCanary = "FAKE-STDERR-CANARY Codex writes this to its stderr"

func fakeCodex() int {
	args := os.Args[1:]
	if len(args) == 0 || args[len(args)-1] != appServer {
		fmt.Fprintln(os.Stderr, "fake-codex: not started as app-server:", args)
		return 2
	}
	fmt.Fprintln(os.Stderr, stderrCanary)
	home := codexHome(os.Getenv("HOME"))
	sessions := filepath.Join(home, "sessions", "2026", "11", "18")
	snapshots := filepath.Join(home, "shell_snapshots")
	_ = os.MkdirAll(sessions, 0o700)
	_ = os.MkdirAll(snapshots, 0o700)
	auth := filepath.Join(home, "auth.json")
	if os.Getenv("FAKE_SIGNED_OUT") == "" {
		if _, err := os.Stat(auth); err != nil {
			_ = os.WriteFile(auth, []byte(`{"FAKE-SIGNIN-CANARY":"the sign-in Codex keeps"}`), 0o600)
		}
	}

	out := bufio.NewWriter(os.Stdout)
	var mu sync.Mutex
	write := func(v any) {
		mu.Lock()
		defer mu.Unlock()
		line, _ := json.Marshal(v)
		out.Write(append(line, '\n'))
		out.Flush()
	}
	notify := func(method string, params map[string]any) { write(map[string]any{"method": method, "params": params}) }
	answers := map[string]chan json.RawMessage{}
	var answersMu sync.Mutex
	asked := 0
	ask := func(method string, params map[string]any) json.RawMessage {
		answersMu.Lock()
		asked++
		id := asked
		ch := make(chan json.RawMessage, 1)
		answers[fmt.Sprint(id)] = ch
		answersMu.Unlock()
		write(map[string]any{"method": method, "id": id, "params": params})
		return <-ch
	}

	var thread struct {
		sync.Mutex
		id, model, instructions, policy, sandbox string
		tools                                    []string
		rollout                                  *os.File
		active                                   string
		steered                                  chan string
		total                                    map[string]int
	}
	rolloutOf := func(id string) string {
		matches, _ := filepath.Glob(filepath.Join(sessions, "rollout-*-"+id+".jsonl"))
		if len(matches) == 0 {
			return ""
		}
		return matches[0]
	}
	record := func(v any) {
		line, _ := json.Marshal(v)
		thread.rollout.Write(append(line, '\n'))
	}
	turns := 0
	userMessage := func(turn, uuid, text string) {
		item := map[string]any{"type": "userMessage", "id": fmt.Sprintf("um_%d", time.Now().UnixNano()), "clientId": uuid,
			"content": []any{map[string]any{"type": "text", "text": text}}}
		base := map[string]any{"threadId": thread.id, "turnId": turn, "item": item}
		notify("item/started", base)
		record(map[string]any{"type": "event_msg", "payload": map[string]any{"type": "item_completed", "turn_id": turn,
			"item": map[string]any{"type": "UserMessage", "client_id": uuid}}})
		notify("item/completed", base)
	}
	usage := func(turn string, input, output int) {
		for k, v := range map[string]int{"inputTokens": input, "outputTokens": output, "cachedInputTokens": 3, "cacheWriteInputTokens": 1} {
			thread.total[k] += v
		}
		total := map[string]any{"totalTokens": 0, "reasoningOutputTokens": 0}
		for k, v := range thread.total {
			total[k] = v
		}
		notify("thread/tokenUsage/updated", map[string]any{"threadId": thread.id, "turnId": turn,
			"tokenUsage": map[string]any{"total": total, "last": map[string]any{"inputTokens": input, "outputTokens": output}}})
	}
	reply := func(turn, text string) {
		message := fmt.Sprintf("msg_%s_%d", turn, len(text))
		notify("item/started", map[string]any{"threadId": thread.id, "turnId": turn, "item": map[string]any{"type": "agentMessage", "id": message, "text": ""}})
		half := len(text) / 2
		for _, piece := range []string{text[:half], text[half:]} {
			notify("item/agentMessage/delta", map[string]any{"threadId": thread.id, "turnId": turn, "itemId": message, "delta": piece})
		}
		notify("item/completed", map[string]any{"threadId": thread.id, "turnId": turn, "item": map[string]any{"type": "agentMessage", "id": message, "text": text}})
		usage(turn, 10, len(text)%97)
	}
	complete := func(turn, status string, errorInfo any) {
		thread.Lock()
		if thread.active == turn {
			thread.active = ""
		}
		thread.Unlock()
		t := map[string]any{"id": turn, "items": []any{}, "status": status, "error": nil}
		if errorInfo != nil {
			t["error"] = errorInfo
		}
		notify("turn/completed", map[string]any{"threadId": thread.id, "turn": t})
	}
	runTurn := func(turn, words string, config map[string]any) {
		switch {
		case strings.Contains(words, "hello"):
			reply(turn, fmt.Sprintf("Hello from the fake Codex: policy %s/%s, tools %s, model %s, effort %v, instructions %q",
				thread.policy, thread.sandbox, strings.Join(thread.tools, ","), thread.model, config["effort"], thread.instructions))
		case strings.Contains(words, "slow"):
			notify("item/agentMessage/delta", map[string]any{"threadId": thread.id, "turnId": turn, "itemId": "msg_cut", "delta": "Starting"})
			select {
			case steered := <-thread.steered:
				reply(turn, "Read the steer: "+steered)
			case <-time.After(5 * time.Second):
				reply(turn, "no steer came")
			}
		case strings.Contains(words, "read"):
			args := json.RawMessage(`{"action":"read","path":"notes.txt","count":12345678901234567890}`)
			notify("item/started", map[string]any{"threadId": thread.id, "turnId": turn, "item": map[string]any{"type": "dynamicToolCall", "id": "call_read", "tool": "files"}})
			answered := ask("item/tool/call", map[string]any{"threadId": thread.id, "turnId": turn, "callId": "call_read", "tool": "files", "arguments": args})
			var a struct {
				Result struct {
					ContentItems []struct{ Text string } `json:"contentItems"`
					Success      bool                    `json:"success"`
				} `json:"result"`
			}
			_ = json.Unmarshal(answered, &a)
			text := ""
			for _, item := range a.Result.ContentItems {
				text += item.Text
			}
			reply(turn, fmt.Sprintf("The tool answered %q, success %v", text, a.Result.Success))
		case strings.Contains(words, "own"):
			command := map[string]any{"type": "commandExecution", "id": "cmd_1", "command": "/bin/bash -lc 'cat secret-of-the-folder'", "status": "inProgress"}
			notify("item/started", map[string]any{"threadId": thread.id, "turnId": turn, "item": command})
			command["status"], command["aggregatedOutput"] = "completed", "FOLDER-CANARY"
			notify("item/completed", map[string]any{"threadId": thread.id, "turnId": turn, "item": command})
			reply(turn, "ran it")
		case strings.Contains(words, "fail"):
			harness := "HARNESS-WORDS unexpected status 401 Unauthorized, sign in at https://example.invalid"
			notify("error", map[string]any{"threadId": thread.id, "turnId": turn, "willRetry": true, "error": map[string]any{"message": harness}})
			complete(turn, "failed", map[string]any{"message": harness, "codexErrorInfo": map[string]any{"httpConnectionFailed": map[string]any{"httpStatusCode": 401}}})
			return
		case strings.Contains(words, "late"):
			reply(turn, "early")
			complete(turn, "completed", nil)
			time.Sleep(50 * time.Millisecond)
			own := fmt.Sprintf("turn_own_%d", turns)
			notify("turn/started", map[string]any{"threadId": thread.id, "turn": map[string]any{"id": own, "items": []any{}, "status": "inProgress"}})
			reply(own, "a turn of my own")
			complete(own, "completed", nil)
			return
		case strings.Contains(words, "counts"):
			notify("thread/tokenUsage/updated", map[string]any{"threadId": thread.id, "turnId": turn, "tokenUsage": map[string]any{"total": map[string]any{"inputTokens": 5}}})
			notify("thread/tokenUsage/updated", map[string]any{"threadId": thread.id, "turnId": turn, "tokenUsage": map[string]any{}})
			notify("model/rerouted", map[string]any{"threadId": thread.id, "turnId": turn, "fromModel": thread.model, "toModel": "fake-mini", "reason": "highRiskCyberActivity"})
			reply(turn, "counted")
		case strings.Contains(words, "other"):
			input := ask("item/tool/requestUserInput", map[string]any{"threadId": thread.id, "turnId": turn, "questions": []any{}})
			approval := ask("item/commandExecution/requestApproval", map[string]any{"threadId": thread.id, "turnId": turn, "itemId": "cmd_2"})
			clock := ask("currentTime/read", map[string]any{})
			var a, b, c map[string]any
			_ = json.Unmarshal(input, &a)
			_ = json.Unmarshal(approval, &b)
			_ = json.Unmarshal(clock, &c)
			_, refused := a["error"]
			decision := b["result"].(map[string]any)["decision"]
			_, timed := c["result"].(map[string]any)["currentTimeAt"]
			reply(turn, fmt.Sprintf("input refused %v, approval %v, time %v", refused, decision, timed))
		case strings.Contains(words, "stranger"):
			answered := ask("item/tool/call", map[string]any{"threadId": "019a0000-0000-7000-8000-000000000000", "turnId": turn, "callId": "call_x", "tool": "files", "arguments": map[string]any{}})
			var a struct {
				Result struct {
					Success bool `json:"success"`
				} `json:"result"`
			}
			_ = json.Unmarshal(answered, &a)
			reply(turn, fmt.Sprintf("the stranger's call ran %v", a.Result.Success))
		case strings.Contains(words, "child"):
			// A sub-agent's thread works: its lines name its own thread.
			child := "019a0000-0000-7000-8000-00000000c41d"
			notify("turn/started", map[string]any{"threadId": child, "turn": map[string]any{"id": "turn_child", "items": []any{}, "status": "inProgress"}})
			notify("thread/tokenUsage/updated", map[string]any{"threadId": child, "turnId": "turn_child", "tokenUsage": map[string]any{"total": map[string]any{
				"inputTokens": 7, "cachedInputTokens": 0, "cacheWriteInputTokens": 0, "outputTokens": 2}}})
			reply(turn, "a child ran")
		case strings.Contains(words, "agent"):
			// The session's own call of a sub-agent, and no line of its thread.
			call := map[string]any{"type": "collabAgentToolCall", "id": "collab_1", "tool": "spawnAgent", "status": "inProgress"}
			notify("item/started", map[string]any{"threadId": thread.id, "turnId": turn, "item": call})
			call["status"] = "completed"
			notify("item/completed", map[string]any{"threadId": thread.id, "turnId": turn, "item": call})
			reply(turn, "an agent ran")
		case strings.Contains(words, "none"):
			notify("thread/tokenUsage/updated", map[string]any{"threadId": thread.id, "turnId": turn, "tokenUsage": map[string]any{}})
			reply(turn, "none counted")
		case strings.Contains(words, "missing"):
			notify("thread/tokenUsage/updated", map[string]any{"threadId": thread.id, "turnId": turn, "tokenUsage": map[string]any{"total": map[string]any{"inputTokens": 5}}})
			reply(turn, "one count missing")
		case strings.Contains(words, "big"):
			reply(turn, strings.Repeat("x", 2<<20))
		default:
			reply(turn, "ok")
		}
		complete(turn, "completed", nil)
	}

	initialized := false
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
			ok := func(result any) { write(map[string]any{"id": m.ID, "result": result}) }
			fail := func(code int, message string) {
				write(map[string]any{"id": m.ID, "error": map[string]any{"code": code, "message": message}})
			}
			str := func(name string) string { s, _ := m.Params[name].(string); return s }
			switch {
			case m.Method == "" && len(m.ID) > 0:
				answersMu.Lock()
				ch := answers[string(m.ID)]
				delete(answers, string(m.ID))
				answersMu.Unlock()
				if ch != nil {
					ch <- json.RawMessage(line)
				}
			case m.Method == "initialize":
				caps, _ := m.Params["capabilities"].(map[string]any)
				initialized = caps["experimentalApi"] == true
				ok(map[string]any{"userAgent": "fake-codex/0.169.0", "codexHome": home})
			case !initialized:
				fail(-32600, "initialize with experimentalApi first")
			case m.Method == "initialized":
			case m.Method == "account/read":
				if _, err := os.Stat(auth); err == nil {
					ok(map[string]any{"account": map[string]any{"type": "chatgpt", "email": "FAKE-ACCOUNT-CANARY@example.invalid", "planType": "plus"}, "requiresOpenaiAuth": true})
				} else {
					ok(map[string]any{"account": nil, "requiresOpenaiAuth": true})
				}
			case m.Method == "model/list":
				if str("cursor") == "" {
					ok(map[string]any{"data": []any{
						map[string]any{"id": "fake-sol", "displayName": "Fake Sol", "isDefault": true, "supportedReasoningEfforts": []any{map[string]any{"reasoningEffort": "low"}, map[string]any{"reasoningEffort": "high"}}},
					}, "nextCursor": "page-2"})
				} else {
					ok(map[string]any{"data": []any{
						map[string]any{"id": "fake-mini", "displayName": "Fake Mini", "supportedReasoningEfforts": []any{map[string]any{"reasoningEffort": "medium"}, map[string]any{"reasoningEffort": "high"}}},
					}, "nextCursor": nil})
				}
			case m.Method == "thread/start" || m.Method == "thread/resume":
				thread.policy, thread.sandbox = str("approvalPolicy"), str("sandbox")
				thread.instructions = str("developerInstructions")
				thread.model = "fake-sol"
				if model := str("model"); model != "" {
					thread.model = model
				}
				thread.total = map[string]int{}
				if m.Method == "thread/start" {
					thread.id = newFakeThreadID()
					thread.tools = nil
					tools, _ := m.Params["dynamicTools"].([]any)
					for _, t := range tools {
						thread.tools = append(thread.tools, fmt.Sprint(t.(map[string]any)["name"]))
					}
					path := filepath.Join(sessions, "rollout-2026-11-18T10-00-00-"+thread.id+".jsonl")
					thread.rollout, _ = os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
					record(map[string]any{"type": "session_meta", "payload": map[string]any{"id": thread.id, "dynamic_tools": thread.tools}})
					_ = os.WriteFile(filepath.Join(snapshots, thread.id+".1.sh"), []byte("declare -x SECRET=FAKE-FOLDER-CANARY\n"), 0o600)
				} else {
					id := str("threadId")
					path := rolloutOf(id)
					if path == "" {
						fail(-32600, noRolloutWords+" "+id)
						continue
					}
					thread.id = id
					thread.tools = []string{"(the thread's own)"}
					thread.rollout, _ = os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
				}
				thread.steered = make(chan string, 4)
				ok(map[string]any{"thread": map[string]any{"id": thread.id, "turns": []any{}}, "model": thread.model, "approvalPolicy": thread.policy})
				if m.Method == "thread/resume" && os.Getenv("FAKE_NO_REPEAT") == "" {
					// A resume sends the thread's last total again, naming the
					// turn before it, as Codex 0.169.0 does.
					usage("turn_before", 0, 0)
				}
			case m.Method == "turn/start":
				turns++
				turn := fmt.Sprintf("turn_%d", turns)
				thread.Lock()
				thread.active = turn
				thread.Unlock()
				input, _ := m.Params["input"].([]any)
				words := ""
				for _, i := range input {
					if item, _ := i.(map[string]any); item["type"] == "text" {
						words = fmt.Sprint(item["text"])
					}
				}
				if os.Getenv("FAKE_EXIT_ON") != "" && strings.Contains(words, os.Getenv("FAKE_EXIT_ON")) {
					return 3
				}
				ok(map[string]any{"turn": map[string]any{"id": turn, "items": []any{}, "status": "inProgress"}})
				config := map[string]any{"effort": m.Params["effort"]}
				uuid := str("clientUserMessageId")
				go func() {
					notify("turn/started", map[string]any{"threadId": thread.id, "turn": map[string]any{"id": turn, "items": []any{}, "status": "inProgress"}})
					userMessage(turn, uuid, words)
					runTurn(turn, words, config)
				}()
			case m.Method == "turn/steer":
				thread.Lock()
				active := thread.active
				thread.Unlock()
				if os.Getenv("FAKE_STEER_REFUSE") != "" || active == "" || str("expectedTurnId") != active {
					fail(-32600, "no active turn to steer")
					continue
				}
				ok(map[string]any{"turnId": active})
				input, _ := m.Params["input"].([]any)
				words := ""
				for _, i := range input {
					if item, _ := i.(map[string]any); item["type"] == "text" {
						words = fmt.Sprint(item["text"])
					}
				}
				userMessage(active, str("clientUserMessageId"), words)
				thread.steered <- words
			case m.Method == "thread/delete":
				id := str("threadId")
				if os.Getenv("FAKE_DELETE_FAIL") != "" {
					fail(-32603, "failed to delete thread: thread-store internal error: database is locked")
					continue
				}
				path := rolloutOf(id)
				if path == "" {
					fail(-32600, noRolloutWords+" "+id)
					continue
				}
				_ = os.Remove(path)
				ok(map[string]any{})
			default:
				fail(-32601, "fake-codex does not answer "+m.Method)
			}
		}
		if err != nil {
			return 0
		}
	}
}

var fakeThreads = 0

// newFakeThreadID is a thread id in Codex's form, a lowercase uuid, fresh
// for each thread.
func newFakeThreadID() string {
	fakeThreads++
	return fmt.Sprintf("019a%04x-%04x-7000-8000-%012x", os.Getpid()&0xffff, fakeThreads, time.Now().UnixNano()&0xffffffffffff)
}
