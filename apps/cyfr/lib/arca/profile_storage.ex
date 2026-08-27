# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorage do
  @moduledoc """
  Persistence mechanics for profiles. Validation and consent semantics
  live in the `Sanctum.*` layer, which is the only caller. Every read and
  write is keyed by the owning athanor.
  """

  import Ecto.Query

  alias Arca.Schemas.Profile

  @spec put(map()) :: {:ok, Profile.t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.put", fn ->
      # A profile without an athanor is a construction bug — fail here, not
      # at the NOT NULL constraint.
      _ = Map.fetch!(attrs, :athanor_id)
      row = Map.put_new(attrs, :id, Emissary.UUID7.generate_id("prof"))

      struct(Profile, row)
      |> Arca.Repo.insert()
    end)
  end

  @spec get(String.t(), String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get(athanor_id, id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.get", fn ->
      case Arca.Repo.get_by(Profile, id: id, athanor_id: athanor_id) do
        nil -> {:error, :not_found}
        profile -> {:ok, profile}
      end
    end)
  end

  @doc "Non-revoked profiles for a name-level source ref within an athanor."
  @spec list_for_source(String.t(), String.t()) :: {:ok, [Profile.t()]} | {:error, term()}
  def list_for_source(athanor_id, source_ref) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.list_for_source", fn ->
      rows =
        Arca.Repo.all(
          from p in Profile,
            where:
              p.athanor_id == ^athanor_id and p.source_ref == ^source_ref and
                p.status != "revoked",
            order_by: p.id
        )

      {:ok, rows}
    end)
  end

  @spec set_status(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_status(athanor_id, id, status) when is_binary(status) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.set_status", fn ->
      case Arca.Repo.update_all(
             from(p in Profile, where: p.id == ^id and p.athanor_id == ^athanor_id),
             set: [status: status, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :not_found}
      end
    end)
  end

  @doc """
  Compare-and-swap the head consent pointer. The update counts as applied
  only when the stored head still equals `expected` (or is NULL for the
  bootstrap revision) — a concurrent advance makes this return
  `{:error, :head_moved}` and the caller re-plans.
  """
  @spec advance_head(String.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, :head_moved | term()}
  def advance_head(athanor_id, id, expected, new_consent_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.advance_head", fn ->
      base = from(p in Profile, where: p.id == ^id and p.athanor_id == ^athanor_id)

      query =
        case expected do
          nil -> from(p in base, where: is_nil(p.head_consent_id))
          expected -> from(p in base, where: p.head_consent_id == ^expected)
        end

      case Arca.Repo.update_all(query,
             set: [head_consent_id: new_consent_id, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :head_moved}
      end
    end)
  end
end
