# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProfileStorage do
  @moduledoc """
  Persistence mechanics for profiles. Validation and consent semantics
  live in the `Sanctum.*` layer, which is the only caller.
  """

  import Ecto.Query

  require Arca.Repo.Errors
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Schemas.Profile

  @spec put(map()) :: {:ok, Profile.t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    row =
      attrs
      |> Map.put_new(:id, Emissary.UUID7.generate_id("prof"))
      |> Map.update(:org_id, "", &QueryHelpers.normalize_org_id/1)
      |> Map.update(:project_id, "default", &QueryHelpers.normalize_project_id/1)

    struct(Profile, row)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ProfileStorage] put failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec get(String.t(), String.t(), String.t()) :: {:ok, Profile.t()} | {:error, :not_found}
  def get(org_id, project_id, id) do
    org_id = QueryHelpers.normalize_org_id(org_id)
    project_id = QueryHelpers.normalize_project_id(project_id)

    case Arca.Repo.get_by(Profile, id: id, org_id: org_id, project_id: project_id) do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ProfileStorage] get failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "Non-revoked profiles for a name-level source ref within a tenant."
  @spec list_for_source(String.t(), String.t(), String.t()) ::
          {:ok, [Profile.t()]} | {:error, term()}
  def list_for_source(org_id, project_id, source_ref) do
    org_id = QueryHelpers.normalize_org_id(org_id)
    project_id = QueryHelpers.normalize_project_id(project_id)

    rows =
      Arca.Repo.all(
        from p in Profile,
          where:
            p.org_id == ^org_id and p.project_id == ^project_id and
              p.source_ref == ^source_ref and p.status != "revoked",
          order_by: p.id
      )

    {:ok, rows}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ProfileStorage] list_for_source failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec set_status(String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_status(org_id, project_id, id, status) when is_binary(status) do
    org_id = QueryHelpers.normalize_org_id(org_id)
    project_id = QueryHelpers.normalize_project_id(project_id)

    case Arca.Repo.update_all(
           from(p in Profile,
             where: p.id == ^id and p.org_id == ^org_id and p.project_id == ^project_id
           ),
           set: [status: status, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ProfileStorage] set_status failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Compare-and-swap the head consent pointer. The update counts as applied
  only when the stored head still equals `expected` (or is NULL for the
  bootstrap revision) — a concurrent advance makes this return
  `{:error, :head_moved}` and the caller re-plans.

  Org-scoped only by design: the sole caller is the consent-commit
  transaction, which fetched the profile project-scoped moments earlier in
  the same flow — the id is already tenant-verified when it reaches here.
  """
  @spec advance_head(String.t(), String.t(), String.t() | nil, String.t()) ::
          :ok | {:error, :head_moved | term()}
  def advance_head(org_id, id, expected, new_consent_id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    base = from(p in Profile, where: p.id == ^id and p.org_id == ^org_id)

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
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ProfileStorage] advance_head failed: #{Exception.message(e)}")
      {:error, :database_error}
  end
end
