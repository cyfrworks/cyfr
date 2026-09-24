# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageUnits do
  @moduledoc """
  The `storage_units` pointer rows and their `storage_commits` journal:
  what publishes a unit under a seeded root.

  A unit's objects prove nothing. A unit is published when its row names a
  committed revision, and the journal records that same commit; a complete
  object set no row names is staging, a loser's remains or hand-laid
  bytes. Rows only: this module moves no object and reads no tree
  (`Arca.Overlay` runs the write protocol over it).

  ## The write protocol's row half

    1. `register_draft/4` gives the unit's one draft to a writer's token.
       Another writer is refused while that draft is live — held, and
       registered within `draft_ttl_ms/0` — so a writer that died cannot
       hold a unit for longer than that.
    2. The writer stages its objects under `stage_prefix/3`, outside any
       transaction.
    3. `commit/5` is one short transaction: it rechecks that the row is
       the actor's athanor's and not retired, compares the pointer with
       the revision the writer staged against and the draft token with the
       writer's, moves the pointer, clears the token and appends exactly
       one journal row. Of two writers with one expected revision exactly
       one commits.

  `abandon_draft/3` gives a draft back without committing.

  ## The projection generation

  A commit and a retirement each change what the root's domain projection
  must show, so each raises the root's epoch in its own transaction and
  writes the unit's change row at that generation, not ready
  (`Arca.StorageProjectionRoots.advance!/3`); it is announced once the
  transaction commits. `stamped_commit/5` and `stamped_retire/3` answer
  the generation, which the writer marks ready when the move or the delete
  it names has finished (`Arca.StorageProjectionChanges.mark_ready/5`). A
  retirement writes its tombstone even for a unit no row names: the bytes
  it deletes may have been laid by hand. Registering, abandoning and
  releasing a draft change nothing a reader sees, and stamp nothing.

  ## Tenancy

  Every function takes the `Prima.Actor` first and scopes every query to
  its athanor. An actor with no athanor is refused as
  `{:error, :no_athanor}` before any query. A store that cannot answer is
  `{:error, :outcome_unknown}`: the outcome is unknown and nothing may be
  assumed.
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.{StorageCommit, StorageUnit}
  alias Arca.Storage.UnitLocator
  alias Arca.{StorageProjectionChanges, StorageProjectionRoots}

  @draft_ttl_ms :timer.minutes(15)

  @type refusal :: {:error, :no_athanor | :outcome_unknown}

  @typedoc "What a commit records beside the pointer move."
  @type identity :: %{
          required(:new_revision) => String.t(),
          required(:content_identity) => String.t(),
          required(:commit_identity) => String.t()
        }

  @doc "How long a registered draft holds its unit against another writer."
  @spec draft_ttl_ms() :: pos_integer()
  def draft_ttl_ms, do: @draft_ttl_ms

  @doc "A fresh revision name: time-ordered, and safe as one path segment."
  @spec new_revision() :: String.t()
  def new_revision, do: Prima.UUID7.generate_id("rev")

  @doc "A fresh writer token."
  @spec new_writer_token() :: String.t()
  def new_writer_token, do: Prima.UUID7.generate_id("wrt")

  @doc """
  Give the unit's draft to `writer_token`, answering the row as the writer
  must stage against it: `current_revision` is the revision its commit
  will expect.

  A unit never seen gets a `draft` row. A `committed` row keeps its state
  and its pointer — readers keep the committed revision while the next is
  staged. A `retired` row becomes a `draft` again with no pointer; the
  journal keeps its earlier commits. Registering again with the same
  token holds. `{:error, :stale_writer}` when another writer's live draft
  holds the unit.
  """
  @spec register_draft(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, StorageUnit.t()} | {:error, :stale_writer} | refusal()
  def register_draft(%Prima.Actor{} = actor, root, unit_key, writer_token)
      when is_binary(root) and is_binary(unit_key) and is_binary(writer_token) and
             writer_token != "" do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("register_draft", fn ->
        ensure_row(athanor, root, unit_key)
        take_draft(athanor, root, unit_key, writer_token)
        held_by(fetch(athanor, root, unit_key), writer_token)
      end)
    end
  end

  @doc """
  Give a draft back without committing: the token is cleared if it is
  still `writer_token`, and a unit that was never committed is retired.
  Idempotent — a draft another writer has since taken is left alone.
  """
  @spec abandon_draft(Prima.Actor.t(), StorageUnit.t(), String.t()) :: :ok | refusal()
  def abandon_draft(%Prima.Actor{} = actor, %StorageUnit{} = unit, writer_token)
      when is_binary(writer_token) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("abandon_draft", fn -> release_draft(athanor, unit.id, writer_token) end)
    end
  end

  @doc """
  The revision-unique prefix a writer stages `revision` of `unit` under —
  `Arca.Storage.UnitLocator.revision_prefix/2`. The writer creates the
  prefix's in-progress marker before its first upload. A unit of another
  athanor is `{:error, :missing_unit}`.
  """
  @spec stage_prefix(Prima.Actor.t(), StorageUnit.t(), String.t()) ::
          {:ok, Arca.Storage.path()} | {:error, :missing_unit | :no_athanor}
  def stage_prefix(%Prima.Actor{} = actor, %StorageUnit{} = unit, revision)
      when is_binary(revision) do
    with {:ok, athanor} <- tenant(actor),
         :ok <- owned(athanor, unit) do
      {:ok,
       unit.root |> UnitLocator.unit_path(unit.unit_key) |> UnitLocator.revision_prefix(revision)}
    end
  end

  @doc """
  Publish a staged revision: one transaction that moves the pointer from
  `expected_revision` (nil for a unit never committed) to
  `identity.new_revision`, sets the state `committed`, clears the draft
  token and appends one journal row — or does none of it. Answers `t:Arca.Schemas.StorageUnit.commit_result/0`:
  `:stale_revision` when the pointer moved, `:stale_writer` when the draft
  is no longer the writer's, `:missing_unit` for a row that is absent,
  retired or another athanor's.
  """
  @spec commit(Prima.Actor.t(), StorageUnit.t(), String.t() | nil, String.t(), identity()) ::
          StorageUnit.commit_result() | {:error, :no_athanor}
  def commit(%Prima.Actor{} = actor, %StorageUnit{} = unit, expected_revision, writer_token, identity) do
    case stamped_commit(actor, unit, expected_revision, writer_token, identity) do
      {:committed, _generation} -> :committed
      {:error, _} = refusal -> refusal
    end
  end

  @doc """
  `commit/5`, answering the projection generation the commit stamped on
  the unit — the one `Arca.StorageProjectionChanges.mark_ready/5` is
  handed once the committed revision is served.
  """
  @spec stamped_commit(Prima.Actor.t(), StorageUnit.t(), String.t() | nil, String.t(), identity()) ::
          {:committed, pos_integer()}
          | {:error,
             :stale_revision | :stale_writer | :missing_unit | :outcome_unknown | :no_athanor}
  def stamped_commit(
        %Prima.Actor{} = actor,
        %StorageUnit{} = unit,
        expected_revision,
        writer_token,
        %{new_revision: new_revision, content_identity: content, commit_identity: who} = identity
      )
      when is_binary(writer_token) and is_binary(new_revision) and is_binary(content) and
             is_binary(who) and (is_nil(expected_revision) or is_binary(expected_revision)) do
    with {:ok, athanor} <- tenant(actor),
         :ok <- owned(athanor, unit) do
      rescuing_db("commit", fn ->
        move_pointer(actor, athanor, unit, expected_revision, writer_token, identity)
      end)
    end
  end

  @doc """
  The committed pointer of one unit, for a reader to resolve once per
  operation. A draft never committed and a retired unit are
  `{:error, :not_found}`: readers see no unit.
  """
  @spec current(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | refusal()
  def current(%Prima.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("current", fn ->
        case fetch(athanor, root, unit_key) do
          %StorageUnit{state: "committed"} = unit -> {:ok, unit}
          _absent_draft_or_retired -> {:error, :not_found}
        end
      end)
    end
    |> Arca.Data.project()
  end

  @doc "Every committed pointer under a root, by unit key — the batch form of `current/3`."
  @spec current_under(Prima.Actor.t(), String.t()) ::
          {:ok, %{String.t() => map()}} | refusal()
  def current_under(%Prima.Actor{} = actor, root) when is_binary(root) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("current_under", fn -> {:ok, committed_under(athanor, root)} end)
    end
    |> Arca.Data.project()
  end

  @doc """
  Retire a unit — the drop: readers see no unit from here on, the draft
  token is cleared, and the pointer keeps its last revision for the
  journal's sake. `{:error, :not_found}` for a unit with no row or one
  already retired.
  """
  @spec retire(Prima.Actor.t(), String.t(), String.t()) :: :ok | {:error, :not_found} | refusal()
  def retire(%Prima.Actor{} = actor, root, unit_key) do
    case stamped_retire(actor, root, unit_key) do
      {:retired, _generation} -> :ok
      {:not_found, _generation} -> {:error, :not_found}
      {:error, _} = refusal -> refusal
    end
  end

  @doc """
  `retire/3` as one locking transaction that also writes the unit's
  tombstone, not ready, at a new projection generation — whether or not a
  row named the unit — and answers that generation beside what became of
  the row: `:retired`, or `:not_found` for no row or one already retired.
  The deleter marks the tombstone ready once the tenant delete returns
  (`Arca.StorageProjectionChanges.mark_ready/5`, revision nil).
  """
  @spec stamped_retire(Prima.Actor.t(), String.t(), String.t()) ::
          {:retired | :not_found, pos_integer()} | refusal()
  def stamped_retire(%Prima.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      answer =
        rescuing_db("retire", fn ->
          Arca.Repo.locking_transaction(fn ->
            retired = retire_row(athanor, root, unit_key)

            generation =
              StorageProjectionRoots.advance!(actor, root, %{
                unit_key: unit_key,
                ready: false,
                tombstone: true,
                source_revision: nil
              })

            {retired, generation}
          end)
        end)

      case answer do
        {:ok, {retired, generation}} ->
          StorageProjectionChanges.announce(athanor, root, generation, false)
          {retired, generation}

        {:error, _} = refusal ->
          refusal
      end
    end
  end

  @doc """
  A unit's commits, oldest first — what repair and collection read to
  tell a committed revision from a loser's staging. `{:error, :not_found}`
  for a unit with no row; a retired unit keeps its journal.
  """
  @spec journal(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :not_found} | refusal()
  def journal(%Prima.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("journal", fn ->
        case fetch(athanor, root, unit_key) do
          nil -> {:error, :not_found}
          %StorageUnit{id: id} -> {:ok, commits_of(athanor, id)}
        end
      end)
    end
    |> Arca.Data.project()
  end

  # ---------------------------------------------------------------------------
  # Tenancy and the outage spelling
  # ---------------------------------------------------------------------------

  # The refusal that precedes every query: no athanor, no rows.
  defp tenant(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Prima.Actor{}), do: {:error, :no_athanor}

  # A row handed back by a caller is still checked against the actor: a
  # struct is not proof of whose unit it is.
  defp owned(athanor, %StorageUnit{athanor_id: athanor}), do: :ok
  defp owned(_athanor, %StorageUnit{}), do: {:error, :missing_unit}

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageUnits.#{entry}", fun) do
      {:error, :database_error} -> {:error, :outcome_unknown}
      answer -> answer
    end
  end

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  defp fetch(athanor, root, unit_key) do
    StorageUnit
    |> where_athanor(athanor)
    |> by_key(root, unit_key)
    |> Arca.Repo.one()
  end

  defp by_key(query, root, unit_key),
    do: from(u in query, where: u.root == ^root and u.unit_key == ^unit_key)

  # Insert-if-absent, so two first writers of one key both find a row to
  # contend for instead of one of them raising on the unique index.
  defp ensure_row(athanor, root, unit_key) do
    now = DateTime.utc_now()

    row = %{
      id: Prima.UUID7.generate_id("unit"),
      athanor_id: athanor,
      root: root,
      unit_key: unit_key,
      state: "draft",
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(StorageUnit, [row],
      on_conflict: :nothing,
      conflict_target: [:athanor_id, :root, :unit_key]
    )
  end

  # One conditional update each, so the take is atomic on every adapter:
  # a draft is free when nobody holds it, when this writer already does,
  # or when its holder registered longer ago than the draft lives.
  defp take_draft(athanor, root, unit_key, writer_token) do
    now = DateTime.utc_now()
    expiry = DateTime.add(now, -@draft_ttl_ms, :millisecond)

    free =
      from(u in by_key(where_athanor(StorageUnit, athanor), root, unit_key),
        where:
          is_nil(u.draft_writer_token) or u.draft_writer_token == ^writer_token or
            u.updated_at < ^expiry
      )

    {revived, _} =
      Arca.Repo.update_all(from(u in free, where: u.state == "retired"),
        set: [
          state: "draft",
          current_revision: nil,
          draft_writer_token: writer_token,
          updated_at: now
        ]
      )

    if revived == 0 do
      Arca.Repo.update_all(from(u in free, where: u.state != "retired"),
        set: [draft_writer_token: writer_token, updated_at: now]
      )
    end

    :ok
  end

  defp held_by(%StorageUnit{draft_writer_token: token} = unit, token), do: {:ok, unit}
  defp held_by(_another_writers_or_gone, _token), do: {:error, :stale_writer}

  defp release_draft(athanor, id, writer_token) do
    now = DateTime.utc_now()

    held =
      from(u in where_athanor(StorageUnit, athanor),
        where: u.id == ^id and u.draft_writer_token == ^writer_token
      )

    Arca.Repo.update_all(from(u in held, where: u.state == "draft"),
      set: [state: "retired", draft_writer_token: nil, updated_at: now]
    )

    Arca.Repo.update_all(from(u in held, where: u.state == "committed"),
      set: [draft_writer_token: nil, updated_at: now]
    )

    :ok
  end

  defp retire_row(athanor, root, unit_key) do
    live =
      from(u in by_key(where_athanor(StorageUnit, athanor), root, unit_key),
        where: u.state != "retired"
      )

    case Arca.Repo.update_all(live,
           set: [state: "retired", draft_writer_token: nil, updated_at: DateTime.utc_now()]
         ) do
      {0, _} -> :not_found
      {_retired, _} -> :retired
    end
  end

  defp committed_under(athanor, root) do
    from(u in where_athanor(StorageUnit, athanor),
      where: u.root == ^root and u.state == "committed"
    )
    |> Arca.Repo.all()
    |> Map.new(&{&1.unit_key, &1})
  end

  defp commits_of(athanor, unit_id) do
    from(c in where_athanor(StorageCommit, athanor),
      where: c.storage_unit_id == ^unit_id,
      order_by: [asc: c.committed_at, asc: c.id]
    )
    |> Arca.Repo.all()
  end

  # ---------------------------------------------------------------------------
  # The commit transaction
  # ---------------------------------------------------------------------------

  # The pointer move, the journal row and the projection generation share
  # one transaction, so none exists without the others. The compare is the
  # update's own WHERE: no read-then-write window, on either adapter. The
  # unit row is locked by that update before the root's epoch is raised —
  # the order every storage writer keeps — and the root and key the
  # generation is stamped on are the row's, never the caller's struct's.
  # The change is announced once it has committed.
  defp move_pointer(actor, athanor, %StorageUnit{id: id}, expected_revision, writer_token, identity) do
    now = DateTime.utc_now()

    Arca.Repo.locking_transaction(fn ->
      case swap(athanor, id, expected_revision, writer_token, identity, now) do
        [{root, unit_key}] ->
          append_journal!(athanor, id, expected_revision, identity, now)

          generation =
            StorageProjectionRoots.advance!(actor, root, %{
              unit_key: unit_key,
              ready: false,
              tombstone: false,
              source_revision: identity.new_revision
            })

          {root, generation}

        [] ->
          Arca.Repo.rollback(refusal(athanor, id, expected_revision))
      end
    end)
    |> case do
      {:ok, {root, generation}} ->
        StorageProjectionChanges.announce(athanor, root, generation, false)
        {:committed, generation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp swap(athanor, id, expected_revision, writer_token, identity, now) do
    held =
      from(u in where_athanor(StorageUnit, athanor),
        where: u.id == ^id and u.state != "retired" and u.draft_writer_token == ^writer_token
      )

    at_expected =
      if is_nil(expected_revision),
        do: from(u in held, where: is_nil(u.current_revision)),
        else: from(u in held, where: u.current_revision == ^expected_revision)

    {_moved, keys} =
      Arca.Repo.update_all(from(u in at_expected, select: {u.root, u.unit_key}),
        set: [
          state: "committed",
          current_revision: identity.new_revision,
          draft_writer_token: nil,
          updated_at: now
        ]
      )

    keys
  end

  defp append_journal!(athanor, id, expected_revision, identity, now) do
    %StorageCommit{}
    |> StorageCommit.changeset(%{
      id: Prima.UUID7.generate_id("cmt"),
      athanor_id: athanor,
      storage_unit_id: id,
      prior_revision: expected_revision,
      new_revision: identity.new_revision,
      content_identity: identity.content_identity,
      commit_identity: identity.commit_identity,
      committed_at: now
    })
    |> Arca.Repo.insert!()
  end

  # Why the swap matched no row. The pointer is judged before the token:
  # a writer whose expected revision is gone lost to a commit, whoever
  # holds the draft now.
  defp refusal(athanor, id, expected_revision) do
    case Arca.Repo.one(from(u in where_athanor(StorageUnit, athanor), where: u.id == ^id)) do
      nil -> :missing_unit
      %StorageUnit{state: "retired"} -> :missing_unit
      %StorageUnit{current_revision: ^expected_revision} -> :stale_writer
      %StorageUnit{} -> :stale_revision
    end
  end
end
