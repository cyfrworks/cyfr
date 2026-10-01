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

  ## What a decision may name beyond bindings

    * `:origins` — the `Prima.Origin` values the revision admits, a
      non-empty list; `[:interactive]` when absent. The revision is written
      with them as its `admitted_origins`, and the commit digest binds them.
    * `:subset` — a narrowing: per consent-graph node, the part of the ask
      granted for each kind its enforcement point can narrow, in the wire's
      string-keyed form (`Sanctum.Consent.Normalize.subset/3`). Each value
      must lie inside the ask, and a limit inside the ceiling too
      (`Sanctum.Consent.BlobBuilder.narrow/5`); a superset is refused, since
      granting more than the ask is the `:override` decision.

  ## What preview answers

  A `Prima.ConsentPreview` (`t:Sanctum.Consent.preview/0`): the typed
  rows of what the revision would grant, the origins it would admit and the
  commit digest binding both, with the proof and the expected revision
  beside them, and the rendered `summary` lines the rows replace.
  """

  require Logger

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.Normalize
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Prima.Authority.RootSelect
  alias Sanctum.Consent.Components
  alias Prima.JCS
  alias Sanctum.VaultReader

  @type decisions :: %{
          optional(:ref) => String.t(),
          optional(:label) => String.t(),
          optional(:kind) => :owner | :public,
          optional(:scope) => :versionless | :pinned,
          optional(:invoke_mode) => :open_inert | :edge_only,
          optional(:bindings) => [map()],
          optional(:selections) => [map()],
          optional(:override) => boolean(),
          optional(:publish_from) => String.t(),
          optional(:need_ids) => [String.t()],
          optional(:durable_storage) => boolean(),
          optional(:origins) => [Prima.Origin.t(), ...],
          optional(:subset) => CommitDigest.subset()
        }

  # Derive public-source limits from Prima.Authority.zero_limits/0.
  # Policy defaults may be less restrictive.
  @public_limits Prima.Authority.zero_limits()
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

  @doc """
  Recompute live, answer the structured preview with the summary, mint the
  commit proof. Two previews of the same decisions over the same world
  answer the same rows and the same digest.
  """
  @spec preview(Context.t(), decisions()) ::
          {:ok, Sanctum.Consent.preview()} | {:error, term()}
  def preview(%Context{} = ctx, decisions) do
    with :ok <- Authz.authorize_staging(ctx),
         {:ok, prep} <- prepare(ctx, decisions),
         {:ok, rows} <- preview_rows(ctx, prep),
         {:ok, preview} <- consent_preview(rows, prep),
         {:ok, proof} <- mint_commit_proof(ctx, prep) do
      document = Prima.ConsentPreview.encode(preview)

      {:ok,
       %{
         v: document["v"],
         rows: document["rows"],
         origins: document["origins"],
         commit_digest: document["commit_digest"],
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
         {:ok, activation_json} <- JCS.encode(prep.activation.graph),
         {:ok, consent} <-
           persist(ctx, prep, prep.blob_json, prep.blob_refs, activation_json, granted_via) do
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
  Grant a credential to a profile whose shape has not moved: the simple
  verb for binding a vault entry to a need on an existing owner consent,
  without a fresh plan, preview and proof.

  It reuses the commit's binding resolution, its compare-and-set on the
  consent revision and its digests, and re-issues the head's scope, invoke
  mode and admitted origins, and the narrowing the head holds: every field
  whose grant differs from the ask is named again, so binding a key never
  widens a narrowed consent. It refuses when the revision is stale, or
  moves while the head is re-issued (a consent conflict), when the
  component's shape moved since the head (`:shape_moved` — plan, preview
  and commit again), when the profile is not an active owner profile, or
  when the head grants external tool servers, which a grant does not carry
  (`:grant_requires_full_commit`).

  Params: `:profile_id`, `:bindings` (the commit's binding shape) and
  `:expected_consent_revision`.
  """
  @spec grant(Context.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant(%Context{} = ctx, %{profile_id: profile_id} = params, _opts \\ []) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, profile} <- Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id),
         :ok <- check_grantable_profile(profile),
         {:ok, head} <- Arca.ConsentStorage.head_consent(Context.actor(ctx), profile_id),
         :ok <- check_no_tool_servers(head, profile.source_ref),
         decisions = grant_decisions(profile, head, Map.get(params, :bindings, [])),
         {:ok, asked} <- prepare(ctx, decisions),
         :ok <- check_expected_revision(params, asked),
         :ok <- check_head_read(head, asked),
         :ok <- check_shape_unmoved(asked, head),
         {:ok, prep} <- keep_narrowing(ctx, decisions, asked, {profile_id, head}),
         :ok <- check_expected_revision(params, prep),
         {:ok, activation_json} <- JCS.encode(prep.activation.graph),
         {:ok, consent} <-
           persist(ctx, prep, prep.blob_json, prep.blob_refs, activation_json, :interactive) do
      reactivate_profile(ctx, prep)

      {:ok,
       %{
         profile_id: consent.profile_id,
         revision: consent.revision,
         commit_digest: prep.commit_digest
       }}
    end
  end

  # The head whose decisions a grant re-issues must be the revision the
  # caller presented and the one its walk read: a revision landing between
  # the head's read and a walk, or between the two walks a narrowed head
  # takes, would otherwise be written over with the older head's origins
  # and narrowing, a write nobody decided that can widen the grant.
  defp check_head_read(%{revision: revision}, %{expected_revision: revision}), do: :ok

  defp check_head_read(%{revision: head}, %{expected_revision: walked}),
    do: conflict(:stale_plan, head, walked)

  defp check_grantable_profile(%{kind: "owner", status: status}) when status != "revoked",
    do: :ok

  defp check_grantable_profile(%{kind: "owner"}), do: {:error, :profile_revoked}
  defp check_grantable_profile(_profile), do: {:error, :grant_requires_owner_profile}

  # The head's decisions, with the new bindings in place of its own: an
  # owner profile, the label it carries, and the scope, invoke mode and
  # origins the head was committed under. A head written without origins
  # admits interactive alone.
  defp grant_decisions(profile, head, bindings) do
    %{
      ref: profile.source_ref,
      label: profile.label,
      kind: :owner,
      scope: head.scope,
      invoke_mode: head.invoke_mode,
      origins: Map.get(head, :admitted_origins) || Plan.default_origins(),
      bindings: bindings,
      selections: head_selections(head),
      tool_servers: []
    }
  end

  # The head's narrowing, named again: every field of a narrowable kind
  # whose grant on the head differs from the ask as it stands. A head no
  # narrowing touched grants the ask, and is re-issued as `asked` was.
  defp keep_narrowing(ctx, decisions, asked, {profile_id, head}) do
    with {:ok, head_nodes} <- blob_nodes(head.resolved_policy),
         {:ok, asked_nodes} <- blob_nodes(asked.blob_json) do
      case head_narrowing(asked.source_ref, head_nodes, asked_nodes) do
        subset when subset == %{} -> {:ok, asked}
        subset -> prepare(ctx, Map.put(decisions, :subset, subset))
      end
    else
      # Unreadable, the head's narrowing is unknown: re-issuing the ask
      # could widen it, so nothing is granted.
      :error -> {:error, {:corrupt, {:profile, profile_id}}}
    end
  end

  defp blob_nodes(json) do
    case Jason.decode(json) do
      {:ok, %{"nodes" => nodes}} when is_map(nodes) -> {:ok, nodes}
      _ -> :error
    end
  end

  defp head_narrowing(source_ref, head_nodes, asked_nodes) do
    for {node_key, head_node} <- head_nodes,
        Map.has_key?(asked_nodes, node_key),
        record =
          node_narrowing(
            BlobBuilder.node_resources(head_nodes, source_ref, node_key),
            BlobBuilder.node_resources(asked_nodes, source_ref, node_key),
            head_node["limits"],
            asked_nodes[node_key]["limits"]
          ),
        record != %{},
        into: %{},
        do: {node_key, record}
  end

  defp node_narrowing(head, asked, head_limits, asked_limits) do
    %{}
    |> put_differing(
      "egress",
      fields_differing(head, asked, "egress", ~w(domains methods schemes private_ips))
    )
    |> put_differing("storage", fields_differing(head, asked, "storage", ~w(paths actions)))
    |> put_differing("tools", tools_differing(head, asked))
    |> put_differing("limits", limits_differing(head_limits || %{}, asked_limits || %{}))
  end

  defp fields_differing(head, asked, kind, fields) do
    head_kind = (head && head[kind]) || %{}
    asked_kind = (asked && asked[kind]) || %{}

    for field <- fields,
        Map.get(head_kind, field, []) != Map.get(asked_kind, field, []),
        into: %{},
        do: {field, Map.get(head_kind, field, [])}
  end

  defp tools_differing(head, asked) do
    head_tools = (head && head["tools"]) || []
    if head_tools != ((asked && asked["tools"]) || []), do: head_tools
  end

  defp limits_differing(head_limits, asked_limits) do
    for {field, value} <- head_limits, value != asked_limits[field], into: %{} do
      case {value, asked_limits[field]} do
        {%{} = rate, %{} = asked_rate} ->
          {field, for({k, v} <- rate, v != asked_rate[k], into: %{}, do: {k, v})}

        _differs ->
          {field, value}
      end
    end
  end

  defp put_differing(record, _kind, nil), do: record
  defp put_differing(record, _kind, empty) when empty == %{}, do: record
  defp put_differing(record, kind, value), do: Map.put(record, kind, value)

  # The selections the head carries, re-decided as they stand: the same
  # lender, the same fields, the digest pinned again from the live entry.
  defp head_selections(head) do
    with {:ok, %{"nodes" => nodes}} <- Jason.decode(head.resolved_policy) do
      for {from, node} <- nodes,
          {edge_key, %{"vault" => %{"via" => %{"label" => label}} = vault}} <-
            node["edges"] || %{},
          {:ok, dep} <- [Prima.Authority.Blob.edge_target(edge_key)] do
        # A selection that named no fields lends the lender's again.
        Prima.MapUtil.put_present(
          %{from: from, dep: dep, label: label},
          :fields,
          get_in(vault, ["projection", "fields"])
        )
      end
    else
      _ -> []
    end
  end

  # A tool-server grant lives on the head's ingress edge and is not a
  # binding; re-issuing the head without it would silently drop it.
  defp check_no_tool_servers(head, source_ref) do
    with {:ok, %{"nodes" => nodes}} <- Jason.decode(head.resolved_policy),
         %{"edges" => edges} <- Map.get(nodes, source_ref, %{}),
         %{} = ingress <- Map.get(edges, Prima.Authority.Blob.ingress_key(), %{}) do
      case Map.get(ingress, "tool_servers") do
        [_ | _] -> {:error, :grant_requires_full_commit}
        _ -> :ok
      end
    else
      _ -> :ok
    end
  end

  defp check_shape_unmoved(prep, head) do
    if prep.shape_digest == head.shape_digest, do: :ok, else: {:error, :shape_moved}
  end

  @doc """
  Stages `profile.publish` from an owner profile with public, edge-only,
  pinned decisions. Retains credentials only for `need_ids` and returns a
  plan token for preview and commit, with what the public profile would
  grant as preview rows and the origins it would admit.
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
         {:ok, rows} <- preview_rows(ctx, prep),
         {:ok, plan_token} <- mint_publish_plan_token(ctx, prep) do
      {:ok,
       %{
         plan_token: plan_token,
         decisions: decisions,
         shape_digest: prep.shape_digest,
         expected_consent_revision: prep.expected_revision,
         source_ref: prep.source_ref,
         rows: rows,
         origins: Prima.Origin.to_wire_list(prep.origins),
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
      |> Prima.MapUtil.put_present(:profile_id, prep.profile_id)

    Proof.mint(bindings, ttl_ms: 600_000)
  end

  # ---------------------------------------------------------------------------
  # Preparation — one recomputation shared by preview and commit
  # ---------------------------------------------------------------------------

  defp prepare(ctx, %{publish_from: owner_profile_id} = decisions)
       when is_binary(owner_profile_id) do
    with {:ok, owner_profile} <-
           Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), owner_profile_id),
         :ok <- check_owner_profile(owner_profile),
         {:ok, owner_consent} <-
           Arca.ConsentStorage.head_consent(Context.actor(ctx), owner_profile_id),
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

    with :ok <- RootSelect.check_label(label),
         {:ok, origins} <- decided_origins(decisions),
         {:ok, subset} <- decided_subset(decisions),
         {:ok, source_ref} <- Plan.name_ref(Map.get(decisions, :ref, "")),
         {:ok, component} <- Plan.fetch_component(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- shape_for_scope(shape_input, scope, component),
         {:ok, profile_id, expected_revision} <-
           Plan.locate_profile(ctx, source_ref, label, kind),
         declared = declared_needs(component, source_ref),
         {:ok, bindings, entries} <- prepared_bindings(ctx, decisions, published, declared),
         {:ok, selections} <-
           prepared_selections(ctx, decisions, published, activation, source_ref),
         {:ok, tool_servers} <- resolve_tool_servers(ctx, decisions),
         # Build the blob before digest validation; preview renders these same bytes.
         blob_inputs = %{
           source_ref: source_ref,
           activation: activation,
           bindings: bindings,
           selections: selections,
           tool_servers: tool_servers,
           subset: subset,
           publish_nodes: published && published.nodes
         },
         {:ok, blob_json, blob_refs, narrowed} <- build_blob(ctx, blob_inputs),
         blob_digest = JCS.hash_binary(blob_json),
         {:ok, commit_input} <-
           commit_input(
             shape_digest,
             blob_digest,
             {label, kind, invoke_mode},
             {origins, subset},
             bindings,
             selections,
             tool_servers,
             decisions
           ),
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
         blob_json: blob_json,
         blob_digest: blob_digest,
         blob_refs: blob_refs,
         bindings: bindings,
         selections: selections,
         entries: entries,
         tool_servers: tool_servers,
         origins: origins,
         subset: subset,
         narrowed: narrowed,
         profile_id: profile_id,
         expected_revision: expected_revision,
         override: Map.get(decisions, :override, false),
         publish_nodes: published && published.nodes
       }}
    end
  end

  # The origins a decision names, in the enum's order; interactive alone
  # when it names none.
  defp decided_origins(decisions) do
    case Map.get(decisions, :origins) do
      nil ->
        {:ok, Plan.default_origins()}

      origins ->
        case Normalize.origins(%{origins: origins}, :origins, :invalid_decision) do
          {:ok, spellings} ->
            {:ok, Enum.map(spellings, &(&1 |> Prima.Origin.from_wire() |> elem(1)))}

          {:error, {:invalid_decision, :origins, why}} ->
            {:error, {:invalid_argument, "The origins a grant admits #{why}"}}
        end
    end
  end

  # The narrowing's shape; whether it lies inside the ask is the builder's.
  defp decided_subset(decisions) do
    case Normalize.subset(decisions, :subset, :invalid_decision) do
      {:ok, subset} ->
        {:ok, subset}

      {:error, {:invalid_decision, _key, why}} ->
        {:error, {:invalid_argument, "The narrowing " <> narrowing_sentence(why)}}
    end
  end

  defp narrowing_sentence("must be " <> _ = why), do: why
  defp narrowing_sentence("names " <> _ = why), do: why
  defp narrowing_sentence(why), do: "is refused: " <> why

  # The caller's requested patterns, narrowed to what the server's own
  # config permits. Nothing is taken verbatim.
  #
  # Narrowed at the PATTERN level, not by expanding against the live tool
  # catalogue: the catalog reports `tool_names: []` for a server it could
  # not reach, so expanding would silently collapse a legitimate grant to
  # nothing whenever the upstream is down.
  #
  # A requested `"*"` means "whatever this server exposes", so it resolves
  # to the config itself rather than being stored as `"*"` — the operator
  # then sees the actual patterns on the consent sheet instead of a
  # wildcard that reads far wider than the grant it can produce.
  defp narrow_tool_patterns(nil, config), do: {:ok, config}

  defp narrow_tool_patterns(requested, config) when is_list(requested) do
    if "*" in requested do
      {:ok, config}
    else
      {:ok,
       requested
       |> Enum.filter(fn pattern ->
         is_binary(pattern) and Prima.ToolPattern.valid?(pattern) and
           covered_by_config?(pattern, config)
       end)
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  # Reject non-list narrowing values; only an absent key uses the configured set.
  defp narrow_tool_patterns(_not_a_list, _config), do: :error

  defp covered_by_config?(pattern, config) do
    Enum.any?(config, fn allowed ->
      cond do
        allowed == "*" -> true
        allowed == pattern -> true
        String.ends_with?(allowed, ".*") -> String.starts_with?(pattern, dot_prefix(allowed))
        true -> false
      end
    end)
  end

  defp dot_prefix(pattern), do: String.trim_trailing(pattern, "*")

  # Resolve tool-server digests live during preparation. Include a
  # description baseline when the catalog is reachable.
  defp resolve_tool_servers(ctx, decisions) do
    decisions
    |> Map.get(:tool_servers, [])
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      name = Map.get(raw, :server_name)

      case Sanctum.Grimoire.tool_server_candidate(ctx, name || "") do
        {:ok, %{server_digest: digest} = candidate} when is_binary(digest) ->
          # Intersect granted patterns with the server’s configured patterns.
          # Dispatch also rechecks the live configuration.
          case narrow_tool_patterns(Map.get(raw, :tool_patterns), candidate.tool_patterns) do
            {:ok, patterns} ->
              grant = %{
                server_name: candidate.name,
                server_digest: digest,
                tool_patterns: patterns,
                descriptions_digest: candidate.descriptions_digest
              }

              {:cont, {:ok, [grant | acc]}}

            :error ->
              {:halt, {:error, {:invalid_tool_patterns, name}}}
          end

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

  # A public twin lends no other profile's entry.
  defp prepared_selections(_ctx, _decisions, published, _activation, _source_ref)
       when is_map(published),
       do: {:ok, []}

  defp prepared_selections(ctx, decisions, nil, activation, source_ref),
    do: resolve_selections(ctx, decisions, activation, source_ref)

  # Each selection names a dependency of the closure and, by label, one
  # of its active owner profiles whose head binds an entry on its
  # ingress; the binding digest is pinned from that live entry, so a
  # rebind of the lender after this commit leaves the selection
  # unresolved rather than lending a differently shaped credential.
  defp resolve_selections(ctx, decisions, activation, source_ref) do
    decisions
    |> Map.get(:selections, [])
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      with {:ok, from, dep} <- selection_target(ctx, raw, activation, source_ref),
           {:ok, profile} <- lender_profile(ctx, dep, Map.get(raw, :label, "default")),
           {:ok, bound} <- lender_binding(ctx, profile),
           {:ok, entry} <- fetch_active_entry(ctx, bound.entry_id),
           {:ok, live_digest} <- VaultReader.binding_digest(entry),
           :ok <- check_lender_digest(live_digest, bound, dep, profile.label),
           {:ok, lent} <- lent_fields(bound, dep, profile.label),
           {:ok, fields} <- selected_fields(raw, lent, dep) do
        selection = %{
          from: from,
          dep: dep,
          label: profile.label,
          profile_id: profile.id,
          binding_digest: live_digest,
          entry_id: entry.id,
          entry_name: entry.name,
          fields: fields,
          lent_fields: lent,
          # The selection names no scopes, so the lender's reach the edge.
          lent_scopes: Map.get(bound.projection, :scopes) || []
        }

        {:cont, {:ok, [selection | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, selections} -> {:ok, Enum.reverse(selections)}
      error -> error
    end
  end

  defp selection_target(ctx, raw, activation, source_ref) do
    with {:ok, dep} <- Plan.name_ref(Map.get(raw, :dep) || ""),
         {:ok, from} <- selection_from(raw, source_ref),
         true <- Map.has_key?(activation.graph, from),
         {:ok, manifest} <- node_manifest(ctx, from),
         true <- dep in BlobBuilder.dep_edges(manifest, activation.graph, from) do
      {:ok, from, dep}
    else
      _ -> {:error, {:selection_target_unknown, Map.get(raw, :dep)}}
    end
  end

  defp selection_from(raw, source_ref) do
    case Map.get(raw, :from) do
      nil -> {:ok, source_ref}
      from when is_binary(from) and from != "" -> Plan.name_ref(from)
      _ -> {:error, :invalid_from}
    end
  end

  defp node_manifest(ctx, node_key) do
    with {:ok, ref} <- Prima.ComponentRef.parse(node_key),
         {:ok, row} <- Components.get_latest(ctx, ref.name, ref.namespace, ref.type) do
      {:ok, manifest(row, node_key)}
    end
  end

  defp lender_profile(ctx, dep, label) when is_binary(label) do
    with {:ok, profiles} <- Arca.ConsentStorage.profiles(Context.actor(ctx), dep),
         %{status: :active} = profile <-
           Enum.find(profiles, &(&1.label == label and &1.kind == :owner)) do
      {:ok, profile}
    else
      _ -> {:error, {:selection_profile_unavailable, dep, label}}
    end
  end

  defp lender_profile(_ctx, dep, label),
    do: {:error, {:selection_profile_unavailable, dep, label}}

  defp lender_binding(ctx, profile) do
    with {:ok, head} <- Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id),
         {:ok, blob} <- Prima.Authority.Blob.parse(head.resolved_policy),
         {:ok, ingress} <- Prima.Authority.Blob.ingress(blob, profile.source_ref),
         true <- Prima.Authority.Blob.bound_vault?(ingress.vault) do
      {:ok, ingress.vault}
    else
      _ -> {:error, {:selection_unbound, profile.source_ref, profile.label}}
    end
  end

  defp check_lender_digest(live, %{binding_digest: bound}, dep, label) do
    if Plug.Crypto.secure_compare(live, bound),
      do: :ok,
      else: {:error, {:selection_unbound, dep, label}}
  end

  # A lender lends the fields its own edge names; an edge that names none
  # lends nothing.
  defp lent_fields(%{projection: %{fields: [_ | _] = lent}}, _dep, _label), do: {:ok, lent}
  defp lent_fields(_unprojected, dep, label), do: {:error, {:selection_unbound, dep, label}}

  # The selection may narrow the lender's fields, never widen them. Naming
  # none lends every field the lender names (the selection writes no
  # projection of its own and the loader takes the lender's); an explicit
  # empty list names nothing and is refused.
  defp selected_fields(raw, lent, dep) do
    case Map.fetch(raw, :fields) do
      :error ->
        {:ok, []}

      {:ok, [_ | _] = fields} ->
        case Enum.reject(fields, &(&1 in lent)) do
          [] -> {:ok, Enum.sort(fields)}
          missing -> {:error, {:selection_fields_unavailable, dep, missing}}
        end

      {:ok, _empty} ->
        {:error, empty_projection(dep, :fields)}
    end
  end

  defp declared_needs(component, source_ref) do
    component
    |> manifest(source_ref)
    |> Prima.Manifest.Needs.from_manifest()
  end

  # A manifest that does not decode declares nothing. The line names the
  # component, never the manifest's bytes.
  defp manifest(row, ref) do
    case Prima.Manifest.decode_strict(Map.get(row, :manifest) || Map.get(row, "manifest")) do
      {:ok, manifest} ->
        manifest

      {:error, :malformed_manifest} ->
        Logger.warning("[Sanctum.Consent.Commit] manifest malformed: #{ref}")
        %{}
    end
  end

  # Apply public limits to the source and make storage read-only unless
  # durable writes are enabled. Retain vault resources only for need_ids,
  # verifying their binding digests against live entries.
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

          # Only the SOURCE node drops to the public constants: the public
          # ceiling governs what the anonymous caller can drive, and every
          # request enters at the source. Children keep the owner's clamped
          # limits — they are reachable only through the source's edges, so
          # the public budget already bounds how often they run, and
          # re-clamping them here would change consented in-chain behavior.
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
        # Any storage block, whether or not it spells `actions`. An absent
        # roster already denies every action downstream (`Opus.EdgeGuard`
        # reads a missing list as the empty one), so writing the filtered
        # list here changes nothing — it just makes the transform total, so
        # the promise above holds by construction rather than by agreement
        # with a fail-closed reader two modules away.
        storage when is_map(storage) and not durable? ->
          Map.put(edge, "storage", %{
            "paths" => storage["paths"] || [],
            "actions" =>
              storage
              |> Map.get("actions", [])
              |> Enum.filter(&(&1 in @readonly_storage_actions))
          })

        _ ->
          edge
      end

    # Public profiles grant no external MCP access, and lend no other
    # profile's entry: a selection never publishes.
    edge = Map.delete(edge, "tool_servers")

    case Map.get(edge, "vault") do
      %{"entry_id" => _} -> if edge_key in need_ids, do: edge, else: Map.delete(edge, "vault")
      _ -> Map.delete(edge, "vault")
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
    case Components.resolve_verified(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:error, {:activation_unresolvable, reason}}
    end
  end

  # Pin by activation digest; retain the version for display.
  defp shape_for_scope(shape_input, :versionless, _component) do
    ShapeDigest.compute(shape_input)
  end

  # Pinned profiles require a release digest.
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

  # Derive binding digests from live rows. Use @ingress only when the
  # manifest declares no needs; otherwise each binding must name a declared need.
  defp resolve_bindings(ctx, decisions, declared) do
    decisions
    |> Map.get(:bindings, [])
    |> Enum.reduce_while({:ok, [], %{}}, fn raw, {:ok, acc, entries} ->
      need = Map.get(raw, :need, Prima.Authority.Blob.ingress_key())

      with {:ok, declared_need} <- check_known_need(need, declared),
           {:ok, fields} <- binding_list(raw, :fields, declared_need, need),
           {:ok, scopes} <- binding_list(raw, :scopes, declared_need, need),
           :ok <- check_token_grant(declared_need, scopes, need),
           {:ok, entry} <- fetch_active_entry(ctx, Map.get(raw, :entry_id)),
           {:ok, digest} <- VaultReader.binding_digest(entry),
           {:ok, fields, scopes} <- named_projection(declared_need, fields, scopes, entry, need) do
        binding = %{
          need: need,
          entry_id: entry.id,
          binding_digest: digest,
          fields: fields,
          scopes: scopes
        }

        {:cont, {:ok, [binding | acc], Map.put(entries, entry.id, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, [_, _ | _], _entries} ->
        # Allow only one credential binding per direct-run execution closure.
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

  # A binding's projection is its need's: the declared fields of a key or
  # bundle need, the declared scopes of an OAuth need, which the shape has
  # already refused to leave empty. The caller may name its own list in
  # their place; an explicit empty list names nothing and is refused rather
  # than read as everything the entry holds.
  defp binding_list(raw, key, declared_need, need) do
    case Map.fetch(raw, key) do
      :error -> {:ok, declared_list(declared_need, key)}
      {:ok, [_ | _] = list} -> {:ok, list}
      {:ok, _empty} -> {:error, empty_projection(need, key)}
    end
  end

  defp declared_list(nil, _key), do: []
  defp declared_list(declared_need, key), do: Map.fetch!(declared_need, key)

  # A token is dispensed only under scopes an OAuth need grants: a key or
  # bundle need's edge names no scopes, so it never dispenses one.
  defp check_token_grant(%{kind: kind}, [_ | _], need) when kind in ~w(api_key bundle) do
    {:error,
     {:invalid_argument,
      "The binding for #{need} names scopes, but #{need} is a #{kind} need; " <>
        "only an OAuth need grants scopes"}}
  end

  defp check_token_grant(_declared_need, _scopes, _need), do: :ok

  # An `@ingress` binding on a manifest that declares no need has no list to
  # inherit. When its caller names none, it names what the entry holds at
  # consent time — its field names and, for an OAuth entry, its authorized
  # scopes — so the edge still references its entry under a projection the
  # preview shows. Those are the entry's binding fields: a change to them
  # moves the binding digest and asks again. An entry that holds neither
  # has nothing to project and is refused.
  defp named_projection(nil, [], [], entry, need) do
    fields = stored_list(entry.field_names)
    scopes = if entry.kind == "oauth", do: stored_list(entry.oauth_scopes), else: []

    if fields == [] and scopes == [],
      do: {:error, empty_projection(need, :fields)},
      else: {:ok, fields, scopes}
  end

  defp named_projection(_declared_need, fields, scopes, _entry, _need),
    do: {:ok, fields, scopes}

  defp stored_list(json) when is_binary(json) and json != "" do
    case Prima.Json.decode(json) do
      {:ok, list} when is_list(list) -> list |> Enum.filter(&is_binary/1) |> Enum.sort()
      _ -> []
    end
  end

  defp stored_list(_absent), do: []

  defp empty_projection(name, key) do
    {:invalid_argument,
     "The binding for #{name} names no #{key}; a projection names the #{key} it reads"}
  end

  defp fetch_active_entry(_ctx, nil), do: {:error, {:invalid_binding, :entry_id_required}}

  defp fetch_active_entry(ctx, entry_id) do
    case Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry_id) do
      {:ok, %{status: "active"} = entry} -> {:ok, entry}
      {:ok, %{status: status}} -> {:error, {:entry_unavailable, entry_id, status}}
      {:error, reason} -> {:error, {:entry_unavailable, entry_id, reason}}
    end
  end

  # Include the built blob's digest alongside the displayed decisions so
  # the proof binds every runtime grant.
  defp commit_input(
         shape_digest,
         blob_digest,
         {label, kind, invoke_mode},
         {origins, subset},
         bindings,
         selections,
         tool_servers,
         decisions
       ) do
    {:ok,
     %{
       shape_digest: shape_digest,
       blob_digest: blob_digest,
       # Which profile the grant lands on, which the blob cannot say —
       # `(source_ref, label, kind)` is the profiles' identity index, and
       # on a first consent both labels answer `{:ok, nil, 0}`, so the
       # proof bound nothing that told them apart.
       label: label,
       kind: kind,
       invoke_mode: invoke_mode,
       origins: origins,
       bindings: bindings,
       selections:
         Enum.map(selections, &Map.take(&1, [:from, :dep, :label, :binding_digest, :fields])),
       tool_servers:
         Enum.map(tool_servers, &Map.take(&1, [:server_name, :server_digest, :tool_patterns])),
       override: Map.get(decisions, :override, false),
       subset: subset
     }}
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
      |> Prima.MapUtil.put_present(:profile_id, prep.profile_id)

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
      |> Prima.MapUtil.put_present(:profile_id, prep.profile_id)

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
      |> Prima.MapUtil.put_present(:profile_id, prep.profile_id)

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

    with {:ok, nodes, narrowed} <- BlobBuilder.narrow_nodes(nodes, prep.source_ref, prep.subset),
         {:ok, blob_json} <- JCS.encode(%{"canonical" => "jcs-1", "nodes" => nodes}),
         :ok <- check_binding_digests(blob_json, prep) do
      {:ok, blob_json, refs, narrowed}
    end
  end

  defp build_blob(ctx, prep) do
    # The single credential binding rides the ingress edge whatever its
    # need name — "@ingress" for no-needs manifests, the declared need
    # for manifests with one. resolve_bindings already refused a second.
    # A selected dependency's edges carry the selection.
    source_binding = List.first(prep.bindings)
    selections = Map.new(prep.selections, &{{&1.from, &1.dep}, &1})

    vault_fn = fn node_key, _row, _manifest ->
      if node_key == prep.source_ref and source_binding != nil do
        vault_resource(source_binding)
      end
    end

    edge_vault_fn = fn from, dep, _row, _manifest ->
      selections |> Map.get({from, dep}) |> selection_resource()
    end

    extras =
      case prep.tool_servers do
        [] -> %{}
        grants -> %{"tool_servers" => Enum.map(grants, &tool_server_resource/1)}
      end

    with {:ok, nodes} <-
           BlobBuilder.build(ctx, prep.activation.graph, prep.source_ref, vault_fn,
             ingress_extras: extras,
             edge_vault_fn: edge_vault_fn,
             subset: prep.subset
           ),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         :ok <- check_binding_digests(blob_json, prep) do
      {:ok, blob_json, BlobBuilder.vault_refs(nodes), BlobBuilder.narrowed(nodes)}
    end
  end

  defp check_binding_digests(blob_json, prep) do
    parsed =
      case Prima.Authority.Blob.parse(blob_json) do
        {:ok, blob} -> Prima.Authority.Blob.entry_digest_conflicts(blob)
        _ -> []
      end

    decided = conflicting_entry_ids(prep.bindings ++ prep.selections)

    case Enum.uniq(parsed ++ decided) do
      [id | _] -> {:error, {:inconsistent_binding_digest, id}}
      [] -> :ok
    end
  end

  defp conflicting_entry_ids(items) do
    items
    |> Enum.filter(fn item ->
      is_binary(Map.get(item, :entry_id)) and is_binary(Map.get(item, :binding_digest))
    end)
    |> Enum.group_by(& &1.entry_id, & &1.binding_digest)
    |> Enum.filter(fn {_id, digests} -> digests |> Enum.uniq() |> length() > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
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

  defp selection_resource(nil), do: nil

  defp selection_resource(selection) do
    base = %{
      "via" => %{"label" => selection.label, "binding_digest" => selection.binding_digest}
    }

    case put_projection(%{}, "fields", selection.fields) do
      projection when projection == %{} -> base
      projection -> Map.put(base, "projection", projection)
    end
  end

  defp put_projection(map, _key, []), do: map
  defp put_projection(map, key, values), do: Map.put(map, key, Enum.sort(values))

  defp persist(ctx, prep, blob_json, refs, activation_json, granted_via) do
    profile_id = prep.profile_id || Prima.UUID7.generate_id("prof")

    attrs = %{
      athanor_id: ctx.athanor_id,
      profile_id: profile_id,
      revision: prep.expected_revision + 1,
      scope: Atom.to_string(prep.scope),
      pinned_version: pinned_version(prep),
      invoke_mode: Atom.to_string(prep.invoke_mode),
      shape_digest: prep.shape_digest,
      commit_digest: prep.commit_digest,
      # Stored beside the bytes it covers so `Consent.Loader` can refuse a
      # `resolved_policy` altered in place — nothing else on the row
      # detects that: `check_blob_refs_equality/2` compares vault-ref pairs
      # only, and `commit_digest` covers this column, not the blob.
      blob_digest: prep.blob_digest,
      resolved_policy: blob_json,
      activation: activation_json,
      admitted_origins: prep.origins,
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
    case Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile_id) do
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
    case Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id) do
      {:ok, %{status: "needs_consent"}} ->
        Arca.ProfileStorage.set_status(Sanctum.Context.actor(ctx), profile_id, "active")

      {:ok, _other_status} ->
        :ok

      # A store fault leaves the profile blocked while the commit reports
      # success — fail-closed in effect, but it must not be silent: the
      # person consented and their profile stayed stuck.
      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Consent.Commit] could not reactivate profile #{profile_id} " <>
            "after commit: #{inspect(reason)} — it stays needs_consent until re-read"
        )

        :ok
    end
  end

  defp reactivate_profile(_ctx, _prep), do: :ok

  # ---------------------------------------------------------------------------
  # Rendering + helpers
  # ---------------------------------------------------------------------------

  # The typed rows of what the revision grants, read from the same blob
  # bytes the digest covers: the builder's rows for resources, limits and a
  # tincture's declarations, and the credentials and tool servers only the
  # commit can name.
  defp preview_rows(ctx, prep) do
    with {:ok, nodes} <- blob_nodes_or_bug(prep.blob_json),
         {:ok, granted} <- BlobBuilder.grant_rows(ctx, prep.source_ref, nodes, prep.narrowed),
         {:ok, credentials} <- credential_rows(prep, nodes) do
      rows = BlobBuilder.order_rows(granted ++ credentials ++ tool_server_rows(prep, nodes))

      case BlobBuilder.check_rows(rows) do
        {:ok, _checked} -> {:ok, rows}
        {:error, reason} -> {:error, {:preview_unrepresentable, reason}}
      end
    end
  end

  defp consent_preview(rows, prep) do
    document = %{
      "v" => Prima.ConsentPreview.version(),
      "rows" => rows,
      "origins" => Prima.Origin.to_wire_list(prep.origins),
      "commit_digest" => prep.commit_digest
    }

    case Prima.ConsentPreview.decode(document) do
      {:ok, preview} -> {:ok, preview}
      {:error, reason} -> {:error, {:preview_unrepresentable, reason}}
    end
  end

  # The blob was just built from this prep; bytes that do not decode are a
  # construction bug, never a shorter preview.
  defp blob_nodes_or_bug(json) do
    case blob_nodes(json) do
      {:ok, nodes} -> {:ok, nodes}
      :error -> {:error, {:preview_unrepresentable, :blob}}
    end
  end

  # One row per credential an edge carries, on the node whose edge carries
  # it: the source for its ingress, the calling node for an edge into a
  # dependency, with the edge's key, so one entry lent on two edges is two
  # rows. A bound entry is named by the entry; a selection by the lender's
  # entry and the label of the profile lending it.
  defp credential_rows(prep, nodes) do
    carried =
      for {from, node} <- Enum.sort(nodes),
          {key, %{"vault" => vault}} <- Enum.sort(node["edges"] || %{}) do
        target =
          case Prima.Authority.Blob.edge_target(key) do
            :ingress -> from
            {:ok, dep} -> dep
          end

        credential_row(prep, {from, key, target}, vault)
      end

    case Enum.find(carried, &match?({:error, _}, &1)) do
      nil ->
        rows = for {:ok, row} <- carried, do: row
        {:ok, Enum.sort_by(rows, &{&1["node"], &1["values"]["name"], &1["values"]["edge"]})}

      error ->
        error
    end
  end

  defp credential_row(prep, {from, key, _target}, %{"entry_id" => entry_id} = vault) do
    case Map.fetch(prep.entries, entry_id) do
      {:ok, entry} ->
        {:ok,
         BlobBuilder.row(
           "credential",
           from,
           %{
             "name" => entry.name,
             "edge" => key,
             "fields" => projection(vault, "fields"),
             "scopes" => projection(vault, "scopes")
           },
           false
         )}

      :error ->
        {:error, {:preview_unrepresentable, :credential}}
    end
  end

  defp credential_row(prep, {from, key, target}, %{"via" => %{"label" => label}} = vault) do
    case Enum.find(prep.selections, &(&1.from == from and &1.dep == target)) do
      nil ->
        {:error, {:preview_unrepresentable, :credential}}

      selection ->
        fields =
          case projection(vault, "fields") do
            [] -> Enum.sort(selection.lent_fields)
            fields -> fields
          end

        {:ok,
         BlobBuilder.row(
           "credential",
           from,
           %{
             "name" => selection.entry_name,
             "edge" => key,
             "label" => label,
             "fields" => fields,
             "scopes" => Enum.sort(Enum.uniq(selection.lent_scopes))
           },
           false
         )}
    end
  end

  defp projection(vault, key),
    do: (get_in(vault, ["projection", key]) || []) |> Enum.uniq() |> Enum.sort()

  defp tool_server_rows(prep, nodes) do
    nodes
    |> get_in([prep.source_ref, "edges", Prima.Authority.Blob.ingress_key(), "tool_servers"])
    |> List.wrap()
    |> Enum.sort_by(& &1["server_name"])
    |> Enum.map(fn server ->
      BlobBuilder.row(
        "tool_servers",
        prep.source_ref,
        %{
          "name" => server["server_name"],
          "digest" => server["server_digest"],
          "tool_patterns" => server["tool_patterns"] |> List.wrap() |> Enum.uniq() |> Enum.sort()
        },
        false
      )
    end)
  end

  # Render grants from the same blob covered by the approved digest.
  defp render_summary(prep) do
    header =
      "Grant #{prep.source_ref} — #{prep.kind}, #{prep.scope}, revision #{prep.expected_revision + 1}"

    bindings =
      Enum.map(prep.bindings, fn binding ->
        entry = Map.fetch!(prep.entries, binding.entry_id)

        "Uses #{entry.name} (#{render_projection(binding)})"
      end)

    selections =
      Enum.map(prep.selections, fn selection ->
        fields = if selection.fields == [], do: selection.lent_fields, else: selection.fields

        "#{selection.dep} runs with #{selection.entry_name}, the key bound on its " <>
          "'#{selection.label}' profile (#{Enum.join(fields, ", ")})"
      end)

    [header | bindings ++ selections] ++ render_grants(prep)
  end

  # The fields and scopes the edge's projection names, as written. A
  # binding on a manifest with no need names only what its caller named.
  defp render_projection(binding) do
    case {binding.fields, binding.scopes} do
      {[], []} -> "no projection"
      {fields, []} -> Enum.join(fields, ", ")
      {[], scopes} -> "scopes " <> Enum.join(scopes, ", ")
      {fields, scopes} -> Enum.join(fields, ", ") <> "; scopes " <> Enum.join(scopes, ", ")
    end
  end

  defp render_grants(prep) do
    case Prima.Authority.Blob.parse(prep.blob_json) do
      {:ok, blob} ->
        blob.nodes
        |> Enum.sort_by(fn {ref, _node} -> ref end)
        |> Enum.flat_map(&render_node/1)

      # The blob was just built from this prep, so a parse failure is a
      # construction bug — say so rather than rendering a shorter, quieter
      # sheet that reads like a narrower grant.
      {:error, reason} ->
        Logger.error("[Sanctum.Consent.Commit] the grants did not parse: #{inspect(reason)}")
        ["Grants could not be rendered — do not approve"]
    end
  end

  defp render_node({ref, node}) do
    grants =
      node.edges
      |> Enum.sort_by(fn {key, _edge} -> key end)
      |> Enum.flat_map(fn {_key, edge} -> render_edge(edge) end)
      |> Enum.uniq()

    # Include each node’s limits in the consent summary.
    lines = grants ++ render_limits(node.limits)

    case lines do
      [] -> ["#{ref}: no capabilities"]
      lines -> Enum.map(lines, fn line -> "#{ref}: #{line}" end)
    end
  end

  defp render_limits(nil), do: []

  defp render_limits(%Prima.Limits{} = limits) do
    rate =
      case limits.rate_limit do
        %{requests: requests, window: window} -> "#{requests}/#{window}"
        _ -> nil
      end

    parts =
      [
        limits.timeout && "timeout #{limits.timeout}",
        limits.max_memory_bytes && "memory #{limits.max_memory_bytes}B",
        rate && "rate #{rate}",
        limits.max_concurrent_tasks && "concurrency #{limits.max_concurrent_tasks}"
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> []
      parts -> ["limits #{Enum.join(parts, ", ")}"]
    end
  end

  defp render_edge(edge) do
    Enum.concat([
      render_egress(edge.egress),
      render_storage(edge.storage),
      render_tools(edge.tools),
      render_tool_servers(edge.tool_servers)
    ])
  end

  defp render_egress(nil), do: []

  defp render_egress(%{domains: []}), do: []

  defp render_egress(%{domains: domains} = egress) do
    methods = egress |> Map.get(:methods, []) |> render_list("any method")

    # Schemes and private_ips were computed into the blob and shown
    # nowhere. `private_ips` is the one that matters: an operator
    # approving "network internal.corp (GET)" was not told the grant
    # reaches RFC1918 space, which is the whole SSRF question.
    schemes =
      case Map.get(egress, :schemes, []) do
        [] -> nil
        schemes -> "via #{Enum.join(Enum.sort(schemes), ", ")}"
      end

    private =
      case Map.get(egress, :private_ips, []) do
        [] -> nil
        ranges -> "INCLUDING PRIVATE #{Enum.join(Enum.sort(ranges), ", ")}"
      end

    qualifiers = Enum.reject([methods, schemes, private], &is_nil/1)

    ["network #{Enum.join(domains, ", ")} (#{Enum.join(qualifiers, "; ")})"]
  end

  defp render_storage(nil), do: []
  defp render_storage(%{paths: []}), do: []

  defp render_storage(%{paths: paths, actions: actions}) do
    ["storage #{Enum.join(paths, ", ")} (#{render_list(actions, "no actions")})"]
  end

  defp render_tools([]), do: []
  defp render_tools(tools), do: ["tools #{Enum.join(Enum.sort(tools), ", ")}"]

  defp render_tool_servers([]), do: []

  defp render_tool_servers(servers) do
    Enum.map(servers, fn server ->
      "tool server #{server.server_name} (#{render_list(server.tool_patterns, "no tools")})"
    end)
  end

  defp render_list([], empty), do: empty
  defp render_list(values, _empty), do: values |> Enum.sort() |> Enum.join(", ")

  defp conflict(cause, expected, actual) do
    {:error,
     {:consent_conflict, %{expected_revision: expected, actual_revision: actual, cause: cause}}}
  end
end
