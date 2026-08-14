# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAccess do
  @moduledoc """
  Centralized tincture visibility and access decisions.

  Private access (`get_private/3`) requires an authenticated `Sanctum.Context`
  and delegates authorization to `Context.authorize/2`.

  Public access (`get_public/3`) requires an unauthenticated `Sanctum.Context`
  (built at the Phoenix boundary via `TinctureHelpers.build_public_context/0`).
  It does NOT call `Context.authorize` — that function rejects all
  unauthenticated contexts. Instead it checks whether an active public
  profile exists for the tincture (what `profile.publish` mints), then
  looks up the component via `Compendium.Registry`, and returns
  `:not_found` for both missing and private tinctures (indistinguishable
  404 to avoid leaking existence).

  Tincture lookups go through `Compendium.Registry` (the authoritative
  component store), not `Prism.TinctureRegistry` (a shell-only UI cache).
  """

  require Logger

  alias Sanctum.{Context, ComponentRef}

  @doc """
  Look up a tincture for authenticated/private access.
  """
  @spec get_private(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :forbidden}
  def get_private(%Context{} = ctx, publisher, tincture_name) do
    with :ok <- Context.authorize(ctx, :read),
         :ok <- validate_refs(publisher, tincture_name) do
      case lookup_tincture(ctx, publisher, tincture_name) do
        {:ok, tincture} -> {:ok, tincture}
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      {:error, "Unauthorized" <> _} -> {:error, :forbidden}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Look up a tincture for public/unauthenticated access.

  Requires a `%Sanctum.Context{}` with `authenticated: false`, built at
  the Phoenix boundary. MUST NOT call `Context.authorize/2-3` — that
  rejects unauthenticated contexts. Checks the tincture's policy `is_public`
  store (not the manifest) for public visibility. Returns `:not_found`
  for both missing and non-public tinctures (indistinguishable 404).
  """
  @spec get_public(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_public(%Context{} = ctx, publisher, tincture_name) do
    # Every context carries a resolved org_id (single-user installs use
    # `"local"`). An unresolved nil/"" org_id indicates a routing bug —
    # fail closed.
    if ctx.org_id in [nil, ""] do
      Logger.warning(
        "[TinctureAccess] org_id unresolved for public tincture lookup: #{publisher}/#{tincture_name}"
      )

      {:error, :not_found}
    else
      with :ok <- validate_refs(publisher, tincture_name),
           true <- tincture_public?(ctx, publisher, tincture_name) do
        case lookup_tincture(ctx, publisher, tincture_name) do
          {:ok, tincture} -> {:ok, tincture}
          {:error, :not_found} -> {:error, :not_found}
        end
      else
        _ -> {:error, :not_found}
      end
    end
  end

  # Public-ness is a published profile, not a policy bit: a tincture is
  # public exactly when an active public profile exists for it — what
  # profile.publish mints and profile.revoke retires.
  defp tincture_public?(ctx, publisher, tincture_name) do
    ref = "tincture:#{publisher}.#{tincture_name}"

    case Sanctum.Consent.Source.impl().profiles(ctx, ref) do
      {:ok, profiles} ->
        Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))

      _ ->
        false
    end
  end

  @doc """
  Look up a tincture via the authoritative registry without auth checks.

  Used for asset serving where sandboxed iframes (no allow-same-origin)
  cannot send cookies. Validates refs and resolves through Compendium.Registry.
  Does NOT check visibility — callers should use `get_public/3` for that.
  """
  @spec lookup(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup(%Context{} = ctx, publisher, tincture_name) do
    with :ok <- validate_refs(publisher, tincture_name) do
      lookup_tincture(ctx, publisher, tincture_name)
    else
      _ -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_refs(publisher, name),
    do: ComponentRef.validate_ref_parts(publisher, name)

  # Look up the latest tincture version via Compendium.Registry and enrich
  # with the Arca segments needed by controllers for asset serving.
  defp lookup_tincture(ctx, publisher, tincture_name) do
    case Compendium.Registry.get_latest(ctx, tincture_name, publisher, "tincture") do
      {:ok, component} ->
        {:ok, enrich_with_segments(component)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp enrich_with_segments(component) do
    manifest = decode_manifest(component[:manifest] || component["manifest"])

    segments =
      Compendium.ComponentPath.version_dir(
        component.component_type,
        component.publisher,
        component.name,
        component.version,
        {component.org_id, component.project_id}
      )

    component
    |> Map.put(:segments, segments)
    |> Map.put(:manifest, manifest)
  end

  defp decode_manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp decode_manifest(manifest) when is_map(manifest), do: manifest
  defp decode_manifest(_), do: %{}
end
