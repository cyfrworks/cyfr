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

  `profiles/2` and `head_consent/2` are the read side the consent decision
  logic (`Sanctum.Consent.Loader` and the walk around it) sees. They decode
  strictly and fail closed: a stored kind, status, scope or invoke mode
  outside the closed vocabulary, or an activation blob that does not parse,
  drops the profile or refuses the consent rather than guessing. Rows can
  only get that way through a bug or a hand edit, and neither may root an
  execution.
  """

  import Ecto.Query

  alias Arca.Schemas.Consent
  alias Arca.Schemas.ConsentVaultRef

  @typedoc """
  One immutable consent revision, decoded.

  `vault_refs` carries the derived reverse-index rows for the revision —
  the consent decision's blob/refs equality check needs both sides, and
  delivering them together keeps the check atomic with the read.

  The atoms are spelled here rather than borrowed from the layer above:
  this is the closed vocabulary the column holds, and the decision layer's
  own types are defined against the same words.
  """
  @type consent :: %{
          required(:id) => String.t(),
          required(:revision) => non_neg_integer(),
          required(:scope) => :versionless | :pinned,
          required(:pinned_version) => String.t(),
          required(:invoke_mode) => :open_inert | :edge_only,
          required(:shape_digest) => String.t(),
          required(:commit_digest) => String.t(),
          required(:blob_digest) => String.t() | nil,
          required(:resolved_policy) => String.t(),
          required(:activation) => %{String.t() => String.t()},
          required(:vault_refs) => [
            %{vault_entry_id: String.t(), binding_digest: String.t()}
          ]
        }

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

    # Through the schema's changeset, never a raw struct: the label rule
    # and the kind/status vocabulary are the changeset's, and this is the
    # one production mint of a profile.
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :profile,
      Arca.Schemas.Profile.changeset(%Arca.Schemas.Profile{}, profile_attrs)
    )
    |> revision_multi(row, vault_refs, nil, athanor_id, opts)
    |> run_multi(:consent)
  end

  defp revision_row(attrs, athanor_id) do
    # A nonempty blob_digest is required to verify resolved_policy.
    # Reject nil and empty strings before the raw struct insert.
    case Map.fetch!(attrs, :blob_digest) do
      digest when is_binary(digest) and digest != "" ->
        :ok

      other ->
        raise ArgumentError,
              "consent revisions require a blob_digest, got: #{inspect(other)}"
    end

    attrs
    |> Map.put(:athanor_id, athanor_id)
    |> Map.put_new(:id, Cyfr.UUID7.generate_id("cons"))
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

    # A writer that lost the race to the same revision meets the unique
    # index before the head CAS; both answer `:head_moved`.
    consent =
      Consent
      |> struct(row)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:profile_id, :revision])

    multi
    |> Ecto.Multi.insert(:consent, consent)
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
      case Arca.ProfileStorage.advance_head(
             Cyfr.Actor.in_athanor(athanor_id),
             row.profile_id,
             expected_head,
             row.id
           ) do
        :ok -> {:ok, :advanced}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp run_multi(multi, return_key) do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.run_multi", fn ->
      case Arca.Repo.transaction(multi) do
        {:ok, done} ->
          {:ok, Map.fetch!(done, return_key)}

        {:error, :consent, %Ecto.Changeset{errors: errors} = changeset, _done} ->
          if Keyword.has_key?(errors, :profile_id),
            do: {:error, :head_moved},
            else: {:error, changeset}

        {:error, _step, reason, _done} ->
          {:error, reason}
      end
    end)
  end

  defp insert_refs([]), do: {0, nil}
  # arca:unscoped-ok each row was derived from the consent being committed, athanor included.
  defp insert_refs(rows), do: Arca.Repo.insert_all(ConsentVaultRef, rows)

  @doc "The head consent revision of a profile, with its vault refs."
  # `get_head/2` and `head_profiles_referencing/2` take the `Cyfr.Actor`
  # first and match it in the head, so the athanor comes from the caller;
  # an actor whose athanor is nil or the empty string is
  # `{:error, :no_athanor}` before any query. The two multi writers take
  # attribute maps their caller assembled and stamp no tenant of their
  # own.
  @spec get_head(Cyfr.Actor.t(), String.t()) ::
          {:ok, Consent.t(), [ConsentVaultRef.t()]}
          | {:error, :no_athanor | :not_found | :no_head | term()}
  def get_head(%Cyfr.Actor{athanor_id: athanor_id} = actor, profile_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.get_head", fn ->
      with {:ok, profile} <- Arca.ProfileStorage.get(actor, profile_id),
           head_id when is_binary(head_id) <- profile.head_consent_id || {:error, :no_head},
           %Consent{} = consent <-
             Arca.Repo.get_by(Consent, id: head_id, athanor_id: athanor_id) do
        refs =
          from(r in ConsentVaultRef, where: r.consent_id == ^head_id)
          |> Arca.QueryHelpers.where_athanor(athanor_id)
          |> Arca.Repo.all()

        {:ok, consent, refs}
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def get_head(%Cyfr.Actor{}, _profile_id), do: {:error, :no_athanor}

  @doc """
  Profiles whose **head** revision references a vault entry.

  Deliberately head-only: counting every historical revision would
  over-report — a profile that dropped the entry two revisions ago is not
  affected right now.
  """
  @spec head_profiles_referencing(Cyfr.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def head_profiles_referencing(%Cyfr.Actor{athanor_id: athanor_id}, vault_entry_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.head_profiles_referencing", fn ->
      ids =
        from(r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.athanor_id == r.athanor_id,
          join: p in Arca.Schemas.Profile,
          on: p.head_consent_id == c.id and p.athanor_id == c.athanor_id,
          where: r.vault_entry_id == ^vault_entry_id,
          distinct: true,
          select: p.id
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, ids}
    end)
  end

  def head_profiles_referencing(%Cyfr.Actor{}, _vault_entry_id), do: {:error, :no_athanor}

  @doc """
  Candidate profiles for a name-level source ref within the actor's tenant,
  decoded into the selection vocabulary.

  A row whose stored kind or status is outside the closed vocabulary is
  dropped rather than guessed at: it cannot be selected, and a selection
  that silently admitted it would root an execution on a value no writer
  of this table can produce.
  """
  @spec profiles(Cyfr.Actor.t(), String.t()) ::
          {:ok, [Cyfr.Authority.RootSelect.profile_summary()]} | {:error, term()}
  def profiles(%Cyfr.Actor{} = actor, source_ref) do
    with {:ok, rows} <- Arca.ProfileStorage.list_for_source(actor, source_ref) do
      {:ok, rows |> Enum.map(&profile_summary/1) |> Enum.reject(&is_nil/1)}
    end
  end

  @doc """
  The head consent revision of a profile, fully decoded with its vault refs.

  Decoding fails closed — a stored scope or invoke mode outside the closed
  vocabulary, or an activation blob that does not parse, refuses the
  consent. `resolved_policy` stays a string: `Cyfr.Authority.Blob.parse/1`
  is the single fail-closed entry for those bytes and this is not it.
  """
  @spec head_consent(Cyfr.Actor.t(), String.t()) ::
          {:ok, consent()} | {:error, :no_athanor | :not_found | :no_head | term()}
  def head_consent(%Cyfr.Actor{} = actor, profile_id) do
    with {:ok, consent, refs} <- get_head(actor, profile_id) do
      decode_consent(consent, refs)
    end
  end

  defp profile_summary(row) do
    with {:ok, kind} <- decode_enum(row.kind, %{"owner" => :owner, "public" => :public}),
         {:ok, status} <-
           decode_enum(row.status, %{
             "active" => :active,
             "needs_consent" => :needs_consent,
             "revoked" => :revoked
           }) do
      %{id: row.id, kind: kind, source_ref: row.source_ref, label: row.label, status: status}
    else
      _ -> nil
    end
  end

  defp decode_consent(consent, refs) do
    with {:ok, scope} <-
           decode_enum(consent.scope, %{"versionless" => :versionless, "pinned" => :pinned}),
         {:ok, invoke_mode} <-
           decode_enum(consent.invoke_mode, %{
             "open_inert" => :open_inert,
             "edge_only" => :edge_only
           }),
         {:ok, activation} <- decode_activation(consent.activation) do
      {:ok,
       %{
         id: consent.id,
         revision: consent.revision,
         scope: scope,
         pinned_version: consent.pinned_version,
         invoke_mode: invoke_mode,
         shape_digest: consent.shape_digest,
         commit_digest: consent.commit_digest,
         blob_digest: consent.blob_digest,
         resolved_policy: consent.resolved_policy,
         activation: activation,
         vault_refs:
           Enum.map(refs, fn r ->
             %{vault_entry_id: r.vault_entry_id, binding_digest: r.binding_digest}
           end)
       }}
    end
  end

  defp decode_enum(value, mapping) do
    case Map.fetch(mapping, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_stored_value, value}}
    end
  end

  defp decode_activation(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{} = graph} ->
        if Enum.all?(graph, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, graph}
        else
          {:error, {:invalid_stored_value, :activation}}
        end

      _ ->
        {:error, {:invalid_stored_value, :activation}}
    end
  end

  defp decode_activation(_), do: {:error, {:invalid_stored_value, :activation}}
end
