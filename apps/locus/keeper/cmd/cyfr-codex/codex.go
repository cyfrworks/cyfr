// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"sort"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// Codex's app-server protocol on its standard input and output, as the
// driver speaks it: JSON-RPC 2.0 messages without the `jsonrpc` member, one
// per line. The driver sends requests (`initialize`, `account/read`,
// `model/list`, `thread/start`, `thread/resume`, `turn/start`,
// `turn/steer`, `thread/delete`) and the `initialized` notification, and
// answers Codex's own requests: `item/tool/call` for CYFR's tools, given
// to the thread as its dynamic tools, held until CYFR answers it and then
// answered by its request's id; the approvals, which are allowed; and
// `currentTime/read`. Every other request is refused. These shapes are the
// ones the catalyst read from Codex 0.167.0
// (seed/components/catalysts/local/openai-codex/0.1.6/src/src/server.rs
// and chat.rs), held on 0.169.0, the version a brain row pins, against its
// own schema (`codex app-server generate-json-schema`) and the binary.

// appServer is the harness's command line's own argument.
const appServer = "app-server"

// How a thread runs inside the keeper's box (the user's ruling D2): the box
// is the only boundary. Codex's own sandbox is off, since it would nest a
// second sandbox inside the box's and its namespaces are not the box's to
// grant, and it asks for nothing: its commands and patches run as the box
// lets them, and are shown by name only.
const (
	approvalPolicy = "never"
	sandbox        = "danger-full-access"
)

// ownTools are the types of Codex's thread items that are its own tools,
// shown as `own` by that name.
var ownTools = map[string]bool{
	"commandExecution": true, "fileChange": true, "mcpToolCall": true, "webSearch": true,
	"imageView": true, "imageGeneration": true, "collabAgentToolCall": true,
}

// mediaTypes are the images Codex takes as input (by data URL); it takes no
// document.
var mediaTypes = map[string]bool{"image/jpeg": true, "image/png": true, "image/gif": true, "image/webp": true}

// listingPages bounds the pages of Codex's model listing read.
const listingPages = 10

func request(id, method string, params any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"id": id, "method": method, "params": params})
	return line
}

// initializeLine opts into the experimental API: `thread/start`'s
// `dynamicTools`, which carry CYFR's tools, is an experimental field.
func initializeLine(id string) []byte {
	return request(id, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "cyfr", "title": "CYFR", "version": "1"},
		"capabilities": map[string]any{"experimentalApi": true},
	})
}

func initializedLine() []byte {
	line, _ := brainwire.Marshal(map[string]any{"method": "initialized"})
	return line
}

// dynamicTool is one of CYFR's tools as a thread's dynamic tool.
func dynamicTool(t brainwire.Tool) map[string]any {
	return map[string]any{"type": "function", "name": t.Name, "description": t.Description, "inputSchema": t.Parameters}
}

