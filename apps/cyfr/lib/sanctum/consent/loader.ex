# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Loader do
  @moduledoc """
  Fail-closed construction of a root `Sanctum.Authority` from a profile's
  head consent.

  The checks run in a fixed order, each refusing rather than degrading:

  1. profile status — only `:active` roots an execution
  2. head consent exists
  3. consent internal validity (pinned ⟺ non-empty version — the database
     cannot enforce it portably, so the loader is the gate)
  4. the resolved policy blob parses (`Sanctum.Authority.Blob.parse/1`)
  5. **blob/refs equality** — every vault reference inside the blob must
     exactly equal the consent's stored `vault_refs`; any asymmetry means
     the blob and the reverse index disagree about what was granted, and
     the consent is refused
  6. the `Sanctum.Consent.Loader.Decision` table over granted vs installed
     activation
  7. `Sanctum.Authority.root/3` — ceiling clamping happens inside

  The live side of step 6 (`live` and `live_shape_digest`) is supplied by
  the caller, because resolving installed components is registry work the
  loader deliberately cannot do — its inputs stay inert data. A nil
  `live_shape_digest` compares as unknown and fails closed to
  `consent_required` on drift.
  """

  require Logger

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Consent.Loader.Decision
  alias Sanctum.Consent.Source
  alias Sanctum.ComponentRef
  alias Sanctum.Context
  alias Sanctum.JCS

  @type load_error ::
          Sanctum.Consent.error()
          | {:profile_unavailable, :needs_consent | :revoked}
          | {:no_head_consent, String.t()}
          | {:invalid_consent, atom()}
          | {:invalid_blob, Blob.error()}
          | {:blob_refs_mismatch, %{blob_only: [tuple()], refs_only: [tuple()]}}
          | {:integrity_alarm, [String.t()]}
          | {:invalid_profile, atom()}
          | {:unknown_source_node, String.t()}
          | {:missing_ingress, String.t()}

  @typedoc "What run_root stamps on the execution row."
  @type stamp :: %{activation_digest: String.t(), activation_graph: %{String.t() => String.t()}}

  @doc """
  Load the head consent of `profile` and build the root Authority.

  ## Options

  - `:live` — verified live activation (`Compendium.Activation.resolve_verified/2`
    result), required for the integrity evaluation
  - `:live_shape_digest` — the installed source's shape digest, nil = unknown
  - `:ceiling` — override the platform ceiling (tests only)
  - `:source` — override the configured `Sanctum.Consent.Source` (tests only)
  """
  @spec load_root(Context.t(), map(), keyword()) ::
          {:ok, Authority.t(), stamp()} | {:error, load_error()}
  def load_root(%Context{} = ctx, profile, opts \\ []) when is_map(profile) do
    source = Keyword.get(opts, :source, Source.impl())

    with :ok <- check_profile_status(profile),
         {:ok, consent} <- fetch_head(source, ctx, profile),
         :ok <- check_consent_validity(consent),
         {:ok, blob} <- parse_blob(consent),
         :ok <- check_blob_refs_equality(blob, consent),
         {:ok, running} <- evaluate_activation(ctx, profile, consent, opts),
         {:ok, authority} <- build_root(profile, consent, blob, running, opts) do
      {:ok, authority, %{activation_digest: running.digest, activation_graph: running.graph}}
    end
  end

  defp check_profile_status(%{status: :active}), do: :ok
  defp check_profile_status(%{status: status}), do: {:error, {:profile_unavailable, status}}
  defp check_profile_status(_), do: {:error, {:invalid_profile, :status}}

  defp fetch_head(source, ctx, profile) do
    case source.head_consent(ctx, profile.id) do
      {:ok, consent} -> {:ok, consent}
      {:error, _} -> {:error, {:no_head_consent, profile.id}}
    end
  end

  defp check_consent_validity(consent) do
    cond do
      consent.scope not in [:versionless, :pinned] ->
        {:error, {:invalid_consent, :scope}}

      consent.scope == :pinned and consent.pinned_version == "" ->
        {:error, {:invalid_consent, :pinned_version}}

      consent.scope == :versionless and consent.pinned_version != "" ->
        {:error, {:invalid_consent, :pinned_version}}

      not is_map(consent.activation) or consent.activation == %{} ->
        {:error, {:invalid_consent, :activation}}

      true ->
        :ok
    end
  end

  defp parse_blob(consent) do
    case Blob.parse(consent.resolved_policy) do
      {:ok, blob} -> {:ok, blob}
      {:error, reason} -> {:error, {:invalid_blob, reason}}
    end
  end

  # The blob is what runs; the refs are what "which profiles touch this
  # entry" queries answer from. If they disagree, one of them lies about
  # the grant, so neither is trusted.
  defp check_blob_refs_equality(blob, consent) do
    blob_refs = blob_vault_refs(blob)

    stored_refs =
      MapSet.new(consent.vault_refs, fn ref -> {ref.vault_entry_id, ref.binding_digest} end)

    if MapSet.equal?(blob_refs, stored_refs) do
      :ok
    else
      {:error,
       {:blob_refs_mismatch,
        %{
          blob_only: blob_refs |> MapSet.difference(stored_refs) |> Enum.sort(),
          refs_only: stored_refs |> MapSet.difference(blob_refs) |> Enum.sort()
        }}}
    end
  end

  defp blob_vault_refs(%Blob{nodes: nodes}) do
    for {_ref, node} <- nodes,
        {_key, edge} <- node.edges,
        edge.vault != nil,
        into: MapSet.new() do
      {edge.vault.entry_id, edge.vault.binding_digest}
    end
  end

  defp evaluate_activation(_ctx, profile, consent, opts) do
    live = Keyword.get(opts, :live, {:error, {:incomplete, :not_resolved}})
    shape = compare_shape(Keyword.get(opts, :live_shape_digest), consent.shape_digest)

    with {:ok, granted_digest} <- hash_activation(consent.activation) do
      case Decision.evaluate(consent.scope, granted_digest, live, shape, local_source?(profile)) do
        :allow ->
          {:ok, live_running(live)}

        {:allow_record, running} ->
          {:ok, running}

        outcome when outcome in [:needs_consent, :needs_consent_repin] ->
          if outcome == :needs_consent_repin do
            Logger.info("[Consent.Loader] local rebuild under pin — re-pin needed: #{profile.id}")
          end

          {:error,
           {:consent_required,
            %{profile_id: profile.id, current_revision: consent.revision, shape_diff: []}}}

        {:integrity_alarm, nodes} ->
          Logger.error(
            "[Consent.Loader] activation integrity alarm — release digest does not " <>
              "re-derive from its row: profile=#{profile.id} nodes=#{inspect(nodes)}"
          )

          :telemetry.execute(
            [:sanctum, :consent, :integrity_alarm],
            %{count: length(nodes)},
            %{profile_id: profile.id, nodes: nodes}
          )

          {:error, {:integrity_alarm, nodes}}

        {:setup_required, reason} ->
          {:error,
           {:setup_required,
            %{profile_id: profile.id, node_ref: profile.source_ref, need: "", reason: reason}}}
      end
    end
  end

  defp hash_activation(activation) do
    case JCS.hash(activation) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, {:invalid_consent, :activation}}
    end
  end

  defp compare_shape(nil, _stored), do: :unknown
  defp compare_shape(live, stored) when live == stored, do: :match
  defp compare_shape(_live, _stored), do: :differ

  defp local_source?(%{source_ref: source_ref}) do
    case ComponentRef.parse(source_ref) do
      {:ok, %ComponentRef{namespace: namespace}} ->
        Compendium.ComponentPath.local_publisher?(namespace)

      _ ->
        false
    end
  end

  defp live_running({:ok, %{digest: digest, graph: graph}}), do: %{digest: digest, graph: graph}

  defp build_root(profile, consent, blob, running, opts) do
    profile_map = %{
      profile_id: profile.id,
      consent_id: consent.id,
      source_ref: profile.source_ref,
      kind: profile.kind,
      invoke_mode: consent.invoke_mode,
      # D2 keys self-invocation on what is actually running, which under a
      # versionless consent may be newer than what the revision recorded.
      activation: running.graph
    }

    Authority.root(profile_map, blob, Keyword.take(opts, [:ceiling]))
  end
end
