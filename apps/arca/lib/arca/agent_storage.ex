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

  The index is the `aqua` root's projection, so it is rewritten only
  against a snapshot of that root (`Arca.StorageProjectionChanges.snapshot/3`)
  and acknowledged in the same transaction. A rewrite made under a
  provisioning claim carries that claim, and then the claim guard is in
  that transaction too: the index speaks for the estate, so it is
  published only by the attempt that still holds it.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.Agent
  alias Arca.StorageProjectionChanges

  @doc """
  Replace the athanor's rows with `rows` against `token`, the `aqua`
  root's snapshot, in one transaction: the index is a whole rewrite from
  the tree, never a merge, and it acknowledges every unit the token names
  that is ready — and the root's epoch when all of them are.

  The transaction holds the root's row and the token's unit rows before it
  writes (`Arca.StorageProjectionChanges.replace/4`): a change the token
  did not see — a unit created after the snapshot included, whether or
  not the token names it — writes nothing and answers
  `{:error, :generation_conflict}`. A token of another athanor is
  `{:error, :cross_tenant}`. Each row is stamped with the actor's athanor.

  `:claim` in `opts` — `%{owner: owner, fence: fence}` — makes the rewrite
  a provisioning attempt's, and then the transaction that writes the rows
  is the one that holds the claim (`Arca.ProvisioningClaims.hold?/3`): a
  rewrite whose claim a successor took writes nothing and answers
  `{:error, :claim_lost}`. Without it the caller has no claim to lose — a
  person editing a role through the console — and the rewrite stands on
  its own. The guard is inside the transaction and not before it, because
  a provisioning attempt's claim can lapse while a sync is running.
  """
  @spec replace_projection(
          Cyfr.Actor.t(),
          StorageProjectionChanges.token(),
          [map()],
          keyword()
        ) ::
          {:ok, [map()]}
          | {:error,
             :no_athanor
             | :cross_tenant
             | :invalid_token
             | :generation_conflict
             | :claim_lost
             | term()}
  def replace_projection(actor, token, rows, opts \\ [])

  def replace_projection(%Cyfr.Actor{athanor_id: athanor_id} = actor, token, rows, opts)
      when is_binary(athanor_id) and athanor_id != "" and is_map(token) and is_list(rows) and
             is_list(opts) do
    claim = Keyword.get(opts, :claim)
    rows = Enum.map(rows, &Arca.QueryHelpers.stamp_tenant!(actor, &1))

    Arca.Repo.Errors.with_db_rescue("Arca.AgentStorage.replace_projection", fn ->
      StorageProjectionChanges.replace(actor, "aqua", token, fn ->
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

  def replace_projection(%Cyfr.Actor{}, _token, _rows, _opts), do: {:error, :no_athanor}

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
