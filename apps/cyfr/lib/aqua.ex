# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua do
  @moduledoc """
  The agent-orchestration domain: conversations, turns, and the action
  plane an agent speaks through.

  - `Aqua.ConversationRunner` — one process per conversation with a live
    turn; every send, approval and decline is a call into it.
  - `Aqua.Turn` — builds a turn's input for the AQUA formula and parses
    its completion.
  - `Aqua.Prompt` — the one composer of the system prompt, from the
    resolved agent and the turn's pinned authority.
  - `Aqua.ToolGrants` — standing approvals as rows, composed over the
    agent's declared `tool_policy`.
  - `Aqua.Actions` — validates the `aqua-actions` blocks a model emits
    into typed client intents, against the agent's tool policy.
  - `Aqua.VirtualTools` — the UI-plane pseudo-tools those intents name.
  - `Aqua.AgentConfig` — the soul's and the roles' definitions and prompts.
  - `Aqua.Aloud` — the one deliberate copy: your own lines, said into an
    estate you belong to.
  - `Aqua.Attachments` — chat attachment refs and blobs.
  - `Aqua.ConversationCompactor` — bounds a history to the model window.
  - `Aqua.MCPHelpers` — the single seam to `Emissary.MCP.*`
    (`Aqua.ToolSeamTest` keeps it the only one).

  This is domain, not console: it drives `PrismWeb`'s chat through PubSub
  broadcasts and rows, and never names the console back (pinned by
  `Cyfr.NamespaceDirectionTest`).
  """
end
