# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Execution do
  @moduledoc """
  The execution records: admission, completion, the record readers and
  the retention primitives over `Arca.Schemas.Execution`. Every row a
  function here answers is a plain map (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.Schemas.Execution, as: Row

  # Every function that names a tenant takes the `Cyfr.Actor` first. The
  # record readers and the lifecycle writes branch on `scope` through
  # `Arca.QueryHelpers.where_tenant_unless_platform/2` — a platform-scope
  # actor reads across athanors and legitimately carries none, so they
  # match the actor and let the backstop raise for an athanor-scope actor
  # with no athanor rather than guarding a resolved one in the head. The
  # sweeps and the retention primitives carry no actor and say why where
  # they stand.

  @terminal_statuses Row.terminal_statuses()
  @fields Row.__schema__(:fields)

  @doc "Every status an execution row can carry."
  @spec statuses() :: [String.t()]
  def statuses, do: Row.statuses()

  @doc "The statuses a finished execution can carry."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Every kind an execution row can carry."
  @spec kinds() :: [String.t()]
  def kinds, do: Row.kinds()

  @doc "The columns a start writes, for the write path to pin its attrs against."
  @spec start_fields() :: [atom()]
  def start_fields, do: Row.start_fields()

  @doc "Every column of an execution row, in the plain map a reader answers."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The child of `parent_execution_id` admitted under `child_key`, scoped to
  the caller's athanor: `{:ok, row}`, or `:none` when no child carries
  that key.
  """
  @spec child_by_key(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | :none | {:error, :database_error}
  def child_by_key(%Cyfr.Actor{} = actor, parent_execution_id, child_key)
      when is_binary(parent_execution_id) and
             is_binary(child_key) do
    Arca.Repo.Errors.with_db_rescue("Execution.child_by_key", fn ->
      from(e in Row,
        where: e.parent_execution_id == ^parent_execution_id and e.child_key == ^child_key
      )
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  # An insert that lost the child-key race answers by name, so the caller
  # reads the winner instead of a changeset.
  defp duplicate_child_key({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    case Keyword.get(errors, :child_key) do
      {_message, [constraint: :unique, constraint_name: _name]} -> {:error, :duplicate_child_key}
      _other -> {:error, changeset}
    end
  end

  defp duplicate_child_key(other), do: other

  @doc """
  Records the start of an execution in the database.
  """
  @spec record_start(map()) :: {:ok, map()} | {:error, term()}
  def record_start(attrs) do
    Arca.Repo.Errors.with_db_rescue("Execution.record_start", fn ->
      attrs
      |> Row.start_changeset()
      |> Arca.Repo.insert()
      |> duplicate_child_key()
    end)
    |> Arca.Data.project()
  end

  @doc """
  Whether `reason` is the refusal of one of `admit/2`'s barriers: an
  expired hold, a superseded step, a parent that ended, an occurrence not
  claimed, a grant whose estate no longer stands at its generation, or an
  admission that named no grant.
  """
  @spec barrier_refusal?(term()) :: boolean()
  def barrier_refusal?(reason),
    do:
      reason in [
        :hold_expired,
        :step_superseded,
        :parent_ended,
        :occurrence_not_claimed,
        :not_standing,
        :missing_grant
      ]

  @doc """
  Admit an execution: the row, its first attempt and, for a root, its
  budget reservation, in one transaction. `attrs` are the start
  changeset's; `opts`:

  - `:attempt` — the attempt id (minted when absent); `:service_id` (the
    worker service the attempt is dispatched to; nil, the default, when the
    control plane holds it), `:boot_id` (the boot holding it; this boot's
    when absent), `:lease_until` (defaults from `Arca.ExecutionAttempts`).
  - `:reservation` — `%{budget_id, cap}` to mint the root's reservation.
  - `:charge` — `%{reservation_id, id}` of the hold this child was
    charged under; the hold barrier stamps it admitted while it stands,
    and admission is refused `{:error, :hold_expired}` otherwise.
  - `:step` — `%{id, generation, athanor_id}` of the loop step this child
    belongs to; the step barrier binds the child to it while the step is
    dispatched, on its generation and not cancelled, and admission is
    refused `{:error, :step_superseded}` otherwise.
  - `:parent_attempt` — the attempt of the row's `parent_execution_id` this
    child is admitted under; the parent barrier holds it while it owns its
    running parent, running with no cancel asked of it
    (`Arca.ExecutionAttempts.hold_for_child!/3`), and admission is refused
    `{:error, :parent_ended}` otherwise.
  - `:payloads` — staged payloads (`Arca.ExecutionPayloads.Staged`)
    committed for the attempt in the same transaction; one that cannot
    be kept refuses admission `{:error, {:payload_not_retained, why}}`.
  - `:occurrence_id` — the schedule occurrence this root runs; it moves
    from `claimed` to `started` in the same transaction
    (`Arca.ScheduleOccurrences.start!/3`), and admission is refused
    `{:error, :occurrence_not_claimed}` when it is not claimed.
  - `:grant` and `:verify` (required, `Arca.ExecutionStanding`) — the
    `Cyfr.ExecutionGrant` the attempt is stamped with and the caller's
    check over it, asked first in the transaction, before any row is
    written or locked. A root's grant is its estate's standing read at
    admission; a child's must be the stamp its parent's current attempt
    carries, and one that is not is refused `{:error, :not_standing}`.
    The check's refusal is answered as itself; an admission missing
    either is `{:error, :missing_grant}`.

  Answers `{:ok, %{execution: row, attempt: row}}`, each a plain map; the
  execution's `event_seq` is the number of the `execution.started` event
  the transaction appended, for the caller to publish. A barrier's refusal
  (`barrier_refusal?/1`) writes nothing, and neither does a row whose
  `child_key` another child of the same parent already carries:
  `{:error, :duplicate_child_key}`, for the caller to answer with that
  child (`child_by_key/3`).
  """
  @spec admit(map(), keyword()) ::
          {:ok, %{execution: map(), attempt: map()}} | {:error, term()}
  def admit(attrs, opts) when is_map(attrs) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.admit", fn ->
      athanor_id = Map.fetch!(attrs, :athanor_id)

      case Arca.ExecutionStanding.inputs(opts, fn -> nil end) do
        {:ok, %Cyfr.ExecutionGrant{athanor_id: ^athanor_id} = grant, verify} ->
          admit(attrs, opts, grant, verify)

        {:ok, _other, _verify} ->
          {:error, :not_standing}

        {:error, :missing_grant} = refused ->
          refused
      end
    end)
    |> Arca.Data.project()
  end

  # arca:db-raise-ok its caller rescues around it.
  defp admit(attrs, opts, grant, verify) do
    athanor_id = Map.fetch!(attrs, :athanor_id)
    attempt_id = Keyword.get(opts, :attempt) || Arca.ExecutionAttempts.generate_id()
    boot_id = Keyword.get(opts, :boot_id) || Cyfr.Boot.id()
    lease_until = Keyword.get(opts, :lease_until) || Arca.ExecutionAttempts.lease_until()
    started_at = Map.get(attrs, :started_at) || DateTime.utc_now()

    attrs =
      attrs
      |> Map.put(:started_at, started_at)
      |> Map.put(:status, "running")
      |> Map.put(:current_attempt, attempt_id)

    Arca.Repo.locking_transaction(fn ->
      # The estate's standing first, before any execution or attempt row
      # is written or locked; a child's grant is its parent's stamp.
      Arca.ExecutionStanding.verify!(grant, verify)
      inherits!(athanor_id, Map.get(attrs, :parent_execution_id), grant)

      execution =
        case Arca.Repo.insert(Row.start_changeset(attrs)) do
          {:ok, row} -> row
          {:error, changeset} -> Arca.Repo.rollback(changeset)
        end

      attempt =
        Arca.ExecutionAttempts.open!(Cyfr.Actor.in_athanor(athanor_id), execution.id,
          attempt: attempt_id,
          service_id: Keyword.get(opts, :service_id),
          boot_id: boot_id,
          lease_until: lease_until,
          started_at: started_at,
          grant: grant
        )

      case Keyword.get(opts, :reservation) do
        %{budget_id: budget_id, cap: cap} ->
          Arca.BudgetReservations.mint!(
            Cyfr.Actor.in_athanor(athanor_id),
            execution.id,
            budget_id,
            cap
          )

        nil ->
          :ok
      end

      case Keyword.get(opts, :charge) do
        %{reservation_id: reservation_id, id: id} ->
          if Arca.BudgetReservations.admit_hold!(
               Cyfr.Actor.in_athanor(athanor_id),
               reservation_id,
               id
             ) != 1,
             do: Arca.Repo.rollback(:hold_expired)

        nil ->
          :ok
      end

      case Keyword.get(opts, :step) do
        %{id: step_id, generation: generation} ->
          if Arca.TurnStorage.bind_child!(
               Cyfr.Actor.in_athanor(athanor_id),
               step_id,
               generation,
               execution.id
             ) != 1,
             do: Arca.Repo.rollback(:step_superseded)

        nil ->
          :ok
      end

      case Keyword.get(opts, :parent_attempt) do
        parent_attempt when is_binary(parent_attempt) ->
          parent_id = Map.fetch!(attrs, :parent_execution_id)

          if Arca.ExecutionAttempts.hold_for_child!(
               Cyfr.Actor.in_athanor(athanor_id),
               parent_id,
               parent_attempt,
               grant
             ) != 1,
             do: Arca.Repo.rollback(:parent_ended)

        nil ->
          :ok
      end

      commit_payloads!(Keyword.get(opts, :payloads, []), attempt_id)

      case Keyword.get(opts, :occurrence_id) do
        occurrence_id when is_binary(occurrence_id) ->
          if Arca.ScheduleOccurrences.start!(
               Cyfr.Actor.in_athanor(athanor_id),
               occurrence_id,
               execution.id
             ) != 1,
             do: Arca.Repo.rollback(:occurrence_not_claimed)

        nil ->
          :ok
      end

      event =
        Arca.ExecutionEvents.append!(
          Cyfr.Actor.in_athanor(athanor_id),
          execution.id,
          "execution.started",
          data: %{"attempt" => attempt_id}
        )

      %{
        execution: %{execution | current_attempt: attempt_id, event_seq: event.seq},
        attempt: attempt
      }
    end)
    |> duplicate_child_key()
  end

  # A child inherits its parent's stored grant unchanged: the stamp the
  # parent's current attempt carries, never one read from the estate now.
  # arca:db-raise-ok inside the caller's transaction
  defp inherits!(_athanor_id, nil, _grant), do: :ok

  defp inherits!(athanor_id, parent_id, %Cyfr.ExecutionGrant{} = grant) do
    if Arca.ExecutionStanding.stored_of_execution(Cyfr.Actor.in_athanor(athanor_id), parent_id) !=
         grant,
       do: Arca.Repo.rollback(:not_standing)

    :ok
  end

  @doc """
  Records the completion of an execution in the database.

  Uses tenant-scoped lookup when a context is provided.

  The write carries an atomic `status == "running"` precondition, like its
  sibling `mark_failed_if_running/3`: cancel and the finishing runner race
  on this row, and without the guard whichever wrote second won — a
  `cancelled` row overwritten `completed` (with a second terminal event on
  the wire), or a finished run stamped `cancelled` and its output
  discarded. A row that already left `running` answers
  `{:error, :not_running}` and the caller keeps its hands off the wire.

  `opts`: `attempt:` narrows the write to the attempt that owns the row
  (against `current_attempt`), so a finisher whose attempt is no longer
  the row's is refused the same way; `grant:` and `verify:` (required,
  `Arca.ExecutionStanding`) are the completion's standing, asked before
  the row is written: a completion needs a grant that stands. `grant:
  :stored` names the stamp the row's current attempt carries; a row with
  no attempt needs an explicit grant of its own athanor. A row whose
  attempt carries another stamp is refused `{:error, :not_standing}`, the
  check's refusal is answered as itself, and a missing input is
  `{:error, :missing_grant}`; none writes. The attempt row itself is
  closed by `record_end/6`, which every engine completion uses.
  """
  @spec record_complete(Cyfr.Actor.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def record_complete(actor, id, attrs, opts \\ [])

  def record_complete(%Cyfr.Actor{} = actor, id, attrs, opts) when is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.record_complete", fn ->
      case Arca.ExecutionStanding.inputs(opts, fn -> stored_of(actor, id) end) do
        {:ok, %Cyfr.ExecutionGrant{} = grant, verify} ->
          complete_standing(actor, id, attrs, opts, grant, verify)

        {:ok, nil, _verify} ->
          {:error, :missing_grant}

        {:error, :missing_grant} = refused ->
          refused
      end
    end)
    |> Arca.Data.project()
  end

  # The standing first, then the row: the grant is checked before the row
  # is locked by its write, and must be the stamp of the row's attempt.
  # arca:db-raise-ok inside the caller's rescue.
  defp complete_standing(actor, id, attrs, opts, grant, verify) do
    fn ->
      Arca.ExecutionStanding.verify!(grant, verify)

      case row_of(actor, id) do
        nil ->
          Arca.Repo.rollback(:not_found)

        # get_tenant is itself db-rescued: an outage answers a tuple here,
        # and binding it as the row would raise a non-DB error straight
        # through this rescue, reaching the caller as a crash rather than
        # the storage refusal every sibling answers.
        {:error, reason} ->
          Arca.Repo.rollback(reason)

        execution ->
          if execution.athanor_id != grant.athanor_id or not stamped?(execution, grant),
            do: Arca.Repo.rollback(:not_standing)

          changeset = Row.complete_changeset(execution, attrs)
          if not changeset.valid?, do: Arca.Repo.rollback(changeset)

          from(e in Row, where: e.id == ^id, where: e.status == "running")
          |> fenced(Keyword.take(opts, [:attempt]))
          |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
          |> Arca.Repo.update_all(set: Map.to_list(changeset.changes))
          |> case do
            {1, _} -> Ecto.Changeset.apply_changes(changeset)
            {0, _} -> Arca.Repo.rollback(:not_running)
          end
      end
    end
    |> Arca.Repo.locking_transaction()
  end

  # A row with an attempt carries that attempt's stamp; one with none (a
  # `record_start/1` row) has only its athanor to match.
  # arca:db-raise-ok inside the caller's transaction
  defp stamped?(%Row{current_attempt: nil}, _grant), do: true

  defp stamped?(%Row{athanor_id: athanor_id, id: id}, grant),
    do:
      Arca.ExecutionStanding.stored_of_execution(Cyfr.Actor.in_athanor(athanor_id), id) ==
        grant

  @doc """
  Lists recent executions with optional filters.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status
  """
  @spec list(keyword()) :: [map()] | {:error, :database_error}
  def list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.list", fn ->
      limit = Keyword.get(opts, :limit, 20)
      user_id = Keyword.get(opts, :user_id)
      status = Keyword.get(opts, :status)
      athanor_id = Keyword.fetch!(opts, :athanor_id)

      query =
        from(e in Row,
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
        )

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
    |> Arca.Data.project()
  end

  @doc """
  Gets an execution by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering. Any other context is scoped via
  `where_tenant/2`, which raises for a context without an athanor (fail
  closed).
  """
  @spec get_tenant(Cyfr.Actor.t(), String.t()) ::
          map() | nil | {:error, :database_error}
  def get_tenant(%Cyfr.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("Execution.get_tenant", fn -> row_of(actor, id) end)
    |> Arca.Data.project()
  end

  # The row itself, for the writers here that act on it inside their own
  # rescue or transaction.
  # arca:db-raise-ok inside the caller's rescue.
  defp row_of(actor, id) do
    from(e in Row, where: e.id == ^id)
    |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
    |> Arca.Repo.one()
  end

  @doc """
  The executions a request id started, newest first, scoped to the caller's
  athanor.

  Returns execution records associated with an MCP request for
  `mcp_log.correlate`.
  """
  @spec list_by_request(Cyfr.Actor.t(), String.t(), non_neg_integer()) ::
          [map()] | {:error, :database_error}
  def list_by_request(actor, request_id, limit \\ 100)

  def list_by_request(%Cyfr.Actor{} = actor, request_id, limit) when is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_by_request", fn ->
      from(e in Row,
        where: e.request_id == ^request_id,
        order_by: [desc: e.started_at],
        limit: ^limit
      )
      # Scoped to the caller's athanor — no per-user narrowing (members are
      # interchangeable), and no cross-athanor reach for an operator either:
      # only a server-internal context reads unfiltered.
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.all()
    end)
    |> Arca.Data.project()
  end

  @doc """
  How many executions each of `request_ids` started, as a map — the fan-out
  count `mcp_log.fan_outs` reports. Same tenant scoping as
  `list_by_request/3`.
  """
  @spec count_by_request(Cyfr.Actor.t(), [String.t()]) ::
          %{String.t() => non_neg_integer()} | {:error, :database_error}
  def count_by_request(%Cyfr.Actor{} = actor, request_ids) when is_list(request_ids) do
    Arca.Repo.Errors.with_db_rescue("Execution.count_by_request", fn ->
      case Enum.filter(request_ids, &is_binary/1) do
        [] ->
          %{}

        ids ->
          from(e in Row,
            where: e.request_id in ^ids,
            group_by: e.request_id,
            select: {e.request_id, count(e.id)}
          )
          |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
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
        from(e in Row, where: e.id in ^ids)
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

    from(e in Row,
      where: e.started_at < ^cutoff,
      where: e.status not in ["running", "paused"]
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
      from(e in Row,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    from(e in Row,
      where: e.id not in subquery(keep_ids_query),
      where: e.status not in ["running", "paused"]
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
  @spec list_running_children(String.t()) :: [map()] | {:error, :database_error}
  def list_running_children(parent_execution_id) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_running_children", fn ->
      case Arca.Repo.get(Row, parent_execution_id) do
        %{athanor_id: athanor_id} ->
          from(e in Row,
            where: e.parent_execution_id == ^parent_execution_id,
            where: e.status == "running"
          )
          |> Arca.QueryHelpers.where_athanor(athanor_id)
          |> Arca.Repo.all()

        nil ->
          []
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Fail an execution that is still open, closing its attempt with it.

  System-internal: the `id` originates from trusted runtime state — the
  cancellation cascade (`list_running_children/1`, already tenant-scoped)
  or the `Cyfr.Execution.Sweeper`'s own scan — never from caller-supplied
  input. `fence`: `attempt:` names the attempt being retired (the row's
  current one when absent); `lease_until:` is the lease the sweeper
  observed, and the attempt lapses only if that exact lease still stands,
  so a renewal that landed after the scan matches nothing; `grant:`
  (`:stored` for the current attempt's stamp) and `verify:`
  (`Arca.ExecutionStanding`, required) — a failure retires work, so its
  check need not find the grant standing, but the attempt must carry its
  stamp. Answers `{count, nil}` with the rows failed; `{0, nil}` when the
  check refused or either input was missing.
  """
  def mark_failed_if_running(id, attrs, fence \\ []) when is_binary(id) and is_list(fence) do
    # Fail-open default: a row the store could not fail stays running; the sweep retries next tick.
    Arca.Repo.Errors.with_db_rescue("Execution.mark_failed_if_running", {0, nil}, fn ->
      stored = fn -> stored_of(id) end

      case Arca.ExecutionStanding.inputs(fence, stored) do
        {:ok, grant, verify} -> fail_open(id, attrs, fence, grant, verify)
        {:error, :missing_grant} -> {0, nil}
      end
    end)
  end

  # arca:unscoped-ok the id comes from trusted runtime state (the
  # tenant-scoped cancellation cascade or the sweeper's own scan), never
  # from caller input; the grant names the athanor.
  # arca:db-raise-ok inside the caller's rescue.
  defp stored_of(id) do
    case Arca.Repo.one(from(e in Row, where: e.id == ^id, select: e.athanor_id)) do
      nil ->
        nil

      athanor_id ->
        Arca.ExecutionStanding.stored_of_execution(Cyfr.Actor.in_athanor(athanor_id), id)
    end
  end

  # arca:unscoped-ok the id comes from trusted runtime state, never from
  # caller input; the row read is narrowed to the grant's athanor.
  # arca:db-raise-ok inside the caller's rescue.
  #
  # A `:stored` grant that resolved to nothing is a row that never had an
  # attempt (`record_start/1`, a test helper outside the grant contract):
  # there is no stamp to match and no attempt to retire, so it fails on
  # its status alone. A row with an attempt and no grant fails nothing.
  defp fail_open(id, attrs, fence, grant, verify) do
    Arca.Repo.locking_transaction(fn ->
      if grant, do: Arca.ExecutionStanding.verify!(grant, verify)

      open = from(e in Row, where: e.id == ^id and e.status in ["running", "paused"])

      row =
        if grant,
          do: Arca.Repo.one(from(e in open, where: e.athanor_id == ^grant.athanor_id)),
          else: Arca.Repo.one(open)

      case row do
        nil ->
          {0, nil}

        %Row{} = execution ->
          attempt = Keyword.get(fence, :attempt) || execution.current_attempt

          retired? =
            cond do
              attempt != execution.current_attempt -> false
              is_nil(attempt) -> true
              is_nil(grant) -> false
              true -> retire_attempt(execution, attempt, Keyword.get(fence, :lease_until), grant)
            end

          if retired? do
            {count, _} =
              from(e in Row, where: e.id == ^id and e.status in ["running", "paused"])
              |> Arca.Repo.update_all(
                set: [
                  status: "failed",
                  completed_at: attrs[:completed_at],
                  duration_ms: attrs[:duration_ms],
                  error_message: attrs[:error_message]
                ]
              )

            # The lifecycle row of a run ended from outside: swept
            # (`execution.lapsed`) or failed by its parent's end.
            event =
              Arca.ExecutionEvents.append!(
                Cyfr.Actor.in_athanor(execution.athanor_id),
                id,
                Keyword.get(fence, :event, "execution.failed"),
                data: %{"status" => "failed", "error" => attrs[:error_message]}
              )

            {count, event.seq}
          else
            {0, nil}
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} -> {0, nil}
    end
  end

  @doc """
  End an execution from the attempt that owns it: the attempt closes with
  `outcome`, the row leaves `running`/`paused` as `status`, and the
  lifecycle event (`execution.<status>`, or `execution.result_lost` for
  a completed run whose result was not kept) is appended — its number is
  the answered execution's `event_seq` — in one transaction. `attempt` nil means the row's current attempt (a cancel
  from a read-back record). `{:error, :not_running}` when the row is not
  open or the attempt does not own it.

  `opts` are the grant contract's (`Arca.ExecutionStanding`, required):
  `grant:` (`:stored` for the current attempt's stamp) and `verify:`,
  asked before the row is locked; the owning attempt is closed only when
  it carries the grant's stamp. A completion's check must find the grant
  standing; a failure or a cancel retires work, and its check need not.
  The check's refusal is answered as itself (`{:error, :not_standing}`),
  and a missing input as `{:error, :missing_grant}`; neither writes.
  """
  @spec record_end(Cyfr.Actor.t(), String.t(), String.t(), map(), String.t() | nil, keyword()) ::
          {:ok, map()}
          | {:error,
             :not_running
             | :not_found
             | :database_error
             | :not_standing
             | :unavailable
             | :missing_grant
             | {:payload_not_retained, term()}
             | {:invalid, Arca.Data.field_errors()}}
  def record_end(%Cyfr.Actor{} = actor, id, status, attrs, attempt, opts)
      when status in @terminal_statuses and is_list(opts) do
    # `attrs[:payloads]` are staged payloads committed for the owning
    # attempt in this transaction; `attrs[:outcome]` names the attempt's
    # outcome when it is not the status's own; `attrs[:event]` is data the
    # lifecycle event carries besides the status.
    Arca.Repo.Errors.with_db_rescue("Execution.record_end", fn ->
      case Arca.ExecutionStanding.inputs(opts, fn -> stored_of(actor, id) end) do
        {:ok, grant, verify} -> end_owned(actor, id, status, attrs, attempt, grant, verify)
        {:error, :missing_grant} = refused -> refused
      end
    end)
    |> Arca.Data.project()
  end

  # The stamp of the current attempt of an execution the actor may read.
  # arca:db-raise-ok inside the caller's rescue.
  defp stored_of(actor, id) do
    case row_of(actor, id) do
      %Row{athanor_id: athanor_id} ->
        Arca.ExecutionStanding.stored_of_execution(Cyfr.Actor.in_athanor(athanor_id), id)

      _none ->
        nil
    end
  end

  # A `:stored` grant that resolved to nothing is a row that never had an
  # attempt (`record_start/1`, a test helper outside the grant contract):
  # it may fail or be cancelled on its status alone, and never complete.
  # arca:db-raise-ok inside the caller's rescue.
  defp end_owned(actor, id, status, attrs, attempt, grant, verify) do
    Arca.Repo.locking_transaction(fn ->
      if grant, do: Arca.ExecutionStanding.verify!(grant, verify)

      execution =
        from(e in Row, where: e.id == ^id and e.status in ["running", "paused"])
        |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
        |> Arca.Repo.one()

      if is_nil(execution), do: Arca.Repo.rollback(:not_running)
      owner = attempt || execution.current_attempt
      if owner != execution.current_attempt, do: Arca.Repo.rollback(:not_running)

      changeset = Row.complete_changeset(execution, Map.put(attrs, :status, status))
      if not changeset.valid?, do: Arca.Repo.rollback(changeset)

      {attempt_state, outcome} = attempt_end(status, Map.get(attrs, :outcome))

      if grant && execution.athanor_id != grant.athanor_id,
        do: Arca.Repo.rollback(:not_standing)

      if is_nil(grant) and (is_binary(owner) or status == "completed"),
        do: Arca.Repo.rollback(:missing_grant)

      if owner &&
           is_nil(
             Arca.ExecutionAttempts.close!(
               Cyfr.Actor.in_athanor(execution.athanor_id),
               owner,
               attempt_state,
               outcome,
               grant
             )
           ),
         do: Arca.Repo.rollback(stamp_refusal(execution.athanor_id, owner, grant))

      commit_payloads!(Map.get(attrs, :payloads, []), owner)

      {1, _} =
        from(e in Row, where: e.id == ^id and e.status in ["running", "paused"])
        |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
        |> Arca.Repo.update_all(set: Map.to_list(changeset.changes))

      event =
        Arca.ExecutionEvents.append!(
          Cyfr.Actor.in_athanor(execution.athanor_id),
          id,
          lifecycle_type(status, Map.get(attrs, :outcome)),
          data:
            %{
              "status" => status,
              "outcome" => outcome,
              "duration_ms" => Map.get(attrs, :duration_ms),
              "error" => Map.get(attrs, :error_message)
            }
            |> Map.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.merge(Map.get(attrs, :event, %{}))
        )

      %{Ecto.Changeset.apply_changes(changeset) | event_seq: event.seq}
    end)
  end

  # Why the owning attempt did not close: a stamp other than the grant's
  # is `:not_standing`, any other miss the row not being open.
  # arca:db-raise-ok inside the caller's transaction
  defp stamp_refusal(athanor_id, attempt, grant) do
    case Arca.ExecutionStanding.stored(Cyfr.Actor.in_athanor(athanor_id), attempt) do
      %Cyfr.ExecutionGrant{} = stamp when stamp != grant -> :not_standing
      _ -> :not_running
    end
  end

  # The lifecycle event a terminal write appends; a completed run whose
  # result was lost is its own kind.
  defp lifecycle_type("failed", "result_lost"), do: "execution.result_lost"
  defp lifecycle_type(status, _outcome), do: "execution." <> status

  @doc "The execution's durable event counter, within the athanor."
  @spec event_seq(Cyfr.Actor.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def event_seq(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Execution.event_seq", fn ->
      case Arca.Repo.one(
             from(e in Row,
               where: e.id == ^id and e.athanor_id == ^athanor_id,
               select: e.event_seq
             )
           ) do
        nil -> {:error, :not_found}
        seq -> {:ok, seq}
      end
    end)
  end

  def event_seq(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  # Staged payloads join the transaction as the attempt's rows; one the
  # store refuses rolls the whole write back.
  # arca:db-raise-ok inside the caller's transaction
  defp commit_payloads!(staged, attempt) do
    for payload <- staged, not is_nil(payload) do
      try do
        Arca.ExecutionPayloads.commit!(payload, attempt)
      rescue
        e -> Arca.Repo.rollback({:payload_not_retained, Exception.message(e)})
      end
    end

    :ok
  end

  defp attempt_end("completed", outcome), do: {"completed", outcome || "ok"}
  defp attempt_end("failed", outcome), do: {"failed", outcome || "error"}
  defp attempt_end("cancelled", outcome), do: {"cancelled", outcome || "cancelled"}

  # Retire the owning attempt, stamped with `grant`: on the lease the
  # sweeper observed when one is given (a renewal since matches nothing),
  # else as failed.
  # arca:db-raise-ok inside the caller's transaction
  defp retire_attempt(_execution, attempt, %DateTime{} = seen, grant) do
    is_integer(Arca.ExecutionAttempts.lapse!(attempt, seen, grant))
  end

  defp retire_attempt(execution, attempt, nil, grant) do
    not is_nil(
      Arca.ExecutionAttempts.close!(
        Cyfr.Actor.in_athanor(execution.athanor_id),
        attempt,
        "failed",
        "error",
        grant
      )
    )
  end

  # Fence a write on the attempt that owns the row. A nil attempt adds no
  # fence: cancellation then checks status alone.
  defp fenced(query, fence) do
    Enum.reduce(fence, query, fn
      {_key, nil}, q -> q
      {:attempt, attempt}, q -> where(q, [e], e.current_attempt == ^attempt)
      {_other, _}, q -> q
    end)
  end

  @doc """
  Executions whose current attempt is running with a lease lapsed before
  `now` (the sweep), each as the row's map with the attempt's `attempt`,
  `athanor_generation`, `service_id`, `boot_id`, `claimed_by` and
  `lease_until` beside it.

  Intentionally spans all tenants: the `Cyfr.Execution.Sweeper` GC must reap
  orphaned rows left by a crashed runner — this node's or another
  node's — when no tenant context can be reconstructed. System-internal
  only — not reachable from a tenant request.
  """
  @spec list_stale_running(DateTime.t(), pos_integer()) :: [map()]
  def list_stale_running(now, limit \\ 50) do
    # Fail-open default: an unreadable store sweeps nothing this tick; the next tick retries.
    Arca.Repo.Errors.with_db_rescue("Execution.list_stale_running", [], fn ->
      # arca:unscoped-ok the sweeper reaps orphaned rows across all tenants
      # when no tenant context can be reconstructed — system-internal only.
      from(a in Arca.Schemas.ExecutionAttempt,
        join: e in Row,
        on: e.id == a.execution_id and e.current_attempt == a.attempt,
        where: a.state == "running" and a.lease_until < ^now,
        where: e.status == "running",
        order_by: [asc: a.lease_until],
        limit: ^limit,
        select: {e, a}
      )
      |> Arca.Repo.all()
      |> Enum.map(&attempt_row/1)
    end)
    |> Arca.Data.project()
  end

  @doc """
  The running executions whose current attempt is one of `attempts`,
  running, dispatched to the worker service `service_id` on its boot
  `boot_id` and, when `runner` is given, claimed by that runner, in the
  shape `list_stale_running/2` answers. Spans every tenant: the ids come
  from a verified worker service report or from an attempt's own state,
  never from a request. `{:error, :database_error}` when the store cannot
  answer.
  """
  @spec list_running_dispatched([String.t()], String.t() | nil, String.t(), String.t() | nil) ::
          [map()] | {:error, :database_error}
  def list_running_dispatched(attempts, service_id, boot_id, runner)
      when is_list(attempts) and (is_binary(service_id) or is_nil(service_id)) and
             is_binary(boot_id) and (is_binary(runner) or is_nil(runner)) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_running_dispatched", fn ->
      # arca:unscoped-ok a runner's attempts are lapsed across tenants when
      # its worker service reports its exit; the ids are the report's.
      query =
        from(a in Arca.Schemas.ExecutionAttempt,
          join: e in Row,
          on: e.id == a.execution_id and e.current_attempt == a.attempt,
          where: a.attempt in ^attempts and a.boot_id == ^boot_id,
          where: a.state == "running" and e.status == "running",
          select: {e, a}
        )

      query =
        if is_nil(service_id),
          do: where(query, [a], is_nil(a.service_id)),
          else: where(query, [a], a.service_id == ^service_id)

      query = if is_nil(runner), do: query, else: where(query, [a], a.claimed_by == ^runner)

      query
      |> Arca.Repo.all()
      |> Enum.map(&attempt_row/1)
    end)
    |> Arca.Data.project()
  end

  defp attempt_row({execution, attempt}) do
    execution
    |> Arca.Data.project()
    |> Map.merge(%{
      attempt: attempt.attempt,
      athanor_generation: attempt.athanor_generation,
      service_id: attempt.service_id,
      boot_id: attempt.boot_id,
      claimed_by: attempt.claimed_by,
      lease_until: attempt.lease_until
    })
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
