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

  alias Sanctum.Consent.BlobBuilder
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
    vault_fn = fn node_key, row, manifest -> vault_pointer(ctx, node_key, row, manifest) end

    with :ok <- check_unclaimed(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, nodes} <- BlobBuilder.build(ctx, activation.graph, source_ref, vault_fn),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <- compute_digests(source_ref, nodes),
         {:ok, activation_json} <- JCS.encode(activation.graph) do
      insert(ctx, source_ref, blob_json, digests, activation_json, BlobBuilder.vault_refs(nodes))
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

    # Profile and first revision commit together — a failed consent leg
    # must not leave an orphan profile with a NULL head.
    with {:ok, _consent} <-
           Arca.ConsentStorage.mint_profile_with_revision(
             %{
               id: profile_id,
               org_id: ctx.org_id,
               project_id: ctx.project_id,
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
               resolved_policy: blob_json,
               activation: activation_json,
               granted_by: "system:bootstrap",
               granted_via: "bootstrap"
             },
             vault_refs
           ) do
      {:ok, profile_id}
    end
  end
end
