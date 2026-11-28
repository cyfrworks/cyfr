// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//go:build linux

// Command cyfr-codex drives OpenAI Codex as a brain of CYFR's. It is the
// start of a `driven` program row's command, before the harness's own:
//
//	cyfr-codex npx -y @openai/codex@0.169.0
//
// On a terminal it runs the harness's command unchanged, in its place, so
// the person signs in to Codex on the same row (`login --device-auth`).
// Otherwise its one host, Opus.Brain, speaks the brain wire to it over the
// `run` session's standard input and output (tests/fixtures/brain_wire.json,
// its "comment"; internal/brainwire serves it, as it does for every brain
// driver), and it speaks Codex's own app-server protocol to the harness it
// starts, the command followed by `app-server` (codex.go). It writes
// nothing to its output but the wire's lines, and nothing of the harness's
// standard error, its folder, its sign-in or its account reaches them: the
// harness's errors are said in the driver's own words.
//
// It says `hello` first, naming the wire's version and its boot, fresh for
// each process. A `start` starts the app-server and in it a new thread,
// given the start's tools as its dynamic tools, which the thread keeps for
// its life, or resumes the thread it names; Codex's answer answers
// `started`, and a thread it holds no rollout of answers `gone`. A `work`
// writes nothing: Codex takes no tools after a thread's start. A `post` is
// a turn of its own (`turn/start`), or is added to the native turn under
// way (`turn/steer`), under a uuid derived from the post's id; it is
// `accepted` once Codex answers that it took it, which is no durable
// delivery. A call of CYFR's tool
// (`item/tool/call`) is held and shown as an `ask`, and an `answer`
// answers it by its request's id. A steer Codex answers with an error
// other than a refusal of the request may have been taken, so its post is
// refused and never written again. Stop is the session's close: a native
// turn under way is first sent Codex's own `turn/interrupt`, then the
// harness's input closes, a TERM follows at 2 s and a kill at 5 s
// (brainwire's Process.Stop). A start runs
// the thread in the access it names, one of those `models` lists
// (accessChoices: Full access, no approvals, Codex's own sandbox off and
// asking for nothing), or in the first when it names none; a start naming
// another ends the driver before anything starts. Codex's own tools run
// in its box and are shown by name, each run under its item's id with what
// it runs and a patch's diff, never a command's output, and its reasoning
// summary, which every turn asks for, as `thought`; nothing of a sub-agent's thread is passed on, only
// the session's own call of it. The driver keeps no account of
// calls: which post a native turn answers is Codex's own naming of the
// posts' uuids in that turn, which `idle` passes on, and a turn's usage
// is the thread's total as Codex reports it,
// partial once a sub-agent works and for a resumed thread's first usable
// total, one that carries counts (the wire's "comment" says why).
//
// The driver ends when its input ends (the session is closed), when the
// harness ends, with the harness's status, and on a hangup or a TERM, each
// time closing the harness first.
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
