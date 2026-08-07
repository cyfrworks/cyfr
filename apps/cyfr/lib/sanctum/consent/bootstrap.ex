# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Bootstrap do
  @moduledoc """
  Convert a legacy install's effective policy into consents.

  For every executable local component without a profile, mints an owner
  profile and a revision-1 consent whose blob mirrors what the legacy
  resolver grants today: each closure node runs under its own effective
  policy's limits, the ingress edge carries the source's own resources,
  and every edge into a node carries **that node's** resources — the
  behavior-equivalence of the callee-keyed model, frozen into
  source-keyed form. Legacy credentials become sealed vault pointers so
  the vault reader can serve them until re-entry.

  Deliberately included: the manifest auto-merge widening inside
  `Sanctum.Policy.get_effective/2` — equivalence first, de-widening is a
  later, deliberate step measured by the equivalence oracle.

  Idempotent: a source ref that already has an owner profile is skipped.
  Machine-minted revisions record `granted_via: "bootstrap"`.
  """

  require Logger

  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Sanctum.JCS
  alias Sanctum.VaultReader

  @type result :: %{minted: [String.t()], skipped: [{String.t(), term()}]}

  @doc "Bootstrap every executable local component in the caller's tenant."
  @spec run(Context.t()) :: {:ok, result()}
  def run(%Context{} = ctx) do
    components = executable_local_components(ctx)

    {minted, skipped} =
      Enum.reduce(components, {[], []}, fn component, {minted, skipped} ->
        source_ref = Compendium.Activation.node_key(component)

        case bootstrap_component(ctx, component, source_ref) do
          {:ok, _profile_id} -> {[source_ref | minted], skipped}
          {:skip, reason} -> {minted, [{source_ref, reason} | skipped]}
          {:error, reason} -> {minted, [{source_ref, reason} | skipped]}
        end
      end)

    {:ok, %{minted: Enum.reverse(minted), skipped: Enum.reverse(skipped)}}
  end

  defp executable_local_components(ctx) do
    types = Enum.map(Sanctum.ComponentRef.executable_types(), &to_string/1)

    case Arca.ComponentStorage.list_components(ctx, publisher: "local") do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row -> to_string(row.component_type) in types end)
        |> Enum.group_by(fn row -> {row.component_type, row.name} end)
        |> Enum.map(fn {_key, versions} -> hd(versions) end)

      _ ->
        []
    end
  end

  defp bootstrap_component(ctx, component, source_ref) do
    with :ok <- check_unclaimed(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, nodes} <- build_nodes(ctx, activation.graph, source_ref),
         {:ok, blob_json} <- encode_blob(nodes),
         {:ok, digests} <- compute_digests(source_ref, nodes),
         {:ok, activation_json} <- JCS.encode(activation.graph) do
      insert(ctx, source_ref, blob_json, digests, activation_json, vault_refs(nodes))
    end
  end

  defp check_unclaimed(ctx, source_ref) do
    case Arca.ProfileStorage.list_for_source(ctx.org_id, ctx.project_id, source_ref) do
      {:ok, []} -> :ok
      {:ok, _existing} -> {:skip, :already_bootstrapped}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_activation(ctx, component) do
    case Compendium.Activation.resolve(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:skip, {:activation_unresolvable, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob construction
  # ---------------------------------------------------------------------------

  defp build_nodes(ctx, graph, source_ref) do
    Enum.reduce_while(Map.keys(graph), {:ok, %{}}, fn node_key, {:ok, acc} ->
      case build_node(ctx, node_key, source_ref) do
        {:ok, node} -> {:cont, {:ok, Map.put(acc, node_key, node)}}
        {:error, reason} -> {:halt, {:error, {node_key, reason}}}
      end
    end)
  end

  defp build_node(ctx, node_key, source_ref) do
    with {:ok, row} <- node_row(ctx, node_key),
         {:ok, policy, _meta} <- Sanctum.Policy.get_effective(ctx, node_key) do
      manifest =
        Compendium.Manifest.decode(Map.get(row, :manifest) || Map.get(row, "manifest"))

      resources = resource_map(policy)
      vault = vault_pointer(ctx, node_key, row, manifest)

      edges =
        manifest
        |> direct_dep_keys(node_key)
        |> Map.new(fn dep_key -> {dep_key, %{"__dep__" => dep_key}} end)

      edges =
        if node_key == source_ref do
          Map.put(edges, "@ingress", Map.put(resources, "__vault__", vault))
        else
          edges
        end

      {:ok,
       %{
         limits: limits_map(policy),
         resources: Map.put(resources, "__vault__", vault),
         edges: edges
       }}
    end
  end

  defp node_row(ctx, node_key) do
    case Sanctum.ComponentRef.parse(node_key) do
      {:ok, ref} ->
        case Compendium.Registry.get_latest(ctx, ref.name, ref.namespace, ref.type) do
          {:ok, row} -> {:ok, row}
          {:error, reason} -> {:error, {:missing_node_row, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_node_key, reason}}
    end
  end

  defp direct_dep_keys(manifest, node_key) do
    case Compendium.DependencyResolver.extract_from_manifest(manifest, node_key) do
      {:ok, deps} ->
        deps
        |> Enum.map(fn dep -> "#{dep.dep_type}:#{dep.dep_namespace}.#{dep.dep_name}" end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == node_key))

      {:error, _} ->
        []
    end
  end

  # Assemble the final blob: every edge A → B carries B's own resources,
  # which is exactly what the callee-keyed model grants B today.
  defp encode_blob(nodes) do
    encoded_nodes =
      Map.new(nodes, fn {node_key, node} ->
        edges =
          Map.new(node.edges, fn
            {"@ingress", resources} ->
              {"@ingress", finalize_edge(resources)}

            {dep_key, %{"__dep__" => dep_key}} ->
              {dep_key, finalize_edge(nodes[dep_key].resources)}
          end)

        {node_key, %{"limits" => node.limits, "edges" => edges}}
      end)

    JCS.encode(%{"canonical" => "jcs-1", "nodes" => encoded_nodes})
  end

  defp finalize_edge(resources) do
    {vault, rest} = Map.pop(resources, "__vault__")

    case vault do
      nil -> rest
      vault -> Map.put(rest, "vault", vault)
    end
  end

  defp limits_map(policy) do
    %{
      "timeout" => policy.timeout,
      "max_memory_bytes" => policy.max_memory_bytes,
      "max_request_size" => policy.max_request_size,
      "max_response_size" => policy.max_response_size,
      "rate_limit" => rate_limit_map(policy.rate_limit),
      "max_concurrent_tasks" => policy.max_concurrent_tasks,
      "batch_timeout" => policy.batch_timeout
    }
  end

  # A nil legacy rate limit means unchecked; the blob grammar requires a
  # map, so the ceiling's maximum is the closest expressible equivalent.
  defp rate_limit_map(nil), do: %{"requests" => 10_000, "window" => "1m"}

  defp rate_limit_map(%{requests: requests, window: window}),
    do: %{"requests" => requests, "window" => window}

  defp resource_map(policy) do
    %{
      "egress" => %{
        "domains" => policy.allowed_domains,
        "methods" => policy.allowed_methods,
        "schemes" => ["https", "http"],
        "private_ips" => policy.allowed_private_ips
      },
      "storage" => %{
        "paths" => policy.allowed_paths,
        "actions" => policy.allowed_actions
      },
      "tools" => expand_tools(policy.allowed_tools)
    }
  end

  # Tool grants are stored expanded: a pattern is not a stable capability,
  # so an action added upstream later is correctly outside this consent.
  defp expand_tools(patterns) do
    all = all_tool_actions()

    patterns
    |> Enum.flat_map(fn pattern ->
      cond do
        pattern == "*" -> all
        String.ends_with?(pattern, ".*") -> prefix_matches(all, pattern)
        pattern in all -> [pattern]
        true -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp prefix_matches(all, pattern) do
    prefix = String.trim_trailing(pattern, "*")
    Enum.filter(all, &String.starts_with?(&1, prefix))
  end

  defp all_tool_actions do
    for module <- Application.get_env(:cyfr, :tool_providers, []),
        tool <- module.tools(),
        {action, _annotation} <- get_in(tool, [:annotations, :actions]) || %{},
        do: "#{tool.name}.#{action}"
  end

  # ---------------------------------------------------------------------------
  # Vault pointers
  # ---------------------------------------------------------------------------

  defp vault_pointer(ctx, node_key, _row, manifest) do
    secrets = granted_secret_pointers(ctx, node_key)
    oauth = oauth_pointers(node_key, manifest)

    if secrets == [] and oauth == [] do
      nil
    else
      mint_entry(ctx, node_key, secrets, oauth)
    end
  end

  defp granted_secret_pointers(ctx, node_key) do
    # Grants list as plain secret names; the storage scope is the tenant
    # scope the rows were written under, which is what the pointer must
    # record for the reader's decrypt to find the same AAD.
    {scope, _org, _project} = Sanctum.TenantScope.extract(ctx)

    case Sanctum.Secrets.list_component_grants(ctx, node_key) do
      {:ok, names} ->
        names
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(fn name -> %{"name" => name, "scope" => scope} end)

      _ ->
        []
    end
  end

  defp oauth_pointers(node_key, manifest) do
    manifest
    |> Map.get("oauth", %{})
    |> Map.keys()
    |> Enum.map(fn provider -> %{"component_ref" => node_key, "provider" => provider} end)
  end

  defp mint_entry(ctx, node_key, secrets, oauth) do
    entry_id = Emissary.UUID7.generate_id("vlt")

    payload =
      Jason.encode!(%{"v" => 1, "legacy" => %{"secrets" => secrets, "oauth" => oauth}})

    provider_hint = "legacy"
    aad = Sanctum.CipherAAD.vault_entry(ctx.org_id, ctx.project_id, entry_id, provider_hint)

    {:ok, sealed} = Sanctum.Cipher.encrypt(payload, aad)

    field_names =
      Enum.map(secrets, & &1["name"]) ++ Enum.map(oauth, &"oauth:#{&1["provider"]}")

    attrs = %{
      id: entry_id,
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      name: "legacy:#{node_key}",
      provider_hint: provider_hint,
      kind: "bundle",
      provenance: "user",
      field_names: Jason.encode!(Enum.sort(field_names)),
      oauth_scopes: nil,
      oauth_endpoints: nil,
      status: "active",
      sealed_payload: sealed
    }

    {:ok, binding} = VaultReader.binding_digest(struct_like(attrs))

    case Arca.VaultStorage.put(Map.put(attrs, :binding_digest, binding)) do
      {:ok, entry} ->
        %{
          "entry_id" => entry.id,
          "binding_digest" => binding,
          "projection" => %{"fields" => Enum.sort(field_names)}
        }

      {:error, reason} ->
        Logger.error(
          "[Consent.Bootstrap] vault entry mint failed for #{node_key}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp struct_like(attrs) do
    %{
      provider_hint: attrs.provider_hint,
      field_names: attrs.field_names,
      oauth_endpoints: attrs.oauth_endpoints,
      oauth_scopes: attrs.oauth_scopes
    }
  end

  defp vault_refs(nodes) do
    for {_key, node} <- nodes,
        vault = node.resources["__vault__"],
        vault != nil,
        uniq: true do
      %{vault_entry_id: vault["entry_id"], binding_digest: vault["binding_digest"]}
    end
  end

  # ---------------------------------------------------------------------------
  # Digests + insert
  # ---------------------------------------------------------------------------

  defp compute_digests(source_ref, nodes) do
    ingress_tools =
      get_in(nodes, [source_ref, :resources, "tools"]) || []

    with {:ok, shape_digest} <-
           ShapeDigest.compute(%{
             scope: :versionless,
             source_ref: source_ref,
             tool_actions: ingress_tools
           }),
         {:ok, commit_digest} <-
           CommitDigest.compute(%{
             shape_digest: shape_digest,
             kind: :owner,
             invoke_mode: :open_inert
           }) do
      {:ok, %{shape_digest: shape_digest, commit_digest: commit_digest}}
    end
  end

  defp insert(ctx, source_ref, blob_json, digests, activation_json, vault_refs) do
    profile_id = Emissary.UUID7.generate_id("prof")

    with {:ok, _profile} <-
           Arca.ProfileStorage.put(%{
             id: profile_id,
             org_id: ctx.org_id,
             project_id: ctx.project_id,
             source_ref: source_ref,
             kind: "owner",
             label: "default",
             status: "active"
           }),
         {:ok, _consent} <-
           Arca.ConsentStorage.insert_revision(
             %{
               org_id: ctx.org_id,
               profile_id: profile_id,
               revision: 1,
               scope: "versionless",
               pinned_version: "",
               invoke_mode: "open_inert",
               shape_digest: digests.shape_digest,
               commit_digest: digests.commit_digest,
               resolved_policy: blob_json,
               activation: activation_json,
               granted_by: "system:bootstrap",
               granted_via: "bootstrap"
             },
             vault_refs,
             nil
           ) do
      {:ok, profile_id}
    end
  end
end
