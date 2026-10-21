# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.StorageJournal do
  @moduledoc """
  A unit's commits as a test observes them: the journal rows
  `Arca.StorageUnits.commit/5` writes, oldest first, in the actor's
  athanor. A unit with no row is `{:error, :not_found}`; a retired unit
  keeps its journal.
  """

  import Ecto.Query

  alias Arca.Schemas.{StorageCommit, StorageUnit}

  @spec journal(Prima.Actor.t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def journal(%Prima.Actor{athanor_id: athanor}, root, unit_key)
      when is_binary(athanor) and athanor != "" and is_binary(root) and is_binary(unit_key) do
    unit =
      Arca.Repo.one(
        from(u in StorageUnit,
          where: u.athanor_id == ^athanor and u.root == ^root and u.unit_key == ^unit_key
        )
      )

    case unit do
      nil ->
        {:error, :not_found}

      %StorageUnit{id: id} ->
        from(c in StorageCommit,
          where: c.athanor_id == ^athanor and c.storage_unit_id == ^id,
          order_by: [asc: c.committed_at, asc: c.id]
        )
        |> Arca.Repo.all()
        |> then(&{:ok, &1})
        |> Arca.Data.project()
    end
  end
end