// dynamicName is a dynamic tool's name as Codex takes one
// (`validate_dynamic_tools`): `^[a-zA-Z0-9_-]+$`, at most 128 characters,
// never `mcp` or `mcp__…`, which Codex keeps for itself.
func dynamicName(name string) bool {
	if name == "" || len(name) > 128 || name == "mcp" || len(name) >= 5 && name[:5] == "mcp__" {
		return false
	}
	for _, c := range []byte(name) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// dynamicTools are a start's tools as a new thread's, or why Codex cannot
// be given them whole: nothing is cut.
func dynamicTools(tools []brainwire.Tool) ([]map[string]any, error) {
	out := make([]map[string]any, 0, len(tools))
	seen := map[string]bool{}
	for _, t := range tools {
		if !dynamicName(t.Name) {
			return nil, fmt.Errorf("the tool %q has a name Codex does not take: letters, digits, _ and - only, never mcp", t.Name)
		}
		if seen[t.Name] {
			return nil, fmt.Errorf("the tool %q is named twice", t.Name)
		}
		seen[t.Name] = true
		out = append(out, dynamicTool(t))
	}
	return out, nil
}

// threadStart starts a new thread under the box's policy, with CYFR's system
// prompt as developer instructions beside Codex's own, CYFR's tools as its
// dynamic tools, which the thread keeps for its life, and the start's model.
func threadStart(id string, system string, tools []map[string]any, config brainwire.Config) []byte {
	params := map[string]any{"approvalPolicy": approvalPolicy, "sandbox": sandbox, "dynamicTools": tools}
	if system != "" {
		params["developerInstructions"] = system
	}
	if config.Model != "" {
		params["model"] = config.Model
	}
	return request(id, "thread/start", params)
}

// threadResume resumes the thread the folder holds, which keeps the dynamic
// tools it was started with.
func threadResume(id, thread, system string, config brainwire.Config) []byte {
	params := map[string]any{"threadId": thread, "approvalPolicy": approvalPolicy, "sandbox": sandbox, "excludeTurns": true}
	if system != "" {
		params["developerInstructions"] = system
	}
	if config.Model != "" {
		params["model"] = config.Model
	}
	return request(id, "thread/resume", params)
}

// turnStart starts a turn of `input` under the post's uuid, with the
// start's effort, which Codex takes per turn.
func turnStart(id, thread string, input []any, uuid string, config brainwire.Config) []byte {
	params := map[string]any{"threadId": thread, "input": input, "clientUserMessageId": uuid}
	if config.Effort != "" {
		params["effort"] = config.Effort
	}
	return request(id, "turn/start", params)
}

// turnSteer adds `input` to the turn `turn` while it is under way, under the
// post's uuid; Codex refuses it once that turn is not (-32600, "no active
// turn to steer") and opens no turn.
func turnSteer(id, thread, turn string, input []any, uuid string) []byte {
	return request(id, "turn/steer", map[string]any{"threadId": thread, "expectedTurnId": turn, "input": input, "clientUserMessageId": uuid})
}

// inputItems are a post's blocks as Codex's input items, or why one cannot
// be: Codex takes text and images.
func inputItems(blocks []brainwire.Block) ([]any, error) {
	out := make([]any, 0, len(blocks))
	for _, b := range blocks {
		switch {
		case b.Type == "text":
			out = append(out, map[string]any{"type": "text", "text": b.Text, "text_elements": []any{}})
		case b.Type == "image" && mediaTypes[b.MediaType]:
			out = append(out, map[string]any{"type": "image", "url": "data:" + b.MediaType + ";base64," + b.Data})
		default:
			return nil, fmt.Errorf("a %s block", b.Type)
		}
	}
	return out, nil
}

// answerLine answers Codex's request `id` with `result`.
func answerLine(id json.RawMessage, result any) []byte {
	line, _ := brainwire.Marshal(map[string]any{"id": id, "result": result})
	return line
}

// toolAnswer answers an `item/tool/call`: CYFR's answer as one text item,
// and whether CYFR ran the call.
func toolAnswer(id json.RawMessage, text string, success bool) []byte {
	return answerLine(id, map[string]any{"contentItems": []any{map[string]any{"type": "inputText", "text": text}}, "success": success})
}

// refuseLine refuses a request of Codex's the driver does not answer.
func refuseLine(id json.RawMessage, method string) []byte {
	line, _ := brainwire.Marshal(map[string]any{"id": id, "error": map[string]any{"code": -32601, "message": "CYFR does not answer " + method}})
	return line
}

// allowed is the answer to an approval request, by its method, or false for
// a request that is no approval. `currentTime/read` is no approval but a
// question Codex's clock asks its client, which only the driver can answer.
func allowed(method string, params json.RawMessage, now int64) (any, bool) {
	switch method {
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
		return map[string]any{"decision": "accept"}, true
	case "execCommandApproval", "applyPatchApproval":
		return map[string]any{"decision": "approved"}, true
	case "item/permissions/requestApproval":
		var p struct {
			Permissions json.RawMessage `json:"permissions"`
		}
		_ = json.Unmarshal(params, &p)
		if p.Permissions == nil {
			p.Permissions = json.RawMessage("null")
		}
		return map[string]any{"permissions": p.Permissions, "scope": "turn"}, true
	case "mcpServer/elicitation/request":
		return map[string]any{"action": "accept", "content": nil}, true
	case "currentTime/read":
		return map[string]any{"currentTimeAt": now}, true
	}
	return nil, false
}

// rpc is one line of Codex's, as far as the driver reads it: a response to
// a request of the driver's (an id, no method), a request of Codex's (an
// id and a method) or a notification (a method alone).
type rpc struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// item is a thread item, as far as the driver reads one.
type item struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	ClientID string `json:"clientId"`
	Text     string `json:"text"`
}

