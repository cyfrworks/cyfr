// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"unicode/utf16"

	"github.com/cyfr/locus/keeper/internal/brainwire"
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
// were read from Claude Code 2.1.318 and held on 2.1.323, the version a
// brain row pins, in the live probe.

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
	// `updatedInput`, measured on 2.1.318 (not measured again on the pinned
	// 2.1.323): 50,000 characters arrive whole, 50,625 are replaced by its
	// own note.
	maxResultChars = 50000
)

// accessChoices are the access choices the driver lists, each with the
// arguments Claude Code starts and resumes with in it; a start naming none
// runs in the first. Default mode is the harness's default permission
// mode: it asks the driver before each of its own tools, which the driver
// allows, and before each of CYFR's, which CYFR's gate decides.
var accessChoices = []brainwire.Access[[]string]{
	{Choice: brainwire.Choice{ID: "default", Name: "Default mode"}, Native: []string{"--permission-mode", "default"}},
}

// harnessArgv is the harness's command line: its own command, then the
// base, the session, the start's model and effort, its access's arguments
// and the harness's own tools.
func harnessArgv(command []string, session string, resume bool, config brainwire.Config, access []string) []string {
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
	} {
		if pair[1] != "" {
			argv = append(argv, pair[0], pair[1])
		}
	}
	argv = append(argv, access...)
	if config.HarnessTools != nil {
		argv = append(argv, "--tools", strings.Join(*config.HarnessTools, ","))
	}
	return argv
}

func controlRequest(id string, request map[string]any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"type": "control_request", "request_id": id, "request": request})
	return line
}

// initializeLine carries CYFR's system prompt, appended to the harness's.
// The snapshot is off at every start: with it, a resume replays the prompt
// the session was first started with and never reads this one (2.1.323).
func initializeLine(system string) []byte {
	request := map[string]any{"subtype": "initialize", "systemPromptSnapshot": false}
	if system != "" {
		request["appendSystemPrompt"] = system
	}
	return controlRequest(initID, request)
}

// stubTool is one tool as the stub's argument.
func stubTool(t brainwire.Tool) (string, error) {
	line, err := brainwire.Marshal(map[string]any{"name": t.Name, "description": t.Description, "inputSchema": t.Parameters})
	return string(line), err
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
	line, _ := brainwire.Marshal(map[string]any{
		"type":               "user",
		"uuid":               uuid,
		"message":            map[string]any{"role": "user", "content": content},
		"parent_tool_use_id": nil,
		"session_id":         "",
	})
	return line
}

// harnessBlocks are the wire's content blocks in the Messages API's shapes.
func harnessBlocks(blocks []brainwire.Block) []any {
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

// allowLine allows the ask `id` with the input the call runs with.
func allowLine(id string, input any) []byte {
	line, _ := brainwire.Marshal(map[string]any{
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
	line, _ := brainwire.Marshal(map[string]any{
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
// An account's error says only what the type tells: the account or key
// the program ran with was refused, its sign-in or a key in its
// environment, never which one; the Codex driver says it alike.
func errorSentence(kind string) string {
	switch kind {
	case "authentication":
		return "The account or key Claude Code used was refused; check its sign-in on the program's terminal, or a key in its settings."
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
	ModelUsage      json.RawMessage `json:"model_usage_since_last_result"`
	RequestID       string          `json:"request_id"`
	Request         json.RawMessage `json:"request"`
	Response        json.RawMessage `json:"response"`
}

// main is a line of the main session, not of a subagent's.
func (l *harnessLine) main() bool { return l.ParentToolUseID == nil || *l.ParentToolUseID == "" }

// noTranscript is the result a `--resume` of a session the folder holds
// no transcript of ends with, as Claude Code 2.1.318 wrote it and the
// pinned 2.1.323 still did in the live probe: no turn
// ran, and its errors name the session in the harness's own words
// (claude_words.go).
func (l *harnessLine) noTranscript() bool {
	if l.Type != "result" || l.NumTurns == nil || *l.NumTurns != 0 {
		return false
	}
	for _, e := range l.Errors {
		if s, ok := e.(string); ok && strings.HasPrefix(s, noTranscriptWords) {
			return true
		}
	}
	return false
}

// harnessCounts are the wire's counts by the names the harness gives
// them in each model's usage. Its thinking tokens are already inside its
// output tokens and its cache writes of either lifetime inside its cache
// writes, so neither is counted again.
var harnessCounts = map[string]string{
	"input_tokens":       "inputTokens",
	"output_tokens":      "outputTokens",
	"cache_read_tokens":  "cacheReadInputTokens",
	"cache_write_tokens": "cacheCreationInputTokens",
}

// accounting reads a result's usage as Claude Code 2.1.323 reports it:
// `model_usage_since_last_result`, each model's usage of every request
// the harness made since its last result, its side requests included,
// keyed by the model. The result's own `usage` counts the main requests
// alone, which that already holds, so it is not read: adding it would
// count them twice. A result with no such usage, as before the
// harness's first request, is "unavailable", never zeros; one with an
// entry or a count that does not read is "partial", with the models that
// did; otherwise "complete".
func accounting(raw json.RawMessage) (string, []brainwire.ModelCounts) {
	var byModel map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &byModel) != nil || byModel == nil {
		return "unavailable", nil
	}
	names := make([]string, 0, len(byModel))
	for name := range byModel {
		names = append(names, name)
	}
	sort.Strings(names)
	read := "complete"
	models := []brainwire.ModelCounts{}
	for _, name := range names {
		counts, ok := modelCountsOf(byModel[name])
		if !ok || !brainwire.IsID(name) || len(models) == brainwire.MaxList {
			read = "partial"
			continue
		}
		models = append(models, brainwire.ModelCounts{Model: name, Counts: counts})
	}
	return read, models
}

func modelCountsOf(raw json.RawMessage) (map[string]uint64, bool) {
	var usage map[string]json.RawMessage
	if json.Unmarshal(raw, &usage) != nil || usage == nil {
		return nil, false
	}
	counts := map[string]uint64{}
	for name, key := range harnessCounts {
		var n uint64
		if !brainwire.IsCount(usage[key]) || json.Unmarshal(usage[key], &n) != nil {
			return nil, false
		}
		counts[name] = n
	}
	return counts, true
}
