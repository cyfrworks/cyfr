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

  The ask is answered as `rows`, the typed rows of `Prima.ConsentPreview`
  in their JSON form, one per resource each node of the closure asks for,
  its limits, and a tincture's frame, streams, cards and system actions:
  what a narrowing is chosen from, none of it narrowed yet. `origins` is
  the default a decision that names none admits, `interactive` alone.

  A plan for a profile with a head says what the head holds:
  `head_origins`, the origins it admits, so a re-grant starts from them
  rather than quietly dropping one; and, when the component's shape moved
  since the head, `shape_diff`, the head as the person narrowed it against
  the live ask (`Sanctum.Consent.ShapeDiff`). With no head, `head_origins` is nil
  and `shape_diff` empty.

  `candidates` are the athanor's active entries. An OAuth candidate answers
  `narrowable`, whether a token for fewer of its scopes can be dispensed,
  which is so only where its provider attenuates a refresh
  (`Sanctum.Vault.OAuth.attenuates_scope?/1`); a need asking for fewer
  scopes than a candidate that is not narrowable holds is not met by it.

  A closure that cannot be resolved is `unresolved`: `%{reason, missing}`,
  the reason's tag (`"unresolvable_dependency"`, `"missing_release_digest"`
  or the resolution's own) and the name-level ref of what is missing,
  `nil` when the resolution names none. Its `rows` are empty, since the
  source's rows alone are not the ask, and it offers no selection; the
  preview and the commit refuse it. A resolved closure is `unresolved:
  nil`.
  """

  alias Prima.Authority.RootSelect
  alias Sanctum.Consent.Components

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Sanctum.Vault.OAuth

  require Logger

  # Ten minutes: an operator reads candidates and decides. The commit
  # proof (120s) is the short-lived one; the plan token only pins facts.
  @plan_ttl_ms 600_000

  # What a grant admits when its decision names no origin.
  @default_origins [:interactive]

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
          rows: [BlobBuilder.row()],
          unresolved: %{reason: String.t(), missing: String.t() | nil} | nil,
          origins: [String.t(), ...],
          head_origins: [String.t(), ...] | nil,
          shape_diff: [map()],
          candidates: [map()],
          tool_server_candidates: [Sanctum.Grimoire.tool_server_candidate()],
          warnings: [String.t()],
          defaults: map()
        }

  @doc "The origins a grant admits when its decision names none: `interactive` alone."
  @spec default_origins() :: [Prima.Origin.t(), ...]
  def default_origins, do: @default_origins

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
         manifest = manifest(component, source_ref),
         {:ok, resources, limits} <-
           Sanctum.Consent.BlobBuilder.node_grant(ctx, source_ref, manifest),
         closure = closure(ctx, component),
         {:ok, rows} <- ask_rows(ctx, closure),
         {:ok, candidates} <- candidates(ctx),
         needs = need_rows(manifest),
         {:ok, plan_token} <-
           mint_token(ctx, shape_digest, profile_id, expected_revision) do
      head = head_facts(ctx, profile_id, shape_digest, source_ref)

      {:ok,
       %{
         plan_token: plan_token,
         shape_digest: shape_digest,
         expected_consent_revision: expected_revision,
         profile_id: profile_id,
         source_ref: source_ref,
         needs: needs,
         dependency_needs: dependency_needs(ctx, closure),
         caps: resources,
         limits: limits,
         rows: rows,
         unresolved: unresolved(closure),
         origins: Prima.Origin.to_wire_list(@default_origins),
         head_origins: head.origins,
         shape_diff: head.shape_diff,
         candidates: candidates,
         tool_server_candidates: Sanctum.Grimoire.tool_server_candidates(ctx),
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
    case Prima.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, reason} -> {:error, {:invalid_ref, reason}}
    end
  end

  @doc false
  def fetch_component(ctx, source_ref) do
    with {:ok, parsed} <- Prima.ComponentRef.parse(source_ref),
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

  # A manifest that does not decode declares nothing. The line names the
  # component, never the manifest's bytes.
  defp manifest(row, ref) do
    case Prima.Manifest.decode_strict(Map.get(row, :manifest) || Map.get(row, "manifest")) do
      {:ok, manifest} ->
        manifest

      {:error, :malformed_manifest} ->
        Logger.warning("[Sanctum.Consent.Plan] manifest malformed: #{ref}")
        %{}
    end
  end

  # Declared needs become the sheet's rows — the operator sees each
  # need's reason, never the developer's key names. A manifest with no
  # needs block keeps the single ingress slot.
  defp need_rows(manifest) do
    case Prima.Manifest.Needs.from_manifest(manifest) do
      nil ->
        [
          %{
            need: Prima.Authority.Blob.ingress_key(),
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

  # A required need no active candidate can satisfy is satisfiable only
  # after the operator creates a vault entry — say so up front. A key or
  # bundle need is satisfied by a candidate of its kind; an OAuth need only
  # by an OAuth candidate whose scopes contain the need's and either equal
  # them or can be narrowed to them (`narrowable`), since a token for fewer
  # scopes than an entry holds is dispensed only where its provider
  # attenuates a refresh.
  defp need_warnings(needs, candidates) do
    for %{required: true, kind: kind, need: name} = need <- needs,
        kind in ~w(api_key oauth bundle),
        not Enum.any?(candidates, &satisfies?(&1, need)) do
      need_warning(name, need)
    end
  end

  defp satisfies?(%{kind: "oauth"} = candidate, %{kind: "oauth"} = need) do
    held = scope_set(candidate.oauth_scopes)
    wanted = scope_set(Map.get(need, :scopes))

    wanted -- held == [] and (wanted == held or candidate.narrowable)
  end

  defp satisfies?(%{kind: kind}, %{kind: kind}), do: true
  defp satisfies?(_candidate, _need), do: false

  defp scope_set(scopes) when is_list(scopes), do: scopes |> Enum.uniq() |> Enum.sort()
  defp scope_set(_scopes), do: []

  defp need_warning(name, %{kind: "oauth"} = need) do
    "need '#{name}' wants an oauth vault entry granting " <>
      "#{Enum.join(scope_set(Map.get(need, :scopes)), ", ")}, and none can yet — create one first"
  end

  defp need_warning(name, %{kind: kind}),
    do: "need '#{name}' wants a #{kind} vault entry and none exists yet — create one first"

  # The athanor's active entries, each OAuth one saying whether a token for
  # fewer of its scopes can be dispensed (`narrowable`): only where its
  # provider attenuates a refresh. Other kinds carry no such key.
  defp candidates(ctx) do
    with {:ok, entries} <- Sanctum.Vault.list(ctx) do
      {:ok,
       for %{status: "active"} = entry <- entries do
         if entry.kind == "oauth",
           do: Map.put(entry, :narrowable, OAuth.attenuates_scope?(entry.provider_hint)),
           else: entry
       end}
    end
  end

  # What the profile's head holds: the origins it admits, and what changed
  # against it when the shape moved. A head that cannot be read answers as
  # none, which the commit's own revision check still fences.
  defp head_facts(_ctx, nil, _shape_digest, _source_ref), do: %{origins: nil, shape_diff: []}

  defp head_facts(ctx, profile_id, shape_digest, source_ref) do
    case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile_id) do
      {:ok, head} ->
        %{
          origins: Prima.Origin.to_wire_list(head.admitted_origins),
          shape_diff:
            if(head.shape_digest == shape_digest,
              do: [],
              else: Sanctum.Consent.ShapeDiff.compute(ctx, source_ref, head.resolved_policy)
            )
        }

      {:error, _no_head} ->
        %{origins: nil, shape_diff: []}
    end
  end

  # The activation closure's graph, or what keeps it from resolving: the
  # reason's tag and the ref the resolution names as missing, if any.
  defp closure(ctx, component) do
    case Components.resolve(ctx, component) do
      {:ok, %{graph: graph}} -> {:ok, graph}
      {:error, reason} -> {:unresolved, unresolved_reason(reason)}
    end
  end

  defp unresolved_reason({:incomplete, {tag, missing}}) when is_atom(tag) and is_binary(missing),
    do: %{reason: Atom.to_string(tag), missing: missing}

  defp unresolved_reason({:incomplete, tag}) when is_atom(tag),
    do: %{reason: Atom.to_string(tag), missing: nil}

  defp unresolved_reason({tag, _detail}) when is_atom(tag),
    do: %{reason: Atom.to_string(tag), missing: nil}

  defp unresolved_reason(tag) when is_atom(tag), do: %{reason: Atom.to_string(tag), missing: nil}
  defp unresolved_reason(_reason), do: %{reason: "unresolvable", missing: nil}

  defp unresolved({:ok, _graph}), do: nil
  defp unresolved({:unresolved, unresolved}), do: unresolved

  # The ask of every node of the closure, each row held to its shape, each
  # once. A closure that cannot be resolved has no ask to show: the
  # source's own rows would read as the whole of it.
  defp ask_rows(_ctx, {:unresolved, _unresolved}), do: {:ok, []}

  defp ask_rows(ctx, {:ok, graph}) do
    with {:ok, rows} <- BlobBuilder.ask_rows(ctx, Map.keys(graph)) do
      rows = BlobBuilder.order_rows(rows)

      case BlobBuilder.check_rows(rows) do
        {:ok, _checked} -> {:ok, rows}
        {:error, reason} -> {:error, {:preview_unrepresentable, reason}}
      end
    end
  end

  # The closure's dependency edges whose target declares a credential
  # need, each with the owner profiles of that target that bind one —
  # what a selection may name. A closure that cannot be resolved offers
  # none; the commit refuses a selection it cannot place anyway.
  defp dependency_needs(_ctx, {:unresolved, _unresolved}), do: []

  defp dependency_needs(ctx, {:ok, graph}) do
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
  end

  defp node_manifest(ctx, node_key) do
    with {:ok, ref} <- Prima.ComponentRef.parse(node_key),
         {:ok, row} <- Components.get_latest(ctx, ref.name, ref.namespace, ref.type) do
      {:ok, manifest(row, node_key)}
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
            {:ok, blob} <- [Prima.Authority.Blob.parse(head.resolved_policy)],
            {:ok, ingress} <- [Prima.Authority.Blob.ingress(blob, dep)],
            Prima.Authority.Blob.bound_vault?(ingress.vault),
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
      |> Prima.MapUtil.put_present(:profile_id, profile_id)

    Proof.mint(bindings, ttl_ms: @plan_ttl_ms)
  end
end
