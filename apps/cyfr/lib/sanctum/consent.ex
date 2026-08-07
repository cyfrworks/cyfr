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

  Persistence and the API endpoints are deliberately not here yet; these
  are the pure verbs the endpoints will be built from.

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
  @type granted_via :: :interactive | :scoped_key

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

  @doc """
  The ways a consent can have been granted, as recorded on the revision.
  """
  @spec granted_via_values() :: [granted_via()]
  def granted_via_values, do: [:interactive, :scoped_key]
end
