# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua do
  @moduledoc """
  The agent-orchestration domain: threads, turns, and the action
  plane an agent speaks through.

  - `Aqua.Runner` — one process per thread; every send is admitted
    and accepted through it, and it owns the turns' lifecycle.
  - `Aqua.Loop` — one turn, run by the process that holds its root: the
    model rounds, the dispatch, the cards, the clones (`Aqua.Loop.Turn`,
    `Aqua.Loop.Binding`, `Aqua.Loop.Request`, `Aqua.Loop.Planner`,
    `Aqua.Loop.Policy`, `Aqua.Loop.Clone`).
  - `Aqua.Tape` — the one persistence port of the runner and the loop.
  - `Aqua.Approvals` — a card decided once, from its own rows;
    `Aqua.Standing` — what may stand for later calls; `Aqua.Launch` — an
    approved launch run as its approver.
  - `Aqua.Agent` — the agent a turn is addressed to, as the
    approvals re-authorise a card against it.
  - `Aqua.Prompt` — the one composer of the system prompt, from the
    resolved agent and the turn's pinned authority.
  - `Aqua.ToolGrants` — standing approvals as rows, composed over the
    agent's declared `tool_policy`.
  - `Aqua.Hands` — the pseudo-tools that run on the bundled catalysts, and
    the console intents (`Aqua.Intents`).
  - `Aqua.AgentConfig` — the soul's and the roles' definitions and prompts;
    `Aqua.Roster` — who may be addressed.
  - `Aqua.Aloud` — the one deliberate copy: your own lines, said into an
    estate you belong to.
  - `Aqua.Notes` — what somebody chose to keep out of a thread: the
    estate's pinned page and its filed pile, surviving the tape.
  - `Aqua.RoomExcerpt` — what the person has open beside the thread, read
    for the turn as quoted material.
  - `Aqua.Attachments` — chat attachment refs and blobs.
  - `Aqua.Ops` — the single seam to `Emissary.MCP.*`
    (`Aqua.ToolSeamTest` keeps it the only one).

  This is domain, not console: it drives `PrismWeb`'s chat through PubSub
  broadcasts and rows, and never names the console back (pinned by
  `Cyfr.NamespaceDirectionTest`).
  """
end
