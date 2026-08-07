# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProviderCredentialStorage do
  @moduledoc """
  Storage for OAuth provider client credentials.

  Persistence mechanics only — sealing, permission checks and the
  legacy-secret fallback live in `Sanctum.ProviderCredentials`. Tenant
  coordinates are normalized at every boundary so nil/"" sentinel variance
  cannot split the partition.
  """

  import Ecto.Query

  require Logger
  require Arca.Repo.Errors

  alias Arca.Schemas.OauthProviderCredential

  @spec get(String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, OauthProviderCredential.t()} | {:error, :not_found | :database_error}
  def get(org_id, project_id, provider) when is_binary(provider) do
    {org, project} = normalize(org_id, project_id)

    query =
      from(c in OauthProviderCredential,
        where: c.provider == ^provider and c.org_id == ^org and c.project_id == ^project,
        limit: 1
      )

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
    {org, project} = normalize(attrs[:org_id], attrs[:project_id])
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Emissary.UUID7.generate_id("opc"),
      org_id: org,
      project_id: project,
      provider: Map.fetch!(attrs, :provider),
      payload_ciphertext: Map.fetch!(attrs, :payload_ciphertext),
      created_by: attrs[:created_by],
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(OauthProviderCredential, [row],
      on_conflict: {:replace, [:payload_ciphertext, :created_by, :updated_at]},
      conflict_target: [:provider, :org_id, :project_id]
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ProviderCredentialStorage] Database error in put: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec delete(String.t() | nil, String.t() | nil, String.t()) ::
          :ok | {:error, :not_found | :database_error}
  def delete(org_id, project_id, provider) when is_binary(provider) do
    {org, project} = normalize(org_id, project_id)

    query =
      from(c in OauthProviderCredential,
        where: c.provider == ^provider and c.org_id == ^org and c.project_id == ^project
      )

    case Arca.Repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[ProviderCredentialStorage] Database error in delete: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec exists?(String.t() | nil, String.t() | nil, String.t()) :: boolean()
  def exists?(org_id, project_id, provider) when is_binary(provider) do
    match?({:ok, _}, get(org_id, project_id, provider))
  end

  defp normalize(org_id, project_id) do
    {Arca.QueryHelpers.normalize_org_id(org_id), Arca.QueryHelpers.normalize_project_id(project_id)}
  end
end
