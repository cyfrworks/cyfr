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

  The draft is the unit's one write lease: whoever holds it owns every
  transition of the unit — the next commit, its release, its removal —
  and nobody else may make one until it is given back or has outlived
  `draft_ttl_ms/0`.

    1. `register_draft/4` gives the unit's one draft to a writer's token.
       Another writer is refused while that draft is live — held, and
       registered within `draft_ttl_ms/0` — so a writer that died cannot
       hold a unit for longer than that.
    2. The writer stages its objects under `stage_prefix/3`, outside any
       transaction.
    3. `commit/5` is one short transaction: it verifies the writing
       member still holds its slot in the cell, rechecks that the row is
       the actor's athanor's and not retired, compares the pointer with
       the revision the writer staged against and the draft token with the
       writer's, moves the pointer and appends exactly one journal row. Of
       two writers with one expected revision exactly one commits. The
       token is KEPT: the writer still holds the unit until its release,
       so no other commit can land and no removal can delete between its
       commit and its release.
    4. `release_served/4` is the finish's one short transaction: it gives
       the draft back only while the pointer still names the revision the
       writer served and the token is still the writer's. A writer whose
       token was taken — it stalled past the draft's lifetime — is told
       `:stale_writer` and has published nothing a reader will keep.

  A removal takes the same lease: `stamped_retire/4` verifies the
  writing member's slot as a commit does, moves the row to `retiring`
  under a token of its own, the deleter deletes the retired revision's
  prefix while it holds it, and `finish_retire/4` retires the row. A
  commit, a registration or another removal against a `retiring` row is
  refused `:stale_writer` while that token lives.

  The draft's lifetime is judged on the cell's clock
  (`Arca.ServerMetaStorage.now!/0`), as every lease in the cell is: the
  instant a draft is registered, taken or given back is written from it
  and compared against it, so members whose own clocks have drifted
  agree which draft is live.

  `abandon_draft/3` gives a draft back without committing, and is how a
  finish that could not move its bytes hands the unit to repair.

  ## The projection generation

  A commit and a retirement each change what the root's domain projection
  must show, so each raises the root's epoch in its own transaction and
  writes the unit's change row at that generation, not ready
  (`Arca.StorageProjectionRoots.advance!/3`); it is announced once the
  transaction commits. `stamped_commit/6` and `stamped_retire/4` answer
  the generation, which the writer marks ready once the move or the delete
  it names has finished and the draft is given back
  (`Arca.StorageProjectionChanges.mark_ready/5`). A retirement writes its tombstone even
  for a unit no row named before it: the bytes it deletes may have been
  laid by hand, and the row it makes is the lease it deletes under.
  Registering, abandoning and releasing a draft change nothing a reader
  sees, and stamp nothing.

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
  journal keeps its earlier commits. So does a `retiring` row whose
  deleter's token has outlived the draft's lifetime: the deleter is dead,
  and what it left of the unit is the collector's, and the next commit's
  to supersede. Registering again with the same token holds, and renews the
  lease. `{:error, :stale_writer}` when another writer's live draft holds
  the unit — a commit being staged or finished, or a removal under way.
  """
  @spec register_draft(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, StorageUnit.t()} | {:error, :stale_writer} | refusal()
  def register_draft(%Prima.Actor{} = actor, root, unit_key, writer_token)
      when is_binary(root) and is_binary(unit_key) and is_binary(writer_token) and
             writer_token != "" do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("register_draft", fn ->
        now = Arca.ServerMetaStorage.now!()
        ensure_row(athanor, root, unit_key, now)
        take_draft(athanor, root, unit_key, writer_token, now)
        held_by(fetch(athanor, root, unit_key), writer_token)
      end)
    end
  end

  @doc """
  Give a draft back without committing: the token is cleared if it is
  still `writer_token`; a unit that was never committed is retired, a
  committed unit keeps its pointer, and a `retiring` unit — its deleter
  giving up or dead — is retired. Idempotent — a draft another writer has
  since taken is left alone.
  """
  @spec abandon_draft(Prima.Actor.t(), StorageUnit.t(), String.t()) :: :ok | refusal()
  def abandon_draft(%Prima.Actor{} = actor, %StorageUnit{} = unit, writer_token)
      when is_binary(writer_token) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("abandon_draft", fn -> release_draft(athanor, unit.id, writer_token) end)
    end
  end

  @doc """
  The unit's row as `writer_token` holds it — the check a release, a
  repair or a removal makes immediately before it touches a revision's
  prefix, under the overlay's node-local fence. `{:error, :stale_writer}`
  when the row is gone or its draft is no longer this writer's: the token
  was taken after it outlived the draft's lifetime, and the unit is its
  taker's.
  """
  @spec held(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, StorageUnit.t()} | {:error, :stale_writer} | refusal()
  def held(%Prima.Actor{} = actor, root, unit_key, writer_token)
      when is_binary(root) and is_binary(unit_key) and is_binary(writer_token) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("held", fn -> held_by(fetch(athanor, root, unit_key), writer_token) end)
    end
  end

  @doc """
  The finish's release: one short transaction that gives the draft back
  only while the row is committed at `revision` and the draft is still
  `writer_token`'s — the revision's prefix is then read through the
  pointer alone, and the next writer may take the unit. `{:error, :stale_revision}` when the
  token is still the writer's but the pointer does not name `revision`;
  `{:error, :stale_writer}` when the draft is no longer the writer's. In
  neither case is anything changed.
  """
  @spec release_served(Prima.Actor.t(), StorageUnit.t(), String.t(), String.t()) ::
          :ok | {:error, :stale_revision | :stale_writer} | refusal()
  def release_served(%Prima.Actor{} = actor, %StorageUnit{} = unit, writer_token, revision)
      when is_binary(writer_token) and is_binary(revision) do
    with {:ok, athanor} <- tenant(actor),
         :ok <- owned(athanor, unit) do
      rescuing_db("release_served", fn ->
        served =
          from(u in where_athanor(StorageUnit, athanor),
            where:
              u.id == ^unit.id and u.state == "committed" and
                u.current_revision == ^revision and u.draft_writer_token == ^writer_token
          )

        case Arca.Repo.update_all(served,
               set: [draft_writer_token: nil, updated_at: Arca.ServerMetaStorage.now!()]
             ) do
          {1, _} ->
            :ok

          {0, _} ->
            case Arca.Repo.one(
                   from(u in where_athanor(StorageUnit, athanor), where: u.id == ^unit.id)
                 ) do
              %StorageUnit{draft_writer_token: ^writer_token} -> {:error, :stale_revision}
              _taken_or_gone -> {:error, :stale_writer}
            end
        end
      end)
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
  `identity.new_revision`, sets the state `committed` and appends one
  journal row — or does none of it. The draft token stays the writer's:
  the writer holds the unit until `release_served/4`, so nothing lands
  over the revision while its bytes move. Answers `t:Arca.Schemas.StorageUnit.commit_result/0`:
  `:stale_revision` when the pointer moved, `:stale_writer` when the draft
  is no longer the writer's, `:missing_unit` for a row that is absent,
  retired, retiring or another athanor's, `:not_owner` when the writing
  member no longer holds its slot in the cell.

  The slot is the one this member holds as the commit begins
  (`Arca.ControlPlane.member_slot/0`, a term read), and the transaction
  verifies it live before it touches the row
  (`Arca.ControlPlane.verify_held/1`, which holds the slot's lease row
  until commit): a takeover of the member's slot either lands first, and
  the pointer does not move, or waits until the commit has landed. A
  member's cached standing outlives the row it stands for by up to a
  renewal, so the cached check every gate makes on the way in is never
  what lets a pointer move. `stamped_commit/6` names the writer instead.
  """
  @spec commit(Prima.Actor.t(), StorageUnit.t(), String.t() | nil, String.t(), identity()) ::
          StorageUnit.commit_result() | {:error, :not_owner | :no_athanor}
  def commit(
        %Prima.Actor{} = actor,
        %StorageUnit{} = unit,
        expected_revision,
        writer_token,
        identity
      ) do
    case stamped_commit(actor, unit, expected_revision, writer_token, identity) do
      {:committed, _generation} -> :committed
      {:error, _} = refusal -> refusal
    end
  end

  @doc """
  `commit/5`, answering the projection generation the commit stamped on
  the unit — the one `Arca.StorageProjectionChanges.mark_ready/5` is
  handed once the committed revision is served.

  `:claim` in `opts` — `%{owner: owner, fence: fence, slot: slot}`, a
  provisioning claim and the member slot it was taken under — makes the
  commit a provisioning attempt's: the transaction verifies THAT slot and
  holds THAT claim (`Arca.ProvisioningClaims.hold?/4`) in place of the
  slot the member holds now, so an attempt whose member lost its slot, or
  whose claim a successor took, moves no pointer even after the member
  has won a newer slot back. Either loss answers `{:error, :not_owner}`.
  Without it the writer is the member as it stands (`commit/5`).
  """
  @spec stamped_commit(
          Prima.Actor.t(),
          StorageUnit.t(),
          String.t() | nil,
          String.t(),
          identity(),
          keyword()
        ) ::
          {:committed, pos_integer()}
          | {:error,
             :stale_revision
             | :stale_writer
             | :missing_unit
             | :not_owner
             | :outcome_unknown
             | :no_athanor}
  def stamped_commit(
        %Prima.Actor{} = actor,
        %StorageUnit{} = unit,
        expected_revision,
        writer_token,
        %{new_revision: new_revision, content_identity: content, commit_identity: who} = identity,
        opts \\ []
      )
      when is_binary(writer_token) and is_binary(new_revision) and is_binary(content) and
             is_binary(who) and (is_nil(expected_revision) or is_binary(expected_revision)) and
             is_list(opts) do
    with {:ok, athanor} <- tenant(actor),
         :ok <- owned(athanor, unit),
         {:ok, writer} <- writer(Keyword.get(opts, :claim)) do
      rescuing_db("commit", fn ->
        move_pointer(actor, athanor, unit, expected_revision, writer_token, identity, writer)
      end)
    end
  end

  # Who a commit or a removal is written for: the member as it stands, or
  # the provisioning attempt a claim names, with the slot it was taken
  # under. A member that holds no slot is refused before any transaction.
  defp writer(nil) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot(), do: {:ok, {:member, slot}}
  end

  defp writer(%{owner: owner, fence: fence, slot: slot})
       when is_binary(owner) and is_integer(fence),
       do: {:ok, {:claim, owner, fence, slot}}

  # Inside the commit's or the removal's locking transaction: the member's
  # slot verified live, or the attempt's slot verified and its claim held.
  defp writes?(_actor, {:member, slot}), do: Arca.ControlPlane.verify_held(slot) == :ok

  defp writes?(actor, {:claim, owner, fence, slot}),
    do: Arca.ProvisioningClaims.hold?(actor, owner, fence, slot)

  @doc """
  The committed pointer of one unit, for a reader to resolve once per
  operation. A draft never committed, a unit being removed and a retired
  unit are `{:error, :not_found}`: readers see no unit.
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
  Retire a unit's row — the drop, rows only: readers see no unit from
  here on, the draft token is cleared, and the pointer keeps its last
  revision for the journal's sake. `stamped_retire/4` and
  `finish_retire/4` with nothing between them; a unit that never had a
  row gets a retired one. `{:error, :stale_writer}` while another
  writer's live draft holds the unit, and `{:error, :not_owner}` from a
  member whose slot is not live, as `stamped_retire/4` answers.
  """
  @spec retire(Prima.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :not_owner | :stale_writer} | refusal()
  def retire(%Prima.Actor{} = actor, root, unit_key) do
    case stamped_retire(actor, root, unit_key) do
      {:retiring, _generation, token} -> finish_retire(actor, root, unit_key, token)
      {:error, _} = refusal -> refusal
    end
  end

  @doc """
  Begin a unit's removal: one locking transaction that takes the unit's
  draft under a fresh token — making the row first when the unit never
  had one — moves the row to `retiring` — readers see no unit from here
  on — and writes the unit's tombstone, not ready, at a new projection
  generation. Answers `{:retiring, generation, token}`:
  the deleter deletes the retired revision's prefix while it holds the
  token, marks the tombstone ready once the tenant delete returns
  (`Arca.StorageProjectionChanges.mark_ready/5`, revision nil) and then
  calls `finish_retire/4`. While the row is `retiring` no commit lands,
  no draft is registered and no second removal begins.

  A unit already retired is taken the same way: a removal that died or
  whose delete was refused left bytes the next removal clears under the
  lease. A unit that never had a row gets one, as a writer's registration
  would give it, and is taken the same way: the bytes a deleter clears
  may have been laid by hand, and a first publication landing meanwhile
  is refused or refuses the delete, never erased by it. `{:error,
  :stale_writer}` when another writer's live draft holds the unit — a
  commit being staged or finished, or another removal — and nothing is
  written: the caller asks again once that writer is done.

  The writer is verified before the row moves, in this transaction, as
  `stamped_commit/6` verifies a commit's: the slot this member holds as
  the removal begins (`Arca.ControlPlane.member_slot/0`), verified live
  (`Arca.ControlPlane.verify_held/1`, which holds the slot's lease row
  until commit), so a member whose slot a successor took over retires
  nothing and deletes nothing, however its cached standing reads, and is
  answered `{:error, :not_owner}`. `:claim` in `opts` is
  `stamped_commit/6`'s: a provisioning attempt's retirement — the cleanup
  of a unit its own publish committed — lands only while the attempt
  still holds its claim and the slot it was taken under, both held in
  this transaction before the row moves, and answers
  `{:error, :not_owner}` with nothing retired otherwise, so a resumed
  stale attempt never retires its successor's unit.
  """
  @spec stamped_retire(Prima.Actor.t(), String.t(), String.t(), keyword()) ::
          {:retiring, pos_integer(), String.t()}
          | {:error, :not_owner | :stale_writer}
          | refusal()
  def stamped_retire(%Prima.Actor{} = actor, root, unit_key, opts \\ [])
      when is_binary(root) and is_binary(unit_key) and is_list(opts) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, writer} <- writer(Keyword.get(opts, :claim)) do
      token = new_writer_token()

      answer =
        rescuing_db("retire", fn ->
          Arca.Repo.locking_transaction(fn ->
            unless writes?(actor, writer), do: Arca.Repo.rollback(:not_owner)

            case retire_row(athanor, root, unit_key, token) do
              :stale_writer -> Arca.Repo.rollback(:stale_writer)
              :retiring -> tombstone!(actor, root, unit_key)
            end
          end)
        end)

      case answer do
        {:ok, generation} ->
          StorageProjectionChanges.announce(athanor, root, generation, false)
          {:retiring, generation, token}

        {:error, _} = refusal ->
          refusal
      end
    end
  end

  @doc """
  End a unit's removal: the row `stamped_retire/4` moved to `retiring`
  becomes `retired` and its token is cleared, in one short transaction,
  only while the token is still `token` — the retired revision's prefix
  is then deleted, or the delete was refused and left bytes the collector
  or a later drop clears.
  `{:error, :stale_writer}` when the row is no longer this deleter's: its
  token outlived the draft's lifetime and a writer took the unit.
  """
  @spec finish_retire(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :stale_writer} | refusal()
  def finish_retire(%Prima.Actor{} = actor, root, unit_key, token)
      when is_binary(root) and is_binary(unit_key) and is_binary(token) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("finish_retire", fn ->
        retiring =
          from(u in by_key(where_athanor(StorageUnit, athanor), root, unit_key),
            where: u.state == "retiring" and u.draft_writer_token == ^token
          )

        case Arca.Repo.update_all(retiring,
               set: [
                 state: "retired",
                 draft_writer_token: nil,
                 updated_at: Arca.ServerMetaStorage.now!()
               ]
             ) do
          {1, _} -> :ok
          {0, _} -> {:error, :stale_writer}
        end
      end)
    end
  end

  defp tombstone!(actor, root, unit_key) do
    StorageProjectionRoots.advance!(actor, root, %{
      unit_key: unit_key,
      ready: false,
      tombstone: true,
      source_revision: nil
    })
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
  defp ensure_row(athanor, root, unit_key, now) do
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
  # or when its holder registered longer ago than the draft lives, on the
  # cell's clock `now` was read from. A retired row, and a retiring one
  # whose deleter's token has outlived the lifetime, come back as a draft
  # with no pointer.
  defp take_draft(athanor, root, unit_key, writer_token, now) do
    free =
      from(u in by_key(where_athanor(StorageUnit, athanor), root, unit_key),
        where:
          is_nil(u.draft_writer_token) or u.draft_writer_token == ^writer_token or
            u.updated_at < ^expiry(now)
      )

    {revived, _} =
      Arca.Repo.update_all(from(u in free, where: u.state in ["retired", "retiring"]),
        set: [
          state: "draft",
          current_revision: nil,
          draft_writer_token: writer_token,
          updated_at: now
        ]
      )

    if revived == 0 do
      Arca.Repo.update_all(from(u in free, where: u.state in ["draft", "committed"]),
        set: [draft_writer_token: writer_token, updated_at: now]
      )
    end

    :ok
  end

  # When a token registered before this moment, on the cell's clock, has
  # outlived the draft.
  defp expiry(now), do: DateTime.add(now, -@draft_ttl_ms, :millisecond)

  defp held_by(%StorageUnit{draft_writer_token: token} = unit, token), do: {:ok, unit}
  defp held_by(_another_writers_or_gone, _token), do: {:error, :stale_writer}

  defp release_draft(athanor, id, writer_token) do
    now = Arca.ServerMetaStorage.now!()

    held =
      from(u in where_athanor(StorageUnit, athanor),
        where: u.id == ^id and u.draft_writer_token == ^writer_token
      )

    Arca.Repo.update_all(from(u in held, where: u.state in ["draft", "retiring"]),
      set: [state: "retired", draft_writer_token: nil, updated_at: now]
    )

    Arca.Repo.update_all(from(u in held, where: u.state == "committed"),
      set: [draft_writer_token: nil, updated_at: now]
    )

    :ok
  end

  # The removal's take of the lease: the unit's row — made if the unit
  # never had one, as a writer's registration makes it, so that bytes no
  # row names are removed under the same lease a first publication must
  # take — moves to `retiring` under the deleter's token in one
  # conditional update when its draft is nobody's or its holder's token
  # has outlived the lifetime, whatever its state: a retired row too,
  # since what an earlier removal left behind is cleared under the lease
  # as well. A live token is another writer's — a commit staging or
  # finishing, or a removal under way — and refuses.
  defp retire_row(athanor, root, unit_key, token) do
    now = Arca.ServerMetaStorage.now!()
    ensure_row(athanor, root, unit_key, now)

    takeable =
      from(u in by_key(where_athanor(StorageUnit, athanor), root, unit_key),
        where: is_nil(u.draft_writer_token) or u.updated_at < ^expiry(now)
      )

    case Arca.Repo.update_all(takeable,
           set: [state: "retiring", draft_writer_token: token, updated_at: now]
         ) do
      {1, _} -> :retiring
      {0, _} -> :stale_writer
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
  # one transaction, so none exists without the others. The writer is
  # verified first — its slot under the lease row's shared lock, and an
  # attempt's claim row held — so a writer that lost either moves no
  # pointer and a takeover cannot land between the check and the move. The compare is the update's own WHERE: no
  # read-then-write window, on either adapter. The unit row is locked by
  # that update before the root's epoch is raised — the order every
  # storage writer keeps — and the root and key the generation is stamped
  # on are the row's, never the caller's struct's. The change is announced
  # once it has committed.
  defp move_pointer(
         actor,
         athanor,
         %StorageUnit{id: id},
         expected_revision,
         writer_token,
         identity,
         writer
       ) do
    now = Arca.ServerMetaStorage.now!()

    Arca.Repo.locking_transaction(fn ->
      unless writes?(actor, writer), do: Arca.Repo.rollback(:not_owner)

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
        where:
          u.id == ^id and u.state in ["draft", "committed"] and
            u.draft_writer_token == ^writer_token
      )

    at_expected =
      if is_nil(expected_revision),
        do: from(u in held, where: is_nil(u.current_revision)),
        else: from(u in held, where: u.current_revision == ^expected_revision)

    # The token stays: the writer holds the unit until `release_served/4`,
    # so nothing lands between its commit and its release.
    {_moved, keys} =
      Arca.Repo.update_all(from(u in at_expected, select: {u.root, u.unit_key}),
        set: [
          state: "committed",
          current_revision: identity.new_revision,
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
      %StorageUnit{state: gone} when gone in ["retired", "retiring"] -> :missing_unit
      %StorageUnit{current_revision: ^expected_revision} -> :stale_writer
      %StorageUnit{} -> :stale_revision
    end
  end
end
