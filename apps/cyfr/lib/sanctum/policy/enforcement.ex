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
    * `scheme_blocked` — HTTP egress blocked by scheme
    * `rate_limit` — rate limit exceeded
    * `request_size` — input/output exceeded `max_request_size`/`max_response_size`
    * `denied` — catch-all when a more specific type doesn't fit

  ## Telemetry

  Emits `[:cyfr, :sanctum, :policy, :decision]` with measurements
  `%{system_time: ..., duration_ms: 0}` and metadata
  `%{event_type, decision, component_ref, component_type, request_id,
    execution_id, user_id, athanor_id, decision_reason}`.

  Subscribers should treat any of these as terminal — no follow-up event.
  """

  require Logger

  alias Sanctum.Context

  @type decision :: :allowed | :denied
  @type event_type ::
          :policy_consultation
          | :domain_blocked
          | :method_blocked
          | :scheme_blocked
          | :rate_limit
          | :request_size
          | :denied

  @doc """
  Record a policy enforcement decision.

  ## Required attrs

    * `:ctx` — `Sanctum.Context.t()`. Source of `user_id`, `athanor_id`,
      `request_id`, `execution_id`.
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
        # `:error`, like every other "a security record did not land" site
        # (`Arca.RecordSink`, `Emissary.MCP.RequestLog`, `Arca.AuditHandler`).
        # An operator alarming on level:error over the audit plane was getting
        # an arbitrary subset while this one said :warning.
        Logger.error("[Policy.Enforcement] record failed: #{inspect(reason)}")
        emit_audit_failure(reason)
        :ok
    end
  rescue
    e ->
      Logger.error("[Policy.Enforcement] record raised: #{Exception.message(e)}")
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
      user_id: ctx.user_id || "system",
      athanor_id: ctx.athanor_id,
      timestamp: now,
      event_type: to_string(event_type),
      component_ref: attrs[:component_ref],
      component_type: attrs[:component_type] && to_string(attrs[:component_type]),
      decision: to_string(decision),
      host_policy_snapshot: snapshot,
      decision_reason: attrs[:decision_reason],
      # Store runtime facts; join attribution from immutable consent rows on read.
      consent_id: attrs[:consent_id],
      activation_digest: attrs[:activation_digest],
      dep_ref: attrs[:dep_ref],
      need: attrs[:need],
      cursor_state: attrs[:cursor_state],
      chain: encode_chain(attrs[:chain]),
      value_source: attrs[:value_source]
    }

    # A denial is on disk before the refusal returns; an allowed line is
    # bookkeeping and rides the write-behind.
    if decision == :allowed do
      Arca.RecordSink.enqueue({:policy_log, record_attrs})
      emit_telemetry(record_attrs)
      :ok
    else
      case Arca.PolicyLog.record(record_attrs) do
        {:ok, _} ->
          emit_telemetry(record_attrs)
          :ok

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, refusal} ->
          # A store's refusal is not a typed word, and its own shape must
          # not escape the audit plane: the caller gets one word and the
          # detail goes to the log. Read by field rather than by struct —
          # the rule for a decision this domain records is that it never
          # names the store's types.
          Logger.warning("[Policy.Enforcement] denial record refused: " <> detail(refusal))

          {:error, :audit_write_failed}
      end
    end
  end

  defp do_record(_), do: {:error, :missing_ctx}

  # The refusal's own detail, without naming the store's shapes: a
  # validation refusal carries `errors`, anything else is sanitized whole
  # — a policy record holds no credential, but the audit plane is not the
  # place to find out.
  defp detail(%{errors: errors}) when is_list(errors), do: inspect(errors)

  defp detail(other),
    do: inspect(Cyfr.Sanitizer.sanitize(other), limit: 20, printable_limit: 200)

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
        :athanor_id,
        :decision_reason,
        :consent_id,
        :activation_digest,
        :dep_ref,
        :need,
        :cursor_state,
        :value_source
      ])
    )
  rescue
    # A raising telemetry handler must not fail the decision — but a
    # swallowed raise here would hide a broken audit pipeline entirely.
    e ->
      Logger.warning("[Policy.Enforcement] decision telemetry raised: " <> Exception.message(e))

      :ok
  end

  # Audit writes are best-effort, but a sustained failure means policy decisions
  # are not being recorded. Surface it as a telemetry counter so operators can
  # alarm on dropped audit writes instead of grepping warning logs.
  defp emit_audit_failure(reason) do
    :telemetry.execute(
      [:cyfr, :sanctum, :policy, :audit_failure],
      %{count: 1, system_time: System.system_time()},
      # As DATA, not `inspect(reason)`: `Arca.AuditHandler` redacts this
      # metadata by KEY on its way to the sinks, and key-based redaction
      # cannot see inside a string — so a credential-bearing reason flattened
      # here reached an operator's sink verbatim.
      %{reason: reason}
    )
  rescue
    # This function exists to make dropped audit writes visible; its own
    # failure must at least reach the log.
    e ->
      Logger.warning(
        "[Policy.Enforcement] audit-failure telemetry raised: " <> Exception.message(e)
      )

      :ok
  end

  defp safe_encode(map) do
    Jason.encode!(map)
  rescue
    e ->
      # The snapshot is a FIELD of the audit record, so losing it is a gap in
      # the record — not a debug detail that disappears below the default
      # level while everything else in this module speaks at :warning.
      Logger.warning("[Policy.Enforcement] snapshot encode failed: #{Exception.message(e)}")
      nil
  end

  # The chain is a list of refs; no native array column exists on either
  # adapter, so it stores as text + Jason like every other list here.
  defp encode_chain(nil), do: nil
  defp encode_chain(chain) when is_list(chain), do: safe_encode(chain)
  defp encode_chain(chain) when is_binary(chain), do: chain
  defp encode_chain(_), do: nil

  defp generate_id, do: Cyfr.UUID7.generate_id("polog")
end
