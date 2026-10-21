# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent do
  @moduledoc """
  Consent: the act by which an operator grants a component the authority it
  runs under, and the vocabulary that act is expressed in.

  This module holds the **contract** — the protocol shape, the error
  payloads, and the types every participant agrees on. The verbs live
  beside it, `plan` in `Sanctum.Consent.Plan` and `preview`, `commit` and
  `grant` in `Sanctum.Consent.Commit`, and rest on these:

  | Module | Role |
  |---|---|
  | `Sanctum.Consent.ShapeDigest` | what the operator was shown, before any choice |
  | `Sanctum.Consent.CommitDigest` | the shape plus every decision made on it |
  | `Sanctum.Consent.Proof` | single-use authorization bound to one commit |
  | `Sanctum.Consent.Authz` | who may consent at all, and whether a sensitive change is confirmed |

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

      plan     {ref, label?, kind?}
               → plan token, shape digest, expected revision, candidates,
                 defaults, the ask as preview rows, the default origins

      preview  {decisions}
               → the structured preview (rows, origins, the head's
                 bindings it removes, commit digest) and the proof

      commit   {decisions, plan_token, proof, commit_digest,
                expected_consent_revision}
               → authorize the caller, recompute the live shape, check
                 the expected revision, consume the plan token, check the
                 presented commit digest against the recomputed one,
                 consume the proof bound to it, then in one transaction
                 insert the revision with its admitted origins, write its
                 rows, re-verify vault binding liveness and compare-and-set
                 the head

  Beside the three steps, `grant` (`profile.grant`) writes a revision of
  an existing owner profile whose shape has not moved, binding an entry
  to a need, with no plan, preview or proof: it re-issues the head's
  scope, invoke mode, origins and narrowing under the same revision
  compare-and-set (`Sanctum.Consent.Commit.grant/2`).

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
  first three the WIT boundary too, so their payloads are normative rather
  than incidental.

      setup_required         {profile_id, node_ref, need, reason}
      consent_required       {profile_id, current_revision, shape_diff}
      consent_conflict       {expected_revision, actual_revision, cause}
      confirmation_required  {id, operation, expires_at}

  `consent_required`'s `shape_diff` is what changed since the head, one
  entry per capability of each node of the closure, each naming its
  `node` and whether the head never held it (`new`) or the ask no longer
  names it (`dropped`) (`Sanctum.Consent.ShapeDiff`).

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
          shape_diff: [Sanctum.Consent.ShapeDiff.entry()]
        }

  @type consent_conflict :: %{
          expected_revision: non_neg_integer(),
          actual_revision: non_neg_integer(),
          cause: conflict_cause()
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
          | {:confirmation_required, confirmation_required()}

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
  The grant the installed tincture version `reference` (pinned to its
  version) opens under: its one active owner profile's head, held to that
  version by the decision a run is held to, so a version that reads more
  than the consent's shape asks again (`Sanctum.Consent.TinctureGrant`).
  `{:error, :ungranted}` while the person has to consent, a tincture with
  no grant at all among them; `{:error, :unavailable}` when it could not
  be read; `{:error, {:refused, reason}}` for damage no consent repairs.
  """
  @spec tincture_grant(Sanctum.Context.t(), String.t()) ::
          {:ok, Sanctum.Consent.TinctureGrant.t()}
          | {:error, Sanctum.Consent.TinctureGrant.refusal()}
  defdelegate tincture_grant(ctx, reference), to: Sanctum.Consent.TinctureGrant, as: :fetch

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
