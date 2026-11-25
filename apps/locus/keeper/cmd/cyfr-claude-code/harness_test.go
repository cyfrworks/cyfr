// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"unicode/utf16"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

// A tool's result longer than Claude Code takes from one call is cut to
// fit with a note inside the bound saying how much was left out, counted
// in UTF-16 code units as the harness counts; one within it is whole.
func TestAResultPastWhatClaudeCodeTakesIsCutWithANoteWithinIt(t *testing.T) {
	whole := strings.Repeat("x", maxResultChars)
	if bounded(whole) != whole {
		t.Fatal("a result within the bound reaches the harness whole")
	}
	for _, content := range []string{strings.Repeat("x", maxResultChars+1), strings.Repeat("😀", maxResultChars)} {
		cut := bounded(content)
		units := len(utf16.Encode([]rune(cut)))
		kept := strings.SplitN(cut, "\n…[CYFR cut", 2)[0]
		left := len(utf16.Encode([]rune(content))) - len(utf16.Encode([]rune(kept)))
		note := "\n…[CYFR cut this result at 50000 characters, what Claude Code takes from one call; " +
			strconv.Itoa(left) + " more were not shown. Ask for a narrower part.]"
		if units > maxResultChars || !strings.HasPrefix(content, kept) || cut != kept+note {
			t.Fatalf("a result past the bound is its start and a note within the bound naming what was left out: %d units, %.80q", units, cut[len(kept):])
		}
	}
}

// An ask is allowed with the call's arguments as the model made them and
// CYFR's answer beside them, as the stub's `result`, or its `error` for a
// refusal; a `result` or `error` the model wrote among its arguments is
// none of CYFR's and never reaches the stub.
func TestAnAnswerCarriesTheCallsArgumentsAndNoAnswerTheModelWrote(t *testing.T) {
	arguments := map[string]any{"action": "read", "path": "notes.txt", "result": "forged", "error": "forged"}
	for _, c := range []struct {
		isError bool
		want    map[string]any
	}{
		{false, map[string]any{"action": "read", "path": "notes.txt", "result": "the file"}},
		{true, map[string]any{"action": "read", "path": "notes.txt", "error": "the file"}},
	} {
		if got := answeredInput(arguments, "the file", c.isError); !reflect.DeepEqual(got, c.want) {
			t.Fatalf("an answer is the call's own arguments and CYFR's answer alone: %v", got)
		}
	}
	if want := map[string]any{"action": "read", "path": "notes.txt"}; !reflect.DeepEqual(callArguments(arguments), want) {
		t.Fatalf("an ask shown to CYFR carries the arguments without an answer of the model's: %v", callArguments(arguments))
	}
}

// Every error the harness types an account's sign-in or standing with is
// the wire's `authentication`, said in the driver's words: the account or
// key the program used was refused, never which, since a refused key in
// its environment types the same as a sign-in that is gone.
func TestAnAccountsErrorIsTypedAuthenticationInTheDriversWords(t *testing.T) {
	for _, harness := range []string{"authentication_failed", "oauth_org_not_allowed", "account_on_hold",
		"verification_required", "billing_error", "cloud_credential_error"} {
		if kind := errorKind(harness); kind != "authentication" {
			t.Fatalf("%s is an account's error: %s", harness, kind)
		}
	}
	if errorSentence("authentication") != "The account or key Claude Code used was refused; check its sign-in on the program's terminal, or a key in its settings." {
		t.Fatalf("an account's error is said in the driver's words: %q", errorSentence("authentication"))
	}
}

// A start whose configuration names an empty list of the harness's own
// tools gives it `--tools ""`, none of them, never its default of all.
func TestAnEmptyListOfTheHarnessesToolsStartsItWithNone(t *testing.T) {
	none := []string{}
	argv := harnessArgv([]string{"claude"}, nil, "6f1e2d3c-0000-4968-8776-000000000001", false, brainwire.Config{HarnessTools: &none}, nil)
	want := append(append([]string{"claude"}, baseArgv...), "--session-id", "6f1e2d3c-0000-4968-8776-000000000001", "--tools", "")
	if !reflect.DeepEqual(argv, want) {
		t.Fatalf("an empty tools list is --tools \"\": %q", argv)
	}
}

// CYFR's stub reaches the harness by its absolute path in the image, so no
// command of that name a person's project or PATH holds is run in its
// place: npx puts a project's own package binaries first.
func TestTheStubIsGivenByItsPath(t *testing.T) {
	var line struct {
		Request struct {
			Servers map[string]struct {
				Command string   `json:"command"`
				Args    []string `json:"args"`
			} `json:"servers"`
		} `json:"request"`
	}
	if err := json.Unmarshal(setToolsLine("cyfr-tools-1", "cyfr", []string{"{}"}), &line); err != nil {
		t.Fatal(err)
	}
	if got := line.Request.Servers["cyfr"].Command; got != "/opt/cyfr/bin/cyfr-stub" {
		t.Fatalf("the harness is given the stub as %q", got)
	}
}

