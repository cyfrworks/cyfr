# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Record do
  @moduledoc """
  Struct and storage for execution records.

  Execution records capture the complete state of a component execution
  for auditing, debugging, and forensic replay purposes.

  ## Storage

  Records are stored in SQLite via `Arca.Execution` to the `executions` table.
  The crash-resilient
  pattern writes a "started" record BEFORE execution begins, and updates it with
  completion/failure data AFTER execution finishes.

  If an execution record exists with status "running" but no completion,
  the execution crashed or was interrupted.

  ## Usage

      # Create and write started record BEFORE execution
      record = Record.new(ctx, reference, input)
      :ok = Record.write_started(record)

      # Execute...

      # On success: write completion
      record = Record.complete(record, output)
      :ok = Record.write_completed(record)

      # On failure: write failure
      record = Record.fail(record, error)
      :ok = Record.write_failed(record)

  ## Correlation IDs

  All IDs use UUID v7 (RFC 9562) format for time-ordering:
  - `execution_id`: `exec_<uuid7>` - Generated for each execution
  - `request_id`: `req_<uuid7>` - From the MCP request context (if available)
  """

  require Logger

  alias Sanctum.Context

  @typedoc """
  A decoded JSON value. The `input`, `output` and `host_policy` columns hold
  whatever the execution produced, and a component's result is not required
  to be an object.
  """
  @type json :: map() | list() | String.t() | number() | boolean() | nil

  @typedoc "The executable component types (`Cyfr.ComponentRef.executable_types/0`)."
  @type component_type :: :catalyst | :reagent | :formula

  @type t :: %__MODULE__{
          id: String.t(),
          request_id: String.t() | nil,
          user_id: String.t(),
          athanor_id: String.t() | nil,
          reference: String.t() | nil,
          resolved_from: String.t() | nil,
          component_type: component_type() | :agent,
          component_digest: String.t() | nil,
          input: json(),
          output: json(),
          status: :running | :paused | :completed | :failed | :cancelled | :unknown,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: non_neg_integer() | nil,
          error: String.t() | nil,
          host_policy: json(),
          parent_execution_id: String.t() | nil,
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
          retention_class: String.t() | nil,
          retained_input: map() | nil
        }

  defstruct [
    :id,
    :request_id,
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
    :root_execution_id,
    :resolver_digest,
    :activation_digest,
    :activation_graph,
    :profile_id,
    # The attempt that owns the row (`Arca.ExecutionAttempts`): minted with
    # the record, opened at admission, named by every later write.
    :attempt,
    # What the row is (`component | turn | tool_call`) and the turn it
    # belongs to; a turn root is admitted by `Cyfr.Execution.TurnRoot`.
    :kind,
    :turn_id,
    # The schedule this root runs for (`Cyfr.Schedules`); nil otherwise.
    :schedule_id,
    # A root's invocation reservation, `%{budget_id, cap}`, minted at
    # admission; nil for a child.
    :reservation,
    # The class the execution's retained payloads are swept under
    # (`Cyfr.Retention.Payloads` and its siblings): `api`, `webhook`,
    # `schedule`, `system`, or `chat_step` for a turn's own dispatches.
    # Not a column — the payload rows carry it.
    :retention_class,
    :retained_input
  ]

  @doc """
  Create a new execution record when starting execution.

  Options:
  - `:component_type` - The component type (:catalyst, :reagent, :formula). Defaults to :reagent.
  - `:component_digest` - The SHA256 digest of the WASM component.
  - `:host_policy` - Snapshot of the host policy applied to this execution.
  - `:parent_execution_id` - Parent formula execution ID for sub-invocations.
  - `:root_execution_id` - The chain's root execution ID. A root stamps
    itself, so every row in a chain carries the same value.
  - `:retained_input` - The map kept as the input payload in place of
    `input`, when the sent input carries transient content; the row's
    hash and envelope still describe `input`
  - `:retention_class` - The class the execution's payloads are kept
    under; derived from the caller when absent (`webhook` for a webhook
    identity, `system` for the server's own context, else `api`).
  """
  @spec new(Context.t(), String.t(), map(), keyword()) :: t()
  def new(%Context{} = ctx, reference, input, opts \\ []) do
    component_type = Keyword.get(opts, :component_type, :reagent)
    component_digest = Keyword.get(opts, :component_digest)
    host_policy = Keyword.get(opts, :host_policy)
    parent_execution_id = Keyword.get(opts, :parent_execution_id)
    id = Keyword.get(opts, :execution_id) || generate_id()
    # A root execution is its own root: one comparison answers "is this
    # row in my chain" without walking parents.
    root_execution_id = Keyword.get(opts, :root_execution_id) || id

    %__MODULE__{
      id: id,
      request_id: ctx.request_id,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      reference: reference,
      component_type: component_type,
      component_digest: component_digest,
      input: input,
      output: nil,
      status: :running,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      duration_ms: nil,
      error: nil,
      host_policy: host_policy,
      parent_execution_id: parent_execution_id,
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
      retention_class: Keyword.get(opts, :retention_class) || default_retention_class(ctx),
      retained_input: Keyword.get(opts, :retained_input)
    }
  end

  defp default_retention_class(%Context{} = ctx), do: Cyfr.Retention.default_class(ctx)

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
  Cancel a running execution. `opts[:restart_required]` — a consent
  payload — rides the `execution.cancelled` event, so a surface can say
  "approved — re-run to continue" instead of "cancelled".

  Only running executions can be cancelled. Returns:
  - `{:ok, record}` - Successfully cancelled
  - `{:error, :not_found}` - Execution not found
  - `{:error, :not_cancellable}` - Execution already completed/failed/cancelled
  """
  @spec cancel(Context.t(), String.t()) ::
          {:ok, t()} | {:error, :not_found | :not_cancellable | term()}
  def cancel(ctx, id, opts \\ [])

  def cancel(%Context{} = ctx, id, opts) do
    case get(ctx, id) do
      {:ok, %{status: :running} = record} ->
        # `get/2` authorized the READ; cancelling is a mutation and takes the
        # :execute permission — every ingress funnels through here, so a
        # viewer credential cannot kill executions.
        case Context.authorize(ctx, :execute, {:execution, Map.from_struct(record)}) do
          :ok -> do_cancel(record, cancel_data(opts))
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

  defp cancel_data(opts) do
    case Keyword.get(opts, :restart_required) do
      payload when is_map(payload) -> %{"restart_required" => payload}
      _ -> %{}
    end
  end

  defp do_cancel(record, event_data) do
    now = DateTime.utc_now()
    duration_ms = DateTime.diff(now, record.started_at, :millisecond)

    cancelled_record = %{
      record
      | status: :cancelled,
        completed_at: now,
        duration_ms: duration_ms
    }

    case write_failed(cancelled_record, event_data) do
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
  Admit the execution BEFORE it begins: the row, its first attempt and,
  for a root carrying a reservation, its budget row, in one transaction
  (`Arca.Execution.admit/2`). `opts` carry the admission barriers a child
  passes through (`:charge`, `:step`, and `:parent_attempt`, the attempt of
  its parent it is admitted under), a scheduled run's `:occurrence_id`, and
  the worker side holding the attempt: `:service_id`, the worker service it
  is dispatched to (absent when this control plane holds it), and
  `:boot_id`, the boot holding it (`boot_id/0` when absent).

  The row keeps an input envelope — the reference, digest, sizes,
  top-level keys and attachment digests — and the input itself is the
  payload store's, staged first and committed by the admission
  transaction under the record's retention class — the retained form
  when the record carries one, else the input as sent: an input that
  cannot be kept is `{:error, {:payload_not_retained, reason}}` and
  nothing is admitted.
  """
  @spec write_started(t(), keyword()) :: :ok | {:error, term()}
  def write_started(%__MODULE__{} = record, opts \\ []) do
    ctx = record_to_ctx(record)

    case stage(ctx, record, "input", encode_json(record.retained_input || record.input || %{})) do
      {:ok, staged} ->
        case admit(record, opts, [staged]) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = Arca.ExecutionPayloads.discard(staged)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:payload_not_retained, reason}}
    end
  end

  defp admit(%__MODULE__{} = record, opts, payloads) do
    case Arca.Execution.admit(
           %{
             id: record.id,
             request_id: record.request_id,
             reference: encode_reference(record.reference),
             input_hash: Arca.Execution.hash_input(record.input),
             user_id: record.user_id,
             athanor_id: record.athanor_id,
             component_type: to_string(record.component_type),
             component_digest: record.component_digest,
             started_at: record.started_at,
             status: "running",
             input: encode_json(input_envelope(record)),
             host_policy: encode_json(record.host_policy),
             parent_execution_id: record.parent_execution_id,
             root_execution_id: record.root_execution_id,
             resolver_digest: record.resolver_digest,
             activation_digest: record.activation_digest,
             activation_graph: record.activation_graph,
             profile_id: record.profile_id,
             kind: record.kind || "component",
             turn_id: record.turn_id,
             schedule_id: record.schedule_id
           },
           Keyword.merge(
             [
               attempt: record.attempt,
               boot_id: boot_id(),
               reservation: record.reservation,
               payloads: payloads
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
          "reference" => encode_reference(record.reference)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The lifecycle row committed; its subscribers hear of it now, in the
  # order the rows were numbered.
  defp publish(%__MODULE__{} = record, type, seq, data) when is_integer(seq) do
    _ = Cyfr.Execution.Events.publish(record.id, record, type, seq, data)
    :ok
  end

  defp publish(_record, _type, _seq, _data), do: :ok

  defp stage(ctx, %__MODULE__{} = record, kind, bytes),
    do: Arca.ExecutionPayloads.stage(ctx, record.id, kind, bytes, record.retention_class)

  @doc "How long one lease renewal is good for."
  def lease_seconds, do: Arca.ExecutionAttempts.lease_seconds()

  @doc """
  This boot's id: the `boot_id` of an attempt this control plane holds
  itself (a turn root's) and of a row admitted with no `:boot_id`. Each
  restart has a different id.
  """
  @spec boot_id() :: String.t()
  def boot_id, do: Cyfr.Boot.id()

  @doc "A fresh lease expiry from now."
  def lease_until, do: Arca.ExecutionAttempts.lease_until()

  @doc """
  Renew the lease this attempt holds on its running execution.

  `{:ok, until}` is the new expiry the attempt now carries. `:lost` means
  the store answered and the attempt no longer owns its execution — it
  finished, was cancelled, paused, lapsed, or a successor took the row —
  and the runner stops authorized work at once. `:unavailable` means the
  store could not answer; the runner keeps working only while the lease it
  last held still holds.
  """
  @spec renew_lease(String.t(), String.t() | nil) ::
          {:ok, DateTime.t()} | :lost | :unavailable
  def renew_lease(_execution_id, nil), do: :lost

  def renew_lease(execution_id, attempt) when is_binary(execution_id) and is_binary(attempt) do
    Arca.ExecutionAttempts.renew(attempt, lease_until())
  rescue
    e ->
      Logger.warning(
        "[Cyfr.Execution.Record] lease renewal failed for #{execution_id}: #{Exception.message(e)}"
      )

      :unavailable
  end

  @doc """
  Close the row as completed. The row keeps an envelope of the output
  (`persisted_output/1`); the output itself is staged as the result
  payload and committed by the same transaction that closes the attempt.
  A result that cannot be kept closes the attempt `result_lost` and the
  row failed — durably, so nothing retries an effect that already
  happened — and answers `{:error, {:result_lost, reason}}`.
  """
  @spec write_completed(t()) :: :ok | {:error, term()}
  def write_completed(%__MODULE__{status: :completed} = record) do
    ctx = record_to_ctx(record)

    close = %{
      completed_at: record.completed_at,
      duration_ms: record.duration_ms,
      output: encode_json(persisted_output(record))
    }

    case stage_result(ctx, record) do
      {:ok, staged} ->
        case Arca.Execution.record_end(
               ctx,
               record.id,
               "completed",
               Map.put(close, :payloads, List.wrap(staged)),
               record.attempt
             ) do
          {:ok, execution} ->
            publish(record, "execution.completed", execution.event_seq, %{
              "status" => "completed",
              "duration_ms" => record.duration_ms
            })

          {:error, {:payload_not_retained, reason}} ->
            if staged, do: Arca.ExecutionPayloads.discard(staged)
            result_lost(ctx, record, reason)

          {:error, reason} ->
            if staged, do: Arca.ExecutionPayloads.discard(staged)
            {:error, reason}
        end

      {:error, reason} ->
        result_lost(ctx, record, reason)
    end
  end

  def write_completed(%__MODULE__{status: status}) do
    {:error, "Cannot write completed record for status: #{status}"}
  end

  defp stage_result(_ctx, %__MODULE__{output: nil}), do: {:ok, nil}

  defp stage_result(ctx, %__MODULE__{} = record),
    do: stage(ctx, record, "result", encode_json(record.output))

  defp result_lost(ctx, %__MODULE__{} = record, reason) do
    Logger.error(
      "[Cyfr.Execution.Record] result of #{record.id} not retained: #{inspect(reason)}; " <>
        "the attempt closes result_lost"
    )

    case Arca.Execution.record_end(
           ctx,
           record.id,
           "failed",
           %{
             completed_at: record.completed_at,
             duration_ms: record.duration_ms,
             error_message: "result not retained",
             outcome: "result_lost"
           },
           record.attempt
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
  Close the row as failed or cancelled, and publish the lifecycle event
  with `event_data` merged into what it carries (a cancel that asks for
  a restart says so there).
  """
  @spec write_failed(t(), map()) :: :ok | {:error, term()}
  def write_failed(record, event_data \\ %{})

  def write_failed(%__MODULE__{status: status} = record, event_data)
      when status in [:failed, :cancelled] and is_map(event_data) do
    ctx = record_to_ctx(record)

    case Arca.Execution.record_end(
           ctx,
           record.id,
           Atom.to_string(status),
           %{
             completed_at: record.completed_at,
             duration_ms: record.duration_ms,
             error_message: record.error,
             event: event_data
           },
           record.attempt
         ) do
      {:ok, execution} ->
        data =
          %{"status" => Atom.to_string(status), "error" => record.error}
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.merge(event_data)

        publish(record, "execution." <> Atom.to_string(status), execution.event_seq, data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def write_failed(%__MODULE__{status: status}, _event_data) do
    {:error, "Cannot write failed record for status: #{status}"}
  end

  @doc """
  Load an execution record by ID.
  """
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, id) do
    case Arca.Execution.get_tenant(ctx, id) do
      nil ->
        {:error, :not_found}

      # get_tenant is db-rescued and answers a tuple on an outage. Bound as
      # the row it reaches execution_to_map/1, whose `is_struct or is_map`
      # guard raises — an outage read as a crash. Passed through, the
      # caller sees the storage refusal its siblings already answer.
      {:error, _} = err ->
        err

      record ->
        result = execution_to_map(record)

        case Context.authorize(ctx, :storage_read, {:execution, result}) do
          :ok -> {:ok, hydrate_output(ctx, from_mcp_result(result))}
          {:error, _} -> {:error, :not_found}
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

    opts = [
      limit: limit,
      athanor_id: ctx.athanor_id
    ]

    opts =
      if status_filter != :all,
        do: Keyword.put(opts, :status, to_string(status_filter)),
        else: opts

    records = Arca.Execution.list(opts)
    {:ok, Enum.map(records, fn r -> from_mcp_result(execution_to_map(r)) end)}
  end

  # ===========================================================================
  # Private - Struct Conversion
  # ===========================================================================

  @spec from_mcp_result(map()) :: t()
  defp from_mcp_result(result) when is_map(result) do
    %__MODULE__{
      id: result.id,
      request_id: result.request_id,
      user_id: result.user_id,
      athanor_id: result[:athanor_id],
      reference: parse_reference(result.reference),
      component_type: parse_component_type(result.component_type),
      component_digest: result.component_digest,
      input: parse_json_or_nil(result.input) || %{},
      output: parse_json_or_nil(result.output),
      status: parse_status(result.status),
      started_at: parse_datetime_value(result.started_at),
      completed_at: parse_datetime_value(result.completed_at),
      duration_ms: result.duration_ms,
      error: result.error_message,
      host_policy: parse_json_or_nil(result.host_policy),
      parent_execution_id: result[:parent_execution_id],
      root_execution_id: result[:root_execution_id],
      resolver_digest: result[:resolver_digest],
      activation_digest: result[:activation_digest],
      # The canonically-encoded graph string, exactly as stamped — never
      # decoded and re-encoded, which could break its canonical form.
      activation_graph: result[:activation_graph],
      profile_id: result[:profile_id],
      attempt: result[:current_attempt],
      kind: result[:kind],
      turn_id: result[:turn_id]
    }
  end

  defp parse_json_or_nil(nil), do: nil

  defp parse_json_or_nil(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        map

      {:error, _reason} ->
        Logger.warning(
          "[Cyfr.Execution.Record] Failed to parse stored JSON (#{byte_size(json)} bytes), returning nil"
        )

        nil
    end
  end

  defp parse_json_or_nil(other), do: other

  defp parse_reference(nil), do: nil
  defp parse_reference(ref) when is_binary(ref), do: ref
  defp parse_reference(other), do: inspect(other)

  defp parse_status(nil), do: :running
  defp parse_status("running"), do: :running
  defp parse_status("paused"), do: :paused
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("cancelled"), do: :cancelled

  defp parse_status(unknown) do
    Logger.warning(
      "[Cyfr.Execution.Record] Unrecognized status: #{inspect(unknown)}, treating as :unknown"
    )

    :unknown
  end

  defp parse_datetime_value(nil), do: nil
  defp parse_datetime_value(%DateTime{} = dt), do: dt

  defp parse_datetime_value(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime_value(_), do: nil

  # ===========================================================================
  # Private
  # ===========================================================================

  @doc """
  Generate a unique execution ID.

  Uses `Cyfr.UUID7` for time-ordered execution identifiers.
  """
  @spec generate_id() :: String.t()
  def generate_id, do: Cyfr.UUID7.execution_id()

  defp encode_reference(ref) when is_binary(ref), do: ref
  defp encode_reference(nil), do: nil
  defp encode_reference(other), do: inspect(other)

  defp encode_json(nil), do: nil
  defp encode_json(value) when is_binary(value), do: value

  defp encode_json(value), do: Cyfr.Json.safe_encode(value)

  # What the row keeps of the input: enough to say what ran and to tell
  # two inputs apart, nothing of what they said.
  defp input_envelope(%__MODULE__{} = record) do
    input = record.input || %{}
    encoded = Jason.encode!(input)

    %{
      "envelope" => "v1",
      "reference" => encode_reference(record.reference),
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
        data = attachment["data"] || attachment[:data] || ""

        %{
          "filename" => attachment["filename"] || attachment[:filename],
          "media_type" => attachment["media_type"] || attachment[:media_type],
          "bytes" => byte_size(data),
          "digest" => Cyfr.Digest.sha256(data)
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
      "output_hash" => Cyfr.Digest.sha256(encoded),
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
           Arca.ExecutionPayloads.get(ctx, record.id, "result", attempt: record.attempt),
         {:ok, output} <- Jason.decode(bytes) do
      %{record | output: output}
    else
      _ -> record
    end
  end

  defp hydrate_output(_ctx, record), do: record

  defp usage_of(%{"usage" => usage}), do: usage
  defp usage_of(%{usage: usage}), do: usage
  defp usage_of(_), do: nil

  # The row's shape has one owner: the Ecto schema. The read map carries
  # every schema column except the lease mechanics, which belong to the
  # write path and the sweeper alone — `write_started` stamps them fresh
  # and nothing read back through here may act on them. A new column
  # flows into the map on its own; only `from_mcp_result/1` (the parser
  # layer) needs a decision about it.
  @row_only_fields [:event_seq]

  defp execution_to_map(record) when is_struct(record) or is_map(record) do
    Map.new(Arca.Execution.__schema__(:fields) -- @row_only_fields, fn field ->
      {field, Map.get(record, field)}
    end)
  end

  @executable_types Map.new(Cyfr.ComponentRef.executable_types(), &{&1, String.to_atom(&1)})

  @doc """
  The executable component type a stored `component_type` column names, as
  its atom, or `:error` when it names none: an empty column, a turn root's
  `"agent"`, or a type this build does not execute.
  """
  @spec executable_type(term()) :: {:ok, component_type()} | :error
  def executable_type(type) when is_binary(type), do: Map.fetch(@executable_types, type)
  def executable_type(_type), do: :error

  defp parse_component_type(nil), do: :reagent
  # A turn root: the agent is a consent source, not an executable type.
  defp parse_component_type("agent"), do: :agent

  defp parse_component_type(type_str) when is_binary(type_str) do
    case executable_type(type_str) do
      {:ok, type} ->
        type

      :error ->
        Logger.warning(
          "[Cyfr.Execution.Record] Unknown component type: #{inspect(type_str)}, defaulting to :reagent"
        )

        :reagent
    end
  end

  defp parse_component_type(other) do
    raise ArgumentError,
          "Unexpected component type value: #{inspect(other)}. " <>
            "Expected nil, a binary string, or an atom."
  end

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
