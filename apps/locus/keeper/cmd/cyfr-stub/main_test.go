// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

package main

import (
	"bufio"
	"encoding/json"
	"strings"
	"testing"
)

const files = `{"name":"files","description":"Read the athanor's files","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}}`

// exchange sends each message to a stub serving tools and answers what it
// wrote back, one decoded response per line.
func exchange(t *testing.T, tools []tool, messages ...string) []map[string]any {
	t.Helper()
	var out strings.Builder
	if err := serve(strings.NewReader(strings.Join(messages, "\n")+"\n"), &out, tools); err != nil {
		t.Fatalf("serve: %v", err)
	}
	var answers []map[string]any
	scanner := bufio.NewScanner(strings.NewReader(out.String()))
	scanner.Buffer(make([]byte, 1<<20), maxLineBytes)
	for scanner.Scan() {
		var answer map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &answer); err != nil {
			t.Fatalf("a line that is no JSON: %q", scanner.Text())
		}
		answers = append(answers, answer)
	}
	return answers
}

func mustTools(t *testing.T, args ...string) []tool {
	t.Helper()
	tools, err := parseTools(args)
	if err != nil {
		t.Fatalf("parseTools: %v", err)
	}
	return tools
}

func textOf(t *testing.T, answer map[string]any) (string, bool) {
	t.Helper()
	result, ok := answer["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", answer)
	}
	blocks := result["content"].([]any)
	if len(blocks) != 1 {
		t.Fatalf("one text block expected: %v", blocks)
	}
	block := blocks[0].(map[string]any)
	if block["type"] != "text" {
		t.Fatalf("a text block expected: %v", block)
	}
	isError, _ := result["isError"].(bool)
	return block["text"].(string), isError
}

func TestListsTheToolsItWasGivenInOrder(t *testing.T) {
	tools := mustTools(t, files, `{"name":"github__create_issue"}`)
	answers := exchange(t, tools,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code"}}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
	)
	if len(answers) != 2 {
		t.Fatalf("a notification is answered with nothing: %v", answers)
	}
	init := answers[0]["result"].(map[string]any)
	if init["protocolVersion"] != "2025-06-18" || init["capabilities"].(map[string]any)["tools"] == nil {
		t.Fatalf("initialize: %v", init)
	}
	listed := answers[1]["result"].(map[string]any)["tools"].([]any)
	if len(listed) != 2 {
		t.Fatalf("two tools expected: %v", listed)
	}
	first := listed[0].(map[string]any)
	schema, _ := json.Marshal(first["inputSchema"])
	if first["name"] != "files" || first["description"] != "Read the athanor's files" ||
		string(schema) != `{"additionalProperties":false,"properties":{"path":{"type":"string"}},"type":"object"}` {
		t.Fatalf("the first tool as given: %v", first)
	}
	second := listed[1].(map[string]any)
	if second["name"] != "github__create_issue" || second["inputSchema"].(map[string]any)["type"] != "object" {
		t.Fatalf("a tool with no schema takes an object's: %v", second)
	}
	if _, has := second["description"]; has {
		t.Fatalf("no description is none: %v", second)
	}
}

func TestACallAnswersTheResultItsInputCarries(t *testing.T) {
	tools := mustTools(t, files)
	answers := exchange(t, tools,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"files","arguments":{"path":"a.txt","result":"line one\nline two"},"_meta":{"claudecode/toolUseId":"toolu_1"}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"files","arguments":{"path":"a.txt","error":"Denied by the person."}}}`,
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"files","arguments":{"result":{"rows":2}}}}`,
	)
	if text, isError := textOf(t, answers[0]); text != "line one\nline two" || isError {
		t.Fatalf("the result as its content: %q %v", text, isError)
	}
	if answers[0]["id"].(float64) != 3 {
		t.Fatalf("answered under the call's id: %v", answers[0])
	}
	if text, isError := textOf(t, answers[1]); text != "Denied by the person." || !isError {
		t.Fatalf("the error as an error: %q %v", text, isError)
	}
	if text, _ := textOf(t, answers[2]); text != `{"rows":2}` {
		t.Fatalf("a result that is no string, as its JSON: %q", text)
	}
}

func TestACallThatDidNotPassTheAskIsAnErrorAndRunsNothing(t *testing.T) {
	tools := mustTools(t, files)
	answers := exchange(t, tools, `{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"files","arguments":{"path":"a.txt"}}}`)
	if text, isError := textOf(t, answers[0]); !isError || text != ungated {
		t.Fatalf("an ungated call: %q %v", text, isError)
	}
}

func TestUnknownToolsAndMethodsAreRefused(t *testing.T) {
	tools := mustTools(t, files)
	answers := exchange(t, tools,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"shell","arguments":{"result":"x"}}}`,
		`{"jsonrpc":"2.0","id":8,"method":"resources/list"}`,
		`{"jsonrpc":"2.0","id":9,"method":"ping"}`,
		`not json`,
	)
	codes := []float64{-32602, -32601}
	for i, code := range codes {
		if got := answers[i]["error"].(map[string]any)["code"].(float64); got != code {
			t.Fatalf("answer %d: code %v, want %v", i, got, code)
		}
	}
	if _, ok := answers[2]["result"].(map[string]any); !ok {
		t.Fatalf("a ping is answered: %v", answers[2])
	}
	if answers[3]["error"].(map[string]any)["code"].(float64) != -32700 {
		t.Fatalf("a line that is no JSON: %v", answers[3])
	}
}

func TestAToolListThatIsNoToolListIsRefused(t *testing.T) {
	for _, args := range [][]string{
		{`{"description":"no name"}`},
		{`{"name":""}`},
		{`[1,2]`},
		{`{"name":"a"}`, `{"name":"a"}`},
		{`{"name":"a","inputSchema":"object"}`},
		{`{"name":"` + strings.Repeat("n", 129) + `"}`},
	} {
		if _, err := parseTools(args); err == nil {
			t.Fatalf("%v: refused expected", args)
		}
	}
	if tools, err := parseTools(nil); err != nil || len(tools) != 0 {
		t.Fatalf("no tools is an empty list: %v %v", tools, err)
	}
}

func TestALargeResultCrossesWhole(t *testing.T) {
	tools := mustTools(t, files)
	big := strings.Repeat("x", 3<<20)
	call, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 10, "method": "tools/call",
		"params": map[string]any{"name": "files", "arguments": map[string]any{"result": big}}})
	answers := exchange(t, tools, string(call))
	if text, _ := textOf(t, answers[0]); text != big {
		t.Fatalf("a result of %d bytes came back as %d", len(big), len(text))
	}
}
