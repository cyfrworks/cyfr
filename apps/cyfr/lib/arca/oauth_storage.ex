# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OAuthStorage do
  @moduledoc """
  Storage operations for OAuth credentials.

  Stores both provider credentials (client_id/secret) and component token
  bundles (access_token, refresh_token, etc.) in a single `oauth_credentials`
  table, distinguished by `component_ref` (empty string for provider creds,
  component reference for tokens).

  Values are stored as encrypted JSON blobs via the configured `Sanctum.Cipher`.
  Called by `Sanctum.OAuth` which handles encryption/decryption.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query
  import Arca.QueryHelpers,
    only: [normalize_org_id: 1, normalize_project_id: 1, where_org_id: 2, where_project_id: 2]

  @table Arca.Schemas.OauthCredential

  # ============================================================================
  # Component Tokens
  # ============================================================================

  @doc """
  Get encrypted token bundle for a component.
  """
  @spec get_token(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, binary()} | {:error, :not_found}
  def get_token(component_ref, provider, org_id, project_id \\ "default") do
    pid = normalize_project_id(project_id)
    cache_key = {:oauth_token, {component_ref, provider, org_id, pid}}

    case Arca.Cache.get(cache_key) do
      {:ok, cached} -> {:ok, cached}
      :miss -> get_credential_from_db(provider, component_ref, org_id, pid, cache_key)
    end
  end

  @doc """
  Upsert a token bundle for a component.
  """
  @spec put_token(String.t(), String.t(), binary(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def put_token(component_ref, provider, encrypted_data, org_id, project_id \\ "default") do
    put_credential(provider, component_ref, encrypted_data, org_id, project_id)
  end

  @doc """
  Delete a token bundle for a component.
  """
  @spec delete_token(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  def delete_token(component_ref, provider, org_id, project_id \\ "default") do
    delete_credential(provider, component_ref, org_id, project_id)
  end

  @doc """
  List all providers with tokens for a component (returns provider names only).
  """
  @spec list_tokens(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]}
  def list_tokens(component_ref, org_id, project_id \\ "default") do
    query =
      from(c in @table,
        where: c.component_ref == ^component_ref and c.component_ref != "",
        select: c.provider,
        order_by: c.provider
      )

    query = where_org_id(query, org_id)
    query = where_project_id(query, project_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[OAuthStorage] Database error in list_tokens: #{Exception.message(e)}")
      {:error, :database_error}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp get_credential_from_db(provider, component_ref, org_id, project_id, cache_key) do
    query =
      from(c in @table,
        where: c.provider == ^provider and c.component_ref == ^component_ref,
        limit: 1,
        select: c.encrypted_data
      )

    query = where_org_id(query, org_id)
    query = where_project_id(query, project_id)

    case Arca.Repo.one(query) do
      nil ->
        {:error, :not_found}

      encrypted_data ->
        Arca.Cache.put(cache_key, encrypted_data)
        {:ok, encrypted_data}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[OAuthStorage] Database error in get_credential: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp put_credential(provider, component_ref, encrypted_data, org_id, project_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pid = normalize_project_id(project_id)

    attrs = %{
      id: Ecto.UUID.generate(),
      provider: provider,
      component_ref: component_ref,
      encrypted_data: encrypted_data,
      org_id: normalize_org_id(org_id),
      project_id: pid,
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(
      @table,
      [attrs],
      on_conflict: {:replace, [:encrypted_data, :updated_at]},
      conflict_target: [:provider, :component_ref, :org_id, :project_id]
    )

    # Invalidate both raw and decrypted caches
    cache_key =
      if component_ref == "",
        do: {:oauth_cred, {provider, org_id, pid}},
        else: {:oauth_token, {component_ref, provider, org_id, pid}}

    Arca.Cache.invalidate(cache_key)
    Arca.Cache.invalidate({:oauth_token_dec, {component_ref, provider, org_id, pid}})
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[OAuthStorage] Database error in put_credential: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp delete_credential(provider, component_ref, org_id, project_id) do
    pid = normalize_project_id(project_id)

    query =
      from(c in @table,
        where: c.provider == ^provider and c.component_ref == ^component_ref
      )

    query = where_org_id(query, org_id)
    query = where_project_id(query, pid)

    Arca.Repo.delete_all(query)

    cache_key =
      if component_ref == "",
        do: {:oauth_cred, {provider, org_id, pid}},
        else: {:oauth_token, {component_ref, provider, org_id, pid}}

    Arca.Cache.invalidate(cache_key)
    Arca.Cache.invalidate({:oauth_token_dec, {component_ref, provider, org_id, pid}})
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[OAuthStorage] Database error in delete_credential: #{Exception.message(e)}")
      {:error, :database_error}
  end
end