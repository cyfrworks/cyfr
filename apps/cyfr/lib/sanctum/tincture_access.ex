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
  unauthenticated contexts. Instead it checks the tincture's policy for
  `is_public: true`, then looks up the component via `Compendium.Registry`,
  and returns `:not_found` for both missing and private tinctures
  (indistinguishable 404 to avoid leaking existence).

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

  # Check if a tincture is public by reading its policy's is_public field.
  defp tincture_public?(ctx, publisher, tincture_name) do
    ref = "tincture:#{publisher}.#{tincture_name}"

    case Sanctum.Policy.get_effective(ctx, ref) do
      {:ok, %{is_public: true}, _meta} -> true
      _ -> false
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

  @doc """
  Check if a component reference is in the tincture's manifest dependencies.

  The manifest's `dependencies.static` list acts as the invoke allowlist.
  Matches by type + namespace + name. If either the dep or invoke ref is
  versionless, any version matches. If both are pinned, versions must be equal.

  This check runs BEFORE the executor resolves versionless refs, so we must
  accept versionless invocations against pinned deps (and vice versa).
  """
  @spec can_invoke?(map(), String.t()) :: boolean()
  def can_invoke?(tincture_manifest, reference) when is_map(tincture_manifest) do
    deps = get_in(tincture_manifest, ["dependencies", "static"]) || []

    case ComponentRef.parse(reference) do
      {:ok, parsed} ->
        Enum.any?(deps, fn dep ->
          case ComponentRef.parse(dep["ref"] || "") do
            {:ok, dep_parsed} -> refs_match?(dep_parsed, parsed)
            _ -> false
          end
        end)

      _ ->
        false
    end
  end

  def can_invoke?(_, _), do: false

  # Match by type + namespace + name. If either side is versionless, match
  # any version — this is correct because can_invoke? runs BEFORE the
  # executor resolves versionless refs (Compendium.Resolver.resolve/2).
  # A tincture invoking "c:local.claude" (versionless) against a pinned
  # dep "c:local.claude:1.0.0" should succeed; the executor will resolve
  # the invoke ref to the correct installed version.
  defp refs_match?(dep, invoke) do
    dep.type == invoke.type &&
      dep.namespace == invoke.namespace &&
      dep.name == invoke.name &&
      (dep.version == nil || invoke.version == nil || dep.version == invoke.version)
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
