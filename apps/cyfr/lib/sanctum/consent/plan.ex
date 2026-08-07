# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Plan do
  @moduledoc """
  The plan verb: everything the operator must see before deciding, plus
  the plan token that pins what they were shown.

  The token binds the **shape digest** — the pre-decision facts — and the
  expected consent revision, and is consumed only at commit. Preview stays
  re-runnable while the operator changes decisions; if the world moves
  between plan and commit (a new release, a concurrent revision), the
  bindings no longer match and the commit surfaces `consent_conflict`
  instead of granting against stale facts.

  Needs vocabulary: until manifests declare named needs, every component
  exposes the single ingress slot, spelled `"@ingress"` in decisions —
  the edge the bound credential rides. The blob edge-key grammar reserves
  `@`-prefixed names, so a future manifest need can never collide.
  """

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  # Ten minutes: an operator reads candidates and decides. The commit
  # proof (120s) is the short-lived one; the plan token only pins facts.
  @plan_ttl_ms 600_000

  @type t :: %{
          plan_token: String.t(),
          shape_digest: String.t(),
          expected_consent_revision: non_neg_integer(),
          profile_id: String.t() | nil,
          source_ref: String.t(),
          needs: [map()],
          caps: map(),
          limits: map(),
          candidates: [map()],
          warnings: [String.t()],
          defaults: map()
        }

  @doc "Stage a consent: facts, candidates, and the plan token."
  @spec plan(Context.t(), map()) :: {:ok, t()} | {:error, term()}
  def plan(%Context{} = ctx, %{ref: ref} = params) when is_binary(ref) do
    label = Map.get(params, :label, "default")
    kind = Map.get(params, :kind, :owner)

    with :ok <- Authz.authorize_staging(ctx),
         {:ok, source_ref} <- name_ref(ref),
         {:ok, _component} <- fetch_component(ctx, source_ref),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- ShapeDigest.compute(shape_input),
         {:ok, profile_id, expected_revision} <- locate_profile(ctx, source_ref, label, kind),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, source_ref),
         {:ok, candidates} <- candidates(ctx),
         {:ok, plan_token} <-
           mint_token(ctx, shape_digest, profile_id, expected_revision) do
      {:ok,
       %{
         plan_token: plan_token,
         shape_digest: shape_digest,
         expected_consent_revision: expected_revision,
         profile_id: profile_id,
         source_ref: source_ref,
         needs: needs(),
         caps: Sanctum.Consent.BlobBuilder.resource_map(policy),
         limits: Sanctum.Consent.BlobBuilder.limits_map(policy),
         candidates: candidates,
         tool_server_candidates: Emissary.MCP.ExternalProvider.consent_candidates(ctx),
         warnings: [],
         defaults: %{scope: :versionless, kind: kind, label: label, invoke_mode: :open_inert}
       }}
    end
  end

  def plan(_ctx, _params), do: {:error, {:invalid_plan, :ref_required}}

  @doc false
  # Shared with the commit path: which profile (if any) this grant would
  # revise, and the revision the caller must expect. A needs_consent
  # profile is a first-class target — re-consent is how it unblocks.
  def locate_profile(ctx, source_ref, label, kind) do
    with {:ok, profiles} <- Source.impl().profiles(ctx, source_ref) do
      case Enum.find(profiles, fn p -> p.label == label and p.kind == kind end) do
        nil ->
          {:ok, nil, 0}

        profile ->
          case Source.impl().head_consent(ctx, profile.id) do
            {:ok, consent} -> {:ok, profile.id, consent.revision}
            {:error, :no_head} -> {:ok, profile.id, 0}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc false
  def name_ref(ref) do
    case Compendium.Activation.key_for_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_ref, reason}}
    end
  end

  @doc false
  def fetch_component(ctx, source_ref) do
    with {:ok, parsed} <- Sanctum.ComponentRef.parse(source_ref),
         {:ok, component} <-
           Compendium.Registry.get_latest(ctx, parsed.name, parsed.namespace, parsed.type) do
      {:ok, component}
    else
      {:error, reason} -> {:error, {:component_not_found, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp needs do
    [
      %{
        need: "@ingress",
        reason: "credentials this component may use when invoked",
        required: false
      }
    ]
  end

  defp candidates(ctx) do
    with {:ok, entries} <- Sanctum.Vault.list(ctx) do
      {:ok, Enum.filter(entries, &(&1.status == "active"))}
    end
  end

  defp mint_token(ctx, shape_digest, profile_id, expected_revision) do
    bindings =
      %{
        kind: :plan,
        commit_digest: shape_digest,
        actor: ctx.user_id,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        expected_revision: expected_revision
      }
      |> put_present(:profile_id, profile_id)

    Proof.mint(bindings, ttl_ms: @plan_ttl_ms)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
