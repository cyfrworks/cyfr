# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CronSchedule do
  @moduledoc """
  Row-plane storage for an athanor's cron schedules and feeds
  (`Arca.Schemas.CronSchedule`); `user_id` records who created a row
  (attribution), the athanor owns it.

  Uses the `Arca.QueryHelpers` return convention: database failures return
  `{:error, :database_error}`, missing rows return `{:error, :not_found}`,
  and validation returns `{:error, {:validation, %{field => [message]}}}`.
  Every row a function here answers is a plain map (`Arca.Data`); raw
  changesets do not leave the storage layer.

  ## Kinds

  A row is a `schedule` or a `feed`. The scheduler fires both, so
  `active_schedules/0`, `get_for_daemon/1`, `record_run/3` and
  `record_error/3` answer either. `list/2` and `get_by_id_or_name/3` take
  a `kind:` option (nil reads both), and `count_active/2` counts one kind.
  A live name is unique per kind, so a feed may share a schedule's name.

  ## Feeds

  A feed's row id is its binding id, and only `create_feed/2` writes one.
  Every feed function takes the actor first and touches that athanor's
  rows alone: another athanor's actor naming a feed id finds nothing and
  changes nothing. Every feed write runs in one locking transaction whose
  first step checks the member's slot (`Arca.ControlPlane.verify_held/1`),
  so a member that lost its slot writes nothing and is answered
  `:not_owner`:

    * `create_feed/2` counts the athanor's live feeds and inserts under
      the athanor's row lock, refusing `:feed_cap` at the caller's cap;
    * `claim_feed_seq/2` raises the feed's `feed_fire_seq`, the seq a run
      starts under;
    * `accept_feed_result/5` writes a result only under the slot its
      claimant read, only for a claimed seq, and only when that seq is
      above the accepted one, so an earlier-started result never replaces
      a later one;
    * `remove_feed/2` soft-deletes.

  `list_feeds/1` and `get_feed/2` read the live feed rows and decode
  nothing.
  """

  import Ecto.Query, except: [update: 2]
  import Arca.QueryHelpers, only: [where_tenant_unless_platform: 2]
  # Every function that names a tenant takes the `Prima.Actor` first and
  # reads a schedule through `get_tenant/2`, whose platform bypass is the
  # shared `where_tenant_unless_platform/2`. A platform-scope actor
  # carries no athanor by design, so these match the actor and leave the
  # refusal to that backstop; `get_for_daemon/1` reads unscoped and says
  # why where it stands. The feed functions are held to the actor's own
  # athanor (`Arca.QueryHelpers.where_tenant/2`), and refuse an actor that
  # names none.

  alias Arca.QueryHelpers
  alias Arca.Repo.Errors
  alias Arca.Schemas.Athanor
  alias Arca.Schemas.CronSchedule, as: Row
  alias Prima.Feed.Binding

  @kinds Row.kinds()

  @doc "The status vocabulary this table's rows may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: Row.statuses()

  @doc "The kinds a row may be: a schedule, or a feed."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Creates a new cron schedule, always of kind `schedule`."
  @spec create(map()) ::
          {:ok, map()}
          | {:error, {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the athanor arrives in attrs and is validated required before the insert.
  def create(attrs) do
    Errors.with_db_rescue("CronSchedule.create", fn ->
      now = DateTime.utc_now()

      attrs =
        attrs
        |> Map.put_new(:id, Prima.UUID7.generate_id("sched"))
        |> Map.put_new(:created_at, now)
        |> Map.put_new(:updated_at, now)

      attrs
      |> Row.create_changeset()
      |> Arca.Repo.insert()
      |> mapped_validation()
    end)
    |> Arca.Data.project()
  end

  @doc "Updates an existing cron schedule with tenant-scoped lookup."
  @spec update(Prima.Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  def update(%Prima.Actor{} = actor, id, attrs) do
    Errors.with_db_rescue("CronSchedule.update", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        attrs = Map.put(attrs, :updated_at, DateTime.utc_now())

        schedule
        |> Row.update_changeset(attrs)
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Gets a schedule by ID with tenant-scoped lookup."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get(%Prima.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.get", fn -> get_tenant(actor, id) end)
    |> Arca.Data.project()
  end

  @doc """
  Gets a schedule by ID (unscoped).

  Reserved for the scheduler daemon, which needs to load schedules
  before a tenant context can be constructed (chicken-and-egg: we need
  the schedule's user_id/athanor_id to build a context).
  """
  @spec get_for_daemon(String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok the daemon reads the row to LEARN the athanor it must
  # build a context from — scoping first would need the answer it is asking for.
  def get_for_daemon(id) do
    Errors.with_db_rescue("CronSchedule.get_for_daemon", fn ->
      case Arca.Repo.get(Row, id) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Gets one of the athanor's live rows by either ID or name. `kind:` reads
  one kind, and nil (the default) both. An id names one row whatever its
  kind; a name both a schedule and a feed hold, read with no kind, names
  neither and is `:not_found`, never one of the two picked.
  """
  @spec get_by_id_or_name(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
  def get_by_id_or_name(%Prima.Actor{} = actor, id_or_name, opts \\ []) do
    Errors.with_db_rescue("CronSchedule.get_by_id_or_name", fn ->
      # At most three rows match: the one the id names, and one live row
      # of that name per kind.
      from(s in Row,
        where: s.status != "deleted",
        where: s.id == ^id_or_name or s.name == ^id_or_name
      )
      |> where_tenant_unless_platform(actor)
      |> of_kind(Keyword.get(opts, :kind))
      |> Arca.Repo.all()
      |> case do
        [] -> {:error, :not_found}
        [row] -> {:ok, row}
        rows -> by_id(rows, id_or_name)
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Lists the athanor's live rows, newest first. `kind:` lists one kind and
  nil (the default) both; `limit:` bounds the answer (50).
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [map()]} | {:error, :database_error}
  def list(actor, opts \\ [])

  def list(%Prima.Actor{} = actor, opts) do
    Errors.with_db_rescue("CronSchedule.list", fn ->
      limit = Keyword.get(opts, :limit, 50)

      rows =
        from(s in Row,
          where: s.status != "deleted",
          order_by: [desc: s.created_at],
          limit: ^limit
        )
        |> where_tenant_unless_platform(actor)
        |> of_kind(Keyword.get(opts, :kind))
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  @doc """
  Returns all active rows, schedules and feeds alike (unscoped).

  Unscoped daemon query. The scheduler constructs a context from each
  row's `user_id` and `athanor_id` before executing it.
  """
  @spec active_schedules() :: {:ok, [map()]} | {:error, :database_error}
  # arca:unscoped-ok the firing loop walks every athanor by design, then runs
  # each schedule inside a context built from its own row.
  def active_schedules do
    Errors.with_db_rescue("CronSchedule.active_schedules", fn ->
      rows =
        from(s in Row,
          where: s.status == "active",
          order_by: [asc: s.next_run_at]
        )
        |> Arca.Repo.all()

      {:ok, rows}
    end)
    |> Arca.Data.project()
  end

  @doc "Records a successful run with tenant-scoped lookup."
  @spec record_run(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok get_tenant/2 in the same with establishes row ownership.
  # Increment atomically; concurrent runs must not overwrite each other’s counts.
  def record_run(%Prima.Actor{} = actor, id, execution_id) do
    Errors.with_db_rescue("CronSchedule.record_run", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        now = DateTime.utc_now()

        from(s in Row, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [last_run_at: now, last_execution_id: execution_id, updated_at: now],
          inc: [run_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Records an error with tenant-scoped lookup."
  @spec record_error(Prima.Actor.t(), String.t(), term()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  # arca:unscoped-ok the row was fetched tenant-scoped by get_tenant/2 in the same with.
  # Atomic increment, for the reason spelled out at `record_run/3`.
  def record_error(%Prima.Actor{} = actor, id, _reason) do
    Errors.with_db_rescue("CronSchedule.record_error", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        from(s in Row, where: s.id == ^schedule.id)
        |> Arca.Repo.update_all(
          set: [updated_at: DateTime.utc_now()],
          inc: [error_count: 1]
        )

        get_tenant(actor, id)
      end
    end)
    |> Arca.Data.project()
  end

  @doc "Soft-deletes a schedule with tenant-scoped lookup."
  @spec soft_delete(Prima.Actor.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | {:validation, %{atom() => [String.t()]}} | :database_error}
  def soft_delete(%Prima.Actor{} = actor, id) do
    Errors.with_db_rescue("CronSchedule.soft_delete", fn ->
      with {:ok, schedule} <- get_tenant(actor, id) do
        schedule
        |> Row.delete_changeset(DateTime.utc_now())
        |> Arca.Repo.update()
        |> mapped_validation()
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Counts the athanor's non-deleted rows of `kind` occupying its cap slots.
  Paused schedules retain their slots; resuming does not require a cap check.
  """
  @spec count_active(Prima.Actor.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def count_active(%Prima.Actor{} = actor, kind) when kind in @kinds do
    Errors.with_db_rescue("CronSchedule.count_active", fn ->
      count =
        from(s in Row,
          where: s.status != "deleted" and s.kind == ^kind,
          select: count(s.id)
        )
        |> where_tenant_unless_platform(actor)
        |> Arca.Repo.one()

      {:ok, count || 0}
    end)
  end

  # ---- feeds ------------------------------------------------------------------

  @doc """
  Binds a feed in the actor's athanor: `binding` (a `Prima.Feed.Binding`),
  the pinned version the caller resolved for it (`resolved_reference`), the
  profile it fires under (`profile_id`), and `cap`, the most live feeds the
  athanor may hold, which the caller names (`Crucible.Feeds`).

  The row's id is a new binding id (`Prima.UUID7.generate_id("feed")`). It
  runs `Prima.Feed.input/1` on `Prima.Feed.cron/1`, never overlapping
  itself, and carries the binding's JSON text. Its first occurrence is due
  at once, on the database's clock, and the scheduler's claim advances the
  cursor along the cron from there, as it does any schedule's.

  One locking transaction checks the member's slot, locks the athanor's
  row, counts its live feeds and inserts, so binds racing for the last
  slot leave one row in it. Refused with `:feed_cap` at `cap`, `:conflict`
  for a name a live feed holds, `:not_owner` on a member that no longer
  owns its slot, `:not_found` when the athanor has no row, `:no_athanor`
  for an actor that names none, `{:validation, errors}` for a malformed
  binding or field, and `:database_error`.
  """
  @spec create_feed(Prima.Actor.t(), map()) ::
          {:ok, map()}
          | {:error,
             :feed_cap
             | :conflict
             | :not_owner
             | :not_found
             | :no_athanor
             | :database_error
             | {:validation, %{atom() => [String.t()]}}}
  def create_feed(%Prima.Actor{athanor_id: athanor_id} = actor, %{} = attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    with {:ok, row, cap} <- feed_row(actor, attrs) do
      fenced("CronSchedule.create_feed", fn -> insert_feed(actor, row, cap) end)
    end
  end

  def create_feed(%Prima.Actor{}, %{}), do: {:error, :no_athanor}

  @doc """
  Claims the next seq of the athanor's live feed `binding_id`: raises its
  `feed_fire_seq` and answers it. A result is accepted only for a seq
  claimed here (`accept_feed_result/5`). A schedule's id, a deleted or
  another athanor's feed, or an absent id is `:not_found`, and a member
  that lost its slot `:not_owner`; neither writes anything.
  """
  @spec claim_feed_seq(Prima.Actor.t(), String.t()) ::
          {:ok, pos_integer()}
          | {:error, :not_found | :not_owner | :no_athanor | :database_error}
  def claim_feed_seq(%Prima.Actor{athanor_id: athanor_id} = actor, binding_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(binding_id) do
    fenced("CronSchedule.claim_feed_seq", fn -> claim_seq(actor, binding_id) end)
  end

  def claim_feed_seq(%Prima.Actor{}, _binding_id), do: {:error, :no_athanor}

  @doc """
  Accepts `result_json`, a result's JSON text, as the athanor's live feed
  `binding_id`'s result for the run that claimed `seq`, under `slot`: the
  member slot the claimant read when it claimed the seq
  (`Arca.ControlPlane.member_slot/0`), verified live in this write's own
  transaction.

  On the locked row it writes `feed_result`, `feed_result_at` (the
  database's clock) and `feed_result_seq`, only when `seq` was claimed (at
  most `feed_fire_seq`, else `:unclaimed`) and is above the accepted seq
  (else `:stale`). So an earlier-started result never replaces a later
  one, and an unclaimed seq never makes later results stale. A schedule's
  id, a deleted or another athanor's feed, or an absent id is
  `:not_found`, and a lost slot `:not_owner`. Only `{:ok, row}` writes.
  """
  @spec accept_feed_result(
          Prima.Actor.t(),
          String.t(),
          integer(),
          String.t(),
          Arca.ControlPlane.slot() | :none
        ) ::
          {:ok, map()}
          | {:error,
             :stale | :unclaimed | :not_found | :not_owner | :no_athanor | :database_error}
  def accept_feed_result(
        %Prima.Actor{athanor_id: athanor_id} = actor,
        binding_id,
        seq,
        result_json,
        slot
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(binding_id) and
             is_integer(seq) and is_binary(result_json) and (slot == :none or is_map(slot)) do
    fenced("CronSchedule.accept_feed_result", slot, fn ->
      accept_result(actor, binding_id, seq, result_json)
    end)
  end

  def accept_feed_result(%Prima.Actor{}, _binding_id, _seq, _result_json, _slot),
    do: {:error, :no_athanor}

  @doc """
  Soft-deletes the athanor's live feed `binding_id`, under the member's
  live slot. Its name is free again, and binding it again is a new id. A
  schedule's id, a deleted or another athanor's feed, or an absent id is
  `:not_found`, and a member that lost its slot `:not_owner`; neither
  writes anything.
  """
  @spec remove_feed(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_owner | :no_athanor | :database_error}
  def remove_feed(%Prima.Actor{athanor_id: athanor_id} = actor, binding_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(binding_id) do
    fenced("CronSchedule.remove_feed", fn -> soft_delete_feed(actor, binding_id) end)
  end

  def remove_feed(%Prima.Actor{}, _binding_id), do: {:error, :no_athanor}

  @doc "The athanor's live feeds, by name. Nothing is decoded."
  @spec list_feeds(Prima.Actor.t()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list_feeds(%Prima.Actor{athanor_id: athanor_id} = actor)
      when is_binary(athanor_id) and athanor_id != "" do
    Errors.with_db_rescue("CronSchedule.list_feeds", fn ->
      {:ok, actor |> live_feeds() |> order_by([s], asc: s.name) |> Arca.Repo.all()}
    end)
    |> Arca.Data.project()
  end

  def list_feeds(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  The athanor's live feed `binding_id`, or `:not_found` for a schedule's
  id, a deleted or another athanor's feed, or an absent id. Nothing is
  decoded.
  """
  @spec get_feed(Prima.Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :no_athanor | :database_error}
  def get_feed(%Prima.Actor{athanor_id: athanor_id} = actor, binding_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(binding_id) do
    Errors.with_db_rescue("CronSchedule.get_feed", fn ->
      case actor |> live_feeds() |> where([s], s.id == ^binding_id) |> Arca.Repo.one() do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  def get_feed(%Prima.Actor{}, _binding_id), do: {:error, :no_athanor}

  # The tenant-scoped single-row read every mutation goes through. The
  # platform bypass is the shared `where_tenant_unless_platform/2` — the
  # one spelling the other record readers use, not a hand-rolled fourth.
  defp get_tenant(%Prima.Actor{} = actor, id) do
    from(s in Row, where: s.id == ^id)
    |> where_tenant_unless_platform(actor)
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  defp of_kind(query, nil), do: query
  defp of_kind(query, kind) when kind in @kinds, do: where(query, [s], s.kind == ^kind)

  # Two or three rows match an id-or-name: the id's row is the one meant,
  # and two live rows of one name with no id among them are ambiguous.
  defp by_id(rows, id) do
    case Enum.find(rows, &(&1.id == id)) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  # A raw changeset never escapes the storage layer: validation failures
  # cross as a plain field=>messages map a seam can render with no Ecto
  # knowledge.
  defp mapped_validation({:ok, _} = ok), do: ok

  defp mapped_validation({:error, %Ecto.Changeset{} = changeset}) do
    {:invalid, errors} = Arca.Data.invalid(changeset)
    {:error, {:validation, errors}}
  end

  # ---- feed internals ---------------------------------------------------------

  # The row a bind writes, but for the clock's columns, which the insert's
  # own transaction reads. It is checked before any lock is taken, so a
  # malformed bind waits on nothing. The binding is read back from its own
  # JSON, so a hand-built struct its grammar refuses is refused here too.
  defp feed_row(
         actor,
         %{binding: binding, resolved_reference: resolved, profile_id: profile} = attrs
       ) do
    with {:ok, binding} <- feed_binding(binding),
         {:ok, cap} <- feed_cap(Map.get(attrs, :cap)),
         {:ok, input} <- json_text(Prima.Feed.input(binding)),
         {:ok, spec} <- json_text(Binding.to_json(binding)) do
      row =
        QueryHelpers.stamp_tenant!(actor, %{
          id: Prima.UUID7.generate_id("feed"),
          user_id: actor.user_id,
          name: binding.name,
          cron_expression: Prima.Feed.cron(binding),
          reference: binding.reference,
          resolved_reference: resolved,
          profile_id: profile,
          input: input,
          concurrency: "forbid",
          feed_spec: spec
        })

      checked = DateTime.utc_now()

      case Row.feed_changeset(
             Map.merge(row, %{next_run_at: checked, created_at: checked, updated_at: checked})
           ) do
        %Ecto.Changeset{valid?: true} -> {:ok, row, cap}
        changeset -> mapped_validation({:error, changeset})
      end
    end
  end

  defp feed_row(_actor, _attrs) do
    {:error,
     {:validation, %{binding: ["binding, resolved_reference and profile_id are required"]}}}
  end

  defp feed_binding(%Binding{} = binding) do
    case binding |> Binding.to_json() |> Binding.validate() do
      {:ok, %Binding{}} ->
        {:ok, binding}

      {:error, %{path: path, reason: reason}} ->
        {:error, {:validation, %{binding: ["#{reason} at #{inspect(path)}"]}}}
    end
  rescue
    # `to_json/1` raises, naming no value, on a struct whose actions are no
    # list of actions.
    ArgumentError -> {:error, {:validation, %{binding: ["is not a feed binding"]}}}
  end

  defp feed_binding(_binding),
    do: {:error, {:validation, %{binding: ["is not a feed binding"]}}}

  defp feed_cap(cap) when is_integer(cap) and cap >= 0, do: {:ok, cap}
  defp feed_cap(_cap), do: {:error, {:validation, %{cap: ["must be a non-negative integer"]}}}

  defp json_text(value) do
    case Prima.Json.encode(value) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, {:validation, %{binding: ["is not JSON"]}}}
    end
  end

  # A feed write: one locking transaction whose first step checks `slot`,
  # the member's slot, on the database's clock, so a takeover that
  # committed first refuses it and one that starts later waits for it.
  # `fenced/2` reads the slot now; `fenced/3` takes the one a claimant read
  # when it claimed the seq the write is for.
  defp fenced(tag, write) do
    case Arca.ControlPlane.member_slot() do
      {:ok, slot} -> fenced(tag, slot, write)
      {:error, :not_owner} = refused -> refused
    end
  end

  defp fenced(tag, slot, write) do
    Errors.with_db_rescue(tag, fn ->
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> write.() |> committed()
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)

  # In the bind's transaction: the athanor's row is locked before the
  # count, so binds into one athanor count and insert one at a time.
  defp insert_feed(actor, row, cap) do
    with {:ok, _athanor} <- lock_athanor(actor),
         :ok <- below_cap(actor, cap) do
      now = Arca.ServerMetaStorage.now!()

      row
      |> Map.merge(%{next_run_at: now, created_at: now, updated_at: now})
      |> Row.feed_changeset()
      |> Arca.Repo.insert()
      |> feed_inserted()
    end
  end

  # The athanor's row, locked as `Arca.SecurityTransitions` locks one.
  defp lock_athanor(%Prima.Actor{athanor_id: athanor_id}) do
    case from(a in Athanor, where: a.id == ^athanor_id)
         |> QueryHelpers.for_update()
         |> Arca.Repo.one() do
      nil -> {:error, :not_found}
      athanor -> {:ok, athanor}
    end
  end

  defp below_cap(actor, cap) do
    count =
      from(s in Row, where: s.kind == "feed" and s.status != "deleted", select: count(s.id))
      |> QueryHelpers.where_tenant(actor)
      |> Arca.Repo.one()

    if (count || 0) < cap, do: :ok, else: {:error, :feed_cap}
  end

  defp feed_inserted({:ok, row}), do: {:ok, row}

  defp feed_inserted({:error, %Ecto.Changeset{errors: errors} = changeset}) do
    if Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end),
      do: {:error, :conflict},
      else: mapped_validation({:error, changeset})
  end

  # The athanor's live feed rows: a schedule's row, a deleted feed and
  # another athanor's rows are never among them.
  defp live_feeds(actor) do
    from(s in Row, where: s.kind == "feed" and s.status != "deleted")
    |> QueryHelpers.where_tenant(actor)
  end

  defp locked_feed(actor, binding_id) do
    actor
    |> live_feeds()
    |> where([s], s.id == ^binding_id)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`locked_feed/2`).
  defp claim_seq(actor, binding_id) do
    case locked_feed(actor, binding_id) do
      nil ->
        {:error, :not_found}

      %Row{feed_fire_seq: fired} = row ->
        claimed = fired + 1

        with {:ok, _row} <-
               row |> Ecto.Changeset.change(feed_fire_seq: claimed) |> Arca.Repo.update(),
             do: {:ok, claimed}
    end
  end

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`locked_feed/2`).
  defp accept_result(actor, binding_id, seq, result_json) do
    case locked_feed(actor, binding_id) do
      nil ->
        {:error, :not_found}

      %Row{feed_fire_seq: fired} when seq > fired ->
        {:error, :unclaimed}

      %Row{feed_result_seq: accepted} when seq <= accepted ->
        {:error, :stale}

      row ->
        row
        |> Ecto.Changeset.change(
          feed_result: result_json,
          feed_result_at: Arca.ServerMetaStorage.now!(),
          feed_result_seq: seq
        )
        |> Arca.Repo.update()
    end
  end

  # arca:unscoped-ok the row was read and locked under the actor's athanor (`locked_feed/2`).
  defp soft_delete_feed(actor, binding_id) do
    case locked_feed(actor, binding_id) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Row.delete_changeset(Arca.ServerMetaStorage.now!())
        |> Arca.Repo.update()
    end
  end
end
