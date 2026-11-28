// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"errors"
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
	// what it needs, as initialize's agentInfo.version names it; none
	// (zeros) for a program that names no version there, whose version is
	// its row's pin.
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
	// answer reads as `gone`. A program that offers no resume has no
	// resumeNotFound: a session goes on by its load alone.
	resumeNotFound, loadNotFound func(e *rpcError, session string) bool
	// serverList are the words after the row's command with which the
	// program lists its MCP servers, the person's own, and serverNames
	// reads their names from what it prints, or says it listed none it can
	// read. CYFR's server takes a name none of them has (relay.go).
	serverList  []string
	serverNames func(out []byte) ([]string, bool)
	// namesOnce says the program's listing starts the servers it lists, so
	// the name CYFR's server takes is read once, when a session is made,
	// kept with the session's own record and used at every start that goes
	// on with it, with no listing (relay.go).
	namesOnce bool
	// listsAtPrompt says the program's servers list their tools at a
	// session's first prompt, not when the session is made: the start
	// answers once the session does, and a native turn that ends with no
	// listing ends with an error saying CYFR's tools did not reach it.
	listsAtPrompt bool
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
	// toolPrefix, where it is set, is how the program names a tool of the
	// server `server` in a tool_call's name: a call so named is one of that
	// server's.
	toolPrefix func(server string) string
	// commandInput and subjectInput are the members of a call's rawInput
	// where the program puts the command it runs and the path it acts on,
	// what its start's detail says (brainwire.InputDetail).
	commandInput, subjectInput string
	// sessionFiles are the files that hold one session's content, each a
	// way down from the home, or from the folder the program is told to
	// keep its files in, which internal/homepath walks following no link;
	// every one a forget removes. An error says, in the driver's words, why
	// they are not reached, and nothing is removed.
	sessionFiles func(home, session string) ([]homepath.Path, error)
	// checkFolder, where it is set, says why the folder the program keeps
	// its sessions in is not one CYFR will walk, before the program is
	// asked for anything: a start, a listing and a forget are refused with
	// its sentence.
	checkFolder func(home string) error
	// deletes says a forget rests on the program's own session/delete,
	// proved by its load's not-found answer after it (forget.go), the
	// session being in a store of the program's own that holds more than
	// it, its sign-in among it.
	deletes bool
	// forgetLoads says a forget of the session's files is confirmed by the
	// program's load, in a process of the driver's own (forget.go): its
	// answer that it lacks the session, or that it is signed out, which
	// leaves the files' proved absence standing.
	forgetLoads bool
	// counted is the accounting of a prompt's counts that read, and counts
	// the wire's counts by the usage names each sums; a count of no name is
	// one the program does not report, counted 0 under its accounting,
	// which says the counts may be short.
	counted string
	counts  map[string][]string
	// efforts, where it is set, reads each model's efforts in the listing's
	// own process, which the driver lists in even while a session runs:
	// by selecting each model in the listing session (OpenCode), or by the
	// program's own list of every model's options (Cursor). Otherwise they
	// are its variants among the available models (listedModels).
	efforts func(o *oneOff, listed sessionAnswer) map[string][]string
	// clientMeta, where it is set, is initialize's clientCapabilities._meta.
	clientMeta map[string]any
	// namesTools says a tool_call's `name` is the program's own name of the
	// tool, shown for its call where it is a bounded plain name.
	namesTools bool
	// signedOutSentence refuses a post and a listing while signed out, and
	// refusedSentence, where it is set, says a prompt's authentication
	// error in the program's own terms.
	signedOutSentence, refusedSentence string
	// failure reads text that is a whole native turn's output, one message
	// chunk and nothing else said or called, as the program's own report of
	// a turn that failed, where the program ends such a turn as if it had
	// answered: the wire's error type and CYFR's own sentence for it, or ""
	// for text of any other form (driver.go's update and ended).
	failure func(text string) (kind, words string)
	// access is the choices the driver lists, each with its native mode.
	access []brainwire.Access[nativeAccess]
	// toolBudget, where it is set, is the most a start's tools may take,
	// each as its compact {name, description, parameters} (toolsBytes),
	// for a program that drops tools from a longer list without a word: a
	// start past it ends too_many_tools before the program runs.
	toolBudget int
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
var profiles = map[string]*profile{antigravity.name: antigravity, opencode.name: opencode, cursor.name: cursor}

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
	stubKinds:  map[string]bool{"other": true},
	toolPrefix: func(server string) string { return "mcp_" + server + "_" },
	// Seen in Antigravity 1.5.16: run_command's {CommandLine, …,
	// toolSummary}, read_file's and edit_file's {Path, …}.
	commandInput: "CommandLine",
	subjectInput: "Path",
	mcpCall: func(rawInput json.RawMessage) (string, string, bool) {
		var input struct {
			ServerName string `json:"ServerName"`
			ToolName   string `json:"ToolName"`
		}
		ok := json.Unmarshal(rawInput, &input) == nil && input.ServerName != "" && input.ToolName != ""
		return input.ServerName, input.ToolName, ok
	},
	sessionFiles: func(home, session string) ([]homepath.Path, error) {
		return []homepath.Path{
			geminiPath(home, "antigravity-cli", "brain", session),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db"),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db-wal"),
			geminiPath(home, "antigravity-cli", agySessionDatabases, session+".db-shm"),
			geminiPath(home, "antigravity-cli", "annotations", session+".pbtxt"),
		}, nil
	},
	// Each session's title request is a model call of the program's own
	// whose counts no prompt's answer carries.
	counted: "partial",
	counts: map[string][]string{"input_tokens": {"inputTokens"}, "output_tokens": {"outputTokens"},
		"cache_read_tokens": {"cachedReadTokens"}, "cache_write_tokens": {"cachedWriteTokens"}},
	signedOutSentence: "Antigravity has no sign-in it can use; sign it in on the program's terminal.",
	failure:           agyFailure,
	access: []brainwire.Access[nativeAccess]{
		{Choice: brainwire.Choice{ID: "full-access", Name: "Full access, no approvals"}, Native: nativeAccess{mode: "default"}},
	},
	toolBudget: agyToolBudget,
}

