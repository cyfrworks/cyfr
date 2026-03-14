defmodule Sanctum.PubSub do
  @moduledoc """
  Tenant-aware PubSub topic helper.

  Prefixes topics with tenant scope in Arx mode so broadcasts
  are isolated per-org. Core mode passes topics through unchanged.

  Most PubSub topics in the system are routed through `topic/2`.
  This ensures tenant isolation is enforced consistently:

  - `"execution:events:<id>"` — Opus.ExecutionEventBuffer
  - `"build:<id>"` — Locus.Builder compile progress
  - `"register:<id>"` — Compendium.MCP register progress
  - `"progress:<id>"` — Compendium.MCP pull/publish progress
  - `"schedules"` — Opus.CronScheduler schedule updates
  - `"prism:executions"` — Prism execution list updates
  - `"prism:components"` — Prism component list updates
  - `"prism:requests"` — Prism request log updates
  - `"prism:system"` — Prism system metrics

  The `"sanctum:sessions"` topic is intentionally global (not routed
  through `topic/2`) because it is an internal auth signal only.
  """

  alias Sanctum.Context

  @doc """
  Build a tenant-scoped topic string.

  In core mode or when context has no org_id, returns the base topic unchanged.
  In arx mode with an org_id, prefixes with `"tenant:<org_id>:<project_id>:"`.

  Accepts a `Sanctum.Context`, `nil`, or a raw org_id string.

  ## Examples

      iex> Sanctum.PubSub.topic("execution:events", nil)
      "execution:events"

      iex> ctx = %Sanctum.Context{org_id: "org_1", project_id: "proj_1"}
      iex> Sanctum.PubSub.topic("execution:events", ctx)
      "tenant:org_1:proj_1:execution:events"  # in arx mode

  """
  @spec topic(String.t(), Context.t() | String.t() | nil) :: String.t()
  def topic(base, nil), do: base

  def topic(base, %Context{org_id: nil}), do: base

  def topic(base, %Context{org_id: org_id, project_id: project_id}) do
    if arx_mode?() do
      "tenant:#{org_id}:#{project_id || "default"}:#{base}"
    else
      base
    end
  end

  def topic(base, org_id) when is_binary(org_id) do
    if arx_mode?() and org_id != "" do
      "tenant:#{org_id}:#{base}"
    else
      base
    end
  end

  defp arx_mode? do
    Application.get_env(:cyfr, :edition, :core) == :arx
  end
end
