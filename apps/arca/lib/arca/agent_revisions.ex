# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AgentRevisions do
  @moduledoc """
  The `agent_revisions` rows: every agent file the estate's index has
  seen, by the digest of its bytes. Content-addressed and immutable — a
  revision is written once and read back verified, so what a turn pinned
  is retrievable as it was, whatever the tree holds now.

  Both functions take the `Cyfr.Actor` first and match it in the head, so
  the athanor a revision is kept and read under comes from the caller; an
  actor whose athanor is nil or the empty string is
  `{:error, :no_athanor}` before any query.
  """

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.AgentRevision

  @doc """
  Keep `bytes` as a revision of the athanor's, answering its digest. A
  revision already kept is left as it is.
  """
  @spec put(Cyfr.Actor.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put(%Cyfr.Actor{athanor_id: athanor_id}, bytes)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(bytes) do
    digest = Cyfr.Digest.sha256(bytes)

    Arca.Repo.Errors.with_db_rescue("Arca.AgentRevisions.put", fn ->
      row = %{
        id: Cyfr.UUID7.generate_id("agr"),
        athanor_id: athanor_id,
        digest: digest,
        bytes: bytes,
        inserted_at: DateTime.utc_now()
      }

      {_count, _} =
        Arca.Repo.insert_all(AgentRevision, [row],
          on_conflict: :nothing,
          conflict_target: [:athanor_id, :digest]
        )

      {:ok, digest}
    end)
    |> Arca.Data.project()
  end

  def put(%Cyfr.Actor{}, _bytes), do: {:error, :no_athanor}

  @doc """
  The bytes kept under `digest` for the athanor, verified against it:
  `{:error, :not_found}` for a digest never kept, `{:error, :corrupt}`
  for bytes that no longer hash to it.
  """
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, binary()} | {:error, :no_athanor | :not_found | :corrupt | term()}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, digest)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(digest) do
    Arca.Repo.Errors.with_db_rescue("Arca.AgentRevisions.get", fn ->
      case Arca.Repo.one(
             from(r in AgentRevision, where: r.athanor_id == ^athanor_id and r.digest == ^digest)
           ) do
        nil -> {:error, :not_found}
        %AgentRevision{bytes: bytes} -> verify(bytes, digest)
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Cyfr.Actor{}, _digest), do: {:error, :no_athanor}

  defp verify(bytes, digest) do
    if Cyfr.Digest.sha256(bytes) == digest, do: {:ok, bytes}, else: {:error, :corrupt}
  end
end
