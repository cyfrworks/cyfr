# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Execution do
  @moduledoc """
  Ecto schema for execution records.

  Stores the complete execution lifecycle including input/output payloads,
  WASI traces, and host policy snapshots.

  ## Schema

  - `id` - Execution ID (exec_<uuid7>)
  - `request_id` - MCP request ID (req_<uuid7>) for cross-entity correlation
  - `reference` - JSON-encoded component reference
  - `input_hash` - SHA256 hash of input JSON (for deduplication)
  - `user_id` - User who initiated the execution
  - `component_type` - catalyst, reagent, or formula
  - `component_digest` - SHA256 digest of the WASM component
  - `started_at` - When execution started
  - `completed_at` - When execution finished (nil if running)
  - `duration_ms` - Execution duration in milliseconds
  - `status` - running, completed, failed, or cancelled
  - `error_message` - Error message if failed
  - `input` - JSON-encoded execution input
  - `output` - JSON-encoded execution output
  - `host_policy` - JSON-encoded host policy snapshot
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  # The execution lifecycle vocabulary, in one place like its sibling
  # stores. A row starts "running" and ends in exactly one of the
  # terminal three.
  @statuses ~w(running completed failed cancelled)
  @terminal_statuses ~w(completed failed cancelled)

  @doc "Every status an execution row can carry."
  def statuses, do: @statuses

  @doc "The statuses a finished execution can carry."
  def terminal_statuses, do: @terminal_statuses

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts []

  schema "executions" do
    field :reference, :string
    field :input_hash, :string
    field :user_id, :string
    field :athanor_id, :string
    field :request_id, :string
    field :component_type, :string
    field :component_digest, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :status, :string, default: "running"
    field :error_message, :string
    field :input, :string
    field :output, :string
    field :host_policy, :string
    field :parent_execution_id, :string
    field :root_execution_id, :string
    field :resolver_digest, :string
    field :activation_digest, :string
    field :activation_graph, :string
    field :runner_id, :string
    field :lease_until, :utc_datetime_usec
    # The fence. Minted with the row and carried by the one runner attempt
    # that opened it; every later write — renewal, completion, the sweep —
    # names it, so a runner that lost the row (its lease lapsed and the
    # sweeper failed it, or another attempt took it) cannot write over the
    # current owner. Two rows can share an id across restarts of this
    # process; they never share an attempt.
    field :attempt, :string
    # Which consent this execution rooted under: stamped by every root —
    # `run_root/5` and a `run_root_edge/5` tincture ingress alike — and nil
    # for a child row, which walks its parent's authority rather than
    # rooting one. The row is the SSOT: a caller that needs the turn's
    # authority again — an approval, an audit — reads it here instead of
    # re-deriving a selection that may since have become ambiguous.
    field :profile_id, :string
  end

  # Every column a start writes — the write path's half of the row shape,
  # exposed so the engine's record layer can pin its attrs against it.
  @start_fields [
    :id,
    :reference,
    :input_hash,
    :user_id,
    :athanor_id,
    :request_id,
    :component_type,
    :component_digest,
    :started_at,
    :status,
    :input,
    :host_policy,
    :parent_execution_id,
    :root_execution_id,
    :resolver_digest,
    :activation_digest,
    :activation_graph,
    :runner_id,
    :lease_until,
    :attempt,
    :profile_id
  ]

  @doc "The columns `start_changeset/1` casts, for the write path to pin against."
  def start_fields, do: @start_fields

  @doc """
  Creates a changeset for inserting a new execution record when starting.
  """
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @start_fields)
    |> validate_required([
      :id,
      :reference,
      :user_id,
      :athanor_id,
      :started_at,
      :status,
      :component_type
    ])
    |> validate_inclusion(:status, @statuses)
    # Which component types exist is product vocabulary — sourced from the
    # canonical list rather than re-declared in the persistence layer.
    # Tinctures never execute server-side, hence executable_types.
    |> validate_inclusion(:component_type, Sanctum.ComponentRef.executable_types())
  end

  @doc """
  Creates a changeset for completing an execution.
  """
  def complete_changeset(execution, attrs) do
    execution
    |> cast(attrs, [:completed_at, :duration_ms, :status, :error_message, :output])
    |> validate_required([:completed_at, :duration_ms, :status])
    |> validate_inclusion(:status, @terminal_statuses)
  end

  @doc """
  Records the start of an execution in the database.
  """
  def record_start(attrs) do
    Arca.Repo.Errors.with_db_rescue("Execution.record_start", fn ->
      attrs
      |> start_changeset()
      |> Arca.Repo.insert()
    end)
  end

  @doc """
  Records the completion of an execution in the database.

  Uses tenant-scoped lookup when a context is provided.

  The write carries an atomic `status == "running"` precondition, like its
  sibling `mark_failed_if_running/2`: cancel and the finishing runner race
  on this row, and without the guard whichever wrote second won — a
  `cancelled` row overwritten `completed` (with a second terminal event on
  the wire), or a finished run stamped `cancelled` and its output
  discarded. A row that already left `running` answers
  `{:error, :not_running}` and the caller keeps its hands off the wire.

  `fence` narrows the write to the attempt that owns the row (see
  `fenced/2`): a finisher whose attempt is no longer the row's is refused
  the same way.
  """
  def record_complete(%Sanctum.Context{} = ctx, id, attrs, fence \\ []) do
    Arca.Repo.Errors.with_db_rescue("Execution.record_complete", fn ->
      case get_tenant(ctx, id) do
        nil ->
          {:error, :not_found}

        # get_tenant is itself db-rescued: an outage answers a tuple here,
        # and binding it as the row would raise a non-DB error straight
        # through this rescue, reaching the caller as a crash rather than
        # the storage refusal every sibling answers.
        {:error, _} = err ->
          err

        execution ->
          changeset = complete_changeset(execution, attrs)

          if changeset.valid? do
            sets = Map.to_list(changeset.changes)

            from(e in __MODULE__, where: e.id == ^id, where: e.status == "running")
            |> fenced(fence)
            |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
            |> Arca.Repo.update_all(set: sets)
            |> case do
              {1, _} -> {:ok, Ecto.Changeset.apply_changes(changeset)}
              {0, _} -> {:error, :not_running}
            end
          else
            {:error, changeset}
          end
      end
    end)
  end

  @doc """
  Lists recent executions with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status
  """
  def list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.list", fn ->
      limit = Keyword.get(opts, :limit, 20)
      user_id = Keyword.get(opts, :user_id)
      status = Keyword.get(opts, :status)
      athanor_id = Keyword.fetch!(opts, :athanor_id)

      query =
        from e in __MODULE__,
          order_by: [desc: e.started_at],
          limit: ^limit,
          select:
            map(e, [
              :id,
              :reference,
              :input_hash,
              :user_id,
              :athanor_id,
              :request_id,
              :component_type,
              :component_digest,
              :started_at,
              :completed_at,
              :duration_ms,
              :status,
              :error_message,
              :parent_execution_id,
              :root_execution_id,
              :resolver_digest,
              :activation_digest
            ])

      query = Arca.QueryHelpers.where_athanor(query, athanor_id)

      query = if user_id, do: where(query, [e], e.user_id == ^user_id), else: query

      query =
        if status && status != :all,
          do: where(query, [e], e.status == ^to_string(status)),
          else: query

      parent_id = Keyword.get(opts, :parent_execution_id)

      query =
        if parent_id, do: where(query, [e], e.parent_execution_id == ^parent_id), else: query

      Arca.Repo.all(query)
    end)
  end

  @doc """
  Gets an execution by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering. Any other context is scoped via
  `where_tenant/2`, which raises for a context without an athanor (fail
  closed).
  """
  @spec get_tenant(Sanctum.Context.t(), String.t()) ::
          %__MODULE__{} | nil | {:error, :database_error}
  def get_tenant(%Sanctum.Context{} = ctx, id) do
    Arca.Repo.Errors.with_db_rescue("Execution.get_tenant", fn ->
      from(e in __MODULE__, where: e.id == ^id)
      |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
      |> Arca.Repo.one()
    end)
  end

  @doc """
  The executions a request id started, newest first, scoped to the caller's
  athanor.

  What `mcp_log.correlate` shows beside the log lines for a request. It
  lives here, with the schema, because `Emissary.MCP.Tools.RecordsProvider`
  was writing the Ecto for it inline — an MCP tool handler as a query
  layer, and the only place in the transport namespace that touched the
  Repo besides the health check's `SELECT 1`.
  """
  @spec list_by_request(Sanctum.Context.t(), String.t(), non_neg_integer()) ::
          [%__MODULE__{}] | {:error, :database_error}
  def list_by_request(%Sanctum.Context{} = ctx, request_id, limit \\ 100)
      when is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_by_request", fn ->
      from(e in __MODULE__,
        where: e.request_id == ^request_id,
        order_by: [desc: e.started_at],
        limit: ^limit
      )
      # Scoped to the caller's athanor — no per-user narrowing (members are
      # interchangeable), and no cross-athanor reach for an operator either:
      # only a server-internal context reads unfiltered.
      |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
      |> Arca.Repo.all()
    end)
  end

  @doc """
  How many executions each of `request_ids` started, as a map — the fan-out
  count `mcp_log.fan_outs` reports. Same tenant scoping as
  `list_by_request/3`.
  """
  @spec count_by_request(Sanctum.Context.t(), [String.t()]) ::
          %{String.t() => non_neg_integer()} | {:error, :database_error}
  def count_by_request(%Sanctum.Context{} = ctx, request_ids) when is_list(request_ids) do
    Arca.Repo.Errors.with_db_rescue("Execution.count_by_request", fn ->
      case Enum.filter(request_ids, &is_binary/1) do
        [] ->
          %{}

        ids ->
          from(e in __MODULE__,
            where: e.request_id in ^ids,
            group_by: e.request_id,
            select: {e.request_id, count(e.id)}
          )
          |> Arca.QueryHelpers.where_tenant_unless_platform(ctx)
          |> Arca.Repo.all()
          |> Map.new()
      end
    end)
  end

  @doc """
  Deletes executions older than the newest `keep` records within an
  athanor. Members are interchangeable, so retention keeps the N most
  recent executions per athanor, not per user. The row-plane retention
  convention: `{:ok, count}` — or `{:error, :database_error}` when the
  store cannot answer.
  """
  @spec delete_older_than(non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_older_than(keep, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.delete_older_than", fn ->
      {count, _} = Arca.Repo.delete_all(stale_query(keep, opts))
      {:ok, count}
    end)
  end

  @doc """
  Deletes an athanor's executions that started more than `days` ago, the
  age bound beside the count bound above. A row still "running" is never
  stale, for the reasons `stale_query/2` gives.
  """
  @spec delete_older_than_days(pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_older_than_days(days, opts) when is_integer(days) and days > 0 and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.delete_older_than_days", fn ->
      {count, _} = Arca.Repo.delete_all(aged_query(days, opts))
      {:ok, count}
    end)
  end

  @doc "The ids `delete_older_than/2` would remove, for what must go before them."
  @spec stale_ids(non_neg_integer(), keyword()) :: {:ok, [String.t()]} | {:error, :database_error}
  def stale_ids(keep, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.stale_ids", fn ->
      {:ok, Arca.Repo.all(from(e in stale_query(keep, opts), select: e.id))}
    end)
  end

  @doc "The ids `delete_older_than_days/2` would remove, for what must go before them."
  @spec ids_older_than_days(pos_integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, :database_error}
  def ids_older_than_days(days, opts) when is_integer(days) and days > 0 and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.ids_older_than_days", fn ->
      {:ok, Arca.Repo.all(from(e in aged_query(days, opts), select: e.id))}
    end)
  end

  @doc """
  Deletes the named executions of an athanor — the retention kinds' write,
  after the payloads those rows reference were released
  (`Arca.ExecutionPayloads.release/2`; the database refuses a row whose
  payload is still held).
  """
  @spec delete_ids([String.t()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_ids([], _opts), do: {:ok, 0}

  def delete_ids(ids, opts) when is_list(ids) and is_list(opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("Arca.Execution.delete_ids", fn ->
      {count, _} =
        from(e in __MODULE__, where: e.id in ^ids)
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  @doc "How many rows `delete_older_than_days/2` would remove — the dry-run count."
  @spec count_older_than_days(pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_older_than_days(days, opts) when is_integer(days) and days > 0 and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.count_older_than_days", fn ->
      {:ok, Arca.Repo.aggregate(aged_query(days, opts), :count)}
    end)
  end

  defp aged_query(days, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    from(e in __MODULE__,
      where: e.started_at < ^cutoff,
      where: e.status != "running"
    )
    |> Arca.QueryHelpers.where_athanor(athanor_id)
  end

  @doc "How many rows `delete_older_than/2` would remove — the dry-run count."
  @spec count_stale(non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_stale(keep, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Execution.count_stale", fn ->
      {:ok, Arca.Repo.aggregate(stale_query(keep, opts), :count)}
    end)
  end

  # Everything past the newest `keep` in the athanor — the one spelling
  # both the delete and its dry-run count share. A row still "running" is
  # never stale whatever its age: deleting it mid-flight blinds the lease
  # sweeper, makes its record_complete a :not_found, and loses its children
  # from the cancel cascade. The sweeper fails a lease-lapsed row first;
  # retention collects it on the next cycle.
  defp stale_query(keep, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    keep_ids_query =
      from(e in __MODULE__,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    from(e in __MODULE__,
      where: e.id not in subquery(keep_ids_query),
      where: e.status != "running"
    )
    |> Arca.QueryHelpers.where_athanor(athanor_id)
  end

  @doc """
  Lists child executions still in 'running' state for a given parent.

  Scoped to the parent's own athanor. Legitimate children always inherit the
  parent's athanor when spawned, so this matches every real child while
  preventing a cross-athanor `parent_execution_id` from grafting a foreign
  execution into the parent's cancellation/failure cascade.
  """
  def list_running_children(parent_execution_id) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_running_children", fn ->
      case Arca.Repo.get(__MODULE__, parent_execution_id) do
        %{athanor_id: athanor_id} ->
          from(e in __MODULE__,
            where: e.parent_execution_id == ^parent_execution_id,
            where: e.status == "running"
          )
          |> Arca.QueryHelpers.where_athanor(athanor_id)
          |> Arca.Repo.all()

        nil ->
          []
      end
    end)
  end

  @doc """
  Marks an execution as failed only if it's still 'running'. Returns {count, nil}.

  System-internal: the `id` originates from trusted runtime state — the
  cancellation cascade (`list_running_children/1`, already tenant-scoped) or the
  `Opus.ExecutionSweeper` GC's own scan — never from caller-supplied input. Do
  not call it with an id taken straight from a request.
  """
  def mark_failed_if_running(id, attrs, fence \\ []) do
    # Fail-open default: a row the store could not fail stays running; the sweep retries next tick.
    Arca.Repo.Errors.with_db_rescue("Execution.mark_failed_if_running", {0, nil}, fn ->
      # arca:unscoped-ok the id comes from trusted runtime state (the
      # tenant-scoped cancellation cascade or the sweeper's own scan), never
      # from caller input — see the doc above.
      from(e in __MODULE__,
        where: e.id == ^id,
        where: e.status == "running"
      )
      |> fenced(fence)
      |> Arca.Repo.update_all(
        set: [
          status: "failed",
          completed_at: attrs[:completed_at],
          duration_ms: attrs[:duration_ms],
          error_message: attrs[:error_message]
        ]
      )
    end)
  end

  @doc """
  Renew a running execution's lease: the runner is alive and the row is
  still its. Returns the number of rows touched — 0 once the execution has
  finished, been failed by the sweeper, or (with a fence) left this
  attempt's hands. A store that cannot answer also renews nothing, and the
  runner treats an unrenewed lease as one that lapses.
  """
  @spec renew_lease(String.t(), DateTime.t(), keyword()) :: non_neg_integer()
  # arca:unscoped-ok the runner renews the lease on the row it is running;
  # the id comes from trusted runtime state, never from a request.
  def renew_lease(id, %DateTime{} = until, fence \\ []) do
    # Fail-closed by shape: 0 rows, and the runner stops once its lease lapses.
    Arca.Repo.Errors.with_db_rescue("Execution.renew_lease", 0, fn ->
      {count, _} =
        from(e in __MODULE__, where: e.id == ^id and e.status == "running")
        |> fenced(fence)
        |> Arca.Repo.update_all(set: [lease_until: until])

      count
    end)
  end

  # The fence a writer proves it still owns the row with. `attempt` is the
  # id minted when the row was opened; `runner_id` the boot the attempt
  # runs on; `lease_until` the exact value the sweeper observed — a
  # renewal in between changes it, and the sweep then matches nothing,
  # which is the whole point. A nil value is "no fence on this key": a
  # caller that does not know the attempt (a person's cancel of a row
  # opened before the column existed) fences on the status alone.
  defp fenced(query, fence) do
    Enum.reduce(fence, query, fn
      {_key, nil}, q -> q
      {:attempt, attempt}, q -> where(q, [e], e.attempt == ^attempt)
      {:runner_id, runner}, q -> where(q, [e], e.runner_id == ^runner)
      {:lease_until, %DateTime{} = seen}, q -> where(q, [e], e.lease_until == ^seen)
    end)
  end

  @doc """
  Lists 'running' executions whose lease lapsed before `now` (the sweep).

  Intentionally spans all tenants: the `Opus.ExecutionSweeper` GC must reap
  orphaned 'running' rows left by a crashed runner — this node's or another
  node's — when no tenant context can be reconstructed. System-internal
  only — not reachable from a tenant request.
  """
  def list_stale_running(now, limit \\ 50) do
    # Fail-open default: an unreadable store sweeps nothing this tick; the next tick retries.
    Arca.Repo.Errors.with_db_rescue("Execution.list_stale_running", [], fn ->
      # arca:unscoped-ok the sweeper reaps orphaned rows across all tenants
      # when no tenant context can be reconstructed — system-internal only.
      from(e in __MODULE__,
        where: e.status == "running",
        where: e.lease_until < ^now,
        order_by: [asc: e.lease_until],
        limit: ^limit
      )
      |> Arca.Repo.all()
    end)
  end

  @doc """
  Computes SHA256 hash of input for deduplication.
  """
  def hash_input(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} ->
        Cyfr.Digest.sha256_hex(json)

      {:error, _} ->
        nil
    end
  end

  def hash_input(_), do: nil
end
