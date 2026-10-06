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
  rather than quietly dropping one; `head_bindings`, each binding the head
  holds as `%{binding_key, lifetime: %{kind, until}, consumed}` and what
  it binds (`entry_id`, `instance_entry_id` or a lending profile's
  `label`) from its `consent_vault_refs` row (`consumed` when a root has
  used a `once` binding), so a re-grant reopens on what the head holds,
  never wider, and a surface can offer to grant a consumed `once` binding
  again; `head_narrowing`, per consent-graph node the narrowing the head
  holds against the ask as it stands, in the decisions' `subset` shape
  (`head_narrowing/4`, the one definition `Sanctum.Consent.Commit.grant/3`
  re-issues too), so a re-grant opens as narrow as its head, and a method
  newly asked for, or a dependency a release added, opens off; and, when
  the component's shape moved since the head, `shape_diff`, the head as
  the person narrowed it against the live ask, every node of the closure,
  each entry naming its node and whether the head never held it or the
  ask no longer names it (`Sanctum.Consent.ShapeDiff`, read against the
  ask the narrowing is). With no head, `head_origins` is nil and
  `head_bindings`, `head_narrowing` and `shape_diff` are empty. A plan
  reads the head once, so all it says of the head and the revision it
  expects are of one read. A head whose policy fails its digest or does
  not parse refuses the plan `{:corrupt, {:profile, profile_id}}`: its
  narrowing is unknown.

  `candidates` are the athanor's active entries. An OAuth candidate answers
  `narrowable`, whether a token for fewer of its scopes can be dispensed,
  which is so only where its provider attenuates a refresh
  (`Sanctum.Vault.OAuth.attenuates_scope?/1`); a need asking for fewer
  scopes than a candidate that is not narrowable holds is not met by it.

  ## Each need's choice

  Every row of `needs`, and every need of a `dependency_needs` row,
  answers what can meet it and what the plan suggests (`need_choice/4`):

    * `candidates` — the athanor's active entries and the instance
      entries offered to the person (`Sanctum.InstanceEntries.offered/1`)
      of the need's kind whose `provider_hint` is the need's qualifier,
      each `%{source: "own" | "instance", entry_id | instance_entry_id,
      name, kind, provider, destination, disclosed}`, `narrowable` beside
      an OAuth one, which must hold the need's scopes as above. An
      instance entry is a candidate only where its component policy
      admits the node the need is bound on (`admits?/3`, with the node's
      release digest in the closure). A need the component reads itself —
      a disclose-only need, which declares no `attach`, the `@ingress`
      slot of a manifest declaring no needs, and a `disclose: true` need —
      is met by a disclosed entry of the athanor alone, never by an
      instance entry.
    * `suggested` — `%{entry_id: id}` or `%{instance_entry_id: id}`: the
      athanor's default of the need's provider (`Arca.VaultDefaults`) when
      it is a candidate, else the only candidate, else the one instance
      candidate when the athanor holds no active entry of that provider,
      else nil. A default suggests; it never binds.
    * `choice_required` — true only when several candidates match and
      none is suggested.
    * `source` — `"provided"` for a dependency's need the node's
      `provides` covers, which shows that configuration's `destination`
      and takes no candidate; otherwise the suggested candidate's source,
      or nil.
    * `newer_shipped` — for a disclose-only need, the newer version the
      install media ships of the component (`Components.newer_shipped/2`),
      or nil.

  Each declared need, the app's own and a dependency's, also names what a
  surface prefills a new entry for it from: its `kind` and `provider` (the
  type's qualifier), `disclose_only` (it declares no attach rule),
  `disclose` (true only where it declares `disclose: true`), and the
  `hosts` and `paths` it declares, nil where it declares none. A
  dependency row's lenders (`candidates`) each name the `fields` and the
  OAuth `scopes` the lending profile's binding projects, `[]` for none.

  `warnings` names, for each required need nothing can meet, the need
  and its provider, and for a disclose-only need that the component reads
  the value itself, with the newer shipped version when there is one; and
  each `provides` entry that provides nothing (a need its dependency does
  not declare, or declares with no attach rule) and each dependency the
  configuration would fill twice, since its edge holds one credential.

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

  # The needs an entry meets; the others name a component.
  @credential_kinds ~w(api_key oauth bundle)

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
          head_bindings: [head_binding()],
          head_narrowing: map(),
          shape_diff: [Sanctum.Consent.ShapeDiff.entry()],
          candidates: [map()],
          tool_server_candidates: [Sanctum.Grimoire.tool_server_candidate()],
          warnings: [String.t()],
          defaults: map()
        }

  @typedoc "One binding of the profile's head, as its `consent_vault_refs` row holds it."
  @type head_binding :: %{
          required(:binding_key) => String.t(),
          required(:lifetime) => %{kind: String.t(), until: String.t() | nil},
          required(:consumed) => boolean(),
          optional(:entry_id) => String.t(),
          optional(:instance_entry_id) => String.t(),
          optional(:label) => String.t()
        }

  @doc "The origins a grant admits when its decision names none: `interactive` alone."
  @spec default_origins() :: [Prima.Origin.t(), ...]
  def default_origins, do: @default_origins

  @doc """
  Stage a consent: facts, candidates, and the plan token.

  A dependency's lenders are read as the loader reads a selection's
  (`Sanctum.Consent.Loader`), keeping a store that cannot answer, a
  damaged row and an absent one apart, never a plan with that lender
  missing:

    * a profile list, a lender's head, or the entry a lender's head binds,
      that could not be read refuses the plan `{:lender_unavailable, dep}`
      (for the entry, any refusal of `Sanctum.VaultReader.usable/3` or
      `Sanctum.InstanceEntries.binding/2` that is not one of the answers
      below);
    * a profile row, a lender's head, or a head's policy that does not
      decode, or whose bytes fail their digest, refuses it
      `{:lender_corrupt, dep, profile_id}`.

  A dependency with no profile lends nothing, and so does a profile whose
  head is absent, binds no entry on the dependency's ingress, or binds an
  entry its reader answers is missing (`:not_found`), not usable
  (`{:entry_unavailable, …}`, `{:binding_mismatch, …}`), rebound, not
  offered to this person or not theirs to use (`:not_offered`,
  `:denied`, `:anonymous_denied`, `:no_person`), or of a component its
  policy does not admit.
  """
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
         {:ok, profile_id, expected_revision, head} <-
           locate_head(ctx, source_ref, label, kind),
         stored = if(head, do: {:ok, head, profile_id}, else: :none),
         manifest = manifest(component, source_ref),
         {:ok, resources, limits} <-
           Sanctum.Consent.BlobBuilder.node_grant(ctx, source_ref, manifest),
         {closure, closure_rows} = closure(ctx, component),
         {:ok, rows} <- ask_rows(ctx, closure, closure_rows),
         {:ok, candidates} <- candidates(ctx),
         {:ok, sources} <- choice_sources(ctx),
         needs =
           need_rows(
             ctx,
             sources,
             {component, manifest},
             node_facts(source_ref, closure, closure_rows)
           ),
         {:ok, {dependency_needs, provided_notes}} <-
           dependency_needs(ctx, sources, closure, closure_rows),
         {:ok, asked} <- held_ask(ctx, stored, source_ref, {closure, closure_rows}),
         {:ok, head_narrowing} <- held_narrowing(stored, source_ref, asked),
         {:ok, plan_token} <-
           mint_token(ctx, shape_digest, profile_id, expected_revision) do
      head = head_facts(ctx, stored, shape_digest, {source_ref, asked})

      {:ok,
       %{
         plan_token: plan_token,
         shape_digest: shape_digest,
         expected_consent_revision: expected_revision,
         profile_id: profile_id,
         source_ref: source_ref,
         needs: needs,
         dependency_needs: dependency_needs,
         caps: resources,
         limits: limits,
         rows: rows,
         unresolved: unresolved(closure),
         origins: Prima.Origin.to_wire_list(@default_origins),
         head_origins: head.origins,
         head_bindings: head.bindings,
         head_narrowing: head_narrowing,
         shape_diff: head.shape_diff,
         candidates: candidates,
         tool_server_candidates: Sanctum.Grimoire.tool_server_candidates(ctx),
         warnings: need_warnings(needs, provided_notes),
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
    with {:ok, profile_id, revision, _head} <- locate_head(ctx, source_ref, label, kind),
         do: {:ok, profile_id, revision}
  end

  # `locate_profile/4` with the head it read, nil for no profile or no
  # head: a plan reads the profile's head this once, so what it says of
  # the head and the revision it expects are of the same read.
  defp locate_head(ctx, source_ref, label, kind) do
    with {:ok, profiles} <- Arca.ConsentStorage.profiles(Context.actor(ctx), source_ref) do
      case Enum.find(profiles, fn p -> p.label == label and p.kind == kind end) do
        nil ->
          {:ok, nil, 0, nil}

        profile ->
          case Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id) do
            {:ok, consent} -> {:ok, profile.id, consent.revision, consent}
            {:error, :no_head} -> {:ok, profile.id, 0, nil}
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
  # need's reason, never the developer's key names — each with what can
  # meet it and what the plan suggests (`need_choice/4`). A manifest with
  # no needs block keeps the single ingress slot, which the component
  # reads itself.
  defp need_rows(ctx, sources, {component, manifest}, facts) do
    newer = fn -> newer_shipped(ctx, component) end

    case Prima.Manifest.Needs.from_manifest(manifest) do
      nil ->
        [
          %{
            need: Prima.Authority.Blob.ingress_key(),
            reason: "credentials this component may use when invoked",
            required: false,
            hosts: nil,
            paths: nil,
            disclose: false
          }
          |> Map.merge(choice_row(ctx, sources, nil, facts))
          |> Map.put(:newer_shipped, newer.())
        ]

      declared ->
        Enum.map(declared, fn need ->
          %{
            need: need.name,
            type: "#{need.kind}:#{need.qualifier}",
            reason: need.reason,
            fields: need.fields,
            scopes: need.scopes,
            required: need.required
          }
          |> Map.merge(prefill(need))
          |> Map.merge(choice_row(ctx, sources, need, facts))
          |> put_newer_shipped(need, newer)
        end)
    end
  end

  defp credential?(%{kind: kind}), do: kind in @credential_kinds

  # What a declared need says of the entry that can meet it, which a
  # surface prefills a new entry from: its kind and provider, whether the
  # component reads the value itself, and the destination it declares.
  defp prefill(need) do
    %{
      kind: need.kind,
      provider: need.qualifier,
      disclose_only: credential?(need) and Prima.Manifest.Needs.disclose_only?(need),
      disclose: Map.get(need, :disclose) == true,
      hosts: declared_list(Map.get(need, :hosts)),
      paths: declared_list(Map.get(need, :paths))
    }
  end

  defp declared_list([_ | _] = list), do: list
  defp declared_list(_none), do: nil

  # A disclose-only credential need names the newer shipped version, which
  # may attach rather than disclose; every other need names none.
  defp put_newer_shipped(row, need, newer) do
    if credential?(need) and Prima.Manifest.Needs.disclose_only?(need),
      do: Map.put(row, :newer_shipped, newer.()),
      else: Map.put(row, :newer_shipped, nil)
  end

  defp newer_shipped(ctx, component) do
    case Components.newer_shipped(ctx, component) do
      {:ok, version} -> version
      {:error, _unreadable} -> nil
    end
  end

  defp choice_row(_ctx, _sources, %{kind: kind}, _facts) when kind not in @credential_kinds,
    do: %{candidates: [], suggested: nil, choice_required: false, source: nil}

  defp choice_row(ctx, sources, need, facts) do
    choice = need_choice(ctx, sources, need, facts)
    Map.put(choice, :source, suggested_source(choice))
  end

  defp suggested_source(%{suggested: %{entry_id: _}}), do: "own"
  defp suggested_source(%{suggested: %{instance_entry_id: _}}), do: "instance"
  defp suggested_source(_choice), do: nil

  # A required credential need nothing can meet is satisfiable only after
  # the person creates an entry — say so up front, naming the need and
  # its provider; a need the component reads itself says so, and names
  # the newer version the media ships when there is one. Then what the
  # closure's `provides` blocks cannot provide.
  defp need_warnings(needs, provided_notes) do
    for(
      %{required: true, kind: kind, candidates: []} = need <- needs,
      kind in @credential_kinds,
      do: need_warning(need)
    ) ++ provided_notes
  end

  defp need_warning(%{disclose_only: true} = need) do
    "need '#{need.need}' wants a disclosed #{kind_words(need)}: the component reads the value " <>
      "itself, and no disclosed entry can yet — create one first" <> newer_words(need)
  end

  defp need_warning(need) do
    "need '#{need.need}' wants #{kind_words(need)}, and none can yet — create one first"
  end

  defp kind_words(%{kind: "oauth"} = need) do
    "oauth entry for #{need.provider} granting #{Enum.join(scope_set(need.scopes), ", ")}"
  end

  defp kind_words(need), do: "#{need.kind} entry for #{need.provider}"

  defp newer_words(%{newer_shipped: version}) when is_binary(version),
    do: ", or update to version #{version}, which the release ships"

  defp newer_words(_need), do: ""

  defp scope_set(scopes) when is_list(scopes), do: scopes |> Enum.uniq() |> Enum.sort()
  defp scope_set(_scopes), do: []

  # ---------------------------------------------------------------------------
  # A need's choice
  # ---------------------------------------------------------------------------

  @typedoc "What a need's choice reads: the athanor's active entries, the offered instance entries, the defaults."
  @type choice_sources :: %{own: [map()], offered: [map()], defaults: map()}

  @doc false
  # Read once per plan or preview: the athanor's active entries, the
  # instance entries offered to the context's person (none for a context
  # with no person) and the athanor's default per provider.
  @spec choice_sources(Context.t()) :: {:ok, choice_sources()} | {:error, term()}
  def choice_sources(ctx) do
    with {:ok, entries} <- Sanctum.Vault.list(ctx),
         {:ok, defaults} <- Sanctum.Vault.defaults(ctx) do
      offered =
        case Sanctum.InstanceEntries.offered(ctx) do
          {:ok, offered} -> offered
          {:error, _no_person} -> []
        end

      {:ok,
       %{
         own: Enum.filter(entries, &(&1.status == "active")),
         offered: offered,
         defaults: defaults
       }}
    end
  end

  @doc false
  # The node facts an instance entry's component policy is read against:
  # the node, named at the release the closure resolved (`rows`, so a
  # pinned dependency is read at its pin), and its release digest in the
  # resolved closure (nil when the closure does not resolve, which admits
  # nothing under `shipped`).
  @spec node_facts(String.t(), {:ok, map()} | {:unresolved, map()} | map(), map()) :: map()
  def node_facts(node_key, {:ok, graph}, rows), do: node_facts(node_key, graph, rows)

  def node_facts(node_key, {:unresolved, _}, _rows),
    do: %{node_ref: node_key, activation_digest: nil}

  def node_facts(node_key, graph, rows) when is_map(graph) and is_map(rows),
    do: %{node_ref: release_ref(node_key, rows), activation_digest: Map.get(graph, node_key)}

  defp release_ref(node_key, rows) do
    with %{} = row <- Map.get(rows, node_key),
         version when is_binary(version) <- Prima.ComponentRow.field(row, :version),
         {:ok, ref} <- Prima.ComponentRef.parse(node_key) do
      Prima.ComponentRef.build(ref.type, ref.namespace, ref.name, version)
    else
      _ -> node_key
    end
  end

  @doc false
  # One need's choice (see the moduledoc): its candidates, the one the
  # plan suggests and whether the person must choose. `need` is a
  # declared credential need (`Prima.Manifest.Needs.from_manifest/1`'s) or
  # nil for the `@ingress` slot of a manifest declaring none; `facts` the
  # node it is bound on. The commit's preview rows read the same rule.
  @spec need_choice(Context.t(), choice_sources(), map() | nil, map()) :: %{
          candidates: [map()],
          suggested: map() | nil,
          choice_required: boolean()
        }
  def need_choice(ctx, sources, need, facts) do
    candidates =
      Enum.flat_map(sources.own, &own_candidate(&1, need)) ++
        Enum.flat_map(sources.offered, &instance_candidate(ctx, &1, need, facts))

    suggested = suggestion(candidates, sources, need)

    %{
      candidates: candidates,
      suggested: suggested,
      choice_required: length(candidates) > 1 and suggested == nil
    }
  end

  # A need the component reads itself is met by a disclosed entry alone.
  defp reads_itself?(nil), do: true

  defp reads_itself?(need),
    do: Prima.Manifest.Needs.disclose_only?(need) or Map.get(need, :disclose) == true

  defp own_candidate(entry, need) do
    candidate =
      %{
        source: "own",
        entry_id: entry.id,
        name: entry.name,
        kind: entry.kind,
        provider: entry.provider_hint,
        destination: canonical_destination(entry.destination),
        disclosed: not entry.attach_only
      }
      |> put_narrowable(entry)

    if matches?(candidate, entry.oauth_scopes, need) and
         (candidate.disclosed or not reads_itself?(need)),
       do: [candidate],
       else: []
  end

  defp instance_candidate(_ctx, _entry, nil, _facts), do: []

  defp instance_candidate(ctx, entry, need, facts) do
    candidate =
      %{
        source: "instance",
        instance_entry_id: entry.id,
        name: entry.name,
        kind: entry.kind,
        provider: entry.provider_hint,
        destination: canonical_destination(entry.destination),
        disclosed: false
      }
      |> put_narrowable(entry)

    if not reads_itself?(need) and matches?(candidate, entry.oauth_scopes, need) and
         Sanctum.InstanceEntries.admits?(ctx, entry, facts),
       do: [candidate],
       else: []
  end

  # The `@ingress` slot of a manifest declaring no needs names no kind or
  # provider: any disclosed entry may meet it.
  defp matches?(_candidate, _scopes, nil), do: true

  defp matches?(candidate, scopes, need) do
    candidate.kind == need.kind and candidate.provider == need.qualifier and
      scopes_met?(candidate, scopes, need)
  end

  # An OAuth candidate holds the need's scopes and either exactly them or
  # can be narrowed to them, since a token for fewer scopes than an entry
  # holds is dispensed only where its provider attenuates a refresh.
  defp scopes_met?(%{kind: "oauth"} = candidate, scopes, need) do
    held = scope_set(scopes)
    wanted = scope_set(need.scopes)
    wanted -- held == [] and (wanted == held or candidate.narrowable)
  end

  defp scopes_met?(_candidate, _scopes, _need), do: true

  defp put_narrowable(%{kind: "oauth"} = candidate, entry),
    do: Map.put(candidate, :narrowable, OAuth.attenuates_scope?(entry.provider_hint))

  defp put_narrowable(candidate, _entry), do: candidate

  defp canonical_destination(%{} = map) do
    case Prima.Destination.from_map(map) do
      {:ok, destination} -> Prima.Destination.to_map(destination)
      {:error, _} -> nil
    end
  end

  defp canonical_destination(_absent), do: nil

  # The default of the need's provider when it is a candidate (the two
  # are separate reads, so a default naming none suggests nothing here),
  # else the only candidate, else the one instance candidate when the
  # athanor holds no active entry of the provider.
  defp suggestion(candidates, sources, need) do
    default_candidate(candidates, sources, need) || only(candidates) ||
      offered_alone(candidates, sources, need)
  end

  defp default_candidate(_candidates, _sources, nil), do: nil

  defp default_candidate(candidates, sources, need) do
    case Map.get(sources.defaults, need.qualifier) do
      %{vault_entry_id: id} ->
        if Enum.any?(candidates, &(Map.get(&1, :entry_id) == id)), do: %{entry_id: id}

      %{instance_entry_id: id} ->
        if Enum.any?(candidates, &(Map.get(&1, :instance_entry_id) == id)),
          do: %{instance_entry_id: id}

      nil ->
        nil
    end
  end

  defp only([candidate]), do: identity(candidate)
  defp only(_none_or_several), do: nil

  defp offered_alone(_candidates, _sources, nil), do: nil

  defp offered_alone(candidates, sources, need) do
    held? = Enum.any?(sources.own, &(&1.provider_hint == need.qualifier))

    case Enum.filter(candidates, &(&1.source == "instance")) do
      [instance] when not held? -> identity(instance)
      _ -> nil
    end
  end

  defp identity(%{source: "own", entry_id: id}), do: %{entry_id: id}
  defp identity(%{source: "instance", instance_entry_id: id}), do: %{instance_entry_id: id}

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

  # What the profile's head holds: the origins it admits, its bindings,
  # and what changed against it when the shape moved. A first grant, or a
  # profile with no head, holds none.
  defp head_facts(_ctx, :none, _shape_digest, _ask),
    do: %{origins: nil, bindings: [], shape_diff: []}

  defp head_facts(ctx, {:ok, head, _profile_id}, shape_digest, {source_ref, asked}) do
    %{
      origins: Prima.Origin.to_wire_list(head.admitted_origins),
      bindings: Enum.map(head.vault_refs, &head_binding/1),
      shape_diff:
        if(head.shape_digest == shape_digest,
          do: [],
          else: Sanctum.Consent.ShapeDiff.compute(ctx, source_ref, head.resolved_policy, asked)
        )
    }
  end

  @doc """
  The narrowing a stored head holds against the ask as it stands, in the
  decisions' `subset` shape: per consent-graph node the ask names, every
  field of a narrowable kind whose grant on the head differs from the
  ask, named as the head grants it within the ask — the egress domains,
  methods, schemes and private ranges, the storage paths and actions, the
  tools, and each limit (a rate limit by the fields that differ). A head
  no narrowing touched answers `%{}`.

  A narrowing grants part of the ask, so it is the head's grant
  intersected with what the ask still names, each value read as the
  commit reads a narrowing (`BlobBuilder.narrow/5`, domains and paths
  included): what the head granted that the ask no longer names opens as
  nothing, and a field that, so kept, equals the ask names nothing. Each
  limit is the narrower of the head's and the ask's: the ask's where it
  is now lower, and for a rate limit, which bounds a burst and a rate at
  once, the overlap, the smaller count over the longer window. Where the
  ask has not moved since the head, everything the head grants lies
  inside it, so the head's grant is named whole.

  A node the head never held, a dependency a release added, grants none
  of what it asks: each narrowable field the ask names is named empty, so
  it is granted only as the person grants it. Its limits, credentials,
  tool servers and declarations are granted whole, as for any node.

  `head` is the stored head revision, read as every head's bytes are
  read (`Sanctum.Consent.Loader.head_blob/1`: its policy hashes to its
  stored digest and parses as a blob), and `asked_blob` the ask's blob,
  built as a commit builds it (`BlobBuilder.build/5` and
  `BlobBuilder.encode/1`), as JSON. A head that fails that read leaves its
  narrowing unknown, so nothing may be re-issued over it:
  `{:error, {:corrupt, {:profile, profile_id}}}`.

  The one definition of what a re-grant keeps: a plan answers it as
  `head_narrowing`, which the grant sheet opens on, and
  `Sanctum.Consent.Commit.grant/3` re-issues it.
  """
  @spec head_narrowing(String.t(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, {:corrupt, {:profile, String.t()}}}
  def head_narrowing(profile_id, head, source_ref, asked_blob) do
    with {:ok, _blob} <- Sanctum.Consent.Loader.head_blob(head),
         {:ok, head_nodes} <- decoded_nodes(head.resolved_policy),
         {:ok, asked_nodes} <- decoded_nodes(asked_blob) do
      held =
        for {node_key, head_node} <- head_nodes,
            Map.has_key?(asked_nodes, node_key),
            record =
              node_narrowing(
                node_key,
                {BlobBuilder.node_resources(head_nodes, source_ref, node_key),
                 head_node["limits"]},
                {BlobBuilder.node_resources(asked_nodes, source_ref, node_key),
                 asked_nodes[node_key]["limits"]}
              ),
            record != %{},
            into: %{},
            do: {node_key, record}

      unheld =
        for {node_key, _asked_node} <- asked_nodes,
            not Map.has_key?(head_nodes, node_key),
            record = granting_none(BlobBuilder.node_resources(asked_nodes, source_ref, node_key)),
            record != %{},
            into: %{},
            do: {node_key, record}

      {:ok, Map.merge(held, unheld)}
    else
      _unreadable -> {:error, {:corrupt, {:profile, profile_id}}}
    end
  end

  defp decoded_nodes(json) do
    case Jason.decode(json) do
      {:ok, %{"nodes" => nodes}} when is_map(nodes) -> {:ok, nodes}
      _ -> :error
    end
  end

  # A node the head never held, one a release added to the closure: it
  # opens granting none of what it asks, each narrowable field the ask
  # names set to the empty set, which a narrowing reads as granting none,
  # so it is granted only as the person ticks it. Its limits bound it as
  # asked: they grant nothing.
  defp granting_none(asked) do
    sets =
      for {kind, fields} <- [
            {"egress", ~w(domains methods schemes private_ips)},
            {"storage", ~w(paths actions)}
          ],
          asked_kind = (asked && asked[kind]) || %{},
          record =
            for(
              field <- fields,
              Map.get(asked_kind, field, []) != [],
              into: %{},
              do: {field, []}
            ),
          record != %{},
          into: %{},
          do: {kind, record}

    if ((asked && asked["tools"]) || []) != [],
      do: Map.put(sets, "tools", []),
      else: sets
  end

  # The head's grant of one node within the ask, kind by kind: a narrowing
  # grants part of the ask, so what the head grants and the ask no longer
  # names opens as nothing, and a field that, kept, equals the ask narrows
  # nothing. Whether a value lies inside the ask is the narrowing's own
  # reading (`asked?/3`). Where the ask has not moved, everything the head
  # grants lies inside it, and the head's grant is named whole.
  defp node_narrowing(node_key, {head, head_limits}, {asked, asked_limits}) do
    %{}
    |> put_differing(
      "egress",
      fields_differing(node_key, head, asked, "egress", ~w(domains methods schemes private_ips))
    )
    |> put_differing(
      "storage",
      fields_differing(node_key, head, asked, "storage", ~w(paths actions))
    )
    |> put_differing("tools", tools_differing(node_key, head, asked))
    |> put_differing(
      "limits",
      limits_differing(node_key, head_limits || %{}, asked_limits || %{})
    )
  end

  defp fields_differing(node_key, head, asked, kind, fields) do
    head_kind = (head && head[kind]) || %{}
    asked_kind = (asked && asked[kind]) || %{}

    for field <- fields,
        kept =
          Enum.filter(
            Map.get(head_kind, field, []),
            &asked?(node_key, {asked, nil}, %{kind => %{field => [&1]}})
          ),
        kept != Map.get(asked_kind, field, []),
        into: %{},
        do: {field, kept}
  end

  defp tools_differing(node_key, head, asked) do
    kept =
      Enum.filter(
        (head && head["tools"]) || [],
        &asked?(node_key, {asked, nil}, %{"tools" => [&1]})
      )

    if kept != ((asked && asked["tools"]) || []), do: kept
  end

  # The head's limits that differ from the ask, each the narrower of the
  # head's and the ask's, taken together as the commit took them when they
  # all lie inside the ask. A limit is checked field by field
  # (`Prima.Limits.new/1` holds no field to another), so one the ask does
  # not hold is above it: the ask's is the narrower, and it names nothing.
  # A rate limit bounds two things at once, so its narrower is the overlap
  # (`rate_overlap/2`), never the ask's, which may be faster or allow a
  # larger burst.
  defp limits_differing(node_key, head_limits, asked_limits) do
    differing =
      for {field, value} <- head_limits,
          value != asked_limits[field],
          into: %{},
          do: {field, value}

    within =
      if asked?(node_key, {nil, asked_limits}, %{"limits" => differing}),
        do: differing,
        else:
          for(
            {field, value} <- differing,
            narrower = narrower_limit(node_key, asked_limits, field, value),
            narrower != asked_limits[field],
            into: %{},
            do: {field, narrower}
          )

    for {field, value} <- within, into: %{} do
      case {value, asked_limits[field]} do
        {%{} = rate, %{} = asked_rate} ->
          {field, for({k, v} <- rate, v != asked_rate[k], into: %{}, do: {k, v})}

        _differs ->
          {field, value}
      end
    end
  end

  # The narrower of the head's limit and the ask's: the head's when it lies
  # inside the ask, else the ask's, or, for a rate limit, the overlap.
  defp narrower_limit(node_key, asked_limits, field, value) do
    cond do
      asked?(node_key, {nil, asked_limits}, %{"limits" => %{field => value}}) -> value
      field == "rate_limit" -> rate_overlap(value, asked_limits[field])
      true -> asked_limits[field]
    end
  end

  # A rate limit no wider than either: the smaller burst over the longer
  # window, which allows no larger a burst and no faster a rate than the
  # head or the ask. Unreadable, the ask's stands, as it would at a run.
  defp rate_overlap(%{} = head, %{} = asked) do
    head = Map.merge(asked, head)

    with requests when is_integer(requests) <- min_integer(head["requests"], asked["requests"]),
         {:ok, head_ms} <- Prima.Limits.parse_duration(head["window"]),
         {:ok, asked_ms} <- Prima.Limits.parse_duration(asked["window"]) do
      window = if head_ms >= asked_ms, do: head["window"], else: asked["window"]
      %{"requests" => requests, "window" => window}
    else
      _unreadable -> asked
    end
  end

  defp rate_overlap(_head, asked), do: asked

  defp min_integer(a, b) when is_integer(a) and is_integer(b), do: min(a, b)
  defp min_integer(_a, _b), do: nil

  # Whether a narrowing lies inside the ask, as the commit holds it
  # (`BlobBuilder.narrow/5`), against the ask alone: an empty ceiling map
  # bounds nothing, so a ceiling lowered since the head was granted never
  # drops what the head holds.
  defp asked?(node_key, {asked, asked_limits}, subset),
    do: match?({:ok, _, _, _}, BlobBuilder.narrow(node_key, asked, asked_limits, subset, %{}))

  defp put_differing(record, _kind, nil), do: record
  defp put_differing(record, _kind, empty) when empty == %{}, do: record
  defp put_differing(record, kind, value), do: Map.put(record, kind, value)

  # The ask a head is held against, built once for what a plan says of the
  # head: none for a first grant, which holds nothing against it.
  defp held_ask(_ctx, :none, _source_ref, _closure), do: {:ok, nil}
  defp held_ask(ctx, {:ok, _head, _id}, source_ref, closure), do: ask(ctx, source_ref, closure)

  @doc false
  # The ask of `source_ref`'s closure as it resolves now, built as a commit
  # builds it with nothing narrowed (`BlobBuilder.build/5`,
  # `BlobBuilder.encode/1`), as JSON: what a head's narrowing and the shape
  # diff (`Sanctum.Consent.ShapeDiff`) are read against. `{:ok, nil}` for a
  # closure that does not resolve, which has no ask to hold a head against.
  @spec asked_blob(Context.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def asked_blob(%Context{} = ctx, source_ref) do
    with {:ok, component} <- fetch_component(ctx, source_ref),
         do: ask(ctx, source_ref, closure(ctx, component))
  end

  defp ask(_ctx, _source_ref, {{:unresolved, _}, _rows}), do: {:ok, nil}

  defp ask(ctx, source_ref, {{:ok, graph}, rows}) do
    with {:ok, nodes} <-
           BlobBuilder.build(ctx, graph, source_ref, fn _, _, _ -> nil end, rows: rows),
         do: BlobBuilder.encode(nodes)
  end

  # What the head's grant narrows of the ask as it stands
  # (`head_narrowing/4`): the narrowing a re-grant opens on. A first
  # grant keeps none, nor does a closure that does not resolve, which has
  # no ask to hold the head against and offers nothing to commit.
  defp held_narrowing(:none, _source_ref, _asked), do: {:ok, %{}}
  defp held_narrowing({:ok, _head, _id}, _source_ref, nil), do: {:ok, %{}}

  defp held_narrowing({:ok, head, profile_id}, source_ref, asked),
    do: head_narrowing(profile_id, head, source_ref, asked)

  # A head row as a re-grant reopens it: its key, what it binds (the
  # athanor's entry, the instance entry or the lending profile's label,
  # never material), its lifetime and whether a root consumed it.
  defp head_binding(ref) do
    %{
      binding_key: ref.binding_key,
      lifetime: %{kind: ref.lifetime_kind, until: until_of(ref.expires_at)},
      consumed: is_binary(ref.consumed_by_root)
    }
    |> Prima.MapUtil.put_present(:entry_id, ref.vault_entry_id)
    |> Prima.MapUtil.put_present(:instance_entry_id, ref.instance_entry_id)
    |> Prima.MapUtil.put_present(:label, ref.via_label)
  end

  # The instant as it was decided: a whole second is spelled without the
  # store's microseconds, so it reads as the RFC 3339 the decision sent.
  defp until_of(%DateTime{microsecond: {0, _precision}} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp until_of(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp until_of(_none), do: nil

  # The activation closure's graph and the rows it resolved, or what keeps
  # it from resolving: the reason's tag and the ref the resolution names
  # as missing, if any.
  defp closure(ctx, component) do
    with {:ok, %{graph: graph}} <- Components.resolve(ctx, component),
         {:ok, rows} <- closure_rows(ctx, component, graph) do
      {{:ok, graph}, rows}
    else
      {:error, reason} -> {{:unresolved, unresolved_reason(reason)}, %{}}
    end
  end

  @doc false
  # The rows the closure resolved, by node key: the walk
  # `Compendium.Activation` makes from the source (a dependency its
  # dependent's manifest pins at that version, any other at its latest),
  # each held to the release digest the closure's graph records, so a
  # consent reads every dependency's manifest at the release that runs. A
  # row the graph does not record at that digest is
  # `{:error, {:activation_moved, node_key}}`: the closure moved under the
  # read, and the plan or the commit is asked again.
  @spec closure_rows(Context.t(), map(), %{String.t() => String.t()}) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def closure_rows(%Context{} = ctx, source_row, graph) when is_map(graph),
    do: walk_rows(ctx, source_row, graph, %{})

  defp walk_rows(ctx, row, graph, rows) do
    key = Prima.ComponentRow.node_key(row)

    cond do
      Map.has_key?(rows, key) ->
        {:ok, rows}

      Map.get(graph, key) != Prima.ComponentRow.field(row, :release_digest) ->
        {:error, {:activation_moved, key}}

      true ->
        row
        |> manifest(key)
        |> Prima.Manifest.Dependencies.from_manifest()
        |> case do
          {:ok, deps} -> deps
          {:error, _} -> []
        end
        |> Enum.reduce_while({:ok, Map.put(rows, key, row)}, fn dep, {:ok, rows} ->
          # As the activation walks: an optional dependency whose release is
          # not installed is skipped, whether or not another path reaches
          # its node at another release; any other that does not read
          # leaves the closure incomplete.
          case dependency_row(ctx, dep) do
            {:ok, dep_row} ->
              case walk_rows(ctx, dep_row, graph, rows) do
                {:ok, rows} -> {:cont, {:ok, rows}}
                {:error, _} = refused -> {:halt, refused}
              end

            {:error, :not_found} when dep.optional == true ->
              {:cont, {:ok, rows}}

            {:error, :not_found} ->
              dep_key = Prima.ComponentRef.build(dep.dep_type, dep.dep_namespace, dep.dep_name)
              {:halt, {:error, {:incomplete, {:unresolvable_dependency, dep_key}}}}

            {:error, _} = refused ->
              {:halt, refused}
          end
        end)
    end
  end

  defp dependency_row(ctx, %{dep_version: version} = dep) when is_binary(version),
    do: Components.get_component(ctx, dep.dep_name, version, dep.dep_namespace, dep.dep_type)

  defp dependency_row(ctx, dep),
    do: Components.get_latest(ctx, dep.dep_name, dep.dep_namespace, dep.dep_type)

  defp unresolved_reason({:activation_moved, key}),
    do: %{reason: "activation_moved", missing: key}

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
  defp ask_rows(_ctx, {:unresolved, _unresolved}, _closure_rows), do: {:ok, []}

  defp ask_rows(ctx, {:ok, _graph}, closure_rows) do
    with {:ok, rows} <- BlobBuilder.ask_rows(ctx, closure_rows) do
      rows = BlobBuilder.order_rows(rows)

      case BlobBuilder.check_rows(rows) do
        {:ok, _checked} -> {:ok, rows}
        {:error, reason} -> {:error, {:preview_unrepresentable, reason}}
      end
    end
  end

  # The closure's dependency edges whose target declares a credential
  # need, each with the owner profiles of that target that bind one —
  # what a selection may name — and each need with its own choice, or
  # the configuration the calling node provides for it. Beside them, what
  # each node's `provides` cannot provide. A closure that cannot be
  # resolved offers none; the commit refuses a selection it cannot place
  # anyway. A lender that cannot be read refuses the whole (`plan/2`).
  defp dependency_needs(_ctx, _sources, {:unresolved, _unresolved}, _rows), do: {:ok, {[], []}}

  defp dependency_needs(ctx, sources, {:ok, graph}, rows) do
    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn from ->
      case node_manifest(rows, from) do
        {:ok, manifest} ->
          manifest
          |> BlobBuilder.dep_edges(graph, from)
          |> Enum.sort()
          |> Enum.map(&{from, manifest, &1})

        _ ->
          []
      end
    end)
    |> Enum.reduce_while({:ok, {[], []}}, fn {from, manifest, dep}, {:ok, {all, notes}} ->
      case dependency_rows(ctx, sources, {from, manifest, graph, rows}, dep) do
        {:ok, {dep_rows, dep_notes}} -> {:cont, {:ok, {all ++ dep_rows, notes ++ dep_notes}}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  # What a `provides` entry cannot provide, and a dependency it would fill
  # twice, said once each.
  defp provided_notes(from, dep, %{covered: covered, unprovidable: unprovidable}) do
    twice =
      case covered do
        [_, _ | _] ->
          [
            "#{from} provides #{Enum.map_join(covered, " and ", &elem(&1, 0))} for #{dep}, " <>
              "which takes one credential on its edge; it cannot be granted until one is dropped"
          ]

        _one_or_none ->
          []
      end

    twice ++
      Enum.map(unprovidable, fn
        {need, :undeclared} ->
          "#{from} provides #{need} for #{dep}, which declares no such need; it provides nothing"

        {need, :no_attach} ->
          "#{from} provides #{need} for #{dep}, whose need declares no attach rule; it " <>
            "provides nothing, and the need takes an entry"
      end)
  end

  # A closure node's manifest at the release the closure resolved.
  defp node_manifest(rows, node_key) do
    case Map.fetch(rows, node_key) do
      {:ok, row} -> {:ok, manifest(row, node_key)}
      :error -> {:error, :not_in_closure}
    end
  end

  defp dependency_rows(ctx, sources, {from, from_manifest, graph, rows}, dep) do
    with {:ok, row} <- Map.fetch(rows, dep),
         dep_manifest = manifest(row, dep),
         {:ok, _caps} <- ShapeDerivation.declared_caps(dep_manifest, dep),
         needs = Prima.Manifest.Needs.from_manifest(dep_manifest) do
      provided = BlobBuilder.provided(from_manifest, dep, dep_manifest)
      notes = provided_notes(from, dep, provided)
      covered = Map.new(provided.covered)
      facts = node_facts(dep, graph, rows)
      newer = fn -> newer_shipped(ctx, row) end

      case Enum.filter(needs || [], &credential?/1) do
        [] ->
          {:ok, {[], notes}}

        credential_needs ->
          with {:ok, lenders} <- lender_candidates(ctx, dep, facts) do
            {:ok,
             {[
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
                      |> Map.merge(prefill(need))
                      |> Map.merge(dependency_choice(ctx, sources, need, facts, covered))
                      |> put_newer_shipped(need, newer)
                    end),
                  candidates: lenders
                }
              ], notes}}
          end
      end
    else
      _ -> {:ok, {[], []}}
    end
  end

  # A need the calling node provides configuration for shows where it
  # goes and asks for nothing; any other takes its choice.
  defp dependency_choice(ctx, sources, need, facts, covered) do
    case Map.fetch(covered, need.name) do
      {:ok, %{"provided" => provided}} ->
        %{
          candidates: [],
          suggested: nil,
          choice_required: false,
          source: "provided",
          destination: provided["destination"]
        }

      :error ->
        choice_row(ctx, sources, need, facts)
    end
  end

  # The dependency's active owner profiles whose head binds a usable entry
  # on its ingress; provided configuration is no entry to lend.
  defp lender_candidates(ctx, dep, facts) do
    actor = Context.actor(ctx)

    with {:ok, entries} <- lender_profiles(actor, dep),
         do: lenders(ctx, actor, dep, facts, entries)
  end

  @doc false
  # The profiles of a dependency `dep` that may lend it a key, as the plan
  # and the commit read them (`Sanctum.Consent.Commit`), and as the loader
  # reads a selection's lender: a row whose kind or status does not decode
  # may be an active owner profile, so it refuses `{:lender_corrupt, dep,
  # id}` rather than being skipped, and a store that cannot answer is
  # `{:lender_unavailable, dep}`, never a dependency with no lender. Either
  # would offer or grant over profiles that exist as if none lent a key.
  @spec lender_profiles(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Authority.RootSelect.profile_summary()]}
          | {:error,
             {:lender_corrupt, String.t(), String.t()} | {:lender_unavailable, String.t()}}
  def lender_profiles(%Prima.Actor{} = actor, dep) when is_binary(dep) do
    case Arca.ConsentStorage.profile_entries(actor, dep) do
      {:ok, entries} ->
        case Enum.find(entries, &(&1.status == :corrupt)) do
          %{id: id} -> {:error, {:lender_corrupt, dep, id}}
          nil -> {:ok, entries}
        end

      {:error, _unanswered} ->
        {:error, {:lender_unavailable, dep}}
    end
  end

  # Each active owner profile's lending, in profile order, or the first
  # lender that cannot be read or is damaged.
  defp lenders(ctx, actor, dep, facts, entries) do
    entries
    |> Enum.filter(&match?(%{kind: :owner, status: :active}, &1))
    |> Enum.reduce_while({:ok, []}, fn profile, {:ok, lent} ->
      with {:ok, head} <- lender_head(actor, dep, profile),
           {:ok, lends} <- lending(ctx, dep, facts, profile, head) do
        {:cont, {:ok, lent ++ lends}}
      else
        :absent -> {:cont, {:ok, lent}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
  end

  # A lender's head as the loader reads it (`fetch_head/2`): absent lends
  # nothing, one stored outside the closed vocabulary is damaged, and any
  # other refusal is a store that could not answer.
  defp lender_head(actor, dep, profile) do
    case Arca.ConsentStorage.head_consent(actor, profile.id) do
      {:ok, head} -> {:ok, head}
      {:error, absent} when absent in [:not_found, :no_head] -> :absent
      {:error, {:invalid_stored_value, _}} -> {:error, {:lender_corrupt, dep, profile.id}}
      {:error, _unanswered} -> {:error, {:lender_unavailable, dep}}
    end
  end

  # What a lender's head lends on the dependency's ingress: the entry its
  # binding names, when this person may use it, or nothing. A head whose
  # policy fails its digest or does not parse is damaged, read as a
  # selection reads its lender (`Sanctum.Consent.Loader.head_blob/1`), and
  # a lent entry its reader could not read is a lender that cannot be
  # read: either refuses the plan, which would otherwise offer no lender,
  # or a damaged one, over one that exists. Nothing is lent only by a head
  # that binds no entry on the ingress, or whose entry its reader answers
  # is missing, not usable or not this person's.
  defp lending(ctx, dep, facts, profile, head) do
    case Sanctum.Consent.Loader.head_blob(head) do
      {:ok, blob} -> ingress_lending(ctx, dep, facts, profile, blob)
      {:error, _damaged} -> {:error, {:lender_corrupt, dep, profile.id}}
    end
  end

  defp ingress_lending(ctx, dep, facts, profile, blob) do
    with {:ok, %{vault: %{entry_id: _} = vault}} <- Prima.Authority.Blob.ingress(blob, dep) do
      case lent_entry(ctx, vault, facts) do
        {:ok, lent} ->
          {:ok,
           [
             %{
               profile_id: profile.id,
               label: profile.label,
               source: lent.source,
               entry_id: lent.id,
               entry_name: lent.name,
               fields: projected(vault.projection, :fields),
               scopes: projected(vault.projection, :scopes)
             }
           ]}

        :absent ->
          {:ok, []}

        :unread ->
          {:error, {:lender_unavailable, dep}}
      end
    else
      _no_entry_on_ingress -> {:ok, []}
    end
  end

  defp projected(%{} = projection, key), do: Map.get(projection, key) || []
  defp projected(_none, _key), do: []

  # The entry a lender's binding names, usable by this person at the
  # digest the lender bound: the athanor's own, or an instance entry as it
  # is offered to the person (`Sanctum.InstanceEntries.binding/2`) whose
  # component policy admits the dependency node, as the commit holds it.
  # `:absent` is the reader's own answer about the entry (a moved binding
  # and a component not admitted among them), `:unread` any other refusal.
  defp lent_entry(ctx, %{scope: "instance", entry_id: id, binding_digest: digest}, facts) do
    case Sanctum.InstanceEntries.binding(ctx, id) do
      {:ok, %{binding_digest: ^digest} = view} ->
        if Sanctum.InstanceEntries.admits?(ctx, view, facts),
          do: {:ok, %{source: "instance", id: view.id, name: view.name}},
          else: :absent

      {:ok, _moved} ->
        :absent

      {:error, reason} ->
        if instance_entry_answer?(reason), do: :absent, else: :unread
    end
  end

  defp lent_entry(ctx, %{entry_id: id, binding_digest: digest}, _facts) do
    case Sanctum.VaultReader.usable(ctx.athanor_id, id, digest) do
      {:ok, entry} -> {:ok, %{source: "own", id: entry.id, name: entry.name}}
      {:error, reason} -> if own_entry_answer?(reason), do: :absent, else: :unread
    end
  end

  # `Sanctum.VaultReader.usable/3`'s answers about the entry itself: not
  # held, not active, or no longer at the digest bound.
  defp own_entry_answer?(:not_found), do: true
  defp own_entry_answer?({:entry_unavailable, _name, _status}), do: true
  defp own_entry_answer?({:binding_mismatch, _name}), do: true
  defp own_entry_answer?(_unread), do: false

  # `Sanctum.InstanceEntries.binding/2`'s answers about the entry and the
  # person: not offered to them, not theirs to use, or not active.
  defp instance_entry_answer?(reason)
       when reason in [:not_offered, :denied, :anonymous_denied, :no_person],
       do: true

  defp instance_entry_answer?({:entry_unavailable, _status}), do: true
  defp instance_entry_answer?(_unread), do: false

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
