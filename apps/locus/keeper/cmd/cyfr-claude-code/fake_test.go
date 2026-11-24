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
	"sort"
	"strings"
	"sync"
	"time"
)

// The test binary is also a stand-in for Claude Code when CYFR_FAKE_CLAUDE
// is set: it speaks the stream-json shapes the adapter read from Claude
// Code 2.1.318 (harness.go), keeps each session's transcript in
// `$HOME/.claude/projects/-fake/<session>.jsonl` as user lines under the
// uuids it was given, and turns a user line's last text into a turn:
//
//	hello  streams a reply naming its flags, then the whole message and a result
//	read   asks CYFR's `files` and replies quoting the answer's `result` or `error`
//	own    runs its own Bash after asking, shows its result, then replies
//	rate   ends with an errored message of the rate limit and an errored result
//	late   replies, then writes a later result naming no line, as a background end
//	uncounted  replies with a result that reports no model's usage
//	partial    replies with a result one of whose models' counts does not read
//	big    replies with 2 MiB of text
//	other  asks the driver a control request of another kind, then replies
//	modes  asks for its own Write and Bash, then replies with its
//	       whole command line and the driver's two whole answers, as JSON
//	together  waits for the next post, then answers both in one result,
//	       whose singular `user_message_uuid` names the first alone
//	subagent  streams and says words of a subagent's, runs its tool, then replies
//	around replies in one message of text, a call of CYFR's, and text
//	handed replies with the initialize request it was started with, as JSON
//	theirs calls `theirs` of each server of the person's own it still holds,
//	       each asked as that server's, then replies naming them
//	arrived calls a tool named with CYFR's prefix that is a server's named
//	       by FAKE_LATE_SERVER (JSON, `mcp_server` as the ask names it),
//	       as one that started after its listing, then replies with the
//	       driver's whole answer
//	unended makes the same call, allowed, and ends its turn with no result
//	       for it
//	noise  writes a line that is no JSON, one of no type the driver
//	       reads and an event that does not read, then replies
//
// The person's own servers are those `$HOME/.claude.json` names under
// `mcpServers`, held unless it was started with `--strict-mcp-config`, as
// 2.1.323 was measured to hold them (aq-claude-own): `mcp_status` lists
// them, and a server `mcp_set_servers` names replaces one of theirs of
// the same name for the process's life. Each ask of an MCP tool names its
// server, `mcp_server`, by name and source, and its call, `tool_use_id`.
// FAKE_STATUS answers `mcp_status` with an error (`error`) or a success
// that lists no servers (`unlisted`).
//
// Started with `--resume` of a session its folder does not hold, it ends
// as 2.1.318 ended: a result of no turn naming the session, and exit 1,
// before it reads a line. It writes a canary to its standard error, which
// the driver must never pass on.
const fakeEnv = "CYFR_FAKE_CLAUDE"

const stderrCanary = "FAKE-STDERR-CANARY the harness writes this to its stderr"

