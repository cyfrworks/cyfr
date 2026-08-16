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

  alias Arca.Schemas.Consent
  alias Arca.Schemas.ConsentVaultRef

  @doc """
  Insert one revision with its vault refs and advance the profile head,
  atomically. `expected_head` is the CAS token (nil for revision 1).

  `opts[:verify]` is a zero-arity function run **inside the transaction**,
  after the refs land and before the head advances — the seam a consent
  commit uses to re-verify binding liveness so a `vault.rebind` racing the
  commit rolls the whole revision back. It must return `:ok` or
  `{:error, reason}` and must only read.
  """
  @spec insert_revision(map(), [map()], String.t() | nil, keyword()) ::
          {:ok, Consent.t()} | {:error, term()}
  def insert_revision(attrs, vault_refs, expected_head, opts \\ []) when is_map(attrs) do
    athanor_id = Map.fetch!(attrs, :athanor_id)
    row = revision_row(attrs, athanor_id)

    Ecto.Multi.new()
    |> revision_multi(row, vault_refs, expected_head, athanor_id, opts)
    |> run_multi(:consent)
  end

  @doc """
  Mint a profile together with its first revision in one transaction —
  a failed consent insert must not leave an orphan profile whose
  `head_consent_id` is forever NULL.
  """
  @spec mint_profile_with_revision(map(), map(), [map()], keyword()) ::
          {:ok, Consent.t()} | {:error, term()}
  def mint_profile_with_revision(profile_attrs, consent_attrs, vault_refs, opts \\ []) do
    athanor_id = Map.fetch!(profile_attrs, :athanor_id)
    row = revision_row(consent_attrs, athanor_id)

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:profile, struct(Arca.Schemas.Profile, profile_attrs))
    |> revision_multi(row, vault_refs, nil, athanor_id, opts)
    |> run_multi(:consent)
  end

  defp revision_row(attrs, athanor_id) do
    attrs
    |> Map.put(:athanor_id, athanor_id)
    |> Map.put_new(:id, Emissary.UUID7.generate_id("cons"))
    |> Map.put_new(:granted_at, DateTime.utc_now())
  end

  defp revision_multi(multi, row, vault_refs, expected_head, athanor_id, opts) do
    ref_rows =
      Enum.map(vault_refs, fn ref ->
        %{
          consent_id: row.id,
          athanor_id: athanor_id,
          vault_entry_id: ref.vault_entry_id,
          binding_digest: ref.binding_digest
        }
      end)

    verify = Keyword.get(opts, :verify, fn -> :ok end)

    multi
    |> Ecto.Multi.insert(:consent, struct(Consent, row))
    |> Ecto.Multi.run(:refs, fn _repo, _done ->
      # insert_all cannot signal a partial write through its return shape;
      # the count assertion is what makes the refs leg able to fail at all.
      case insert_refs(ref_rows) do
        {count, _} when count == length(ref_rows) -> {:ok, count}
        {count, _} -> {:error, {:refs_partial_insert, count, length(ref_rows)}}
      end
    end)
    |> Ecto.Multi.run(:verify, fn _repo, _done ->
      case verify.() do
        :ok -> {:ok, :verified}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Ecto.Multi.run(:head, fn _repo, _done ->
      case Arca.ProfileStorage.advance_head(athanor_id, row.profile_id, expected_head, row.id) do
        :ok -> {:ok, :advanced}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp run_multi(multi, return_key) do
    case Arca.Repo.transaction(multi) do
      {:ok, done} -> {:ok, Map.fetch!(done, return_key)}
      {:error, _step, reason, _done} -> {:error, reason}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.ConsentStorage] transaction failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  defp insert_refs([]), do: {0, nil}
  defp insert_refs(rows), do: Arca.Repo.insert_all(ConsentVaultRef, rows)

  @doc "The head consent revision of a profile, with its vault refs."
  @spec get_head(String.t(), String.t()) ::
          {:ok, Consent.t(), [ConsentVaultRef.t()]} | {:error, :not_found | :no_head | term()}
  def get_head(athanor_id, profile_id) do
    with {:ok, profile} <- Arca.ProfileStorage.get(athanor_id, profile_id),
         head_id when is_binary(head_id) <- profile.head_consent_id || {:error, :no_head},
         %Consent{} = consent <-
           Arca.Repo.get_by(Consent, id: head_id, athanor_id: athanor_id) do
      refs =
        Arca.Repo.all(
          from r in ConsentVaultRef,
            where: r.consent_id == ^head_id and r.athanor_id == ^athanor_id
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

  @doc """
  Profiles whose **head** revision references a vault entry.

  Deliberately head-only: counting every historical revision would
  over-report — a profile that dropped the entry two revisions ago is not
  affected right now.
  """
  @spec head_profiles_referencing(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def head_profiles_referencing(athanor_id, vault_entry_id) do
    ids =
      Arca.Repo.all(
        from r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.athanor_id == r.athanor_id,
          join: p in Arca.Schemas.Profile,
          on: p.head_consent_id == c.id and p.athanor_id == c.athanor_id,
          where: r.vault_entry_id == ^vault_entry_id and r.athanor_id == ^athanor_id,
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
