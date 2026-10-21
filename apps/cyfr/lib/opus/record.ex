# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Record do
  @moduledoc """
  Struct and storage for execution records.

  Execution records capture the complete state of a component execution
  for auditing, debugging, and forensic replay purposes.

  ## Storage

  Records are stored through `Arca.Execution` in the `executions` table, on
  either database adapter. The crash-resilient pattern writes a "started"
  record BEFORE execution begins, and updates it with completion/failure
  data AFTER execution finishes.

  If an execution record exists with status "running" but no completion,
  the execution crashed or was interrupted.

  ## Usage

      # Create and write started record BEFORE execution
      record = Record.new(ctx, reference, input)
      :ok = Record.write_started(ctx, record, retention_class: class)

      # Execute...

      # On success: write completion
      record = Record.complete(record, output)
      {:ok, _ledger} = Record.write_completed_ledger(record, retention_class: class)

      # On failure: write failure
      record = Record.fail(record, error)
      :ok = Record.write_failed(record)

  ## Correlation IDs

  All IDs use UUID v7 (RFC 9562) format for time-ordering:
  - `execution_id`: `exec_<uuid7>` - Generated for each execution
  - `request_id`: `req_<uuid7>` - From the MCP request context (if available)
  - `call_id`: `call_<uuid7>` - The admission decision the run was started
    under (`Sanctum.Context`'s `call_id`), which the calls its chain makes
    name as their parent call
  """

  require Logger

  alias Sanctum.Context

  # Each stored execution status (`Prima.ExecutionState.statuses/0`) and
  # its atom, made at compile time so parsing a row never makes one.
  @status_atoms Map.new(Prima.ExecutionState.statuses(), &{&1, String.to_atom(&1)})

  @typedoc """
  A decoded JSON value. The `input`, `output` and `host_policy` columns hold
  whatever the execution produced, and a component's result is not required
  to be an object.
  """
  @type json :: map() | list() | String.t() | number() | boolean() | nil

  @typedoc "The executable component types (`Prima.ComponentRef.executable_types/0`)."
  @type component_type :: :catalyst | :reagent | :formula

  @typedoc """
  What a stored row ran: an executable component type, a turn root's
  `:agent`, or the `:tool_server` an MCP tool call
  (`Emissary.External.Proxy`) runs on.
  """
  @type row_type :: component_type() | :agent | :tool_server

  @type t :: %__MODULE__{
          id: String.t(),
          request_id: String.t() | nil,
          call_id: String.t() | nil,
          user_id: String.t(),
          athanor_id: String.t() | nil,
          reference: String.t(),
          resolved_from: String.t() | nil,
          component_type: row_type(),
          component_digest: String.t() | nil,
          input: json(),
          output: json(),
          status: :running | :paused | :completed | :failed | :cancelled,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          error: String.t() | nil,
          host_policy: json(),
          parent_execution_id: String.t() | nil,
          child_key: String.t() | nil,
          root_execution_id: String.t() | nil,
          resolver_digest: String.t() | nil,
          activation_digest: String.t() | nil,
          activation_graph: String.t() | nil,
          profile_id: String.t() | nil,
          attempt: String.t() | nil,
          kind: String.t() | nil,
          turn_id: String.t() | nil,
          schedule_id: String.t() | nil,
          reservation: map() | nil,
          sources: [Prima.Source.t()],
          launch_classes: [Prima.Source.class()]
        }

  # One execution row, as its admission builds it and a read returns it.
  # What admission alone needs to write the row (its grant, its origin,
  # its payloads' retention class and retained input) is admission's
  # (`write_started/3`), not the row's.
  defstruct [
    :id,
    :request_id,
    # The admission decision the run was started under: the context's
    # `call_id` when the record is made (`Arca.DecisionLog`).
    :call_id,
    :user_id,
    :athanor_id,
    :reference,
    :resolved_from,
    :component_type,
    :component_digest,
    :input,
    :output,
    :status,
    :started_at,
    :completed_at,
    :duration_ms,
    :error,
    :host_policy,
    :parent_execution_id,
    # The key the parent's runner minted for this child (`Prima.HostAPI`
    # `t:child_key/0`), unique under the parent; nil for a root.
    :child_key,
    :root_execution_id,
    :resolver_digest,
    :activation_digest,
    :activation_graph,
    :profile_id,
    # The attempt that owns the row (`Arca.ExecutionAttempts`): minted with
    # the record, opened at admission, named by every later write.
    :attempt,
    # What the row is (`component | turn | tool_call`) and the turn it
    # belongs to; a turn root is admitted by `Opus.TurnRoot`.
    :kind,
    :turn_id,
    # The schedule this root runs for (`Opus.Schedules`); nil otherwise.
    :schedule_id,
    # A root's invocation reservation, `%{budget_id, cap}`, minted at
    # admission; nil for a child.
    :reservation,
    # A root's seed (`Prima.Source`), from what admitted it (`root_seed/2`);
    # a child's is its parent's ledger, read where it is admitted. On a
    # record read back, the row's ledger as that read found it.
    sources: [],
    # The classes an approved launch let flow to every exit of its tree,
    # written into the root's policy (`Arca.Execution.launch_key/0`).
    launch_classes: []
  ]

  @doc """
  Create a new execution record when starting execution.

  Options:
  - `:component_type` - The component type (:catalyst, :reagent, :formula). Defaults to :reagent.
  - `:parent_execution_id` - Parent formula execution ID for sub-invocations.
  - `:child_key` - The key the parent's runner minted for this child, which
    the row carries so a repeated admission under it answers this child.
  - `:root_execution_id` - The chain's root execution ID. A root stamps
    itself, so every row in a chain carries the same value.

  A root's source ledger is seeded from what admitted it, never from an
  argument: an approved launch's stamp (`:launch`, `%{sources, classes}`,
  which `Opus.Admission` takes off the approver's context alone) seeds the
  turn's sources and writes the classes the person let flow; a webhook's
  run starts outside; a frame's invocation starts with the classes its
  declared reads may carry (`:frame_sources`, which `Opus.Tincture`
  alone passes); an interactive, programmatic, scheduled or feed run
  starts empty until it reads. A child's is its parent's.
  """
  @spec new(Context.t(), String.t(), map(), keyword()) :: t()
  def new(%Context{} = ctx, reference, input, opts \\ []) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    parent_execution_id = Keyword.get(opts, :parent_execution_id)
    id = Keyword.get(opts, :execution_id) || generate_id()
    # A root execution is its own root: one comparison answers "is this
    # row in my chain" without walking parents.
    root_execution_id = Keyword.get(opts, :root_execution_id) || id

    %__MODULE__{
      id: id,
      request_id: ctx.request_id,
      call_id: ctx.call_id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      reference: reference,
      component_type: component_type,
      component_digest: nil,
      input: input,
      output: nil,
      status: :running,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      duration_ms: nil,
      error: nil,
      host_policy: nil,
      parent_execution_id: parent_execution_id,
      child_key: Keyword.get(opts, :child_key),
      root_execution_id: root_execution_id,
      # Which consent rooted this run. The root's admission resolves the
      # profile before anything executes and passes its id here, so the row
      # records the authority rather than leaving it to be re-derived.
      profile_id: Keyword.get(opts, :profile_id),
      attempt: Arca.ExecutionAttempts.generate_id(),
      kind: Keyword.get(opts, :kind, "component"),
      turn_id: Keyword.get(opts, :turn_id),
      schedule_id: Keyword.get(opts, :schedule_id),
      reservation: Keyword.get(opts, :reservation),
      sources: if(is_nil(parent_execution_id), do: root_seed(ctx, opts), else: []),
      launch_classes: if(is_nil(parent_execution_id), do: launch_classes(opts), else: [])
    }
  end

  defp root_seed(%Context{} = ctx, opts) do
    case Keyword.get(opts, :launch) do
      %{sources: sources} when is_list(sources) ->
        Prima.Source.set(sources)

      _no_launch ->
        cond do
          ctx.origin == :webhook -> [Prima.Source.outside("webhook")]
          is_list(Keyword.get(opts, :frame_sources)) -> Keyword.fetch!(opts, :frame_sources)
          true -> []
        end
    end
  end

  defp launch_classes(opts) do
    case Keyword.get(opts, :launch) do
      %{classes: classes} when is_list(classes) ->
        Enum.filter(Prima.Source.classes(), &(&1 in classes))

      _no_launch ->
        []
    end
  end

  @doc """
  The class a run's payloads are kept under when its admission names none
  (`Arca.Retention.Payloads` and its siblings): derived from the caller —
  `webhook` for a webhook identity, `system` for the server's own context,
  else `api`. A turn's own dispatches name `chat_step`.
  """
  @spec default_retention_class(Context.t()) :: String.t()
  def default_retention_class(%Context{} = ctx),
    do: Arca.Retention.default_class(Context.actor(ctx))

  @doc "Mark execution as completed with output."
  @spec complete(t(), map()) :: t()
  def complete(%__MODULE__{} = record, output) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    %{
      record
      | output: output,
        status: :completed,
        completed_at: now,
        duration_ms: duration_ms
    }
  end

  @doc "Mark execution as failed with error message."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = record, error) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    %{
      record
      | status: :failed,
        error: error,
        completed_at: now,
        duration_ms: duration_ms
    }
  end

  @doc """
  Cancel a running execution.

  Only running executions can be cancelled. Returns:
  - `{:ok, record}` - Successfully cancelled
  - `{:error, :not_found}` - Execution not found
  - `{:error, :not_cancellable}` - Execution already completed/failed/cancelled
  """
  @spec cancel(Context.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found | :not_cancellable | term()}
  def cancel(%Context{} = ctx, id) do
    case get(ctx, id) do
      {:ok, %{status: :running} = record} ->
        # `get/2` authorized the READ; cancelling is a mutation and takes the
        # :execute permission — every ingress funnels through here, so a
        # viewer credential cannot kill executions.
        case Context.authorize(ctx, :execute, {:execution, Map.from_struct(record)}) do
          :ok -> do_cancel(record)
          {:error, _} = error -> error
        end

      {:ok, _record} ->
        {:error, :not_cancellable}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp do_cancel(record) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    cancelled_record = %{
      record
      | status: :cancelled,
        completed_at: now,
        duration_ms: duration_ms
    }

    case write_failed(cancelled_record) do
      :ok ->
        {:ok, cancelled_record}

      {:error, :not_running} ->
        # The run finished between the `:running` read above and this write
        # — the row's conditional guard refused the stamp, so the completed
        # result stands and nothing gets killed.
        {:error, :not_cancellable}

      error ->
        error
    end
  end

  # ============================================================================
  # Storage API (delegates to Arca.Execution)
  # ============================================================================

  @doc """
  Admit the execution BEFORE it begins, in `ctx`, the context it was
  admitted in: the row, its first attempt and, for a root carrying a
  reservation, its budget row, in one transaction
  (`Arca.Execution.admit/2`). A root's row records `ctx`'s origin
  (`Prima.Origin`), which the admission entry that built `ctx` set; a
  child's row takes its parent's.

  `opts` carry what the admission settled: `:grant`, the
  `Prima.ExecutionGrant` the run is admitted under (when absent, a root's
  athanor standing read now, `Sanctum.ExecutionStanding.capture/1`, or the
  stamp its parent's current attempt stores, which a child inherits
  unchanged); `:retention_class`, the class its payloads are kept under
  (`default_retention_class/1` of `ctx` when absent); and
  `:retained_input`, the map kept as the input payload in place of the
  input, when the sent input carries transient content (the row's hash
  and envelope still describe the input). They also carry the admission
  barriers a child
  passes through (`:charge`, `:step`, and `:parent_attempt`, the attempt of
  its parent it is admitted under), a scheduled run's `:occurrence_id`, and
  the worker side holding the attempt: `:service_id`, the worker service it
  is dispatched to (absent when this control plane holds it), and
  `:boot_id`, the boot holding it (`boot_id/0` when absent).

  The row keeps an input envelope — the reference, digest, sizes,
  top-level keys and attachment digests — and the input itself is the
  payload store's, staged first and committed by the admission
  transaction under the retention class — the retained form when there
  is one, else the input as sent: an input that cannot be kept is
  `{:error, {:payload_not_retained, reason}}` and nothing is admitted.

  The row is admitted under the grant, checked in the admission
  transaction (`Sanctum.ExecutionStanding.verify/1`): a grant that does
  not stand admits nothing and is refused `{:error, :not_standing}`, a
  barrier's refusal (`Arca.Execution.barrier_refusal?/1`).
  """
  @spec write_started(Context.t(), t(), keyword()) :: :ok | {:error, term()}
  def write_started(%Context{} = admitted_ctx, %__MODULE__{} = record, opts \\ []) do
    ctx = record_to_ctx(record)

    class =
      Keyword.get_lazy(opts, :retention_class, fn -> default_retention_class(admitted_ctx) end)

    input = Keyword.get(opts, :retained_input) || record.input || %{}
    origin = if is_nil(record.parent_execution_id), do: admitted_ctx.origin

    with {:ok, grant} <- admission_grant(record, opts),
         {:ok, staged} <- stage_input(ctx, record, input, class) do
      case admit(record, origin, grant, opts, [staged]) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = Arca.ExecutionPayloads.discard(staged)
          {:error, reason}
      end
    end
  end

  defp stage_input(ctx, record, input, class) do
    case stage(ctx, record, "input", encode_json(input), class) do
      {:ok, staged} -> {:ok, staged}
      {:error, reason} -> {:error, {:payload_not_retained, reason}}
    end
  end

  # The grant `record` is admitted under: the one admission settled, else a
  # root's athanor standing read now or the stamp its parent's current
  # attempt stores. `{:error, :not_standing}` when neither stands,
  # `{:error, :unavailable}` when the store cannot answer.
  defp admission_grant(record, opts) do
    case Keyword.get(opts, :grant) do
      %Prima.ExecutionGrant{} = grant -> {:ok, grant}
      nil -> stored_or_captured_grant(record)
    end
  end

  defp stored_or_captured_grant(%__MODULE__{parent_execution_id: nil} = record),
    do: Sanctum.ExecutionStanding.capture(record_to_ctx(record))

  defp stored_or_captured_grant(%__MODULE__{athanor_id: athanor_id, parent_execution_id: parent}),
    do: inherited_grant(athanor_id, parent)

  @doc """
  The grant a child of `parent_execution_id` in `athanor_id` inherits: the
  stamp its parent's current attempt stores, unchanged.
  `{:error, :not_standing}` when the parent has none, `{:error,
  :unavailable}` when the store cannot answer.
  """
  @spec inherited_grant(String.t() | nil, String.t()) ::
          {:ok, Prima.ExecutionGrant.t()} | {:error, :not_standing | :unavailable}
  def inherited_grant(athanor_id, parent_execution_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(parent_execution_id) do
    case Arca.ExecutionAttempts.grant(Prima.Actor.in_athanor(athanor_id), parent_execution_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, :database_error} -> {:error, :unavailable}
      {:error, _none} -> {:error, :not_standing}
    end
  end

  def inherited_grant(_athanor_id, _parent_execution_id), do: {:error, :not_standing}

  @doc """
  Whether any run of the tree rooted at `execution_id` was admitted with
  egress, as each admission marked the root (`Arca.Execution.reached_outside/2`):
  what a launcher reads from the run's completion result. `nil` when the
  root cannot be read, which a reader takes as outside.
  """
  @spec reached_outside(Context.t(), String.t()) :: boolean() | nil
  def reached_outside(%Context{} = ctx, execution_id) when is_binary(execution_id) do
    case Arca.Execution.reached_outside(Sanctum.Context.actor(ctx), execution_id) do
      {:ok, reached} -> reached
      {:error, _unreadable} -> nil
    end
  end

  def reached_outside(%Context{}, _execution_id), do: nil

  # A run's own admitted egress: the domains its edge allows.
  defp reaches_outside?(%{allowed_domains: [_ | _]}), do: true
  defp reaches_outside?(_policy), do: false

  # The root's policy with the classes its approved launch let flow, read
  # for every send of its tree (`Arca.Execution.flow_state/2`).
  defp launch_policy(%__MODULE__{launch_classes: []} = record), do: record.host_policy

  defp launch_policy(%__MODULE__{host_policy: policy, launch_classes: classes}) do
    (policy || %{})
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put(Arca.Execution.launch_key(), Enum.map(classes, &Atom.to_string/1))
  end

  defp admit(%__MODULE__{} = record, origin, grant, opts, payloads) do
    case Arca.Execution.admit(
           %{
             id: record.id,
             request_id: record.request_id,
             call_id: record.call_id,
             reference: record.reference,
             input_hash: Arca.Execution.hash_input(record.input),
             user_id: record.user_id,
             athanor_id: record.athanor_id,
             component_type: to_string(record.component_type),
             component_digest: record.component_digest,
             started_at: record.started_at,
             status: "running",
             input: encode_json(input_envelope(record)),
             host_policy: encode_json(launch_policy(record)),
             parent_execution_id: record.parent_execution_id,
             child_key: record.child_key,
             root_execution_id: record.root_execution_id,
             resolver_digest: record.resolver_digest,
             activation_digest: record.activation_digest,
             activation_graph: record.activation_graph,
             profile_id: record.profile_id,
             kind: record.kind,
             turn_id: record.turn_id,
             schedule_id: record.schedule_id,
             origin: origin,
             sources: record.sources
           },
           Keyword.merge(
             [
               attempt: record.attempt,
               boot_id: boot_id(),
               reservation: record.reservation,
               payloads: payloads,
               grant: grant,
               verify: &Sanctum.ExecutionStanding.verify/1,
               # A run admitted with egress marks its tree's root in this
               # transaction, where retention cannot reach it first.
               reaches_outside: reaches_outside?(record.host_policy)
             ],
             Keyword.take(opts, [
               :charge,
               :step,
               :parent_attempt,
               :occurrence_id,
               :service_id,
               :boot_id
             ])
           )
         ) do
      {:ok, %{execution: execution}} ->
        publish(record, "execution.started", execution.event_seq, %{
          "attempt" => record.attempt,
          "reference" => record.reference
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The lifecycle row committed; its subscribers hear of it now, in the
  # order the rows were numbered.
  defp publish(%__MODULE__{} = record, type, seq, data) when is_integer(seq) do
    _ = Opus.Events.publish(record.id, record, type, seq, data)
    :ok
  end

  defp publish(_record, _type, _seq, _data), do: :ok

  defp stage(ctx, %__MODULE__{} = record, kind, bytes, class),
    do: Arca.ExecutionPayloads.stage(Sanctum.Context.actor(ctx), record.id, kind, bytes, class)

  @doc """
  This boot's id: the `boot_id` of an attempt this control plane holds
  itself (a turn root's) and of a row admitted with no `:boot_id`. Each
  restart has a different id.
  """
  @spec boot_id() :: String.t()
  def boot_id, do: Prima.Boot.id()

  @doc "A fresh lease expiry from now."
  def lease_until, do: Arca.ExecutionAttempts.lease_until()

  @doc """
  Renew the lease this attempt holds on its running execution.

  `{:ok, until}` is the new expiry the attempt now carries. `:lost` means
  the store answered and the attempt no longer owns its execution — it
  finished, was cancelled, paused, lapsed, or a successor took the row —
  or its grant no longer stands (its athanor was archived), and the runner
  stops authorized work at once. `:unavailable` means the store could not
  answer; the runner keeps working only while the lease it last held
  still holds.
  """
  @spec renew_lease(String.t(), String.t()) :: {:ok, DateTime.t()} | :lost | :unavailable
  def renew_lease(execution_id, attempt) when is_binary(execution_id) and is_binary(attempt) do
    Arca.ExecutionAttempts.renew(attempt, lease_until(),
      grant: :stored,
      verify: &Sanctum.ExecutionStanding.verify/1
    )
  rescue
    e ->
      Logger.warning(
        "[Opus.Record] lease renewal failed for #{execution_id}: #{Prima.LogFilter.exception_message(e)}"
      )

      :unavailable
  end

  @doc """
  Close the row as completed, answering `{:ok, ledger}`: the run's source
  ledger as the terminal transaction itself read it
  (`Arca.Execution.row_ledger/1`), the first carrier of its provenance to
  whoever it answers — never a read after the write, which retention may
  race. The row keeps an envelope of the output (`persisted_output/1`);
  the output itself is staged as the result payload and committed by the
  same transaction that closes the attempt. A result that cannot be kept
  closes the attempt `result_lost` and the row failed — durably, so
  nothing retries an effect that already happened — and answers
  `{:error, {:result_lost, reason}}`.

  `opts`: `:retention_class`, the class the run's input was staged under
  (`write_started/3`), required; and `:grant`, the grant the run was
  admitted under (the attempt's stored stamp when absent). A completion
  commits only under a grant that stands
  (`Sanctum.ExecutionStanding.verify/1`). One whose athanor was archived
  while the run was in flight is never recorded as a success: its attempt
  closes `uncertain` and the row failed, since what the run did may
  already have happened, and the answer is `{:error, :not_standing}`.
  """
  @spec write_completed_ledger(t(), keyword()) :: {:ok, [Prima.Source.t()]} | {:error, term()}
  def write_completed_ledger(record, opts)

  def write_completed_ledger(%__MODULE__{status: :completed} = record, opts) do
    ctx = record_to_ctx(record)
    grant = written_grant(opts)

    close = %{
      completed_at: record.completed_at,
      duration_ms: record.duration_ms,
      output: encode_json(persisted_output(record))
    }

    case stage_result(ctx, record, Keyword.fetch!(opts, :retention_class)) do
      {:ok, staged} ->
        case Arca.Execution.record_end(
               Sanctum.Context.actor(ctx),
               record.id,
               "completed",
               Map.put(close, :payloads, List.wrap(staged)),
               record.attempt,
               grant: grant,
               verify: &Sanctum.ExecutionStanding.verify/1
             ) do
          {:ok, execution} ->
            :ok =
              publish(record, "execution.completed", execution.event_seq, %{
                "status" => "completed",
                "duration_ms" => record.duration_ms
              })

            {:ok, Arca.Execution.row_ledger(execution)}

          {:error, :not_standing} ->
            if staged, do: Arca.ExecutionPayloads.discard(staged)
            retired(ctx, record, grant)

          {:error, {:payload_not_retained, reason}} ->
            if staged, do: Arca.ExecutionPayloads.discard(staged)
            result_lost(ctx, record, grant, reason)

          {:error, reason} ->
            if staged, do: Arca.ExecutionPayloads.discard(staged)
            {:error, reason}
        end

      {:error, reason} ->
        result_lost(ctx, record, grant, reason)
    end
  end

  def write_completed_ledger(%__MODULE__{status: status}, _opts) do
    {:error, "Cannot write completed record for status: #{status}"}
  end

  # The grant a terminal write is fenced on: the one the run was admitted
  # under, else the attempt's stored stamp.
  defp written_grant(opts), do: Keyword.get(opts, :grant, :stored)

  defp stage_result(_ctx, %__MODULE__{output: nil}, _class), do: {:ok, nil}

  defp stage_result(ctx, %__MODULE__{} = record, class),
    do: stage(ctx, record, "result", encode_json(record.output), class)

  # The grant retired while the run was in flight: the run may have acted,
  # so the attempt closes `uncertain`, never `ok`, and the output is
  # neither kept nor published.
  defp retired(ctx, %__MODULE__{} = record, grant) do
    message = "the execution's athanor is no longer active"

    case Arca.Execution.record_end(
           Sanctum.Context.actor(ctx),
           record.id,
           "failed",
           %{
             completed_at: record.completed_at,
             duration_ms: record.duration_ms,
             error_message: message,
             outcome: "uncertain"
           },
           record.attempt,
           grant: grant,
           verify: &Sanctum.ExecutionStanding.stamp_only/1
         ) do
      {:ok, execution} ->
        publish(record, "execution.failed", execution.event_seq, %{
          "status" => "failed",
          "error" => message,
          "duration_ms" => record.duration_ms
        })

      _ ->
        :ok
    end

    {:error, :not_standing}
  end

  defp result_lost(ctx, %__MODULE__{} = record, grant, reason) do
    Logger.error(
      "[Opus.Record] result of #{record.id} not retained: #{inspect(reason)}; " <>
        "the attempt closes result_lost"
    )

    case Arca.Execution.record_end(
           Sanctum.Context.actor(ctx),
           record.id,
           "failed",
           %{
             completed_at: record.completed_at,
             duration_ms: record.duration_ms,
             error_message: "result not retained",
             outcome: "result_lost"
           },
           record.attempt,
           grant: grant,
           verify: &Sanctum.ExecutionStanding.stamp_only/1
         ) do
      {:ok, execution} ->
        publish(record, "execution.result_lost", execution.event_seq, %{
          "status" => "failed",
          "error" => "result not retained",
          "duration_ms" => record.duration_ms
        })

      _ ->
        :ok
    end

    {:error, {:result_lost, reason}}
  end

  @doc """
  Close the row as failed or cancelled, and publish the lifecycle event.
  A failure and a cancel retire work, so they need the attempt's stamp and
  not a grant that still stands (`Sanctum.ExecutionStanding.stamp_only/1`):
  `opts[:grant]`, the grant the run was admitted under, else the
  attempt's stored stamp.
  """
  @spec write_failed(t(), keyword()) :: :ok | {:error, term()}
  def write_failed(record, opts \\ [])

  def write_failed(%__MODULE__{status: status} = record, opts)
      when status in [:failed, :cancelled],
      do: write_ended(record, nil, written_grant(opts))

  def write_failed(%__MODULE__{status: status}, _opts) do
    {:error, "Cannot write failed record for status: #{status}"}
  end

  @doc """
  `write_failed/2` for a run its attempt stopped holding before it closed
  the run: the attempt closes with outcome `uncertain`, since what the
  run did before it ended is not known, and the row fails as
  `write_failed/2` fails it. `record` is one `fail/2` made.
  """
  @spec write_uncertain(t(), keyword()) :: :ok | {:error, term()}
  def write_uncertain(%__MODULE__{status: :failed} = record, opts \\ []),
    do: write_ended(record, "uncertain", written_grant(opts))

  defp write_ended(%__MODULE__{status: status} = record, outcome, grant) do
    ctx = record_to_ctx(record)

    case Arca.Execution.record_end(
           Sanctum.Context.actor(ctx),
           record.id,
           Atom.to_string(status),
           Prima.MapUtil.put_present(
             %{
               completed_at: record.completed_at,
               duration_ms: record.duration_ms,
               error_message: record.error
             },
             :outcome,
             outcome
           ),
           record.attempt,
           grant: grant,
           verify: &Sanctum.ExecutionStanding.stamp_only/1
         ) do
      {:ok, execution} ->
        data =
          %{"status" => Atom.to_string(status), "error" => record.error}
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        publish(record, "execution." <> Atom.to_string(status), execution.event_seq, data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The outcome the attempt that owns the row `record` was reread as
  (`reread/1`) closed with — `"ok"`, `"error"`, `"uncertain"`,
  `"result_lost"` or `"cancelled"` — read in the record's own athanor.
  `{:error, :not_found}` for a record with no attempt or an attempt not
  yet closed, `{:error, reason}` when the store cannot answer.
  """
  @spec ended_outcome(t()) :: {:ok, String.t()} | {:error, term()}
  def ended_outcome(%__MODULE__{attempt: attempt} = record) when is_binary(attempt) do
    case Arca.ExecutionAttempts.get(Sanctum.Context.actor(record_to_ctx(record)), attempt) do
      %{outcome: outcome} when is_binary(outcome) -> {:ok, outcome}
      {:error, _} = error -> error
      _open_or_missing -> {:error, :not_found}
    end
  end

  def ended_outcome(%__MODULE__{}), do: {:error, :not_found}

  @doc """
  Load an execution record by ID.
  """
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, id) do
    case Arca.Execution.get_tenant(Sanctum.Context.actor(ctx), id) do
      nil ->
        {:error, :not_found}

      # get_tenant is db-rescued and answers a tuple on an outage. Bound as
      # the row it reaches execution_to_map/1, whose `is_map`
      # guard raises — an outage read as a crash. Passed through, the
      # caller sees the storage refusal its siblings already answer.
      {:error, _} = err ->
        err

      record ->
        result = execution_to_map(record)

        with :ok <- read_authorized(ctx, result),
             {:ok, record} <- from_row(result) do
          {:ok, hydrate_output(ctx, record)}
        end
    end
  end

  @doc """
  The row `record` was admitted as, as it stands now: read in the record's
  own athanor with a host-side context, whatever plane the run was
  admitted on. The context a run was admitted with is never widened for
  it.
  """
  @spec reread(t()) :: {:ok, t()} | {:error, term()}
  def reread(%__MODULE__{} = record) do
    ctx =
      Sanctum.internal_context(
        user_id: record.user_id,
        athanor_id: record.athanor_id,
        permissions: [:storage_read],
        scope: :athanor
      )

    get(ctx, record.id)
  end

  @doc """
  List execution records for the context's athanor.

  Members of an athanor are interchangeable, so this returns the athanor's
  executions, not just the caller's own.

  Options:
  - `:limit` - Maximum number of records (default: 20)
  - `:status` - Filter by status (:running, :completed, :failed, :all)
  """
  @spec list(Context.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(%Context{} = ctx, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    status_filter = Keyword.get(opts, :status, :all)

    opts = [limit: limit]

    opts =
      if status_filter != :all,
        do: Keyword.put(opts, :status, to_string(status_filter)),
        else: opts

    # `Arca.Execution.list/2` runs under `with_db_rescue`, so an outage
    # comes back as a refusal rather than rows, and the refusal travels:
    # every caller's error branch (`Opus.ArchiveWatch` among them) is
    # written for it.
    case Arca.Execution.list(Context.actor(ctx), opts) do
      {:error, reason} ->
        {:error, reason}

      records ->
        Enum.reduce_while(records, {:ok, []}, fn row, {:ok, acc} ->
          case from_row(execution_to_map(row)) do
            {:ok, record} -> {:cont, {:ok, [record | acc]}}
            {:error, _} = damaged -> {:halt, damaged}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          damaged -> damaged
        end
    end
  end

  defp read_authorized(ctx, result) do
    case Context.authorize(ctx, :storage_read, {:execution, result}) do
      :ok -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end

  # ===========================================================================
  # Private - Struct Conversion
  # ===========================================================================

  # A row's stored status and type are closed sets (the status CHECK, and
  # the types its writers stamp), and its input, output and host policy
  # are JSON or SQL NULL; a row holding anything else is damaged, refused
  # `{:corrupt, {:execution, id}}` rather than read as something it is not.
  @spec from_row(map()) :: {:ok, t()} | {:error, {:corrupt, {:execution, String.t()}}}
  defp from_row(result) when is_map(result) do
    with {:ok, status} <- parse_status(result.status),
         {:ok, component_type} <- parse_component_type(result.component_type),
         {:ok, input} <- stored_json(result, :input),
         {:ok, output} <- stored_json(result, :output),
         {:ok, host_policy} <- stored_json(result, :host_policy) do
      # An input the read does not select (a listing selects no payload
      # column) reads as empty.
      json = %{input: input || %{}, output: output, host_policy: host_policy}
      {:ok, record_of(result, status, component_type, json)}
    else
      :error ->
        Logger.error(
          "[Opus.Record] execution #{result.id} is stored damaged: status " <>
            "#{inspect(result.status)}, component type #{inspect(result.component_type)}"
        )

        {:error, {:corrupt, {:execution, result.id}}}

      {:not_json, column} ->
        Logger.error(
          "[Opus.Record] execution #{result.id} is stored damaged: its #{column} is not JSON"
        )

        {:error, {:corrupt, {:execution, result.id}}}
    end
  end

  defp record_of(result, status, component_type, json) do
    %__MODULE__{
      id: result.id,
      request_id: result.request_id,
      call_id: result[:call_id],
      user_id: result.user_id,
      athanor_id: result[:athanor_id],
      reference: result.reference,
      component_type: component_type,
      component_digest: result.component_digest,
      input: json.input,
      output: json.output,
      status: status,
      started_at: result.started_at,
      completed_at: result.completed_at,
      duration_ms: result.duration_ms,
      error: result.error_message,
      host_policy: json.host_policy,
      parent_execution_id: result[:parent_execution_id],
      child_key: result[:child_key],
      root_execution_id: result[:root_execution_id],
      resolver_digest: result[:resolver_digest],
      activation_digest: result[:activation_digest],
      # The canonically-encoded graph string, exactly as stamped — never
      # decoded and re-encoded, which could break its canonical form.
      activation_graph: result[:activation_graph],
      profile_id: result[:profile_id],
      attempt: result[:current_attempt],
      kind: result[:kind],
      turn_id: result[:turn_id],
      sources: Arca.Execution.row_ledger(result)
    }
  end

  # SQL NULL is a column its writer leaves empty (a running row's output,
  # the host policy of a run admitted with none) or one the read does not
  # select, and reads as nil; stored bytes that do not decode are damage.
  defp stored_json(result, column) do
    case Map.fetch!(result, column) do
      nil ->
        {:ok, nil}

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, value} -> {:ok, value}
          {:error, _not_json} -> {:not_json, column}
        end
    end
  end

  defp parse_status(status) when is_map_key(@status_atoms, status),
    do: {:ok, @status_atoms[status]}

  defp parse_status(_damaged), do: :error

  # ===========================================================================
  # Private
  # ===========================================================================

  @doc """
  Generate a unique execution ID.

  Uses `Prima.UUID7` for time-ordered execution identifiers.
  """
  @spec generate_id() :: String.t()
  def generate_id, do: Prima.UUID7.execution_id()

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value

  defp encode_json(value), do: Prima.Json.safe_encode(value)

  # What the row keeps of the input: enough to say what ran and to tell
  # two inputs apart, nothing of what they said.
  defp input_envelope(%__MODULE__{} = record) do
    input = record.input || %{}
    encoded = Jason.encode!(input)

    %{
      "envelope" => "v1",
      "reference" => record.reference,
      "input_hash" => Arca.Execution.hash_input(input),
      "bytes" => byte_size(encoded),
      "keys" => input |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }
    |> put_attachment_digests(input)
  end

  defp put_attachment_digests(envelope, %{"attachments" => attachments})
       when is_list(attachments) do
    digests =
      for %{} = attachment <- attachments do
        data = attachment["data"] || ""

        %{
          "filename" => attachment["filename"],
          "media_type" => attachment["media_type"],
          "bytes" => byte_size(data),
          "digest" => Prima.Digest.sha256(data)
        }
      end

    Map.put(envelope, "attachments", digests)
  end

  defp put_attachment_digests(envelope, _input), do: envelope

  # The row keeps an envelope of every output — its digest, its size and
  # the usage a planner reads — and the payload store keeps the bytes,
  # under the execution's retention class, for as long as retention does.
  defp persisted_output(%__MODULE__{output: nil}), do: nil

  defp persisted_output(%__MODULE__{output: output}) do
    encoded = encode_json(output)

    %{
      "envelope" => "v1",
      "output_hash" => Prima.Digest.sha256(encoded),
      "bytes" => byte_size(encoded),
      "usage" => usage_of(output)
    }
  end

  # A read joins the retained bytes back onto the envelope the row keeps;
  # once retention has swept them, the envelope alone answers.
  @spec hydrate_output(Context.t(), t()) :: t()
  defp hydrate_output(
         ctx,
         %__MODULE__{output: %{"envelope" => "v1", "output_hash" => _}} = record
       ) do
    with {:ok, _row, bytes} <-
           Arca.ExecutionPayloads.get(Sanctum.Context.actor(ctx), record.id, "result",
             attempt: record.attempt
           ),
         {:ok, output} <- Jason.decode(bytes) do
      %{record | output: output}
    else
      _ -> record
    end
  end

  defp hydrate_output(_ctx, record), do: record

  # Usage is what a `model/chat@1` answer carries in its data
  # (`{"status": 200, "data": {..., "usage": {...}}}`); no other output
  # has a usage of its own.
  defp usage_of(%{"status" => 200, "data" => %{"usage" => usage}}), do: usage
  defp usage_of(_output), do: nil

  # The row's shape has one owner: the storage row (`Arca.Execution.fields/0`).
  # The read map carries every column except the lease mechanics, which belong to the
  # write path and the sweeper alone — `write_started` stamps them fresh
  # and nothing read back through here may act on them. A new column
  # flows into the map on its own; only `from_row/1` (the parser layer)
  # needs a decision about it.
  @row_only_fields [:event_seq]

  defp execution_to_map(record) when is_map(record) do
    Map.new(Arca.Execution.fields() -- @row_only_fields, fn field ->
      {field, Map.get(record, field)}
    end)
  end

  @executable_types Map.new(Prima.ComponentRef.executable_types(), &{&1, String.to_atom(&1)})

  @doc """
  The executable component type a stored `component_type` column names, as
  its atom, or `:error` when it names none: an empty column, a turn root's
  `"agent"`, or a type this build does not execute.
  """
  @spec executable_type(term()) :: {:ok, component_type()} | :error
  def executable_type(type) when is_binary(type), do: Map.fetch(@executable_types, type)
  def executable_type(_type), do: :error

  # A turn root: the agent is a consent source, not an executable type.
  defp parse_component_type("agent"), do: {:ok, :agent}
  # An MCP tool call's row: the server it ran on (`Emissary.External.Proxy`).
  defp parse_component_type("tool_server"), do: {:ok, :tool_server}
  defp parse_component_type(type), do: executable_type(type)

  # Rebuild a minimal context from execution record fields for tenant-scoped writes.
  # namespace is identity-only and not path-bearing, so it is omitted — the
  # row lands in the correct partition via athanor_id.
  defp record_to_ctx(%__MODULE__{} = record) do
    # Server-built write-back, but tenant-scoped to the originating athanor
    # (scope: :athanor + the record's athanor) so the row lands in the
    # correct partition. Routed through the single server-internal builder
    # (auth_method: :system).
    Sanctum.internal_context(
      user_id: record.user_id,
      athanor_id: record.athanor_id,
      permissions: [],
      scope: :athanor
    )
  end
end
