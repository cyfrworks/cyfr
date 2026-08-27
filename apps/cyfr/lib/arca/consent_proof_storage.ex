# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentProofStorage do
  @moduledoc """
  Persistence mechanics for single-use consent proofs. Take is
  delete-keyed: the delete count decides the winner between concurrent
  consumers, which is the portable atomic-take on both adapters (no
  RETURNING, no row locks).
  """

  import Ecto.Query

  alias Arca.Schemas.ConsentProof

  @spec insert(map()) :: :ok | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentProofStorage.insert", fn ->
      case Arca.Repo.insert(struct(ConsentProof, attrs)) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Read-then-delete by token hash. Exactly one concurrent caller sees
  `{:ok, row}` — everyone else gets `:not_found`, including the loser
  who read the row an instant before the winner's delete landed.
  """
  @spec take(String.t()) :: {:ok, ConsentProof.t()} | {:error, :not_found}
  def take(token_hash) when is_binary(token_hash) do
    # Deliberate default: an outage reads as an unusable proof (:not_found) —
    # fail closed, a proof the store cannot confirm consumed never grants.
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentProofStorage.take", {:error, :not_found}, fn ->
      case Arca.Repo.get(ConsentProof, token_hash) do
        nil ->
          {:error, :not_found}

        row ->
          case Arca.Repo.delete_all(from(p in ConsentProof, where: p.token_hash == ^token_hash)) do
            {1, _} -> {:ok, row}
            {0, _} -> {:error, :not_found}
          end
      end
    end)
  end

  @spec purge_expired(DateTime.t()) :: non_neg_integer()
  def purge_expired(now) do
    # Deliberate default: housekeeping — a sweep the store missed is retried
    # on the next cadence, and expired proofs stay refused by their timestamp.
    # arca:unscoped-ok proofs are keyed by token hash, not tenant; the sweep
    # reclaims expired rows server-wide.
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentProofStorage.purge_expired", 0, fn ->
      {count, _} = Arca.Repo.delete_all(from(p in ConsentProof, where: p.expires_at <= ^now))
      count
    end)
  end
end
