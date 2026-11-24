// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
	"github.com/cyfr/locus/keeper/internal/homepath"
)

// profile is what one program differs in under the one ACP driver: data,
// and the few hooks where its shapes are its own. The driver's name picks
// it (profiles), and every other step is the driver's, the same for each.
type profile struct {
	// name is the driver's name, which a row's command starts with, and
	// title the program's name as a person reads it in the driver's words.
	name, title string
	// args follow the row's own command to start the program's ACP server.
	args []string
	// minVersion is the first version the profile was probed at that does
	// what it needs, as initialize's agentInfo.version names it.
	minVersion [3]int
	// steer is how the program takes a message written while its turn
	// runs (steer's kinds); with none a post mid-turn is answered `later`.
	steer steer
	// steerMethod is a steerRequest's method, and steerAnswer reads its
	// answer: taken, or not taken since no turn runs (`later`); any other
	// answer is a refusal.
	steerMethod string
	steerAnswer func(result json.RawMessage) (taken, noTurn bool)
	// sessionID says whether a session id is of the form the program names
	// its sessions with, checked wherever the driver takes or sends one.
	sessionID func(id string) bool
	// signedOut is the one error code the program answers a session with
	// when it has no sign-in.
	signedOut int
	// resumeNotFound and loadNotFound are the program's own answers for a
	// session its folder lacks, each naming the session asked about, whole:
	// a resume that says so is followed by a load, and only the load's
	// answer reads as `gone`.
	resumeNotFound, loadNotFound func(e *rpcError, session string) bool
	// serverList are the words after the row's command with which the
	// program lists its MCP servers, the person's own, and serverNames
	// reads their names from what it prints, or says it listed none it can
	// read. CYFR's server takes a name none of them has (relay.go).
	serverList  []string
	serverNames func(out []byte) ([]string, bool)
	// appends reads initialize's agentCapabilities: whether the program
	// takes instructions for one process in a place of its own, which
	// instructionsMeta builds as a session's `_meta`. Otherwise the
	// instructions lead the session's first prompt (instructions.go).
	appends          func(capabilities json.RawMessage) bool
	instructionsMeta func(system string) map[string]any
	// callArguments are the argument objects a tool_call's rawInput may
	// show a call with: a call of CYFR's is matched to one of them by the
	// arguments its socket call carries (driver.go's ownUpdate), and to
	// nothing the program names or titles. Nil where the program never
	// shows a call of CYFR's as a tool call of its own: then nothing of a
	// socket call is kept to match.
	callArguments func(rawInput json.RawMessage) []json.RawMessage
	// stubKinds are the ACP kinds the program gives a call that reaches a
	// stub server, CYFR's among them, read from the update's kind field: a
	// call of one of them waits to be matched to the socket, and is shown
	// as the program's own only at its end; a call of any other kind is the
	// program's own, shown while it runs (own.go). A program whose
	// announcement gives no kind field shows every own call at its end, its
	// stated lack.
	stubKinds map[string]bool
	// mcpCall is the server and tool a tool_call's rawInput names when it
	// is a call of an MCP server's, shown as `mcp:<server>/<tool>`.
	mcpCall func(rawInput json.RawMessage) (server, tool string, ok bool)
	// sessionFiles are the files that hold one session's content, each a
	// way down from the home, or from the folder the program is told to
	// keep its files in, which internal/homepath walks following no link;
	// every one a forget removes.
	sessionFiles func(home, session string) []homepath.Path
	// deletes says a forget rests on the program's own session/delete,
	// proved by its load's not-found answer after it (forget.go), the
	// session being in a store of the program's own that holds more than
	// it, its sign-in among it.
	deletes bool
	// counted is the accounting of a prompt's counts that read, and counts
	// the wire's counts by the usage names each sums; a count of no name is
	// one the program does not report, counted 0 under its accounting,
	// which says the counts may be short.
	counted string
	counts  map[string][]string
	// selectEfforts says a model's efforts are offered only once it is the
	// session's model: the listing selects each to read them. Otherwise
	// they are its variants among the available models (listedModels).
	selectEfforts bool
	// namesTools says a tool_call's `name` is the program's own name of the
	// tool, shown for its call where it is a bounded plain name.
	namesTools bool
	// signedOutSentence refuses a post and a listing while signed out, and
	// refusedSentence, where it is set, says a prompt's authentication
	// error in the program's own terms.
	signedOutSentence, refusedSentence string
	// access is the choices the driver lists, each with its native mode.
	access []brainwire.Access[nativeAccess]
}

