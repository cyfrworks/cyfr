// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
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
	// steers says the program takes a prompt written while one runs into
	// the running turn, and answers the earlier prompt once it has: that
	// answer is the program's confirmation. Without it a post mid-turn is
	// answered `later`.
	steers bool
	// signedOut is the one error code the program answers a session with
	// when it has no sign-in.
	signedOut int
	// resumeNotFound and loadNotFound are the program's own answers for a
	// session its folder lacks: a resume that says so is followed by a
	// load, and only the load's answer reads as `gone`.
	resumeNotFound, loadNotFound func(e *rpcError) bool
	// appends reads initialize's agentCapabilities: whether the program
	// takes instructions for one process in a place of its own, which
	// instructionsMeta builds as a session's `_meta`. Otherwise the
	// instructions lead the session's first prompt (instructions.go).
	appends          func(capabilities json.RawMessage) bool
	instructionsMeta func(system string) map[string]any
	// callArguments are the argument objects a tool_call's rawInput may
	// show a call with: a call of CYFR's is matched to one of them by the
	// arguments its socket call carries (driver.go's ownUpdate), and to
	// nothing the program names or titles.
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
	// sessionRoot is the program's folder in the home, and sessionFiles the
	// files under it that hold one session's content, every one a forget
	// removes; nothing on the way from the root is followed through a link.
	sessionRoot  func(home string) string
	sessionFiles func(home, session string) []string
	// counted is the accounting of a prompt's counts that read.
	counted string
	// signedOutSentence refuses a post and a listing while signed out.
	signedOutSentence string
	// access is the choices the driver lists, each with its native mode.
	access []brainwire.Access[nativeAccess]
}

// nativeAccess is a choice's native setting: the session's mode, as its
// `mode` config option names one. Every permission question is answered
// allow in each (allowOption).
type nativeAccess struct{ mode string }

// profiles are the programs the driver runs as, by the name it runs under.
var profiles = map[string]*profile{antigravity.name: antigravity}

// relayServer is the name CYFR's server takes in every session.
const relayServer = "cyfr"

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
	steers:     true,
	signedOut:  -32000,
	// Seen in Antigravity 1.5.16: "Failed to read session <id>; retry, or
	// load it with session/load" (-32603) for a resume, and "Session not
	// found: <id>" (-32002) for a load. Only the load's code is read as
	// gone: -32603 is the program's code for any internal failure.
	resumeNotFound: func(e *rpcError) bool {
		return e.Code == -32603 && strings.HasPrefix(e.Message, "Failed to read session")
	},
	loadNotFound: func(e *rpcError) bool { return e.Code == -32002 },
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
	sessionRoot: geminiHome,
	sessionFiles: func(home, session string) []string {
		cli := filepath.Join(geminiHome(home), "antigravity-cli")
		return []string{
			filepath.Join(cli, "brain", session),
			filepath.Join(cli, agySessionDatabases, session+".db"),
			filepath.Join(cli, agySessionDatabases, session+".db-wal"),
			filepath.Join(cli, agySessionDatabases, session+".db-shm"),
			filepath.Join(cli, "annotations", session+".pbtxt"),
		}
	},
	// Each session's title request is a model call of the program's own
	// whose counts no prompt's answer carries.
	counted:           "partial",
	signedOutSentence: "Antigravity has no sign-in it can use; sign it in on the program's terminal.",
	access: []brainwire.Access[nativeAccess]{
		{Choice: brainwire.Choice{ID: "full-access", Name: "Full access, no approvals"}, Native: nativeAccess{mode: "default"}},
	},
}

// geminiHome is where Antigravity keeps its sessions and its sign-in.
func geminiHome(home string) string {
	if dir := os.Getenv("GEMINI_HOME"); dir != "" {
		return dir
	}
	return filepath.Join(home, ".gemini")
}
