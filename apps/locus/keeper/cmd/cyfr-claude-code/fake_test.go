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
//	big    replies with 2 MiB of text
//	other  asks the driver a control request of another kind, then replies
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
			said := "No conversation found with session ID: " + resume
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
	var answersMu sync.Mutex
	asked := 0
	ask := func(tool string, input map[string]any) map[string]any {
		answersMu.Lock()
		asked++
		id := fmt.Sprintf("ask-%d", asked)
		ch := make(chan map[string]any, 1)
		answers[id] = ch
		answersMu.Unlock()
		write(map[string]any{"type": "control_request", "request_id": id, "request": map[string]any{
			"subtype": "can_use_tool", "tool_name": tool, "input": input, "tool_use_id": fmt.Sprintf("toolu_%d", asked)}})
		return <-ch
	}
	turns := 0
	reply := func(uuids []string, text string) {
		turns++
		message := fmt.Sprintf("msg_fake_%d", turns)
		write(map[string]any{"type": "stream_event", "parent_tool_use_id": nil, "event": map[string]any{"type": "message_start", "message": map[string]any{"id": message}}})
		half := len(text) / 2
		for _, piece := range []string{text[:half], text[half:]} {
			write(map[string]any{"type": "stream_event", "parent_tool_use_id": nil, "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": piece}}})
		}
		write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": message, "content": []any{map[string]any{"type": "text", "text": text}}}})
		write(map[string]any{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "uuid": fmt.Sprintf("result-uuid-%d", turns),
			"user_message_uuids": uuids, "usage": map[string]any{"input_tokens": 12, "output_tokens": 3, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2}})
	}
	turn := func(uuid, words string) {
		uuids := []string{uuid}
		write(map[string]any{"type": "system", "subtype": "init", "session_id": session, "user_message_uuids": uuids})
		switch {
		case strings.Contains(words, "hello"):
			reply(uuids, "Hello from the fake harness: "+flags)
		case strings.Contains(words, "read"):
			input := map[string]any{"action": "read", "path": "notes.txt", "count": json.Number("12345678901234567890")}
			write(map[string]any{"type": "assistant", "parent_tool_use_id": nil, "message": map[string]any{"id": "msg_tool", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_read", "name": toolPrefix + "files", "input": input}}}})
			decision := ask(toolPrefix+"files", input)
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
		case strings.Contains(words, "late"):
			reply(uuids, "early")
			time.Sleep(50 * time.Millisecond)
			write(map[string]any{"type": "system", "subtype": "init", "session_id": session})
			reply(nil, "a background task ended")
		case strings.Contains(words, "big"):
			reply(uuids, strings.Repeat("x", 2<<20))
		case strings.Contains(words, "other"):
			write(map[string]any{"type": "control_request", "request_id": "hook-1", "request": map[string]any{"subtype": "hook_callback"}})
			answersMu.Lock()
			ch := make(chan map[string]any, 1)
			answers["hook-1"] = ch
			answersMu.Unlock()
			got := <-ch
			reply(uuids, fmt.Sprintf("the driver answered %v", got["subtype"]))
		default:
			reply(uuids, "ok")
		}
	}
	work := make(chan [2]string, 16)
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
					write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": map[string]any{
						"models": []any{
							map[string]any{"value": "default", "displayName": "Default", "supportedEffortLevels": []string{"low", "high"}},
							map[string]any{"value": "fake-opus", "displayName": "Fake Opus", "supportedEffortLevels": []string{"low", "medium", "high", "max"}},
							map[string]any{"value": "fake-haiku", "displayName": "Fake Haiku"},
						}}}})
				case "mcp_set_servers":
					errors := map[string]any{}
					if os.Getenv("FAKE_TOOLS_FAIL") != "" {
						errors["cyfr"] = "failed to start"
					}
					write(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": id, "response": map[string]any{"errors": errors}}})
				}
			case "control_response":
				response, _ := message["response"].(map[string]any)
				answersMu.Lock()
				ch := answers[fmt.Sprint(response["request_id"])]
				delete(answers, fmt.Sprint(response["request_id"]))
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
