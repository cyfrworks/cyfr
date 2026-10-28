# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RegistryTokenStorage do
  @moduledoc """
  Storage for registry push tokens.

  Persistence mechanics only — sealing and credential semantics live in
  `Sanctum.RegistryCredentials`, the only caller. Rows are keyed by
  `(user_id, registry, namespace_slug)`; this is a platform-plane store
  (tokens belong to users, not tenants), so there are no tenant columns.
  """

  import Ecto.Query

  alias Arca.Schemas.RegistryToken

  @spec get(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :database_error}
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
    |> Arca.Data.project()
  end

  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, :database_error}
  def list(user_id, registry) when is_binary(user_id) and is_binary(registry) do
    Arca.Repo.Errors.with_db_rescue("RegistryTokenStorage.list", fn ->
      query =
        from(t in RegistryToken,
          where: t.user_id == ^user_id and t.registry == ^registry,
          order_by: [asc: t.namespace_slug]
        )

      {:ok, Arca.Repo.all(query)}
    end)
    |> Arca.Data.project()
  end

  @doc """
  Store a push-token row, replacing the one its `(user, registry,
  namespace)` held. A token is stored after the registry answered, so it
  is the holder's write alone (`Arca.Repo.owned/2`): a member whose slot
  was taken meanwhile is refused `:not_owner` and stores nothing.
  """
  @spec put(map()) :: :ok | {:error, :not_owner | :database_error}
  def put(attrs) do
    Arca.Repo.owned("Arca.RegistryTokenStorage.put", fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      row = %{
        id: Prima.UUID7.generate_id("rtk"),
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

      {:ok, :ok}
    end)
    |> stored()
  end

  defp stored({:ok, :ok}), do: :ok
  defp stored({:error, _reason} = refused), do: refused

  @doc """
  Delete the row of `(user_id, registry, namespace_slug)` only while it
  still holds `credential_ciphertext`: a token stored since the caller
  read the row is kept. Answers `:ok` whether or not a row went. It
  follows the registry's refusal of a push, so it is the holder's write
  alone (`Arca.Repo.owned/2`).
  """
  @spec delete_if_unchanged(String.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, :not_owner | :database_error}
  def delete_if_unchanged(user_id, registry, namespace_slug, credential_ciphertext)
      when is_binary(user_id) and is_binary(registry) and is_binary(namespace_slug) and
             is_binary(credential_ciphertext) do
    Arca.Repo.owned("Arca.RegistryTokenStorage.delete_if_unchanged", fn ->
      query =
        from(t in RegistryToken,
          where:
            t.user_id == ^user_id and t.registry == ^registry and
              t.namespace_slug == ^namespace_slug and
              t.credential_ciphertext == ^credential_ciphertext
        )

      {_count, _} = Arca.Repo.delete_all(query)
      {:ok, :ok}
    end)
    |> stored()
  end
end
