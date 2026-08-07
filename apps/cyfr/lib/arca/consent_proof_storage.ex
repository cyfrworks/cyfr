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

  require Arca.Repo.Errors
  require Logger

  alias Arca.Schemas.ConsentProof

  @spec insert(map()) :: :ok | {:error, term()}
  def insert(attrs) when is_map(attrs) do
    case Arca.Repo.insert(struct(ConsentProof, attrs)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentProofStorage] insert failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Read-then-delete by token hash. Exactly one concurrent caller sees
  `{:ok, row}` — everyone else gets `:not_found`, including the loser
  who read the row an instant before the winner's delete landed.
  """
  @spec take(String.t()) :: {:ok, ConsentProof.t()} | {:error, :not_found}
  def take(token_hash) when is_binary(token_hash) do
    case Arca.Repo.get(ConsentProof, token_hash) do
      nil ->
        {:error, :not_found}

      row ->
        case Arca.Repo.delete_all(from(p in ConsentProof, where: p.token_hash == ^token_hash)) do
          {1, _} -> {:ok, row}
          {0, _} -> {:error, :not_found}
        end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentProofStorage] take failed: #{Exception.message(e)}")
      {:error, :not_found}
  end

  @spec purge_expired(DateTime.t()) :: non_neg_integer()
  def purge_expired(now) do
    {count, _} = Arca.Repo.delete_all(from(p in ConsentProof, where: p.expires_at <= ^now))
    count
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentProofStorage] purge_expired failed: #{Exception.message(e)}")
      0
  end
end
