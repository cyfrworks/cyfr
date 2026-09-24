# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageProjectionChanges do
  @moduledoc """
  The pending changes of a seeded root's units, as a domain projection of
  that root must consume them: which generation each unit last took,
  whether the bytes that change names are served, and which generation
  the projection has acknowledged.

  Generic storage: a row says a unit changed and nothing about what the
  unit means. The projection that reads a root is its domain's; this
  module never names one.

  ## The writers

  Every change takes its generation from `Arca.StorageProjectionRoots.advance!/3`
  in the transaction that makes it:

    * a publication (`Arca.StorageUnits` moving a unit's pointer) writes
      the new revision not ready, and `mark_ready/5` marks it once its
      move to the served location finishes;
    * a retirement writes a tombstone not ready, even for a unit no row
      names, marked ready once the tenant delete returns;
    * a repair writes the unit's revision not ready before it touches a
      served byte (`begin_repair/4`), marked ready when it finishes;
    * an edit inside a unit writes a pending generation before the write
      (`begin_edit/3`) and a later, ready one after it (`finish_edit/4`).

  `mark_ready/5` acts only while the unit's row still holds the
  generation and revision it was given, so a finisher a later change
  overtook marks nothing. A row already ready at that generation was
  settled underneath its writer (`settle_stale/3`), and is raised to a
  new ready generation instead: what a projection derived while the move
  ran is derived again.

  ## The reader

  `snapshot/3` is a token naming the root's epoch and every pending unit
  (and any unit asked for) at one consistent read. The domain derives its
  rows from the tree after it, and replaces them through its own storage
  facade, which runs `replace/4`: one locking transaction that holds the
  root row and then every named unit's row in unit-key order, compares
  each with the token, writes the rows and sets the acknowledgments — or
  rolls all of it back as `{:error, :generation_conflict}`. A unit created
  after the snapshot raised the epoch, so it invalidates the whole
  replacement even when the token never named it.

  ## Notification

  Every committed change is announced as the telemetry event
  `[:cyfr, :storage_projection, :changed]` after its transaction commits,
  never inside it. Nothing depends on it being heard: a reader compares
  the epoch with what was acknowledged (`Arca.StorageProjectionRoots.epoch/2`).

  ## Tenancy

  Every function takes the `Cyfr.Actor` first and refuses one with no
  athanor as `{:error, :no_athanor}` before any query, except
  `pending_athanors/2`, the recovery walk across estates, which a
  platform-scope actor alone may make. A token names its athanor, and a
  replacement under another athanor's actor is `{:error, :cross_tenant}`.
  A store that cannot answer is `{:error, :unavailable}`.
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2, for_update: 1]

  require Logger

  alias Arca.Schemas.{StorageProjectionChange, StorageProjectionRoot, StorageUnit}
  alias Arca.Storage.UnitLocator
  alias Arca.StorageProjectionRoots

  @event [:cyfr, :storage_projection, :changed]

  @type refusal :: {:error, :no_athanor | :unavailable}

  @typedoc """
  One unit as a snapshot names it. `pending` is `generation >
  acknowledged_generation`; a unit asked for that no change has touched
  is generation 0, ready and not pending. `updated_at` is when its change
  was last written, nil for such a unit.
  """
  @type unit :: %{
          unit_key: String.t(),
          generation: non_neg_integer(),
          ready: boolean(),
          tombstone: boolean(),
          source_revision: String.t() | nil,
          acknowledged_generation: non_neg_integer(),
          pending: boolean(),
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  What a replacement must still find: the athanor and root it was read
  for, the root's epoch then, and every pending unit with every unit asked
  for, ordered by unit key.
  """
  @type token :: %{
          athanor_id: String.t(),
          root: String.t(),
          epoch: non_neg_integer(),
          acknowledged_epoch: non_neg_integer(),
          units: [unit()]
        }

  @doc "The telemetry event every committed change is announced as."
  @spec event() :: [atom(), ...]
  def event, do: @event

  # ---------------------------------------------------------------------------
  # The reader
  # ---------------------------------------------------------------------------

  @doc """
  A token for replacing the projection of `root`: the root's epoch and the
  units whose change the projection has not acknowledged, at one
  consistent read (`Arca.Repo.read_transaction/1`).

  `units:` names unit keys to include whether pending or not — a caller
  deriving those units whatever the rows say.
  """
  @spec snapshot(Cyfr.Actor.t(), String.t(), keyword()) :: {:ok, token()} | refusal()
  def snapshot(%Cyfr.Actor{} = actor, root, opts \\ []) when is_binary(root) and is_list(opts) do
    requested = opts |> Keyword.get(:units, []) |> MapSet.new()

    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("snapshot", fn ->
        Arca.Repo.read_transaction(fn ->
          standing = StorageProjectionRoots.standing(athanor, root)
          rows = snapshot_rows(athanor, root, requested)
          found = MapSet.new(rows, & &1.unit_key)

          absent =
            for key <- requested, not MapSet.member?(found, key), do: untouched(key)

          %{
            athanor_id: athanor,
            root: root,
            epoch: standing.epoch,
            acknowledged_epoch: standing.acknowledged_epoch,
            units: Enum.sort_by(Enum.map(rows, &unit/1) ++ absent, & &1.unit_key)
          }
        end)
      end)
    end
  end

  # The pending rows; with units asked for, the whole root, filtered here
  # rather than bound one parameter per key.
  defp snapshot_rows(athanor, root, requested) do
    if MapSet.size(requested) == 0 do
      from(c in where_athanor(StorageProjectionChange, athanor),
        where: c.root == ^root and c.generation > c.acknowledged_generation
      )
      |> Arca.Repo.all()
    else
      from(c in where_athanor(StorageProjectionChange, athanor), where: c.root == ^root)
      |> Arca.Repo.all()
      |> Enum.filter(
        &(&1.generation > &1.acknowledged_generation or MapSet.member?(requested, &1.unit_key))
      )
    end
  end

  defp unit(%StorageProjectionChange{} = row) do
    %{
      unit_key: row.unit_key,
      generation: row.generation,
      ready: row.ready,
      tombstone: row.tombstone,
      source_revision: row.source_revision,
      acknowledged_generation: row.acknowledged_generation,
      pending: row.generation > row.acknowledged_generation,
      updated_at: row.updated_at
    }
  end

  defp untouched(key) do
    %{
      unit_key: key,
      generation: 0,
      ready: true,
      tombstone: false,
      source_revision: nil,
      acknowledged_generation: 0,
      pending: false,
      updated_at: nil
    }
  end

  @doc """
  Whether a replacement made under `token` acknowledges the root's epoch:
  every pending unit it names is ready. A pending unit that is not is
  left pending, and so is the root.
  """
  @spec complete?(token()) :: boolean()
  def complete?(%{units: units}), do: Enum.all?(units, &(&1.ready or not &1.pending))

  @doc false
  # The replacement transaction every projection's storage facade runs:
  # hold and check the token, run `write` (which may roll back with its
  # own reason), then acknowledge. The acknowledgment never lowers a
  # generation or an epoch.
  @spec replace(Cyfr.Actor.t(), String.t(), token(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def replace(%Cyfr.Actor{} = actor, root, token, write)
      when is_binary(root) and is_function(write, 0) do
    with {:ok, athanor} <- tenant(actor),
         :ok <- token_for(athanor, root, token) do
      Arca.Repo.locking_transaction(fn ->
        hold!(athanor, token)
        result = write.()
        acknowledge!(athanor, token)
        result
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp token_for(athanor, root, %{athanor_id: athanor, root: root, epoch: epoch, units: units})
       when is_integer(epoch) and is_list(units),
       do: :ok

  defp token_for(athanor, _root, %{athanor_id: other}) when is_binary(other) and other != athanor,
    do: {:error, :cross_tenant}

  defp token_for(_athanor, _root, _token), do: {:error, :invalid_token}

  # The root row first, then each named unit's row in unit-key order: the
  # lock order every writer of these rows keeps.
  defp hold!(athanor, %{root: root, epoch: epoch, units: units}) do
    held =
      from(r in where_athanor(StorageProjectionRoot, athanor),
        where: r.root == ^root,
        select: r.epoch
      )
      |> for_update()
      |> Arca.Repo.one()

    if (held || 0) != epoch, do: Arca.Repo.rollback(:generation_conflict)

    keys = Enum.map(units, & &1.unit_key)

    current =
      from(c in where_athanor(StorageProjectionChange, athanor),
        where: c.root == ^root and c.unit_key in ^keys,
        order_by: [asc: c.unit_key],
        select: {c.unit_key, c.generation}
      )
      |> for_update()
      |> Arca.Repo.all()
      |> Map.new()

    for %{unit_key: key, generation: generation} <- units,
        Map.get(current, key, 0) != generation do
      Arca.Repo.rollback(:generation_conflict)
    end

    :ok
  end

  defp acknowledge!(athanor, %{root: root, epoch: epoch, units: units} = token) do
    ready = for %{ready: true, generation: generation} = unit <- units, generation > 0, do: unit.unit_key

    if ready != [] do
      from(c in where_athanor(StorageProjectionChange, athanor),
        where:
          c.root == ^root and c.unit_key in ^ready and
            c.acknowledged_generation < c.generation,
        update: [set: [acknowledged_generation: c.generation]]
      )
      |> Arca.Repo.update_all([])
    end

    if complete?(token) and epoch > 0 do
      from(r in where_athanor(StorageProjectionRoot, athanor),
        where: r.root == ^root and r.epoch == ^epoch and r.acknowledged_epoch < ^epoch
      )
      |> Arca.Repo.update_all(set: [acknowledged_epoch: epoch])
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # The writers
  # ---------------------------------------------------------------------------

  @doc """
  Mark a publication's, a repair's or a retirement's change ready, once
  the move or the delete it names has finished: only while the unit's row
  still holds `generation` and `source_revision` (nil for a tombstone).

  A row already ready there was settled while its writer worked
  (`settle_stale/3`), and is raised to a new ready generation, so a
  projection derived before the move finished is derived again.
  `{:error, :stale_generation}` when a later change has overtaken it:
  that change is the one to mark.
  """
  @spec mark_ready(Cyfr.Actor.t(), String.t(), String.t(), pos_integer(), String.t() | nil) ::
          :ok | {:error, :stale_generation} | refusal()
  def mark_ready(%Cyfr.Actor{} = actor, root, unit_key, generation, source_revision)
      when is_binary(root) and is_binary(unit_key) and is_integer(generation) and
             (is_nil(source_revision) or is_binary(source_revision)) do
    with {:ok, athanor} <- tenant(actor) do
      "mark_ready"
      |> rescuing_db(fn ->
        Arca.Repo.locking_transaction(fn ->
          epoch = lock_root(athanor, root)

          case lock_change(athanor, root, unit_key) do
            %{generation: ^generation, source_revision: ^source_revision, ready: false} = row ->
              set_ready!(row)
              epoch

            %{generation: ^generation, source_revision: ^source_revision, tombstone: tombstone} ->
              StorageProjectionRoots.advance!(actor, root, %{
                unit_key: unit_key,
                ready: true,
                tombstone: tombstone,
                source_revision: source_revision
              })

            _overtaken ->
              Arca.Repo.rollback(:stale_generation)
          end
        end)
      end)
      |> announced(athanor, root, true)
      |> case do
        {:ok, _epoch} -> :ok
        {:error, _} = refusal -> refusal
      end
    end
  end

  @doc """
  An edit inside a unit is about to write: the unit's pending generation,
  before a byte moves. Answers the generation `finish_edit/4` is handed.
  The change names the unit's committed revision, if a commit published
  it.
  """
  @spec begin_edit(Cyfr.Actor.t(), String.t(), String.t()) ::
          {:ok, pos_integer()} | refusal()
  def begin_edit(%Cyfr.Actor{} = actor, root, unit_key)
      when is_binary(root) and is_binary(unit_key) do
    with {:ok, athanor} <- tenant(actor) do
      "begin_edit"
      |> rescuing_db(fn ->
        Arca.Repo.locking_transaction(fn ->
          StorageProjectionRoots.advance!(actor, root, %{
            unit_key: unit_key,
            ready: false,
            tombstone: false,
            source_revision: committed_revision(athanor, root, unit_key)
          })
        end)
      end)
      |> announced(athanor, root, false)
    end
  end

  @doc """
  An edit's write has returned: the unit takes a new, ready generation,
  above the pending one `begin_edit/3` answered, in one transaction. A
  row another writer has since made pending is that writer's to mark,
  and its generation covers this write: `{:ok, :covered}`.
  """
  @spec finish_edit(Cyfr.Actor.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, pos_integer() | :covered} | refusal()
  def finish_edit(%Cyfr.Actor{} = actor, root, unit_key, pending_generation)
      when is_binary(root) and is_binary(unit_key) and is_integer(pending_generation) do
    with {:ok, athanor} <- tenant(actor) do
      answer =
        rescuing_db("finish_edit", fn ->
          Arca.Repo.locking_transaction(fn ->
            _epoch = lock_root(athanor, root)

            case lock_change(athanor, root, unit_key) do
              %{ready: false, generation: generation} when generation != pending_generation ->
                :covered

              _mine_or_ready ->
                StorageProjectionRoots.advance!(actor, root, %{
                  unit_key: unit_key,
                  ready: true,
                  tombstone: false,
                  source_revision: committed_revision(athanor, root, unit_key)
                })
            end
          end)
        end)

      case answer do
        {:ok, :covered} -> {:ok, :covered}
        other -> announced(other, athanor, root, true)
      end
    end
  end

  @doc """
  A repair is about to move `revision` of a unit to the served location:
  the unit's pending generation, the revision unchanged. Answers the
  generation `mark_ready/5` is handed when the move finishes.
  """
  @spec begin_repair(Cyfr.Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, pos_integer()} | refusal()
  def begin_repair(%Cyfr.Actor{} = actor, root, unit_key, revision)
      when is_binary(root) and is_binary(unit_key) and is_binary(revision) do
    with {:ok, athanor} <- tenant(actor) do
      "begin_repair"
      |> rescuing_db(fn ->
        Arca.Repo.locking_transaction(fn ->
          StorageProjectionRoots.advance!(actor, root, %{
            unit_key: unit_key,
            ready: false,
            tombstone: false,
            source_revision: revision
          })
        end)
      end)
      |> announced(athanor, root, false)
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery and retention
  # ---------------------------------------------------------------------------

  @doc """
  Settle the root's changes whose writer is gone: every change not ready
  and last written more than `settle_after_ms:` ago (option, required;
  `now:` for the clock) is repaired or marked ready where it stands.

  Each is first asked of `Arca.Overlay.repair_unit/2`. A move the journal
  proves is finished there, and the repair marks its own new generation.
  Nothing to move (an edit, a deletion, a unit laid by hand), or only the
  remainder of a move that already served the whole revision, and the
  change is marked ready at its generation: a writer still working marks
  a newer one when it returns (`finish_edit/4`, `mark_ready/5`), so the
  projection derives again. A change whose move cannot be proven — a
  journal that names another revision, a store that does not answer — is
  left pending. Answers how many changes are ready now.
  """
  @spec settle_stale(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | refusal()
  def settle_stale(%Cyfr.Actor{} = actor, root, opts) when is_binary(root) and is_list(opts) do
    after_ms = Keyword.fetch!(opts, :settle_after_ms)
    cutoff = DateTime.add(Keyword.get(opts, :now, DateTime.utc_now()), -after_ms, :millisecond)

    with {:ok, athanor} <- tenant(actor),
         {:ok, stale} <- rescuing_db("settle_stale", fn -> {:ok, stale(athanor, root, cutoff)} end) do
      {:ok, Enum.count(stale, &settle(actor, athanor, root, &1))}
    end
  end

  defp stale(athanor, root, cutoff) do
    from(c in where_athanor(StorageProjectionChange, athanor),
      where: c.root == ^root and not c.ready and c.updated_at < ^cutoff,
      order_by: [asc: c.unit_key]
    )
    |> Arca.Repo.all()
  end

  defp settle(actor, athanor, root, %StorageProjectionChange{} = row) do
    case Arca.Overlay.repair_unit(actor, UnitLocator.unit_path(root, row.unit_key)) do
      {:ok, :repaired} ->
        true

      {:ok, :nothing_pending} ->
        settle_row(athanor, root, row)

      {:error, finished} when finished in [:staged_incomplete, :not_found] ->
        settle_row(athanor, root, row)

      {:error, unlocatable} when unlocatable in [:not_overlaid, :not_a_unit] ->
        settle_row(athanor, root, row)

      {:error, reason} ->
        Logger.warning(
          "[Arca.StorageProjectionChanges] #{root}/#{row.unit_key} stays pending: " <>
            inspect(reason)
        )

        false
    end
  end

  defp settle_row(athanor, root, row) do
    "settle_stale"
    |> rescuing_db(fn ->
      Arca.Repo.locking_transaction(fn ->
        epoch = lock_root(athanor, root)

        case lock_change(athanor, root, row.unit_key) do
          %{generation: generation, ready: false} = held when generation == row.generation ->
            set_ready!(held)
            epoch

          _moved_on ->
            Arca.Repo.rollback(:stale_generation)
        end
      end)
    end)
    |> announced(athanor, root, true)
    |> settled?()
  end

  defp settled?({:ok, _epoch}), do: true
  defp settled?(_refused), do: false

  @doc """
  The estates holding a root whose projection is behind its epoch — the
  recovery walk's roster, read before any caller is known. The one read
  across estates here, and a platform-scope actor's alone
  (`{:error, :forbidden}` for any other). `limit:` bounds it (default
  1000).
  """
  @spec pending_athanors(Cyfr.Actor.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, :forbidden | :unavailable}
  def pending_athanors(actor, opts \\ [])

  def pending_athanors(%Cyfr.Actor{scope: :platform}, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 1000)
    rescuing_db("pending_athanors", fn -> {:ok, behind(limit)} end)
  end

  def pending_athanors(%Cyfr.Actor{}, _opts), do: {:error, :forbidden}

  # arca:unscoped-ok the recovery walk reads every estate's root rows to find a projection behind its epoch before any caller is known (Cyfr.Boundaries.system_responsibilities/0).
  defp behind(limit) do
    from(r in StorageProjectionRoot,
      where: r.epoch > r.acknowledged_epoch,
      distinct: true,
      order_by: [asc: r.athanor_id],
      select: r.athanor_id,
      limit: ^limit
    )
    |> Arca.Repo.all()
  end

  @doc """
  Remove the root's deletion evidence the projection has fully consumed:
  tombstones that are ready, acknowledged at their own generation, and
  last written before `before:` (option, required). The root's epoch is
  untouched, so a unit recreated later still takes a newer generation.
  Answers the count removed; with `dry_run: true`, the count the same
  rows would be, removing nothing.
  """
  @spec prune_acknowledged_tombstones(Cyfr.Actor.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | refusal()
  def prune_acknowledged_tombstones(%Cyfr.Actor{} = actor, root, opts)
      when is_binary(root) and is_list(opts) do
    before = Keyword.fetch!(opts, :before)

    with {:ok, athanor} <- tenant(actor) do
      if Keyword.get(opts, :dry_run, false) do
        rescuing_db("prune_acknowledged_tombstones", fn ->
          {:ok, Arca.Repo.aggregate(consumed_tombstones(athanor, root, before), :count)}
        end)
      else
        rescuing_db("prune_acknowledged_tombstones", fn ->
          Arca.Repo.locking_transaction(fn ->
            _epoch = lock_root(athanor, root)
            {count, _} = Arca.Repo.delete_all(consumed_tombstones(athanor, root, before))
            count
          end)
        end)
      end
    end
  end

  # What fully consumed deletion evidence is, for the prune and its count
  # alike.
  defp consumed_tombstones(athanor, root, before) do
    from(c in where_athanor(StorageProjectionChange, athanor),
      where:
        c.root == ^root and c.tombstone and c.ready and
          c.acknowledged_generation == c.generation and c.updated_at < ^before
    )
  end

  # ---------------------------------------------------------------------------
  # Announcement
  # ---------------------------------------------------------------------------

  @doc false
  # After the owning transaction has committed, never inside it.
  @spec announce(String.t(), String.t(), non_neg_integer(), boolean()) :: :ok
  def announce(athanor, root, epoch, ready)
      when is_binary(athanor) and is_binary(root) and is_integer(epoch) and is_boolean(ready) do
    :telemetry.execute(@event, %{epoch: epoch}, %{athanor_id: athanor, root: root, ready: ready})
  end

  defp announced({:ok, epoch}, athanor, root, ready) when is_integer(epoch) do
    announce(athanor, root, epoch, ready)
    {:ok, epoch}
  end

  defp announced(other, _athanor, _root, _ready), do: other

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  defp lock_root(athanor, root) do
    from(r in where_athanor(StorageProjectionRoot, athanor),
      where: r.root == ^root,
      select: r.epoch
    )
    |> for_update()
    |> Arca.Repo.one()
    |> Kernel.||(0)
  end

  defp lock_change(athanor, root, unit_key) do
    from(c in where_athanor(StorageProjectionChange, athanor),
      where: c.root == ^root and c.unit_key == ^unit_key
    )
    |> for_update()
    |> Arca.Repo.one()
  end

  defp set_ready!(%StorageProjectionChange{id: id, athanor_id: athanor}) do
    {1, _} =
      from(c in where_athanor(StorageProjectionChange, athanor), where: c.id == ^id)
      |> Arca.Repo.update_all(set: [ready: true, updated_at: DateTime.utc_now()])

    :ok
  end

  # The revision a commit published the unit at, if one did.
  defp committed_revision(athanor, root, unit_key) do
    from(u in where_athanor(StorageUnit, athanor),
      where: u.root == ^root and u.unit_key == ^unit_key and u.state == "committed",
      select: u.current_revision
    )
    |> Arca.Repo.one()
  end

  defp tenant(%Cyfr.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Cyfr.Actor{}), do: {:error, :no_athanor}

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageProjectionChanges.#{entry}", fun) do
      {:error, :database_error} -> {:error, :unavailable}
      answer -> answer
    end
  end
end