func fakeClaude() int {
	args := os.Args[1:]
	flag := func(name string) string {
		for i, a := range args {
			if a == name && i+1 < len(args) {
				return args[i+1]
			}
		}
		return ""
	}
	for _, a := range baseArgv {
		if !strings.Contains(strings.Join(args, " "), a) {
			fmt.Fprintln(os.Stderr, "fake-claude: missing", a)
			return 2
		}
	}
	// theirs are the person's own servers it holds, by name; dynamic is the
	// one server the driver set, CYFR's. Both are read by a turn and set by
	// the driver's lines, under serversMu.
	theirs := map[string]bool{}
	var dynamic string
	var serversMu sync.Mutex
	held := func() (string, []string) {
		serversMu.Lock()
		defer serversMu.Unlock()
		return dynamic, sortedKeys(theirs)
	}
	if !strings.Contains(strings.Join(args, " "), "--strict-mcp-config") {
		var config struct {
			MCPServers map[string]any `json:"mcpServers"`
		}
		home, _ := os.UserHomeDir()
		if raw, err := os.ReadFile(filepath.Join(home, ".claude.json")); err == nil {
			_ = json.Unmarshal(raw, &config)
		}
		for name := range config.MCPServers {
			theirs[name] = true
		}
	}
	fmt.Fprintln(os.Stderr, stderrCanary)
	out := bufio.NewWriter(os.Stdout)
	var mu sync.Mutex
	write := func(v any) {
		mu.Lock()
		defer mu.Unlock()
		line, _ := json.Marshal(v)
		out.Write(append(line, '\n'))
		out.Flush()
	}
	home, _ := os.UserHomeDir()
	project := filepath.Join(home, ".claude", "projects", "-fake")
	_ = os.MkdirAll(project, 0o700)
	session := flag("--session-id")
	if resume := flag("--resume"); resume != "" {
		session = resume
		if _, err := os.Stat(filepath.Join(project, session+".jsonl")); err != nil {
			said := noTranscriptWords + ": " + resume
			write(map[string]any{"type": "result", "subtype": "error_during_execution", "is_error": true,
				"num_turns": 0, "session_id": resume, "errors": []string{said}})
			fmt.Fprintln(os.Stderr, said)
			return 1
		}
	}
	transcript, _ := os.OpenFile(filepath.Join(project, session+".jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	defer transcript.Close()
	flags := fmt.Sprintf("model=%s effort=%s permission=%s tools=%s", flag("--model"), flag("--effort"), flag("--permission-mode"), flag("--tools"))

	answers := map[string]chan map[string]any{}
	// wholes are the driver's answers as their whole lines, by request id.
	wholes := map[string]map[string]any{}
	var answersMu sync.Mutex
	asked := 0
	askOf := func(tool string, input map[string]any, server map[string]any, use ...string) map[string]any {
		answersMu.Lock()
		asked++
		id := fmt.Sprintf("ask-%d", asked)
		ch := make(chan map[string]any, 1)
		answers[id] = ch
		answersMu.Unlock()
		request := map[string]any{"subtype": "can_use_tool", "tool_name": tool, "input": input, "tool_use_id": fmt.Sprintf("toolu_%d", asked)}
		if len(use) > 0 {
			request["tool_use_id"] = use[0]
		}
		if server != nil {
			request["mcp_server"] = server
		}
		write(map[string]any{"type": "control_request", "request_id": id, "request": request})
		return <-ch
	}
	ask := func(tool string, input map[string]any) map[string]any { return askOf(tool, input, nil) }
	// cyfrs is CYFR's tool of that name, under the server the driver set.
	cyfrs := func(name string) string {
		server, _ := held()
		return "mcp__" + server + "__" + name
	}
	askCYFR := func(name string, input map[string]any) map[string]any {
		server, _ := held()
		return askOf(cyfrs(name), input, map[string]any{"name": server, "source": "dynamic"})
	}
	turns := 0
	// Each result's usage as Claude Code 2.1.323 reports it: the main
	// requests' own `usage`, and every model's since the last result, the
	// side requests' among them, which holds the main requests' too.
	modelUsage := map[string]any{
		"fake-opus": map[string]any{"inputTokens": 12, "outputTokens": 3, "cacheReadInputTokens": 5, "cacheCreationInputTokens": 2,
			"thinkingTokens": 1, "cacheCreationEphemeral5mInputTokens": 2, "webSearchRequests": 0, "costUSD": 0.01},
		"fake-haiku": map[string]any{"inputTokens": 1173, "outputTokens": 40, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
			"webSearchRequests": 0, "costUSD": 0.001},
	}
	var reply func(uuids []string, text string)
	replyWith := func(uuids []string, text string, usage map[string]any) {
		turns++
		message := fmt.Sprintf("msg_fake_%d", turns)
		write(map[string]any{"type": "stream_event", "parent_tool_use_id": nil, "event": map[string]any{"type": "message_start", "message": map[string]any{"id": message}}})
		half := len(text) / 2
		for _, piece := range []string{text[:half], text[half:]} {
			write(map[string]any{"type": "stream_event", "parent_tool_use_id": nil, "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": piece}}})
		}
		write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": message, "content": []any{map[string]any{"type": "text", "text": text}}}})
		result := map[string]any{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "uuid": fmt.Sprintf("result-uuid-%d", turns),
			"user_message_uuids": uuids, "usage": map[string]any{"input_tokens": 2, "output_tokens": 3, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2}}
		if usage != nil {
			result["model_usage_since_last_result"] = usage
		}
		write(result)
	}
	reply = func(uuids []string, text string) { replyWith(uuids, text, modelUsage) }
	// What initialize asked, for `handed`.
	var initialized []byte
	// The posts each turn is begun from; a turn that waits for the next
	// post takes it here.
	work := make(chan [2]string, 16)
	turn := func(uuid, words string) {
		uuids := []string{uuid}
		write(map[string]any{"type": "system", "subtype": "init", "session_id": session, "user_message_uuids": uuids})
		switch {
		case strings.Contains(words, "hello"):
			reply(uuids, "Hello from the fake harness: "+flags)
		case strings.Contains(words, "read"):
			input := map[string]any{"action": "read", "path": "notes.txt", "count": json.Number("12345678901234567890")}
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_tool", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_read", "name": cyfrs("files"), "input": input}}}})
			decision := askCYFR("files", input)
			updated, _ := decision["updatedInput"].(map[string]any)
			if result, ok := updated["result"].(string); ok {
				reply(uuids, "The file says: "+result)
			} else {
				reply(uuids, fmt.Sprintf("CYFR refused: %v", updated["error"]))
			}
		case strings.Contains(words, "own"):
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_own", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_own", "name": "Bash", "input": map[string]any{"command": "cat secret-of-the-folder"}}}}})
			decision := ask("Bash", map[string]any{"command": "cat secret-of-the-folder"})
			write(map[string]any{"type": "user", "parent_tool_use_id": nil, "message": map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_result", "tool_use_id": "toolu_own", "content": "FOLDER-CANARY " + fmt.Sprint(decision["behavior"])}}}})
			reply(uuids, "ran it")
		case strings.Contains(words, "rate"):
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "error": "rate_limit", "message": map[string]any{"id": "msg_err", "content": []any{
				map[string]any{"type": "text", "text": "API Error: please run /login HARNESS-WORDS"}}}})
			write(map[string]any{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1, "uuid": "result-err", "user_message_uuids": uuids, "usage": map[string]any{}})
		case strings.Contains(words, "uncounted"):
			replyWith(uuids, "no usage", nil)
		case strings.Contains(words, "partial"):
			replyWith(uuids, "some usage", map[string]any{"fake-opus": modelUsage["fake-opus"],
				"fake-haiku": map[string]any{"inputTokens": 7, "outputTokens": -1, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0}})
		case strings.Contains(words, "late"):
			reply(uuids, "early")
			time.Sleep(50 * time.Millisecond)
			write(map[string]any{"type": "system", "subtype": "init", "session_id": session})
			reply(nil, "a background task ended")
		case strings.Contains(words, "big"):
			reply(uuids, strings.Repeat("x", 2<<20))
		case strings.Contains(words, "modes"):
			var ids []string
			for _, tool := range []struct {
				name  string
				input map[string]any
			}{
				{"Write", map[string]any{"file_path": "/work/new.txt", "content": "x"}},
				{"Bash", map[string]any{"command": "touch new.txt"}},
			} {
				ask(tool.name, tool.input)
				ids = append(ids, fmt.Sprintf("ask-%d", asked))
			}
			answersMu.Lock()
			got := []any{}
			for _, id := range ids {
				got = append(got, wholes[id])
			}
			answersMu.Unlock()
			line, _ := json.Marshal(map[string]any{"argv": args, "answers": got})
			reply(uuids, string(line))
		case strings.Contains(words, "other"):
			// Registered before it is written, as ask does: an answer read
			// before its channel stands is dropped, and the turn never ends.
			answersMu.Lock()
			ch := make(chan map[string]any, 1)
			answers["hook-1"] = ch
			answersMu.Unlock()
			write(map[string]any{"type": "control_request", "request_id": "hook-1", "request": map[string]any{"subtype": "hook_callback"}})
			got := <-ch
			reply(uuids, fmt.Sprintf("the driver answered %v", got["subtype"]))
		case strings.Contains(words, "together"):
			next := <-work
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_both", "content": []any{
				map[string]any{"type": "text", "text": "both answered"}}}})
			write(map[string]any{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "uuid": "result-both",
				"user_message_uuid": uuid, "user_message_uuids": []string{uuid, next[0]}, "model_usage_since_last_result": modelUsage})
		case strings.Contains(words, "subagent"):
			task := "toolu_task"
			write(map[string]any{"type": "stream_event", "parent_tool_use_id": task, "event": map[string]any{"type": "content_block_delta",
				"delta": map[string]any{"type": "text_delta", "text": "SUBAGENT-WORDS"}}})
			write(map[string]any{"type": "assistant", "parent_tool_use_id": task, "message": map[string]any{"id": "msg_sub", "content": []any{
				map[string]any{"type": "text", "text": "SUBAGENT-WORDS"},
				map[string]any{"type": "tool_use", "id": "toolu_sub", "name": "Grep", "input": map[string]any{"pattern": "x"}}}}})
			write(map[string]any{"type": "user", "parent_tool_use_id": task, "message": map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_result", "tool_use_id": "toolu_sub", "content": "SUBAGENT-WORDS"}}}})
			reply(uuids, "the main reply")
		case strings.Contains(words, "around"):
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_around", "content": []any{
				map[string]any{"type": "text", "text": "before the call, "},
				map[string]any{"type": "tool_use", "id": "toolu_around", "name": cyfrs("files"), "input": map[string]any{}},
				map[string]any{"type": "text", "text": "after it"}}}})
			write(map[string]any{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "uuid": "result-around",
				"user_message_uuids": uuids, "model_usage_since_last_result": modelUsage})
		case strings.Contains(words, "theirs"):
			var ran []string
			_, own := held()
			for _, name := range own {
				tool := "mcp__" + name + "__theirs"
				use := "toolu_theirs_" + name
				write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_" + use, "content": []any{
					map[string]any{"type": "tool_use", "id": use, "name": tool, "input": map[string]any{}}}}})
				decision := askOf(tool, map[string]any{}, map[string]any{"name": name, "source": "user"}, use)
				updated, _ := decision["updatedInput"].(map[string]any)
				write(map[string]any{"type": "user", "parent_tool_use_id": nil, "message": map[string]any{"role": "user", "content": []any{
					map[string]any{"type": "tool_result", "tool_use_id": use, "content": "their server ran"}}}})
				ran = append(ran, fmt.Sprintf("%s:%v:%d", tool, decision["behavior"], len(updated)))
			}
			server, _ := held()
			reply(uuids, "their servers ran: "+strings.Join(ran, " ")+" beside "+server)
		case strings.Contains(words, "arrived"):
			var server map[string]any
			_ = json.Unmarshal([]byte(os.Getenv("FAKE_LATE_SERVER")), &server)
			tool, input := cyfrs("late"), map[string]any{"query": "theirs"}
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_late", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_late", "name": tool, "input": input}}}})
			decision := askOf(tool, input, server, "toolu_late")
			write(map[string]any{"type": "user", "parent_tool_use_id": nil, "message": map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_result", "tool_use_id": "toolu_late", "content": "their late server ran"}}}})
			answer, _ := json.Marshal(decision)
			reply(uuids, string(answer))
		case strings.Contains(words, "unended"):
			var server map[string]any
			_ = json.Unmarshal([]byte(os.Getenv("FAKE_LATE_SERVER")), &server)
			tool, input := cyfrs("late"), map[string]any{"query": "theirs"}
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_unended", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_late", "name": tool, "input": input}}}})
			askOf(tool, input, server, "toolu_late")
			reply(uuids, "ended with the call unanswered")
		case strings.Contains(words, "handed"):
			reply(uuids, string(initialized))
		case strings.Contains(words, "noise"):
			mu.Lock()
			out.WriteString("not a line of JSON\n")
			out.Flush()
			mu.Unlock()
			write(map[string]any{"type": "keep_alive"})
			write(map[string]any{"type": "stream_event", "parent_tool_use_id": nil, "event": "not an event"})
			reply(uuids, "still here")
		default:
			reply(uuids, "ok")
		}
	}
	go func() {
		for w := range work {
			turn(w[0], w[1])
		}
	}()
	in := bufio.NewReaderSize(os.Stdin, 1<<20)
	for {
		line, err := in.ReadBytes('\n')
		if len(line) > 0 {
			var message map[string]any
			if json.Unmarshal(line, &message) != nil {
				continue
			}
			switch message["type"] {
			case "control_request":
				request, _ := message["request"].(map[string]any)
				id := message["request_id"]
				switch request["subtype"] {
				case "initialize":
					initialized, _ = json.Marshal(request)
					answer := map[string]any{
						"models": []any{
							map[string]any{"value": "default", "displayName": "Default", "supportedEffortLevels": []string{"low", "high"}},
							map[string]any{"value": "fake-opus", "displayName": "Fake Opus", "supportedEffortLevels": []string{"low", "medium", "high", "max"}},
							map[string]any{"value": "fake-haiku", "displayName": "Fake Haiku"},
						}}
					if account := os.Getenv("FAKE_ACCOUNT"); account != "" {
						answer["account"] = json.RawMessage(account)
					}
					write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": answer}})
				case "mcp_status":
					listed := []any{}
					server, own := held()
					for _, name := range own {
						listed = append(listed, map[string]any{"name": name, "status": "pending", "scope": "user", "source": "user"})
					}
					if server != "" {
						listed = append(listed, map[string]any{"name": server, "status": "connected", "scope": "dynamic", "source": "dynamic"})
					}
					answer := map[string]any{"subtype": "success", "request_id": id, "response": map[string]any{"mcpServers": listed}}
					switch os.Getenv("FAKE_STATUS") {
					case "error":
						answer = map[string]any{"subtype": "error", "request_id": id, "error": "no status"}
					case "unlisted":
						answer["response"] = map[string]any{}
					}
					write(map[string]any{"type": "control_response", "response": answer})
				case "mcp_set_servers":
					servers, _ := request["servers"].(map[string]any)
					serversMu.Lock()
					dynamic = ""
					for name := range servers {
						dynamic = name
						delete(theirs, name)
					}
					set := dynamic
					serversMu.Unlock()
					errors := map[string]any{}
					if os.Getenv("FAKE_TOOLS_FAIL") != "" {
						errors[set] = "failed to start"
					}
					write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": map[string]any{"errors": errors}}})
				}
			case "control_response":
				response, _ := message["response"].(map[string]any)
				answersMu.Lock()
				ch := answers[fmt.Sprint(response["request_id"])]
				delete(answers, fmt.Sprint(response["request_id"]))
				wholes[fmt.Sprint(response["request_id"])] = message
				answersMu.Unlock()
				if ch != nil {
					inner, _ := response["response"].(map[string]any)
					if inner == nil {
						inner = map[string]any{"subtype": response["subtype"]}
					}
					ch <- inner
				}
			case "user":
				entry, _ := json.Marshal(map[string]any{"type": "user", "uuid": message["uuid"], "message": message["message"]})
				transcript.Write(append(entry, '\n'))
				inner, _ := message["message"].(map[string]any)
				content, _ := inner["content"].([]any)
				words := ""
				for _, block := range content {
					if b, ok := block.(map[string]any); ok && b["type"] == "text" {
						words = fmt.Sprint(b["text"])
					}
				}
				if os.Getenv("FAKE_EXIT_ON") != "" && strings.Contains(words, os.Getenv("FAKE_EXIT_ON")) {
					return 3
				}
				work <- [2]string{fmt.Sprint(message["uuid"]), words}
			}
		}
		if err != nil {
			close(work)
			return 0
		}
	}
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
