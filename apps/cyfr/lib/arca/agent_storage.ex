# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentStorage do
  @moduledoc """
  The `agents` rows — the derived index of an athanor's `aqua/` tree
  (`Compendium.AgentIndex` derives them; this module is the only place
  they are read and written).
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Agent

  @doc """
  Replace the athanor's rows with `rows`, in one transaction: the index is
  a whole rewrite from the tree, never a merge.
  """
  @spec replace_all(String.t(), [map()]) :: {:ok, [Agent.t()]} | {:error, term()}
  def replace_all(athanor_id, rows) when is_binary(athanor_id) and is_list(rows) do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.replace_all", fn ->
      Arca.Repo.transaction(fn ->
        Arca.Repo.delete_all(from(a in Agent, where: a.athanor_id == ^athanor_id))
        Arca.Repo.insert_all(Agent, rows)
        Enum.map(rows, &struct(Agent, &1))
      end)
    end)
  end

  @doc "The athanor's rows, by name."
  @spec list(String.t()) :: {:ok, [Agent.t()]} | {:error, term()}
  def list(athanor_id) when is_binary(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.list", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Agent, where: a.athanor_id == ^athanor_id, order_by: [asc: a.name])
       )}
    end)
  end
end
