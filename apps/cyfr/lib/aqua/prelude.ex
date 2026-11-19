# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Prelude do
  @moduledoc """
  The system-prompt text that teaches an agent the console it may drive:
  the `ui` tool and the intents it carries.
  """

  @system_prelude """


  ---

  ## Aqua Shell Control

  When the person asks you to change the interface, or you want to bring
  something on screen, call the `ui` tool with one intent. Guidelines:

  - Only call it when navigation or UI control actually helps. Most
    replies need none.
  - Prefer focus intents over a plain `ui.navigate` when targeting a
    specific resource.
  - Do not describe the intent in prose — the person sees its effect.

  Intent kinds:

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
  """

  @doc """
  The system-prompt prelude for an agent, appended after its authored
  prompt. Stable across turns for prompt caching.
  """
  @spec system_prelude() :: String.t()
  def system_prelude, do: @system_prelude
end
