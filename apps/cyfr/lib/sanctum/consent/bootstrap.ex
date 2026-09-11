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
  never touched by a person) in two cases: it lacks a selection its
  dependencies now declare under an unmoved shape, or its shape moved
  because the seed did — every node of the live closure is vouched for,
  so the revision is the same operator-vouched mint as the first. A node
  is vouched for when it is a shipped release, or when the head already
  names it at the same release digest: a release that retires the version
  an estate holds does not turn that unchanged copy into a person's own.
  A closure a person widened (an installed or edited dependency) or a
  head a person committed is theirs to consent again.

  Idempotent: a source ref that already has an owner profile is skipped
  (revised only as above). Machine-minted revisions record
  `granted_via: "bootstrap"`.

  ## Why provisioning is the only caller

  This mints a consent nobody was asked for, which `Sanctum.Consent.Authz`
  otherwise forbids — so what it mints over has to be code the operator
  already vouched for. At provisioning that holds: the bundle ships in the
  image, the `seed-guards` CI job makes shipped version directories
  immutable, and its caps are auditable once at build time rather than per
  athanor.

  Bootstrap consent applies only to the operator's seed bundle.
  Components discovered by `component.register` require explicit consent.
  """

  require Logger

  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Sanctum.JCS

  @type result :: %{
          minted: [String.t()],
          revised: [String.t()],
          skipped: [{String.t(), term()}]
        }

  # Dependencies before the sources that select them.
  @type_rank %{"catalyst" => 0, "reagent" => 1, "tincture" => 2, "formula" => 3}

  # The profile a shipped source's selection names on a shipped dependency.
  @selected_label "default"

  @doc """
  Bootstrap every executable local component in the caller's athanor.

  `granted_by` names who the mint is attributed to: the person whose
  sign-in provisioned the athanor (`ctx.user_id` when a person), or
  `"system:bootstrap"` for a server-side mint (a seed context).
  """
  @spec run(Context.t()) :: {:ok, result()}
  def run(%Context{} = ctx) do
    components =
      ctx
      |> executable_local_components()
      |> Enum.sort_by(fn row ->
        {Map.get(@type_rank, to_string(row.component_type), 9), row.name}
      end)

    # The shipped releases a live closure may consist of: the newest local
    # version of each component, when that version is the seed's own copy.
    shipped_nodes =
      components
      |> Enum.filter(&shipped?(ctx, &1))
      |> Map.new(&{Compendium.Activation.node_key(&1), &1.release_digest})

    run_components(ctx, components, shipped_nodes)
  end

  defp run_components(ctx, components, shipped_nodes) do
    {minted, revised, skipped} =
      Enum.reduce(components, {[], [], []}, fn component, {minted, revised, skipped} ->
        source_ref = Compendium.Activation.node_key(component)

        case bootstrap_component(ctx, component, source_ref, shipped_nodes) do
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

  defp executable_local_components(ctx) do
    # Every valid type is profile-bearing: tinctures are not executable,
    # but a profile is what makes one invocable at all — the route selects
    # it. Owner profiles mint here; public ones only via profile.publish.
    types = Sanctum.ComponentRef.valid_types()

    case Arca.ComponentStorage.list_components(ctx,
           publisher: Compendium.ComponentPath.default_publisher(),
           limit: :none
         ) do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row -> to_string(row.component_type) in types end)
        |> Enum.group_by(fn row -> {row.component_type, row.name} end)
        |> Enum.map(fn {_key, versions} -> Compendium.Registry.latest_of(versions) end)

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Consent.Bootstrap] component listing failed for " <>
            "#{ctx.athanor_id}: #{inspect(reason)}; bootstrapping nothing"
        )

        []
    end
  end

  defp bootstrap_component(ctx, component, source_ref, shipped_nodes) do
    case claimed(ctx, source_ref) do
      :unclaimed ->
        vouched = %{shipped: shipped_nodes, named: %{}, selected: MapSet.new()}
        mint(ctx, component, source_ref, selection_fn(component, source_ref, vouched))

      {:claimed, nil} ->
        {:skip, :already_bootstrapped}

      {:claimed, profile} ->
        case Arca.ConsentStorage.get_head(ctx.athanor_id, profile.id) do
          {:ok, %{granted_via: "bootstrap"} = head, _refs} ->
            vouched = vouched_by(head, shipped_nodes)
            vault_fn = selection_fn(component, source_ref, vouched)
            revise_bootstrap(ctx, component, source_ref, profile, head, vault_fn, vouched)

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
    case Arca.ProfileStorage.list_for_source(ctx.athanor_id, source_ref) do
      {:ok, []} -> :unclaimed
      {:ok, existing} -> {:claimed, default_owner(existing)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_owner(profiles),
    do: Enum.find(profiles, &(&1.kind == "owner" and &1.label == "default"))

  # A machine-minted revision binds no entry of its own: a vouched
  # source's edges select what its vouched dependencies' default profiles
  # bind, and every other edge carries no vault resource.
  defp mint(ctx, component, source_ref, vault_fn) do
    with {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, nodes} <- BlobBuilder.build(ctx, activation.graph, source_ref, vault_fn),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <- compute_digests(ctx, source_ref, JCS.hash_binary(blob_json)),
         {:ok, activation_json} <- JCS.encode(activation.graph) do
      insert(ctx, source_ref, blob_json, digests, activation_json, BlobBuilder.vault_refs(nodes))
    end
  end

  # What a bootstrap-only head vouches for beside the seed: the nodes its
  # activation names, at those digests, and the ones its blob selects.
  defp vouched_by(head, shipped_nodes) do
    named =
      case Jason.decode(head.activation || "") do
        {:ok, %{} = graph} -> graph
        _ -> %{}
      end

    selected =
      case Jason.decode(head.resolved_policy || "") do
        {:ok, %{"nodes" => nodes}} when is_map(nodes) ->
          for {_ref, node} <- nodes,
              {key, %{"vault" => %{"via" => _}}} <- node["edges"] || %{},
              into: MapSet.new(),
              do: key |> String.split("|", parts: 2) |> hd()

        _ ->
          MapSet.new()
      end

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
  # what the head already selected at an unchanged digest: a person's own
  # component consents through the walk, where the selection is shown.
  defp selection_fn(source_row, source_ref, vouched) do
    source_vouched? = vouched?(vouched, source_ref, release_digest(source_row))

    fn node_key, row, manifest ->
      digest = release_digest(row)

      dep_vouched? =
        Map.get(vouched.shipped, node_key) == digest or
          (MapSet.member?(vouched.selected, node_key) and
             Map.get(vouched.named, node_key) == digest)

      if node_key != source_ref and source_vouched? and credential_needs?(manifest) and
           dep_vouched? do
        %{"via" => %{"label" => @selected_label}}
      end
    end
  end

  defp release_digest(row), do: Map.get(row, :release_digest) || Map.get(row, "release_digest")

  defp shipped?(ctx, row) do
    unit =
      Compendium.ComponentPath.version_dir(
        to_string(Map.get(row, :component_type) || Map.get(row, "component_type")),
        Map.get(row, :publisher) || Map.get(row, "publisher"),
        Map.get(row, :name) || Map.get(row, "name"),
        Map.get(row, :version) || Map.get(row, "version")
      )

    Arca.Overlay.unit_status(ctx, unit) == {:ok, :shipped}
  end

  defp credential_needs?(manifest) do
    case Compendium.Manifest.Needs.from_manifest(manifest) do
      needs when is_list(needs) -> Enum.any?(needs, &(&1.kind in ~w(api_key oauth bundle)))
      _ -> false
    end
  end

  # A bootstrap-only head is re-minted when what a mint would produce today
  # differs from it in a way the seed alone accounts for (see
  # `revisable/5`).
  defp revise_bootstrap(ctx, component, source_ref, profile, head, vault_fn, vouched) do
    with {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, nodes} <- BlobBuilder.build(ctx, activation.graph, source_ref, vault_fn),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <- compute_digests(ctx, source_ref, JCS.hash_binary(blob_json)),
         :ok <- revisable(head, blob_json, digests, activation.graph, vouched),
         {:ok, activation_json} <- JCS.encode(activation.graph),
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

  # Under an unmoved shape, only the selections may differ. Under a moved
  # shape, every node of the live closure must be vouched for at its
  # digest — a dependency a person installed, edited or pinned elsewhere
  # moves the shape too, and that is not the seed's.
  defp revisable(head, blob_json, digests, graph, vouched) do
    cond do
      digests.shape_digest == head.shape_digest and blob_json == head.resolved_policy ->
        {:skip, :already_bootstrapped}

      digests.shape_digest == head.shape_digest ->
        if same_but_selections?(blob_json, head.resolved_policy),
          do: :ok,
          else: {:skip, :already_bootstrapped}

      Enum.all?(graph, fn {key, digest} -> vouched?(vouched, key, digest) end) ->
        :ok

      true ->
        {:skip, :shape_moved}
    end
  end

  defp same_but_selections?(blob_json, head_json) do
    with {:ok, fresh} <- Jason.decode(blob_json),
         {:ok, head} <- Jason.decode(head_json) do
      strip_selections(fresh) == strip_selections(head)
    else
      _ -> false
    end
  end

  defp strip_selections(%{"nodes" => nodes} = blob) do
    %{
      blob
      | "nodes" =>
          Map.new(nodes, fn {ref, node} ->
            edges =
              Map.new(node["edges"] || %{}, fn
                {key, %{"vault" => %{"via" => _}} = edge} -> {key, Map.delete(edge, "vault")}
                {key, edge} -> {key, edge}
              end)

            {ref, Map.put(node, "edges", edges)}
          end)
    }
  end

  defp strip_selections(other), do: other

  defp resolve_activation(ctx, component) do
    case Compendium.Activation.resolve(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:skip, {:activation_unresolvable, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Digests + insert
  # ---------------------------------------------------------------------------

  defp compute_digests(ctx, source_ref, blob_digest) do
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
             invoke_mode: :open_inert
           }) do
      {:ok,
       %{
         shape_digest: shape_digest,
         commit_digest: commit_digest,
         blob_digest: blob_digest
       }}
    end
  end

  # A person's provisioning is attributed to the person; a server-side mint
  # (a seed context) to the system.
  defp granted_by(%Context{auth_method: :system}), do: "system:bootstrap"
  defp granted_by(%Context{user_id: user_id}) when is_binary(user_id), do: user_id
  defp granted_by(_), do: "system:bootstrap"

  defp insert(ctx, source_ref, blob_json, digests, activation_json, vault_refs) do
    profile_id = Cyfr.UUID7.generate_id("prof")

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
               granted_by: granted_by(ctx),
               granted_via: "bootstrap"
             },
             vault_refs
           ) do
      {:ok, profile_id}
    end
  end
end
