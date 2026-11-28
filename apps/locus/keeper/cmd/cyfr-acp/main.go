// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-acp drives a program that speaks the Agent Client Protocol
// (ACP, version 1) as a brain of CYFR's. It is built once and installed
// under one name for each program, the name it runs under picking the
// program's profile (profile.go): `cyfr-antigravity` for Antigravity's CLI,
// `cyfr-opencode` for OpenCode's, `cyfr-cursor` for Cursor's agent.
// It is the start of a `driven` program row's command, before the
// program's own:
//
//	cyfr-antigravity agy
//
// On a terminal it runs the program's command unchanged, in its place, so
// the person signs the program in on the same row. Otherwise its one host,
// Opus.Brain, speaks the brain wire to it over the `run` session's standard
// input and output (tests/fixtures/brain_wire.json, its "comment";
// internal/brainwire serves it), and it speaks ACP to the program it
// starts, the command followed by the profile's words (`acp`). It writes
// nothing to its output but the wire's lines, and nothing of the program's
// standard error, its folder, its sign-in, its account or its tier reaches
// them: the program's errors are said in the driver's own words.
//
// CYFR's tools reach the program through CYFR's own MCP server, the stub
// (`cyfr-stub --socket <name>`), named in every session the driver makes or
// goes on with, under a name no server of the person's has (relay.go). The stub asks the driver's tool socket (internal/toolsock)
// for the start's tools and passes each call to it; the driver shows each
// call as an `ask`, holds it, and its `answer` is the call's result, so
// every call of CYFR's tools passes CYFR's gate whatever the program's own
// permission mode. A start answers `started` only once the stub has listed
// the tools, or, for a program whose servers list at a session's first
// prompt, at once, the native turn that ends with no listing ending with an
// error saying CYFR's tools did not reach it. The program's permission questions are each answered allow;
// none stands in for an ask. The program's own tools are shown as `own`
// (own.go), each run under its tool call's id with what its input runs and
// the diffs its end shows, and its thought chunks as `thought`. Its
// message chunks are said whole under the message id it gives them; where
// it gives none (Cursor, Antigravity), a tool call ends the message under
// way, and what it says after is a message of its own. A sub-agent's
// frames are none of the member's: OpenCode's, each marked
// `_meta["opencode/child-session"]`, are dropped, and Cursor and
// Antigravity put none on the stream, so only the call that started it is
// shown.
//
// A `start` makes a new session (`session/new`), or goes on with the one it
// names (`session/resume`, and `session/load` where the program says the
// resume found nothing, or at once for a program that offers no resume);
// only the load's own not-found answer is `gone`.
// The start's model and effort are the session's config options, and its
// instructions go where the program takes instructions for one process, or
// else lead the session's first prompt (instructions.go). A `post` is a
// prompt carrying the post's uuid in its `_meta`, since an ACP prompt takes
// no id of the client's; a post while a prompt runs is a second prompt
// where the program steers with one, `accepted` once the program has
// answered the earlier, or the program's own steer request, `accepted`
// once it says it took it and `later` where it says no turn runs, and is
// otherwise answered `later`, so the driver holds no post. While a call of CYFR's tools is held, a post during the
// running prompt is answered `later` on every profile, steering or not, and
// nothing is written: the holder writes one command at a time, so a steer's
// confirmation that waited on the program, itself waiting on the ask's
// answer, would wait forever. The native turn's `idle` names every post its
// prompts carried. A load's replay is never passed on, so `held` names none.
//
// A `forget` removes the session's files the profile names and proves them
// absent, then, where the profile says so, asks the program to load it,
// forgotten only on the load's not-found answer; or, for a program that
// keeps its sessions in a store of its own with its sign-in, asks the
// program to delete it and to load it after, forgotten only on the load's
// not-found answer. What a program keeps of every session in one index of its own
// stays (Antigravity: each session's title and summary, in its index under
// antigravity-cli, antigravity_words.go), since CYFR never writes a
// program's database.
//
// Stop is the session's close: a prompt running is first cancelled in
// ACP's way (`session/cancel`), then the program's input closes, a TERM
// follows at 2 s and a kill at 5 s (brainwire's Process.Stop). The driver
// ends when its input ends, when the program ends, with its status, and on
// a hangup or a TERM, each time closing the program first.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

func main() {
	os.Exit(run(filepath.Base(os.Args[0]), os.Args[1:]))
}

// run serves the wire as the profile `name` names, or says how the driver
// is run when it names none.
func run(name string, command []string) int {
	p, ok := profiles[name]
	if !ok {
		names := make([]string, 0, len(profiles))
		for n := range profiles {
			names = append(names, n)
		}
		sort.Strings(names)
		return brainwire.Usage(name, fmt.Sprintf("usage: %s HARNESS [ARG]...: cyfr-acp runs under a program's name, one of %s",
			strings.Join(names, " | "), strings.Join(names, ", ")))
	}
	return brainwire.Main(p.name, command, func(command []string, c *brainwire.Conn, home string) brainwire.Driver {
		return newDriver(p, command, c, home)
	})
}
