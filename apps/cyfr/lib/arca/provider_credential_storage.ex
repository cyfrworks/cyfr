# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProviderCredentialStorage do
  @moduledoc """
  Storage for OAuth provider client credentials.

  Persistence mechanics only — sealing and permission checks live in
  `Sanctum.ProviderCredentials`. One row per `(athanor_id, provider)`.
  """

  import Ecto.Query
  import Arca.QueryHelpers, only: [where_athanor: 2]

  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.OauthProviderCredential

  @spec get(String.t(), String.t()) ::
          {:ok, OauthProviderCredential.t()} | {:error, :not_found | :database_error}
  def get(athanor_id, provider) when is_binary(provider) do
    query =
      from(c in OauthProviderCredential, where: c.provider == ^provider, limit: 1)
      |> where_athanor(athanor_id)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ProviderCredentialStorage] Database error in get: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec put(map()) :: :ok | {:error, :database_error}
  def put(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Emissary.UUID7.generate_id("opc"),
      athanor_id: Map.fetch!(attrs, :athanor_id),
      provider: Map.fetch!(attrs, :provider),
      payload_ciphertext: Map.fetch!(attrs, :payload_ciphertext),
      created_by: attrs[:created_by],
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(OauthProviderCredential, [row],
      on_conflict: {:replace, [:payload_ciphertext, :created_by, :updated_at]},
      conflict_target: [:athanor_id, :provider]
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ProviderCredentialStorage] Database error in put: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found | :database_error}
  def delete(athanor_id, provider) when is_binary(provider) do
    query =
      from(c in OauthProviderCredential, where: c.provider == ^provider)
      |> where_athanor(athanor_id)

    case Arca.Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[ProviderCredentialStorage] Database error in delete: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(athanor_id, provider) when is_binary(provider) do
    match?({:ok, _}, get(athanor_id, provider))
  end
end
