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

  alias Arca.Schemas.OauthProviderCredential

  @spec get(String.t(), String.t()) ::
          {:ok, OauthProviderCredential.t()} | {:error, :not_found | :database_error}
  def get(athanor_id, provider) when is_binary(provider) do
    Arca.Repo.Errors.with_db_rescue("ProviderCredentialStorage.get", fn ->
      query =
        from(c in OauthProviderCredential, where: c.provider == ^provider, limit: 1)
        |> where_athanor(athanor_id)

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @spec put(map()) :: :ok | {:error, :database_error}
  def put(attrs) do
    Arca.Repo.Errors.with_db_rescue("ProviderCredentialStorage.put", fn ->
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
    end)
  end

  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found | :database_error}
  def delete(athanor_id, provider) when is_binary(provider) do
    Arca.Repo.Errors.with_db_rescue("ProviderCredentialStorage.delete", fn ->
      query =
        from(c in OauthProviderCredential, where: c.provider == ^provider)
        |> where_athanor(athanor_id)

      case Arca.Repo.delete_all(query) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(athanor_id, provider) when is_binary(provider) do
    match?({:ok, _}, get(athanor_id, provider))
  end

  @doc "The athanor's rows, by provider name — never the ciphertext."
  @spec list(String.t()) ::
          {:ok, [%{provider: String.t(), created_by: String.t() | nil, updated_at: DateTime.t()}]}
          | {:error, :database_error}
  def list(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("ProviderCredentialStorage.list", fn ->
      rows =
        from(c in OauthProviderCredential,
          order_by: [asc: c.provider],
          select: %{provider: c.provider, created_by: c.created_by, updated_at: c.updated_at}
        )
        |> where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, rows}
    end)
  end
end
