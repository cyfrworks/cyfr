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

  Consent rows are security rows: a domain or a surface learns about
  them only through `profiles/2`, `head_consent/2` and `revoke_source/2`
  here. Each scopes by the tenant of the caller's context, and each keeps
  an unreadable store, a damaged row and an absent one apart — a caller
  that cannot tell them apart would read an outage as "not granted".

  ## The protocol

  Three steps, because the authorization must bind the *exact* thing the
  operator saw — not a plan that could still change underneath it:

      plan     {ref, label?, kind?, scope?}
               → shape digest, expected revision, candidates, defaults

      preview  {plan_token, decisions}
               → commit digest, rendered summary

      commit   {plan_token, decisions, commit_digest, expected_revision, proof}
               → verify the proof binds THIS commit digest, recompute the
                 live shape digest, re-verify vault binding liveness, CAS on
                 the head revision, then insert

  `preview` exists so a proof can bind the exact commit digest that was
  rendered. Without it, a choice made after approval — a different vault
  entry, a widened projection — would be covered by an authorization the
  operator never gave.

  ## Errors

  These four cross the WIT boundary, the MCP boundary, the console, the PWA
  and the CLI, so their payloads are normative rather than incidental.

      setup_required     {profile_id, node_ref, need, reason}
      consent_required   {profile_id, current_revision, shape_diff}
      consent_conflict   {expected_revision, actual_revision, cause}
      restart_required   {profile_id, new_revision, missing}

  `consent_conflict`'s cause distinguishes a stale plan from a digest that
  changed under the operator from a genuine race — different remedies:
  re-plan, re-preview, or retry.
  """

  @type scope :: :versionless | :pinned
  @type invoke_mode :: :open_inert | :edge_only
  @type profile_kind :: :owner | :public

  @typedoc """
  How a consent revision was granted. `:bootstrap` marks machine-minted
  revisions — connections bind through the walk, so these carry no vault
  resource and no human granted them. Recording them as `:interactive`
  would render a false audit line ("you, interactive") into every
  enforcement display forever.
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

  @type error ::
          {:setup_required, setup_required()}
          | {:consent_required, consent_required()}
          | {:consent_conflict, consent_conflict()}
          | {:restart_required, restart_required()}

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
          Cyfr.Authority.RootSelect.profile_summary()
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
