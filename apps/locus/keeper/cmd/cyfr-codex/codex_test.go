// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A failed turn's error is typed by its `codexErrorInfo`, a variant by
// name or one carrying an HTTP status, and said in the driver's own words,
// whatever Codex's were.
func TestATurnsErrorIsTypedByItsInfoInTheDriversWords(t *testing.T) {
	sentences := map[string]string{
		"authentication":  "The account or key OpenAI Codex used was refused; check its sign-in on the program's terminal, or a key in its settings.",
		"rate_limited":    "OpenAI Codex reported a usage or rate limit; ask again later.",
		"overloaded":      "OpenAI Codex reported its provider overloaded; ask again later.",
		"invalid_request": "OpenAI Codex refused the request as invalid, or its context is full.",
		"unknown_model":   "OpenAI Codex does not know the model asked for.",
		"provider_error":  "OpenAI Codex reported an error of its provider.",
	}
	info := func(info string) string {
		return `{"message":"HARNESS-WORDS unexpected status, sign in at https://example.invalid","codexErrorInfo":` + info + `}`
	}
	status := func(code int) string {
		return info(fmt.Sprintf(`{"responseStreamConnectionFailed":{"httpStatusCode":%d}}`, code))
	}
	for _, c := range []struct{ error, kind string }{
		{info(`"unauthorized"`), "authentication"},
		{status(401), "authentication"},
		{status(403), "authentication"},
		{info(`"usageLimitExceeded"`), "rate_limited"},
		{info(`"rateLimitExceeded"`), "rate_limited"},
		{status(429), "rate_limited"},
		{info(`"serverOverloaded"`), "overloaded"},
		{status(503), "overloaded"},
		{status(529), "overloaded"},
		{info(`"badRequest"`), "invalid_request"},
		{info(`"contextWindowExceeded"`), "invalid_request"},
		{info(`"modelNotFound"`), "unknown_model"},
		{info(`"internalServerError"`), "provider_error"},
		{status(500), "provider_error"},
		{info(`null`), "provider_error"},
		{`{"message":"HARNESS-WORDS"}`, "provider_error"},
		{`null`, "provider_error"},
		{``, "provider_error"},
	} {
		kind := errorKind(json.RawMessage(c.error))
		if kind != c.kind || errorSentence(kind) != sentences[c.kind] {
			t.Fatalf("%s is %s, said %q: %s, said %q", c.error, c.kind, sentences[c.kind], kind, errorSentence(kind))
		}
	}
}

// Every approval Codex asks for is allowed in its own method's answer, the
// time is answered, and a request that is neither is not.
func TestEveryApprovalIsAllowedTheTimeAnsweredAndNothingElse(t *testing.T) {
	for _, c := range []struct{ method, params, answer string }{
		{"item/commandExecution/requestApproval", `{}`, `{"decision":"accept"}`},
		{"item/fileChange/requestApproval", `{}`, `{"decision":"accept"}`},
		{"execCommandApproval", `{}`, `{"decision":"approved"}`},
		{"applyPatchApproval", `{}`, `{"decision":"approved"}`},
		{"item/permissions/requestApproval", `{"permissions":{"network":{"enabled":true}}}`, `{"permissions":{"network":{"enabled":true}},"scope":"turn"}`},
		{"item/permissions/requestApproval", `{}`, `{"permissions":null,"scope":"turn"}`},
		{"mcpServer/elicitation/request", `{}`, `{"action":"accept","content":null}`},
		{"currentTime/read", `{}`, `{"currentTimeAt":7}`},
		{"item/tool/requestUserInput", `{}`, ""},
		{"account/chatgptAuthTokens/refresh", `{}`, ""},
	} {
		answer, ok := allowed(c.method, json.RawMessage(c.params), 7)
		line, _ := brainwire.Marshal(answer)
		if ok != (c.answer != "") || ok && string(line) != c.answer || !ok && answer != nil {
			t.Fatalf("%s %s is answered %q: %v %s", c.method, c.params, c.answer, ok, line)
		}
	}
}

// CYFR's system prompt, starting a thread or resuming one, and an answer
// of CYFR's reach Codex as one line each, whatever lines they hold, and
// read back as they were.
func TestTextOfManyLinesReachesCodexAsOneLine(t *testing.T) {
	text := "first line\nsecond line\r\nthird"
	thread := "019a0000-0000-7000-8000-00000000aaaa"
	none := map[string]any{"features": map[string]any{"plugins": false, "apps": false}, "mcp_servers": map[string]any{}}
	for _, c := range []struct {
		line []byte
		want map[string]any
	}{
		{threadStart("cyfr-thread-1", text, []map[string]any{}, "/home/kept", nil, brainwire.Config{}, accessChoices[0].Native), map[string]any{"id": "cyfr-thread-1", "method": "thread/start", "params": map[string]any{
			"approvalPolicy": "never", "sandbox": "danger-full-access", "dynamicTools": []any{}, "cwd": "/home/kept", "config": none, "developerInstructions": text}}},
		{threadResume("cyfr-thread-1", thread, text, "/home/kept", nil, brainwire.Config{}, accessChoices[0].Native), map[string]any{"id": "cyfr-thread-1", "method": "thread/resume", "params": map[string]any{
			"threadId": thread, "approvalPolicy": "never", "sandbox": "danger-full-access", "excludeTurns": true, "cwd": "/home/kept", "config": none, "developerInstructions": text}}},
		{toolAnswer(json.RawMessage("7"), text, true), map[string]any{"id": float64(7), "result": map[string]any{
			"contentItems": []any{map[string]any{"type": "inputText", "text": text}}, "success": true}}},
	} {
		var got map[string]any
		if bytes.ContainsAny(c.line, "\r\n") || json.Unmarshal(c.line, &got) != nil || !reflect.DeepEqual(got, c.want) {
			t.Fatalf("text of many lines is one line to Codex, read back as it was: %s", c.line)
		}
	}
}

// A start ending on Codex's own servers names them, at most five, and
// says what the person does.
func TestTheSentenceOfServersOfCodexsOwnNamesThem(t *testing.T) {
	const do = ": add the server in CYFR, and remove it from Codex's own configuration or plugins on the program's terminal."
	for _, c := range []struct {
		names []string
		want  string
	}{
		{[]string{"late"}, `it runs an MCP server of its own, "late", that CYFR does not use` + do},
		{[]string{"a", "b c"}, `it runs MCP servers of its own, "a", "b c", that CYFR does not use` + do},
		{[]string{"1", "2", "3", "4", "5", "6", "7"}, `it runs MCP servers of its own, "1", "2", "3", "4", "5" and 2 more, that CYFR does not use` + do},
	} {
		if got := ownServerSentence(c.names); got != c.want {
			t.Fatalf("%v: %q", c.names, got)
		}
	}
}
