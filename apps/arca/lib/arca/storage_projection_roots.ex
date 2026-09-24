# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageProjectionRoots do
  @moduledoc """
  The epoch of a seeded root in one athanor: the counter every change of a
  unit under the root raises, and the generation that change takes.

  `advance!/3` is the one writer. It runs inside the transaction that
  makes the change — a commit's pointer move, a retirement, a repair's
  pending mark, an edit's marks — raises the root's epoch by one and
  writes the unit's change row at that generation, so the change and its
  generation commit together or not at all. The root row is created by
  its first advance and never deleted: a unit dropped and recreated takes
  a generation above every one it held before, whatever retention later
  does with the deletion's evidence.

  ## Lock order

  The root row, then the change rows by unit key, everywhere
  (`Arca.StorageProjectionChanges`). `advance!/3` takes the root row by
  the increment itself and then the one change row; on PostgreSQL a
  replacement that holds the root row (`for_update/1`) makes every
  advance of that root wait for its commit. On SQLite every transaction
  holds the one write lock from its start (`Arca.Repo.locking_transaction/2`).

  ## Tenancy

  Every function takes the `Prima.Actor` first. `epoch/2` refuses an actor
  with no athanor as `{:error, :no_athanor}` before any query; `advance!/3`
  runs inside a caller's transaction and raises instead
  (`Arca.QueryHelpers.no_athanor!/1`).
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.{StorageProjectionChange, StorageProjectionRoot}

  @typedoc "One unit's change, as `advance!/3` writes it."
  @type change :: %{
          required(:unit_key) => String.t(),
          required(:ready) => boolean(),
          required(:tombstone) => boolean(),
          required(:source_revision) => String.t() | nil
        }

  @typedoc "A root's epoch and the epoch its projection has acknowledged; 0 and 0 before any change."
  @type standing :: %{epoch: non_neg_integer(), acknowledged_epoch: non_neg_integer()}

  @doc """
  Raise the root's epoch and write `change` for its unit at the new
  epoch, answering that generation. Inside a transaction the caller owns:
  raises when there is none, and on any database fault, so the caller's
  change rolls back with it.

  The unit's `acknowledged_generation` is kept: a projection that
  acknowledged an earlier generation of the unit has not seen this one.
  """
  @spec advance!(Prima.Actor.t(), String.t(), change()) :: pos_integer()
  # arca:db-raise-ok a step of the caller's transaction: a fault must roll
  # the change it stamps back with it.
  def advance!(%Prima.Actor{} = actor, root, %{unit_key: unit_key} = change)
      when is_binary(root) and is_binary(unit_key) do
    athanor = athanor!(actor, "advance!/3")

    unless Arca.Repo.in_transaction?() do
      raise ArgumentError,
            "Arca.StorageProjectionRoots.advance!/3 runs inside the transaction of the change"
    end

    now = DateTime.utc_now()
    ensure_root!(athanor, root)

    {1, [epoch]} =
      Arca.Repo.update_all(
        from(r in where_athanor(StorageProjectionRoot, athanor),
          where: r.root == ^root,
          select: r.epoch
        ),
        inc: [epoch: 1]
      )

    write_change!(athanor, root, change, epoch, now)
    epoch
  end

  @doc """
  The root's epoch and the epoch its projection acknowledged, read in one
  consistent read (`Arca.Repo.read_transaction/1`): the barrier's
  question, one row by its unique key. A root no change has touched is
  `%{epoch: 0, acknowledged_epoch: 0}`. `{:error, :unavailable}` when the
  store cannot answer.
  """
  @spec epoch(Prima.Actor.t(), String.t()) ::
          {:ok, standing()} | {:error, :no_athanor | :unavailable}
  def epoch(%Prima.Actor{} = actor, root) when is_binary(root) do
    with {:ok, athanor} <- tenant(actor) do
      rescuing_db("epoch", fn ->
        Arca.Repo.read_transaction(fn -> standing(athanor, root) end)
      end)
    end
  end

  @doc false
  # The standing of one root, read inside the caller's transaction.
  @spec standing(String.t(), String.t()) :: standing()
  # arca:db-raise-ok a read inside the caller's transaction, which rescues.
  def standing(athanor, root) do
    from(r in where_athanor(StorageProjectionRoot, athanor),
      where: r.root == ^root,
      select: %{epoch: r.epoch, acknowledged_epoch: r.acknowledged_epoch}
    )
    |> Arca.Repo.one()
    |> Kernel.||(%{epoch: 0, acknowledged_epoch: 0})
  end

  # Insert-if-absent, so two first changes of one root both find a row to
  # raise instead of one of them raising on the unique index. The row is
  # born at 1 and raised to 2 by the advance that created it: the check
  # constraint wants a positive epoch, and 1 is never a generation.
  defp ensure_root!(athanor, root) do
    Arca.Repo.insert_all(
      StorageProjectionRoot,
      [
        %{
          id: Prima.UUID7.generate_id("spr"),
          athanor_id: athanor,
          root: root,
          epoch: 1,
          acknowledged_epoch: 0
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:athanor_id, :root]
    )
  end

  defp write_change!(athanor, root, change, generation, now) do
    Arca.Repo.insert_all(
      StorageProjectionChange,
      [
        %{
          id: Prima.UUID7.generate_id("spc"),
          athanor_id: athanor,
          root: root,
          unit_key: change.unit_key,
          generation: generation,
          ready: change.ready,
          source_revision: change.source_revision,
          tombstone: change.tombstone,
          acknowledged_generation: 0,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:generation, :ready, :source_revision, :tombstone, :updated_at]},
      conflict_target: [:athanor_id, :root, :unit_key]
    )
  end

  defp tenant(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Prima.Actor{}), do: {:error, :no_athanor}

  defp athanor!(actor, fun) do
    case tenant(actor) do
      {:ok, athanor} -> athanor
      {:error, :no_athanor} -> Arca.QueryHelpers.no_athanor!("Arca.StorageProjectionRoots.#{fun}")
    end
  end

  defp rescuing_db(entry, fun) do
    case Arca.Repo.Errors.with_db_rescue("Arca.StorageProjectionRoots.#{entry}", fun) do
      {:error, :database_error} -> {:error, :unavailable}
      answer -> answer
    end
  end
end
