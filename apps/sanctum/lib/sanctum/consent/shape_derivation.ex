# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDerivation do
  @moduledoc """
  The one computation of a component's consent *shape* from live state.

  Derives the shape at consent time and at load time. The loader compares
  these digests to decide whether a versionless release requires consent.

  The shape is manifest-sourced: it carries the declared needs, the
  flattened caps, the caps tools expanded against the live catalog, and
  the slot vocabulary (sorted need names). A manifest with no `needs` or
  `caps` blocks derives the empty ask — deny-all resources, no needs —
  exactly as if it declared empty blocks.

  Includes releases from the activation closure via `dependency_releases/3`,
  excluding the source’s own release. Dependency code changes alter the shape;
  source releases remain versionless when consent is versionless.

  The canonical caps encoding is dotted flat keys (`"egress.domains"`,
  `"limits.rate_limit.requests"`, …) over the digest's existing flat caps
  vocabulary — one spelling, no nesting grammar. Empty lists and absent
  limits are omitted: declaring nothing and asking for nothing are the
  same shape.

  A stored manifest that does not decode has no shape: every entry here
  answers `{:error, {:corrupt, {:manifest, source_ref}}}` for it, never the
  empty ask, which would read as a component that asks for nothing.

  A tincture that declares a frame, cards, streams or system actions
  (`Prima.Manifest.Tincture`) carries that declaration's digest as
  `tincture_digest`, so a version that declares more changes the shape and
  asks again; one that declares none carries no digest, and its shape is
  what it was before tinctures declared anything.

  A vault need names what its projection reads: every derived `api_key`
  or `bundle` need row carries a non-empty `fields` list and every
  `oauth` need row a non-empty `scopes` list, which the consent writes as
  the edge's projection. A need that declares none, or an empty list, has
  no projection to consent to, and the shape refuses it as a manifest
  error naming the need and the component (`{:invalid_argument,
  sentence}`), never as a need that reads everything its entry holds.
  """

  alias Prima.Manifest.Caps
  alias Prima.Manifest.Needs
  alias Prima.Manifest.Tincture
  alias Sanctum.Consent.Components
  alias Sanctum.Consent.ShapeDigest
  alias Prima.ToolPattern

  @doc """
  The live shape digest for a source ref, or `{:error, reason}` when the
  shape inputs cannot be read — the caller treats that as no live shape,
  which fails closed to `needs_consent`.
  """
  # The live shape is a function of the athanor's registered manifests: it
  # is cached briefly and swept when the registry changes. EVERY mutation
  # of the registry must run `Compendium.Registry.invalidate_executor_caches/1`
  # — register, delete, and the auto-indexer's stale sweep do today — or a
  # commit (which derives fresh) and the loader (which reads this cache)
  # would answer different shapes for up to a minute.
  @live_cache_ttl_ms :timer.seconds(60)

  # The list each vault need kind's projection names; the kinds not here
  # are component-typed and project nothing.
  @projection_lists %{"api_key" => :fields, "bundle" => :fields, "oauth" => :scopes}

  @spec live_digest(Sanctum.Context.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def live_digest(ctx, source_ref) do
    key = live_shape_key(ctx, source_ref)

    case key && Arca.Cache.get(key) do
      {:ok, digest} when is_binary(digest) ->
        {:ok, digest}

      _ ->
        with {:ok, input} <- shape_input(ctx, source_ref),
             {:ok, digest} <- ShapeDigest.compute(input) do
          if key, do: Arca.Cache.put(key, digest, @live_cache_ttl_ms)
          {:ok, digest}
        end
    end
  end

  defp live_shape_key(%Sanctum.Context{athanor_id: athanor_id}, source_ref)
       when is_binary(athanor_id) and athanor_id != "" and is_binary(source_ref),
       do: Arca.Cache.Keys.live_shape(Prima.Actor.in_athanor(athanor_id), source_ref)

  defp live_shape_key(_ctx, _source_ref), do: nil

  @doc """
  The `ShapeDigest.compute/1` input derived from live state. An agent
  source's shape also carries its model target (`catalyst#model`): the
  model an agent runs on is what it may do, so changing it re-asks.
  """
  @spec shape_input(Sanctum.Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shape_input(ctx, source_ref) do
    with {:ok, row, manifest} <- manifest_row(ctx, source_ref),
         {:ok, releases} <- dependency_releases(ctx, row, source_ref),
         needs = Needs.from_manifest(manifest) || [],
         :ok <- check_vault_projections(needs, source_ref),
         {:ok, tincture_digest} <- tincture_digest(manifest, source_ref),
         {:ok, caps} <- declared_caps(manifest, source_ref) do
      {:ok,
       %{
         scope: :versionless,
         source_ref: source_ref,
         needs: digest_needs(needs),
         caps: digest_caps(caps),
         tool_actions: expand_tools(caps.tools),
         slots: Enum.sort(Enum.map(needs, & &1.name)),
         dependency_releases: releases
       }
       |> Prima.MapUtil.put_present(:model_target, model_target(manifest))
       |> Prima.MapUtil.put_present(:tool_policy, tool_policy(manifest))
       |> Prima.MapUtil.put_present(:tincture_digest, tincture_digest)}
    end
  end

  # The frame declaration's digest, or nil for a manifest that declares
  # none. A stored declaration was held to its shapes when it was written,
  # so one that does not read is a damaged row, refused as the manifest is.
  defp tincture_digest(manifest, source_ref) do
    if Tincture.declared?(manifest) do
      case Tincture.from_manifest(manifest) do
        {:ok, declaration} -> {:ok, Tincture.digest(declaration)}
        {:error, _} -> {:error, {:corrupt, {:manifest, source_ref}}}
      end
    else
      {:ok, nil}
    end
  end

  defp model_target(manifest) do
    agent = manifest["agent"] || %{}

    case {manifest["type"], agent["catalyst"], agent["model"]} do
      {"agent", catalyst, model}
      when is_binary(catalyst) and catalyst != "" and is_binary(model) and model != "" ->
        "#{catalyst}##{model}"

      _ ->
        nil
    end
  end

  defp tool_policy(manifest) do
    case get_in(manifest, ["agent", "policy"]) do
      %{"auto" => auto, "ask" => ask} when is_list(auto) and is_list(ask) ->
        %{auto: auto, ask: ask}

      %{"auto" => auto} when is_list(auto) ->
        %{auto: auto, ask: []}

      %{"ask" => ask} when is_list(ask) ->
        %{auto: [], ask: ask}

      _ ->
        nil
    end
  end

  @doc """
  The activation closure's releases, EXCLUDING the source's own.

  Encoded as sorted `"<node_key>@<release_digest>"` strings — node keys are
  `type:publisher.name` and digests are `sha256:…`, so neither can contain
  the separator.

  ## Why the source is excluded, and why that keeps versionless working

  Include dependency releases in the shape so changed dependency code requires consent.

  Excluding the source's own release is what preserves the point of a
  versionless consent: re-publishing the source itself still moves the
  activation digest while leaving the shape alone, so it still lands on
  `{:allow_record, …}`. That arm stays live and load-bearing — only the
  DEPENDENCY case moves to `:needs_consent`.

  A closure that cannot be resolved contributes nothing rather than
  failing the shape: the loader has its own `{:incomplete, …}` path for an
  unresolvable world (`setup_required`), and a shape that errored here
  would report the wrong thing. A source whose own manifest does not
  decode is not an unresolvable world but a damaged row: its closure would
  resolve to the source alone, so it is refused as corrupt instead.
  """
  @spec dependency_releases(Sanctum.Context.t(), map(), String.t()) ::
          {:ok, [String.t()]} | {:error, {:corrupt, {:manifest, String.t()}}}
  def dependency_releases(ctx, row, source_ref) do
    with {:ok, _manifest} <- manifest(row, source_ref) do
      case Components.resolve(ctx, row) do
        {:ok, %{graph: graph}} when is_map(graph) ->
          {:ok,
           graph
           |> Enum.reject(fn {node_key, _digest} -> node_key == source_ref end)
           |> Enum.map(fn {node_key, digest} -> "#{node_key}@#{digest}" end)
           |> Enum.sort()}

        _unresolvable ->
          {:ok, []}
      end
    end
  end

  @doc """
  The declared manifest blocks for a source ref's latest release:
  `{:ok, needs, caps}` with `nil` for an absent block, or an error when
  the row cannot be read, its manifest does not decode, or its caps block
  no longer meets the grammar (`declared_caps/2`).
  """
  @spec manifest_blocks(Sanctum.Context.t(), String.t()) ::
          {:ok, [map()] | nil, map() | nil} | {:error, term()}
  def manifest_blocks(ctx, source_ref) do
    with {:ok, _row, manifest} <- manifest_row(ctx, source_ref),
         {:ok, caps} <- declared_caps(manifest, source_ref) do
      {:ok, Needs.from_manifest(manifest), if(Map.has_key?(manifest, "caps"), do: caps)}
    end
  end

  @doc """
  What a stored manifest's `caps` block asks for: the block normalized,
  `Prima.Manifest.Caps.empty/0` for a manifest that declares none, and
  `{:error, {:corrupt, {:manifest, source_ref}}}` for a block that is
  present but does not meet the grammar — a release published before a
  rule it now breaks (a storage path spelled other than the door reaches
  it, say). Such a block is refused, never read as asking for nothing.
  """
  @spec declared_caps(map(), String.t()) ::
          {:ok, map()} | {:error, {:corrupt, {:manifest, String.t()}}}
  def declared_caps(manifest, source_ref) when is_map(manifest) do
    case Caps.from_manifest(manifest, &Arca.Storage.valid_guest_path?/1) do
      %{} = caps ->
        {:ok, caps}

      nil ->
        if Map.has_key?(manifest, "caps"),
          do: {:error, {:corrupt, {:manifest, source_ref}}},
          else: {:ok, Caps.empty()}
    end
  end

  # The row rides along for `shape_input/2`, which needs it to resolve the
  # activation closure; `manifest_blocks/2` above keeps the narrower shape
  # its other callers read.
  defp manifest_row(ctx, source_ref) do
    with {:ok, ref} <- Prima.ComponentRef.parse(source_ref),
         {:ok, row} <- Components.get_latest(ctx, ref.name, ref.namespace, ref.type),
         {:ok, manifest} <- manifest(row, source_ref) do
      {:ok, row, manifest}
    end
  end

  @doc """
  Expand tool patterns against the registered tool catalog. Grants are
  stored expanded: a pattern is not a stable capability, so an action
  added upstream later is correctly outside an existing consent.
  """
  @spec expand_tools([String.t()]) :: [String.t()]
  def expand_tools(patterns) when is_list(patterns) do
    ToolPattern.expand(patterns, all_tool_actions())
  end

  @doc false
  # The catalog's own roster, through the port consent reads it by, so a
  # shape derived here can only name actions the catalog can serve.
  def all_tool_actions, do: Sanctum.Grimoire.tool_actions()

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # A vault need whose projection names nothing would consent to an edge
  # the vault reader refuses as corrupt at dispense; it is refused here
  # instead, where the manifest's author can be told.
  defp check_vault_projections(needs, source_ref) do
    Enum.find_value(needs, :ok, fn need ->
      with {:ok, list} <- Map.fetch(@projection_lists, need.kind),
           [] <- Map.fetch!(need, list) do
        {:error,
         {:invalid_argument,
          "#{source_ref} declares the vault need \"#{need.name}\" without #{list}; " <>
            "a vault need names the #{list} it reads"}}
      else
        _named_or_component_typed -> nil
      end
    end)
  end

  # The digest's need rows: name/type/fields/scopes — the reason is prose
  # and required-ness surfaces on the sheet, neither is shape.
  defp digest_needs(needs) do
    Enum.map(needs, fn need ->
      %{
        name: need.name,
        type: "#{need.kind}:#{need.qualifier}",
        fields: need.fields,
        scopes: need.scopes
      }
    end)
  end

  defp digest_caps(caps) do
    %{}
    |> put_list("egress.domains", caps.egress.domains)
    |> put_list("egress.methods", caps.egress.methods)
    |> put_list("egress.schemes", caps.egress.schemes)
    |> put_list("egress.private_ips", caps.egress.private_ips)
    |> put_list("storage.paths", caps.storage.paths)
    |> put_list("storage.actions", caps.storage.actions)
    |> put_limits(caps.limits)
  end

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)

  defp put_limits(map, limits) do
    Enum.reduce(limits, map, fn
      {:rate_limit, %{requests: requests, window: window}}, acc ->
        acc
        |> Map.put("limits.rate_limit.requests", requests)
        |> Map.put("limits.rate_limit.window", window)

      {key, value}, acc ->
        Map.put(acc, "limits.#{key}", value)
    end)
  end

  # A manifest that does not decode is a damaged row, refused by the ref it
  # was read under and never by its bytes.
  defp manifest(row, ref) do
    case Prima.Manifest.decode_strict(Map.get(row, :manifest) || Map.get(row, "manifest")) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, :malformed_manifest} -> {:error, {:corrupt, {:manifest, ref}}}
    end
  end
end
