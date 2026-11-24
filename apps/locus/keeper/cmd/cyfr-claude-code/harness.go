// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"
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
//
// The MCP servers a person set up in Claude Code itself (its user, local
// and project configuration, a plugin's) stay beside CYFR's, as Codex's
// stay beside its: they are the program's own, which CYFR neither decides
// nor removes, hides or switches off. Claude Code starts them as it
// starts, apart from the turn: one that fails to start, or wants a
// sign-in, is left failed, and one that never answers is given up at
// Claude Code's own connect timeout, 30 s (`MCP_TIMEOUT`), while the start
// and the turn go on (2.1.323). Their calls are the program's own tools,
// allowed like the rest, never CYFR's asks: none passes CYFR's gate, the
// Aqua page's list or a member's access, which decide only what CYFR hands
// the harness. A member's access (Default mode alone today) is Claude
// Code's own setting over what it does with its own tools, and the driver
// allows every call of theirs as it allows the rest: what a person's server
// does when called is that server's, which no access covers, a read-only
// one included were one offered.

// baseArgv is what every session starts with: stream-json both ways,
// partial messages for streaming, and every permission ask of the
// harness's put to the driver.
var baseArgv = []string{
	"-p",
	"--input-format", "stream-json",
	"--output-format", "stream-json",
	"--verbose",
	"--include-partial-messages",
	"--permission-prompt-tool", "stdio",
}

