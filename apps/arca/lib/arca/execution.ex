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

  # Every function that names a tenant takes the `Prima.Actor` first. The
  # record readers and the lifecycle writes branch on `scope` through
  # `Arca.QueryHelpers.where_tenant_unless_platform/2` — a platform-scope
  # actor reads across athanors and legitimately carries none, so they
  # match the actor and let the backstop raise for an athanor-scope actor
  # with no athanor rather than guarding a resolved one in the head. The
  # sweeps and the retention primitives carry no actor and say why where
  # they stand.

  @terminal_statuses Row.terminal_statuses()
  @open_statuses Prima.ExecutionState.open_statuses()
  @fields Row.__schema__(:fields)

  # The outcomes an ended execution's attempt may close with, by the
  # status it ends in: a completion is `ok` and a cancel `cancelled`; a
  # failure is an error, an effect that may have landed (`uncertain`), or
  # a completed run whose result could not be kept (`result_lost`). The
  # first of each is the status's own.
  @end_outcomes %{
    "completed" => ["ok"],
    "failed" => ["error", "uncertain", "result_lost"],
    "cancelled" => ["cancelled"]
  }

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
  @spec child_by_key(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | :none | {:error, :database_error}
  def child_by_key(%Prima.Actor{} = actor, parent_execution_id, child_key)
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
  Whether `reason` is the refusal of one of `admit/2`'s barriers: an
  expired hold, a superseded step, a parent that ended, an occurrence not
  claimed, a grant whose athanor no longer stands at its generation, an
  admission that named no grant, or a member that no longer holds its
  slot when the admission checks it in its own transaction (`:not_owner`).
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
        :missing_grant,
        :not_owner
      ]

  @doc """
  Admit an execution: the row, its first attempt and, for a root, its
  budget reservation, in one transaction. `attrs` are the start
  changeset's. A root records the `:origin` its caller names
  (`Prima.Origin`, an atom or its wire spelling), and a root naming none
  is refused `{:error, :no_origin}`; a child's row carries its parent's
  origin, read in the admitting transaction, a child naming another is
  refused `{:error, :origin_mismatch}`, and a child of a parent that
  records none `{:error, :no_origin}`, each with nothing written. `opts`:

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
    `{:error, :parent_ended}` otherwise. The barrier applies to every row
    that names a parent: without the option it holds the parent's current
    attempt, read in the transaction.
  - `:payloads` — staged payloads (`Arca.ExecutionPayloads.Staged`)
    committed for the attempt in the same transaction; one that cannot
    be kept refuses admission `{:error, {:payload_not_retained, why}}`.
  - `:occurrence_id` — the schedule occurrence this root runs; it moves
    from `claimed` to `started` in the same transaction, only while this
    boot (`Prima.Boot.id/0`, the boot the scheduler claims as) is its
    claimant (`Arca.ScheduleOccurrences.start!/4`). Admission is refused
    `{:error, :occurrence_not_claimed}` when it is not claimed, or is
    claimed by another boot since a recoverer took it over, so a stale
    claimant's slow admission starts nothing. A row that names a
    `schedule_id` runs an occurrence, and is refused the same way
    without one.
  - `:reaches_outside` — the run was admitted with egress (its caller's
    reading of its own edge): its tree's root, itself for a root, is
    marked in the same transaction (`reached_outside/2`).

  The row's source ledger (`sources/2`) is seeded in the same
  transaction. A root's is the `:sources` attr its admission path names
  (`Prima.Source`s), absent read as none: the path above this module
  states every root's seed. A child's is its parent's ledger as it stands
  in the transaction — for a child of a turn root, the sources of the turn
  its `:step` belongs to, or of every turn on that root when it names no
  step — joined by any `:sources` its admission names, which are joined
  into its ancestors' ledgers in the same transaction (`join_sources/3`),
  as a tool-server call's server is before the call leaves. The seed is
  also the `execution.started` event's `sources`, for audit.
  - `:grant` and `:verify` (required, `Arca.ExecutionStanding`) — the
    `Prima.ExecutionGrant` the attempt is stamped with and the caller's
    check over it, asked first in the transaction, before any row is
    written or locked. A root's grant is its athanor's standing read at
    admission; a child's must be the stamp its parent's current attempt
    carries, and one that is not is refused `{:error, :not_standing}`.
    The check's refusal is answered as itself; an admission missing
    either is `{:error, :missing_grant}`.

  The member's slot is the last barrier. After the last lock the
  transaction takes (the occurrence's start) and before the
  `execution.started` event is appended, it reads the slot this member
  believes it holds (`Arca.ControlPlane.member_slot/0`) and verifies it on
  the database (`Arca.ControlPlane.verify_held/1`): a member whose slot was
  taken over, even while the transaction waited on a lock, admits nothing
  and is refused `{:error, :not_owner}`. Where no claimant runs the slot
  is `:none` and the check passes.

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
        {:ok, %Prima.ExecutionGrant{athanor_id: ^athanor_id} = grant, verify} ->
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
    boot_id = Keyword.get(opts, :boot_id) || Prima.Boot.id()
    lease_until = Keyword.get(opts, :lease_until) || Arca.ExecutionAttempts.lease_until()
    started_at = Map.get(attrs, :started_at) || DateTime.utc_now()

    attrs =
      attrs
      |> Map.put(:started_at, started_at)
      |> Map.put(:status, "running")
      |> Map.put(:current_attempt, attempt_id)

    Arca.Repo.locking_transaction(fn ->
      # The athanor's standing first, before any execution or attempt row
      # is written or locked; a child's grant is its parent's stamp.
      Arca.ExecutionStanding.verify!(grant, verify)

      # A run admitted with egress marks its tree's root below. The root's
      # execution row is locked here, before any attempt row is — the
      # parent's, which `hold_for_child!` takes, among them — in the
      # execution-then-attempt order every execution write keeps
      # (`Arca.ExecutionAttempts.takeover!/3`), so the admission and a
      # takeover of the root never wait on each other in opposite order. A
      # root admitted with egress holds its own row from its insert.
      root = if Keyword.get(opts, :reaches_outside, false), do: lock_root!(athanor_id, attrs)

      inherits!(athanor_id, Map.get(attrs, :parent_execution_id), grant)
      attrs = origin!(athanor_id, attrs)
      attrs = seed!(athanor_id, attrs, Keyword.get(opts, :step))

      execution =
        case Arca.Repo.insert(Row.start_changeset(attrs)) do
          {:ok, row} -> row
          {:error, changeset} -> Arca.Repo.rollback(changeset)
        end

      attempt =
        Arca.ExecutionAttempts.open!(Prima.Actor.in_athanor(athanor_id), execution.id,
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
            Prima.Actor.in_athanor(athanor_id),
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
               Prima.Actor.in_athanor(athanor_id),
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
               Prima.Actor.in_athanor(athanor_id),
               step_id,
               generation,
               execution.id
             ) != 1,
             do: Arca.Repo.rollback(:step_superseded)

        nil ->
          :ok
      end

      # The barriers a row's own columns call for apply whether or not the
      # caller declared them: a child is held against its parent, and a
      # scheduled root against its occurrence.
      case {execution.parent_execution_id, Keyword.get(opts, :parent_attempt)} do
        {nil, nil} ->
          :ok

        {parent_id, parent_attempt} when is_binary(parent_id) ->
          parent_attempt = parent_attempt || current_attempt_of(athanor_id, parent_id)

          if is_nil(parent_attempt) or
               Arca.ExecutionAttempts.hold_for_child!(
                 Prima.Actor.in_athanor(athanor_id),
                 parent_id,
                 parent_attempt,
                 grant
               ) != 1,
             do: Arca.Repo.rollback(:parent_ended)

        {nil, _declared} ->
          Arca.Repo.rollback(:parent_ended)
      end

      case root do
        nil -> :ok
        :own -> reaches_outside!(athanor_id, execution.id, execution.host_policy)
        {root_id, policy} -> reaches_outside!(athanor_id, root_id, policy)
        :gone -> :ok
      end

      commit_payloads!(Keyword.get(opts, :payloads, []), attempt_id)

      case {execution.schedule_id, Keyword.get(opts, :occurrence_id)} do
        {nil, nil} ->
          :ok

        {_schedule, occurrence_id} when is_binary(occurrence_id) ->
          if Arca.ScheduleOccurrences.start!(
               Prima.Actor.in_athanor(athanor_id),
               occurrence_id,
               Prima.Boot.id(),
               execution.id
             ) != 1,
             do: Arca.Repo.rollback(:occurrence_not_claimed)

        {_schedule, nil} ->
          Arca.Repo.rollback(:occurrence_not_claimed)
      end

      # The member's slot, checked on the database after the last lock
      # this transaction takes and before its event: the cached standing
      # its caller passed is never the authority, and a takeover that
      # committed while this transaction waited refuses it here.
      slot_held!()

      event =
        Arca.ExecutionEvents.append!(
          Prima.Actor.in_athanor(athanor_id),
          execution.id,
          "execution.started",
          data: %{
            "attempt" => attempt_id,
            "sources" => execution.sources |> ledger_text() |> Prima.Source.to_json_list()
          }
        )

      %{
        execution: %{execution | current_attempt: attempt_id, event_seq: event.seq},
        attempt: attempt
      }
    end)
    |> duplicate_child_key()
  end

  # The slot this member believes it holds, verified on the database inside
  # the admission's transaction (`Arca.ControlPlane.verify_held/1`, a
  # shared lock on the lease row until the transaction ends): a member
  # that holds none admits nothing.
  # arca:db-raise-ok inside the caller's transaction
  defp slot_held! do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(),
         :ok <- Arca.ControlPlane.verify_held(slot) do
      :ok
    else
      _not_held -> Arca.Repo.rollback(:not_owner)
    end
  end

  # The attempt that owns `parent_id` now, read in the admission's
  # transaction: the one a child that declared none is held against.
  # arca:db-raise-ok inside the caller's transaction
  defp current_attempt_of(athanor_id, parent_id) do
    Arca.Repo.one(
      from(e in Row,
        where: e.athanor_id == ^athanor_id and e.id == ^parent_id,
        select: e.current_attempt
      )
    )
  end

  # A root records the origin its caller names; a child carries its
  # parent's, read in the admitting transaction, and one naming another is
  # refused. No default stands in for an origin: a root naming none, or a
  # child of a parent that records none, is refused.
  # arca:db-raise-ok inside the caller's transaction
  defp origin!(athanor_id, attrs) do
    named = spelled_origin(Map.get(attrs, :origin))

    case Map.get(attrs, :parent_execution_id) do
      nil ->
        if is_nil(named), do: Arca.Repo.rollback(:no_origin), else: attrs

      parent_id ->
        parent_origin =
          Arca.Repo.one(
            from(e in Row,
              where: e.athanor_id == ^athanor_id and e.id == ^parent_id,
              select: e.origin
            )
          )

        cond do
          is_nil(parent_origin) -> Arca.Repo.rollback(:no_origin)
          is_nil(named) or named == parent_origin -> Map.put(attrs, :origin, parent_origin)
          true -> Arca.Repo.rollback(:origin_mismatch)
        end
    end
  end

  defp spelled_origin(origin) when is_atom(origin) and not is_nil(origin) do
    if Prima.Origin.origin?(origin), do: Prima.Origin.to_wire(origin), else: origin
  end

  defp spelled_origin(origin), do: origin

  # A child inherits its parent's stored grant unchanged: the stamp the
  # parent's current attempt carries, never one read from the athanor now.
  # arca:db-raise-ok inside the caller's transaction
  defp inherits!(_athanor_id, nil, _grant), do: :ok

  defp inherits!(athanor_id, parent_id, %Prima.ExecutionGrant{} = grant) do
    if Arca.ExecutionStanding.stored_of_execution(Prima.Actor.in_athanor(athanor_id), parent_id) !=
         grant,
       do: Arca.Repo.rollback(:not_standing)

    :ok
  end

  # Whether `outcome` (nil for the status's own) is one an execution ending
  # in `status` may close its attempt with.
  defp outcome_allowed?(_status, nil), do: true
  defp outcome_allowed?(status, outcome), do: outcome in Map.get(@end_outcomes, status, [])

  @doc """
  Lists the recent executions of the actor's athanor, newest first, with
  optional filters. An actor without an athanor is `{:error, :no_athanor}`.

  Options:
  - `:limit` - Maximum records to return (default: 20)
  - `:user_id` - Filter by user ID
  - `:status` - Filter by status (`Prima.ExecutionState.statuses/0`, or `:all`)
  - `:parent_execution_id` - Filter by parent
  """
  @spec list(Prima.Actor.t(), keyword()) :: [map()] | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id}, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Execution.list", fn -> list_rows(athanor_id, opts) end)
    |> Arca.Data.project()
  end

  def list(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  defp list_rows(athanor_id, opts) do
    limit = Keyword.get(opts, :limit, 20)
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)

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
  end

  @doc """
  Gets an execution by ID, scoped to the given tenant context.

  Platform scope bypasses tenant filtering. Any other context is scoped via
  `where_tenant/2`, which raises for a context without an athanor (fail
  closed).
  """
  @spec get_tenant(Prima.Actor.t(), String.t()) ::
          map() | nil | {:error, :database_error}
  def get_tenant(%Prima.Actor{} = actor, id) do
    Arca.Repo.Errors.with_db_rescue("Execution.get_tenant", fn -> row_of(actor, id) end)
    |> Arca.Data.project()
  end

  # The key of the mark `admit/2` sets on a tree's root.
  @reached_key "tree_reaches_outside"

  @doc """
  Whether a run of the tree rooted at `id` was admitted with egress, as
  `admit/2`'s `:reaches_outside` marked the root: `{:ok, true | false}`,
  read from the root's own row, which retention keeps while it runs, so
  a child pruned before the root ends cannot take the fact with it.
  `{:error, :not_found}` for no root in the caller's athanor, and
  `{:error, :unreadable}` for a root whose `host_policy` is not a JSON
  object: a policy that cannot be read says nothing, never "no egress".

  The mark lives in the root's `host_policy` JSON, beside the policy its
  own admission recorded.
  """
  @spec reached_outside(Prima.Actor.t(), String.t()) ::
          {:ok, boolean()} | {:error, :not_found | term()}
  def reached_outside(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Execution.reached_outside", fn ->
      case row_of(actor, id) do
        nil -> {:error, :not_found}
        %Row{host_policy: policy} -> reached(policy)
      end
    end)
  end

  defp reached(policy) do
    case decoded_policy(policy) do
      {:ok, map} -> {:ok, Map.get(map, @reached_key) == true}
      :error -> {:error, :unreadable}
    end
  end

  @doc """
  A run's source ledger (`Prima.Source`): every class it read, seeded at
  admission and only ever grown (`join_sources/3`). A turn root's ledger
  is its turns' (`Arca.TurnStorage.chain_sources/2`): the root execution
  of a host loop records none of its own. A stored ledger that is absent
  or does not read is one unnamed outside source, never none: provenance
  that cannot be read is not the athanor's own. `{:error, :not_found}`
  for no such row in the caller's athanor.
  """
  @spec sources(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Source.t()]} | {:error, :not_found | :database_error}
  def sources(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Execution.sources", fn ->
      case row_of(actor, id) do
        nil -> {:error, :not_found}
        %Row{} = row -> {:ok, ledger!(row)}
      end
    end)
  end

  # The key of the classes an approved launch let flow, in its root's
  # `host_policy`.
  @launch_key "launch_flows"

  @doc """
  What a send of the run `id` is decided on: its ledger (`sources/2`) and
  the classes the launch that started its tree let flow to every exit of
  that tree (`:launch_classes`, from the root's `host_policy`, written by
  its admission; empty for a tree no launch started or a root no row
  holds). `{:error, :not_found}` for no such row.
  """
  @spec flow_state(Prima.Actor.t(), String.t()) ::
          {:ok, %{sources: [Prima.Source.t()], launch_classes: [Prima.Source.class()]}}
          | {:error, :not_found | :database_error}
  def flow_state(%Prima.Actor{} = actor, id) when is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Execution.flow_state", fn ->
      case row_of(actor, id) do
        nil ->
          {:error, :not_found}

        %Row{} = row ->
          root =
            case row.root_execution_id do
              root_id when is_binary(root_id) and root_id != row.id -> row_of(actor, root_id)
              _own -> row
            end

          {:ok, %{sources: ledger!(row), launch_classes: launch_classes(root)}}
      end
    end)
  end

  defp launch_classes(%Row{host_policy: policy}) do
    with {:ok, map} <- decoded_policy(policy),
         classes when is_list(classes) <- Map.get(map, @launch_key) do
      by_spelling = Map.new(Prima.Source.classes(), &{Atom.to_string(&1), &1})
      for class <- classes, Map.has_key?(by_spelling, class), do: Map.fetch!(by_spelling, class)
    else
      _none -> []
    end
  end

  defp launch_classes(nil), do: []

  @doc "The key an approved launch's classes are written under in its root's `host_policy`."
  @spec launch_key() :: String.t()
  def launch_key, do: @launch_key

  @doc """
  Join `sources` into the ledger of the run `id` and of every ancestor up
  its admission chain (`parent_execution_id`), stopping below a turn root,
  whose ledger is its turns', in one transaction: the rows are locked
  root first, read again under the lock and written only where the set
  grows, so concurrent joins in one tree neither deadlock nor lose an
  addition. Called before the bytes the sources describe reach the run,
  so every byte a child hands up is preceded by its ancestors holding its
  provenance. `{:error, :not_found}` for no such row.
  """
  @spec join_sources(Prima.Actor.t(), String.t(), [Prima.Source.t()]) ::
          :ok | {:error, :not_found | :database_error}
  def join_sources(%Prima.Actor{athanor_id: athanor_id} = actor, id, sources)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_list(sources) do
    Arca.Repo.Errors.with_db_rescue("Execution.join_sources", fn ->
      case row_of(actor, id) do
        nil ->
          {:error, :not_found}

        %Row{} ->
          if sources == [] do
            :ok
          else
            Arca.Repo.locking_transaction(fn -> join_chain!(athanor_id, id, sources) end)
            |> case do
              {:ok, :ok} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end
      end
    end)
  end

  def join_sources(%Prima.Actor{}, _id, _sources), do: {:error, :not_found}

  # The run and its ancestors up to the first turn root (excluded), locked
  # root first and each joined under its own lock.
  # arca:db-raise-ok inside the caller's transaction
  defp join_chain!(athanor_id, id, sources) do
    athanor_id
    |> chain!(id, [], 0)
    |> Enum.each(fn chain_id ->
      from(e in Row,
        where: e.athanor_id == ^athanor_id and e.id == ^chain_id,
        select: e.sources
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()
      |> case do
        [stored] ->
          joined = Prima.Source.encode(Prima.Source.union(ledger_text(stored), sources))

          if joined != stored do
            from(e in Row, where: e.athanor_id == ^athanor_id and e.id == ^chain_id)
            |> Arca.Repo.update_all(set: [sources: joined])
          end

        [] ->
          :ok
      end
    end)
  end

  # The admission chain from `id` up, as ids root first, stopping below a
  # turn root. Bounded: a chain longer than any depth an admission allows
  # is cut there rather than walked without end.
  @max_chain 64

  # arca:db-raise-ok inside the caller's transaction
  defp chain!(_athanor_id, nil, acc, _depth), do: acc
  defp chain!(_athanor_id, _id, acc, depth) when depth >= @max_chain, do: acc

  defp chain!(athanor_id, id, acc, depth) do
    from(e in Row,
      where: e.athanor_id == ^athanor_id and e.id == ^id,
      select: {e.kind, e.parent_execution_id}
    )
    |> Arca.Repo.one()
    |> case do
      nil -> acc
      {"turn", _parent} -> acc
      {_kind, parent} -> chain!(athanor_id, parent, [id | acc], depth + 1)
    end
  end

  # A row's ledger: a turn root's is its turns'; any other's is its stored
  # set, an absent or unreadable one an unnamed outside source.
  # arca:db-raise-ok inside the caller's rescue or transaction
  defp ledger!(%Row{kind: "turn", id: id, athanor_id: athanor_id}),
    do: Arca.TurnStorage.chain_sources!(Prima.Actor.in_athanor(athanor_id), id)

  defp ledger!(%Row{sources: stored}), do: ledger_text(stored)

  defp ledger_text(nil), do: [Prima.Source.outside(nil)]
  defp ledger_text(stored) when is_binary(stored), do: Prima.Source.decode(stored)

  # The seed `admit/2` writes (see its doc): a root's as named; a child's
  # its parent's ledger joined by what its admission names, which joins
  # its ancestors first, their execution rows locked before any attempt
  # row is.
  # arca:db-raise-ok inside the caller's transaction
  defp seed!(athanor_id, attrs, step) do
    named = named_sources!(Map.get(attrs, :sources))

    case Map.get(attrs, :parent_execution_id) do
      nil ->
        Map.put(attrs, :sources, Prima.Source.encode(named))

      parent_id ->
        inherited = parent_ledger!(athanor_id, parent_id, step)
        if named != [], do: join_chain!(athanor_id, parent_id, named)
        Map.put(attrs, :sources, Prima.Source.encode(Prima.Source.union(inherited, named)))
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  defp named_sources!(nil), do: []

  defp named_sources!(sources) when is_list(sources) do
    if Enum.all?(sources, &is_struct(&1, Prima.Source)),
      do: Prima.Source.set(sources),
      else: Arca.Repo.rollback(:invalid_sources)
  end

  defp named_sources!(_sources), do: Arca.Repo.rollback(:invalid_sources)

  # The parent's ledger as it stands: a turn root's is the turn the
  # child's step belongs to — a step of another root's turn admits
  # nothing — or, with no step, every turn on that root.
  # arca:db-raise-ok inside the caller's transaction
  defp parent_ledger!(athanor_id, parent_id, step) do
    case Arca.Repo.one(from(e in Row, where: e.athanor_id == ^athanor_id and e.id == ^parent_id)) do
      nil ->
        Arca.Repo.rollback(:parent_ended)

      %Row{kind: "turn"} ->
        case step do
          %{id: step_id} when is_binary(step_id) ->
            case Arca.TurnStorage.step_sources!(
                   Prima.Actor.in_athanor(athanor_id),
                   step_id,
                   parent_id
                 ) do
              {:ok, sources} -> sources
              :none -> Arca.Repo.rollback(:step_superseded)
            end

          _no_step ->
            Arca.TurnStorage.chain_sources!(Prima.Actor.in_athanor(athanor_id), parent_id)
        end

      %Row{} = parent ->
        ledger!(parent)
    end
  end

  # The tree's root, locked before any attempt row (see `admit/2`): `:own`
  # for a root, whose insert holds its row, else `{root_id, host_policy}`
  # read under the lock, or `:gone` for a root no row holds.
  # arca:db-raise-ok inside the caller's transaction
  defp lock_root!(athanor_id, attrs) do
    case Map.get(attrs, :root_execution_id) do
      root_id when is_binary(root_id) and root_id != "" ->
        if root_id == Map.get(attrs, :id) do
          :own
        else
          from(e in Row,
            where: e.athanor_id == ^athanor_id and e.id == ^root_id,
            select: e.host_policy
          )
          |> Arca.QueryHelpers.for_update()
          |> Arca.Repo.all()
          |> case do
            [policy] -> {root_id, policy}
            [] -> :gone
          end
        end

      _root ->
        :own
    end
  end

  # Mark the tree's root as reached outside, under the lock `lock_root!/2`
  # took (or the root's own insert): a mark that only turns true, written
  # over the policy read under that lock. A policy that does not read as a
  # JSON object keeps nothing but the mark.
  # arca:db-raise-ok inside the caller's transaction
  defp reaches_outside!(athanor_id, root_id, policy) do
    base =
      case decoded_policy(policy) do
        {:ok, map} -> map
        :error -> %{}
      end

    marked = base |> Map.put(@reached_key, true) |> Jason.encode!()

    if marked != policy do
      from(e in Row, where: e.athanor_id == ^athanor_id and e.id == ^root_id)
      |> Arca.Repo.update_all(set: [host_policy: marked])
    end

    :ok
  end

  # A host policy is a JSON object or it is unreadable.
  defp decoded_policy(policy) when is_binary(policy) do
    case Jason.decode(policy) do
      {:ok, %{} = map} -> {:ok, map}
      _not_an_object -> :error
    end
  end

  defp decoded_policy(_none), do: :error

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
  @spec list_by_request(Prima.Actor.t(), String.t(), non_neg_integer()) ::
          [map()] | {:error, :database_error}
  def list_by_request(actor, request_id, limit \\ 100)

  def list_by_request(%Prima.Actor{} = actor, request_id, limit) when is_binary(request_id) do
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
  @spec count_by_request(Prima.Actor.t(), [String.t()]) ::
          %{String.t() => non_neg_integer()} | {:error, :database_error}
  def count_by_request(%Prima.Actor{} = actor, request_ids) when is_list(request_ids) do
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

  @typedoc "One run a profile admitted, as `list_by_profile/3` answers it."
  @type profile_run :: %{
          id: String.t(),
          root_execution_id: String.t() | nil,
          origin: String.t() | nil,
          kind: String.t(),
          status: String.t(),
          reference: String.t(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          turn_id: String.t() | nil,
          schedule_id: String.t() | nil
        }

  @doc """
  The runs `profile_id` admitted in the actor's athanor, newest first, at
  most `limit`: the rows that rooted under that profile (a child row
  carries no profile and walks its root's), each with its origin's wire
  spelling (`Prima.Origin`), its root and its times.

  Scoped to the actor's own athanor whatever its scope: a profile is one
  athanor's, so no reader of its runs crosses athanors. An actor whose
  athanor is nil or the empty string is `{:error, :no_athanor}` before any
  query. A profile with no runs, or no such profile, is `{:ok, []}`;
  telling those apart is the caller's, which reads the profile through
  its owner.
  """
  @spec list_by_profile(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok, [profile_run()]} | {:error, :no_athanor | :database_error}
  def list_by_profile(%Prima.Actor{athanor_id: athanor_id}, profile_id, limit)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(profile_id) and
             is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Execution.list_by_profile", fn ->
      runs =
        from(e in Row,
          where: e.profile_id == ^profile_id,
          order_by: [desc: e.started_at, desc: e.id],
          limit: ^limit,
          select:
            map(e, [
              :id,
              :root_execution_id,
              :origin,
              :kind,
              :status,
              :reference,
              :started_at,
              :completed_at,
              :turn_id,
              :schedule_id
            ])
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, runs}
    end)
    |> Arca.Data.project()
  end

  # Reached only when the actor's athanor is unresolved: a profile id or a
  # limit of another shape matches neither head.
  def list_by_profile(%Prima.Actor{}, profile_id, limit)
      when is_binary(profile_id) and is_integer(limit) and limit > 0,
      do: {:error, :no_athanor}

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
      where: e.status not in ^@open_statuses
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
  # sweeper, makes its completion a refusal, and loses its children
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
      where: e.status not in ^@open_statuses
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
  or the `Opus.Sweeper`'s own scan — never from caller-supplied
  input. `fence`: `attempt:` names the attempt being retired (the row's
  current one when absent); `lease_until:` is the lease the sweeper
  observed, and the attempt lapses only if that exact lease still stands,
  so a renewal that landed after the scan matches nothing, and the row's
  event is `execution.lapsed` — without one the attempt closes failed and
  the event is `execution.failed`; `grant:`
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
        Arca.ExecutionStanding.stored_of_execution(Prima.Actor.in_athanor(athanor_id), id)
    end
  end

  # arca:unscoped-ok the id comes from trusted runtime state, never from
  # caller input; the row read is narrowed to the grant's athanor.
  # arca:db-raise-ok inside the caller's rescue.
  #
  # A `:stored` grant that resolved to nothing is a row that never had an
  # attempt (no admission wrote it; only test fixtures write one, outside
  # the grant contract): there is no stamp to match and no attempt to
  # retire, so it fails on its status alone. A row with an attempt and no
  # grant fails nothing.
  defp fail_open(id, attrs, fence, grant, verify) do
    Arca.Repo.locking_transaction(fn ->
      if grant, do: Arca.ExecutionStanding.verify!(grant, verify)

      open = from(e in Row, where: e.id == ^id and e.status in ^@open_statuses)

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
              from(e in Row, where: e.id == ^id and e.status in ^@open_statuses)
              |> Arca.Repo.update_all(
                set: [
                  status: "failed",
                  completed_at: attrs[:completed_at],
                  duration_ms: attrs[:duration_ms],
                  error_message: attrs[:error_message]
                ]
              )

            # The lifecycle row of a run ended from outside, named by how
            # its attempt was retired: on the lease the sweep saw
            # (`execution.lapsed`), or failed by its parent's end.
            event =
              Arca.ExecutionEvents.append!(
                Prima.Actor.in_athanor(execution.athanor_id),
                id,
                failure_event(Keyword.get(fence, :lease_until)),
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

  defp failure_event(%DateTime{}), do: "execution.lapsed"
  defp failure_event(nil), do: "execution.failed"

  @doc """
  End an execution from the attempt that owns it: the attempt closes with
  `outcome`, the row leaves `running`/`paused` as `status`, and the
  lifecycle event (`execution.<status>`, or `execution.result_lost` for
  a completed run whose result was not kept) is appended — its number is
  the answered execution's `event_seq` — in one transaction. `attempt`
  names the attempt ending it and is required for a row that has one
  (`{:error, :attempt_not_owner}` when nil); only a row with no attempt —
  a test fixture's, never an admission's — ends with nil.
  `{:error, :not_running}` when the row is not open or the attempt does
  not own it.
  `attrs[:outcome]` is the attempt's outcome when it is not the status's
  own, and must be one that status allows (`completed`: ok; `failed`:
  error, uncertain, result_lost; `cancelled`: cancelled), else
  `{:error, :illegal_transition}`.

  `opts` are the grant contract's (`Arca.ExecutionStanding`, required):
  `grant:` (`:stored` for the current attempt's stamp) and `verify:`,
  asked before the row is locked; the owning attempt is closed only when
  it carries the grant's stamp. A completion's check must find the grant
  standing; a failure or a cancel retires work, and its check need not.
  The check's refusal is answered as itself (`{:error, :not_standing}`),
  and a missing input as `{:error, :missing_grant}`; neither writes.
  """
  @spec record_end(Prima.Actor.t(), String.t(), String.t(), map(), String.t() | nil, keyword()) ::
          {:ok, map()}
          | {:error,
             :not_running
             | :not_found
             | :database_error
             | :not_standing
             | :unavailable
             | :missing_grant
             | :attempt_not_owner
             | :illegal_transition
             | {:payload_not_retained, term()}
             | {:invalid, Arca.Data.field_errors()}}
  def record_end(%Prima.Actor{} = actor, id, status, attrs, attempt, opts)
      when status in @terminal_statuses and is_list(opts) do
    # `attrs[:payloads]` are staged payloads committed for the owning
    # attempt in this transaction; `attrs[:event]` is data the lifecycle
    # event carries besides the status, never its type.
    if outcome_allowed?(status, Map.get(attrs, :outcome)) do
      Arca.Repo.Errors.with_db_rescue("Execution.record_end", fn ->
        case Arca.ExecutionStanding.inputs(opts, fn -> stored_of(actor, id) end) do
          {:ok, grant, verify} -> end_owned(actor, id, status, attrs, attempt, grant, verify)
          {:error, :missing_grant} = refused -> refused
        end
      end)
      |> Arca.Data.project()
    else
      {:error, :illegal_transition}
    end
  end

  # The stamp of the current attempt of an execution the actor may read.
  # arca:db-raise-ok inside the caller's rescue.
  defp stored_of(actor, id) do
    case row_of(actor, id) do
      %Row{athanor_id: athanor_id} ->
        Arca.ExecutionStanding.stored_of_execution(Prima.Actor.in_athanor(athanor_id), id)

      _none ->
        nil
    end
  end

  # A `:stored` grant that resolved to nothing is a row that never had an
  # attempt (no admission wrote it; only test fixtures write one, outside
  # the grant contract): it may fail or be cancelled on its status alone,
  # and never complete.
  # arca:db-raise-ok inside the caller's rescue.
  defp end_owned(actor, id, status, attrs, attempt, grant, verify) do
    Arca.Repo.locking_transaction(fn ->
      if grant, do: Arca.ExecutionStanding.verify!(grant, verify)

      execution =
        from(e in Row, where: e.id == ^id and e.status in ^@open_statuses)
        |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
        |> Arca.Repo.one()

      if is_nil(execution), do: Arca.Repo.rollback(:not_running)

      # The attempt ending the row names itself: a row with an attempt is
      # never ended on whichever attempt happens to own it now.
      if is_nil(attempt) and is_binary(execution.current_attempt),
        do: Arca.Repo.rollback(:attempt_not_owner)

      owner = attempt
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
               Prima.Actor.in_athanor(execution.athanor_id),
               owner,
               attempt_state,
               outcome,
               grant
             )
           ),
         do: Arca.Repo.rollback(stamp_refusal(execution.athanor_id, owner, grant))

      commit_payloads!(Map.get(attrs, :payloads, []), owner)

      {1, _} =
        from(e in Row, where: e.id == ^id and e.status in ^@open_statuses)
        |> Arca.QueryHelpers.where_tenant_unless_platform(actor)
        |> Arca.Repo.update_all(set: Map.to_list(changeset.changes))

      event =
        Arca.ExecutionEvents.append!(
          Prima.Actor.in_athanor(execution.athanor_id),
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
            |> Map.merge(Map.drop(Map.get(attrs, :event, %{}), ["status", "outcome"]))
        )

      %{Ecto.Changeset.apply_changes(changeset) | event_seq: event.seq}
    end)
  end

  # Why the owning attempt did not close: a stamp other than the grant's
  # is `:not_standing`, any other miss the row not being open.
  # arca:db-raise-ok inside the caller's transaction
  defp stamp_refusal(athanor_id, attempt, grant) do
    case Arca.ExecutionStanding.stored(Prima.Actor.in_athanor(athanor_id), attempt) do
      %Prima.ExecutionGrant{} = stamp when stamp != grant -> :not_standing
      _ -> :not_running
    end
  end

  # The lifecycle event a terminal write appends; a completed run whose
  # result was lost is its own kind.
  defp lifecycle_type("failed", "result_lost"), do: "execution.result_lost"
  defp lifecycle_type(status, _outcome), do: "execution." <> status

  @doc "The execution's durable event counter, within the athanor."
  @spec event_seq(Prima.Actor.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def event_seq(%Prima.Actor{athanor_id: athanor_id}, id)
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

  def event_seq(%Prima.Actor{}, _id), do: {:error, :no_athanor}

  # Staged payloads join the transaction as the attempt's rows; one the
  # store refuses rolls the whole write back.
  # arca:db-raise-ok inside the caller's transaction
  defp commit_payloads!(staged, attempt) do
    for payload <- staged, not is_nil(payload) do
      try do
        Arca.ExecutionPayloads.commit!(payload, attempt)
      rescue
        e -> Arca.Repo.rollback({:payload_not_retained, Prima.LogFilter.exception_message(e)})
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
        Prima.Actor.in_athanor(execution.athanor_id),
        attempt,
        "failed",
        "error",
        grant
      )
    )
  end

  @doc """
  Executions whose current attempt is running with a lease lapsed before
  `now` (the sweep), each as the row's map with the attempt's `attempt`,
  `athanor_generation`, `service_id`, `boot_id`, `claimed_by` and
  `lease_until` beside it.

  Intentionally spans all tenants: the `Opus.Sweeper` GC must reap
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
        Prima.Digest.sha256_hex(json)

      {:error, _} ->
        nil
    end
  end

  def hash_input(_), do: nil
end
