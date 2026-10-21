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

  A store that cannot answer — the profiles that make a tincture public,
  or the component facts — is `{:error, :unavailable}`: never absence,
  never public, and alike for a private, an absent and a public tincture
  when it is the public check that cannot answer.

  Tincture lookups go through `Sanctum.Consent.Components` (the port the
  authoritative component store answers), not `Prism.TinctureRegistry` (a
  shell-only UI cache).
  """

  require Logger
  require Sanctum.Consent.Components

  alias Prima.ComponentRef
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
          {:ok, map()} | {:error, :not_found | :forbidden | :unavailable}
  def get_private(%Context{} = ctx, publisher, tincture_name) do
    with :ok <- Context.authorize(ctx, :storage_read),
         :ok <- validate_refs(publisher, tincture_name) do
      lookup_tincture(ctx, publisher, tincture_name)
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
  non-public tinctures (indistinguishable 404), and `:unavailable` when the
  profiles or the component facts cannot be read.
  """
  @spec get_public(Context.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
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
           {:ok, true} <- tincture_public(ctx, publisher, tincture_name) do
        lookup_tincture(ctx, publisher, tincture_name)
      else
        {:error, :unavailable} -> {:error, :unavailable}
        _malformed_or_not_public -> {:error, :not_found}
      end
    end
  end

  # Public-ness is a published profile, not a policy bit: a tincture is
  # public exactly when an active public profile exists for it — what
  # profile.publish mints and profile.revoke retires. A store that cannot
  # list the profiles has not said the tincture is private: it is
  # unavailable, and nothing is served.
  defp tincture_public(ctx, publisher, tincture_name) do
    ref = Prima.ComponentRef.build("tincture", publisher, tincture_name)

    case Arca.ConsentStorage.profiles(Context.actor(ctx), ref) do
      {:ok, profiles} ->
        {:ok, Enum.any?(profiles, &(&1.kind == :public and &1.status == :active))}

      {:error, _unreadable} ->
        {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_refs(publisher, name),
    do: ComponentRef.validate_ref_parts(publisher, name)

  # Look up the latest tincture version through the port and enrich
  # with the Arca segments needed by controllers for asset serving. Every
  # answer but absence is a store that did not say whether the tincture
  # exists: unavailable, never not found.
  defp lookup_tincture(ctx, publisher, tincture_name) do
    case Components.get_latest(ctx, tincture_name, publisher, "tincture") do
      {:ok, component} ->
        enrich_with_segments(component)

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} when Components.is_outage(reason) ->
        {:error, :unavailable}

      {:error, reason} ->
        Logger.warning(
          "[TinctureAccess] component facts unreadable for " <>
            "#{publisher}/#{tincture_name}: #{inspect(error_kind(reason))}"
        )

        {:error, :unavailable}
    end
  end

  # What a warning may say of an error the facts answered: its kind, never
  # its text. An exception's message and a term's strings can carry
  # storage detail, which redaction by field name does not remove, and a
  # map shaped like an exception may name no module at all. The kind is an
  # atom the log line spells, so no term of the callee's is inspected here.
  defp error_kind(%{__exception__: true, __struct__: module}) when is_atom(module), do: module
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_reason), do: :unknown

  defp enrich_with_segments(component) do
    with {:ok, manifest} <- decoded_manifest(Map.get(component, :manifest)) do
      segments =
        Prima.ComponentPath.version_dir(
          component.component_type,
          component.publisher,
          component.name,
          component.version
        )

      {:ok,
       component
       |> Map.put(:segments, segments)
       |> Map.put(:manifest, manifest)}
    end
  end

  # The port hands a row's manifest decoded, or as the bytes storage holds
  # when they do not decode to a JSON object
  # (`Compendium.ConsentFacts.get_component/5`). Those bytes, or no
  # manifest at all, are a declaration refused: the version holds no pages
  # and is not public, so it is not found here, publicly or privately.
  defp decoded_manifest(manifest) when is_map(manifest), do: {:ok, manifest}
  defp decoded_manifest(_undecoded), do: {:error, :not_found}
end
