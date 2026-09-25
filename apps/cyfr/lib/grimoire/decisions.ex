# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.Decisions do
  @moduledoc """
  The gate's admission decisions, recorded: each call the gate (or an
  entry deciding on its own) admitted or refused is appended once to the
  decision log (`Arca.DecisionLog`) with its request-log row
  (`Grimoire.RequestLog`) in the same transaction, emitted once as
  telemetry read off the same `Prima.Decision`, and — for admitted work —
  completed once when the work returns.

  ## Best effort, never a retry

  Audit never decides an operation's outcome. `open/3` and `close/3`
  always answer `:ok`: a decision or completion the log could not write
  — the budget ran out, the store could not answer, the call id already
  held another decision — is the loss event, and the operation's result
  stands. Nothing here runs an operation again, and nothing waits on the
  store past the log's own budget (`Arca.DecisionLog.budget_ms/0`).

  The loss event is the audit's alarm. A gap in the trail is visible only
  here, so it is catalogued with a metric an operator alerts on
  (`cyfr_grimoire_decision_lost_total`, by stage and kind), not a log
  line alone. Audit is not a reaction, so none of these reaches the bus.

  ## Unknown outcomes

  A decision with no completion has an unknown outcome, never a success:
  the completion is recorded by the process that ran the work, after it
  returns, so a process that dies first — a request wrapper a transport
  kills when its caller hangs up, a schedule's runner task among them —
  leaves the decision admitted and incomplete. So does a schedule's fire
  whose member lost its generation between the run and its answer: a
  stale owner emits no result.

  ## What is not recorded

  Discovery and the audit's own reads (`recorded?/2`): what a caller
  reads to learn what exists or what was decided is neither appended nor
  emitted.
  """

  require Logger

  alias Arca.DecisionLog.AuditFailure
  alias Prima.Decision
  alias Sanctum.Context

  # The tools whose every action reads what exists or what was decided.
  @unrecorded_tools ~w(mcp_log record)

  # Single discovery actions of tools that also act.
  @unrecorded_actions [{"tools", "list"}, {"system", "status"}]

  @doc """
  Whether a call of `tool.action` is recorded. False for discovery and
  the audit's own reads: every `mcp_log` and `record` action, `tools.list`
  and `system.status`. Every other call — every `tools/call` and
  `resources/read` among them — is.
  """
  @spec recorded?(term(), term()) :: boolean()
  def recorded?(tool, _action) when tool in @unrecorded_tools, do: false
  def recorded?(tool, action), do: {tool, action} not in @unrecorded_actions

  @doc """
  Append `decision` under the context's actor — or under none, for a
  refusal before any caller was established — with the request-log row
  that projects it (`Grimoire.RequestLog.opened/3`; `projection` names
  its `:method` and `:input`), then emit the decision's event whether or
  not the append landed, and the loss event when it did not. Always
  `:ok`.
  """
  @spec open(Context.t() | nil, Decision.t(), map()) :: :ok
  def open(ctx, decision, projection \\ %{})

  def open(ctx, %Decision{} = decision, projection)
      when (is_nil(ctx) or is_struct(ctx, Context)) and is_map(projection) do
    appended = append(ctx, decision, projection)
    emit(decision)

    case appended do
      :ok -> :ok
      {:error, %AuditFailure{} = failure} -> lost(failure)
    end
  end

  @doc """
  Record how the admitted call `call_id` ended, on its decision and its
  request-log row: `completion` carries `:result` (the call's
  `{:ok, value} | {:error, reason}`), `:duration_ms`, and for the row
  `:routed_to` and `:error_text` (a sentence to store in place of the
  reason's own).

  `{:ok, _}` is `:succeeded`. `{:error, reason}` takes its class
  (`Grimoire.Error.classify/1`) as the completion's class, and is
  `:cancelled` for class `cancelled`, `:uncertain` for class `uncertain`
  and `:failed` otherwise. The loss event when it cannot be written.
  Always `:ok`.
  """
  @spec close(Context.t() | nil, String.t(), map()) :: :ok
  def close(ctx, call_id, %{result: result} = completion)
      when (is_nil(ctx) or is_struct(ctx, Context)) and is_binary(call_id) do
    case finish(ctx, call_id, result, completion) do
      :ok -> :ok
      {:error, %AuditFailure{} = failure} -> lost(failure)
    end
  end

  # ============================================================================
  # Writes
  # ============================================================================

  defp append(ctx, decision, projection) do
    opts =
      case Grimoire.RequestLog.opened(ctx, decision, projection) do
        nil -> []
        row -> [mcp_log: row]
      end

    Arca.DecisionLog.append(actor(ctx), decision, opts)
  rescue
    exception -> unwritten(:append, exception)
  catch
    :exit, reason -> exited(:append, reason)
  end

  defp finish(ctx, call_id, result, completion) do
    {record, stored} = completed(result, completion)

    opts =
      if tenant?(ctx),
        do: [mcp_log: Grimoire.RequestLog.closed(stored, completion)],
        else: []

    Arca.DecisionLog.finish(actor(ctx), call_id, record, opts)
  rescue
    exception -> unwritten(:finish, exception)
  catch
    :exit, reason -> exited(:finish, reason)
  end

  # The decision's completion, and what its row stores: the output, or the
  # refusal's sentence. The reason is classified once.
  defp completed({:ok, _value} = ok, completion), do: {record(:succeeded, nil, completion), ok}

  defp completed({:error, reason}, completion) do
    refusal = Grimoire.Error.classify(reason)

    outcome =
      case refusal.class do
        :cancelled -> :cancelled
        :uncertain -> :uncertain
        _class -> :failed
      end

    text = Map.get(completion, :error_text) || refusal.message
    {record(outcome, refusal.class, completion), {:error, text}}
  end

  defp record(outcome, class, completion) do
    %{
      completion: outcome,
      completion_class: class,
      duration_ms: Map.get(completion, :duration_ms)
    }
  end

  defp actor(nil), do: nil
  defp actor(%Context{} = ctx), do: Context.actor(ctx)

  defp tenant?(%Context{athanor_id: id}), do: is_binary(id) and id != ""
  defp tenant?(_ctx), do: false

  # A write that raised — a shape the log refuses — is a decision the trail
  # does not hold: logged by its shape alone, as an exit is (a message can
  # carry the values it refused), and counted like any other loss.
  defp unwritten(stage, exception) do
    Logger.error("[Grimoire.Decisions] #{stage} raised #{inspect(exception.__struct__)}")
    {:error, %AuditFailure{kind: :unavailable, stage: stage}}
  end

  # Its shape only: an exit reason can carry a connection's state.
  defp exited(stage, reason) do
    Prima.LoggerContext.unexpected(__MODULE__, reason, :error)
    {:error, %AuditFailure{kind: :unavailable, stage: stage}}
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  @doc false
  # The decision's own event, after the gate has decided it.
  @spec emit(Decision.t()) :: :ok
  def emit(%Decision{admission: :admitted} = decision) do
    :telemetry.execute([:cyfr, :grimoire, :decision, :admitted], %{count: 1}, metadata(decision))
  end

  def emit(%Decision{admission: :refused} = decision) do
    :telemetry.execute(
      [:cyfr, :grimoire, :decision, :refused],
      %{count: 1},
      Map.put(metadata(decision), :refusal_class, decision.refusal_class)
    )
  end

  @doc false
  # A decision (`stage: :append`) or its completion (`stage: :finish`) the
  # log could not write, and why.
  @spec lost(AuditFailure.t()) :: :ok
  def lost(%AuditFailure{stage: stage, kind: kind}) do
    :telemetry.execute([:cyfr, :grimoire, :decision, :lost], %{count: 1}, %{
      stage: stage,
      kind: kind
    })
  end

  # Metric tags need a value: an operation not yet named reads as "".
  defp metadata(%Decision{} = decision) do
    %{plane: decision.plane, tool: decision.tool || "", action: decision.action || ""}
  end
end
