# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.PubSub do
  @moduledoc """
  Tenant-aware PubSub topic helper.

  Prefixes every topic with `"tenant:<org_id>:<project_id>:"` so broadcasts
  are isolated per tenant. Single-user installs carry the sentinel
  `org_id: "local"` and `project_id: "default"`, so topics there look like
  `"tenant:local:default:<base>"` — uniform across deployments.

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

  Every context carries a resolved `org_id` (defaulting to `"local"` in
  single-user installs). Calls without a context or with `nil`/empty
  `org_id` indicate a bug and raise.

  ## Examples

      iex> ctx = %Sanctum.Context{org_id: "local", project_id: "default"}
      iex> Sanctum.PubSub.topic("execution:events", ctx)
      "tenant:local:default:execution:events"

      iex> ctx = %Sanctum.Context{org_id: "acme", project_id: "main"}
      iex> Sanctum.PubSub.topic("execution:events", ctx)
      "tenant:acme:main:execution:events"
  """
  @spec topic(String.t(), Context.t() | nil) :: String.t()
  def topic(base, nil) do
    raise ArgumentError,
          "PubSub.topic/2 requires a non-nil context with org_id, " <>
            "got nil for topic #{inspect(base)}"
  end

  def topic(base, %Context{org_id: org_id}) when org_id in [nil, ""] do
    raise ArgumentError,
          "PubSub.topic/2 requires a Context with non-empty org_id, " <>
            "got #{inspect(org_id)} for topic #{inspect(base)}"
  end

  def topic(base, %Context{org_id: org_id, project_id: project_id}) do
    "tenant:#{org_id}:#{project_id || "default"}:#{base}"
  end
end
