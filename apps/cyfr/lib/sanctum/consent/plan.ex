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
         {:ok, component} <- fetch_component(ctx, source_ref),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- ShapeDigest.compute(shape_input),
         {:ok, profile_id, expected_revision} <- locate_profile(ctx, source_ref, label, kind),
         manifest = decode_manifest(component),
         {:ok, resources, limits} <-
           Sanctum.Consent.BlobBuilder.node_grant(ctx, source_ref, manifest),
         {:ok, candidates} <- candidates(ctx),
         needs = need_rows(manifest),
         {:ok, plan_token} <-
           mint_token(ctx, shape_digest, profile_id, expected_revision) do
      {:ok,
       %{
         plan_token: plan_token,
         shape_digest: shape_digest,
         expected_consent_revision: expected_revision,
         profile_id: profile_id,
         source_ref: source_ref,
         needs: needs,
         caps: resources,
         limits: limits,
         candidates: candidates,
         tool_server_candidates: Emissary.MCP.ExternalProvider.consent_candidates(ctx),
         warnings: need_warnings(needs, candidates),
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

  defp decode_manifest(component) do
    Compendium.Manifest.decode(Map.get(component, :manifest) || Map.get(component, "manifest"))
  end

  # Declared needs become the sheet's rows — the operator sees each
  # need's reason, never the developer's key names. A manifest with no
  # needs block keeps the single ingress slot.
  defp need_rows(manifest) do
    case Compendium.Manifest.Needs.from_manifest(manifest) do
      nil ->
        [
          %{
            need: "@ingress",
            reason: "credentials this component may use when invoked",
            required: false
          }
        ]

      declared ->
        Enum.map(declared, fn need ->
          %{
            need: need.name,
            type: "#{need.kind}:#{need.qualifier}",
            kind: need.kind,
            reason: need.reason,
            fields: need.fields,
            scopes: need.scopes,
            required: need.required
          }
        end)
    end
  end

  # A required need with no active candidate of its kind is satisfiable
  # only after the operator creates a Connection — say so up front.
  defp need_warnings(needs, candidates) do
    kinds = candidates |> Enum.map(& &1.kind) |> MapSet.new()

    for %{required: true, kind: kind, need: name} <- needs,
        kind in ~w(api_key oauth bundle),
        not MapSet.member?(kinds, kind) do
      "need '#{name}' wants a #{kind} connection and none exists yet — create one first"
    end
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
        athanor_id: ctx.athanor_id,
        expected_revision: expected_revision
      }
      |> put_present(:profile_id, profile_id)

    Proof.mint(bindings, ttl_ms: @plan_ttl_ms)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
