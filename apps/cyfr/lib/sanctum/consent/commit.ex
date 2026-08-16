# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Commit do
  @moduledoc """
  Preview and commit: the two verbs that turn decisions into a revision.

  Preview recomputes everything live, renders what the operator is about
  to approve, and mints the short-lived commit proof — it never consumes
  the plan token, so an operator can change decisions and preview again.

  Commit re-verifies the world from scratch in a fixed order: authorize
  the caller, recompute the live shape, consume the plan token against it,
  recompute the commit digest from fresh vault rows, consume the proof
  against that, then insert with the head CAS and an in-transaction
  binding re-check. Every gap an adversary or a race could use — a new
  release between plan and commit, a `vault.rebind` between preview and
  commit, a concurrent revision — lands on one of those checks and
  surfaces as `consent_conflict`, never as a grant against stale facts.
  """

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Consent.Source
  alias Sanctum.Context
  alias Sanctum.JCS
  alias Sanctum.VaultReader

  @type decisions :: %{
          optional(:ref) => String.t(),
          optional(:label) => String.t(),
          optional(:kind) => :owner | :public,
          optional(:scope) => :versionless | :pinned,
          optional(:invoke_mode) => :open_inert | :edge_only,
          optional(:bindings) => [map()],
          optional(:override) => boolean(),
          optional(:limits) => map(),
          optional(:publish_from) => String.t(),
          optional(:need_ids) => [String.t()],
          optional(:durable_storage) => boolean()
        }

  # §3.5 ZeroAuthority constants as blob limits — derived from the one
  # literal source (`Sanctum.Authority.zero_limits/0`), never from Policy
  # defaults (which are looser on three of the seven fields). What a public
  # profile's source node runs under until the consent sheet grows a
  # raise-to-ceiling knob. Derivation keeps the blob a user consented to
  # and the ceiling the runtime enforces from ever drifting apart.
  @public_limits Sanctum.Authority.zero_limits()
                 |> Map.from_struct()
                 |> Map.new(fn
                   {:rate_limit, %{requests: r, window: w}} ->
                     {"rate_limit", %{"requests" => r, "window" => w}}

                   {key, value} ->
                     {Atom.to_string(key), value}
                 end)

  @readonly_storage_actions ~w(read list exists)

  # ---------------------------------------------------------------------------
  # Preview
  # ---------------------------------------------------------------------------

  @doc "Recompute live, render the summary, mint the commit proof."
  @spec preview(Context.t(), decisions()) :: {:ok, map()} | {:error, term()}
  def preview(%Context{} = ctx, decisions) do
    with :ok <- Authz.authorize_staging(ctx),
         {:ok, prep} <- prepare(ctx, decisions),
         {:ok, proof} <- mint_commit_proof(ctx, prep) do
      {:ok,
       %{
         commit_digest: prep.commit_digest,
         summary: render_summary(prep),
         proof: proof,
         expected_consent_revision: prep.expected_revision
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Commit
  # ---------------------------------------------------------------------------

  @doc """
  Commit a consent revision. `params`:

    * `:decisions` — the same decisions previewed
    * `:plan_token` — from `Sanctum.Consent.Plan.plan/2`
    * `:proof` — from `preview/2`
    * `:commit_digest` — what the operator saw and approved
    * `:expected_consent_revision` — the revision plan reported

  `opts[:key_capability]` carries a scoped key's consent capability.
  """
  @spec commit(Context.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(%Context{} = ctx, params, opts \\ []) do
    decisions = Map.get(params, :decisions, %{})

    with {:ok, granted_via} <- authorize(ctx, params, decisions, opts),
         {:ok, prep} <- prepare(ctx, decisions),
         :ok <- check_expected_revision(params, prep),
         :ok <- consume_plan_token(ctx, params, prep),
         :ok <- check_presented_digest(params, prep),
         :ok <- consume_commit_proof(ctx, params, prep),
         {:ok, blob_json, refs} <- build_blob(ctx, prep),
         {:ok, activation_json} <- JCS.encode(prep.activation.graph),
         {:ok, consent} <-
           persist(ctx, prep, blob_json, refs, activation_json, granted_via) do
      reactivate_profile(ctx, prep)

      {:ok,
       %{
         profile_id: consent.profile_id,
         revision: consent.revision,
         commit_digest: prep.commit_digest
       }}
    end
  end

  @doc """
  Stage a publish: the §4.2 `profile.publish` front half. Derives the
  forced decisions (`kind: :public`, `edge_only`, pinned) from an owner
  profile, keeping credentials only for `need_ids`, and mints the plan
  token — the caller then walks preview and commit with these decisions
  exactly like any other consent.
  """
  @spec stage_publish(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def stage_publish(%Context{} = ctx, %{profile_id: profile_id} = params) do
    decisions = %{
      publish_from: profile_id,
      need_ids: Map.get(params, :need_ids, []),
      durable_storage: Map.get(params, :durable_storage, false),
      kind: :public,
      scope: :pinned,
      invoke_mode: :edge_only
    }

    with :ok <- Authz.authorize_staging(ctx),
         {:ok, prep} <- prepare(ctx, decisions),
         {:ok, plan_token} <- mint_publish_plan_token(ctx, prep) do
      {:ok,
       %{
         plan_token: plan_token,
         decisions: decisions,
         shape_digest: prep.shape_digest,
         expected_consent_revision: prep.expected_revision,
         source_ref: prep.source_ref,
         summary: render_summary(prep)
       }}
    end
  end

  defp mint_publish_plan_token(ctx, prep) do
    bindings =
      %{
        kind: :plan,
        commit_digest: prep.shape_digest,
        actor: ctx.user_id,
        athanor_id: ctx.athanor_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    Proof.mint(bindings, ttl_ms: 600_000)
  end

  # ---------------------------------------------------------------------------
  # Preparation — one recomputation shared by preview and commit
  # ---------------------------------------------------------------------------

  defp prepare(ctx, %{publish_from: owner_profile_id} = decisions)
       when is_binary(owner_profile_id) do
    with {:ok, owner_profile} <- Arca.ProfileStorage.get(ctx.athanor_id, owner_profile_id),
         :ok <- check_owner_profile(owner_profile),
         {:ok, owner_consent} <- Source.impl().head_consent(ctx, owner_profile_id),
         {:ok, published} <-
           publish_nodes(ctx, owner_consent, decisions, owner_profile.source_ref) do
      prepare_with_blob(
        ctx,
        Map.merge(decisions, %{
          ref: owner_profile.source_ref,
          label: owner_profile.label,
          kind: :public,
          scope: :pinned,
          invoke_mode: :edge_only
        }),
        published
      )
    end
  end

  defp prepare(ctx, decisions), do: prepare_with_blob(ctx, decisions, nil)

  defp check_owner_profile(%{kind: "owner", status: status}) when status != "revoked", do: :ok
  defp check_owner_profile(_), do: {:error, :publish_requires_owner_profile}

  defp prepare_with_blob(ctx, decisions, published) do
    label = Map.get(decisions, :label, "default")
    kind = Map.get(decisions, :kind, :owner)
    scope = Map.get(decisions, :scope, :versionless)
    invoke_mode = Map.get(decisions, :invoke_mode, default_invoke_mode(kind))

    with {:ok, source_ref} <- Plan.name_ref(Map.get(decisions, :ref, "")),
         {:ok, component} <- Plan.fetch_component(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- shape_for_scope(shape_input, scope, component),
         {:ok, profile_id, expected_revision} <-
           Plan.locate_profile(ctx, source_ref, label, kind),
         declared = declared_needs(component),
         {:ok, bindings, entries} <- prepared_bindings(ctx, decisions, published, declared),
         {:ok, tool_servers} <- resolve_tool_servers(ctx, decisions),
         {:ok, commit_input} <-
           commit_input(shape_digest, kind, invoke_mode, bindings, tool_servers, decisions),
         {:ok, commit_digest} <- CommitDigest.compute(commit_input) do
      {:ok,
       %{
         source_ref: source_ref,
         component: component,
         activation: activation,
         scope: scope,
         kind: kind,
         label: label,
         invoke_mode: invoke_mode,
         shape_digest: shape_digest,
         commit_digest: commit_digest,
         commit_input: commit_input,
         bindings: bindings,
         entries: entries,
         tool_servers: tool_servers,
         profile_id: profile_id,
         expected_revision: expected_revision,
         override: Map.get(decisions, :override, false),
         publish_nodes: published && published.nodes
       }}
    end
  end

  # A tool-server decision names the server; the digest is ALWAYS resolved
  # live at prepare — like binding digests, a caller-supplied one could pin
  # a consent to a configuration the server no longer has. The D8 baseline
  # rides along when the catalogue was reachable.
  defp resolve_tool_servers(ctx, decisions) do
    decisions
    |> Map.get(:tool_servers, [])
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      name = Map.get(raw, :server_name)

      case Emissary.MCP.ExternalProvider.consent_candidate(ctx, name || "") do
        {:ok, %{server_digest: digest} = candidate} when is_binary(digest) ->
          grant = %{
            server_name: candidate.name,
            server_digest: digest,
            tool_patterns: Map.get(raw, :tool_patterns, candidate.tool_patterns),
            descriptions_digest: candidate.descriptions_digest
          }

          {:cont, {:ok, [grant | acc]}}

        {:ok, _undigestable} ->
          {:halt, {:error, {:tool_server_unavailable, name}}}

        {:error, _} ->
          {:halt, {:error, {:tool_server_not_found, name}}}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      error -> error
    end
  end

  defp prepared_bindings(ctx, decisions, nil, declared),
    do: resolve_bindings(ctx, decisions, declared)

  defp prepared_bindings(_ctx, _decisions, published, _declared),
    do: {:ok, published.bindings, published.entries}

  defp declared_needs(component) do
    (Map.get(component, :manifest) || Map.get(component, "manifest"))
    |> Compendium.Manifest.decode()
    |> Compendium.Manifest.Needs.from_manifest()
  end

  # Transform the owner's head blob into the public one: the source node
  # drops to the §3.5 constants, storage attenuates to read-only unless
  # durable writes were explicitly enabled, and vault resources survive
  # only on the edges named by need_ids — with their binding digests
  # re-verified against the live rows, because a consent must never be
  # minted around a digest the entry no longer has.
  defp publish_nodes(ctx, owner_consent, decisions, source_ref) do
    need_ids = Map.get(decisions, :need_ids, [])
    durable? = Map.get(decisions, :durable_storage, false)

    with {:ok, %{"canonical" => "jcs-1", "nodes" => nodes}} <-
           Jason.decode(owner_consent.resolved_policy) do
      transformed =
        Map.new(nodes, fn {node_key, node} ->
          edges =
            Map.new(node["edges"] || %{}, fn {edge_key, edge} ->
              {edge_key, publish_edge(edge, edge_key, need_ids, durable?)}
            end)

          limits =
            if node_key == source_ref, do: @public_limits, else: node["limits"]

          {node_key, %{"limits" => limits, "edges" => edges}}
        end)

      with {:ok, bindings, entries} <- collect_publish_bindings(ctx, transformed) do
        {:ok, %{nodes: transformed, bindings: bindings, entries: entries}}
      end
    else
      {:ok, _other} -> {:error, :unpublishable_owner_blob}
      {:error, reason} -> {:error, {:unpublishable_owner_blob, reason}}
    end
  end

  defp publish_edge(edge, edge_key, need_ids, durable?) do
    edge =
      case Map.get(edge, "storage") do
        %{"actions" => actions} = storage when not durable? ->
          Map.put(edge, "storage", %{
            "paths" => storage["paths"] || [],
            "actions" => Enum.filter(actions, &(&1 in @readonly_storage_actions))
          })

        _ ->
          edge
      end

    # Public profiles get no external MCP reach: an anonymous caller
    # driving upstream tools through the operator's server credentials is
    # exactly the §1 shape. Re-granting is a deliberate future decision.
    edge = Map.delete(edge, "tool_servers")

    if edge_key in need_ids do
      edge
    else
      Map.delete(edge, "vault")
    end
  end

  defp collect_publish_bindings(ctx, nodes) do
    vaults =
      for {_node_key, node} <- nodes,
          {edge_key, edge} <- node["edges"] || %{},
          vault = edge["vault"],
          vault != nil,
          uniq: true,
          do: {edge_key, vault}

    Enum.reduce_while(vaults, {:ok, [], %{}}, fn {edge_key, vault}, {:ok, acc, entries} ->
      with {:ok, entry} <- fetch_active_entry(ctx, vault["entry_id"]),
           {:ok, live_digest} <- VaultReader.binding_digest(entry),
           true <-
             Plug.Crypto.secure_compare(live_digest, vault["binding_digest"] || "") ||
               {:error, {:binding_went_stale, entry.id}} do
        binding = %{
          need: edge_key,
          entry_id: entry.id,
          binding_digest: live_digest,
          fields: get_in(vault, ["projection", "fields"]) || [],
          scopes: get_in(vault, ["projection", "scopes"]) || []
        }

        {:cont, {:ok, [binding | acc], Map.put(entries, entry.id, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings, entries} -> {:ok, Enum.reverse(bindings), entries}
      error -> error
    end
  end

  defp default_invoke_mode(:public), do: :edge_only
  defp default_invoke_mode(_), do: :open_inert

  defp resolve_activation(ctx, component) do
    case Compendium.Activation.resolve_verified(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:error, {:activation_unresolvable, reason}}
    end
  end

  # Pinned means the activation digest (D7); the version string rides along
  # as the display identity the shape shows.
  defp shape_for_scope(shape_input, :versionless, _component) do
    ShapeDigest.compute(shape_input)
  end

  # Pinned means the activation identity (D7), so the release digest IS
  # the identity the shape carries; a release that never got one cannot
  # be pinned to.
  defp shape_for_scope(shape_input, :pinned, component) do
    case component.release_digest do
      digest when is_binary(digest) and digest != "" ->
        shape_input
        |> Map.put(:scope, :pinned)
        |> Map.put(:release_identity, digest)
        |> ShapeDigest.compute()

      _ ->
        {:error, {:release_digest_missing, component.version}}
    end
  end

  # Binding digests are ALWAYS derived from the live row here — a caller-
  # supplied digest could pin a consent to a binding the entry no longer
  # has. With no needs block the single slot is spelled "@ingress"; a
  # manifest that declares needs retires the implicit slot entirely
  # (§2.7's omission rule mirrored: every binding must name a declared
  # need), and an unknown need fails, never binds somewhere surprising.
  defp resolve_bindings(ctx, decisions, declared) do
    decisions
    |> Map.get(:bindings, [])
    |> Enum.reduce_while({:ok, [], %{}}, fn raw, {:ok, acc, entries} ->
      need = Map.get(raw, :need, "@ingress")

      with {:ok, declared_need} <- check_known_need(need, declared),
           {:ok, entry} <- fetch_active_entry(ctx, Map.get(raw, :entry_id)),
           {:ok, digest} <- VaultReader.binding_digest(entry) do
        binding = %{
          need: need,
          entry_id: entry.id,
          binding_digest: digest,
          fields: Map.get(raw, :fields, default_fields(declared_need)),
          scopes: Map.get(raw, :scopes, default_scopes(declared_need))
        }

        {:cont, {:ok, [binding | acc], Map.put(entries, entry.id, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, [_, _ | _], _entries} when declared != nil ->
        # One credential per execution closure (§3.11): a direct-run source
        # holds exactly one, so a second binding has nowhere to ride.
        {:error, :multiple_source_bindings_unrepresentable}

      {:ok, bindings, entries} ->
        {:ok, Enum.reverse(bindings), entries}

      error ->
        error
    end
  end

  defp check_known_need("@ingress", nil), do: {:ok, nil}
  defp check_known_need(need, nil), do: {:error, {:unknown_need, need}}

  defp check_known_need(need, declared) when is_list(declared) do
    case Enum.find(declared, &(&1.name == need)) do
      nil ->
        {:error, {:unknown_need, need}}

      %{kind: kind} = declared_need when kind in ~w(api_key oauth bundle) ->
        {:ok, declared_need}

      %{kind: kind} ->
        # Component-typed needs bind at the child edge, which no fixture
        # exercises yet; refusing beats binding somewhere surprising, and
        # the unbound edge fails safe to ZeroAuthority at dispatch.
        {:error, {:component_typed_need_binding_unsupported, need, kind}}
    end
  end

  defp default_fields(nil), do: []
  defp default_fields(%{fields: fields}), do: fields

  defp default_scopes(nil), do: []
  defp default_scopes(%{scopes: scopes}), do: scopes

  defp fetch_active_entry(_ctx, nil), do: {:error, {:invalid_binding, :entry_id_required}}

  defp fetch_active_entry(ctx, entry_id) do
    case Arca.VaultStorage.get(ctx.athanor_id, entry_id) do
      {:ok, %{status: "active"} = entry} -> {:ok, entry}
      {:ok, %{status: status}} -> {:error, {:entry_unavailable, entry_id, status}}
      {:error, reason} -> {:error, {:entry_unavailable, entry_id, reason}}
    end
  end

  defp commit_input(shape_digest, kind, invoke_mode, bindings, tool_servers, decisions) do
    input = %{
      shape_digest: shape_digest,
      kind: kind,
      invoke_mode: invoke_mode,
      bindings: bindings,
      tool_servers:
        Enum.map(tool_servers, &Map.take(&1, [:server_name, :server_digest, :tool_patterns])),
      override: Map.get(decisions, :override, false)
    }

    input =
      case Map.get(decisions, :limits) do
        nil -> input
        limits -> Map.put(input, :limits, limits)
      end

    {:ok, input}
  end

  # ---------------------------------------------------------------------------
  # The commit-order checks
  # ---------------------------------------------------------------------------

  defp authorize(ctx, params, decisions, opts) do
    Authz.authorize(ctx, %Authz.Request{
      commit_digest: Map.get(params, :commit_digest),
      override?: Map.get(decisions, :override, false),
      key_capability: Keyword.get(opts, :key_capability)
    })
  end

  defp check_expected_revision(params, prep) do
    expected = Map.get(params, :expected_consent_revision)

    if expected == prep.expected_revision do
      :ok
    else
      conflict(:stale_plan, expected, prep.expected_revision)
    end
  end

  defp consume_plan_token(ctx, params, prep) do
    bindings =
      %{
        kind: :plan,
        commit_digest: prep.shape_digest,
        actor: ctx.user_id,
        athanor_id: ctx.athanor_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    case Proof.consume(Map.get(params, :plan_token, ""), bindings) do
      :ok ->
        :ok

      {:error, {:binding_mismatch, :commit_digest}} ->
        # The live shape moved since the plan was staged.
        conflict(:digest_changed, prep.expected_revision, prep.expected_revision)

      {:error, {:binding_mismatch, :expected_revision}} ->
        conflict(:stale_plan, Map.get(params, :expected_consent_revision), prep.expected_revision)

      {:error, reason} ->
        {:error, {:plan_token, reason}}
    end
  end

  defp check_presented_digest(params, prep) do
    presented = Map.get(params, :commit_digest, "")

    if is_binary(presented) and Plug.Crypto.secure_compare(presented, prep.commit_digest) do
      :ok
    else
      # A rebind or policy move between preview and commit lands here: the
      # recomputed digest no longer matches what the operator approved.
      conflict(:digest_changed, prep.expected_revision, prep.expected_revision)
    end
  end

  defp mint_commit_proof(ctx, prep) do
    bindings =
      %{
        kind: :consent_commit,
        commit_digest: prep.commit_digest,
        actor: ctx.user_id,
        athanor_id: ctx.athanor_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    Proof.mint(bindings)
  end

  defp consume_commit_proof(ctx, params, prep) do
    bindings =
      %{
        kind: :consent_commit,
        commit_digest: prep.commit_digest,
        actor: ctx.user_id,
        athanor_id: ctx.athanor_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    case Proof.consume(Map.get(params, :proof, ""), bindings) do
      :ok ->
        :ok

      {:error, {:binding_mismatch, _field}} ->
        conflict(:digest_changed, prep.expected_revision, prep.expected_revision)

      {:error, reason} ->
        {:error, {:proof, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob + persistence
  # ---------------------------------------------------------------------------

  defp build_blob(_ctx, %{publish_nodes: nodes} = prep) when is_map(nodes) do
    refs =
      prep.bindings
      |> Enum.map(&%{vault_entry_id: &1.entry_id, binding_digest: &1.binding_digest})
      |> Enum.uniq()

    with {:ok, blob_json} <- JCS.encode(%{"canonical" => "jcs-1", "nodes" => nodes}) do
      {:ok, blob_json, refs}
    end
  end

  defp build_blob(ctx, prep) do
    # The single credential binding rides the ingress edge whatever its
    # need name — "@ingress" for no-needs manifests, the declared need
    # for manifests with one. resolve_bindings already refused a second.
    source_binding = List.first(prep.bindings)

    vault_fn = fn node_key, _row, _manifest ->
      if node_key == prep.source_ref and source_binding != nil do
        vault_resource(source_binding)
      end
    end

    extras =
      case prep.tool_servers do
        [] -> %{}
        grants -> %{"tool_servers" => Enum.map(grants, &tool_server_resource/1)}
      end

    with {:ok, nodes} <-
           BlobBuilder.build(ctx, prep.activation.graph, prep.source_ref, vault_fn,
             ingress_extras: extras
           ),
         {:ok, blob_json} <- BlobBuilder.encode(nodes) do
      {:ok, blob_json, BlobBuilder.vault_refs(nodes)}
    end
  end

  defp tool_server_resource(grant) do
    base = %{
      "server_digest" => grant.server_digest,
      "server_name" => grant.server_name,
      "tool_patterns" => Enum.sort(grant.tool_patterns)
    }

    case grant.descriptions_digest do
      nil -> base
      digest -> Map.put(base, "descriptions_digest", digest)
    end
  end

  defp vault_resource(binding) do
    projection =
      %{}
      |> put_projection("fields", binding.fields)
      |> put_projection("scopes", binding.scopes)

    base = %{"entry_id" => binding.entry_id, "binding_digest" => binding.binding_digest}

    if projection == %{}, do: base, else: Map.put(base, "projection", projection)
  end

  defp put_projection(map, _key, []), do: map
  defp put_projection(map, key, values), do: Map.put(map, key, Enum.sort(values))

  defp persist(ctx, prep, blob_json, refs, activation_json, granted_via) do
    profile_id = prep.profile_id || Emissary.UUID7.generate_id("prof")

    attrs = %{
      athanor_id: ctx.athanor_id,
      profile_id: profile_id,
      revision: prep.expected_revision + 1,
      scope: Atom.to_string(prep.scope),
      pinned_version: pinned_version(prep),
      invoke_mode: Atom.to_string(prep.invoke_mode),
      shape_digest: prep.shape_digest,
      commit_digest: prep.commit_digest,
      resolved_policy: blob_json,
      activation: activation_json,
      granted_by: ctx.user_id,
      granted_via: Atom.to_string(granted_via)
    }

    verify = fn -> verify_binding_liveness(ctx, prep) end

    result =
      if prep.profile_id do
        with {:ok, head_id} <- current_head_id(ctx, prep.profile_id) do
          Arca.ConsentStorage.insert_revision(attrs, refs, head_id, verify: verify)
        end
      else
        Arca.ConsentStorage.mint_profile_with_revision(
          %{
            id: profile_id,
            athanor_id: ctx.athanor_id,
            source_ref: prep.source_ref,
            kind: Atom.to_string(prep.kind),
            label: prep.label,
            status: "active"
          },
          attrs,
          refs,
          verify: verify
        )
      end

    case result do
      {:ok, consent} ->
        {:ok, consent}

      {:error, :head_moved} ->
        actual =
          case Plan.locate_profile(ctx, prep.source_ref, prep.label, prep.kind) do
            {:ok, _id, revision} -> revision
            _ -> prep.expected_revision
          end

        conflict(:race, prep.expected_revision, actual)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pinned_version(%{scope: :pinned, component: component}), do: component.version
  defp pinned_version(_prep), do: ""

  defp current_head_id(ctx, profile_id) do
    case Arca.ConsentStorage.get_head(ctx.athanor_id, profile_id) do
      {:ok, head, _refs} -> {:ok, head.id}
      {:error, :no_head} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs inside the insert transaction: a vault.rebind that landed after
  # prepare must roll the revision back, not ship a consent that is dead
  # on arrival.
  defp verify_binding_liveness(ctx, prep) do
    Enum.reduce_while(prep.bindings, :ok, fn binding, :ok ->
      with {:ok, entry} <- fetch_active_entry(ctx, binding.entry_id),
           {:ok, digest} <- VaultReader.binding_digest(entry),
           true <- Plug.Crypto.secure_compare(digest, binding.binding_digest) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:binding_went_stale, binding.entry_id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A profile blocked at needs_consent is unblocked by exactly this act —
  # a fresh revision IS the re-consent.
  defp reactivate_profile(ctx, %{profile_id: profile_id}) when is_binary(profile_id) do
    case Arca.ProfileStorage.get(ctx.athanor_id, profile_id) do
      {:ok, %{status: "needs_consent"}} ->
        Arca.ProfileStorage.set_status(ctx.athanor_id, profile_id, "active")

      _ ->
        :ok
    end
  end

  defp reactivate_profile(_ctx, _prep), do: :ok

  # ---------------------------------------------------------------------------
  # Rendering + helpers
  # ---------------------------------------------------------------------------

  defp render_summary(prep) do
    header =
      "Grant #{prep.source_ref} — #{prep.kind}, #{prep.scope}, revision #{prep.expected_revision + 1}"

    bindings =
      Enum.map(prep.bindings, fn binding ->
        entry = Map.fetch!(prep.entries, binding.entry_id)

        projected =
          if binding.fields == [], do: "all fields", else: Enum.join(binding.fields, ", ")

        "Uses #{entry.name} (#{projected})"
      end)

    [header | bindings]
  end

  defp conflict(cause, expected, actual) do
    {:error,
     {:consent_conflict, %{expected_revision: expected, actual_revision: actual, cause: cause}}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