const (
	// stubServer is the name CYFR's server takes unless a server of the
	// person's own holds it (serverFor).
	stubServer = "cyfr"
	// stubBinary is CYFR's stub by its absolute path in the image
	// (Dockerfile.locus), never by name: npx puts a project's own package
	// binaries ahead of the PATH it inherits, so a name could run another.
	stubBinary = "/opt/cyfr/bin/cyfr-stub"
	initID     = "cyfr-initialize"
	statusID   = "cyfr-status"
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

// statusLine asks the harness for its MCP servers, the person's own among
// them, which it names as soon as it has read its configuration, before
// any has started.
func statusLine() []byte {
	return controlRequest(statusID, map[string]any{"subtype": "mcp_status"})
}

// listedServers are the servers' names a `mcp_status` answer lists, and
// whether it lists them: `mcpServers` a list, empty when there are none.
// An answer that lists none, or names a server without a name, says
// nothing of the person's servers, so no name can be chosen beside them.
func listedServers(response json.RawMessage) ([]string, bool) {
	var status struct {
		Servers *[]struct {
			Name string `json:"name"`
		} `json:"mcpServers"`
	}
	if json.Unmarshal(response, &status) != nil || status.Servers == nil {
		return nil, false
	}
	names := make([]string, 0, len(*status.Servers))
	for _, s := range *status.Servers {
		if s.Name == "" {
			return nil, false
		}
		names = append(names, s.Name)
	}
	return names, true
}

// serverFor is the name CYFR's server takes beside the servers the harness
// lists: `cyfr`, or else the first of `cyfr-2`, `cyfr-3`… that no listed
// server takes. Claude Code names a tool `mcp__<server>__<tool>`, each
// character of the server's name that is not a letter, a digit, `_` or
// `-` written `_`, and a server the driver sets replaces one of the
// person's of the same name, and a tool of the same whole name, for the
// life of the process (2.1.323). A listed server takes a name when its
// tools' prefix, `mcp__<its name so written>__`, begins with that name's,
// `mcp__<name>__`: then a tool of theirs could be spelled as one of
// CYFR's. So neither shadows the other: no server of theirs is named as
// CYFR's, and no tool of theirs begins with CYFR's prefix.
func serverFor(listed []string) string {
	taken := func(name string) bool {
		for _, other := range listed {
			if strings.HasPrefix(toolPrefix(toolNamePart(other)), toolPrefix(name)) {
				return true
			}
		}
		return false
	}
	name := stubServer
	for n := 2; taken(name); n++ {
		name = fmt.Sprintf("%s-%d", stubServer, n)
	}
	return name
}

// toolNamePart is a server's name as Claude Code writes it in its tools'.
func toolNamePart(server string) string {
	return strings.Map(func(r rune) rune {
		if r == '_' || r == '-' || r < 128 && (unicode.IsLetter(r) || unicode.IsDigit(r)) {
			return r
		}
		return '_'
	}, server)
}

// toolPrefix begins the name of each tool of CYFR's server `server`.
func toolPrefix(server string) string { return "mcp__" + server + "__" }

// stubTool is one tool as the stub's argument.
func stubTool(t brainwire.Tool) (string, error) {
	line, err := brainwire.StubArgument(t)
	return string(line), err
}

// setToolsLine sets CYFR's tools: the stub `server` with each as one
// argument, or no server when there are none. It sets only the servers the
// driver sets; the person's own are untouched.
func setToolsLine(id, server string, args []string) []byte {
	servers := map[string]any{}
	if len(args) > 0 {
		servers[server] = map[string]any{"type": "stdio", "command": stubBinary, "args": args}
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

// answerWait bounds the harness's answer to a start (its `initialize` and
// its `mcp_status`) and to a work's `mcp_set_servers`, the answers the
// driver holds a command for, as listingWait bounds a listing's: 2.1.323
// answers each within a second (measured), and a start's first fetch of
// the program is a listing's. A var, so a test can shorten it.
var answerWait = listingWait

// toolsLateSentence refuses a work whose tools the harness did not start
// within answerWait.
func toolsLateSentence() string {
	return fmt.Sprintf("Claude Code did not start CYFR's tools within %d seconds, so the work was not begun; send it again.", int(answerWait/time.Second))
}

// unsendableSentence is the driver's words for a turn whose request the
// API refused for a message of the session's own history: a previous
// message id it does not take (Claude Code 2.1.323 ended every later turn
// of such a session so, its request's 400). Nothing the person sent was
// invalid, and the session cannot go on, so the driver removes it
// (result): the next message starts a fresh session from the thread's
// posts.
const unsendableSentence = "Claude Code's session holds a message its model's API no longer takes, so this session could not go on; nothing you sent was refused. Your next message starts a fresh one from this thread's posts."

// unsendableWords are the API's words, in a failed result's `result`, for
// that refusal; they are read there alone, never in what the model said.
const unsendableWords = "diagnostics.previous_message_id"

// refusalSentence is the driver's words for a turn the model refused to
// answer and kept to (a result whose stop is `refusal`, 2.1.323): no
// request of the person's was invalid, so it is said as what it is.
const refusalSentence = "Claude Code's model declined to answer this; rephrase the request, or choose another model."

// limitSentence says a rate limit, and when it lifts when the harness said
// (rejectedUntil).
func limitSentence(resets int64) string {
	return "Claude Code reported a rate limit; " + brainwire.UntilWords(resets) + "."
}

// rejectedUntil is when a limit lifts by a `rate_limit_event`'s
// `rate_limit_info`, in the shape T3 Code reads from a subscription's
// session (ClaudeAdapterV2.ts: `status`, and `resetsAt` in Unix seconds; a
// key's session sends none, as 2.1.323 sent none on one): its reset while
// its status is `rejected`, or 0, a limit not reached or one that does not
// read.
func rejectedUntil(info json.RawMessage) int64 {
	var limit struct {
		Status string  `json:"status"`
		Resets float64 `json:"resetsAt"`
	}
	if json.Unmarshal(info, &limit) != nil || limit.Status != "rejected" || limit.Resets <= 0 {
		return 0
	}
	return int64(limit.Resets)
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
		return limitSentence(0)
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
	APIErrorStatus  *int            `json:"api_error_status"`
	StopReason      string          `json:"stop_reason"`
	Result          json.RawMessage `json:"result"`
	RateLimitInfo   json.RawMessage `json:"rate_limit_info"`
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
