# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DecisionLog do
  @moduledoc """
  The admission decision log: one row per call the gate admitted or
  refused (`Prima.Decision`), and later, separately, how the admitted work
  ended.

  ## The budget

  Audit is best-effort for the operation: the caller of `append/3` or
  `finish/4` waits on the database at most 500 ms, checkout included, and
  is answered a typed `Arca.DecisionLog.AuditFailure` when the write did
  not finish in time, never an unbounded wait. Neither retries anything;
  what the caller does with a failure is the caller's, and no failure here
  is a reason to run an operation again.

  Each runs on a connection of its own, in a process of its own, so it is
  never part of a caller's transaction: a caller's rollback cannot take an
  admission back with it. It must not be called from inside one either —
  on SQLite the caller's transaction holds the one write lock this would
  wait for.

  The writing process has a bound of its own. On PostgreSQL it is the
  caller's deadline: the pool closes a connection held past it, and the
  statement's socket goes with it. On SQLite a pool that closes a
  connection while its statement is stepping inside the driver can crash
  the VM, and the pool counts its deadline from the checkout request, so
  a wait for a connection eats into it. The writer's pool timeout is the
  lock-wait bound (`Arca.Repo.busy_timeout_ms/0`) plus a 1 s margin, and
  the transaction is told that deadline as an absolute instant: the lock
  step in `Arca.Repo` waits only as long as still fits before the pool
  acts, with room for the last quantum, the pause and the commit, and a
  writer that reaches the lock with less than that left refuses at once
  and touches nothing. A write that lands after its caller was told
  `:timeout` is the same row a repeat would write, which idempotence
  makes harmless.

  ## Idempotence

  A decision is keyed by its call id. Appending the identical admission
  again is `:ok`; appending a different one under the same id is
  `:conflict` and writes nothing. `finish/4` records the completion once:
  the identical completion again is `:ok`, a different one is
  `:conflict`, and no admission under the id — or one outside the actor's
  tenant — is `:not_found`; nothing is synthesized.

  ## Tenancy

  The row's tenant and person are the actor's. A refusal made before any
  caller was established is appended with no actor and is the host's row,
  with neither. The tenant readers take the actor first and never answer
  a row without a tenant; the global readers are the platform admin's.
  Tenant rows go with the athanor (`Arca.TenantTables`), tenant retention
  is `Arca.Retention.Decisions`, and the host purges the rows without a
  tenant under its own claim (`purge_global/2`).
  """

  import Ecto.Query

  require Arca.Repo.Errors
  require Logger

  alias Arca.Schemas.DecisionLog, as: Row
  alias Prima.Decision

  @budget_ms 500
  @default_limit 50
  @max_limit 500

  defmodule AuditFailure do
    @moduledoc """
    Why a decision was not written: `:timeout` (the budget ran out),
    `:unavailable` (the store could not answer), `:conflict` (the call id
    holds a different decision or completion) or `:not_found` (no
    admission under the id in the actor's tenant, for a completion).
    `stage` is the write that failed.
    """

    @enforce_keys [:kind, :stage]
    defstruct [:kind, :stage]

    @type kind :: :timeout | :unavailable | :conflict | :not_found
    @type stage :: :append | :finish
    @type t :: %__MODULE__{kind: kind(), stage: stage()}
  end

  @type result :: :ok | {:error, AuditFailure.t()}
  @type read_refusal :: :no_athanor | :not_found | :database_error

  @doc "The database waiting budget of one append or finish, in milliseconds."
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  # ============================================================================
  # Writes
  # ============================================================================

  @doc """
  Append the admission `decision` under the actor, or under no actor for a
  refusal before any caller was established.

  `mcp_log:` — the attributes of an `Arca.McpLog` row that projects this
  decision, written in the same transaction; its tenant is the actor's,
  so it needs one. An identical repeat writes neither row again.

  Raises `ArgumentError` for a decision outside `Prima.Decision`'s
  vocabulary, one naming another tenant or person than the actor's, or a
  projection that is not a row.
  """
  @spec append(Prima.Actor.t() | nil, Decision.t(), keyword()) :: result()
  def append(actor, decision, opts \\ [])

  def append(actor, %Decision{} = decision, opts)
      when (is_nil(actor) or is_struct(actor, Prima.Actor)) and is_list(opts) do
    row = admission_row!(actor, decision)
    projection = projection!(actor, Keyword.get(opts, :mcp_log))

    budgeted(:append, fn deadline -> write_admission(row, projection, deadline) end)
  end

  @doc """
  Record how the admitted call `call_id` ended: `completion` is a
  `t:Prima.Decision.completion_record/0`, `completed_at` defaulting to now.

  `mcp_log:` — the completion's columns of the call's `Arca.McpLog` row
  (`status`, `duration_ms`, `routed_to`, `error_code`, `output`,
  `error`), written in the same transaction; the row is the call's own
  in the actor's tenant.

  A row outside the actor's tenant is `:not_found`, as is no row.
  """
  @spec finish(Prima.Actor.t() | nil, String.t(), map(), keyword()) :: result()
  def finish(actor, call_id, completion, opts \\ [])

  def finish(actor, call_id, %{} = completion, opts)
      when (is_nil(actor) or is_struct(actor, Prima.Actor)) and is_binary(call_id) and
             is_list(opts) do
    record = completion_row!(completion)
    projection = completion_projection!(actor, Keyword.get(opts, :mcp_log))
    tenant = tenant_of(actor)

    budgeted(:finish, fn deadline ->
      write_completion(tenant, call_id, record, projection, deadline)
    end)
  end

  # The admission's columns, attributed to the actor. A decision that names
  # a tenant or person is held to the actor's: attribution is the actor's
  # and never the caller's to choose.
  defp admission_row!(actor, %Decision{} = decision) do
    case Decision.validate(decision) do
      :ok -> :ok
      {:error, why} -> raise ArgumentError, "invalid decision: #{why}"
    end

    athanor_id = attributed!(:athanor_id, decision.athanor_id, actor && actor.athanor_id)
    user_id = attributed!(:user_id, decision.user_id, actor && actor.user_id)

    row = %{
      call_id: decision.call_id,
      parent_call_id: decision.parent_call_id,
      request_id: decision.request_id,
      user_id: user_id,
      athanor_id: athanor_id,
      plane: Atom.to_string(decision.plane),
      tool: decision.tool,
      action: decision.action,
      admission: Atom.to_string(decision.admission),
      refusal_class: name(decision.refusal_class),
      reason: decision.reason,
      inserted_at: DateTime.truncate(decision.inserted_at, :microsecond)
    }

    case Row.create_changeset(row) do
      %Ecto.Changeset{valid?: true} -> row
      changeset -> raise ArgumentError, "invalid decision: #{inspect(invalid(changeset))}"
    end
  end

  defp attributed!(_field, nil, actor_value), do: actor_value
  defp attributed!(_field, same, same), do: same

  defp attributed!(field, _named, _actor_value),
    do: raise(ArgumentError, "a decision's #{field} is the actor's")

  defp projection!(_actor, nil), do: nil

  defp projection!(%Prima.Actor{athanor_id: athanor_id}, %{} = attrs)
       when is_binary(athanor_id) and athanor_id != "" do
    case Arca.Schemas.McpLog.create_changeset(Map.put(attrs, :athanor_id, athanor_id)) do
      %Ecto.Changeset{valid?: true} = changeset -> changeset
      changeset -> raise ArgumentError, "invalid mcp_log: #{inspect(invalid(changeset))}"
    end
  end

  defp projection!(_actor, _attrs),
    do: raise(ArgumentError, "an mcp_log projection is filed under the actor's athanor")

  @completion_columns [:status, :duration_ms, :routed_to, :error_code, :output, :error]

  defp completion_projection!(_actor, nil), do: nil

  defp completion_projection!(%Prima.Actor{athanor_id: athanor_id}, %{} = attrs)
       when is_binary(athanor_id) and athanor_id != "" do
    case Map.keys(attrs) -- @completion_columns do
      [] -> attrs |> Map.to_list()
      extra -> raise ArgumentError, "not completion columns of an mcp_log: #{inspect(extra)}"
    end
  end

  defp completion_projection!(_actor, _attrs),
    do: raise(ArgumentError, "an mcp_log projection is filed under the actor's athanor")

  defp completion_row!(completion) do
    case Decision.validate_completion(completion) do
      :ok -> :ok
      {:error, why} -> raise ArgumentError, "invalid completion: #{why}"
    end

    %{
      completion: Atom.to_string(completion.completion),
      completion_class: name(Map.get(completion, :completion_class)),
      completed_at:
        DateTime.truncate(Map.get(completion, :completed_at) || DateTime.utc_now(), :microsecond),
      duration_ms: Map.get(completion, :duration_ms)
    }
  end

  # Whose rows a completion may touch: the actor's athanor, or — for no
  # actor, or one with no athanor — the rows without one.
  defp tenant_of(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:athanor, id}
  defp tenant_of(_actor), do: :none

  defp write_admission(row, projection, deadline) do
    {pool_ms, pool_deadline} = pool_bound(deadline)

    Arca.Repo.transaction(
      fn ->
        case Arca.Repo.insert_all(Row, [row],
               on_conflict: :nothing,
               conflict_target: [:call_id],
               timeout: db_timeout(deadline)
             ) do
          {1, _} ->
            if projection do
              Arca.Repo.insert(projection,
                on_conflict: :nothing,
                conflict_target: :id,
                timeout: db_timeout(deadline)
              )
            end

            :ok

          {0, _} ->
            existing = Arca.Repo.get(Row, row.call_id, timeout: db_timeout(deadline))
            if same_admission?(existing, row), do: :ok, else: Arca.Repo.rollback(:conflict)
        end
      end,
      timeout: pool_ms,
      pool_deadline: pool_deadline
    )
  end

  # The row is the call's own inside the tenant the completion names: an
  # athanor's, or the host's rows without one.
  defp write_completion(tenant, call_id, record, projection, deadline) do
    {pool_ms, pool_deadline} = pool_bound(deadline)

    Arca.Repo.transaction(
      fn ->
        case Arca.Repo.one(completion_target(tenant, call_id), timeout: db_timeout(deadline)) do
          nil ->
            Arca.Repo.rollback(:not_found)

          %Row{completion: nil} ->
            case Arca.Repo.update_all(
                   where(completion_target(tenant, call_id), [r], is_nil(r.completion)),
                   [set: Map.to_list(record)],
                   timeout: db_timeout(deadline)
                 ) do
              {1, _} ->
                project_completion(tenant, call_id, projection, deadline)

              # Another finish landed between the read and the write.
              {0, _} ->
                same_or_conflict(tenant, call_id, record, deadline)
            end

          %Row{} = row ->
            if same_completion?(row, record), do: :ok, else: Arca.Repo.rollback(:conflict)
        end
      end,
      timeout: pool_ms,
      pool_deadline: pool_deadline
    )
  end

  defp same_or_conflict(tenant, call_id, record, deadline) do
    row = Arca.Repo.one(completion_target(tenant, call_id), timeout: db_timeout(deadline))
    if same_completion?(row, record), do: :ok, else: Arca.Repo.rollback(:conflict)
  end

  defp completion_target({:athanor, athanor_id}, call_id),
    do: from(r in Row, where: r.call_id == ^call_id and r.athanor_id == ^athanor_id)

  # The host's own rows, which carry no tenant: a completion recorded with
  # no actor reaches only rows without an athanor.
  defp completion_target(:none, call_id),
    do: from(r in Row, where: r.call_id == ^call_id and is_nil(r.athanor_id))

  defp project_completion(_tenant, _call_id, nil, _deadline), do: :ok

  defp project_completion({:athanor, athanor_id}, call_id, set, deadline) do
    Arca.Repo.update_all(
      from(l in Arca.Schemas.McpLog, where: l.id == ^call_id and l.athanor_id == ^athanor_id),
      [set: set],
      timeout: db_timeout(deadline)
    )

    :ok
  end

  defp same_admission?(%Row{} = existing, row) do
    Enum.all?(Row.admission_fields(), fn
      :inserted_at -> DateTime.compare(existing.inserted_at, row.inserted_at) == :eq
      field -> Map.fetch!(existing, field) == Map.fetch!(row, field)
    end)
  end

  defp same_admission?(nil, _row), do: false

  # A completion is its outcome, class and duration; `completed_at` is when
  # it was first recorded.
  defp same_completion?(%Row{} = row, record) do
    row.completion == record.completion and row.completion_class == record.completion_class and
      row.duration_ms == record.duration_ms
  end

  defp same_completion?(nil, _record), do: false

  # ============================================================================
  # The budget
  # ============================================================================

  # Run `write` in a process of its own under one deadline, and wait for it
  # no longer than that. The answer comes back on an alias that is dropped
  # when the caller stops waiting, so an answer sent after that is never
  # delivered; one that lands between the timeout and the unalias stays in
  # the caller's mailbox as a single `{alias, answer}` message, which a
  # request process tolerates. The process is not linked: the caller's
  # death does not stop a write already under way, and the write's crash
  # is an answer.
  defp budgeted(stage, write) do
    deadline = System.monotonic_time(:millisecond) + @budget_ms
    reply = Process.alias([:reply])
    callers = [self() | List.wrap(Process.get(:"$callers"))]

    {pid, monitor} =
      spawn_monitor(fn ->
        # The sandbox finds its owner through the callers, as it does for
        # a Task.
        Process.put(:"$callers", callers)
        send(reply, {reply, attempt(stage, write, deadline)})
      end)

    receive do
      {^reply, answer} ->
        Process.demonitor(monitor, [:flush])
        answer(stage, answer)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        Process.unalias(reply)
        {:error, failure(stage, :unavailable)}
    after
      left(deadline) ->
        Process.unalias(reply)
        Process.demonitor(monitor, [:flush])
        {:error, failure(stage, :timeout)}
    end
  end

  defp answer(_stage, {:ok, :ok}), do: :ok
  defp answer(stage, {:error, kind}) when is_atom(kind), do: {:error, failure(stage, kind)}

  defp attempt(stage, write, deadline) do
    # A writer that starts past its deadline asks the pool for nothing.
    if left(deadline) == 0 do
      {:error, :timeout}
    else
      case write.(deadline) do
        {:ok, :ok} = ok -> ok
        {:error, kind} when kind in [:conflict, :not_found] -> {:error, kind}
      end
    end
  rescue
    e in DBConnection.ConnectionError ->
      kind = if timed_out?(e, deadline), do: :timeout, else: :unavailable
      logged(stage, kind, e)

    e in Arca.Repo.BusyTimeoutError ->
      logged(stage, :timeout, e)

    e in Arca.Repo.Errors.db_errors() ->
      logged(stage, :unavailable, e)
  catch
    :exit, reason ->
      # Its shape only: an exit reason can carry a connection's state.
      Prima.LoggerContext.unexpected(__MODULE__, reason, :warning)
      {:error, :unavailable}
  end

  # A connection error after the deadline is the deadline's: the pool
  # closes a connection its holder kept past it.
  defp timed_out?(%DBConnection.ConnectionError{reason: :queue_timeout}, _deadline), do: true

  defp timed_out?(%DBConnection.ConnectionError{}, deadline),
    do: System.monotonic_time(:millisecond) >= deadline

  # The exception's module only: a driver's message can carry a statement.
  defp logged(stage, kind, exception) do
    Logger.warning("[Arca.DecisionLog] #{stage} #{kind}: #{inspect(exception.__struct__)}")

    {:error, kind}
  end

  defp failure(stage, kind), do: %AuditFailure{kind: kind, stage: stage}

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Above the lock-wait bound on SQLite, so that a writer that reaches the
  # lock with its full time left can wait the bound out and still commit.
  @sqlite_margin_ms 1_000

  # The writer's pool timeout. On PostgreSQL it is the caller's deadline:
  # the pool closes a connection held past it, and the statement's socket
  # goes with it. On SQLite the pool must never close a connection whose
  # statement is still stepping inside the driver, and the pool counts its
  # deadline from the checkout request, so a wait for the connection eats
  # into it: the timeout is the lock-wait bound plus a margin (never
  # `:infinity`, which would unbound the wait for a connection as well), and
  # the transaction is told the absolute deadline (`:pool_deadline`), so
  # `Arca.Repo`'s lock step cuts its wait to what still fits before the
  # pool acts and refuses at once when nothing does. The caller's wait is
  # the budget either way.
  defp db_timeout(deadline) do
    case Arca.Repo.adapter() do
      Ecto.Adapters.SQLite3 -> Arca.Repo.busy_timeout_ms() + @sqlite_margin_ms
      _postgres -> max(left(deadline), 1)
    end
  end

  # The pool timeout and the absolute instant it names, taken just before
  # the checkout request so the two agree.
  defp pool_bound(deadline) do
    pool_ms = db_timeout(deadline)
    {pool_ms, System.monotonic_time(:millisecond) + pool_ms}
  end

  # ============================================================================
  # Tenant readers
  # ============================================================================

  @doc """
  The actor's tenant's decision under `call_id`. A decision without a
  tenant is never one of them.
  """
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, Decision.t()} | {:error, read_refusal()}
  def get(%Prima.Actor{athanor_id: id} = actor, call_id)
      when is_binary(id) and id != "" and is_binary(call_id) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.get", fn ->
      from(r in Row, where: r.call_id == ^call_id)
      |> Arca.QueryHelpers.where_tenant(actor)
      |> Arca.Repo.one()
      |> found()
    end)
  end

  def get(%Prima.Actor{}, call_id) when is_binary(call_id), do: {:error, :no_athanor}

  @doc """
  The actor's tenant's decisions, newest first. Options: `:limit`
  (default #{@default_limit}, at most #{@max_limit}), `:request_id`,
  `:admission`, `:refusal_class`, `:tool`, `:user_id` and `:since`.
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [Decision.t()]} | {:error, :no_athanor | :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{athanor_id: id} = actor, opts)
      when is_binary(id) and id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.list", fn ->
      rows =
        Row
        |> Arca.QueryHelpers.where_tenant(actor)
        |> filtered(opts)
        |> order_by([r], desc: r.inserted_at, desc: r.call_id)
        |> limit(^limit(opts))
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &to_decision/1)}
    end)
  end

  def list(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  @doc """
  Every decision of the actor's tenant made under the ingress request
  `request_id` — a chain's calls — oldest first.
  """
  @spec correlate(Prima.Actor.t(), String.t()) ::
          {:ok, [Decision.t()]} | {:error, :no_athanor | :database_error}
  def correlate(%Prima.Actor{athanor_id: id} = actor, request_id)
      when is_binary(id) and id != "" and is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.correlate", fn ->
      rows =
        from(r in Row,
          where: r.request_id == ^request_id,
          order_by: [asc: r.inserted_at, asc: r.call_id],
          limit: ^@max_limit
        )
        |> Arca.QueryHelpers.where_tenant(actor)
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &to_decision/1)}
    end)
  end

  def correlate(%Prima.Actor{}, request_id) when is_binary(request_id), do: {:error, :no_athanor}

  # ============================================================================
  # Global readers — the platform admin's
  # ============================================================================

  @doc """
  The decision under `call_id` whatever its tenant, the host's rows
  included. The actor must be a platform admin (`:forbidden` otherwise).
  """
  @spec get_global(Prima.Actor.t(), String.t()) ::
          {:ok, Decision.t()} | {:error, :forbidden | :not_found | :database_error}
  # arca:unscoped-ok platform-admin global audit read
  def get_global(%Prima.Actor{platform_admin: true}, call_id) when is_binary(call_id) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.get_global", fn ->
      Row |> Arca.Repo.get(call_id) |> found()
    end)
  end

  def get_global(%Prima.Actor{}, call_id) when is_binary(call_id), do: {:error, :forbidden}

  @doc """
  Decisions across every tenant and the host's own, newest first. The
  actor must be a platform admin (`:forbidden` otherwise). Options are
  `list/2`'s, plus `:athanor_id` — one tenant's, or `:none` for the rows
  without one.
  """
  @spec list_global(Prima.Actor.t(), keyword()) ::
          {:ok, [Decision.t()]} | {:error, :forbidden | :database_error}
  def list_global(actor, opts \\ [])

  # arca:unscoped-ok platform-admin global audit read
  def list_global(%Prima.Actor{platform_admin: true}, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.list_global", fn ->
      rows =
        Row
        |> by_tenant(Keyword.get(opts, :athanor_id))
        |> filtered(opts)
        |> order_by([r], desc: r.inserted_at, desc: r.call_id)
        |> limit(^limit(opts))
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &to_decision/1)}
    end)
  end

  def list_global(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :forbidden}

  defp by_tenant(query, nil), do: query
  defp by_tenant(query, :none), do: where(query, [r], is_nil(r.athanor_id))
  defp by_tenant(query, id) when is_binary(id), do: Arca.QueryHelpers.where_athanor(query, id)

  defp filtered(query, opts) do
    Enum.reduce(opts, query, fn
      {:request_id, v}, q when is_binary(v) -> where(q, [r], r.request_id == ^v)
      {:admission, v}, q when is_atom(v) -> where(q, [r], r.admission == ^name(v))
      {:refusal_class, v}, q when is_atom(v) -> where(q, [r], r.refusal_class == ^name(v))
      {:tool, v}, q when is_binary(v) -> where(q, [r], r.tool == ^v)
      {:user_id, v}, q when is_binary(v) -> where(q, [r], r.user_id == ^v)
      {:since, %DateTime{} = v}, q -> where(q, [r], r.inserted_at >= ^v)
      _other, q -> q
    end)
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      n when is_integer(n) and n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp found(nil), do: {:error, :not_found}
  defp found(%Row{} = row), do: {:ok, to_decision(row)}

  # ============================================================================
  # Retention
  # ============================================================================

  @doc """
  Delete one athanor's decisions made before `cutoff` (`:athanor_id`
  required): the tenant kind's cleanup (`Arca.Retention.Decisions`).
  """
  @spec delete_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def delete_before(%DateTime{} = cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("DecisionLog.delete_before", fn ->
      {count, _} =
        Row
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:inserted_at, cutoff)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  @doc "How many rows `delete_before/2` would remove — the dry-run count."
  @spec count_before(DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_before(%DateTime{} = cutoff, opts) do
    athanor_id = Keyword.fetch!(opts, :athanor_id)

    Arca.Repo.Errors.with_db_rescue("DecisionLog.count_before", fn ->
      count =
        Row
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.where_before(:inserted_at, cutoff)
        |> Arca.Repo.aggregate(:count)

      {:ok, count}
    end)
  end

  @doc """
  Delete the host's decisions — the rows without a tenant — made before
  `cutoff`. The host's responsibility under its held retention claim
  (`Cyfr.Boundaries.system_responsibilities/0`), so only the platform
  system actor (`Prima.Actor.system/0`) may; any other is `:forbidden`
  before any query. Never touches a tenant's row.
  """
  @spec purge_global(Prima.Actor.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, :forbidden | :database_error}
  # arca:unscoped-ok the host's own decision rows, which carry no tenant,
  # purged under its held retention claim (Cyfr.Boundaries.system_responsibilities/0)
  def purge_global(
        %Prima.Actor{system: true, scope: :platform, athanor_id: nil},
        %DateTime{} = cutoff
      ) do
    Arca.Repo.Errors.with_db_rescue("DecisionLog.purge_global", fn ->
      {count, _} =
        from(r in Row, where: is_nil(r.athanor_id))
        |> Arca.QueryHelpers.where_before(:inserted_at, cutoff)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  def purge_global(%Prima.Actor{}, %DateTime{}), do: {:error, :forbidden}

  # ============================================================================
  # Rows
  # ============================================================================

  defp to_decision(%Row{} = r) do
    %Decision{
      call_id: r.call_id,
      parent_call_id: r.parent_call_id,
      request_id: r.request_id,
      user_id: r.user_id,
      athanor_id: r.athanor_id,
      plane: known(r.plane, Decision.planes()),
      tool: r.tool,
      action: r.action,
      inserted_at: r.inserted_at,
      admission: known(r.admission, Decision.admissions()),
      refusal_class: class(r.refusal_class),
      reason: r.reason,
      completion: known(r.completion, Decision.completions()),
      completion_class: class(r.completion_class),
      completed_at: r.completed_at,
      duration_ms: r.duration_ms
    }
  end

  defp known(nil, _vocabulary), do: nil
  defp known(name, vocabulary), do: Enum.find(vocabulary, &(Atom.to_string(&1) == name))

  # A stored class outside the table reads as the table's own fallback.
  defp class(nil), do: nil
  defp class(name), do: known(name, Prima.Refusal.classes()) || :internal

  defp name(nil), do: nil
  defp name(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp invalid(changeset), do: Arca.Data.invalid(changeset)
end
