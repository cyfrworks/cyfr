// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf16"
)

// Claude Code's own protocol on its standard input and output, as the
// driver speaks it: the command line a session starts with, the lines
// written to it and the lines read back. It runs `-p` with stream-json in
// and out; every line is one JSON object: `user` messages and
// `control_request`/`control_response` in both directions. CYFR's tools
// reach it through `mcp_set_servers`, one MCP stdio server, `cyfr-stub`,
// given the tools on its command line, since an argument is bounded and a
// tool list is not; the system prompt goes on the `initialize` request as
// `appendSystemPrompt`, so the harness keeps its own prompt. These shapes
// were read from Claude Code 2.1.318
// (seed/components/catalysts/local/claude-code/0.1.8/src/src/harness.rs).

// baseArgv is what every session starts with: stream-json both ways,
// partial messages for streaming, no MCP server but the ones the driver
// sets, and every permission ask of the harness's put to the driver.
var baseArgv = []string{
	"-p",
	"--input-format", "stream-json",
	"--output-format", "stream-json",
	"--verbose",
	"--include-partial-messages",
	"--strict-mcp-config",
	"--permission-prompt-tool", "stdio",
}

const (
	stubServer = "cyfr"
	toolPrefix = "mcp__cyfr__"
	stubBinary = "cyfr-stub"
	initID     = "cyfr-initialize"
	toolsID    = "cyfr-tools"
	// maxToolArgBytes bounds one tool as the stub's argument: the kernel's
	// bound on one argument, with its NUL (MAX_ARG_STRLEN).
	maxToolArgBytes = 131071
	// maxResultChars is what Claude Code takes from one tool call through
	// `updatedInput`, measured on 2.1.318: 50,000 characters arrive whole,
	// 50,625 are replaced by its own note.
	maxResultChars = 50000
)

// harnessArgv is the harness's command line: its own command, then the
// base, the session and the start's configuration.
func harnessArgv(command []string, session string, resume bool, config startConfig) []string {
	argv := append([]string{}, command...)
	argv = append(argv, baseArgv...)
	if resume {
		argv = append(argv, "--resume", session)
	} else {
		argv = append(argv, "--session-id", session)
	}
	for _, pair := range [][2]string{
		{"--model", config.Model},
		{"--effort", config.Effort},
		{"--permission-mode", config.PermissionMode},
	} {
		if pair[1] != "" {
			argv = append(argv, pair[0], pair[1])
		}
	}
	if config.HarnessTools != nil {
		argv = append(argv, "--tools", strings.Join(*config.HarnessTools, ","))
	}
	return argv
}

// startConfig is a start's configuration: absent members are the
// harness's defaults.
type startConfig struct {
	Model          string    `json:"model"`
	Effort         string    `json:"effort"`
	PermissionMode string    `json:"permission_mode"`
	HarnessTools   *[]string `json:"harness_tools"`
}

func controlRequest(id string, request map[string]any) []byte {
	line, _ := marshal(map[string]any{"type": "control_request", "request_id": id, "request": request})
	return line
}

// initializeLine carries CYFR's system prompt, appended to the harness's.
func initializeLine(system string) []byte {
	request := map[string]any{"subtype": "initialize"}
	if system != "" {
		request["appendSystemPrompt"] = system
	}
	return controlRequest(initID, request)
}

// stubTool is one tool as the stub's argument.
func stubTool(t tool) (string, error) {
	line, err := marshal(map[string]any{"name": t.Name, "description": t.Description, "inputSchema": t.Parameters})
	return string(line), err
}

type tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"`
}

// setToolsLine sets CYFR's tools: the stub with each as one argument, or
// no server when there are none.
func setToolsLine(id string, args []string) []byte {
	servers := map[string]any{}
	if len(args) > 0 {
		servers[stubServer] = map[string]any{"type": "stdio", "command": stubBinary, "args": args}
	}
	return controlRequest(id, map[string]any{"subtype": "mcp_set_servers", "servers": servers})
}

// userLine is a user message of content blocks in the harness's (the
// Messages API's) shapes, under the uuid its results name it by.
func userLine(content []any, uuid string) []byte {
	line, _ := marshal(map[string]any{
		"type":               "user",
		"uuid":               uuid,
		"message":            map[string]any{"role": "user", "content": content},
		"parent_tool_use_id": nil,
		"session_id":         "",
	})
	return line
}

// harnessBlocks are the wire's content blocks in the Messages API's shapes.
func harnessBlocks(blocks []wireBlock) []any {
	out := make([]any, 0, len(blocks))
	for _, b := range blocks {
		if b.Type == "text" {
			out = append(out, map[string]any{"type": "text", "text": b.Text})
			continue
		}
		out = append(out, map[string]any{
			"type":   b.Type,
			"source": map[string]any{"type": "base64", "media_type": b.MediaType, "data": b.Data},
		})
	}
	return out
}

