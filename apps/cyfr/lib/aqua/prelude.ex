# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Prelude do
  @moduledoc """
  The system-prompt text that teaches an agent the intent protocol, and
  lists the actions its `tool_policy` marks `ask` — sorted, so the prefix
  stays stable for prompt caching.
  """

  @system_prelude_base """


  ---

  ## AQUA Shell Control

  When the user asks you to change the interface, or you want to bring
  something on screen, end your reply with a fenced block:

  ```aqua-actions
  [{"kind": "ui.execution.focus", "id": "exec_..."}]
  ```

  The block executes after your reply completes. Guidelines:

  - Only emit it when navigation/UI control actually helps. Most replies do
    not need a block.
  - One block per reply. Multiple actions may be listed in the same array;
    they execute in order.
  - Do not mention or describe the JSON in prose — the user will not see it.
  - Prefer focus actions over plain `ui.navigate` when targeting a specific
    resource.

  Available action kinds:

  - `ui.navigate` `{"path": "/activities" | "/executions" | "/components" | …}`
  - `ui.overlay.open` `{"state"?: "half" | "full"}`
  - `ui.overlay.close`
  - `ui.overlay.focus_input`
  - `ui.copy_clipboard` `{"text": "..."}`
  - `ui.activity.focus` `{"id": "req_..."}`
  - `ui.execution.focus` `{"id": "exec_..."}`
  - `ui.schedule.focus` `{"id": "sched_..."}`
  - `ui.component.focus` `{"ref": "publisher.name@version"}`
  - `ui.tincture.focus` `{"publisher": "...", "name": "..."}`
  - `ui.mcp_server.focus` `{"name": "..."}`
  - `ui.request_approval` `{"title": "...", "summary": "...", "risk": "low"|"medium"|"high", "action_description": "...", "proposal"?: {"tool": "...", "action": "...", "args": {...}}}` — ask the user to confirm something. The decision arrives as a new user turn (`[System: user approved ...]` / `[System: user declined ...]`); act accordingly. With a `proposal` payload, the harness executes the tool call on your behalf when the user clicks Approve. Use this for any action that publishes, deletes, sends externally, or costs money — and for every action listed under "Actions that need approval" below.
  """

  @doc """
  Build the system-prompt prelude for an agent, listing the approvable
  `(tool, action)` targets derived from its `tool_policy`. The text is
  appended after the orchestrator's base prompt.

  Stable for prompt-caching: the approvable list is sorted deterministically
  so the prefix only invalidates when the manifest changes.
  """

  @spec system_prelude(map()) :: String.t()

  def system_prelude(tool_policy \\ %{}) when is_map(tool_policy) do
    @system_prelude_base <> approval_section(tool_policy)
  end

  defp approval_section(tool_policy) when is_map(tool_policy) do
    approvals =
      tool_policy
      |> Enum.flat_map(fn
        {"native_search", _} -> []
        {key, "ask"} -> if Aqua.Kinds.proposable?(key), do: [key], else: []
        _ -> []
      end)
      |> Enum.sort()

    case approvals do
      [] ->
        ""

      keys ->
        lines = Enum.map(keys, fn key -> "  - `#{key}`" end)

        "\n## Actions that need approval\n\n" <>
          "You cannot call these tool actions directly. To run any of them, end\n" <>
          "your reply with a `ui.request_approval` block carrying a `proposal`\n" <>
          "payload — the harness executes it on user approval and reports the\n" <>
          "result back as the next user turn (`[System: user approved … Result: …]` /\n" <>
          "`[System: user declined …]`).\n\n" <>
          Enum.join(lines, "\n") <> "\n"
    end
  end
end
