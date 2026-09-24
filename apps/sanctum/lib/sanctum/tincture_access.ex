# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.TinctureAccess do
  @moduledoc """
  Centralized tincture visibility and access decisions.

  Private access (`get_private/3`) requires an authenticated `Sanctum.Context`
  and delegates authorization to `Context.authorize/2`.

  Public access (`get_public/3`) requires an unauthenticated `Sanctum.Context`
  (resolved from the URL's athanor segment by `public_context/1`).
  It does NOT call `Context.authorize` — that function rejects all
  unauthenticated contexts. Instead it checks whether an active public
  profile exists for the tincture (what `profile.publish` mints), then
  looks up the component through the component-facts port, and returns
  `:not_found` for both missing and private tinctures (indistinguishable
  404 to avoid leaking existence).

  Tincture lookups go through `Sanctum.Consent.Components` (the port the
  authoritative component store answers), not `Prism.TinctureRegistry` (a
  shell-only UI cache).
  """

  require Logger

  alias Cyfr.ComponentRef
  alias Sanctum.Consent.Components
  alias Sanctum.Context

  @doc """
  The public (unauthenticated) context for the athanor a tincture URL's
  segment names, for lookups in that athanor.

  The segment is the athanor's route slug: `@<namespace>` names a person's
  athanor, a bare slug a group's. Only an active athanor resolves; a
  missing, archived or otherwise inactive one is `{:error, :not_found}` —
  the URL never falls back to another athanor — and a store that cannot
  answer is `{:error, :unavailable}`, never a missing athanor.

  This is the serving and lookup path; nothing runs under it. The context
  that runs a tincture's catalyst is `Sanctum.build_tincture_context/2`'s.
  The context is athanor-scoped with `authenticated: false`, so the
  tenant-scoped reads downstream take it as they take any other, and
  visibility is still decided by whether an active public profile exists
  (`get_public/3`).
  """
  @spec public_context(String.t()) :: {:ok, Context.t()} | {:error, :not_found | :unavailable}
  def public_context("@" <> namespace) when namespace != "",
    do: namespace |> by_slug("person") |> public_in()

  def public_context(slug) when is_binary(slug) and slug != "",
    do: slug |> by_slug("group") |> public_in()

  def public_context(_segment), do: {:error, :not_found}

  defp by_slug(slug, kind), do: Sanctum.Tenancy.Athanors.get_by_slug(kind, slug)

  defp public_in({:ok, %{id: id, status: "active"}}) when is_binary(id),
    do: {:ok, Context.build(athanor_id: id, scope: :athanor, authenticated: false)}

  defp public_in({:ok, _inactive}), do: {:error, :not_found}
  defp public_in({:error, :not_found}), do: {:error, :not_found}
  defp public_in({:error, _unreadable}), do: {:error, :unavailable}

  @doc """
  Look up a tincture for authenticated/private access.
  """
  @spec get_private(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :forbidden}
  def get_private(%Context{} = ctx, publisher, tincture_name) do
    with :ok <- Context.authorize(ctx, :storage_read),
         :ok <- validate_refs(publisher, tincture_name) do
      case lookup_tincture(ctx, publisher, tincture_name) do
        {:ok, tincture} -> {:ok, tincture}
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      # An authorization refusal is 403; a malformed ref is an
      # indistinguishable 404. Branching on the refusal vocabulary, not on
      # the prose an English sentence happened to start with.
      {:error, reason} ->
        if Sanctum.Unauthorized.reason?(reason),
          do: {:error, :forbidden},
          else: {:error, :not_found}
    end
  end

  @doc """
  Look up a tincture for public/unauthenticated access.

  Requires a `%Sanctum.Context{}` with `authenticated: false`, built at
  the Phoenix boundary. MUST NOT call `Context.authorize/2-3` — that
  rejects unauthenticated contexts. Public visibility comes from a published
  profile (not the manifest). Returns `:not_found` for both missing and
  non-public tinctures (indistinguishable 404).
  """
  @spec get_public(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_public(%Context{} = ctx, publisher, tincture_name) do
    # The public route resolves the owning athanor before it gets here; a
    # context without one indicates a routing bug — fail closed.
    if ctx.athanor_id in [nil, ""] do
      Logger.warning(
        "[TinctureAccess] athanor unresolved for public tincture lookup: " <>
          "#{publisher}/#{tincture_name}"
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
    ref = Cyfr.ComponentRef.build("tincture", publisher, tincture_name)

    case Arca.ConsentStorage.profiles(Context.actor(ctx), ref) do
      {:ok, profiles} ->
        Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))

      _ ->
        false
    end
  end

  @doc """
  Look up a tincture via the authoritative registry without auth checks.

  Used for asset serving where sandboxed iframes (no allow-same-origin)
  cannot send cookies. Validates refs and resolves through the component-facts port.
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

  # Look up the latest tincture version through the port and enrich
  # with the Arca segments needed by controllers for asset serving.
  defp lookup_tincture(ctx, publisher, tincture_name) do
    case Components.get_latest(ctx, tincture_name, publisher, "tincture") do
      {:ok, component} ->
        {:ok, enrich_with_segments(component)}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp enrich_with_segments(component) do
    manifest = decode_manifest(component[:manifest] || component["manifest"])

    segments =
      Cyfr.ComponentPath.version_dir(
        component.component_type,
        component.publisher,
        component.name,
        component.version
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