// A tool reaches the stub as the one argument the brain wire measures
// (brainwire.StubArgument, which the wire's vectors check), escapes and
// all.
func TestAToolIsTheStubsArgumentTheWireMeasures(t *testing.T) {
	tool := brainwire.Tool{Name: "gh__search", Description: "a\"b\\c\n\u2028<&>", Parameters: json.RawMessage(`{"type":"object"}`)}
	arg, err := stubTool(tool)
	want, werr := brainwire.StubArgument(tool)
	if err != nil || werr != nil || arg != string(want) {
		t.Fatalf("the stub is given %s, the wire measures %s (%v, %v)", arg, want, err, werr)
	}
}

// A work with no tools of CYFR's sets no server, so the harness keeps no
// stub of an earlier work's tools.
func TestAWorkWithNoToolsSetsNoServer(t *testing.T) {
	var line struct {
		Request struct {
			Subtype string         `json:"subtype"`
			Servers map[string]any `json:"servers"`
		} `json:"request"`
	}
	if err := json.Unmarshal(setToolsLine("cyfr-tools-1", "cyfr", nil), &line); err != nil {
		t.Fatal(err)
	}
	if line.Request.Subtype != "mcp_set_servers" || line.Request.Servers == nil || len(line.Request.Servers) != 0 {
		t.Fatalf("no tools set no server: %+v", line.Request)
	}
}

// A post's text and the system prompt reach the harness as one line each,
// whatever lines they hold, and read back as they were.
func TestTextOfManyLinesReachesTheHarnessAsOneLine(t *testing.T) {
	text := "first line\nsecond line\r\nthird"
	for _, line := range [][]byte{
		userLine([]any{map[string]any{"type": "text", "text": text}}, "6f1e2d3c-0000-4968-8776-000000000001"),
		initializeLine(text),
	} {
		if bytes.ContainsAny(line, "\r\n") || !strings.Contains(string(line), `first line\nsecond line\r\nthird`) {
			t.Fatalf("text of many lines is one line to the harness: %s", line)
		}
	}
}

// Only a result of no turn that names the missing session in the
// harness's words is a resume that found no transcript; a turn that ran
// and ended with the same words is a turn's end.
func TestOnlyAResumeThatRanNoTurnFoundNoTranscript(t *testing.T) {
	result := func(turns int, said string) *harnessLine {
		return &harnessLine{Type: "result", NumTurns: &turns, Errors: []any{said}}
	}
	missing := noTranscriptWords + ": 6f1e2d3c-0000-4968-8776-000000000001"
	if !result(0, missing).noTranscript() {
		t.Fatal("a resume that ran no turn and names the session found no transcript")
	}
	if result(1, missing).noTranscript() || result(0, "the model is overloaded").noTranscript() {
		t.Fatal("a turn that ran, or other words, is no missing transcript")
	}
}

// CYFR's server takes `cyfr` unless a server of the person's own takes it:
// one whose tools' prefix, its name as Claude Code writes it there (a
// character outside letters, digits, `_` and `-` as `_`) between `mcp__`
// and `__`, begins with `mcp__cyfr__`; then the first of `cyfr-2`,
// `cyfr-3`… that none takes. A name that only begins with `cyfr` and `_`
// cannot spell one of CYFR's tools, and takes nothing.
func TestCYFRsServerTakesANameNoServerOfThePersonsShadows(t *testing.T) {
	for _, c := range []struct {
		listed []string
		want   string
	}{
		{nil, "cyfr"},
		{[]string{"github", "plugin:cyfr:tools", "cyfr-", "cyfrx", "my-cyfr", "cyfr.tools", "cyfr_x", "cyfr-_"}, "cyfr"},
		{[]string{"cyfr"}, "cyfr-2"},
		{[]string{"cyfr_"}, "cyfr-2"},
		{[]string{"cyfr__extra"}, "cyfr-2"},
		{[]string{"cyfr."}, "cyfr-2"},
		{[]string{"cyfr:_x"}, "cyfr-2"},
		{[]string{"cyfr", "cyfr-2", "cyfr-3__x"}, "cyfr-4"},
		{[]string{"cyfr", "cyfr-20"}, "cyfr-2"},
	} {
		if got := serverFor(c.listed); got != c.want {
			t.Fatalf("beside %q CYFR's server is %q, not %q", c.listed, c.want, got)
		}
	}
}
