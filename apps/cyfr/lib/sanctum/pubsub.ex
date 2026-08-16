# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSub do
  @moduledoc """
  Tenant-aware PubSub topic helper.

  Prefixes every topic with `"tenant:<athanor_id>:"` so broadcasts are
  isolated per athanor.

  Most PubSub topics in the system are routed through `topic/2`. This
  ensures tenant isolation is enforced consistently:

  - `"execution:events:<id>"` — Opus.ExecutionEventBuffer
  - `"build:<id>"` — Locus.Builder compile progress
  - `"register:<id>"` — Compendium.MCP register progress
  - `"progress:<id>"` — Compendium.MCP pull/publish progress
  - `"schedules"` — Opus.CronScheduler schedule updates
  - `"prism:executions"` — Prism execution list updates
  - `"prism:components"` — Prism component list updates
  - `"prism:requests"` — Prism request log updates

  The `"sanctum:sessions"` topic is intentionally global (not routed
  through `topic/2`) because it is an internal auth signal only.
  """

  alias Sanctum.Context

  @doc """
  Build a tenant-scoped topic string.

  Every context carries a resolved `athanor_id`. Calls without a context or
  with a `nil`/empty athanor indicate a bug and raise.

  ## Examples

      iex> ctx = %Sanctum.Context{athanor_id: "ath_1"}
      iex> Sanctum.PubSub.topic("execution:events", ctx)
      "tenant:ath_1:execution:events"
  """
  @spec topic(String.t(), Context.t() | nil) :: String.t()
  def topic(base, nil) do
    raise ArgumentError,
          "PubSub.topic/2 requires a non-nil context with athanor_id, " <>
            "got nil for topic #{inspect(base)}"
  end

  def topic(base, %Context{athanor_id: athanor_id}) when athanor_id in [nil, ""] do
    raise ArgumentError,
          "PubSub.topic/2 requires a Context with non-empty athanor_id, " <>
            "got #{inspect(athanor_id)} for topic #{inspect(base)}"
  end

  def topic(base, %Context{athanor_id: athanor_id}) do
    "tenant:#{athanor_id}:#{base}"
  end
end
