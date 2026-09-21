# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProviderCredentialStorage do
  @moduledoc """
  Storage for OAuth provider client credentials.

  Persistence mechanics only — sealing and permission checks live in
  `Sanctum.ProviderCredentials`. One row per `(athanor_id, provider)`.

  Every read and delete takes the `Cyfr.Actor` first and matches it in
  its head, so the athanor comes from the caller and never from an
  argument. An actor whose athanor is nil or the empty string is refused
  before any query — `{:error, :no_athanor}`, and a raise from
  `exists?/2`, whose `boolean()` has no refusal to spell and must not
  read an unresolved tenant as "no credentials stored".
  """

  import Ecto.Query
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.OauthProviderCredential

  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, OauthProviderCredential.t()}
          | {:error, :no_athanor | :not_found | :database_error}
  def get(%Cyfr.Actor{athanor_id: athanor_id}, provider)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(provider) do
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

  def get(%Cyfr.Actor{}, _provider), do: {:error, :no_athanor}

  @spec put(map()) :: :ok | {:error, :database_error}
  def put(attrs) do
    Arca.Repo.Errors.with_db_rescue("ProviderCredentialStorage.put", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = %{
        id: Cyfr.UUID7.generate_id("opc"),
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

  @spec delete(Cyfr.Actor.t(), String.t()) ::
          :ok | {:error, :no_athanor | :not_found | :database_error}
  def delete(%Cyfr.Actor{athanor_id: athanor_id}, provider)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(provider) do
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

  def delete(%Cyfr.Actor{}, _provider), do: {:error, :no_athanor}

  @spec exists?(Cyfr.Actor.t(), String.t()) :: boolean()
  def exists?(%Cyfr.Actor{athanor_id: athanor_id} = actor, provider)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(provider) do
    match?({:ok, _}, get(actor, provider))
  end

  def exists?(%Cyfr.Actor{}, _provider),
    do: Arca.QueryHelpers.no_athanor!("Arca.ProviderCredentialStorage.exists?/2")

  @doc "The athanor's rows, by provider name — never the ciphertext."
  @spec list(Cyfr.Actor.t()) ::
          {:ok, [%{provider: String.t(), created_by: String.t() | nil, updated_at: DateTime.t()}]}
          | {:error, :no_athanor | :database_error}
  def list(%Cyfr.Actor{athanor_id: athanor_id}) when is_binary(athanor_id) and athanor_id != "" do
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

  def list(%Cyfr.Actor{}), do: {:error, :no_athanor}
end
