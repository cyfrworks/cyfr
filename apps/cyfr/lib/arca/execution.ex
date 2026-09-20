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
  # Every function that names a tenant takes the `Cyfr.Actor` first. The
  # record readers and the lifecycle writes branch on `scope` through
  # `Arca.QueryHelpers.where_tenant_unless_platform/2` — a platform-scope
  # actor reads across athanors and legitimately carries none, so they
  # match the actor and let the backstop raise for an athanor-scope actor
  # with no athanor rather than guarding a resolved one in the head. The
  # sweeps and the retention primitives carry no actor and say why where
  # they stand.

  # The execution lifecycle vocabulary, in one place like its sibling
  # stores. A row starts "running" and ends in exactly one of the
  # terminal three.
  @statuses ~w(running paused completed failed cancelled)
  # What a row is: a component run, a host loop's logical turn root, or an
  # outbound tool call.
  @kinds ~w(component turn tool_call)
  @terminal_statuses ~w(completed failed cancelled)

  @doc "Every status an execution row can carry."
  def statuses, do: @statuses

  @doc "The statuses a finished execution can carry."
  def terminal_statuses, do: @terminal_statuses

  @doc "Every kind an execution row can carry."
  def kinds, do: @kinds

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
    # The key the parent's runner minted for this child (`Cyfr.HostAPI`
    # `t:child_key/0`): unique under the parent, so a retried admission is
    # answered with this row (`child_by_key/3`). Nil for a root.
    field :child_key, :string
    field :root_execution_id, :string
    field :resolver_digest, :string
    field :activation_digest, :string
    field :activation_graph, :string
    # Which consent this execution rooted under: stamped by every root —
    # `run_root/5` and a `run_root_edge/5` tincture ingress alike — and nil
    # for a child row, which walks its parent's authority rather than
    # rooting one. The row is the SSOT: a caller that needs the turn's
    # authority again — an approval, an audit — reads it here instead of
    # re-deriving a selection that may since have become ambiguous.
    field :profile_id, :string
    # What the row is: a `component` run, the logical `turn` root a host
    # loop holds without a guest, or an outbound `tool_call`. A turn root's
    # `component_type` is `agent`.
    field :kind, :string, default: "component"
    # The turn or schedule this execution belongs to.
    field :turn_id, :string
    field :schedule_id, :string
    # The attempt that owns the row (`Arca.ExecutionAttempts`): every
    # attempt-scoped write names it, and a successor moves it in the same
    # transaction that retires the predecessor.
    field :current_attempt, :string
    # The durable event counter: `Arca.ExecutionEvents` allocates a seq by
    # incrementing it inside the writer's transaction.
    field :event_seq, :integer, default: 0
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
    :child_key,
    :root_execution_id,
    :resolver_digest,
    :activation_digest,
    :activation_graph,
    :profile_id,
    :kind,
    :turn_id,
    :schedule_id,
    :current_attempt,
    :event_seq
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
    |> validate_inclusion(:kind, @kinds)
    |> validate_component_type()
    |> validate_child_key()
  end

  # A child key is the wire's shape and belongs to a child: a root carries
  # none. The unique index decides the race between two admissions of one
  # key; `duplicate_child_key/1` names its loss.
  defp validate_child_key(changeset) do
    case get_field(changeset, :child_key) do
      nil ->
        changeset

      key ->
        changeset
        |> validate_change(:child_key, fn :child_key, _key ->
          if Cyfr.HostAPI.valid_child_key?(key), do: [], else: [child_key: "is malformed"]
        end)
        |> validate_required([:parent_execution_id])
        |> unique_constraint(:child_key,
          name: :executions_athanor_id_parent_execution_id_child_key_index
        )
    end
  end

  @doc """
  The child of `parent_execution_id` admitted under `child_key`, scoped to
  the caller's athanor: `{:ok, row}`, or `:none` when no child carries
  that key.
  """
  @spec child_by_key(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, struct()} | :none | {:error, :database_error}
  def child_by_key(%Cyfr.Actor{} = actor, parent_execution_id, child_key)
      when is_binary(parent_execution_id) and
             is_binary(child_key) do
    Arca.Repo.Errors.with_db_rescue("Execution.child_by_key", fn ->
      from(e in __MODULE__,
        where: e.parent_execution_id == ^parent_execution_id and e.child_key == ^child_key
      )
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
      |> case do
        nil -> :none
        row -> {:ok, row}
      end
    end)
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

  # Which component types exist is product vocabulary — sourced from the
  # canonical list rather than re-declared in the persistence layer.
  # Tinctures never execute server-side, hence executable_types. A turn
  # root is an `agent` (a consent source, never a component) and an
  # outbound tool call a `tool_server`; both are row-level types.
  defp validate_component_type(changeset) do
    case get_field(changeset, :kind) do
      "turn" -> validate_inclusion(changeset, :component_type, ["agent"])
      "tool_call" -> validate_inclusion(changeset, :component_type, ["tool_server"])
      _ -> validate_inclusion(changeset, :component_type, Cyfr.ComponentRef.executable_types())
    end
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
      |> duplicate_child_key()
    end)
  end

  @doc """
  Whether `reason` is the refusal of one of `admit/2`'s barriers: an
  expired hold, a superseded step, a parent that ended or an occurrence
  not claimed.
  """
  @spec barrier_refusal?(term()) :: boolean()
  def barrier_refusal?(reason),
    do: reason in [:hold_expired, :step_superseded, :parent_ended, :occurrence_not_claimed]

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

  Answers `{:ok, %{execution: t(), attempt: ExecutionAttempt.t()}}`; the
  execution's `event_seq` is the number of the `execution.started` event
  the transaction appended, for the caller to publish. A barrier's refusal
  (`barrier_refusal?/1`) writes nothing, and neither does a row whose
  `child_key` another child of the same parent already carries:
  `{:error, :duplicate_child_key}`, for the caller to answer with that
  child (`child_by_key/3`).
  """
  @spec admit(map(), keyword()) ::
          {:ok, %{execution: struct(), attempt: struct()}} | {:error, term()}
  def admit(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.admit", fn ->
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

      Arca.Repo.transaction(fn ->
        execution =
          case Arca.Repo.insert(start_changeset(attrs)) do
            {:ok, row} -> row
            {:error, changeset} -> Arca.Repo.rollback(changeset)
          end

        attempt =
          Arca.ExecutionAttempts.open!(Cyfr.Actor.in_athanor(athanor_id), execution.id,
            attempt: attempt_id,
            service_id: Keyword.get(opts, :service_id),
            boot_id: boot_id,
            lease_until: lease_until,
            started_at: started_at
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
                 parent_attempt
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
    end)
  end

  @doc """
  Close an execution that is still open — `running` or `paused` — as
  `status`, fenced on `current_attempt` when `attempt` is given. A row
  already closed matches nothing. Answers the rows moved.
  """
  @spec mark_terminal_if_open(String.t(), String.t(), map(), String.t() | nil) ::
          non_neg_integer() | {:error, :database_error}
  def mark_terminal_if_open(id, status, attrs, attempt \\ nil)
      when status in @terminal_statuses do
    Arca.Repo.Errors.with_db_rescue("Execution.mark_terminal_if_open", fn ->
      # arca:unscoped-ok the id comes from trusted runtime state (the turn
      # root the runner holds), never from caller input.
      query = from(e in __MODULE__, where: e.id == ^id and e.status in ["running", "paused"])
      query = if attempt, do: where(query, [e], e.current_attempt == ^attempt), else: query

      {count, _} =
        Arca.Repo.update_all(query,
          set: [
            status: status,
            completed_at: attrs[:completed_at] || DateTime.utc_now(),
            duration_ms: attrs[:duration_ms],
            error_message: attrs[:error_message]
          ]
        )

      count
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

  `fence` narrows the write to the attempt that owns the row
  (`attempt:` against `current_attempt`): a finisher whose attempt is no
  longer the row's is refused the same way. The attempt row itself is
  closed by `record_end/5`, which every engine completion uses.
  """
  def record_complete(actor, id, attrs, fence \\ [])

  def record_complete(%Cyfr.Actor{} = actor, id, attrs, fence) do
    Arca.Repo.Errors.with_db_rescue("Execution.record_complete", fn ->
      case get_tenant(actor, id) do
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
            |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
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
  @spec get_tenant(Cyfr.Actor.t(), String.t()) ::
          %__MODULE__{} | nil | {:error, :database_error}
  def get_tenant(%Cyfr.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("Execution.get_tenant", fn ->
      from(e in __MODULE__, where: e.id == ^id)
      |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
      |> Arca.Repo.one()
    end)
  end

  @doc """
  The executions a request id started, newest first, scoped to the caller's
  athanor.

  Returns execution records associated with an MCP request for
  `mcp_log.correlate`.
  """
  @spec list_by_request(Cyfr.Actor.t(), String.t(), non_neg_integer()) ::
          [%__MODULE__{}] | {:error, :database_error}
  def list_by_request(actor, request_id, limit \\ 100)

  def list_by_request(%Cyfr.Actor{} = actor, request_id, limit) when is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Execution.list_by_request", fn ->
      from(e in __MODULE__,
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
          from(e in __MODULE__,
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
      from(e in __MODULE__,
        order_by: [desc: e.started_at],
        limit: ^keep,
        select: e.id
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    from(e in __MODULE__,
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
  Fail an execution that is still open, closing its attempt with it.

  System-internal: the `id` originates from trusted runtime state — the
  cancellation cascade (`list_running_children/1`, already tenant-scoped)
  or the `Cyfr.Execution.Sweeper`'s own scan — never from caller-supplied
  input. `fence`: `attempt:` names the attempt being retired (the row's
  current one when absent); `lease_until:` is the lease the sweeper
  observed, and the attempt lapses only if that exact lease still stands,
  so a renewal that landed after the scan matches nothing. Answers
  `{count, nil}` with the rows failed.
  """
  def mark_failed_if_running(id, attrs, fence \\ []) do
    # Fail-open default: a row the store could not fail stays running; the sweep retries next tick.
    Arca.Repo.Errors.with_db_rescue("Execution.mark_failed_if_running", {0, nil}, fn ->
      # arca:unscoped-ok the id comes from trusted runtime state (the
      # tenant-scoped cancellation cascade or the sweeper's own scan), never
      # from caller input — see the doc above.
      Arca.Repo.transaction(fn ->
        row =
          Arca.Repo.one(
            from(e in __MODULE__, where: e.id == ^id and e.status in ["running", "paused"])
          )

        case row do
          nil ->
            {0, nil}

          %__MODULE__{} = execution ->
            attempt = Keyword.get(fence, :attempt) || execution.current_attempt

            retired? =
              cond do
                attempt != execution.current_attempt -> false
                is_nil(attempt) -> true
                true -> retire_attempt(execution, attempt, Keyword.get(fence, :lease_until))
              end

            if retired? do
              {count, _} =
                from(e in __MODULE__, where: e.id == ^id and e.status in ["running", "paused"])
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
    end)
  end

  @doc """
  End an execution from the attempt that owns it: the attempt closes with
  `outcome`, the row leaves `running`/`paused` as `status`, and the
  lifecycle event (`execution.<status>`, or `execution.result_lost` for
  a completed run whose result was not kept) is appended — its number is
  the answered execution's `event_seq` — in one transaction. `attempt` nil means the row's current attempt (a cancel
  from a read-back record). `{:error, :not_running}` when the row is not
  open or the attempt does not own it.
  """
  @spec record_end(Cyfr.Actor.t(), String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, %__MODULE__{}}
          | {:error,
             :not_running
             | :not_found
             | :database_error
             | {:payload_not_retained, term()}
             | Ecto.Changeset.t()}
  def record_end(%Cyfr.Actor{} = actor, id, status, attrs, attempt)
      when status in @terminal_statuses do
    # `attrs[:payloads]` are staged payloads committed for the owning
    # attempt in this transaction; `attrs[:outcome]` names the attempt's
    # outcome when it is not the status's own; `attrs[:event]` is data the
    # lifecycle event carries besides the status.
    Arca.Repo.Errors.with_db_rescue("Execution.record_end", fn ->
      Arca.Repo.transaction(fn ->
        execution =
          from(e in __MODULE__, where: e.id == ^id and e.status in ["running", "paused"])
          |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
          |> Arca.Repo.one()

        if is_nil(execution), do: Arca.Repo.rollback(:not_running)
        owner = attempt || execution.current_attempt
        if owner != execution.current_attempt, do: Arca.Repo.rollback(:not_running)

        changeset = complete_changeset(execution, Map.put(attrs, :status, status))
        if not changeset.valid?, do: Arca.Repo.rollback(changeset)

        {attempt_state, outcome} = attempt_end(status, Map.get(attrs, :outcome))

        if owner &&
             is_nil(
               Arca.ExecutionAttempts.close!(
                 Cyfr.Actor.in_athanor(execution.athanor_id),
                 owner,
                 attempt_state,
                 outcome
               )
             ),
           do: Arca.Repo.rollback(:not_running)

        commit_payloads!(Map.get(attrs, :payloads, []), owner)

        {1, _} =
          from(e in __MODULE__, where: e.id == ^id and e.status in ["running", "paused"])
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
    end)
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
             from(e in __MODULE__,
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

  # Retire the owning attempt: on the lease the sweeper observed when one
  # is given (a renewal since matches nothing), else as failed.
  # arca:db-raise-ok inside the caller's transaction
  defp retire_attempt(_execution, attempt, %DateTime{} = seen) do
    match?({:ok, ran} when is_integer(ran), Arca.ExecutionAttempts.lapse(attempt, seen))
  end

  defp retire_attempt(execution, attempt, nil) do
    not is_nil(
      Arca.ExecutionAttempts.close!(
        Cyfr.Actor.in_athanor(execution.athanor_id),
        attempt,
        "failed",
        "error"
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
  `service_id`, `boot_id`, `claimed_by` and `lease_until` beside it.

  Intentionally spans all tenants: the `Cyfr.Execution.Sweeper` GC must reap
  orphaned rows left by a crashed runner — this node's or another
  node's — when no tenant context can be reconstructed. System-internal
  only — not reachable from a tenant request.
  """
  def list_stale_running(now, limit \\ 50) do
    # Fail-open default: an unreadable store sweeps nothing this tick; the next tick retries.
    Arca.Repo.Errors.with_db_rescue("Execution.list_stale_running", [], fn ->
      # arca:unscoped-ok the sweeper reaps orphaned rows across all tenants
      # when no tenant context can be reconstructed — system-internal only.
      from(a in Arca.Schemas.ExecutionAttempt,
        join: e in __MODULE__,
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
          join: e in __MODULE__,
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
  end

  defp attempt_row({execution, attempt}) do
    execution
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Map.merge(%{
      attempt: attempt.attempt,
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
