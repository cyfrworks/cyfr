# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent do
  @moduledoc """
  Consent: the act by which an operator grants a component the authority it
  runs under, and the vocabulary that act is expressed in.

  This module holds the **contract** — the protocol shape, the error
  payloads, and the types every participant agrees on. The verbs live
  beside it:

  | Module | Role |
  |---|---|
  | `Sanctum.Consent.ShapeDigest` | what the operator was shown, before any choice |
  | `Sanctum.Consent.CommitDigest` | the shape plus every decision made on it |
  | `Sanctum.Consent.Proof` | single-use authorization bound to one commit |
  | `Sanctum.Consent.Authz` | who may consent at all |

  ## Reading consent from above

  Consent rows are security rows, read only inside Sanctum: Arca's
  consent stores are Sanctum's alone. A domain or a surface reads consent
  state through Sanctum's exported entries, among them `profiles/2`,
  `head_consent/2` and `row_binding/3` here, `Sanctum.Consent.Accounts`
  and `Sanctum.Consent.Loader`, each scoped by the tenant of the caller's
  context.

  ## The protocol

  Three steps, because the authorization must bind the *exact* thing the
  operator saw — not a plan that could still change underneath it:

      plan     {ref, label?, kind?, scope?}
               → shape digest, expected revision, candidates, defaults,
                 the ask as preview rows, the default origins

      preview  {plan_token, decisions}
               → the structured preview (rows, origins, the head's
                 bindings it removes, commit digest) and the proof

      commit   {plan_token, decisions, commit_digest, expected_revision, proof}
               → verify the proof binds THIS commit digest, recompute the
                 live shape digest, re-verify vault binding liveness, CAS on
                 the head revision, then insert with its admitted origins

  `preview` exists so a proof can bind the exact commit digest that was
  rendered. Without it, a choice made after approval — a different vault
  entry, a widened projection — would be covered by an authorization the
  operator never gave.

  Decisions may narrow the ask (`subset`, per consent-graph node and
  resource kind) and name the origins the grant admits (`origins`,
  `interactive` alone when absent); the commit digest binds both
  (`Sanctum.Consent.Commit`).

  ## Errors

  These cross the MCP boundary, the console, the PWA and the CLI, and the
  first four the WIT boundary too, so their payloads are normative rather
  than incidental.

      setup_required         {profile_id, node_ref, need, reason}
      consent_required       {profile_id, current_revision, shape_diff}
      consent_conflict       {expected_revision, actual_revision, cause}
      restart_required       {profile_id, new_revision, missing}
      confirmation_required  {id, operation, expires_at}

  `consent_conflict`'s cause distinguishes a stale plan from a digest that
  changed under the operator from a genuine race — different remedies:
  re-plan, re-preview, or retry. `confirmation_required` is no denial: the
  change stands and waits for a fresh confirmation of the pending
  confirmation `id` names.
  """

  @type scope :: :versionless | :pinned
  @type invoke_mode :: :open_inert | :edge_only
  @type profile_kind :: :owner | :public

  @typedoc """
  How a consent revision was granted. `:bootstrap` marks machine-minted
  revisions — connections bind through the walk, so these carry no entry
  of the athanor's, and the one binding one may carry is the instance
  entry a newly provisioned athanor's person is offered alone
  (`Sanctum.Consent.Bootstrap`); no human granted them. Recording them as
  `:interactive` would render a false audit line ("you, interactive")
  into every enforcement display forever.
  """
  @type granted_via :: :interactive | :scoped_key | :bootstrap

  @type conflict_cause :: :stale_plan | :digest_changed | :race

  @type setup_required :: %{
          profile_id: String.t(),
          node_ref: String.t(),
          need: String.t(),
          reason: atom()
        }

  @type consent_required :: %{
          profile_id: String.t(),
          current_revision: non_neg_integer(),
          shape_diff: [String.t()]
        }

  @type consent_conflict :: %{
          expected_revision: non_neg_integer(),
          actual_revision: non_neg_integer(),
          cause: conflict_cause()
        }

  @type restart_required :: %{
          profile_id: String.t(),
          new_revision: non_neg_integer(),
          missing: %{chain: [String.t()], edge: String.t(), activation: String.t()}
        }

  @type confirmation_required :: %{
          id: String.t(),
          operation: String.t(),
          expires_at: DateTime.t()
        }

  @typedoc """
  What `preview` answers: a `Prima.ConsentPreview` document, its fields
  beside the envelope a commit presents.

    * `v`, `rows`, `origins`, `commit_digest`, `removed` — the document:
      its version, its typed rows each in the row's JSON form
      (`Prima.ConsentPreview.Row`), the origins the grant would admit as
      their wire spellings, the commit digest binding them, and the
      bindings of the profile's head the revision would remove, each in
      its JSON form (`Prima.ConsentPreview`'s "Removed bindings"), empty
      when it removes none. `Prima.ConsentPreview.decode/1` reads these
      five back.
    * `proof` and `expected_consent_revision` — what the commit presents
      with the digest.
  """
  @type preview :: %{
          v: pos_integer(),
          rows: [%{required(String.t()) => term()}],
          origins: [String.t(), ...],
          commit_digest: String.t(),
          removed: [Prima.ConsentPreview.removed()],
          proof: String.t(),
          expected_consent_revision: non_neg_integer()
        }

  @type error ::
          {:setup_required, setup_required()}
          | {:consent_required, consent_required()}
          | {:consent_conflict, consent_conflict()}
          | {:restart_required, restart_required()}
          | {:confirmation_required, confirmation_required()}

  @doc """
  The scopes a consent may take.

  `:versionless` applies to every release of a component line and is the
  default — the resolved policy is an allowlist, so applying it to a newer
  release can only ever grant less than it names, never more. `:pinned`
  names one exact activation, and is forced for consents carrying an
  override and for every public profile.
  """
  @spec scopes() :: [scope()]
  def scopes, do: [:versionless, :pinned]

  @typedoc """
  One candidate profile of a source: decoded, or — when its stored kind or
  status is outside the closed vocabulary — only its id and `:corrupt`.
  """
  @type profile_entry ::
          Prima.Authority.RootSelect.profile_summary()
          | %{required(:id) => String.t(), required(:status) => :corrupt}

  @doc """
  The non-revoked profiles of a name-level `source_ref` in the caller's
  athanor. A row that cannot be decoded is present as
  `%{id: id, status: :corrupt}`, never dropped: a caller that needs the
  decoded profile treats it as unavailable for that profile.

  `{:error, :unavailable}` is a store that could not answer, never an
  empty list; `{:error, :no_athanor}` is a context with no tenant.
  """
  @spec profiles(Sanctum.Context.t(), String.t()) ::
          {:ok, [profile_entry()]} | {:error, :unavailable | :no_athanor}
  def profiles(%Sanctum.Context{} = ctx, source_ref) when is_binary(source_ref) do
    case Arca.ConsentStorage.profile_entries(Sanctum.Context.actor(ctx), source_ref) do
      {:ok, entries} -> {:ok, entries}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  @doc """
  The head consent revision of a profile in the caller's athanor, decoded
  with its vault references (`t:Arca.ConsentStorage.consent/0`).

  A profile with no head, or no such profile, is `:not_found`; a stored
  value outside the closed vocabulary is `:corrupt`; a store that could
  not answer is `:unavailable`.
  """
  @spec head_consent(Sanctum.Context.t(), String.t()) ::
          {:ok, Arca.ConsentStorage.consent()}
          | {:error, :not_found | :unavailable | :corrupt | :no_athanor}
  def head_consent(%Sanctum.Context{} = ctx, profile_id) when is_binary(profile_id) do
    case Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id) do
      {:ok, consent} -> {:ok, consent}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, absent} when absent in [:not_found, :no_head] -> {:error, :not_found}
      {:error, {:invalid_stored_value, _field}} -> {:error, :corrupt}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  @doc """
  What one vault row of the head revision `consent` (from
  `head_consent/2`) binds now, read by its tag: the athanor's own entry,
  a selection of another profile's key resolved as a run resolves it
  under the context's origin, an instance entry read live as the
  context's person is offered it and held to the row's digest, or a row
  naming none (`Sanctum.Consent.Loader.row_binding/3`). Nothing is
  raised.
  """
  @spec row_binding(Sanctum.Context.t(), map(), map()) ::
          {:entry, String.t(), String.t()}
          | {:selection, String.t(), {:ok, map()} | {:error, term()}}
          | {:instance, String.t(), {:ok, map()} | {:error, term()}}
          | :malformed
  def row_binding(%Sanctum.Context{} = ctx, consent, ref) when is_map(consent) and is_map(ref),
    do: Sanctum.Consent.Loader.row_binding(ctx, consent, ref)

  @doc """
  Revoke every profile of a name-level `source_ref` in the caller's
  athanor, in one transaction — what removing the last version of a
  component does to the grants made for it. Consent history and vault
  entries remain. Answers the ids revoked.
  """
  @spec revoke_source(Sanctum.Context.t(), String.t()) ::
          {:ok, %{revoked: [String.t()]}} | {:error, :unavailable | :no_athanor}
  def revoke_source(%Sanctum.Context{} = ctx, source_ref) when is_binary(source_ref) do
    case Arca.ProfileStorage.revoke_for_source(Sanctum.Context.actor(ctx), source_ref) do
      {:ok, ids} -> {:ok, %{revoked: ids}}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end
end