// nativeAccess is a choice's native setting: the session's mode, as its
// `mode` config option names one. Every permission question is answered
// allow in each (allowOption).
type nativeAccess struct{ mode string }

// steer is how a program takes a message mid-turn: not at all
// (steerLater); as a second prompt it takes into the running turn,
// answering the earlier prompt once it has (steerPrompt); or as its own
// request, answered `injected` once taken and `promptRequired` when no turn
// runs (steerRequest, the method named by the profile's steerMethod).
type steer int

const (
	steerLater steer = iota
	steerPrompt
	steerRequest
)

// profiles are the programs the driver runs as, by the name it runs under.
var profiles = map[string]*profile{antigravity.name: antigravity, opencode.name: opencode}

// antigravity is Antigravity's standalone CLI, `agy acp`, as probed at
// 1.5.16. A session's files are its brain folder, its database and its
// annotations, each named by the session's id. Each session's title and
// summary are also kept in the program's one index of every session
// (antigravity_words.go), which CYFR never writes: a forget leaves them,
// Antigravity's lack.
var antigravity = &profile{
	name:       "cyfr-antigravity",
	title:      "Antigravity",
	args:       []string{"acp"},
	minVersion: [3]int{1, 5, 0},
	steer:      steerPrompt,
	sessionID:  brainwire.IsUUID,
	signedOut:  -32000,
	// Seen in Antigravity 1.5.16: "Failed to read session <id>; retry, or
	// load it with session/load" (-32603) for a resume, and "Session not
	// found: <id>" (-32002) for a load. Only the load's answer is read as
	// gone: -32603 is the program's code for any internal failure.
	resumeNotFound: func(e *rpcError, session string) bool {
		return e.Code == -32603 && e.Message == "Failed to read session "+session+"; retry, or load it with session/load"
	},
	loadNotFound: func(e *rpcError, session string) bool {
		return e.Code == -32002 && e.Message == "Session not found: "+session
	},
	// Seen in Antigravity 1.5.16: `agy mcp list` prints "No MCP servers
	// configured." or a table whose first column, under NAME, is each
	// server's name.
	serverList:  []string{"mcp", "list"},
	serverNames: agyServers,
	appends: func(capabilities json.RawMessage) bool {
		var c struct {
			Meta struct {
				Antigravity struct {
					SystemPrompt struct {
						Append bool `json:"append"`
					} `json:"systemPrompt"`
				} `json:"antigravity"`
			} `json:"_meta"`
		}
		return json.Unmarshal(capabilities, &c) == nil && c.Meta.Antigravity.SystemPrompt.Append
	},
	instructionsMeta: func(system string) map[string]any {
		return map[string]any{"antigravity": map[string]any{"systemPrompt": map[string]any{"append": system}}}
	},
	// Seen in Antigravity 1.5.16: a stdio server's tool is shown with its
	// arguments and a required toolSummary of Antigravity's own, which it
	// drops before it calls the server; its own call_mcp_tool shows the
	// call as {ServerName, ToolName, Arguments}.
	callArguments: func(rawInput json.RawMessage) []json.RawMessage {
		var input map[string]json.RawMessage
		if json.Unmarshal(rawInput, &input) != nil || input == nil {
			return nil
		}
		var out []json.RawMessage
		if arguments, ok := input["Arguments"]; ok {
			out = append(out, arguments)
		}
		delete(input, "toolSummary")
		if shown, err := json.Marshal(input); err == nil {
			out = append(out, shown)
		}
		return out
	},
	// Seen in Antigravity 1.5.16: a stdio server's tool is kind other ("Run
	// mcp_<server>_<tool>"); its own tools are read, edit, execute and the
	// rest, and a person's server through its call_mcp_tool is execute.
	stubKinds: map[string]bool{"other": true},
	mcpCall: func(rawInput json.RawMessage) (string, string, bool) {
		var input struct {
			ServerName string `json:"ServerName"`
			ToolName   string `json:"ToolName"`
		}
		ok := json.Unmarshal(rawInput, &input) == nil && input.ServerName != "" && input.ToolName != ""
		return input.ServerName, input.ToolName, ok
	},
	sessionFiles: func(home, session string) []homepath.Path {
		return []homepath.Path{
			geminiPath(home, "antigravity-cli", "brain", session),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db"),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db-wal"),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db-shm"),
			geminiPath(home, "antigravity-cli", "annotations", session+".pbtxt"),
		}
	},
	// Each session's title request is a model call of the program's own
	// whose counts no prompt's answer carries.
	counted: "partial",
	counts: map[string][]string{"input_tokens": {"inputTokens"}, "output_tokens": {"outputTokens"},
		"cache_read_tokens": {"cachedReadTokens"}, "cache_write_tokens": {"cachedWriteTokens"}},
	signedOutSentence: "Antigravity has no sign-in it can use; sign it in on the program's terminal.",
	access: []brainwire.Access[nativeAccess]{
		{Choice: brainwire.Choice{ID: "full-access", Name: "Full access, no approvals"}, Native: nativeAccess{mode: "default"}},
	},
}

