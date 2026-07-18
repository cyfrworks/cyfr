# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.Enforcement do
  @moduledoc """
  Records policy enforcement decisions to `Arca.PolicyLog` and emits telemetry.

  Every enforcement chokepoint (Opus pre-execution gate, HTTP egress checks,
  tincture rate limits, etc.) calls `record/1` on either an allowed or denied
  outcome. The record lands in the database for audit; a telemetry event lets
  Prism subscribers stream decisions live. Allowed executions record one
  `policy_consultation` row at the pre-execution gate — never one per egress
  request.

  `execution_id` is a plain string, not a foreign key: it is captured before
  the execution row is persisted, so a denial (or a later-stage failure) can
  leave an id that never corresponds to a stored execution. Do not join on it.

  ## Event types

  Enforcement uses `event_type` as the typed rule name so the existing
  `decision_reason` field stays free-text. Standard values:

    * `policy_consultation` — policy was consulted, decision allowed
    * `domain_blocked` — HTTP egress blocked by `allowed_domains`
    * `method_blocked` — HTTP egress blocked by `allowed_methods`
    * `rate_limit` — rate limit exceeded
    * `request_size` — input/output exceeded `max_request_size`/`max_response_size`
    * `dependency_unsatisfied` — formula dependency not installed/granted
    * `policy_unconfigured` — catalyst with no `allowed_domains`/`allowed_paths`
    * `denied` — catch-all when a more specific type doesn't fit

  ## Telemetry

  Emits `[:cyfr, :sanctum, :policy, :decision]` with measurements
  `%{system_time: ..., duration_ms: 0}` and metadata
  `%{event_type, decision, component_ref, component_type, request_id,
    execution_id, user_id, org_id, project_id, decision_reason}`.

  Subscribers should treat any of these as terminal — no follow-up event.
  """

  require Logger

  alias Sanctum.Context

  @type decision :: :allowed | :denied
  @type event_type ::
          :policy_consultation
          | :domain_blocked
          | :method_blocked
          | :rate_limit
          | :request_size
          | :dependency_unsatisfied
          | :policy_unconfigured
          | :denied

  @doc """
  Record a policy enforcement decision.

  ## Required attrs

    * `:ctx` — `Sanctum.Context.t()`. Source of `user_id`, `org_id`, `project_id`,
      `request_id`, `session_id`.
    * `:component_ref` — string reference of the component being evaluated.
    * `:event_type` — typed rule name (atom, see module doc).
    * `:decision` — `:allowed` or `:denied`.

  ## Optional attrs

    * `:component_type` — `:catalyst | :reagent | :formula | :tincture` or string.
    * `:decision_reason` — free-text human-readable explanation.
    * `:host_policy_snapshot` — map or struct of the policy that was evaluated.
    * `:execution_id` — execution id if known.

  Failures are logged and swallowed: enforcement audit is best-effort and must
  never break the calling request.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    case do_record(attrs) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Policy.Enforcement] record failed: #{inspect(reason)}")
        emit_audit_failure(reason)
        :ok
    end
  rescue
    e ->
      Logger.warning("[Policy.Enforcement] record raised: #{Exception.message(e)}")
      emit_audit_failure(e)
      :ok
  end

  defp do_record(%{ctx: %Context{} = ctx} = attrs) do
    event_type = attrs[:event_type] || :denied
    decision = attrs[:decision] || :denied
    now = DateTime.utc_now()

    snapshot =
      case attrs[:host_policy_snapshot] do
        nil -> nil
        s when is_binary(s) -> s
        s -> safe_encode(s)
      end

    record_attrs = %{
      id: generate_id(),
      request_id: ctx.request_id,
      execution_id: attrs[:execution_id],
      session_id: ctx.session_id,
      user_id: ctx.user_id || "system",
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      timestamp: now,
      event_type: to_string(event_type),
      component_ref: attrs[:component_ref],
      component_type: attrs[:component_type] && to_string(attrs[:component_type]),
      decision: to_string(decision),
      host_policy_snapshot: snapshot,
      decision_reason: attrs[:decision_reason]
    }

    case Arca.PolicyLog.record(record_attrs) do
      {:ok, _} ->
        emit_telemetry(record_attrs)
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp do_record(_), do: {:error, :missing_ctx}

  defp emit_telemetry(record_attrs) do
    :telemetry.execute(
      [:cyfr, :sanctum, :policy, :decision],
      %{system_time: System.system_time(), duration_ms: 0},
      Map.take(record_attrs, [
        :event_type,
        :decision,
        :component_ref,
        :component_type,
        :request_id,
        :execution_id,
        :user_id,
        :org_id,
        :project_id,
        :decision_reason
      ])
    )
  rescue
    _ -> :ok
  end

  # Audit writes are best-effort, but a sustained failure means policy decisions
  # are not being recorded. Surface it as a telemetry counter so operators can
  # alarm on dropped audit writes instead of grepping warning logs.
  defp emit_audit_failure(reason) do
    :telemetry.execute(
      [:cyfr, :sanctum, :policy, :audit_failure],
      %{count: 1, system_time: System.system_time()},
      %{reason: inspect(reason)}
    )
  rescue
    _ -> :ok
  end

  defp safe_encode(map) do
    Jason.encode!(map)
  rescue
    e ->
      Logger.debug("[Policy.Enforcement] snapshot encode failed: #{Exception.message(e)}")
      nil
  end

  defp generate_id, do: Emissary.UUID7.generate_id("polog")
end