// agyToolBudget is Antigravity's list budget. Measured on Antigravity
// 1.5.16 with tools of ASCII text, on the API-key path: it counts the sum
// of each of CYFR's tools as its compact {name, description, parameters},
// `<`, `>` and `&` a byte each (four tools of 57,000 such bytes, 500 of
// them `<`, all reached its model), never the person's own servers, and
// past about 57,200 bytes and 39 more a tool it drops whole tools, largest
// first, saying nothing. On the account path, signed in, one tool of
// 56,000 bytes reached its model and one of 57,600 was dropped. How it
// counts text outside ASCII, and the line and paragraph separators Go
// escapes, was not measured.
const agyToolBudget = 57000

// agyFailureForm is the whole of the chunk Antigravity 1.5.16 writes for a
// turn whose model request failed, seen on the API-key path (429, 503, 401
// and 500), before it ends the prompt end_turn: its executor's error, the
// request's code, message and status, and the empty details it was always
// seen with, closing the chunk. Anything more on it is the member's reply.
var agyFailureForm = regexp.MustCompile(`^\n⚠ agent executor error: generating and executing: Error \d+, Message: .*, Status: ([A-Z_]+), Details: \[\]\n$`)

// agyFailure is a failed turn's error type and CYFR's sentence for it, by
// its status: an exhausted resource a limit's, an unavailable service an
// overload's, a refused key or account the account's, and any other the
// provider's. Antigravity retries a limit and an overload before it says
// so, and names no time either lifts.
func agyFailure(text string) (string, string) {
	m := agyFailureForm.FindStringSubmatch(text)
	switch {
	case m == nil:
		return "", ""
	case m[1] == "RESOURCE_EXHAUSTED":
		return "rate_limited", "Antigravity reported a usage or rate limit; " + brainwire.UntilWords(0) + "."
	case m[1] == "UNAVAILABLE":
		return "overloaded", "Antigravity reported its model service overloaded; ask again later."
	case m[1] == "UNAUTHENTICATED" || m[1] == "PERMISSION_DENIED":
		return "authentication", "The account or key Antigravity used was refused; check its sign-in on the program's terminal, or its key."
	}
	return "provider_error", "Antigravity reported an error of its provider."
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
	// Seen in OpenCode 2.4.1: a shell's {command, description, cwd}, an
	// edit's and a write's {path, …}.
	commandInput: "command",
	subjectInput: "path",
	sessionFiles: func(string, string) ([]homepath.Path, error) {
		return nil, nil
	},
	deletes: true,
	// Its title request and a sub-agent's work are not in a prompt's usage.
	counted: "partial",
	// Seen in OpenCode 2.4.1: outputTokens leaves out thoughtTokens, and
	// no cache-write count is given.
	counts: map[string][]string{"input_tokens": {"inputTokens"}, "output_tokens": {"outputTokens", "thoughtTokens"},
		"cache_read_tokens": {"cachedReadTokens"}, "cache_write_tokens": {}},
	efforts:           (*oneOff).selectEach,
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

// cursor is Cursor's agent, `agent acp`, as probed at 2026.11.22-e9042b2,
// fetched from Cursor's own archive by cyfr-fetch as a tree, its row
// passing `--disable-auto-update` so it does not replace itself. It names
// no version in initialize and offers no resume: a session goes on by its
// load. Its sessions are its folders `acp-sessions/<id>/` under its
// configuration folder, and it keeps no index of them elsewhere, so a
// forget removes that folder and reads it absent, which proves it; its
// load answering it lacks the session is a second witness where it can
// give one, and a load answered signed out undoes nothing already proved,
// while a load that finds the session, or fails another way, fails the
// forget. Its servers list their tools at
// a session's first prompt. Its own listing of its servers starts each of
// them, so the name of CYFR's server is read once, when a session is made,
// and kept: a server the person adds later under that very name is
// replaced by CYFR's in that session until a new one is made, its lack.
// Its servers in `~/.cursor/mcp.json` wait for the person's approval on
// the row's terminal (`agent mcp enable <name>`), since a session's folder
// is its home, which reads that file as the folder's own: Cursor's rule;
// a server CYFR hands it needs none. A message mid-turn is answered
// `later`: a second prompt cancels the running one. Its prompts report no
// usage. It ends a turn that failed as one that answered, its reason a
// message chunk of its own: a turn whose whole output is one chunk of
// exactly that form is read as an error, in CYFR's words; a turn that said
// or did anything before it ends as it ended, Cursor's words its answer,
// and a model whose whole answer is exactly that form is misread as a
// failure, its lack.
var cursor = &profile{
	name:  "cyfr-cursor",
	title: "Cursor",
	args:  []string{"acp"},
	steer: steerLater,
	// Seen in Cursor 2026.11.22-e9042b2: crypto.randomUUID() names each.
	sessionID: brainwire.IsUUID,
	signedOut: -32000,
	// Seen in Cursor 2026.11.22-e9042b2: -32602 "Invalid params" with
	// data.message `Session "<id>" not found`, -32602 being any invalid
	// parameter's, so the words are read whole.
	loadNotFound: func(e *rpcError, session string) bool {
		var data struct {
			Message string `json:"message"`
		}
		return e.Code == -32602 && e.Message == "Invalid params" && json.Unmarshal(e.Data, &data) == nil &&
			data.Message == `Session "`+session+`" not found`
	},
	// Seen in Cursor 2026.11.22-e9042b2: `agent mcp list` prints
	// `<name>: <status>` a line, and starts each server neither disabled
	// nor awaiting approval to read its status.
	serverList:    []string{"mcp", "list"},
	serverNames:   cursorServers,
	namesOnce:     true,
	listsAtPrompt: true,
	// Seen in Cursor 2026.11.22-e9042b2: a server's call is announced kind
	// other with an empty rawInput, then updated to
	// {providerIdentifier, toolName, args}.
	callArguments: func(rawInput json.RawMessage) []json.RawMessage {
		var input struct {
			Args json.RawMessage `json:"args"`
		}
		if json.Unmarshal(rawInput, &input) != nil || len(input.Args) == 0 {
			return nil
		}
		return []json.RawMessage{input.Args}
	},
	stubKinds: map[string]bool{"other": true},
	// Seen in Cursor 2026.11.22-e9042b2 (S3 F4): a command's {command}, a
	// read's and an edit's {path}.
	commandInput: "command",
	subjectInput: "path",
	mcpCall: func(rawInput json.RawMessage) (string, string, bool) {
		var input struct {
			Server string `json:"providerIdentifier"`
			Tool   string `json:"toolName"`
		}
		ok := json.Unmarshal(rawInput, &input) == nil && input.Server != "" && input.Tool != ""
		return input.Server, input.Tool, ok
	},
	sessionFiles: func(home, session string) ([]homepath.Path, error) {
		folder, err := cursorPath(home, "acp-sessions", session)
		if err != nil {
			return nil, err
		}
		return []homepath.Path{folder}, nil
	},
	forgetLoads: true,
	checkFolder: cursorFolder,
	// Its prompts carry no usage: the accounting is never read.
	counted:           "partial",
	counts:            map[string][]string{},
	signedOutSentence: "Cursor has no sign-in it can use; sign it in on the program's terminal, opened with the word `login`.",
	failure:           cursorFailure,
	access: []brainwire.Access[nativeAccess]{
		{Choice: brainwire.Choice{ID: "full-access", Name: "Full access, no approvals"}, Native: nativeAccess{mode: "agent"}},
	},
	// Seen in Cursor 2026.11.22-e9042b2: initialized with the parameterized
	// picker, its `model` option lists base models, and the model's own
	// options follow it, its effort among them, replaced when the model is
	// set. Without, each value fixes a model's parameters in one.
	clientMeta: map[string]any{"parameterizedModelPicker": true},
	efforts:    cursorEfforts,
}

// cursorEfforts are each model's efforts as Cursor's own
// cursor/list_available_models gives every model's options, with no
// session; a listing it does not answer lists each model with none.
func cursorEfforts(o *oneOff, _ sessionAnswer) map[string][]string {
	efforts := map[string][]string{}
	m, err := o.call("cursor/list_available_models", map[string]any{})
	var answer struct {
		Models []struct {
			Value   string         `json:"value"`
			Options []configOption `json:"configOptions"`
		} `json:"models"`
	}
	if err != nil || m.Error != nil || json.Unmarshal(m.Result, &answer) != nil {
		return efforts
	}
	for _, model := range answer.Models {
		efforts[model.Value] = selectedEfforts(model.Options)
	}
	return efforts
}

// cursorPath is a way down Cursor's configuration folder, where it keeps
// its sessions: CURSOR_CONFIG_DIR when it is set, else XDG_CONFIG_HOME's
// `cursor`, else the home's `.cursor`, as Cursor finds it, walked from the
// home. One not inside the home is refused (cursorFolder).
func cursorPath(home string, steps ...string) (homepath.Path, error) {
	folder := filepath.Join(home, ".cursor")
	if dir := os.Getenv("CURSOR_CONFIG_DIR"); strings.TrimSpace(dir) != "" {
		folder = dir
	} else if dir := os.Getenv("XDG_CONFIG_HOME"); strings.TrimSpace(dir) != "" {
		folder = filepath.Join(dir, "cursor")
	}
	if !filepath.IsAbs(folder) {
		folder = filepath.Join(home, folder)
	}
	rel, err := filepath.Rel(filepath.Clean(home), filepath.Clean(folder))
	if err != nil || !filepath.IsLocal(rel) && rel != "." {
		return homepath.Path{}, errCursorFolder
	}
	return homepath.Path{Root: home, Rel: filepath.Join(append([]string{rel}, steps...)...)}, nil
}

// cursorFolder judges Cursor's sessions folder before Cursor is asked for
// anything (profile's checkFolder): it must be inside the home, and every
// folder of it that is there must be one of this user's own, reached
// through no link, since a forget walks it so; one not made yet is
// Cursor's to make. A folder CYFR will not walk refuses the start, a
// listing and a forget alike, so no session is made that CYFR could not
// remove.
func cursorFolder(home string) error {
	folder, err := cursorPath(home, "acp-sessions")
	if err != nil {
		return err
	}
	dir, err := homepath.Root(folder.Root)
	if err != nil {
		return errCursorFolder
	}
	defer func() { dir.Close() }()
	for _, step := range strings.Split(filepath.ToSlash(folder.Rel), "/") {
		if step == "" || step == "." {
			continue
		}
		next, err := dir.Folder(step, false)
		switch {
		case homepath.Absent(err):
			return nil
		case err != nil:
			return errCursorFolder
		}
		dir.Close()
		dir = next
	}
	return nil
}

// errCursorFolder is the one sentence for a sessions folder CYFR will not
// walk.
var errCursorFolder = errors.New("Cursor keeps its sessions in a folder CURSOR_CONFIG_DIR or XDG_CONFIG_HOME names outside the program's own folder or through a link, which CYFR does not reach; name a folder inside the program's own, or none, in the program's settings")

// cursorNone is what `agent mcp list` prints when no server is configured.
const cursorNone = "No MCP servers configured (expected in .cursor/mcp.json or ~/.cursor/mcp.json)"

// cursorServers are the names `agent mcp list` prints, one `<name>:
// <status>` a line. A name may hold `: ` itself, so every text before each
// `: ` of a line, and the whole line, is a name taken: a name is only ever
// read as taken too often, never as free.
func cursorServers(out []byte) ([]string, bool) {
	text := strings.TrimSpace(string(out))
	if text == cursorNone {
		return []string{}, true
	}
	if text == "" {
		return nil, false
	}
	names := []string{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		names = append(names, line)
		for i := strings.Index(line, ": "); i >= 0; {
			names = append(names, line[:i])
			next := strings.Index(line[i+2:], ": ")
			if next < 0 {
				break
			}
			i += 2 + next
		}
	}
	return names, true
}

// cursorFailureForm is the whole of a chunk Cursor 2026.11.22-e9042b2
// writes for a turn that failed (its agent session's prompt handler): two
// blank lines, then `Error: `, the error's type or a bracketed code, and
// its message; or one of its sentences for an account that cannot go on.
var cursorFailureForm = regexp.MustCompile(`^\n\n(?:Error: (?:(?:(?:[A-Za-z][A-Za-z0-9]*)?Error: )?\[([a-z_]+)\] |(?:[A-Za-z][A-Za-z0-9]*)?Error: )\S.*|(Please sign in to continue|Upgrade your plan to continue|Add a payment method to continue|Check your settings to continue))$`)

// cursorFailure is a failed turn's error type and CYFR's sentence for it:
// a sign-in refused or wanted is the account's, a service that could not
// be reached the provider's, a usage limit or a plan to upgrade a limit's,
// with no time since Cursor names none, and any other failure Cursor's
// own.
func cursorFailure(text string) (string, string) {
	m := cursorFailureForm.FindStringSubmatch(text)
	switch {
	case m == nil:
		return "", ""
	case m[1] == "unauthenticated" || m[2] == "Please sign in to continue":
		return "authentication", "Cursor's sign-in was refused; sign it in again on the program's terminal, opened with the word `login`."
	case m[1] == "unavailable":
		return "provider_error", "Cursor could not reach its service; ask again once the network is back."
	case m[1] == "resource_exhausted" || m[2] == "Upgrade your plan to continue":
		// Cursor names no time the limit lifts.
		return "rate_limited", "Cursor reported a usage or rate limit; " + brainwire.UntilWords(0) + "."
	}
	return "provider_error", "Cursor reported that its turn failed."
}