// geminiPath is a way down Antigravity's folder: from GEMINI_HOME when it
// is set, else from the home through `.gemini`.
func geminiPath(home string, steps ...string) homepath.Path {
	if dir := os.Getenv("GEMINI_HOME"); dir != "" {
		return homepath.Path{Root: dir, Rel: filepath.Join(steps...)}
	}
	return homepath.Path{Root: home, Rel: filepath.Join(append([]string{".gemini"}, steps...)...)}
}

// opencode is OpenCode 2's `opencode acp`, as probed at 2.4.1, fetched
// from OpenCode's own release by cyfr-fetch. Its sessions, and its sign-in
// with them, are in one database of its own, so a forget is its own
// session/delete, proved by its load's not-found answer. A message mid-turn
// is its own steer request. It shows no MCP server's tool to its model as a
// tool: CYFR's, like a person's, are called from JavaScript inside its own
// tool `execute`, so the person sees `execute` running, and each of CYFR's
// calls in it as an ask beside it. Its one place for a process's
// instructions keeps those a session was made with, so CYFR's instructions
// are its lack: they reach it as the opening of a session's first message,
// not as its system text, and a change to them reaches a session already
// made the same way, in its next message (instructions.go). Its
// prompt's usage leaves out its title request and a sub-agent's work, and
// names no cache writes. While its provider cannot be reached it retries
// without end, saying so only in session_info_update notices, which the
// driver drops: no notice is work, so CYFR's silence clock ends the turn as
// for any silent program. A sub-agent's result makes it work on after its
// turn has ended, outside any prompt: that work is not shown.
var opencode = &profile{
	name:       "cyfr-opencode",
	title:      "OpenCode",
	args:       []string{"acp"},
	minVersion: [3]int{2, 4, 1},
	steer:      steerRequest,
	// Seen in OpenCode 2.4.1: `_session/steering` answers
	// {"outcome":"injected"} while a turn runs, and
	// {"outcome":"promptRequired","reason":"noRunningTurn"} when none does.
	steerMethod: "_session/steering",
	steerAnswer: func(result json.RawMessage) (bool, bool) {
		var a struct {
			Outcome string `json:"outcome"`
		}
		_ = json.Unmarshal(result, &a)
		return a.Outcome == "injected", a.Outcome == "promptRequired"
	},
	sessionID: func(id string) bool { return openCodeSession.MatchString(id) },
	// Seen in OpenCode 2.4.1: a provider's refused key answers the prompt
	// -32000 "Authentication required: provider authentication required";
	// a session itself never answers it, since OpenCode's own free models
	// need no sign-in.
	signedOut: -32000,
	// Seen in OpenCode 2.4.1: "Invalid params: session not found: <id>"
	// (-32602) for a resume and a load alike; -32602 is any invalid
	// parameter's, so its words are read too.
	resumeNotFound: openCodeNotFound,
	loadNotFound:   openCodeNotFound,
	// Seen in OpenCode 2.4.1: `mcp list` and its server's MCP listing name
	// no server its configuration holds; `debug config --standalone`
	// prints each configuration document it reads, the folder's and the
	// home's, each server under `mcp.servers` by name, every secret value
	// masked, and leaves no server of its own running.
	serverList:  []string{"debug", "config", "--standalone"},
	serverNames: openCodeServers,
	// No call reaches a stub server but through `execute`, a tool of its
	// own: every call it shows is its own, shown while it runs.
	stubKinds:  map[string]bool{},
	mcpCall:    func(json.RawMessage) (string, string, bool) { return "", "", false },
	namesTools: true,
	sessionFiles: func(string, string) []homepath.Path {
		return nil
	},
	deletes: true,
	// Its title request and a sub-agent's work are not in a prompt's usage.
	counted: "partial",
	// Seen in OpenCode 2.4.1: outputTokens leaves out thoughtTokens, and
	// no cache-write count is given.
	counts: map[string][]string{"input_tokens": {"inputTokens"}, "output_tokens": {"outputTokens", "thoughtTokens"},
		"cache_read_tokens": {"cachedReadTokens"}, "cache_write_tokens": {}},
	selectEfforts:     true,
	signedOutSentence: "OpenCode has no provider it can use; connect one on the program's terminal, opened with the words `auth login`.",
	// A provider's 401 is that provider refusing the credential OpenCode
	// holds for it.
	refusedSentence: "OpenCode's provider refused the credential OpenCode holds for it; connect that provider again in OpenCode, on the program's terminal opened with the words `auth login`.",
	access: []brainwire.Access[nativeAccess]{
		{Choice: brainwire.Choice{ID: "full-access", Name: "Full access, no approvals"}, Native: nativeAccess{mode: "build"}},
	},
}

