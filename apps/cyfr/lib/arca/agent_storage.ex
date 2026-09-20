# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentStorage do
  @moduledoc """
  The `agents` rows — the derived index of an athanor's `aqua/` tree
  (`Compendium.AgentIndex` derives them; this module is the only place
  they are read and written).

  Both functions take the `Cyfr.Actor` first and match it in the head, so
  the estate whose index is rewritten comes from the caller; an actor
  whose athanor is nil or the empty string is `{:error, :no_athanor}`
  before any query.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Agent

  @doc """
  Replace the athanor's rows with `rows`, in one transaction: the index is
  a whole rewrite from the tree, never a merge.
  """
  @spec replace_all(Cyfr.Actor.t(), [map()]) :: {:ok, [Agent.t()]} | {:error, term()}
  def replace_all(%Cyfr.Actor{athanor_id: athanor_id}, rows)
      when is_binary(athanor_id) and athanor_id != "" and is_list(rows) do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.replace_all", fn ->
      Arca.Repo.transaction(fn ->
        Arca.Repo.delete_all(from(a in Agent, where: a.athanor_id == ^athanor_id))
        Arca.Repo.insert_all(Agent, rows)
        Enum.map(rows, &struct(Agent, &1))
      end)
    end)
  end

  def replace_all(%Cyfr.Actor{}, _rows), do: {:error, :no_athanor}

  @doc "The athanor's rows, by name."
  @spec list(Cyfr.Actor.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def list(%Cyfr.Actor{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.list", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Agent, where: a.athanor_id == ^athanor_id, order_by: [asc: a.name])
       )}
    end)
  end

  def list(%Cyfr.Actor{}), do: {:error, :no_athanor}
end
