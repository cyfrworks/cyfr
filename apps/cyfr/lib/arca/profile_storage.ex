# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorage do
  @moduledoc """
  Persistence mechanics for profiles. Validation and consent semantics
  live in the identity domain above, which is the only caller. Every
  function but `put/1` takes the `Cyfr.Actor` first and matches it in the
  head, refusing an actor whose athanor is nil or the empty string with
  `{:error, :no_athanor}` before any query. Every read and
  write is keyed by the owning athanor.
  """

  import Ecto.Query

  alias Arca.Schemas.Profile

  @spec put(map()) :: {:ok, Profile.t()} | {:error, term()}
  # arca:unscoped-ok the athanor arrives in attrs and its absence fails loudly two lines down.
  def put(attrs) when is_map(attrs) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.put", fn ->
      # A profile without an athanor is a construction bug — fail here, not
      # at the NOT NULL constraint.
      _ = Map.fetch!(attrs, :athanor_id)
      row = Map.put_new(attrs, :id, Cyfr.UUID7.generate_id("prof"))

      # The schema's changeset holds the row to the profile vocabulary and
      # carries the active-identity index (a bare struct insert declares no
      # constraint, so a race raised past the db-error rescue). A label
      # refusal keeps the typed shape the consent verbs answer with.
      case Arca.Repo.insert(Profile.changeset(%Profile{}, row)) do
        {:error, %Ecto.Changeset{errors: errors}} = refusal ->
          if Keyword.has_key?(errors, :label),
            do: {:error, {:invalid_label, Map.get(row, :label)}},
            else: refusal

        result ->
          result
      end
    end)
  end

  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, Profile.t()} | {:error, :no_athanor | :not_found | :database_error}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.get", fn ->
      case Arca.Repo.get_by(Profile, id: id, athanor_id: athanor_id) do
        nil -> {:error, :not_found}
        profile -> {:ok, profile}
      end
    end)
  end

  def get(%Cyfr.Actor{}, _id), do: {:error, :no_athanor}

  @doc "Non-revoked profiles for a name-level source ref within an athanor."
  @spec list_for_source(Cyfr.Actor.t(), String.t()) :: {:ok, [Profile.t()]} | {:error, term()}
  def list_for_source(%Cyfr.Actor{athanor_id: athanor_id}, source_ref)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.list_for_source", fn ->
      rows =
        from(p in Profile,
          where: p.source_ref == ^source_ref and p.status != "revoked",
          order_by: p.id
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
  end

  def list_for_source(%Cyfr.Actor{}, _source_ref), do: {:error, :no_athanor}

  @spec set_status(Cyfr.Actor.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_status(%Cyfr.Actor{athanor_id: athanor_id}, id, status)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(status) do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.set_status", fn ->
      case Arca.Repo.update_all(
             from(p in Profile, where: p.id == ^id)
             |> Arca.QueryHelpers.where_athanor(athanor_id),
             set: [status: status, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> :ok
        {0, _} -> {:error, :not_found}
      end
    end)
  end

  def set_status(%Cyfr.Actor{}, _id, _status), do: {:error, :no_athanor}

  @doc """
  Compare-and-swap the head consent pointer. The update counts as applied
  only when the stored head still equals `expected` (or is NULL for the
  bootstrap revision) — a concurrent advance makes this return
  `{:error, :head_moved}` and the caller re-plans.
  """
  @spec advance_head(Cyfr.Actor.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, :no_athanor | :head_moved | term()}
  def advance_head(%Cyfr.Actor{athanor_id: athanor_id}, id, expected, new_consent_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ProfileStorage.advance_head", fn ->
      base =
        from(p in Profile, where: p.id == ^id)
        |> Arca.QueryHelpers.where_athanor(athanor_id)

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

  def advance_head(%Cyfr.Actor{}, _id, _expected, _new_consent_id), do: {:error, :no_athanor}
end
