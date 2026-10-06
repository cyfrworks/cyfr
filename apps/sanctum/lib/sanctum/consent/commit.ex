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

  ## Bindings and selections

  A binding (`:bindings`) binds a need of the source to exactly one of the
  athanor's entries (`entry_id`) and an instance entry offered to the
  person (`instance_entry_id`), under the need's projection or the
  `fields` and `scopes` it names. The entry must be of the need's kind and
  provider (`{:provider_mismatch, need}`); a need the component reads
  itself — disclose-only, `disclose: true`, or the `@ingress` slot of a
  manifest declaring no needs — takes a disclosed entry of the athanor
  alone (`{:disclosure_refused, need}`); and an instance entry must be
  offered to the person (`{:not_offered, need}`), active, and admitted by
  its component policy for the source (`{:component_not_admitted, need}`).
  All of a decision's bindings name one need, since the ingress edge
  carries one need's bindings (bindings of two needs are refused, naming
  them): one of them names no `name` and is the default, and each other
  names its account (`name`) and rides the edge's `named` map.

  Every binding, and every selection, carries its `lifetime` —
  `standing` (when it names none), `until` an RFC 3339 UTC instant
  strictly after the clock and at most 24 hours after it, or `once` —
  and `renew`, which makes a consumed `once` binding consumable again.
  Each is written on the binding's own row (`Arca.ConsentStorage`), never
  on the blob, and the commit digest covers both.

  A selection (`:selections`) fills a dependency's edge: by the `label`
  of the dependency's owner profile that lends its entry (`label:
  "default"` when it names nothing), or with an entry of the athanor or
  an instance entry (`entry_id`, `instance_entry_id`) chosen for one of
  the dependency's credential needs (`need`, required when it declares
  several), checked as a binding of that need against the dependency. A
  dependency edge holds one need's credentials: a need the calling node's
  `provides` covers takes no selection, and an edge two needs would fill
  is refused. A lending profile is read as the plan reads the
  dependency's lenders (`Sanctum.Consent.Plan`) and as a run's selection
  reads it (`Sanctum.Consent.Loader`): a profile row of the dependency
  that does not decode refuses the selection `{:lender_corrupt, dep,
  profile_id}`, a profiles store that could not answer
  `{:lender_unavailable, dep}`, and no active owner profile of the label
  `{:selection_profile_unavailable, dep, label}`. Its head, likewise, that
  does not decode, or whose bytes fail their digest or do not parse,
  refuses `{:lender_corrupt, dep, profile_id}`; one the store could not
  answer `{:lender_unavailable, dep}`; and one that is missing, or binds
  no entry on its ingress, `{:selection_unbound, dep, label}`.

  An edge's selections are one default, which names no account, and any
  number of named accounts beside it (`name`), each an entry chosen here
  for the default's need and checked as the default is, with its own
  lifetime and `renew`, riding the edge's `named` map. A named account
  names an entry, never a lender's label, and sits beside a default entry
  chosen here, never beside a key a profile lends; a name a person would
  read as another (differing only in case) is that name again.

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
  rows of what the revision would grant, the origins it would admit, the
  bindings of the profile's head it would remove and the commit digest
  binding them all, with the proof and the expected revision beside
  them. Every surface renders the rows and the removals itself.

  A head binding is removed when the revision binds nothing under its
  key, or binds it for another need: a grant for another need of the
  app's own calls replaces every binding those calls held. Neither the
  blob nor a binding's row records its need, so a head binding's need is
  told by its entry, as the surfaces tell it: the one need whose
  candidates hold the entry, or the one need there is (`Plan.need_choice/4`);
  on a dependency's edge, the need the edge names, or the dependency's
  one credential need. A head binding whose need cannot be told is
  compared by its key alone, so an entry changed under a kept key is a
  change its new row shows, never a removal.
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
  Recompute live, answer the structured preview, mint the commit proof. Two previews of the same decisions over the same world
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
         removed: document["removed"],
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

  It answers the profile, the revision written, its commit digest and
  `removed`: the bindings of the head the revision dropped, exactly as a
  preview of the same grant over the same head lists them (empty when it
  dropped none). No preview stands before a grant, so its answer is where
  the caller learns which of the app's bindings a grant for another need
  replaced.
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
      {:ok,
       %{
         profile_id: consent.profile_id,
         revision: consent.revision,
         commit_digest: prep.commit_digest,
         # The preparation's own list, the one its digest covers and a
         # preview would show: never computed a second way.
         removed: prep.removed
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
  # origins the head was committed under.
  defp grant_decisions(profile, head, bindings) do
    %{
      ref: profile.source_ref,
      label: profile.label,
      kind: :owner,
      scope: head.scope,
      invoke_mode: head.invoke_mode,
      origins: head.admitted_origins,
      bindings: bindings,
      selections: head_selections(head, profile.source_ref),
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
  # lender, or the same entry for the same need under the same account
  # name, the same fields, the digest pinned again from the live entry,
  # and the lifetime its row holds, renewing nothing — so a consumed
  # `once` carries and nothing widens, and an `until` that has passed
  # refuses the grant as a commit would. An entry on an edge into the
  # source is the source's own binding riding it, never a selection.
  defp head_selections(head, source_ref) do
    rows = Map.new(head.vault_refs, &{&1.binding_key, &1})

    with {:ok, %{"nodes" => nodes}} <- Jason.decode(head.resolved_policy) do
      for {from, node} <- nodes,
          {edge_key, %{"vault" => vault}} <- node["edges"] || %{},
          {:ok, dep} <- [Prima.Authority.Blob.edge_target(edge_key)],
          {slot, selection} <- head_selection(vault, from, dep, source_ref) do
        key = Prima.Authority.Blob.binding_key(from, edge_key, slot)
        Map.put(selection, :lifetime, row_lifetime(Map.get(rows, key)))
      end
    else
      _ -> []
    end
  end

  # A selection that named no fields lends the lender's again.
  defp head_selection(%{"via" => %{"label" => label}} = vault, from, dep, _source_ref) do
    [
      {nil,
       Prima.MapUtil.put_present(
         %{from: from, dep: dep, label: label},
         :fields,
         get_in(vault, ["projection", "fields"])
       )}
    ]
  end

  # An entry bound on a dependency's edge, for the need of the
  # dependency's whose attach rule it carries, and each account named
  # beside it.
  defp head_selection(%{"entry_id" => _} = vault, from, dep, source_ref)
       when dep != source_ref do
    named = vault |> Map.get("named", %{}) |> Enum.sort()

    [{nil, head_entry_selection(vault, from, dep)}] ++
      for {name, bound} <- named,
          do: {name, Map.put(head_entry_selection(bound, from, dep), :name, name)}
  end

  defp head_selection(_bound_source_or_provided, _from, _dep, _source_ref), do: []

  defp head_entry_selection(%{"entry_id" => id} = bound, from, dep) do
    entry_key = if bound["scope"] == "instance", do: :instance_entry_id, else: :entry_id

    %{from: from, dep: dep}
    |> Map.put(entry_key, id)
    |> Prima.MapUtil.put_present(:fields, get_in(bound, ["projection", "fields"]))
    |> Map.put(:head_attach, Map.get(bound, "attach"))
  end

  defp row_lifetime(%{lifetime_kind: "until", expires_at: %DateTime{} = at}),
    do: %{kind: "until", until: DateTime.to_iso8601(at)}

  defp row_lifetime(%{lifetime_kind: kind}) when kind in ~w(standing once), do: %{kind: kind}
  defp row_lifetime(_absent), do: nil

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
         origins: Prima.Origin.to_wire_list(prep.origins)
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
         {:ok, closure_rows} <- resolve_closure_rows(ctx, component, activation),
         :ok <- check_published_nodes(published, closure_rows, source_ref),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- shape_for_scope(shape_input, scope, component),
         {:ok, profile_id, expected_revision} <-
           Plan.locate_profile(ctx, source_ref, label, kind),
         declared = declared_needs(component, source_ref),
         place = %{
           source_ref: source_ref,
           graph: activation.graph,
           rows: closure_rows,
           now: DateTime.utc_now()
         },
         {:ok, provided} <- provided_edges(ctx, place, published),
         {:ok, bindings, entries} <- prepared_bindings(ctx, decisions, published, declared, place),
         {:ok, selections, lent} <-
           prepared_selections(ctx, decisions, published, place, provided),
         {:ok, tool_servers} <- resolve_tool_servers(ctx, decisions),
         # Build the blob before digest validation; preview renders these same bytes.
         blob_inputs = %{
           source_ref: source_ref,
           activation: activation,
           closure_rows: closure_rows,
           bindings: bindings,
           selections: selections,
           provided: provided,
           tool_servers: tool_servers,
           subset: subset,
           publish_nodes: published && published.nodes
         },
         {:ok, blob_json, blob_refs, narrowed} <- build_blob(ctx, blob_inputs),
         blob_digest = JCS.hash_binary(blob_json),
         {:ok, removed} <-
           removed_bindings(ctx, {profile_id, expected_revision}, %{
             refs: blob_refs,
             needs: decided_needs(source_ref, bindings, selections, published),
             source_ref: source_ref,
             declared: declared,
             graph: activation.graph,
             rows: closure_rows
           }),
         {:ok, commit_input} <-
           commit_input(
             shape_digest,
             blob_digest,
             {label, kind, invoke_mode},
             {origins, subset, removed},
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
         closure_rows: closure_rows,
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
         provided: provided,
         entries: Map.merge(entries, lent),
         tool_servers: tool_servers,
         origins: origins,
         subset: subset,
         removed: removed,
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

  defp prepared_bindings(ctx, decisions, nil, declared, place),
    do: resolve_bindings(ctx, decisions, declared, place)

  defp prepared_bindings(_ctx, _decisions, published, _declared, _place),
    do: {:ok, published.bindings, published.entries}

  # A public twin lends no other profile's entry.
  defp prepared_selections(_ctx, _decisions, published, _place, _provided)
       when is_map(published),
       do: {:ok, [], %{}}

  defp prepared_selections(ctx, decisions, nil, place, provided),
    do: resolve_selections(ctx, decisions, place, provided)

  # What each node of the closure provides for each of its dependencies
  # (`BlobBuilder.provided/3`), by edge, holding only the edges it covers.
  # A dependency edge holds one credential, so a node providing two of a
  # dependency's needs cannot be granted. A public twin's provided
  # configuration is its owner's, carried in its nodes.
  defp provided_edges(_ctx, _place, published) when is_map(published), do: {:ok, %{}}

  defp provided_edges(_ctx, %{graph: graph, rows: rows}, nil) do
    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn from, {:ok, acc} ->
      case node_row_manifest(rows, from) do
        {:ok, _row, manifest} ->
          manifest
          |> BlobBuilder.dep_edges(graph, from)
          |> Enum.sort()
          |> Enum.reduce_while({:ok, acc}, fn dep, {:ok, acc} ->
            case edge_provided(rows, manifest, dep) do
              %{covered: []} ->
                {:cont, {:ok, acc}}

              %{covered: [{need, resource}]} ->
                {:cont, {:ok, Map.put(acc, {from, dep}, %{need: need, resource: resource})}}

              %{covered: [{one, _}, {other, _} | _]} ->
                {:halt, {:error, one_credential(dep, one, other)}}
            end
          end)
          |> case do
            {:ok, acc} -> {:cont, {:ok, acc}}
            error -> {:halt, error}
          end

        _unreadable ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp edge_provided(rows, from_manifest, dep) do
    case node_row_manifest(rows, dep) do
      {:ok, _row, dep_manifest} -> BlobBuilder.provided(from_manifest, dep, dep_manifest)
      _unreadable -> %{covered: [], unprovidable: []}
    end
  end

  defp one_credential(dep, one, other) do
    {:invalid_argument,
     "#{dep} takes one credential on its edge; this app provides #{one} and #{other}"}
  end

  # Each selection names a dependency of the closure and fills its edge:
  # by label, with what one of its active owner profiles binds on its
  # ingress, the binding digest pinned from that live entry, so a rebind
  # of the lender after this commit leaves the selection unresolved
  # rather than lending a differently shaped credential; or with an entry
  # chosen here for one of the dependency's credential needs, bound on
  # the edge itself and held to that need as a binding of the source is.
  # Each carries its lifetime and `renew`, and an entry chosen here may
  # ride beside the edge's default under an account name. Answers the
  # selections and the entries they bind, by id, for the preview.
  defp resolve_selections(ctx, decisions, place, provided) do
    decisions
    |> Map.get(:selections, [])
    |> Enum.reduce_while({:ok, [], %{}}, fn raw, {:ok, acc, entries} ->
      case resolve_selection(ctx, raw, place, provided) do
        {:ok, selection, lent} -> {:cont, {:ok, [selection | acc], Map.merge(entries, lent)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, selections, entries} ->
        selections = Enum.reverse(selections)
        with :ok <- check_selection_slots(selections), do: {:ok, selections, entries}

      error ->
        error
    end
  end

  defp resolve_selection(ctx, raw, place, provided) do
    with {:ok, from, dep} <- selection_target(raw, place),
         subject = "The selection of #{dep}",
         {:ok, name} <- selection_name(raw, dep),
         {:ok, lifetime} <- decided_lifetime(raw, subject, place.now),
         {:ok, renew} <- decided_renew(raw, subject),
         {:ok, lent} <- selection_lent(raw, dep) do
      case lent do
        {:label, label} ->
          with :ok <- named_by_entry(name, dep),
               :ok <- no_need(raw, dep, label),
               :ok <-
                 not_provided(Map.get(provided, {from, dep}), dep, nil, "its #{label} profile"),
               {:ok, selection} <- lender_selection(ctx, raw, {from, dep, place}, label) do
            {:ok, Map.merge(selection, %{lifetime: lifetime, renew: renew}), %{}}
          end

        {source, id} ->
          with {:ok, selection, entries} <-
                 entry_selection(
                   ctx,
                   raw,
                   {from, dep, place},
                   {source, id},
                   %{lifetime: lifetime, renew: renew, provided: Map.get(provided, {from, dep})}
                 ) do
            {:ok, Prima.MapUtil.put_present(selection, :name, name), entries}
          end
      end
    end
  end

  # The account a selection rides under beside its edge's default: absent
  # for the default itself.
  defp selection_name(raw, dep) do
    case Map.get(raw, :name) do
      nil ->
        {:ok, nil}

      name ->
        if Prima.Authority.Blob.valid_account_name?(name),
          do: {:ok, name},
          else:
            {:error,
             {:invalid_argument,
              "The selection of #{dep} names an account that is not 1 to 128 bytes of text " <>
                "without a | or a control character"}}
    end
  end

  # The blob holds named accounts beside a bound entry alone, so an account
  # names the entry it binds; a label, or nothing at all, lends.
  defp named_by_entry(nil, _dep), do: :ok

  defp named_by_entry(name, dep),
    do:
      {:error,
       {:invalid_argument,
        "The selection of #{dep} names the account #{name} by a profile's label; a named " <>
          "account names an entry"}}

  # A dependency's edge takes one default, which names no account, and any
  # number of named accounts beside it, each under a name of its own; all
  # of them fill the default's need, since an edge carries one need's
  # credentials, and the default is an entry chosen here, since the blob
  # holds named accounts beside a bound entry alone. A second default is
  # the commit digest's refusal: the edge is selected twice.
  defp check_selection_slots(selections) do
    selections
    |> Enum.group_by(&{&1.from, &1.dep})
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {{_from, dep}, on_edge} ->
      case edge_slots(dep, on_edge) do
        :ok -> nil
        refusal -> refusal
      end
    end)
  end

  defp edge_slots(dep, on_edge) do
    {unnamed, named} = Enum.split_with(on_edge, &is_nil(Map.get(&1, :name)))
    repeated = repeated_account(named)

    cond do
      named == [] or length(unnamed) > 1 ->
        :ok

      unnamed == [] ->
        {:error,
         {:invalid_argument,
          "The selections of #{dep} name accounts beside no default; one selection of #{dep} " <>
            "names no account"}}

      match?([%{kind: :via}], unnamed) ->
        [%{label: label}] = unnamed

        {:error,
         {:invalid_argument,
          "The selections of #{dep} name accounts beside a key its #{label} profile lends; a " <>
            "named account sits beside a default entry chosen here"}}

      repeated != nil ->
        {:error, {:invalid_argument, named_twice("The selections of #{dep}", "Select", repeated)}}

      other = Enum.find(named, &(&1.need != hd(unnamed).need)) ->
        {:error,
         {:invalid_argument,
          "The selections of #{dep} name accounts for #{other.need} beside a default for " <>
            "#{hd(unnamed).need}; an edge carries one need's credentials"}}

      true ->
        :ok
    end
  end

  # What the selection lends from: at most one of a label, an entry and
  # an instance entry, a label "default" when it names none.
  defp selection_lent(raw, dep) do
    case Enum.filter([:label, :entry_id, :instance_entry_id], &(Map.get(raw, &1) != nil)) do
      [] ->
        {:ok, {:label, "default"}}

      [:label] ->
        {:ok, {:label, Map.get(raw, :label)}}

      [key] ->
        case Map.get(raw, key) do
          id when is_binary(id) and id != "" -> {:ok, {source_of(key), id}}
          _ -> {:error, {:invalid_argument, "The selection of #{dep} names an empty #{key}"}}
        end

      _several ->
        {:error,
         {:invalid_argument,
          "The selection of #{dep} names at most one of label, entry_id and instance_entry_id"}}
    end
  end

  defp source_of(:entry_id), do: :own
  defp source_of(:instance_entry_id), do: :instance

  # A label selection lends what its profile binds, for whichever need
  # that is: it names none.
  defp no_need(raw, dep, label) do
    if Map.get(raw, :need) == nil,
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "The selection of #{dep} by its #{label} profile names a need; a label selection " <>
            "lends what that profile binds and names none"}}
  end

  # A dependency's edge holds one credential: a need the calling node
  # provides takes no selection, and a selection beside configuration
  # provided for another need would fill the edge twice.
  defp not_provided(nil, _dep, _need, _what), do: :ok

  defp not_provided(%{need: need}, dep, need, _what),
    do:
      {:error,
       {:invalid_argument, "#{dep}'s need #{need} is provided by this app; it takes no selection"}}

  defp not_provided(%{need: provided}, dep, _need, what),
    do: {:error, one_credential(dep, provided, what)}

  defp lender_selection(ctx, raw, {from, dep, %{graph: graph, rows: rows}}, label) do
    with {:ok, profile} <- lender_profile(ctx, dep, label),
         {:ok, bound} <- lender_binding(ctx, profile),
         {:ok, entry} <- lent_entry(ctx, bound, {dep, profile.label}, {graph, rows}),
         {:ok, lent} <- lent_fields(bound, dep, profile.label),
         {:ok, fields} <- selected_fields(raw, lent, dep) do
      {:ok,
       %{
         kind: :via,
         from: from,
         dep: dep,
         label: profile.label,
         profile_id: profile.id,
         binding_digest: entry.digest,
         source: entry.source,
         entry_id: entry.id,
         entry_name: entry.name,
         provider: entry.provider,
         # Where the lent entry may go and whether it is disclosed are the
         # lender's entry's, read from its row.
         destination: entry.destination,
         disclosed: entry.disclosed,
         fields: fields,
         lent_fields: lent,
         # The selection names no scopes, so the lender's reach the edge.
         lent_scopes: Map.get(bound.projection, :scopes) || [],
         # The need the lent entry fills, when the dependency declares one
         # credential need to name.
         declared_need: single_credential_need(rows, dep)
       }}
    end
  end

  # The entry the lender's binding names, live, by its scope: the
  # athanor's own, active at the digest the lender bound; or an instance
  # entry, as the borrowing person is offered it
  # (`Sanctum.InstanceEntries.binding/2`), at the digest the lender bound
  # and admitted on the dependency node by its component policy, which the
  # attach path checks again at each request.
  defp lent_entry(ctx, %{scope: "instance"} = bound, {dep, label}, {graph, rows}) do
    with {:ok, view} <- lent_instance(ctx, bound.entry_id, dep),
         :ok <- check_lender_digest(view.binding_digest || "", bound, dep, label),
         :ok <-
           check_admission(
             ctx,
             %{source: "instance", policy: view},
             dep,
             Plan.node_facts(dep, graph, rows)
           ),
         {:ok, destination} <-
           bound_destination(%{source: "instance", id: view.id, destination: view.destination}) do
      {:ok,
       %{
         source: "instance",
         id: view.id,
         name: view.name,
         provider: view.provider_hint,
         digest: view.binding_digest,
         destination: destination,
         disclosed: false
       }}
    end
  end

  defp lent_entry(ctx, bound, {dep, label}, _closure) do
    with {:ok, entry} <- fetch_active_entry(ctx, bound.entry_id),
         {:ok, live_digest} <- VaultReader.binding_digest(entry),
         :ok <- check_lender_digest(live_digest, bound, dep, label),
         {:ok, destination} <- BlobBuilder.entry_destination(entry) do
      {:ok,
       %{
         source: "own",
         id: entry.id,
         name: entry.name,
         provider: entry.provider_hint,
         digest: live_digest,
         destination: destination,
         disclosed: not entry.attach_only
       }}
    end
  end

  defp lent_instance(ctx, id, dep) do
    case Sanctum.InstanceEntries.binding(ctx, id) do
      {:ok, view} -> {:ok, view}
      {:error, :not_offered} -> {:error, {:not_offered, dep}}
      {:error, {:entry_unavailable, status}} -> {:error, {:entry_unavailable, id, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp single_credential_need(rows, dep) do
    with {:ok, _row, manifest} <- node_row_manifest(rows, dep),
         declared when is_list(declared) <- Prima.Manifest.Needs.from_manifest(manifest),
         [need] <- Enum.filter(declared, &(&1.kind in ~w(api_key oauth bundle))) do
      need
    else
      _ -> :unknown
    end
  end

  # An entry chosen for one of the dependency's credential needs, bound on
  # the edge as a binding of that need is on the source: the need's kind
  # and provider, its disclosure, the offer and the component policy read
  # against the dependency, under the need's projection narrowed by the
  # selection's fields.
  defp entry_selection(ctx, raw, {from, dep, place}, target, decided) do
    with {:ok, _row, dep_manifest} <- node_row_manifest(place.rows, dep),
         {:ok, need, declared_need} <- selected_need(raw, dep, dep_manifest),
         :ok <- not_provided(decided.provided, dep, need, "#{need}"),
         {:ok, fields} <- binding_list(raw, :fields, declared_need, need),
         {:ok, scopes} <- binding_list(%{}, :scopes, declared_need, need),
         {:ok, bound} <- fetch_bound(ctx, target, need),
         :ok <- check_match(bound, declared_need, need),
         :ok <- check_disclosure(bound, declared_need, need),
         :ok <- check_admission(ctx, bound, need, Plan.node_facts(dep, place.graph, place.rows)),
         {:ok, fields, scopes} <- named_projection(declared_need, fields, scopes, bound, need),
         :ok <- check_scope_projection(bound, scopes),
         {:ok, destination} <- bound_destination(bound) do
      selection = %{
        kind: :entry,
        from: from,
        dep: dep,
        need: need,
        declared_need: declared_need,
        source: bound.source,
        entry_id: bound.id,
        binding_digest: bound.digest,
        scope: bound.scope,
        destination: destination,
        attach: attach_rule(declared_need),
        fields: fields,
        scopes: scopes,
        lifetime: decided.lifetime,
        renew: decided.renew
      }

      {:ok, selection, %{bound.id => bound.entry}}
    end
  end

  # The dependency's credential need an entry is chosen for: the one it
  # names, or the dependency's one credential need when it names none —
  # the `@ingress` slot when the dependency declares no needs at all.
  defp selected_need(raw, dep, dep_manifest) do
    declared = Prima.Manifest.Needs.from_manifest(dep_manifest)

    credential =
      for need <- declared || [], need.kind in ~w(api_key oauth bundle), do: need

    case {Map.get(raw, :need), declared, credential} do
      {nil, nil, _} ->
        {:ok, Prima.Authority.Blob.ingress_key(), nil}

      {nil, _declared, [need]} ->
        {:ok, need.name, need}

      {nil, _declared, []} ->
        {:error, {:unknown_need, Prima.Authority.Blob.ingress_key()}}

      {nil, _declared, several} ->
        # A grant re-issuing a head's selection knows the rule the edge
        # attaches by, and with it the one need of several it was for.
        case Enum.filter(several, &(attach_rule(&1) == Map.get(raw, :head_attach))) do
          [need] when is_map_key(raw, :head_attach) ->
            {:ok, need.name, need}

          _ambiguous ->
            {:error,
             {:invalid_argument,
              "The selection of #{dep} names no need, and #{dep} declares several; name the " <>
                "need the entry is for"}}
        end

      {name, _declared, credential} ->
        case Enum.find(credential, &(&1.name == name)) do
          nil -> {:error, {:unknown_need, name}}
          need -> {:ok, name, need}
        end
    end
  end

  defp selection_target(raw, %{graph: graph, source_ref: source_ref, rows: rows}) do
    with {:ok, dep} <- Plan.name_ref(Map.get(raw, :dep) || ""),
         {:ok, from} <- selection_from(raw, source_ref),
         true <- Map.has_key?(graph, from),
         {:ok, _row, manifest} <- node_row_manifest(rows, from),
         true <- dep in BlobBuilder.dep_edges(manifest, graph, from) do
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

  # A closure node's row and manifest at the release the closure resolved
  # (`Plan.closure_rows/3`): a dependency its dependent pins is read at
  # that version, never at its latest.
  defp node_row_manifest(rows, node_key) do
    case Map.fetch(rows, node_key) do
      {:ok, row} -> {:ok, row, manifest(row, node_key)}
      :error -> {:error, :not_in_closure}
    end
  end

  # A public twin carries its owner's grant node for node, and each node
  # is read at the release the current closure resolved: an owner whose
  # grant names a node this release no longer runs is granted again
  # before it is published, never published with a grant for code that
  # does not run.
  defp check_published_nodes(nil, _rows, _source_ref), do: :ok

  defp check_published_nodes(%{nodes: nodes}, rows, source_ref) do
    case nodes |> Map.keys() |> Enum.sort() |> Enum.reject(&Map.has_key?(rows, &1)) do
      [] ->
        :ok

      [node | _] ->
        {:error,
         {:invalid_argument,
          "The owner profile's grant names #{node}, which this release of #{source_ref} no " <>
            "longer runs; grant the owner profile again, then publish"}}
    end
  end

  defp resolve_closure_rows(ctx, component, activation) do
    case Plan.closure_rows(ctx, component, activation.graph) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:activation_unresolvable, reason}}
    end
  end

  # The dependency's lending profile of `label`, its profiles read as the
  # plan reads them (`Plan.lender_profiles/2`): a damaged row of the
  # dependency refuses `{:lender_corrupt, dep, id}`, and a store that
  # cannot answer `{:lender_unavailable, dep}`, never a profile that does
  # not exist; no active owner profile of that label is
  # `{:selection_profile_unavailable, dep, label}`.
  defp lender_profile(ctx, dep, label) when is_binary(label) do
    with {:ok, profiles} <- Plan.lender_profiles(Context.actor(ctx), dep) do
      case Enum.find(profiles, &(&1.label == label and &1.kind == :owner)) do
        %{status: :active} = profile -> {:ok, profile}
        _absent_or_inactive -> {:error, {:selection_profile_unavailable, dep, label}}
      end
    end
  end

  defp lender_profile(_ctx, dep, label),
    do: {:error, {:selection_profile_unavailable, dep, label}}

  # What the lender's head binds on its own ingress, read as a selection
  # reads its lender (`Sanctum.Consent.Loader`): a head that does not
  # decode, or whose bytes fail their digest or do not parse
  # (`Sanctum.Consent.Loader.head_blob/1`), is a damaged lender, and a
  # head the store could not answer is a lender that cannot be read; a
  # selection recorded over either would be a grant made over a lender the
  # run refuses. A head that is missing, or whose ingress binds no entry,
  # lends nothing.
  defp lender_binding(ctx, profile) do
    dep = profile.source_ref
    unbound = {:error, {:selection_unbound, dep, profile.label}}

    case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id) do
      {:ok, head} ->
        case Sanctum.Consent.Loader.head_blob(head) do
          {:ok, blob} -> ingress_binding(blob, dep, unbound)
          {:error, _damaged} -> {:error, {:lender_corrupt, dep, profile.id}}
        end

      {:error, absent} when absent in [:not_found, :no_head] ->
        unbound

      {:error, {:invalid_stored_value, _}} ->
        {:error, {:lender_corrupt, dep, profile.id}}

      {:error, _unanswered} ->
        {:error, {:lender_unavailable, dep}}
    end
  end

  defp ingress_binding(blob, dep, unbound) do
    with {:ok, ingress} <- Prima.Authority.Blob.ingress(blob, dep),
         %{entry_id: _} = vault <- ingress.vault do
      {:ok, vault}
    else
      _lends_nothing -> unbound
    end
  end

  defp check_lender_digest(live, %{binding_digest: bound}, dep, label) do
    if Plug.Crypto.secure_compare(live, bound),
      do: :ok,
      else: {:error, {:selection_unbound, dep, label}}
  end

  # A lender lends the projection its own edge names: the fields of a key
  # or a bundle, or the scopes of an OAuth binding, which name no field and
  # reach the borrower's edge whole. An edge that names neither lends
  # nothing.
  defp lent_fields(%{projection: %{} = projection}, dep, label) do
    case {Map.get(projection, :fields) || [], Map.get(projection, :scopes) || []} do
      {[], []} -> {:error, {:selection_unbound, dep, label}}
      {fields, _scopes} -> {:ok, fields}
    end
  end

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

    lifetimes = Map.new(owner_consent.vault_refs, &{&1.binding_key, &1.lifetime_kind})

    with {:ok, %{"canonical" => "jcs-1", "nodes" => nodes}} <-
           Jason.decode(owner_consent.resolved_policy),
         :ok <- publishable(nodes, need_ids, lifetimes) do
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
      {:error, {:invalid_argument, _sentence}} = refusal -> refusal
      {:error, reason} -> {:error, {:unpublishable_owner_blob, reason}}
    end
  end

  # A public profile's callers are anonymous, so it keeps of a binding
  # only what it can carry without widening: an athanor's entry bound
  # standing. A kept edge whose binding is an instance entry, carries
  # named accounts, or lives `until` a time or `once` is refused, never
  # dropped in silence.
  defp publishable(nodes, need_ids, lifetimes) do
    Enum.find_value(Enum.sort(nodes), :ok, fn {_node_key, node} ->
      Enum.find_value(Enum.sort(node["edges"] || %{}), fn {edge_key, edge} ->
        with %{"entry_id" => _} = vault <- Map.get(edge, "vault"),
             true <- edge_key in need_ids,
             {:error, _} = refusal <- publishable_vault(vault, edge_key, lifetimes) do
          refusal
        else
          _ -> nil
        end
      end)
    end)
  end

  defp publishable_vault(%{"scope" => "instance"}, edge_key, _lifetimes),
    do:
      publish_refusal(
        edge_key,
        "binds an instance entry: an instance entry is offered to people, and a public " <>
          "profile's callers are anonymous"
      )

  defp publishable_vault(%{"named" => %{} = named}, edge_key, _lifetimes) when named != %{},
    do:
      publish_refusal(
        edge_key,
        "binds named accounts beside its default, which a public profile cannot carry"
      )

  defp publishable_vault(vault, edge_key, lifetimes) do
    case Map.get(lifetimes, vault["binding_key"], "standing") do
      "standing" ->
        :ok

      kind ->
        publish_refusal(
          edge_key,
          "binds its entry #{kind}, and a public profile keeps a standing binding alone"
        )
    end
  end

  defp publish_refusal(edge_key, why),
    do: {:error, {:invalid_argument, "The public profile cannot keep #{edge_key}: it #{why}"}}

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
    # profile's entry: a selection never publishes. Provided configuration
    # is public by its publisher's declaration and is kept.
    edge = Map.delete(edge, "tool_servers")

    case Map.get(edge, "vault") do
      %{"entry_id" => _} -> if edge_key in need_ids, do: edge, else: Map.delete(edge, "vault")
      %{"provided" => _} -> edge
      _ -> Map.delete(edge, "vault")
    end
  end

  defp collect_publish_bindings(ctx, nodes) do
    vaults =
      for {_node_key, node} <- nodes,
          {edge_key, edge} <- node["edges"] || %{},
          %{"entry_id" => _} = vault <- [edge["vault"]],
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
          binding_key: vault["binding_key"],
          entry_id: entry.id,
          binding_digest: live_digest,
          scope: vault["scope"],
          destination: vault["destination"],
          attach: vault["attach"],
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
  defp resolve_bindings(ctx, decisions, declared, place) do
    decisions
    |> Map.get(:bindings, [])
    |> Enum.reduce_while({:ok, [], %{}}, fn raw, {:ok, acc, entries} ->
      case resolve_binding(ctx, raw, declared, place) do
        {:ok, binding, bound} ->
          {:cont, {:ok, [binding | acc], Map.put(entries, bound.id, bound.entry)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings, entries} ->
        with :ok <- check_binding_slots(Enum.reverse(bindings)),
             do: {:ok, Enum.reverse(bindings), entries}

      error ->
        error
    end
  end

  defp resolve_binding(ctx, raw, declared, place) do
    need = Map.get(raw, :need, Prima.Authority.Blob.ingress_key())
    subject = "The binding for #{need}"

    with {:ok, declared_need} <- check_known_need(need, declared),
         {:ok, name} <- binding_name(raw, need),
         {:ok, lifetime} <- decided_lifetime(raw, subject, place.now),
         {:ok, renew} <- decided_renew(raw, subject),
         {:ok, fields} <- binding_list(raw, :fields, declared_need, need),
         {:ok, scopes} <- binding_list(raw, :scopes, declared_need, need),
         :ok <- check_token_grant(declared_need, scopes, need),
         {:ok, target} <- binding_target(raw, need),
         {:ok, bound} <- fetch_bound(ctx, target, need),
         :ok <- check_match(bound, declared_need, need),
         :ok <- check_disclosure(bound, declared_need, need),
         :ok <-
           check_admission(
             ctx,
             bound,
             need,
             Plan.node_facts(place.source_ref, place.graph, place.rows)
           ),
         {:ok, fields, scopes} <- named_projection(declared_need, fields, scopes, bound, need),
         :ok <- check_scope_projection(bound, scopes),
         {:ok, destination} <- bound_destination(bound) do
      binding = %{
        need: need,
        declared_need: declared_need,
        name: name,
        source: bound.source,
        entry_id: bound.id,
        binding_digest: bound.digest,
        scope: bound.scope,
        destination: destination,
        attach: attach_rule(declared_need),
        fields: fields,
        scopes: scopes,
        lifetime: lifetime,
        renew: renew
      }

      {:ok, binding, bound}
    end
  end

  # The ingress edge carries one need's bindings: one default, which names
  # no account, and each other under a name of its own. A name a person
  # would read as another (differing only in case) is that name again.
  # Bindings of two needs are refused naming every need bound, so the
  # person can pick one.
  defp check_binding_slots([]), do: :ok

  defp check_binding_slots([%{need: need} | _] = bindings) do
    {unnamed, named} = Enum.split_with(bindings, &is_nil(&1.name))
    repeated = repeated_account(named)
    needs = bindings |> Enum.map(& &1.need) |> Enum.uniq() |> Enum.sort()

    cond do
      length(needs) > 1 ->
        {:error,
         {:invalid_argument,
          "The app's own calls carry one need's credentials: " <> bind_one_of(needs)}}

      length(unnamed) > 1 ->
        {:error,
         {:invalid_argument,
          "Two bindings for #{need} name no account; one is the default and each other " <>
            "names its account"}}

      unnamed == [] ->
        {:error,
         {:invalid_argument,
          "The bindings for #{need} name accounts beside no default; one binding of " <>
            "#{need} names no account"}}

      repeated != nil ->
        {:error, {:invalid_argument, named_twice("The bindings for #{need}", "Bind", repeated)}}

      true ->
        :ok
    end
  end

  # The first two of `named` that name one account, as account names
  # compare (`Prima.Authority.Blob.same_account_name?/2`): their names as
  # given, in the order given; nil when each names its own.
  defp repeated_account(named) do
    named
    |> Enum.with_index(1)
    |> Enum.find_value(fn {one, i} ->
      named
      |> Enum.drop(i)
      |> Enum.find(&Prima.Authority.Blob.same_account_name?(&1.name, one.name))
      |> case do
        nil -> nil
        other -> {one.name, other.name}
      end
    end)
  end

  # A repeated account, as `subject` (the bindings of a need, or the
  # selections of a dependency) named it. Spelled alike, the name; spelled
  # two ways, both spellings as given and that they are one account: the
  # home decides which names are one account, and a command line folding
  # on other Unicode tables may send two spellings of one as two.
  defp named_twice(subject, _verb, {name, name}),
    do: "#{subject} name the account #{name} twice; each names its own"

  defp named_twice(subject, verb, {one, other}),
    do:
      "#{subject} name one account twice, as \"#{one}\" and \"#{other}\": names that " <>
        "differ only in letter case are the same account. #{verb} it once, under one of " <>
        "the two."

  defp bind_one_of([one, other]), do: "bind #{one} or #{other}, not both"

  defp bind_one_of(needs) do
    {init, [last]} = Enum.split(needs, -1)
    "bind one of #{Enum.join(init, ", ")} or #{last}"
  end

  # An account name a named binding rides under: absent for the default.
  defp binding_name(raw, need) do
    case Map.get(raw, :name) do
      nil ->
        {:ok, nil}

      name ->
        if Prima.Authority.Blob.valid_account_name?(name),
          do: {:ok, name},
          else:
            {:error,
             {:invalid_argument,
              "The binding for #{need} names an account that is not 1 to 128 bytes of text " <>
                "without a | or a control character"}}
    end
  end

  # What a binding binds: exactly one of the athanor's entry and an
  # instance entry.
  defp binding_target(raw, need) do
    case {Map.get(raw, :entry_id), Map.get(raw, :instance_entry_id)} do
      {id, nil} when is_binary(id) and id != "" ->
        {:ok, {:own, id}}

      {nil, id} when is_binary(id) and id != "" ->
        {:ok, {:instance, id}}

      _neither_or_both ->
        {:error,
         {:invalid_argument,
          "The binding for #{need} names exactly one of entry_id and instance_entry_id"}}
    end
  end

  # A lifetime as the decision names it: standing when it names none,
  # `until` an RFC 3339 instant in UTC strictly after `now` and at most a
  # day after it, or `once`. Preview and commit each read their own clock,
  # so an `until` that passed between them is refused at commit.
  @max_until_seconds 24 * 60 * 60
  @lifetime_kinds ~w(standing until once)

  defp decided_lifetime(raw, subject, now) do
    case Map.get(raw, :lifetime) do
      nil ->
        {:ok, %{kind: "standing", until: nil}}

      %{} = lifetime when not is_struct(lifetime) ->
        kind = lifetime_kind(Map.get(lifetime, :kind))
        until = Map.get(lifetime, :until)

        cond do
          Map.keys(lifetime) -- [:kind, :until] != [] ->
            lifetime_refusal(subject, "names a lifetime of only a kind and an until")

          kind not in @lifetime_kinds ->
            lifetime_refusal(subject, "names a lifetime that is not standing, until or once")

          kind != "until" and until != nil ->
            lifetime_refusal(subject, "names an until for a #{kind} lifetime")

          kind != "until" ->
            {:ok, %{kind: kind, until: nil}}

          true ->
            until_instant(until, subject, now)
        end

      _other ->
        lifetime_refusal(subject, "names a lifetime that is not a record of kind and until")
    end
  end

  defp lifetime_kind(kind) when is_atom(kind) and not is_nil(kind), do: Atom.to_string(kind)
  defp lifetime_kind(kind), do: kind

  defp until_instant(until, subject, now) when is_binary(until) do
    utc? = String.ends_with?(until, "Z") or String.ends_with?(until, "+00:00")

    case DateTime.from_iso8601(until) do
      {:ok, instant, 0} when utc? ->
        instant = DateTime.truncate(instant, :microsecond)

        cond do
          DateTime.compare(instant, now) != :gt ->
            lifetime_refusal(subject, "names an until that is not after now")

          DateTime.diff(instant, now, :microsecond) > @max_until_seconds * 1_000_000 ->
            lifetime_refusal(subject, "names an until more than 24 hours from now")

          true ->
            {:ok, %{kind: "until", until: instant}}
        end

      _not_utc ->
        lifetime_refusal(subject, "names an until that is not an RFC 3339 instant in UTC")
    end
  end

  defp until_instant(_until, subject, _now),
    do: lifetime_refusal(subject, "names an until lifetime without its instant")

  defp lifetime_refusal(subject, why), do: {:error, {:invalid_argument, "#{subject} #{why}"}}

  defp decided_renew(raw, subject) do
    case Map.get(raw, :renew, false) do
      renew when is_boolean(renew) -> {:ok, renew}
      _other -> {:error, {:invalid_argument, "#{subject} names renew as neither true nor false"}}
    end
  end

  # The entry a binding names, live: the athanor's own, active, at the
  # digest its row derives; or an instance entry offered to the person and
  # active (`Sanctum.InstanceEntries.binding/2`), at the digest it stands
  # at. Nothing is unsealed.
  defp fetch_bound(ctx, {:own, id}, _need) do
    with {:ok, entry} <- fetch_active_entry(ctx, id),
         {:ok, digest} <- VaultReader.binding_digest(entry) do
      {:ok,
       %{
         source: "own",
         id: entry.id,
         entry: entry,
         digest: digest,
         scope: "athanor",
         kind: entry.kind,
         provider: entry.provider_hint,
         disclosed: not entry.attach_only,
         field_names: stored_list(entry.field_names),
         oauth_scopes: stored_list(entry.oauth_scopes),
         destination: Map.get(entry, :destination)
       }}
    end
  end

  defp fetch_bound(ctx, {:instance, id}, need) do
    case Sanctum.InstanceEntries.binding(ctx, id) do
      {:ok, view} ->
        {:ok,
         %{
           source: "instance",
           id: view.id,
           entry: Map.put(view, :attach_only, true),
           digest: view.binding_digest,
           scope: "instance",
           kind: view.kind,
           provider: view.provider_hint,
           disclosed: false,
           policy: view,
           field_names: [],
           oauth_scopes: view.oauth_scopes,
           destination: view.destination
         }}

      {:error, :not_offered} ->
        {:error, {:not_offered, need}}

      {:error, {:entry_unavailable, status}} ->
        {:error, {:entry_unavailable, id, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An entry meets a declared need of its kind whose qualifier is the
  # entry's provider. The `@ingress` slot of a manifest declaring no needs
  # names neither.
  defp check_match(_bound, nil, _need), do: :ok

  defp check_match(bound, declared_need, need) do
    if bound.kind == declared_need.kind and bound.provider == declared_need.qualifier,
      do: :ok,
      else: {:error, {:provider_mismatch, need}}
  end

  # A need the component reads itself takes a disclosed entry of the
  # athanor; an instance entry is never disclosed.
  defp check_disclosure(bound, declared_need, need) do
    reads_itself? =
      declared_need == nil or Prima.Manifest.Needs.disclose_only?(declared_need) or
        Map.get(declared_need, :disclose) == true

    if reads_itself? and not bound.disclosed,
      do: {:error, {:disclosure_refused, need}},
      else: :ok
  end

  # An instance entry is bound on a node only where its stored component
  # policy admits that node, read at the node's release digest in the
  # closure.
  defp check_admission(ctx, %{source: "instance"} = bound, need, facts) do
    if Sanctum.InstanceEntries.admits?(ctx, bound.policy, facts),
      do: :ok,
      else: {:error, {:component_not_admitted, need}}
  end

  defp check_admission(_ctx, _bound, _need, _facts), do: :ok

  defp bound_destination(%{source: "own", entry: entry}), do: BlobBuilder.entry_destination(entry)

  defp bound_destination(%{source: "instance", id: id, destination: %{} = map}) do
    case Prima.Destination.from_map(map) do
      {:ok, destination} -> {:ok, Prima.Destination.to_map(destination)}
      {:error, _} -> {:error, {:entry_unavailable, id, :destination}}
    end
  end

  defp bound_destination(%{id: id}), do: {:error, {:entry_unavailable, id, :destination}}

  # The need's attach rule as the blob carries it: nil for a disclose-only
  # need, and for the `@ingress` binding of a manifest that declares none.
  defp attach_rule(%{attach: %{} = rule}), do: Prima.Manifest.Needs.attach_to_map(rule)
  defp attach_rule(_declared_need), do: nil

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
  defp named_projection(nil, [], [], bound, need) do
    fields = bound.field_names
    scopes = if bound.kind == "oauth", do: bound.oauth_scopes, else: []

    if fields == [] and scopes == [],
      do: {:error, empty_projection(need, :fields)},
      else: {:ok, fields, scopes}
  end

  defp named_projection(_declared_need, fields, scopes, _bound, _need),
    do: {:ok, fields, scopes}

  # An OAuth projection is held to what its entry can dispense, here and
  # not first at a run: scopes the entry lacks are refused as the reader
  # refuses them, and fewer than it holds only where its provider
  # attenuates a refresh (`Sanctum.Vault.OAuth.attenuates_scope?/1`), since
  # otherwise the person would be shown a narrowing no token honours.
  defp check_scope_projection(%{kind: "oauth"} = bound, [_ | _] = scopes) do
    held = bound.oauth_scopes |> Enum.uniq() |> Enum.sort()
    projected = scopes |> Enum.uniq() |> Enum.sort()

    case projected -- held do
      [] when projected == held ->
        :ok

      [] ->
        if Sanctum.Vault.OAuth.attenuates_scope?(bound.provider),
          do: :ok,
          else: {:error, :scope_not_attenuable}

      missing ->
        {:error, {:scope_projection_unsatisfiable, missing}}
    end
  end

  defp check_scope_projection(_entry, _scopes), do: :ok

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
         {origins, subset, removed},
         bindings,
         selections,
         tool_servers,
         decisions
       ) do
    {:ok,
     %{
       # What the person is shown the revision drops from the head; the
       # head itself is pinned by the expected revision the proof binds.
       removed: removed,
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
       # A binding's scope, destination and attach rule are the blob's,
       # which the blob digest above covers; the decision is what the
       # person chose: the entry or instance entry, the account it rides
       # under, its projection, its lifetime and whether it renews.
       bindings: Enum.map(bindings, &digest_binding/1),
       selections: Enum.map(selections, &digest_selection/1),
       tool_servers:
         Enum.map(tool_servers, &Map.take(&1, [:server_name, :server_digest, :tool_patterns])),
       override: Map.get(decisions, :override, false),
       subset: subset
     }}
  end

  defp digest_binding(binding) do
    binding
    |> Map.take([:need, :binding_digest, :fields, :scopes, :name, :renew])
    |> Map.put(entry_key(binding), binding.entry_id)
    |> Map.put(:lifetime, digest_lifetime(Map.get(binding, :lifetime)))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # A label selection names its label, an entry selection the entry, the
  # need it is chosen for and the account it rides under, if any; both
  # their projection and lifetime.
  defp digest_selection(%{kind: :via} = selection) do
    selection
    |> Map.take([:from, :dep, :label, :binding_digest, :fields, :renew])
    |> Map.put(:lifetime, digest_lifetime(Map.get(selection, :lifetime)))
  end

  defp digest_selection(selection) do
    selection
    |> Map.take([:from, :dep, :need, :binding_digest, :fields, :renew])
    |> Map.put(entry_key(selection), selection.entry_id)
    |> Map.put(:lifetime, digest_lifetime(Map.get(selection, :lifetime)))
    |> Prima.MapUtil.put_present(:name, Map.get(selection, :name))
  end

  defp entry_key(%{scope: "instance"}), do: :instance_entry_id
  defp entry_key(_athanor), do: :entry_id

  defp digest_lifetime(%{kind: "until", until: %DateTime{} = until}),
    do: %{kind: "until", until: DateTime.to_iso8601(until)}

  defp digest_lifetime(%{kind: kind}), do: %{kind: kind}
  defp digest_lifetime(nil), do: %{kind: "standing"}

  # ---------------------------------------------------------------------------
  # What the revision removes from the head
  # ---------------------------------------------------------------------------

  # The head's bindings the revision drops, each as the preview carries it
  # (`Prima.ConsentPreview`'s "Removed bindings"), sorted by key: a key the
  # revision no longer binds, or binds for another need. The head is read
  # here at the revision the profile was located at; a head that moved
  # between the two reads is a race, never a list of another head's
  # bindings.
  defp removed_bindings(_ctx, {nil, _expected}, _built), do: {:ok, []}

  defp removed_bindings(ctx, {profile_id, expected}, built) do
    with {:ok, held} <- head_refs(ctx, profile_id, expected),
         {:ok, sources} <- removal_sources(ctx, held) do
      kept = MapSet.new(built.refs, & &1.binding_key)
      reads = {ctx, sources, built}

      held
      |> Enum.sort_by(& &1.binding_key)
      |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
        case removal(reads, ref, kept) do
          :kept -> {:cont, {:ok, acc}}
          {:ok, item} -> {:cont, {:ok, [item | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, items} -> {:ok, Enum.reverse(items)}
        error -> error
      end
    end
  end

  defp head_refs(ctx, profile_id, expected) do
    case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile_id) do
      {:ok, %{revision: ^expected, vault_refs: refs}} -> {:ok, refs}
      {:ok, %{revision: actual}} -> conflict(:race, expected, actual)
      {:error, :no_head} when expected == 0 -> {:ok, []}
      {:error, :no_head} -> conflict(:race, expected, 0)
      {:error, reason} -> {:error, reason}
    end
  end

  # What a head binding's need is told from, read only when the head holds
  # a binding.
  defp removal_sources(_ctx, []), do: {:ok, nil}
  defp removal_sources(ctx, _held), do: Plan.choice_sources(ctx)

  # A head binding is kept when the revision binds its key for the same
  # need, or for a need either side cannot tell; otherwise it is removed.
  defp removal({_ctx, _sources, built} = reads, ref, kept) do
    with {:ok, {node, edge, name}} <- removed_place(ref.binding_key),
         {:ok, identity} <- head_identity(ref) do
      need = head_need(reads, {node, edge}, identity)
      decided = Map.get(built.needs, ref.binding_key)

      if MapSet.member?(kept, ref.binding_key) and
           (is_nil(need) or is_nil(decided) or need == decided) do
        :kept
      else
        {:ok,
         %{"binding_key" => ref.binding_key, "node" => node, "edge" => edge, "need" => need}
         |> Prima.MapUtil.put_present("connection", name)
         |> Map.merge(removed_entry(reads, identity, edge))}
      end
    end
  end

  # A head row's key spells where it sat; one that does not is a row the
  # preview cannot name, and nothing is granted over it.
  defp removed_place(key) do
    case Prima.Authority.Blob.parse_binding_key(key) do
      {:ok, place} -> {:ok, place}
      :error -> {:error, {:preview_unrepresentable, :removed}}
    end
  end

  defp head_identity(%{vault_entry_id: id}) when is_binary(id), do: {:ok, {:own, id}}
  defp head_identity(%{instance_entry_id: id}) when is_binary(id), do: {:ok, {:instance, id}}
  defp head_identity(%{via_label: label}) when is_binary(label), do: {:ok, {:label, label}}
  defp head_identity(_ref), do: {:error, {:preview_unrepresentable, :removed}}

  # The need a head binding was bound for, as the sheet and the command
  # line tell it, or nil. On the app's own calls: the one need whose
  # candidates hold its entry, else the one need there is (the `@ingress`
  # slot of a manifest declaring none). On a dependency's edge: the need
  # the edge names, the dependency's one credential need, or the one of
  # its several whose candidates hold the entry; a lender's label names
  # none of several.
  defp head_need({ctx, sources, built}, {node, "@ingress"}, identity)
       when node == built.source_ref do
    case identity do
      {:label, _label} ->
        nil

      {_source, id} ->
        needs =
          case built.declared do
            nil -> [{Prima.Authority.Blob.ingress_key(), nil}]
            declared -> Enum.map(declared, &{&1.name, &1})
          end

        told(ctx, sources, needs, Plan.node_facts(node, built.graph, built.rows), id)
    end
  end

  defp head_need({ctx, sources, built}, {_node, edge}, identity) do
    with {:ok, dep} <- edge_dep(edge),
         {:ok, _row, manifest} <- node_row_manifest(built.rows, dep),
         [_ | _] = credential <- credential_needs(manifest) do
      case {String.split(edge, "|", parts: 2), credential, identity} do
        {[_dep, named], _credential, _identity} ->
          if Enum.any?(credential, &(&1.name == named)), do: named

        {_bare, [only], _identity} ->
          only.name

        {_bare, _several, {:label, _label}} ->
          nil

        {_bare, several, {_source, id}} ->
          needs = Enum.map(several, &{&1.name, &1})
          told(ctx, sources, needs, Plan.node_facts(dep, built.graph, built.rows), id)
      end
    else
      _ -> nil
    end
  end

  defp edge_dep(edge) do
    case Prima.Authority.Blob.edge_target(edge) do
      {:ok, dep} -> {:ok, dep}
      :ingress -> :error
    end
  end

  defp credential_needs(manifest) do
    for need <- Prima.Manifest.Needs.from_manifest(manifest) || [],
        need.kind in ~w(api_key oauth bundle),
        do: need
  end

  # The one need whose candidates hold the entry, else the only need.
  defp told(ctx, sources, needs, facts, id) do
    holding =
      for {name, declared} <- needs,
          candidate <- Plan.need_choice(ctx, sources, declared, facts).candidates,
          Map.get(candidate, :entry_id) == id or Map.get(candidate, :instance_entry_id) == id,
          uniq: true,
          do: name

    case {holding, needs} do
      {[one], _needs} -> one
      {_none_or_several, [{only, _declared}]} -> only
      _unknown -> nil
    end
  end

  # What a removed binding bound, as its row names it, with the entry's
  # name and source where they can be read: the athanor's entry by its
  # row whatever its status, an instance entry while it is offered to the
  # person, a lender's entry while the lending profile binds one.
  defp removed_entry({ctx, _sources, _built}, {:own, id}, _edge),
    do:
      Prima.MapUtil.put_present(%{"entry_id" => id, "source" => "own"}, "name", own_name(ctx, id))

  defp removed_entry({_ctx, sources, _built}, {:instance, id}, _edge) do
    Prima.MapUtil.put_present(
      %{"instance_entry_id" => id, "source" => "instance"},
      "name",
      offered_name(sources, id)
    )
  end

  defp removed_entry({ctx, sources, _built}, {:label, label}, edge) do
    with {:ok, dep} <- edge_dep(edge),
         {:ok, profiles} <- Arca.ConsentStorage.profiles(Context.actor(ctx), dep),
         %{} = profile <- Enum.find(profiles, &(&1.label == label and &1.kind == :owner)),
         {:ok, bound} <- lender_binding(ctx, profile) do
      {source, name} =
        if bound.scope == "instance",
          do: {"instance", offered_name(sources, bound.entry_id)},
          else: {"own", own_name(ctx, bound.entry_id)}

      Prima.MapUtil.put_present(%{"via" => label, "source" => source}, "name", name)
    else
      # The lender is gone: its entry's name and source cannot be read.
      _ -> %{"via" => label}
    end
  end

  defp own_name(ctx, id) do
    case Arca.VaultStorage.get(Context.actor(ctx), id) do
      {:ok, %{name: name}} -> if Prima.ConsentPreview.Row.text?(name), do: name
      _unreadable -> nil
    end
  end

  defp offered_name(sources, id) do
    case Enum.find(sources.offered, &(&1.id == id)) do
      %{name: name} -> if Prima.ConsentPreview.Row.text?(name), do: name
      nil -> nil
    end
  end

  # The need each binding of the revision is decided for, by its key: the
  # source's bindings and the entries chosen on a dependency's edge, and a
  # lender's selection where the dependency has one credential need. A
  # public twin's bindings are its owner's, decided for no need here.
  defp decided_needs(_source_ref, _bindings, _selections, published) when is_map(published),
    do: %{}

  defp decided_needs(source_ref, bindings, selections, nil) do
    ingress = Prima.Authority.Blob.ingress_key()

    for(
      binding <- bindings,
      into: %{},
      do: {Prima.Authority.Blob.binding_key(source_ref, ingress, binding.name), binding.need}
    )
    |> Map.merge(
      for selection <- selections,
          need = selection_need(selection),
          is_binary(need),
          into: %{} do
        {Prima.Authority.Blob.binding_key(
           selection.from,
           selection.dep,
           Map.get(selection, :name)
         ), need}
      end
    )
  end

  defp selection_need(%{kind: :entry, need: need}), do: need
  defp selection_need(%{kind: :via, declared_need: %{name: name}}), do: name
  defp selection_need(_selection), do: nil

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

  # A published profile's bindings are its owner's, each at the place and
  # under the key the owner's blob gave it: one row per binding.
  defp build_blob(_ctx, %{publish_nodes: nodes} = prep) when is_map(nodes) do
    refs =
      prep.bindings
      |> Enum.map(fn binding ->
        BlobBuilder.ref_row(binding.binding_key, %{
          "entry_id" => binding.entry_id,
          "binding_digest" => binding.binding_digest,
          "scope" => binding.scope
        })
      end)
      |> Enum.uniq_by(& &1.binding_key)

    with {:ok, nodes, narrowed} <- BlobBuilder.narrow_nodes(nodes, prep.source_ref, prep.subset),
         {:ok, blob_json} <- JCS.encode(%{"canonical" => "jcs-1", "nodes" => nodes}),
         :ok <- check_binding_digests(blob_json, prep) do
      {:ok, blob_json, refs, narrowed}
    end
  end

  defp build_blob(ctx, prep) do
    # One need's bindings ride the ingress edge whatever its name —
    # "@ingress" for no-needs manifests, the declared need for manifests
    # with one: the default as the edge's vault, each named account in its
    # `named` map. resolve_bindings already refused a second need. A
    # selected dependency's edge carries the selection, each account named
    # beside it in its `named` map, and an edge whose need the calling node
    # provides carries that configuration.
    source_vault = source_resource(prep.bindings)
    {defaults, named} = Enum.split_with(prep.selections, &is_nil(Map.get(&1, :name)))
    selections = Map.new(defaults, &{{&1.from, &1.dep}, &1})
    named = Enum.group_by(named, &{&1.from, &1.dep})

    vault_fn = fn node_key, _row, _manifest ->
      if node_key == prep.source_ref, do: source_vault
    end

    edge_vault_fn = fn from, dep, _row, _manifest, _provided ->
      case Map.fetch(selections, {from, dep}) do
        {:ok, selection} ->
          selection_resource(selection, Map.get(named, {from, dep}, []))

        :error ->
          case Map.fetch(prep.provided, {from, dep}) do
            {:ok, %{resource: resource}} -> resource
            :error -> nil
          end
      end
    end

    extras =
      case prep.tool_servers do
        [] -> %{}
        grants -> %{"tool_servers" => Enum.map(grants, &tool_server_resource/1)}
      end

    with {:ok, nodes} <-
           BlobBuilder.build(ctx, prep.activation.graph, prep.source_ref, vault_fn,
             rows: prep.closure_rows,
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

  # The bound resource the source's bindings ride as: the default with
  # each named account beside it; its place gives each its key
  # (`BlobBuilder.encode/1`).
  defp source_resource([]), do: nil

  defp source_resource(bindings) do
    {[default], named} = Enum.split_with(bindings, &is_nil(&1.name))
    BlobBuilder.vault_resource(Map.put(default, :named, Enum.sort_by(named, & &1.name)))
  end

  # A lender's label lends alone: an account named beside it is refused by
  # the slot check, or rides an edge selected twice, which the commit
  # digest refuses before anything is written.
  defp selection_resource(%{kind: :via} = selection, _named) do
    BlobBuilder.vault_resource(%{
      via: selection.label,
      binding_digest: selection.binding_digest,
      fields: selection.fields,
      lifetime: selection.lifetime,
      renew: selection.renew
    })
  end

  # An entry chosen here, each account named beside it in the edge's
  # `named` map; its place gives each its key (`BlobBuilder.encode/1`).
  defp selection_resource(%{kind: :entry} = selection, named),
    do: BlobBuilder.vault_resource(Map.put(selection, :named, Enum.sort_by(named, & &1.name)))

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
        # A fresh revision is the re-consent of a profile blocked at
        # needs_consent; it is unblocked inside the revision's transaction,
        # so a revoke blocking it lands before the revision or after it.
        with {:ok, head_id} <- current_head_id(ctx, prep.profile_id) do
          Arca.ConsentStorage.insert_revision(attrs, refs, head_id,
            verify: verify,
            reactivate: true
          )
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

  # Runs inside the insert transaction, after the instance entries it
  # names are locked (`Arca.ConsentStorage`): a vault.rebind, or an
  # instance entry's, that landed after prepare must roll the revision
  # back, not ship a consent that is dead on arrival. Every binding of the
  # source and every entry a selection binds on a dependency's edge is
  # read again, the athanor's entry from its row and an instance entry as
  # the person is offered it.
  defp verify_binding_liveness(ctx, prep) do
    bound = prep.bindings ++ Enum.filter(prep.selections, &(&1[:kind] == :entry))

    Enum.reduce_while(bound, :ok, fn binding, :ok ->
      with {:ok, digest} <- live_digest(ctx, binding),
           true <- Plug.Crypto.secure_compare(digest || "", binding.binding_digest) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:binding_went_stale, binding.entry_id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp live_digest(ctx, %{scope: "instance", entry_id: id}) do
    case Sanctum.InstanceEntries.binding(ctx, id) do
      {:ok, view} -> {:ok, view.binding_digest}
      {:error, {:entry_unavailable, status}} -> {:error, {:entry_unavailable, id, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_digest(ctx, %{entry_id: id}) do
    with {:ok, entry} <- fetch_active_entry(ctx, id), do: VaultReader.binding_digest(entry)
  end

  # ---------------------------------------------------------------------------
  # Rendering + helpers
  # ---------------------------------------------------------------------------

  # The typed rows of what the revision grants, read from the same blob
  # bytes the digest covers: the builder's rows for resources, limits and a
  # tincture's declarations, and the credentials and tool servers only the
  # commit can name.
  defp preview_rows(ctx, prep) do
    with {:ok, nodes} <- blob_nodes_or_bug(prep.blob_json),
         {:ok, granted} <-
           BlobBuilder.grant_rows(prep.source_ref, nodes, prep.narrowed, prep.closure_rows),
         {:ok, sources} <- Plan.choice_sources(ctx),
         {:ok, credentials} <-
           credential_rows(
             {ctx, sources, {prep.activation.graph, prep.closure_rows}},
             prep,
             nodes
           ) do
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
      "commit_digest" => prep.commit_digest,
      "removed" => prep.removed
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

  # One row per binding an edge carries, on the node whose edge carries
  # it: the source for its ingress, the calling node for an edge into a
  # dependency, with the edge's key and the binding's own key, so one
  # entry lent on two edges, or bound under two names, is two rows. A
  # bound entry is named by the entry, the athanor's own or an instance
  # entry, its named accounts each a row naming its `connection`; a
  # selection by the lender's entry and the label of the profile lending
  # it; provided configuration by the need it fills. Each row says the
  # lifetime its binding was decided with, and whether the plan suggests
  # its entry for that need and whether the need asks the person to
  # choose, by the plan's own rule (`Plan.need_choice/4`); destination and
  # disclosure are the entry's, read from its row.
  defp credential_rows(reads, prep, nodes) do
    carried =
      for {from, node} <- Enum.sort(nodes),
          {key, %{"vault" => vault}} <- Enum.sort(node["edges"] || %{}),
          row <- credential_row(reads, prep, edge_place(from, key), vault),
          do: row

    case Enum.find(carried, &match?({:error, _}, &1)) do
      nil ->
        rows = for {:ok, row} <- carried, do: row

        {:ok,
         Enum.sort_by(
           rows,
           &{&1["node"], &1["values"]["name"], &1["values"]["edge"], &1["values"]["binding_key"]}
         )}

      error ->
        error
    end
  end

  defp edge_place(from, key) do
    case Prima.Authority.Blob.edge_target(key) do
      :ingress -> {from, key, from}
      {:ok, dep} -> {from, key, dep}
    end
  end

  defp credential_row(reads, prep, place, %{"entry_id" => _} = vault) do
    named = vault |> Map.get("named", %{}) |> Enum.sort()

    for {slot, bound} <- [{nil, vault} | named] do
      bound_row(reads, prep, place, slot, bound)
    end
  end

  defp credential_row(reads, prep, {from, key, target}, %{"via" => %{"label" => label}} = vault) do
    case Enum.find(prep.selections, &(&1[:kind] == :via and &1.from == from and &1.dep == target)) do
      nil ->
        [{:error, {:preview_unrepresentable, :credential}}]

      selection ->
        fields =
          case projection(vault, "fields") do
            [] -> Enum.sort(selection.lent_fields)
            fields -> fields
          end

        identity =
          if selection.source == "instance",
            do: %{instance_entry_id: selection.entry_id},
            else: %{entry_id: selection.entry_id}

        {suggested, choice_required} =
          choice_values(
            reads,
            Map.get(selection, :declared_need, :unknown),
            {:dep, target},
            identity
          )

        [
          {:ok,
           BlobBuilder.row(
             "credential",
             from,
             %{
               "name" => selection.entry_name,
               "edge" => key,
               "label" => label,
               "fields" => fields,
               "scopes" => Enum.sort(Enum.uniq(selection.lent_scopes)),
               "destination" => selection.destination,
               "source" => selection.source,
               "disclosed" => selection.disclosed,
               "suggested" => suggested,
               "choice_required" => choice_required,
               # The borrower's binding, where the selection sits.
               "binding_key" => Prima.Authority.Blob.binding_key(from, key, nil),
               "lifetime" => lifetime_values(selection.lifetime)
             }
             |> Prima.MapUtil.put_present("provider", selection.provider),
             false
           )}
        ]
    end
  end

  # Configuration the calling node provides: public by its publisher's
  # declaration, so disclosed, standing, and chosen by nobody.
  defp credential_row(_reads, prep, {from, key, target}, %{
         "provided" => provided
       }) do
    [
      {:ok,
       BlobBuilder.row(
         "credential",
         from,
         %{
           "name" => provided_need(prep, from, target),
           "edge" => key,
           "fields" => provided["values"] |> Map.keys() |> Enum.sort(),
           "scopes" => [],
           "destination" => provided["destination"],
           "source" => "provided",
           "disclosed" => true,
           "suggested" => false,
           "choice_required" => false,
           "binding_key" => Prima.Authority.Blob.binding_key(from, key, nil),
           "lifetime" => lifetime_values(nil)
         },
         false
       )}
    ]
  end

  defp credential_row(_reads, _prep, _place, _vault), do: []

  defp bound_row(reads, prep, {from, key, target}, slot, bound) do
    with {:ok, entry} <- Map.fetch(prep.entries, bound["entry_id"]),
         {:ok, decided} <- bound_decision(prep, {from, target}, slot) do
      instance? = bound["scope"] == "instance"
      identity = if instance?, do: %{instance_entry_id: entry.id}, else: %{entry_id: entry.id}

      {suggested, choice_required} =
        choice_values(reads, decided.declared_need, decided.node, identity)

      {:ok,
       BlobBuilder.row(
         "credential",
         from,
         %{
           "name" => entry.name,
           "edge" => key,
           "fields" => projection(bound, "fields"),
           "scopes" => projection(bound, "scopes"),
           "destination" => bound["destination"],
           "source" => if(instance?, do: "instance", else: "own"),
           "disclosed" => not instance? and not entry.attach_only,
           "suggested" => suggested,
           "choice_required" => choice_required,
           "binding_key" => bound["binding_key"],
           "lifetime" => lifetime_values(decided.lifetime)
         }
         |> Prima.MapUtil.put_present("provider", entry.provider_hint)
         |> Prima.MapUtil.put_present("connection", slot),
         false
       )}
    else
      _ -> {:error, {:preview_unrepresentable, :credential}}
    end
  end

  # The decision a bound entry on an edge carries: the source's binding of
  # that slot, wherever its node's resources ride, or the selection made
  # on that dependency edge. A public twin's bindings are its owner's,
  # standing, and no choice of this decision.
  defp bound_decision(prep, {from, target}, slot) do
    cond do
      target == prep.source_ref ->
        case Enum.find(prep.bindings, &(Map.get(&1, :name) == slot)) do
          nil -> :error
          binding -> {:ok, decision_of(binding, {:source, target})}
        end

      selection =
          Enum.find(
            prep.selections,
            &(&1.from == from and &1.dep == target and Map.get(&1, :name) == slot)
          ) ->
        {:ok, decision_of(selection, {:dep, target})}

      is_map(prep.publish_nodes) ->
        {:ok, %{lifetime: nil, declared_need: :unknown, node: {:dep, target}}}

      true ->
        :error
    end
  end

  defp decision_of(item, node) do
    %{
      lifetime: Map.get(item, :lifetime),
      declared_need: Map.get(item, :declared_need, :unknown),
      node: node
    }
  end

  # Whether the plan suggests this entry for the need, and whether the
  # need asks the person to choose, by the plan's rule. A row whose need
  # cannot be named (a lender's need among several, a public twin's
  # binding) says neither.
  defp choice_values(_reads, :unknown, _node, _identity), do: {false, false}

  defp choice_values({ctx, sources, {graph, rows}}, declared_need, {_kind, node_key}, identity) do
    facts = Plan.node_facts(node_key, graph, rows)
    choice = Plan.need_choice(ctx, sources, declared_need, facts)
    {choice.suggested == identity, choice.choice_required}
  end

  defp lifetime_values(%{kind: "until", until: %DateTime{} = until}),
    do: %{"kind" => "until", "until" => DateTime.to_iso8601(until)}

  defp lifetime_values(%{kind: kind}), do: %{"kind" => kind, "until" => nil}
  defp lifetime_values(nil), do: %{"kind" => "standing", "until" => nil}

  # The need a provided resource fills: the one this decision's closure
  # covers, or, on a public twin, the one its owner's node provides.
  defp provided_need(prep, from, dep) do
    case Map.fetch(prep.provided, {from, dep}) do
      {:ok, %{need: need}} ->
        need

      :error ->
        with {:ok, _row, manifest} <- node_row_manifest(prep.closure_rows, from),
             %{covered: [{need, _resource}]} <- edge_provided(prep.closure_rows, manifest, dep) do
          need
        else
          _ -> dep
        end
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

  defp conflict(cause, expected, actual) do
    {:error,
     {:consent_conflict, %{expected_revision: expected, actual_revision: actual, cause: cause}}}
  end
end
