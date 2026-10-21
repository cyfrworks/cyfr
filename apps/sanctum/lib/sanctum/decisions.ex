# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Decisions do
  @moduledoc """
  The gate's admission decisions, recorded: each call the gate (or an
  entry deciding on its own) admitted or refused is appended once to the
  decision log (`Arca.DecisionLog`) with its request-log row
  (`Sanctum.RequestLog`) in the same transaction, emitted once as
  telemetry read off the same `Prima.Decision`, and — for admitted work —
  completed once when the work returns.

  ## Best effort, never a retry

  Audit never decides an operation's outcome. `open/3` and `close/3`
  always answer `:ok`: a decision or completion the log could not write
  — the budget ran out, the store could not answer, every writer the node
  runs was already busy, the call id already held another decision — is
  the loss event, and the operation's result stands. Nothing here runs an
  operation again or asks the log a second time, and nothing waits on the
  store past the log's own budget (`Arca.DecisionLog.budget_ms/0`); a
  write past the node's writer cap waits for nothing at all.

  Batching decisions, or dropping a class of them, changes the one record
  per call this module keeps: it is a measured design change, never a
  tuning of the writers or the budget.

  The loss event is the audit's alarm. A gap in the trail is visible only
  here, so it is catalogued with a metric an operator alerts on
  (`cyfr_sanctum_decision_lost_total`, by stage and kind — `capacity`
  for an overload the writer cap refused), not a log line alone. Audit is
  not a reaction, so none of these reaches the bus.

  ## What is stored

  Every text a decision and its request-log row store passes through
  `Prima.Sanitizer` here, at the one place both are written: the
  operation's name and action, the refusal's sentence, a failure's text,
  and the row's input and output (`Sanctum.RequestLog`). A credential a
  caller put in an action's name, or that a sentence quotes, is stored as
  the placeholder in both, so the row and its decision agree; the refusal
  a caller is answered is its own and unchanged.

  ## Unknown outcomes

  A decision with no completion has an unknown outcome, never a success:
  the completion is recorded by the process that ran the work, after it
  returns, so a process that dies first — a request wrapper a transport
  kills when its caller hangs up, a schedule's runner task among them —
  leaves the decision admitted and incomplete. So does a schedule's fire
  whose member lost its generation between the run and its answer: a
  stale owner emits no result.

  ## What is not recorded

  Admitted discovery, the audit's own reads, and the reads the shell makes
  of the caller's own state on its own initiative, each a read its
  declaration marks `recorded: false` (`Sanctum.Catalog.recorded?/2`): what a
  caller is admitted to read to learn what exists or what was decided,
  and what the console reads again of the person's own state as they
  navigate, is neither appended nor emitted. A refusal of any call is
  recorded: it is rare in a healthy client and is what an audit exists to
  see. An entry refusing before the gate does not know the operation and
  records whatever the method (`refused/3`).

  ## What a tag carries

  A refused call's names are the caller's own — a guest names any tool,
  an anonymous request any action — so a metric tag holds only a name
  the operation table knows and `"unknown"` otherwise: a tag is a series,
  and a series per guessed name is a series an attacker mints. The row
  keeps the name as sent, cut to the column (`bounded/1`).

  ## Reading the record

  Decisions are security rows: Sanctum is their only reader, and a reader
  above it takes them from here. `list/2` and `correlate/2` read the
  caller's athanor's decisions under the context's actor and nothing
  wider, a platform administrator's included: a context with no athanor
  is refused, and no option names another athanor. `purge_global/2` is
  the host's retention of the decisions without a tenant, under the
  platform's own system actor alone.
  """

  require Logger

  alias Arca.DecisionLog.AuditFailure
  alias Prima.Decision
  alias Sanctum.Context

  @unknown "unknown"

  @doc """
  The call's identity: `id` when the entry minted one before its own
  checks (a `call_` id), a new one when it minted none. Anything else
  raises `ArgumentError`: an identity is minted, never carried in from a
  caller's arguments.
  """
  @spec call_id!(String.t() | nil) :: String.t()
  def call_id!(nil), do: Prima.UUID7.generate_id("call")
  def call_id!("call_" <> rest = call_id) when rest != "", do: call_id

  def call_id!(_other),
    do: raise(ArgumentError, "a decision's :call_id is a call_ id minted by its entry")

  @doc """
  An operation name as a decision stores it: a name that is not a string
  names nothing, and the columns hold 255 characters on PostgreSQL, so a
  longer name — a guest's own — is cut rather than costing the record.
  It is sanitized before it is cut, so no cut leaves part of a
  credential the whole would have redacted.
  """
  @spec bounded(term()) :: String.t() | nil
  def bounded(value) when is_binary(value),
    do:
      value |> Prima.Sanitizer.sanitize() |> String.codepoints() |> Enum.take(255) |> Enum.join()

  def bounded(_value), do: nil

  @doc """
  A refusal an entry makes before the gate, as a decision: `reason` is a
  `%Prima.Refusal{}` or a reason term (`Sanctum.Refusals.classify/1`), whose
  class and sentence the decision carries. `fields` name the `:plane`
  (required) and may name `:call_id` (`call_id!/1`), `:request_id`
  (default the context's), `:parent_call_id`, `:tool` and `:action`. The
  identity is the context's when one exists and none otherwise: a refusal
  before authentication has no actor and a null tenant. `inserted_at` is
  now. `open/3` records it.
  """
  @spec refused(Context.t() | nil, term(), keyword()) :: Decision.t()
  def refused(ctx, reason, fields)
      when (is_nil(ctx) or is_struct(ctx, Context)) and is_list(fields) do
    fields = Map.new(fields)
    refusal = Sanctum.Refusals.classify(reason)

    %Decision{
      call_id: call_id!(Map.get(fields, :call_id)),
      parent_call_id: Map.get(fields, :parent_call_id),
      request_id: Map.get(fields, :request_id) || (ctx && ctx.request_id),
      user_id: ctx && ctx.user_id,
      athanor_id: ctx && ctx.athanor_id,
      plane: Map.fetch!(fields, :plane),
      tool: bounded(Map.get(fields, :tool)),
      action: bounded(Map.get(fields, :action)),
      inserted_at: DateTime.utc_now(),
      admission: :refused,
      refusal_class: refusal.class,
      reason: refusal.message
    }
  end

  @doc """
  Append `decision` under the context's actor — or under none, for a
  refusal before any caller was established — with the request-log row
  that projects it (`Sanctum.RequestLog.opened/3`; `projection` names
  its `:method` and `:input`), then emit the decision's event whether or
  not the append landed, and the loss event when it did not. Always
  `:ok`.
  """
  @spec open(Context.t() | nil, Decision.t(), map()) :: :ok
  def open(ctx, decision, projection \\ %{})

  def open(ctx, %Decision{} = decision, projection)
      when (is_nil(ctx) or is_struct(ctx, Context)) and is_map(projection) do
    decision = stored(decision)
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
  `:routed_to`.

  `{:ok, _}` is `:succeeded`. `{:error, reason}` takes its class
  (`Sanctum.Refusals.classify/1`) as the completion's class, and is
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
  # Reads
  # ============================================================================

  @doc """
  The caller's athanor's decisions, newest first, read under the context's
  actor (`Arca.DecisionLog.list/2`, whose options `opts` are; an
  `:athanor_id` among them names nothing). A context with no athanor is
  `{:error, :no_athanor}`, whatever its scope. The log's refusals pass
  through as it answers them.
  """
  @spec list(Context.t(), keyword()) ::
          {:ok, [Decision.t()]} | {:error, :no_athanor | :database_error}
  def list(%Context{} = ctx, opts) when is_list(opts),
    do: Arca.DecisionLog.list(Context.actor(ctx), opts)

  @doc """
  Every decision of the caller's athanor made under the ingress request
  `request_id` (a chain's calls), oldest first, read under the context's
  actor (`Arca.DecisionLog.correlate/2`). A context with no athanor is
  `{:error, :no_athanor}`, whatever its scope.
  """
  @spec correlate(Context.t(), String.t()) ::
          {:ok, [Decision.t()]} | {:error, :no_athanor | :database_error}
  def correlate(%Context{} = ctx, request_id) when is_binary(request_id),
    do: Arca.DecisionLog.correlate(Context.actor(ctx), request_id)

  @doc """
  Delete the host's decisions, the rows without a tenant, made before
  `cutoff`: the host's responsibility under its held retention claim
  (`Cyfr.Boundaries.system_responsibilities/0`). Only the platform's own
  system actor (`Prima.Actor.system/0`) may; any other is
  `{:error, :forbidden}` before any query (`Arca.DecisionLog.purge_global/2`),
  and it never touches an athanor's row. It is the one function here that
  takes a bare actor, since the retention step holds no context; every
  read takes the caller's.
  """
  @spec purge_global(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :forbidden | :database_error}
  def purge_global(%Prima.Actor{} = actor, %DateTime{} = cutoff),
    do: Arca.DecisionLog.purge_global(actor, cutoff)

  # ============================================================================
  # Writes
  # ============================================================================

  defp append(ctx, decision, projection) do
    opts =
      case Sanctum.RequestLog.opened(ctx, decision, projection) do
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
        do: [mcp_log: Sanctum.RequestLog.closed(ctx, stored, completion)],
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
    refusal = Sanctum.Refusals.classify(reason)

    outcome =
      case refusal.class do
        :cancelled -> :cancelled
        :uncertain -> :uncertain
        _class -> :failed
      end

    text = Prima.Sanitizer.sanitize(refusal.message)
    {record(outcome, refusal.class, completion), {:error, text}}
  end

  defp record(outcome, class, completion) do
    %{
      completion: outcome,
      completion_class: class,
      duration_ms: Map.get(completion, :duration_ms)
    }
  end

  # The decision's texts as they are stored, and as its row and its event
  # read them (`Prima.Sanitizer`).
  defp stored(%Decision{} = decision) do
    %{
      decision
      | tool: Prima.Sanitizer.sanitize(decision.tool),
        action: Prima.Sanitizer.sanitize(decision.action),
        reason: Prima.Sanitizer.sanitize(decision.reason)
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
    Logger.error("[Sanctum.Decisions] #{stage} raised #{inspect(exception.__struct__)}")
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
    :telemetry.execute([:cyfr, :sanctum, :decision, :admitted], %{count: 1}, metadata(decision))
  end

  def emit(%Decision{admission: :refused} = decision) do
    :telemetry.execute(
      [:cyfr, :sanctum, :decision, :refused],
      %{count: 1},
      Map.put(metadata(decision), :refusal_class, decision.refusal_class)
    )
  end

  @doc false
  # A decision (`stage: :append`) or its completion (`stage: :finish`) the
  # log could not write, and why.
  @spec lost(AuditFailure.t()) :: :ok
  def lost(%AuditFailure{stage: stage, kind: kind}) do
    :telemetry.execute([:cyfr, :sanctum, :decision, :lost], %{count: 1}, %{
      stage: stage,
      kind: kind
    })
  end

  # Metric tags need a value: an operation not yet named reads as "". An
  # admitted call's names are the table's; a refused call's are whatever
  # the caller sent, so its tags hold only names the table knows.
  defp metadata(%Decision{admission: :admitted} = decision) do
    %{plane: decision.plane, tool: decision.tool || "", action: decision.action || ""}
  end

  defp metadata(%Decision{} = decision) do
    {tool, action} = catalogued(decision.tool, decision.action)
    %{plane: decision.plane, tool: tool, action: action}
  end

  defp catalogued(nil, _action), do: {"", ""}

  defp catalogued(tool, action) do
    case Sanctum.Catalog.lookup(tool) do
      {:ok, {_module, meta}} -> {tool, action_tag(meta, action)}
      :miss -> {@unknown, if(is_nil(action), do: "", else: @unknown)}
    end
  end

  defp action_tag(_meta, nil), do: ""

  defp action_tag(%{operations: operations}, action) when is_list(operations) do
    if Enum.any?(operations, &(is_map(&1) and Map.get(&1, :action) == action)),
      do: action,
      else: @unknown
  end

  defp action_tag(_meta, _action), do: @unknown
end
