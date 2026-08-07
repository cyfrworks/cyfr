# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorage do
  @moduledoc """
  Persistence mechanics for vault entries. Sealing, binding-digest
  derivation and every consent semantic live in the `Sanctum.*` layer —
  `sealed_payload` arrives encrypted and leaves encrypted.
  """

  import Ecto.Query

  require Arca.Repo.Errors
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Schemas.VaultEntry

  @spec put(map()) :: {:ok, VaultEntry.t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    row =
      attrs
      |> Map.put_new(:id, Emissary.UUID7.generate_id("vlt"))
      |> Map.update(:org_id, "", &QueryHelpers.normalize_org_id/1)
      |> Map.update(:project_id, "default", &QueryHelpers.normalize_project_id/1)

    struct(VaultEntry, row)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] put failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec get(String.t(), String.t()) :: {:ok, VaultEntry.t()} | {:error, :not_found}
  def get(org_id, id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    case Arca.Repo.get_by(VaultEntry, id: id, org_id: org_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] get failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "The living entry with this name in a tenant, if any."
  @spec get_by_name(String.t(), String.t(), String.t()) ::
          {:ok, VaultEntry.t()} | {:error, :not_found}
  def get_by_name(org_id, project_id, name) do
    org_id = QueryHelpers.normalize_org_id(org_id)
    project_id = QueryHelpers.normalize_project_id(project_id)

    row =
      Arca.Repo.one(
        from v in VaultEntry,
          where:
            v.org_id == ^org_id and v.project_id == ^project_id and v.name == ^name and
              v.status != "tombstoned"
      )

    case row do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] get_by_name failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Replace the sealed payload iff `payload_rev` still equals `expected_rev`
  (compare-and-swap). The winning writer bumps the revision; a loser gets
  `{:error, :payload_conflict}` and must re-read.
  """
  @spec rotate_payload(String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, :payload_conflict}
  def rotate_payload(org_id, id, expected_rev, sealed)
      when is_integer(expected_rev) and is_binary(sealed) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    result =
      Arca.Repo.update_all(
        from(v in VaultEntry,
          where: v.id == ^id and v.org_id == ^org_id and v.payload_rev == ^expected_rev
        ),
        set: [
          sealed_payload: sealed,
          payload_rev: expected_rev + 1,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        ]
      )

    case result do
      {1, _} -> :ok
      {0, _} -> {:error, :payload_conflict}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] rotate_payload failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec touch_last_used(String.t(), String.t()) :: :ok
  def touch_last_used(org_id, id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    Arca.Repo.update_all(
      from(v in VaultEntry, where: v.id == ^id and v.org_id == ^org_id),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] touch_last_used failed: #{Exception.message(e)}")
      :ok
  end
end
