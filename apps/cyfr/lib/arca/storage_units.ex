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

  ## Tenancy

  Every function takes the `Cyfr.Actor` first and scopes every query to
  its athanor. An actor with no athanor is refused as
  `{:error, :no_athanor}` before any query. A store that cannot answer is
  `{:error, :unavailable}`: the outcome is unknown and nothing may be
  assumed.
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.{StorageCommit, StorageUnit}
  alias Arca.Storage.UnitLocator

  @draft_ttl_ms :timer.minutes(15)

  @type refusal :: {:error, :no_athanor | :unavailable}

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
  def new_revision, do: Cyfr.UUID7.generate_id("rev")

  @doc "A fresh writer token."
  @spec new_writer_token() :: String.t()
  def new_writer_token, do: Cyfr.UUID7.generate_id("wrt")

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
  @spec register_draft(Cyfr.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, StorageUnit.t()} | {:error, :stale_writer} | refusal()
  def register_draft(%Cyfr.Actor{} = actor, root, unit_key, writer_token)
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
  @spec abandon_draft(Cyfr.Actor.t(), StorageUnit.t(), String.t()) :: :ok | refusal()
  def abandon_draft(%Cyfr.Actor{} = actor, %StorageUnit{} = unit, writer_token)
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
  @spec stage_prefix(Cyfr.Actor.t(), StorageUnit.t(), String.t()) ::
          {:ok, Arca.Storage.path()} | {:error, :missing_unit | :no_athanor}
  def stage_prefix(%Cyfr.Actor{} = actor, %StorageUnit{} = unit, revision)
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
  @spec commit(Cyfr.Actor.t(), StorageUnit.t(), String.t() | nil, String.t(), identity()) ::
          StorageUnit.commit_result() | {:error, :no_athanor}
  def commit(
        %Cyfr.Actor{} = actor,
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
        move_pointer(athanor, unit.id, expected_revision, writer_token, identity)
      end)
    end
  end

  @doc """
  The committed pointer of one unit, for a reader to resolve once per
  operation. A draft never committed and a retired unit are
  `{:error, :not_found}`: readers see no unit.
  """
  @spec current(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, StorageUnit.t()} | {:error, :not_found} | refusal()
  def current(%Cyfr.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("current", fn ->
        case fetch(athanor, root, unit_key) do
          %StorageUnit{state: "committed"} = unit -> {:ok, unit}
          _absent_draft_or_retired -> {:error, :not_found}
        end
      end)
    end
  end

  @doc "Every committed pointer under a root, by unit key — the batch form of `current/3`."
  @spec current_under(Cyfr.Actor.t(), String.t()) ::
          {:ok, %{String.t() => StorageUnit.t()}} | refusal()
  def current_under(%Cyfr.Actor{} = actor, root) when is_binary(root) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("current_under", fn -> {:ok, committed_under(athanor, root)} end)
    end
  end

  @doc """
  Retire a unit — the drop: readers see no unit from here on, the draft
  token is cleared, and the pointer keeps its last revision for the
  journal's sake. `{:error, :not_found}` for a unit with no row or one
  already retired.
  """
  @spec retire(Cyfr.Actor.t(), String.t(), String.t()) :: :ok | {:error, :not_found} | refusal()
  def retire(%Cyfr.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("retire", fn -> retire_row(athanor, root, unit_key) end)
    end
  end

  @doc """
  A unit's commits, oldest first — what repair and collection read to
  tell a committed revision from a loser's staging. `{:error, :not_found}`
  for a unit with no row; a retired unit keeps its journal.
  """
  @spec journal(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, [StorageCommit.t()]} | {:error, :not_found} | refusal()
  def journal(%Cyfr.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("journal", fn ->
        case fetch(athanor, root, unit_key) do
          nil -> {:error, :not_found}
          %StorageUnit{id: id} -> {:ok, commits_of(athanor, id)}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Tenancy and the outage spelling
  # ---------------------------------------------------------------------------

  # The refusal that precedes every query: no athanor, no rows.
  defp tenant(%Cyfr.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Cyfr.Actor{}), do: {:error, :no_athanor}

  # A row handed back by a caller is still checked against the actor: a
  # struct is not proof of whose unit it is.
  defp owned(athanor, %StorageUnit{athanor_id: athanor}), do: :ok
  defp owned(_athanor, %StorageUnit{}), do: {:error, :missing_unit}

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageUnits.#{entry}", fun) do
      {:error, :database_error} -> {:error, :unavailable}
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
      id: Cyfr.UUID7.generate_id("unit"),
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
      {0, _} -> {:error, :not_found}
      {_retired, _} -> :ok
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

  # The pointer move and the journal row share one transaction, so neither
  # exists without the other. The compare is the update's own WHERE: no
  # read-then-write window, on either adapter.
  defp move_pointer(athanor, id, expected_revision, writer_token, identity) do
    now = DateTime.utc_now()

    Arca.Repo.transaction(fn ->
      case swap(athanor, id, expected_revision, writer_token, identity, now) do
        1 ->
          append_journal!(athanor, id, expected_revision, identity, now)
          :committed

        0 ->
          Arca.Repo.rollback(refusal(athanor, id, expected_revision))
      end
    end)
    |> case do
      {:ok, :committed} -> :committed
      {:error, reason} -> {:error, reason}
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

    {moved, _} =
      Arca.Repo.update_all(at_expected,
        set: [
          state: "committed",
          current_revision: identity.new_revision,
          draft_writer_token: nil,
          updated_at: now
        ]
      )

    moved
  end

  defp append_journal!(athanor, id, expected_revision, identity, now) do
    %StorageCommit{}
    |> StorageCommit.changeset(%{
      id: Cyfr.UUID7.generate_id("cmt"),
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
