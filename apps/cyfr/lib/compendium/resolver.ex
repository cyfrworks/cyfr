# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Resolver do
  @moduledoc """
  The string-in/string-out adapter over the one resolver
  (`Compendium.Component.resolve_component/2`): callers that hold a ref
  STRING and want a pinned ref string plus audit metadata (the executor,
  schedules, webhooks) speak this shape; everything that touches the
  registry to answer it lives with the owner.

  Already-pinned references pass through with no registry lookup.

  ## Resolution Rules

  | Input | Resolution |
  |-------|-----------|
  | `c:local.claude:0.1.0` | Pass-through (already pinned) |
  | `c:local.claude` | Resolve to latest version |
  | `local.claude` | Error — type prefix required |

  ## Resolution Metadata

  Every resolution returns metadata for audit/telemetry:

      %{
        resolved_from: "c:local.claude",
        resolved_to: "catalyst:local.claude:0.1.0",
        was_resolved: true,
        resolved_at: ~U[...],
        digest: "sha256:abc..."
      }

  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.ComponentRef

  @type resolution_metadata :: %{
          resolved_from: String.t(),
          resolved_to: String.t(),
          was_resolved: boolean(),
          resolved_at: DateTime.t(),
          digest: String.t() | nil
        }

  @doc """
  Resolve a component reference to a pinned (exact-version) reference.

  Accepts both flexible refs (`c:local.claude`) and already-pinned refs
  (`catalyst:local.claude:0.1.0`). Type prefix is always required.

  Returns `{:ok, resolved_ref_string, metadata}` or `{:error, reason}`.
  """
  @spec resolve(Context.t(), String.t()) ::
          {:ok, String.t(), resolution_metadata()} | {:error, String.t()}
  def resolve(%Context{} = ctx, ref) when is_binary(ref) do
    case ComponentRef.normalize_flexible(ref) do
      {:ok, %ComponentRef{version: nil}} ->
        with {:ok, component, resolved} <- Compendium.Component.resolve_component(ctx, ref) do
          resolved_to =
            ComponentRef.to_string(%ComponentRef{
              type: resolved.type,
              namespace: resolved.namespace,
              name: resolved.name,
              version: resolved.version
            })

          {:ok, resolved_to,
           %{
             resolved_from: ref,
             resolved_to: resolved_to,
             was_resolved: true,
             resolved_at: DateTime.utc_now(),
             digest: component[:digest] || component["digest"]
           }}
        end

      {:ok, parsed} ->
        # Already pinned — pass through, no registry lookup.
        resolved_to = ComponentRef.to_string(parsed)

        {:ok, resolved_to,
         %{
           resolved_from: ref,
           resolved_to: resolved_to,
           was_resolved: false,
           resolved_at: DateTime.utc_now(),
           digest: nil
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Resolve a component reference, passing through already-pinned or unrecognized refs.

  This is the convenience wrapper for handlers (inspect, pull) that should:
  - Resolve typed version-less refs (e.g., `c:local.claude` → `catalyst:local.claude:0.1.0`)
  - Pass through already-pinned refs unchanged
  - Pass through unrecognized refs (OCI, untyped) for downstream handling
  - Only fail when a typed version-less ref can't be resolved

  Returns `{:ok, ref_string}` or `{:error, reason}`.
  """
  @spec resolve_or_passthrough(Context.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_or_passthrough(%Context{} = ctx, ref) when is_binary(ref) do
    case resolve(ctx, ref) do
      {:ok, pinned, _metadata} ->
        {:ok, pinned}

      {:error, _reason} ->
        Logger.debug("[Resolver] Passing through unresolvable ref: #{ref}")
        {:ok, ref}
    end
  end
end
