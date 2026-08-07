# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentStorage do
  @moduledoc """
  Persistence mechanics for consent revisions.

  Consents are insert-only: this module deliberately exports **no update
  function**, and a test pins the export list. A revision, its derived
  vault references and the profile's head advance commit in one
  transaction — a consent that exists but is not the head is history, and
  a head pointing at a missing revision is unrepresentable.
  """

  import Ecto.Query

  require Arca.Repo.Errors
  require Logger

  alias Arca.QueryHelpers
  alias Arca.Schemas.Consent
  alias Arca.Schemas.ConsentVaultRef

  @doc """
  Insert one revision with its vault refs and advance the profile head,
  atomically. `expected_head` is the CAS token (nil for revision 1).
  """
  @spec insert_revision(map(), [map()], String.t() | nil) ::
          {:ok, Consent.t()} | {:error, term()}
  def insert_revision(attrs, vault_refs, expected_head) when is_map(attrs) do
    org_id = QueryHelpers.normalize_org_id(Map.get(attrs, :org_id, ""))

    row =
      attrs
      |> Map.put(:org_id, org_id)
      |> Map.put_new(:id, Emissary.UUID7.generate_id("cons"))
      |> Map.put_new(:granted_at, DateTime.utc_now())

    ref_rows =
      Enum.map(vault_refs, fn ref ->
        %{
          consent_id: row.id,
          org_id: org_id,
          vault_entry_id: ref.vault_entry_id,
          binding_digest: ref.binding_digest
        }
      end)

    Arca.Repo.transaction(fn ->
      with {:ok, consent} <- Arca.Repo.insert(struct(Consent, row)),
           {_count, _} <- insert_refs(ref_rows),
           :ok <-
             Arca.ProfileStorage.advance_head(org_id, row.profile_id, expected_head, row.id) do
        consent
      else
        {:error, reason} -> Arca.Repo.rollback(reason)
      end
    end)
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentStorage] insert_revision failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp insert_refs([]), do: {0, nil}
  defp insert_refs(rows), do: Arca.Repo.insert_all(ConsentVaultRef, rows)

  @doc "The head consent revision of a profile, with its vault refs."
  @spec get_head(String.t(), String.t()) ::
          {:ok, Consent.t(), [ConsentVaultRef.t()]} | {:error, :not_found | :no_head | term()}
  def get_head(org_id, profile_id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    with {:ok, profile} <- Arca.ProfileStorage.get(org_id, profile_id),
         head_id when is_binary(head_id) <- profile.head_consent_id || {:error, :no_head},
         %Consent{} = consent <- Arca.Repo.get_by(Consent, id: head_id, org_id: org_id) do
      refs =
        Arca.Repo.all(
          from r in ConsentVaultRef,
            where: r.consent_id == ^head_id and r.org_id == ^org_id
        )

      {:ok, consent, refs}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentStorage] get_head failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "Every profile whose head references a vault entry — one query."
  @spec profiles_referencing(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def profiles_referencing(org_id, vault_entry_id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    ids =
      Arca.Repo.all(
        from r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.org_id == r.org_id,
          where: r.vault_entry_id == ^vault_entry_id and r.org_id == ^org_id,
          distinct: true,
          select: c.profile_id
      )

    {:ok, ids}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentStorage] profiles_referencing failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Profiles whose **head** revision references a vault entry.

  `profiles_referencing/2` counts every historical revision — right for
  "who ever touched this", wrong for "who is affected right now": a
  profile that dropped the entry two revisions ago would be over-reported.
  """
  @spec head_profiles_referencing(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def head_profiles_referencing(org_id, vault_entry_id) do
    org_id = QueryHelpers.normalize_org_id(org_id)

    ids =
      Arca.Repo.all(
        from r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.org_id == r.org_id,
          join: p in Arca.Schemas.Profile,
          on: p.head_consent_id == c.id and p.org_id == c.org_id,
          where: r.vault_entry_id == ^vault_entry_id and r.org_id == ^org_id,
          distinct: true,
          select: p.id
      )

    {:ok, ids}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error(
        "[Arca.ConsentStorage] head_profiles_referencing failed: #{Exception.message(e)}"
      )

      {:error, :database_error}
  end
end
