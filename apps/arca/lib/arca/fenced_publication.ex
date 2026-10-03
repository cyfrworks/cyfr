# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FencedPublication do
  @moduledoc """
  A write that lands only while its writer still owns its slot in the cell
  and the resource still holds the revision the writer read.

  Named apart from `Arca.Overlay`'s unit publication: that one publishes a
  unit of a seeded root through `Arca.StorageUnits`; this one publishes a
  row or a document under a member's ownership.

  ## Three facts, each checked

    * **The resource revision the writer read** — a per-row counter,
      compared and raised by one in the publishing statement
      (`WHERE revision = ?`). Two healthy members writing one resource
      resolve as a conflict, `:stale`, and never by comparing their
      generations.
    * **The writer's ownership** — its slot, `(node, owner, generation)`,
      verified live inside the publication's transaction by
      `Arca.ControlPlane.verify_held/1`, which holds the lease row under a
      shared lock until commit and reads the database's clock. A lease that
      ran out with no successor refuses exactly as a takeover does
      (`:not_owner`), and on PostgreSQL a member's publications do not
      serialize on its own row.
    * **The lease row's `fence`** — the claimant's renewal token. It is
      never a publication's identity and is never read here, so an owner
      that renewed during a long write still publishes.

  `Arca.ControlPlane.held?/0` and a clock read before the write are fast
  refusals a caller may make first; they are never the guarantee. A
  writer takes its slot from `Arca.ControlPlane.member_slot/0`. Where no
  claimant runs (`Arca.ControlPlane.claimed?/0` false, the test
  configuration alone) there is no slot and the writer names `:none`:
  the live ownership check is skipped and the revision compare-and-set is
  not. A `:none` slot where a claimant runs is `:not_owner`, so a release
  never publishes unfenced.

  ## Resources

    * `{:row, schema, id}` — a row of an Ecto schema with a single primary
      key and an integer `revision` column. `attrs` are set on it with the
      revision in the publishing statement, and nothing else is: a
      timestamp the schema keeps is the caller's to put in `attrs`.
    * `{:document, athanor_id, key}` — a `fenced_documents` row: the
      authoritative reference for bytes staged by `Arca.Storage.stage/3`
      (`staged`, and the `digest` the writer expects, when it names one).
      A document no publication has created reads as revision 0, and the
      first publication creates it at revision 1. The staged bytes stay
      where they were written: the document names their key, the staging
      row becomes `published` in the same transaction, and nothing is
      renamed on any adapter. The staging row of the bytes a publication
      replaces goes `deleting` in that transaction too, and the sweep
      (`Arca.Retention.FencedStaging`) removes them. `document/2` reads
      it, `list/2` reads a prefix of keys, and `remove/3` deletes it under
      the same fence, handing its bytes to the sweep.

  ## Idempotency

  By resource, revision and content together. Publishing what is already
  the resource's content at `revision_read + 1` answers that revision and
  writes nothing; the same content at any other revision is `:stale`. A
  document's content is the staged key with its digest, so two writers
  that staged identical bytes hold two contents, each published against
  its own revision.

  ## The transaction budget

  From the transaction's first statement to its publishing one, measured
  on the monotonic clock: past `budget_ms/0` the transaction rolls back
  with `{:error, :budget}` before it writes, and the slot is left as it
  was.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias Arca.Schemas.{FencedDocument, StorageStaging}

  # The budget must stay under `Arca.ControlPlane.margin_ms/0` (1000 ms):
  # the margin is what a member gives up of every lease it wins, so a
  # publication that verified the lease and reaches its publishing
  # statement within the budget commits inside the lease the database
  # granted, not on the successor's side of it.
  @budget_ms 500

  defmodule Change do
    @moduledoc """
    One fenced publication: the resource it writes and what it writes
    there (`Arca.FencedPublication.publish/3`).

      * `resource` — `{:row, schema, id}` or `{:document, athanor_id, key}`.
      * `attrs` — the fields a row publication sets, atom-keyed; empty for
        a document.
      * `staged` — the staging id `Arca.Storage.stage/3` answered; a
        document publication names one, a row publication none.
      * `digest` — the digest of the staged bytes the writer expects, or
        `nil` to take the one the staging row recorded.
    """

    @type resource :: {:row, module(), term()} | {:document, String.t(), String.t()}

    @type t :: %__MODULE__{
            resource: resource(),
            attrs: %{optional(atom()) => term()},
            staged: String.t() | nil,
            digest: String.t() | nil
          }

    @enforce_keys [:resource]
    defstruct [:resource, attrs: %{}, staged: nil, digest: nil]
  end

  @typedoc """
  The writer's slot, as `Arca.ControlPlane.take/3` won it. Only the node,
  the owner and the generation are read; a `fence` it carries is ignored.
  """
  @type slot :: %{
          required(:node) => String.t(),
          required(:owner) => String.t(),
          required(:generation) => integer(),
          optional(atom()) => term()
        }

  @typedoc """
  The slot a publication names: the writer's own, or `:none` where no
  claimant runs (see the module doc).
  """
  @type writer :: slot() | :none

  @type refusal :: :not_owner | :stale | :expired | :budget | :database_error

  @refusals [:not_owner, :stale, :expired, :budget]

  @doc "The transaction budget, in milliseconds. See the module doc."
  @spec budget_ms() :: pos_integer()
  def budget_ms, do: @budget_ms

  @doc """
  Publish `change` over the revision the writer read, under the writer's
  `slot`, in one transaction.

  Answers `{:ok, revision}`, the revision the resource now holds, or:

    * `{:error, :not_owner}` — the slot is not the writer's on the
      database's clock: taken over, released, or run out.
    * `{:error, :stale}` — the resource no longer holds `revision_read`,
      or never did.
    * `{:error, :expired}` — the staged attempt cannot be published: its
      reservation ran out or was cancelled, the sweep claimed it, it
      belongs to another athanor, or its bytes were never recorded under
      the digest the change names.
    * `{:error, :budget}` — the transaction outran `budget_ms/0` before
      its publishing statement and rolled back.
    * `{:error, :database_error}` — the store could not answer.

  Raises `ArgumentError` for a change of no shape above: a document with
  no staged id or with `attrs`, a row with a staged id, or `attrs` that
  name the revision.
  """
  @spec publish(Change.t(), non_neg_integer(), writer()) ::
          {:ok, non_neg_integer()} | {:error, refusal()}
  def publish(%Change{} = change, revision_read, slot)
      when is_integer(revision_read) and revision_read >= 0 do
    target = target!(change)
    slot = writer!(slot)

    fenced("Arca.FencedPublication.publish", fn ->
      started = System.monotonic_time(:millisecond)
      publication(target, revision_read, slot, started)
    end)
  end

  @doc """
  Remove the document `change` names (`{:document, athanor_id, key}`,
  nothing staged) while it still holds `revision_read`, under the
  writer's `slot`, in one transaction: the reference row is deleted, and
  the staging row of the bytes it named goes `deleting` with it, for the
  sweep to remove.

  Answers `:ok`, or the refusals of `publish/3`: `:not_owner`, `:stale`
  (the document moved on, or holds no revision to remove — a removal of
  what is absent included), `:budget` and `:database_error`.

  A removed document reads as absent, revision 0, as one never published
  does: its next publication creates it again at revision 1.

  Raises `ArgumentError` for a change naming anything else, or one that
  carries staged bytes or `attrs`.
  """
  @spec remove(Change.t(), non_neg_integer(), writer()) :: :ok | {:error, refusal()}
  def remove(%Change{} = change, revision_read, slot)
      when is_integer(revision_read) and revision_read >= 0 do
    {athanor_id, key} = removal!(change)
    slot = writer!(slot)

    fenced("Arca.FencedPublication.remove", fn ->
      started = System.monotonic_time(:millisecond)

      with :ok <- owned(slot),
           :ok <- within_budget(started) do
        removal(athanor_id, key, revision_read)
      end
    end)
    |> case do
      {:ok, _revision} -> :ok
      {:error, _} = refused -> refused
    end
  end

  # One transaction for a publication or a removal: a refusal rolls it
  # back whole, and only the declared refusals leave it.
  defp fenced(label, step) do
    Arca.Repo.Errors.with_db_rescue(label, fn ->
      Arca.Repo.locking_transaction(fn ->
        case step.() do
          {:ok, revision} -> revision
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, revision} when is_integer(revision) and revision >= 0 -> {:ok, revision}
        {:error, reason} when reason in @refusals -> {:error, reason}
      end
    end)
  end

  # The fence, when the slot carries one, is left behind here.
  defp writer!(:none), do: :none

  defp writer!(%{node: _, owner: _, generation: _} = slot),
    do: Map.take(slot, [:node, :owner, :generation])

  defp writer!(_other),
    do: raise(ArgumentError, "a fenced publication names the writer's slot, or :none")

  @doc """
  The document at `key` in the actor's athanor, as a plain map —
  `athanor_id`, `key`, `revision`, `blob_key`, `digest` and timestamps —
  or `:not_found` where no publication has created it (read it as
  revision 0). The bytes are at `blob_key`, a logical storage path joined
  with `/`.
  """
  @spec document(Prima.Actor.t(), String.t()) ::
          map() | :not_found | {:error, :no_athanor | :database_error}
  def document(%Prima.Actor{athanor_id: athanor_id} = actor, key)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.FencedPublication.document", fn ->
      FencedDocument
      |> Arca.QueryHelpers.where_tenant(actor)
      |> where([d], d.key == ^key)
      |> Arca.Repo.one()
      |> case do
        nil -> :not_found
        row -> Arca.Data.project(row)
      end
    end)
  end

  def document(%Prima.Actor{}, key) when is_binary(key), do: {:error, :no_athanor}

  @doc """
  Every document in the actor's athanor whose key begins with `prefix`,
  as the plain maps `document/2` answers, ordered by key (bytewise, the
  same on either adapter). An empty prefix lists them all.
  """
  @spec list(Prima.Actor.t(), String.t()) ::
          {:ok, [map()]} | {:error, :no_athanor | :database_error}
  def list(%Prima.Actor{athanor_id: athanor_id} = actor, prefix)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(prefix) do
    Arca.Repo.Errors.with_db_rescue("Arca.FencedPublication.list", fn ->
      # `substr` rather than `LIKE`: SQLite's `LIKE` folds ASCII case and
      # both treat `%` and `_` as patterns, where a key prefix is bytes.
      length = String.length(prefix)

      rows =
        FencedDocument
        |> Arca.QueryHelpers.where_tenant(actor)
        |> where([d], fragment("substr(?, 1, ?)", d.key, ^length) == ^prefix)
        |> Arca.Repo.all()

      {:ok,
       rows
       |> Enum.filter(&String.starts_with?(&1.key, prefix))
       |> Enum.sort_by(& &1.key)
       |> Enum.map(&Arca.Data.project/1)}
    end)
  end

  def list(%Prima.Actor{}, prefix) when is_binary(prefix), do: {:error, :no_athanor}

  # ---- the transaction ---------------------------------------------------------

  # Ownership first, under the lease row's shared lock; then the staged
  # attempt, on the database's clock read after that lock was won; then
  # the budget; then the one statement that publishes.
  defp publication(target, revision_read, slot, started) do
    with :ok <- owned(slot),
         {:claimed, content} <- claim(target, revision_read),
         :ok <- within_budget(started) do
      commit(target, content, revision_read)
    end
  end

  # `:none` stands for no slot only where no claimant runs; anywhere else
  # `verify_held/1` answers it `:lost`, a writer that holds none.
  defp owned(slot) do
    case Arca.ControlPlane.verify_held(slot) do
      :ok -> :ok
      :lost -> {:error, :not_owner}
    end
  end

  defp within_budget(started) do
    if System.monotonic_time(:millisecond) - started > @budget_ms,
      do: {:error, :budget},
      else: :ok
  end

  # A row has nothing staged to claim.
  defp claim({:row, _schema, _id, _attrs}, _revision_read), do: {:claimed, nil}

  # The staged attempt becomes this publication's by compare-and-set, on
  # both the row's state and its expiry: the sweep's claim of the same row
  # is the same kind of statement, so of the two exactly one lands, and
  # the loser reads what the winner left. The bytes' key and digest are
  # what the statement matched, never a later read.
  defp claim({:document, athanor_id, _key, staged, digest} = target, revision_read) do
    now = Arca.ServerMetaStorage.now!()

    reserved =
      from(s in StorageStaging,
        where:
          s.athanor_id == ^athanor_id and s.id == ^staged and s.state == "reserved" and
            s.expires_at > ^now and not is_nil(s.digest),
        select: {s.key, s.digest}
      )

    reserved = if digest, do: where(reserved, [s], s.digest == ^digest), else: reserved

    case Arca.Repo.update_all(reserved, set: [state: "published", updated_at: now]) do
      {1, [{blob_key, staged_digest}]} -> {:claimed, {blob_key, staged_digest}}
      {0, _} -> replayed(target, revision_read)
    end
  end

  # The attempt is not a reserved one this publication can claim. Already
  # published, it is a replay: a no-op when the document holds exactly it
  # at the revision after the one read, `:stale` otherwise. Anything else
  # — expired, cancelled, claimed by the sweep, gone, never recorded,
  # another digest, another athanor's — cannot be published.
  defp replayed({:document, athanor_id, key, staged, digest}, revision_read) do
    staging =
      Arca.Repo.one(
        from(s in StorageStaging, where: s.athanor_id == ^athanor_id and s.id == ^staged)
      )

    case staging do
      %StorageStaging{state: "published", key: blob_key, digest: staged_digest}
      when digest in [nil, staged_digest] ->
        current =
          Arca.Repo.one(
            from(d in FencedDocument, where: d.athanor_id == ^athanor_id and d.key == ^key)
          )

        case current do
          %FencedDocument{revision: revision, blob_key: ^blob_key, digest: ^staged_digest}
          when revision == revision_read + 1 ->
            {:ok, revision}

          _ ->
            {:error, :stale}
        end

      %StorageStaging{state: "published"} ->
        {:error, :stale}

      _ ->
        {:error, :expired}
    end
  end

  # The publishing statement. A document the writer read as absent is
  # created at revision 1, and a create that finds one already there has
  # lost to another publication; every other publication is a
  # compare-and-set on the revision the writer read.
  defp commit({:document, athanor_id, key, _staged, _digest}, {blob_key, digest}, 0) do
    now = Arca.ServerMetaStorage.now!()

    row = %{
      athanor_id: athanor_id,
      key: key,
      revision: 1,
      blob_key: blob_key,
      digest: digest,
      inserted_at: now,
      updated_at: now
    }

    case Arca.Repo.insert_all(FencedDocument, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, 1}
      {0, _} -> {:error, :stale}
    end
  end

  # The bytes the replaced revision named are handed to the sweep in the
  # same transaction: their staging row goes `deleting`, so the document
  # and its bytes change together or not at all. The blob key is read
  # under the row's lock (the database's one write lock on SQLite), so it
  # is the one the compare-and-set below replaces.
  defp commit({:document, athanor_id, key, _staged, _digest}, {blob_key, digest}, revision_read) do
    current =
      from(d in FencedDocument,
        where: d.athanor_id == ^athanor_id and d.key == ^key and d.revision == ^revision_read
      )

    now = Arca.ServerMetaStorage.now!()
    set = [revision: revision_read + 1, blob_key: blob_key, digest: digest, updated_at: now]

    with replaced when is_binary(replaced) <-
           current
           |> select_blob_key()
           |> Arca.QueryHelpers.for_update()
           |> Arca.Repo.one(),
         {1, _} <- Arca.Repo.update_all(current, set: set) do
      if replaced != blob_key, do: retire(athanor_id, replaced, now)
      {:ok, revision_read + 1}
    else
      _moved -> {:error, :stale}
    end
  end

  # arca:unscoped-ok the row is the one the writer read under its own actor, named by its key.
  defp commit({:row, schema, id, attrs}, nil, revision_read) do
    [primary_key] = schema.__schema__(:primary_key)

    current =
      from(r in schema,
        where: field(r, ^primary_key) == ^id and r.revision == ^revision_read
      )

    case Arca.Repo.update_all(current, set: Map.to_list(attrs) ++ [revision: revision_read + 1]) do
      {1, _} -> {:ok, revision_read + 1}
      {0, _} -> unchanged(schema, primary_key, id, attrs, revision_read)
    end
  end

  # The removal's one statement: the reference row at the revision read,
  # its blob key read under the row's lock first, and the bytes it named
  # handed to the sweep in the same transaction. A document at revision 0
  # is absent, so there is nothing at it to remove.
  defp removal(athanor_id, key, revision_read) do
    current =
      from(d in FencedDocument,
        where: d.athanor_id == ^athanor_id and d.key == ^key and d.revision == ^revision_read
      )

    with blob_key when is_binary(blob_key) <-
           current
           |> select_blob_key()
           |> Arca.QueryHelpers.for_update()
           |> Arca.Repo.one(),
         {1, _} <- Arca.Repo.delete_all(current) do
      retire(athanor_id, blob_key, Arca.ServerMetaStorage.now!())
      {:ok, revision_read}
    else
      _moved -> {:error, :stale}
    end
  end

  defp select_blob_key(query), do: from(d in query, select: d.blob_key)

  # Only a `published` row: the replaced bytes were this document's, and
  # a row in any other state is not a publication's to hand over.
  defp retire(athanor_id, blob_key, now) do
    replaced =
      from(s in StorageStaging,
        where: s.athanor_id == ^athanor_id and s.key == ^blob_key and s.state == "published"
      )

    {_count, _} = Arca.Repo.update_all(replaced, set: [state: "deleting", updated_at: now])
    :ok
  end

  # A row publication that matched nothing is a replay when the row
  # already holds exactly `attrs` at the revision after the one read.
  # arca:unscoped-ok the row is the one the writer read under its own actor, named by its key.
  defp unchanged(schema, primary_key, id, attrs, revision_read) do
    case Arca.Repo.one(from(r in schema, where: field(r, ^primary_key) == ^id)) do
      %{revision: revision} = row when revision == revision_read + 1 ->
        if Enum.all?(attrs, fn {field, value} -> Map.get(row, field) == value end),
          do: {:ok, revision},
          else: {:error, :stale}

      _ ->
        {:error, :stale}
    end
  end

  # ---- the change's shape ----------------------------------------------------

  defp target!(
         %Change{resource: {:document, athanor_id, key}, staged: staged, digest: digest} = change
       )
       when is_binary(athanor_id) and athanor_id != "" and is_binary(key) and key != "" and
              is_binary(staged) and staged != "" and (is_binary(digest) or is_nil(digest)) do
    if change.attrs != %{},
      do: raise(ArgumentError, "a document publication sets no attrs; its content is staged")

    {:document, athanor_id, key, staged, digest}
  end

  defp target!(%Change{resource: {:row, schema, id}, staged: nil, digest: nil, attrs: attrs})
       when is_atom(schema) and not is_nil(id) and is_map(attrs) do
    unless Enum.all?(Map.keys(attrs), &is_atom/1),
      do: raise(ArgumentError, "a row publication's attrs are atom-keyed fields")

    if Map.has_key?(attrs, :revision),
      do: raise(ArgumentError, "the revision is the publication's to raise, not an attr")

    {:row, schema, id, attrs}
  end

  defp target!(%Change{}) do
    raise ArgumentError,
          "a fenced publication writes {:row, schema, id} with attrs, " <>
            "or {:document, athanor_id, key} with a staged id"
  end

  defp removal!(%Change{
         resource: {:document, athanor_id, key},
         staged: nil,
         digest: nil,
         attrs: attrs
       })
       when is_binary(athanor_id) and athanor_id != "" and is_binary(key) and key != "" and
              attrs == %{},
       do: {athanor_id, key}

  defp removal!(%Change{}) do
    raise ArgumentError,
          "a fenced removal names {:document, athanor_id, key}, with nothing staged and no attrs"
  end
end