// openCodeSession is the form of OpenCode's session ids: `ses_` and 26
// letters and digits, as every id 2.4.1 named in its probe is.
var openCodeSession = regexp.MustCompile(`^ses_[0-9A-Za-z]{26}$`)

func openCodeNotFound(e *rpcError, session string) bool {
	return e.Code == -32602 && e.Message == "Invalid params: session not found: "+session
}

// openCodeServers are the servers' names under `mcp.servers` in each
// configuration document `debug config` prints.
func openCodeServers(out []byte) ([]string, bool) {
	var sources []struct {
		Type string `json:"type"`
		Info struct {
			MCP struct {
				Servers map[string]json.RawMessage `json:"servers"`
			} `json:"mcp"`
		} `json:"info"`
	}
	if json.Unmarshal(out, &sources) != nil || sources == nil {
		return nil, false
	}
	names := []string{}
	for _, s := range sources {
		for name := range s.Info.MCP.Servers {
			names = append(names, name)
		}
	}
	return names, true
}

// agyServers are the names in the first column of `agy mcp list`'s table.
func agyServers(out []byte) ([]string, bool) {
	text := strings.TrimSpace(string(out))
	if text == "No MCP servers configured." {
		return []string{}, true
	}
	lines := strings.Split(text, "\n")
	if fields := strings.Fields(lines[0]); len(fields) == 0 || fields[0] != "NAME" {
		return nil, false
	}
	names := []string{}
	for _, line := range lines[1:] {
		if fields := strings.Fields(line); len(fields) > 0 {
			names = append(names, fields[0])
		}
	}
	return names, true
}
