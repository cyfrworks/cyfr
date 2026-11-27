// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-claude-code drives Claude Code as a brain of CYFR's. It is
// the start of a `driven` program row's command, before the harness's own:
//
//	cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323
//
// On a terminal it runs the harness's command unchanged, in its place, so
// the person signs in to Claude Code on the same row. Otherwise its one
// host, Opus.Brain, speaks the brain wire to it over the `run` session's
// standard input and output (tests/fixtures/brain_wire.json, its
// "comment"; internal/brainwire serves it, as it does for every brain
// driver), and it speaks Claude Code's own stream-json protocol, with
// control requests, to the harness it starts (harness.go). It writes
// nothing to its output but the wire's lines, and nothing of the
// harness's standard error, its folder or its sign-in reaches them: the
// harness's errors are said in the driver's own words.
//
// It says `hello` first, naming the wire's version and its boot, fresh
// for each process. A `start` starts the harness for a new session under
// an id the driver draws, or resuming the session it names; the harness's
// answer to `initialize` answers `started`, and a harness that holds no
// transcript of the session named says so and ends, which answers
// `gone`. A start's tools are not read: each `work` sets CYFR's tools on
// the stub (`mcp_set_servers`), a `post` writes a user line under a uuid
// derived from the post's id, an `answer` allows the ask it names with
// CYFR's answer in its input; each is `accepted` once the harness's input
// took it. A start runs the harness in the access it names, one of those
// `models` lists (accessChoices: Default mode, the harness's default
// permission mode), or in the first when it names none; a start naming
// another ends the driver before anything runs. The harness's own tools
// run in its box: their asks are allowed and they are shown by name, all
// but its own question (`AskUserQuestion`), which is declined with
// `brainwire.QuestionsDeclined`, so the model asks in its reply.
// The driver keeps no account of calls: which post a result answers is
// the result's own naming of the posts' uuids, which `idle` passes on.
// A turn's error is said at its result, typed by what the result says
// (driver.go's failure). A start, and a work's setting of CYFR's tools,
// that the harness does not answer within answerWait end: the start ends
// the driver, the work is refused. Its close closes the harness's input,
// asks it to end with a TERM at 2 s and kills it at 5 s.
//
// The driver ends when its input ends (the session is closed), when the
// harness ends but after `gone`, with the harness's status, and on a
// hangup or a TERM, each time closing the harness first.
package main

import (
	"os"

	"github.com/cyfr/locus/keeper/internal/brainwire"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(command []string) int {
	return brainwire.Main(driverName, command, newDriver)
}