// notice is a notification's parameters, as far as the driver reads them.
type notice struct {
	ThreadID   string          `json:"threadId"`
	TurnID     string          `json:"turnId"`
	ItemID     string          `json:"itemId"`
	Delta      string          `json:"delta"`
	Item       item            `json:"item"`
	ToModel    string          `json:"toModel"`
	TokenUsage json.RawMessage `json:"tokenUsage"`
	Turn       struct {
		ID     string          `json:"id"`
		Status string          `json:"status"`
		Error  json.RawMessage `json:"error"`
	} `json:"turn"`
	RequestID json.RawMessage `json:"requestId"`
}

// codexCounts are the wire's counts by the names Codex gives them in a
// thread's token usage (`TokenUsageBreakdown`): input with cached input
// among it, as the Responses API counts it, output with reasoning among
// it, cached input, and cache writes. Its reasoning output and its total
// are inside those, so neither is counted again.
var codexCounts = map[string]string{
	"input_tokens":       "inputTokens",
	"output_tokens":      "outputTokens",
	"cache_read_tokens":  "cachedInputTokens",
	"cache_write_tokens": "cacheWriteInputTokens",
}

// threadTotal reads a `thread/tokenUsage/updated`'s `tokenUsage` as the
// wire carries a total: the thread's counts so far, across every model it
// ran, as one entry under the model the thread runs now. Its `last` is not
// read: Codex sends a total again unchanged whenever its rate limits
// update, so counting each `last` would count a call twice. No total is
// "unavailable", never zeros; a total one of whose counts does not read is
// "partial", naming no model's counts, since a thread has one entry.
func threadTotal(raw json.RawMessage, model string) (string, []brainwire.ModelCounts) {
	var usage struct {
		Total map[string]json.RawMessage `json:"total"`
	}
	if json.Unmarshal(raw, &usage) != nil || usage.Total == nil {
		return "unavailable", nil
	}
	counts := map[string]uint64{}
	names := make([]string, 0, len(codexCounts))
	for name := range codexCounts {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		var n uint64
		value := usage.Total[codexCounts[name]]
		if !brainwire.IsCount(value) || json.Unmarshal(value, &n) != nil {
			return "partial", []brainwire.ModelCounts{}
		}
		counts[name] = n
	}
	if !brainwire.IsID(model) {
		return "partial", []brainwire.ModelCounts{}
	}
	return "complete", []brainwire.ModelCounts{{Model: model, Counts: counts}}
}

// errorKind is the wire's error type for the error a turn failed with, by
// its `codexErrorInfo`: the account's, the provider's, the request's or
// the model's.
func errorKind(raw json.RawMessage) string {
	var e struct {
		Info json.RawMessage `json:"codexErrorInfo"`
	}
	_ = json.Unmarshal(raw, &e)
	var plain string
	status := uint64(0)
	if json.Unmarshal(e.Info, &plain) != nil {
		// A variant carrying an HTTP status is `{variant: {httpStatusCode}}`.
		var variant map[string]struct {
			Status uint64 `json:"httpStatusCode"`
		}
		_ = json.Unmarshal(e.Info, &variant)
		for _, v := range variant {
			status = v.Status
		}
	}
	switch {
	case plain == "unauthorized" || status == 401 || status == 403:
		return "authentication"
	case plain == "usageLimitExceeded" || plain == "rateLimitExceeded" || status == 429:
		return "rate_limited"
	case plain == "serverOverloaded" || status == 503 || status == 529:
		return "overloaded"
	case plain == "badRequest" || plain == "contextWindowExceeded":
		return "invalid_request"
	case plain == "modelNotFound":
		return "unknown_model"
	}
	return "provider_error"
}

// errorSentence is the driver's own words for an error of Codex's: its
// words, which name its account, its endpoint or a sign-in, never leave the
// box.
func errorSentence(kind string) string {
	switch kind {
	case "authentication":
		return "OpenAI Codex is not signed in to an account that can run this; sign in on the program's terminal."
	case "rate_limited":
		return "OpenAI Codex reported a usage or rate limit; ask again later."
	case "overloaded":
		return "OpenAI Codex reported its provider overloaded; ask again later."
	case "invalid_request":
		return "OpenAI Codex refused the request as invalid, or its context is full."
	case "unknown_model":
		return "OpenAI Codex does not know the model asked for."
	}
	return "OpenAI Codex reported an error of its provider."
}
