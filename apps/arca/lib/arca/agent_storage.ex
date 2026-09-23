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

  A rewrite made under a provisioning claim carries that claim
  (`replace_all/3`), and then the claim guard and the rewrite are ONE
  transaction: the index speaks for the estate, so it is published only by
  the attempt that still holds it.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Agent

  @doc """
  Replace the athanor's rows with `rows`, in one transaction: the index is
  a whole rewrite from the tree, never a merge.

  `:claim` in `opts` — `%{owner: owner, fence: fence}` — makes the rewrite
  a provisioning attempt's, and then the transaction that writes the rows
  is the one that holds the claim (`Arca.ProvisioningClaims.hold?/3`): a
  rewrite whose claim a successor took writes nothing and answers
  `{:error, :claim_lost}`. Without it the caller has no claim to lose — a
  person editing a role through the console — and the rewrite stands on
  its own.

  The guard is inside the transaction and not before it, because a
  provisioning attempt's claim can lapse while a sync is running: a check
  taken beforehand is true at one instant and the delete lands at another.
  """
  @spec replace_all(Cyfr.Actor.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, :claim_lost | term()}
  def replace_all(actor, rows, opts \\ [])

  def replace_all(%Cyfr.Actor{athanor_id: athanor_id} = actor, rows, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_list(rows) and is_list(opts) do
    claim = Keyword.get(opts, :claim)

    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.replace_all", fn ->
      Arca.Repo.transaction(fn ->
        if holding?(actor, claim) do
          Arca.Repo.delete_all(from(a in Agent, where: a.athanor_id == ^athanor_id))
          Arca.Repo.insert_all(Agent, rows)
          Enum.map(rows, &struct(Agent, &1))
        else
          Arca.Repo.rollback(:claim_lost)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def replace_all(%Cyfr.Actor{}, _rows, _opts), do: {:error, :no_athanor}

  defp holding?(_actor, nil), do: true

  defp holding?(actor, %{owner: owner, fence: fence}),
    do: Arca.ProvisioningClaims.hold?(actor, owner, fence)

  @doc "The athanor's rows, by name."
  @spec list(Cyfr.Actor.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Cyfr.Actor{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.list", fn ->
      {:ok,
       Arca.Repo.all(
         from(a in Agent, where: a.athanor_id == ^athanor_id, order_by: [asc: a.name])
       )}
    end)
    |> Arca.Data.project()
  end

  def list(%Cyfr.Actor{}), do: {:error, :no_athanor}
end
