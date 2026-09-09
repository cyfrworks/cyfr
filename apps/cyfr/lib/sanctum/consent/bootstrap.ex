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

  Idempotent: a source ref that already has an owner profile is skipped.
  Machine-minted revisions record `granted_via: "bootstrap"`.

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

  @type result :: %{minted: [String.t()], skipped: [{String.t(), term()}]}

  @doc """
  Bootstrap every executable local component in the caller's athanor.

  `granted_by` names who the mint is attributed to: the person whose
  sign-in provisioned the athanor (`ctx.user_id` when a person), or
  `"system:bootstrap"` for a server-side mint (Home at boot, a seed context).
  """
  @spec run(Context.t()) :: {:ok, result()}
  def run(%Context{} = ctx) do
    run_components(ctx, executable_local_components(ctx))
  end

  defp run_components(ctx, components) do
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

  defp bootstrap_component(ctx, component, source_ref) do
    # Nothing legacy exists to point at: connections bind through the
    # walk, so machine-minted revisions carry no vault resource.
    vault_fn = fn _node_key, _row, _manifest -> nil end

    with :ok <- check_unclaimed(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, nodes} <- BlobBuilder.build(ctx, activation.graph, source_ref, vault_fn),
         {:ok, blob_json} <- BlobBuilder.encode(nodes),
         {:ok, digests} <- compute_digests(ctx, source_ref, JCS.hash_binary(blob_json)),
         {:ok, activation_json} <- JCS.encode(activation.graph) do
      insert(ctx, source_ref, blob_json, digests, activation_json, BlobBuilder.vault_refs(nodes))
    end
  end

  defp check_unclaimed(ctx, source_ref) do
    case Arca.ProfileStorage.list_for_source(ctx.athanor_id, source_ref) do
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
  # (Home at boot, a seed context) to the system.
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
