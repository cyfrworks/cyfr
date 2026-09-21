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

  A dependency edge of the closure whose target declares a credential
  need is a `dependency_needs` row: who lends, what it needs, and which
  of its own owner profiles bind an entry — the candidates a `selections`
  decision picks from, so that edge runs the dependency with the key
  bound on that profile rather than a copy of its own.
  """

  alias Cyfr.Authority.RootSelect
  alias Sanctum.Consent.Components

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
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
          dependency_needs: [map()],
          caps: map(),
          limits: map(),
          candidates: [map()],
          tool_server_candidates: [Sanctum.Catalog.tool_server_candidate()],
          warnings: [String.t()],
          defaults: map()
        }

  @doc "Stage a consent: facts, candidates, and the plan token."
  @spec plan(Context.t(), map()) :: {:ok, t()} | {:error, term()}
  def plan(%Context{} = ctx, %{ref: ref} = params) when is_binary(ref) do
    label = Map.get(params, :label, "default")
    kind = Map.get(params, :kind, :owner)

    with :ok <- Authz.authorize_staging(ctx),
         :ok <- RootSelect.check_label(label),
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
         dependency_needs: dependency_needs(ctx, component, source_ref),
         caps: resources,
         limits: limits,
         candidates: candidates,
         tool_server_candidates: Sanctum.Catalog.tool_server_candidates(ctx),
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
    with {:ok, profiles} <- Arca.ConsentStorage.profiles(Context.actor(ctx), source_ref) do
      case Enum.find(profiles, fn p -> p.label == label and p.kind == kind end) do
        nil ->
          {:ok, nil, 0}

        profile ->
          case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id) do
            {:ok, consent} -> {:ok, profile.id, consent.revision}
            {:error, :no_head} -> {:ok, profile.id, 0}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @doc false
  def name_ref(ref) do
    case Cyfr.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_ref, reason}}
    end
  end

  @doc false
  def fetch_component(ctx, source_ref) do
    with {:ok, parsed} <- Cyfr.ComponentRef.parse(source_ref),
         {:ok, component} <-
           Components.get_latest(ctx, parsed.name, parsed.namespace, parsed.type) do
      {:ok, component}
    else
      {:error, reason} -> {:error, {:component_not_found, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp decode_manifest(component) do
    Cyfr.Manifest.decode(Map.get(component, :manifest) || Map.get(component, "manifest"))
  end

  # Declared needs become the sheet's rows — the operator sees each
  # need's reason, never the developer's key names. A manifest with no
  # needs block keeps the single ingress slot.
  defp need_rows(manifest) do
    case Cyfr.Manifest.Needs.from_manifest(manifest) do
      nil ->
        [
          %{
            need: Cyfr.Authority.Blob.ingress_key(),
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
  # only after the operator creates a vault entry — say so up front.
  defp need_warnings(needs, candidates) do
    kinds = candidates |> Enum.map(& &1.kind) |> MapSet.new()

    for %{required: true, kind: kind, need: name} <- needs,
        kind in ~w(api_key oauth bundle),
        not MapSet.member?(kinds, kind) do
      "need '#{name}' wants a #{kind} vault entry and none exists yet — create one first"
    end
  end

  defp candidates(ctx) do
    with {:ok, entries} <- Sanctum.Vault.list(ctx) do
      {:ok, Enum.filter(entries, &(&1.status == "active"))}
    end
  end

  # The closure's dependency edges whose target declares a credential
  # need, each with the owner profiles of that target that bind one —
  # what a selection may name. A closure that cannot be resolved offers
  # none; the commit refuses a selection it cannot place anyway.
  defp dependency_needs(ctx, component, _source_ref) do
    case Components.resolve(ctx, component) do
      {:ok, %{graph: graph}} ->
        graph
        |> Map.keys()
        |> Enum.sort()
        |> Enum.flat_map(fn from ->
          case node_manifest(ctx, from) do
            {:ok, manifest} ->
              manifest
              |> BlobBuilder.dep_edges(graph, from)
              |> Enum.sort()
              |> Enum.flat_map(&dependency_rows(ctx, from, &1))

            _ ->
              []
          end
        end)

      _unresolvable ->
        []
    end
  end

  defp node_manifest(ctx, node_key) do
    with {:ok, ref} <- Cyfr.ComponentRef.parse(node_key),
         {:ok, row} <- Components.get_latest(ctx, ref.name, ref.namespace, ref.type) do
      {:ok, Cyfr.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest"))}
    end
  end

  defp dependency_rows(ctx, from, dep) do
    case ShapeDerivation.manifest_blocks(ctx, dep) do
      {:ok, needs, _caps} when is_list(needs) ->
        case Enum.filter(needs, &(&1.kind in ~w(api_key oauth bundle))) do
          [] ->
            []

          credential_needs ->
            [
              %{
                from: from,
                dep: dep,
                needs:
                  Enum.map(credential_needs, fn need ->
                    %{
                      need: need.name,
                      type: "#{need.kind}:#{need.qualifier}",
                      reason: need.reason,
                      required: need.required,
                      fields: need.fields
                    }
                  end),
                candidates: lender_candidates(ctx, dep)
              }
            ]
        end

      _ ->
        []
    end
  end

  # The dependency's active owner profiles whose head binds a usable entry.
  defp lender_candidates(ctx, dep) do
    case Arca.ConsentStorage.profiles(Context.actor(ctx), dep) do
      {:ok, profiles} ->
        for %{kind: :owner, status: :active} = profile <- profiles,
            {:ok, head} <- [Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id)],
            {:ok, blob} <- [Cyfr.Authority.Blob.parse(head.resolved_policy)],
            {:ok, ingress} <- [Cyfr.Authority.Blob.ingress(blob, dep)],
            Cyfr.Authority.Blob.bound_vault?(ingress.vault),
            {:ok, entry} <-
              [
                Sanctum.VaultReader.usable(
                  ctx.athanor_id,
                  ingress.vault.entry_id,
                  ingress.vault.binding_digest
                )
              ] do
          %{
            profile_id: profile.id,
            label: profile.label,
            entry_id: entry.id,
            entry_name: entry.name,
            fields: (ingress.vault.projection && ingress.vault.projection.fields) || []
          }
        end

      _ ->
        []
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
      |> Cyfr.MapUtil.put_present(:profile_id, profile_id)

    Proof.mint(bindings, ttl_ms: @plan_ttl_ms)
  end
end