type wireBlock struct {
	Type      string `json:"type"`
	Text      string `json:"text"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
}

// allowLine allows the ask `id` with the input the call runs with.
func allowLine(id string, input any) []byte {
	line, _ := marshal(map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "success",
			"request_id": id,
			"response":   map[string]any{"behavior": "allow", "updatedInput": input},
		},
	})
	return line
}

// unansweredLine refuses a control request the driver does not answer.
func unansweredLine(id, subtype string) []byte {
	line, _ := marshal(map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "error",
			"request_id": id,
			"error":      fmt.Sprintf("CYFR does not answer %s", subtype),
		},
	})
	return line
}

// bounded is `content` within what Claude Code takes from one call, the
// rest named in a note.
func bounded(content string) string {
	total := len(utf16.Encode([]rune(content)))
	if total <= maxResultChars {
		return content
	}
	note := func(cut int) string {
		return fmt.Sprintf("\n…[CYFR cut this result at %d characters, what Claude Code takes from one call; %d more were not shown. Ask for a narrower part.]", maxResultChars, cut)
	}
	room := maxResultChars - len(utf16.Encode([]rune(note(total))))
	var kept strings.Builder
	used := 0
	for _, r := range content {
		width := len(utf16.Encode([]rune{r}))
		if used+width > room {
			break
		}
		used += width
		kept.WriteRune(r)
	}
	kept.WriteString(note(total - used))
	return kept.String()
}

// answeredInput is an ask's input with CYFR's answer: the call's arguments
// and the answer as `result`, or as `error` for a refusal, which the stub
// returns as the tool's content.
func answeredInput(arguments map[string]any, content string, isError bool) map[string]any {
	input := callArguments(arguments)
	key := "result"
	if isError {
		key = "error"
	}
	input[key] = bounded(content)
	return input
}

// callArguments are a call's arguments as the model made them, without
// the members the stub answers from.
func callArguments(input map[string]any) map[string]any {
	out := make(map[string]any, len(input))
	for k, v := range input {
		if k != "result" && k != "error" {
			out[k] = v
		}
	}
	return out
}

// errorKind is the wire's error type for an error the harness typed an
// assistant message with: its account's, the provider's, the request's
// or the model's.
func errorKind(err string) string {
	switch err {
	case "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required",
		"billing_error", "cloud_credential_error":
		return "authentication"
	case "rate_limit":
		return "rate_limited"
	case "overloaded":
		return "overloaded"
	case "invalid_request":
		return "invalid_request"
	case "model_not_found":
		return "unknown_model"
	}
	return "provider_error"
}

// errorSentence is the driver's own words for an error of the harness's:
// the harness's words (a sign-in prompt among them) never leave the box.
func errorSentence(kind string) string {
	switch kind {
	case "authentication":
		return "Claude Code is not signed in to an account that can run this; sign in on the program's terminal."
	case "rate_limited":
		return "Claude Code reported a rate limit; ask again later."
	case "overloaded":
		return "Claude Code reported its provider overloaded; ask again later."
	case "invalid_request":
		return "Claude Code refused the request as invalid."
	case "unknown_model":
		return "Claude Code does not know the model asked for."
	}
	return "Claude Code reported an error of its provider."
}

// harnessLine is one line of the harness's output, as far as the driver
// reads it.
type harnessLine struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	Status          string          `json:"status"`
	UUID            string          `json:"uuid"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
	UserMessageIDs  []string        `json:"user_message_uuids"`
	Event           json.RawMessage `json:"event"`
	Message         json.RawMessage `json:"message"`
	Error           *string         `json:"error"`
	IsError         *bool           `json:"is_error"`
	NumTurns        *int            `json:"num_turns"`
	Errors          []any           `json:"errors"`
	Usage           json.RawMessage `json:"usage"`
	RequestID       string          `json:"request_id"`
	Request         json.RawMessage `json:"request"`
	Response        json.RawMessage `json:"response"`
}

// main is a line of the main session, not of a subagent's.
func (l *harnessLine) main() bool { return l.ParentToolUseID == nil || *l.ParentToolUseID == "" }

// noConversation is the result a `--resume` of a session the folder holds
// no transcript of ends with, as Claude Code 2.1.318 wrote it: no turn
// ran, and its errors name the session in these words.
func (l *harnessLine) noConversation() bool {
	if l.Type != "result" || l.NumTurns == nil || *l.NumTurns != 0 {
		return false
	}
	for _, e := range l.Errors {
		if s, ok := e.(string); ok && strings.HasPrefix(s, "No conversation found with session ID") {
			return true
		}
	}
	return false
}

// counts are the wire's counts from the harness's (the Messages API's)
// usage.
func counts(raw json.RawMessage) map[string]uint64 {
	var usage map[string]any
	_ = json.Unmarshal(raw, &usage)
	count := func(key string) uint64 {
		if f, ok := usage[key].(float64); ok && f > 0 {
			return uint64(f)
		}
		return 0
	}
	return map[string]uint64{
		"input_tokens":       count("input_tokens"),
		"output_tokens":      count("output_tokens"),
		"cache_read_tokens":  count("cache_read_input_tokens"),
		"cache_write_tokens": count("cache_creation_input_tokens"),
	}
}
