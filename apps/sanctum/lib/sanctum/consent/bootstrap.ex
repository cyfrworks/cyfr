# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Bootstrap do
  @moduledoc """
  Mint first consents for the **seed bundle** — the operator's own code.

  For every executable local component without a profile, mints an owner
  profile and a revision-1 consent whose blob grants each closure node its
  manifest-declared caps (the empty ask when a manifest declares none):
  the ingress edge carries the source's own resources, and every edge into
  a node carries **that node's** resources.

  A shipped source's edge into a shipped dependency that declares a
  credential need **selects** that dependency's `default` profile: the
  key a person binds on the catalyst's own profile is what the shipped
  formula runs it with, and revoking or rebinding it there is one act.

  A boot revises a **bootstrap-only** head (`granted_via: "bootstrap"`,
  never touched by a person) when its shape moved because the seed did —
  every node of the live closure is vouched for, so the revision is the
  same operator-vouched mint as the first. A node
  is vouched for when the seed ships it at the seed's own digest, or when
  the head already names it at that digest: a release that retires the
  version an athanor holds does not turn that unchanged copy into a
  person's own. An edited shipped copy is not the seed: its digest is
  not the seed's, and it is not re-minted. A member-authored source
  has no machine profile. A closure a person widened or a head a person
  committed is theirs to consent again.

  Idempotent: a source ref that already has an owner profile is skipped
  (revised only as above). Machine-minted revisions record
  `granted_via: "bootstrap"`.

  ## The instance's entry at first sign-in

  A newly provisioned athanor's person may be offered an instance entry
  (`Sanctum.InstanceEntries.offered/1`, read under the walk's own
  context). At the first mint of a shipped catalyst's default profile,
  the walk binds a need that admits an instance entry — one that declares
  `attach` and not `disclose` — when exactly one offered active instance
  entry is of the need's kind and provider and its component policy
  admits the shipped catalyst, in the default slot, standing. A catalyst
  with several such needs binds none, since its ingress edge carries one
  need's bindings. A server-side mint (`auth_method: :system`) has no
  person and binds nothing. A revision of a bootstrap-only head under a
  person keeps the head's instance binding while the person is still
  offered it at the same digest and the policy still admits the node,
  and binds none otherwise. A revision with no person — a boot's seed
  sync — chooses nothing: it carries the head's instance binding as the
  head holds it (entry, digest, key and lifetime) onto the need that
  admits an instance entry, so a shipped catalyst's new release does not
  silently drop it, while the entry is still of that need's kind and
  provider, active, and at the digest the head bound
  (`Sanctum.InstanceEntries.binding_facts/1`); otherwise it binds none,
  and a store that cannot answer skips the source that boot with its
  head kept. A revoke landing after that read meets the revision's
  storage lock, and the walk reports that source skipped with the
  refusal, while `Sanctum.Attach` holds each request to the audience,
  the policy and the caps. A revision never adds a binding the head
  lacked, so an athanor provisioned before an instance entry appeared
  meets it as the suggestion at its next grant.

  The first mint is the only one that binds an instance entry, and a
  revision keeps only what its head bound, so an instance store that
  cannot answer is never read as nothing to bind. An outage of the
  instance entries — reading the entries offered,
  or the binding of the entry a mint chose or a person's revision keeps
  (`Sanctum.InstanceEntries.binding/2`) — skips the source,
  `{:unavailable, "Instance entries"}`, with any head kept, and a later
  run mints or revises it whole. A catalyst whose stored manifest does
  not decode is skipped `{:corrupt, {:manifest, ref}}`, as its shape
  derivation refuses it. A revision whose head policy does not parse,
  or a revision with no person whose ingress names an instance binding
  no ref row holds, is skipped `{:corrupt, {:profile, profile_id}}`, its
  head kept. The reads' other refusals offer nothing: a context with no
  person to read the offer as, as `Sanctum.Consent.Plan` reads the same
  call, or an entry no longer offered or not active, or a person denied,
  and the catalyst is minted, or revised, without a binding.

  A machine-minted revision admits the `interactive` and `programmatic`
  origins: the seed is the operator's own first-party install, run from
  its screens and from its command line and agents alike. A schedule or a
  webhook is admitted only by a person's grant naming it.

  ## Why provisioning is the only caller

  This mints a consent nobody was asked for, which `Sanctum.Consent.Authz`
  otherwise forbids — so what it mints over has to be code the operator
  already vouched for. At provisioning that holds: the bundle ships in the
  image, the `seed-guards` CI job makes shipped version directories
  immutable, and its caps are auditable once at build time rather than per
  athanor.

  The athanor's agents (`agent:local.<name>`, read through the
  component-facts port) are sources here too, minted after the components
  they run on. A source is minted only while it is vouched for — the
  seed's own bytes, or a head that already names it unchanged. A
  member-authored agent or component, and an edited shipped copy, consent
  through the walk.

  Bootstrap consent applies only to the operator's seed bundle.
  Components discovered by `component.register` require explicit consent.
  """

  require Logger

  alias Prima.Authority.Blob
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.Components
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Prima.AgentRef
  alias Prima.ComponentRow
  alias Prima.JCS

  @type result :: %{
          minted: [String.t()],
          revised: [String.t()],
          skipped: [{String.t(), term()}]
        }

  # Dependencies before the sources that select them; roles before the
  # soul that clones into them.
  @type_rank %{"catalyst" => 0, "reagent" => 1, "tincture" => 2, "formula" => 3, "agent" => 4}

  # The profile a shipped source's selection names on a shipped dependency.
  @selected_label "default"

  # The origins a machine-minted revision admits.
  @seeded_origins [:interactive, :programmatic]

  # The stores' declared outage terms, as `Sanctum.Consent.Plan` reads
  # them: a store that could not answer.
  @outages [:database_error, :unavailable]

  @doc """
  Bootstrap every executable local component in the caller's athanor.

  `granted_by` names who the mint is attributed to: the person whose
  sign-in provisioned the athanor (`ctx.user_id` when a person), or
  `"system:bootstrap"` for a server-side mint (a seed context).

  `claim` is the provisioning claim the walk runs under
  (`Arca.ProvisioningClaims`): the walk starts, and each source is minted
  or revised, only while the athanor's claim still reads that owner and
  fence with no outcome. A walk whose claim a later attempt took answers
  `{:error, :claim_lost}` — what it minted before the loss stands, since
  it held the athanor then, and nothing is minted after. With no claim
  (`nil`) the walk is unfenced: an athanor nothing else is filling.

  Answers `{:error, {:component_facts, reason}}` when the athanor's
  component facts cannot be read (`Sanctum.Consent.Components`). That is
  not "nothing is vouched for": a walk that cannot see what the seed ships
  would skip every source as unvouched and report a clean, empty mint, so
  it refuses instead, in a word no missing component and no denial shares.
  """
  # The claim is the row `Arca.ProvisioningClaims` hands back, not a map
  # shaped like one: `holding/2` matches it structurally, which a struct
  # satisfies, but the spec has to name what actually arrives or every
  # caller that passes a real claim reads as a call that cannot succeed.
  @spec run(Context.t(), Sanctum.Provisioning.claim() | nil) ::
          {:ok, result()} | {:error, :claim_lost | {:component_facts, term()}}
  def run(%Context{} = ctx, claim \\ nil) do
    with :ok <- holding(ctx, claim),
         {:ok, result} <- walk(ctx, claim) do
      if Enum.any?(result.skipped, &match?({_ref, :claim_lost}, &1)),
        do: {:error, :claim_lost},
        else: {:ok, result}
    end
  end

  # Whether the athanor's claim is still the one this walk runs under.
  defp holding(_ctx, nil), do: :ok

  defp holding(%Context{} = ctx, %{owner: owner, fence: fence}) do
    case Arca.ProvisioningClaims.current(Context.actor(ctx)) do
      {:ok, %{owner: ^owner, fence: ^fence, outcome: nil}} -> :ok
      _ -> {:error, :claim_lost}
    end
  end

  defp walk(ctx, claim) do
    with {:ok, agents} <- agent_rows(ctx),
         components = sources(ctx, agents),
         # The releases the seed itself ships, at the seed's own digest —
         # never the athanor's copy; an edited shipped unit is absent from
         # the map. With the facts unreadable the walk refuses rather than
         # reading an unreadable athanor as one the operator vouched
         # nothing for, which would skip every source and report a clean,
         # empty mint.
         {:ok, shipped} <- Components.shipped_nodes(ctx, components) do
      run_components({ctx, claim}, components, shipped)
    end
  end

  defp sources(ctx, agents) do
    (executable_local_components(ctx) ++ agents)
    |> Enum.sort_by(fn row ->
      {Map.get(@type_rank, to_string(row.component_type), 9), soul?(row), row.name}
    end)
  end

  # `held` is the context and the claim the walk runs under, carried to
  # the two writes the claim fences.
  defp run_components(held, components, shipped_nodes) do
    {minted, revised, skipped} =
      Enum.reduce(components, {[], [], []}, fn component, {minted, revised, skipped} ->
        source_ref = ComponentRow.node_key(component)

        case bootstrap_component(held, component, source_ref, shipped_nodes) do
          {:ok, _profile_id} -> {[source_ref | minted], revised, skipped}
          {:revised, _profile_id} -> {minted, [source_ref | revised], skipped}
          {:skip, reason} -> {minted, revised, [{source_ref, reason} | skipped]}
          {:error, reason} -> {minted, revised, [{source_ref, reason} | skipped]}
        end
      end)

    {:ok,
     %{
       minted: Enum.reverse(minted),
       revised: Enum.reverse(revised),
       skipped: Enum.reverse(skipped)
     }}
  end

  # An athanor whose agent files cannot be listed bootstraps no agent and
  # goes on: the components are a separate roster and a transient tree
  # read must not hold them up. Facts that are not configured at all are
  # a different thing and refuse the walk — see `run/2`.
  defp agent_rows(ctx) do
    case Components.agent_rows(ctx) do
      {:ok, rows} ->
        {:ok, rows}

      {:error, :component_facts_unavailable = reason} ->
        {:error, {:component_facts, reason}}

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Consent.Bootstrap] agent listing failed for " <>
            "#{ctx.athanor_id}: #{inspect(reason)}; bootstrapping no agent"
        )

        {:ok, []}
    end
  end

  defp agent?(row), do: to_string(row.component_type) == AgentRef.type()
  defp soul?(row), do: agent?(row) and AgentRef.soul?(row.name)

  defp executable_local_components(ctx) do
    # Every valid type is profile-bearing: tinctures are not executable,
    # but a profile is what makes one invocable at all — the route selects
    # it. Owner profiles mint here; public ones only via profile.publish.
    types = Prima.ComponentRef.valid_types()

    case Arca.ComponentStorage.list_components(Sanctum.Context.actor(ctx),
           publisher: Prima.ComponentPath.default_publisher(),
           limit: :none
         ) do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row -> to_string(row.component_type) in types end)
        |> Enum.group_by(fn row -> {row.component_type, row.name} end)
        |> Enum.map(fn {_key, versions} -> ComponentRow.latest_of(versions) end)

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Consent.Bootstrap] component listing failed for " <>
            "#{ctx.athanor_id}: #{inspect(reason)}; bootstrapping nothing"
        )

        []
    end
  end

  defp bootstrap_component({ctx, _claim} = held, component, source_ref, shipped_nodes) do
    case claimed(ctx, source_ref) do
      :unclaimed ->
        vouched = %{shipped: shipped_nodes, named: %{}, selected: MapSet.new()}

        if vouched?(vouched, source_ref, release_digest(component)) do
          mint(held, component, source_ref, vouched)
        else
          {:skip, :not_vouched}
        end

      {:claimed, nil} ->
        {:skip, :already_bootstrapped}

      {:claimed, profile} ->
        case Arca.ConsentStorage.get_head(Sanctum.Context.actor(ctx), profile.id) do
          {:ok, %{granted_via: "bootstrap"} = head, refs} ->
            with {:ok, blob} <- head_blob(profile.id, head) do
              vouched = vouched_by(head, blob, shipped_nodes)
              revise_bootstrap(held, component, source_ref, profile, {head, refs}, vouched)
            end

          {:ok, _person_head, _refs} ->
            {:skip, :already_bootstrapped}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claimed(ctx, source_ref) do
    case Arca.ProfileStorage.list_for_source(Sanctum.Context.actor(ctx), source_ref) do
      {:ok, []} -> :unclaimed
      {:ok, existing} -> {:claimed, default_owner(existing)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_owner(profiles),
    do: Enum.find(profiles, &(&1.kind == "owner" and &1.label == "default"))

  # A machine-minted revision binds no entry of the athanor's: a vouched
  # edge selects what its vouched dependency's default profile binds, an
  # edge whose need the vouched source provides carries that
  # configuration, and every other edge carries no vault resource. The
  # source's own ingress binds the one instance entry its person is
  # offered for its need, when there is exactly one (the moduledoc).
  defp mint({ctx, claim}, component, source_ref, vouched) do
    with {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, binding} <- first_sign_in_binding(ctx, component, source_ref, activation.graph),
         {:ok, nodes} <-
           BlobBuilder.build(ctx, activation.graph, source_ref, source_vault(source_ref, binding),
             source_row: component,
             edge_vault_fn: selection_fn(activation.graph, vouched)
           ),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <-
           compute_digests(ctx, source_ref, JCS.hash_binary(blob_json), List.wrap(binding)),
         {:ok, activation_json} <- JCS.encode(activation.graph),
         :ok <- holding(ctx, claim) do
      insert(ctx, source_ref, blob_json, digests, activation_json, BlobBuilder.vault_refs(nodes))
    end
  end

  defp source_vault(_source_ref, nil), do: fn _node_key, _row, _manifest -> nil end

  defp source_vault(source_ref, binding) do
    fn node_key, _row, _manifest ->
      if node_key == source_ref, do: BlobBuilder.vault_resource(binding)
    end
  end

  # ---------------------------------------------------------------------------
  # The instance's entry at first sign-in
  # ---------------------------------------------------------------------------

  # The person a mint runs for, or none: a server-side mint names none.
  defp person?(%Context{auth_method: :system}), do: false
  defp person?(%Context{}), do: true

  # The one need of a shipped catalyst an instance entry can meet — it
  # attaches, and the component never reads it — or nil when it has none
  # or several. A stored manifest that does not decode declares no need
  # this walk can read: the source is skipped as damaged, as its shape
  # derivation refuses it, never bound or minted as one with no need.
  defp instance_need(component, source_ref) do
    with "catalyst" <- to_string(component.component_type),
         {:ok, manifest} <- Prima.Manifest.decode_strict(Map.get(component, :manifest)),
         needs when is_list(needs) <- Prima.Manifest.Needs.from_manifest(manifest),
         [need] <-
           Enum.filter(needs, fn need ->
             need.kind in ~w(api_key oauth bundle) and is_map(need.attach) and
               need.disclose != true
           end) do
      need
    else
      {:error, :malformed_manifest} -> {:skip, {:corrupt, {:manifest, source_ref}}}
      _none_or_several -> nil
    end
  end

  # The instance entry a newly provisioned athanor's catalyst binds:
  # exactly one active entry offered to the walk's person of the need's
  # kind and provider, holding its scopes as a consent holds them, whose
  # component policy admits the shipped catalyst at its release digest.
  # `{:ok, nil}` when nothing is offered: no person, no such entry,
  # several, or a chosen entry the binding read answers is not usable.
  # A read the store could not answer, or a manifest that does not
  # decode, skips the source instead, since this mint is the only one
  # that binds.
  defp first_sign_in_binding(ctx, component, source_ref, graph) do
    with true <- person?(ctx),
         %{} = need <- instance_need(component, source_ref),
         {:ok, offered} <- offered(ctx, source_ref),
         facts = Sanctum.Consent.Plan.node_facts(source_ref, graph, %{source_ref => component}),
         [entry] <-
           Enum.filter(offered, fn entry ->
             entry.kind == need.kind and entry.provider_hint == need.qualifier and
               scopes_held?(entry, need) and Sanctum.InstanceEntries.admits?(ctx, entry, facts)
           end),
         {:ok, view} <- entry_binding(ctx, entry.id, source_ref) do
      {:ok, instance_binding(view, need)}
    else
      {:skip, _unread_or_damaged} = skip ->
        skip

      {:refused, reason} ->
        Logger.warning(
          "[Sanctum.Consent.Bootstrap] no instance entry bound for #{source_ref}: " <>
            "#{inspect(reason)}"
        )

        {:ok, nil}

      _nothing_offered ->
        {:ok, nil}
    end
  end

  # The entries offered to the walk's person, read as
  # `Sanctum.Consent.Plan` reads the same call: an outage is the read
  # unanswered, never an empty offer; any other refusal says the context
  # has no person to offer anything to, and nothing is offered.
  defp offered(ctx, source_ref) do
    case Sanctum.InstanceEntries.offered(ctx) do
      {:ok, offered} -> {:ok, offered}
      {:error, outage} when outage in @outages -> unanswered(source_ref, outage)
      {:error, _no_person} -> {:ok, []}
    end
  end

  # The entry `entry_id` as the person's consent binds it, for a first
  # mint's chosen entry and for the entry a revision under a person keeps.
  # An outage of the store is the read unanswered; any other refusal (the
  # entry no longer offered or not active, the person denied or
  # anonymous) offers nothing usable.
  defp entry_binding(ctx, entry_id, source_ref) do
    case Sanctum.InstanceEntries.binding(ctx, entry_id) do
      {:ok, view} -> {:ok, view}
      {:error, outage} when outage in @outages -> unanswered(source_ref, outage)
      {:error, reason} -> {:refused, reason}
    end
  end

  defp unanswered(source_ref, reason) do
    Logger.warning(
      "[Sanctum.Consent.Bootstrap] #{source_ref} skipped: Instance entries could not " <>
        "answer (#{inspect(reason)}); a later run tries again"
    )

    {:skip, {:unavailable, "Instance entries"}}
  end

  # An OAuth need is met by an entry authorized for exactly its scopes:
  # a bootstrap narrows nothing.
  defp scopes_held?(%{kind: "oauth"} = entry, need),
    do: Enum.sort(Enum.uniq(entry.oauth_scopes)) == Enum.sort(Enum.uniq(need.scopes))

  defp scopes_held?(_entry, _need), do: true

  defp instance_binding(view, need) do
    with %{} = map <- view.destination,
         {:ok, destination} <- Prima.Destination.from_map(map),
         digest when is_binary(digest) <- view.binding_digest do
      %{
        need: need.name,
        entry_id: view.id,
        binding_digest: digest,
        scope: "instance",
        destination: Prima.Destination.to_map(destination),
        attach: Prima.Manifest.Needs.attach_to_map(need.attach),
        fields: need.fields,
        scopes: need.scopes,
        lifetime: %{kind: "standing", until: nil},
        renew: false
      }
    else
      _ -> nil
    end
  end

  # What a revision of a bootstrap-only head keeps of its instance
  # binding: under a person, the same entry, still offered to them at the
  # digest the head bound, still admitted for the node at its new release
  # digest, for the need that admits it now; with no person, the head's
  # binding carried as the head holds it. Nothing otherwise, and never a
  # binding the head lacked.
  defp kept_binding(ctx, {profile, head, refs}, component, source_ref, graph) do
    if person?(ctx),
      do: offered_binding(ctx, head, component, source_ref, graph),
      else: carried_binding({profile.id, head, refs}, component, source_ref)
  end

  # Under a person, a binding read the store could not answer keeps the
  # head as it is, the source skipped, rather than revising it without the
  # entry it bound.
  defp offered_binding(ctx, head, component, source_ref, graph) do
    with {:ok, blob} <- Prima.Authority.Blob.parse(head.resolved_policy),
         {:ok, %{vault: %{scope: "instance", entry_id: id, binding_digest: digest}}} <-
           Prima.Authority.Blob.ingress(blob, source_ref),
         %{} = need <- instance_need(component, source_ref),
         {:ok, view} <- entry_binding(ctx, id, source_ref),
         true <- is_binary(view.binding_digest) and view.binding_digest == digest,
         true <- view.kind == need.kind and view.provider_hint == need.qualifier,
         true <- scopes_held?(view, need),
         true <-
           Sanctum.InstanceEntries.admits?(
             ctx,
             view,
             Sanctum.Consent.Plan.node_facts(source_ref, graph, %{source_ref => component})
           ) do
      {:ok, instance_binding(view, need)}
    else
      {:skip, _unread_or_damaged} = skip -> skip
      _ -> {:ok, nil}
    end
  end

  # A boot's seed sync has no person to read the offer as, so its revision
  # chooses nothing: it carries the head's instance binding row as the head
  # holds it — the entry, the digest, the key and the lifetime — with the
  # destination it was bound at, onto the need that admits an instance
  # entry now (a need the component reads itself is never met by one),
  # while the entry is still of that need's kind and provider, holds an
  # OAuth need's scopes as a first binding must, is active, and is at the
  # digest the head bound (`Sanctum.InstanceEntries.binding_facts/1`).
  # Any fact moved, or the entry is gone, and the revision binds none. A
  # store that cannot answer decides nothing: the source is skipped this
  # boot with the head kept, rather than revised without its binding, as
  # the walk refuses facts it cannot read rather than reading them as
  # none. A revoke landing after the facts are read meets the revision's
  # storage lock, which the walk reports as the source's skip, and
  # `Sanctum.Attach` holds each request to the audience, the policy and
  # the caps. A head the revision cannot read whole — a policy that does
  # not parse, or an ingress binding no ref row holds — is the profile
  # damaged: the source is skipped with the head kept, never revised as
  # a head that bound nothing.
  defp carried_binding({profile_id, head, refs}, component, source_ref) do
    with {:ok, blob} <- head_blob(profile_id, head),
         {:ok, %{vault: %{scope: "instance", entry_id: id, binding_key: key} = vault}} <-
           Prima.Authority.Blob.ingress(blob, source_ref),
         {:ok, row} <- carried_row(profile_id, refs, key, id),
         %{} = need <- instance_need(component, source_ref),
         {:ok, facts} <- entry_facts(id),
         true <- still_holds?(facts, need, vault.binding_digest) do
      {:ok,
       %{
         need: need.name,
         entry_id: id,
         binding_digest: vault.binding_digest,
         scope: "instance",
         destination: Prima.Destination.to_map(vault.destination),
         attach: Prima.Manifest.Needs.attach_to_map(need.attach),
         fields: need.fields,
         scopes: need.scopes,
         lifetime: %{kind: row.lifetime_kind, until: row.expires_at},
         renew: false
       }}
    else
      {:skip, _damaged} = skip -> skip
      {:unanswered, reason} -> {:error, reason}
      _ -> {:ok, nil}
    end
  end

  defp head_blob(profile_id, head) do
    case Blob.parse(head.resolved_policy) do
      {:ok, blob} -> {:ok, blob}
      {:error, _unparsed} -> {:skip, {:corrupt, {:profile, profile_id}}}
    end
  end

  defp carried_row(profile_id, refs, key, entry_id) do
    case Enum.find(refs, &(&1.binding_key == key and &1.instance_entry_id == entry_id)) do
      %{} = row -> {:ok, row}
      nil -> {:skip, {:corrupt, {:profile, profile_id}}}
    end
  end

  defp entry_facts(id) do
    case Sanctum.InstanceEntries.binding_facts(id) do
      {:ok, facts} -> {:ok, facts}
      {:error, :not_found} -> :gone
      {:error, reason} -> {:unanswered, reason}
    end
  end

  defp still_holds?(facts, need, digest) do
    facts.kind == need.kind and facts.provider_hint == need.qualifier and
      scopes_held?(facts, need) and facts.status == "active" and is_binary(digest) and
      facts.binding_digest == digest
  end

  # What a bootstrap-only head vouches for beside the seed: the nodes its
  # activation names, at those digests, and the ones its blob selects.
  defp vouched_by(head, blob, shipped_nodes) do
    named =
      case Jason.decode(head.activation || "") do
        {:ok, %{} = graph} -> graph
        _ -> %{}
      end

    selected =
      for {from, %Blob.Node{edges: edges}} <- blob.nodes,
          {key, %Blob.Edge{vault: %{via: _}}} <- edges,
          {:ok, dep} <- [Blob.edge_target(key)],
          into: MapSet.new(),
          do: {from, dep}

    %{shipped: shipped_nodes, named: named, selected: selected}
  end

  # A node is vouched for at a digest when the seed ships it at that
  # digest, or the head already names it there.
  defp vouched?(%{shipped: shipped, named: named}, node_key, digest) when is_binary(digest) do
    Map.get(shipped, node_key) == digest or Map.get(named, node_key) == digest
  end

  defp vouched?(_vouched, _node_key, _digest), do: false

  # ---------------------------------------------------------------------------
  # Selections — a shipped source runs a shipped dependency with the key
  # bound on that dependency's own default profile
  # ---------------------------------------------------------------------------

  # Only what is vouched for selects and is selected — the seed's own, or
  # what the head already selected on that edge at an unchanged digest: a
  # person's own component consents through the walk, where the selection
  # is shown. An unvouched from never selects.
  #
  # A dependency edge holds one credential: when the vouched source
  # provides configuration for one of the dependency's needs and the
  # dependency declares no other, the edge carries that configuration;
  # when it provides two, or one beside another need a selection would
  # fill, the walk mints nothing on that edge.
  defp selection_fn(graph, vouched) do
    fn from, dep, row, manifest, provided ->
      digest = release_digest(row)
      from_vouched? = vouched?(vouched, from, Map.get(graph, from))

      dep_vouched? =
        Map.get(vouched.shipped, dep) == digest or
          (MapSet.member?(vouched.selected, {from, dep}) and
             Map.get(vouched.named, dep) == digest)

      case provided.covered do
        [{need, resource}] ->
          if from_vouched? and credential_needs(manifest) == [need], do: resource

        [_, _ | _] ->
          nil

        [] ->
          if from_vouched? and credential_needs(manifest) != [] and dep_vouched? do
            BlobBuilder.vault_resource(%{via: @selected_label})
          end
      end
    end
  end

  defp release_digest(row), do: Map.get(row, :release_digest) || Map.get(row, "release_digest")

  defp credential_needs(manifest) do
    case Prima.Manifest.Needs.from_manifest(manifest) do
      needs when is_list(needs) ->
        for need <- needs, need.kind in ~w(api_key oauth bundle), do: need.name

      _ ->
        []
    end
  end

  # A bootstrap-only head is re-minted when the seed moved its shape (see
  # `revisable/4`).
  defp revise_bootstrap({ctx, claim}, component, source_ref, profile, {head, refs}, vouched) do
    with {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, binding} <-
           kept_binding(ctx, {profile, head, refs}, component, source_ref, activation.graph),
         {:ok, nodes} <-
           BlobBuilder.build(ctx, activation.graph, source_ref, source_vault(source_ref, binding),
             source_row: component,
             edge_vault_fn: selection_fn(activation.graph, vouched)
           ),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <-
           compute_digests(ctx, source_ref, JCS.hash_binary(blob_json), List.wrap(binding)),
         :ok <- revisable(head, digests, activation.graph, vouched),
         {:ok, activation_json} <- JCS.encode(activation.graph),
         :ok <- holding(ctx, claim),
         {:ok, _consent} <-
           Arca.ConsentStorage.insert_revision(
             %{
               athanor_id: ctx.athanor_id,
               profile_id: profile.id,
               revision: head.revision + 1,
               scope: head.scope,
               pinned_version: head.pinned_version,
               invoke_mode: head.invoke_mode,
               shape_digest: digests.shape_digest,
               commit_digest: digests.commit_digest,
               blob_digest: digests.blob_digest,
               resolved_policy: blob_json,
               activation: activation_json,
               admitted_origins: @seeded_origins,
               granted_by: granted_by(ctx),
               granted_via: "bootstrap"
             },
             BlobBuilder.vault_refs(nodes),
             head.id
           ) do
      {:revised, profile.id}
    else
      {:skip, _} = skip -> skip
      {:error, reason} -> {:error, reason}
    end
  end

  # Under a moved shape, every node of the live closure must be vouched for
  # at its digest — a dependency a person installed, edited or pinned
  # elsewhere moves the shape too, and that is not the seed's.
  defp revisable(head, digests, graph, vouched) do
    cond do
      digests.shape_digest == head.shape_digest ->
        {:skip, :already_bootstrapped}

      Enum.all?(graph, fn {key, digest} -> vouched?(vouched, key, digest) end) ->
        :ok

      true ->
        {:skip, :shape_moved}
    end
  end

  defp resolve_activation(ctx, component) do
    case Components.resolve(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:skip, {:activation_unresolvable, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Digests + insert
  # ---------------------------------------------------------------------------

  defp compute_digests(ctx, source_ref, blob_digest, bindings) do
    # The stored shape and the loader's live shape must be one computation
    # (ShapeDerivation), or a freshly minted consent would flip straight to
    # needs_consent on its first load.
    #
    # A machine mint carries `blob_digest` for the same reason an operator's
    # does: it is what lets `Consent.Loader` refuse a `resolved_policy`
    # altered in place, and this path writes a policy over the whole
    # activation closure. This module inserts through its own `insert/6`
    # and never reaches `Commit.persist/6`, so hashing there would have
    # left every provisioning mint undigested.
    with {:ok, input} <- Sanctum.Consent.ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- ShapeDigest.compute(input),
         {:ok, commit_digest} <-
           CommitDigest.compute(%{
             shape_digest: shape_digest,
             blob_digest: blob_digest,
             # The label `insert/6` below mints under, spelled once here
             # so the digest describes the profile it actually creates.
             label: "default",
             kind: :owner,
             invoke_mode: :open_inert,
             origins: @seeded_origins,
             # The instance entry a first sign-in binds, or a revision
             # keeps, when there is one: what the revision decided, as a
             # commit's digest names it.
             bindings:
               Enum.map(bindings, fn binding ->
                 %{
                   need: binding.need,
                   instance_entry_id: binding.entry_id,
                   binding_digest: binding.binding_digest,
                   fields: binding.fields,
                   scopes: binding.scopes,
                   lifetime: digest_lifetime(binding.lifetime),
                   renew: false
                 }
               end)
           }) do
      {:ok,
       %{
         shape_digest: shape_digest,
         commit_digest: commit_digest,
         blob_digest: blob_digest
       }}
    end
  end

  # A lifetime as the commit digest reads it, as `Sanctum.Consent.Commit`
  # names one: its kind, and an `until`'s instant.
  defp digest_lifetime(%{kind: "until", until: %DateTime{} = until}),
    do: %{kind: "until", until: DateTime.to_iso8601(until)}

  defp digest_lifetime(%{kind: kind}), do: %{kind: kind}

  # A person's provisioning is attributed to the person; a server-side mint
  # (a seed context) to the system.
  defp granted_by(%Context{auth_method: :system}), do: "system:bootstrap"
  defp granted_by(%Context{user_id: user_id}) when is_binary(user_id), do: user_id
  defp granted_by(_), do: "system:bootstrap"

  defp insert(ctx, source_ref, blob_json, digests, activation_json, vault_refs) do
    profile_id = Prima.UUID7.generate_id("prof")

    # Profile and first revision commit together — a failed consent leg
    # must not leave an orphan profile with a NULL head.
    with {:ok, _consent} <-
           Arca.ConsentStorage.mint_profile_with_revision(
             %{
               id: profile_id,
               athanor_id: ctx.athanor_id,
               source_ref: source_ref,
               kind: "owner",
               label: "default",
               status: "active"
             },
             %{
               profile_id: profile_id,
               revision: 1,
               scope: "versionless",
               pinned_version: "",
               invoke_mode: "open_inert",
               shape_digest: digests.shape_digest,
               commit_digest: digests.commit_digest,
               blob_digest: digests.blob_digest,
               resolved_policy: blob_json,
               activation: activation_json,
               admitted_origins: @seeded_origins,
               granted_by: granted_by(ctx),
               granted_via: "bootstrap"
             },
             vault_refs
           ) do
      {:ok, profile_id}
    end
  end
end
