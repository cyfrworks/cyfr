# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RegistryTokenStorage do
  @moduledoc """
  Storage for registry push tokens.

  Persistence mechanics only — sealing and credential semantics live in
  `Compendium.Registry.CredentialStore`. Rows are keyed by
  `(user_id, registry, namespace_slug)`; this is a platform-plane store
  (tokens belong to users, not tenants), so there are no tenant columns.
  """

  import Ecto.Query

  alias Arca.Schemas.RegistryToken

  @spec get(String.t(), String.t(), String.t()) ::
          {:ok, RegistryToken.t()} | {:error, :not_found | :database_error}
  def get(user_id, registry, namespace_slug)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    Arca.Repo.Errors.with_db_rescue("RegistryTokenStorage.get", fn ->
      query =
        from(t in RegistryToken,
          where:
            t.user_id == ^user_id and t.registry == ^registry and
              t.namespace_slug == ^namespace_slug,
          limit: 1
        )

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
  end

  @spec list(String.t(), String.t()) :: {:ok, [RegistryToken.t()]} | {:error, :database_error}
  def list(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    Arca.Repo.Errors.with_db_rescue("RegistryTokenStorage.list", fn ->
      query =
        from(t in RegistryToken,
          where: t.user_id == ^user_id and t.registry == ^registry,
          order_by: [asc: t.namespace_slug]
        )

      {:ok, Arca.Repo.all(query)}
    end)
  end

  @spec put(map()) :: :ok | {:error, :database_error}
  def put(attrs) do
    Arca.Repo.Errors.with_db_rescue("RegistryTokenStorage.put", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = %{
        id: Emissary.UUID7.generate_id("rtk"),
        user_id: Map.fetch!(attrs, :user_id),
        registry: Map.fetch!(attrs, :registry),
        namespace_slug: Map.fetch!(attrs, :namespace_slug),
        credential_ciphertext: Map.fetch!(attrs, :credential_ciphertext),
        issued_at: attrs[:issued_at] || now,
        inserted_at: now,
        updated_at: now
      }

      Arca.Repo.insert_all(RegistryToken, [row],
        on_conflict: {:replace, [:credential_ciphertext, :issued_at, :updated_at]},
        conflict_target: [:user_id, :registry, :namespace_slug]
      )

      :ok
    end)
  end

  @spec delete(String.t(), String.t(), String.t()) :: :ok | {:error, :database_error}
  def delete(user_id, registry, namespace_slug)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) do
    Arca.Repo.Errors.with_db_rescue("RegistryTokenStorage.delete", fn ->
      query =
        from(t in RegistryToken,
          where:
            t.user_id == ^user_id and t.registry == ^registry and
              t.namespace_slug == ^namespace_slug
        )

      Arca.Repo.delete_all(query)
      :ok
    end)
  end
end
