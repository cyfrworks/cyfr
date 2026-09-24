# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Keys do
  @moduledoc """
  The tenant-keyed `Arca.Cache` key shapes, in one place.

  Every key that carries an athanor (and the content-addressed compiled
  component) is built here — writers, readers, the invalidation in
  `Compendium.Registry`, and the caps in `Arca.Cache.Sweeper` (which
  pattern-matches the compiled-component key) all agree on the shape
  because none of them spell it themselves. (Keys that carry no athanor —
  a legal-bodies version, a device-login ticket, an OAuth pending state —
  stay spelled at their single owner.)

  Every athanor-keyed shape takes the `Prima.Actor` first and reads the
  tenant out of it, so a key is built from the caller the identity domain
  established and never from an argument beside the row key — the swap
  these shapes exist to prevent would otherwise read another tenant's
  cached rows. An actor with no resolved athanor raises: a key builder
  has no `{:error, _}` to answer with, and a refusal that came back as a
  term would become a cache key shared by every caller that hit it.
  """

  @doc """
  Compiled (NIF) component for a WASM digest. Compilation is a pure function
  of the bytes, so the key is content-addressed: fifty athanors running the
  same bundle share one compiled resource, and a re-registered reference
  simply has a new digest.
  """
  def compiled_component(digest), do: {:compiled_component, digest}

  @doc "Match spec shape for every compiled component (Sweeper cap)."
  def match_compiled_component, do: {:compiled_component, :_}

  @doc """
  Raw WASM bytes for a digest — the fetch cache one step before
  `compiled_component/1`, equally content-addressed and shared across
  athanors. What makes the sharing safe is the verification on both ends
  of a hit: admission compares the served digest against the
  REQUESTING tenant's own row (`Crucible.Admission`), and
  `Compendium.Registry.get_blob/2` re-hashes what it reads — a poisoned
  entry fails the requester's check, never runs under their consent.
  """
  def wasm_bytes(digest), do: {:wasm_bytes, digest}

  @doc """
  The resolved activation of a component's static closure within an
  athanor, keyed by the root's node key and release digest.
  """
  def activation(%Prima.Actor{athanor_id: athanor_id}, node_key, release_digest)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:activation, athanor_id, node_key, release_digest}

  def activation(%Prima.Actor{}, _node_key, _release_digest),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.activation/3")

  @doc "Match spec shape for every activation of one athanor."
  def match_activation(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:activation, athanor_id, :_, :_}

  def match_activation(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.match_activation/1")

  @doc "The live shape digest of a versionless source ref within an athanor."
  def live_shape(%Prima.Actor{athanor_id: athanor_id}, source_ref)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:live_shape, athanor_id, source_ref}

  def live_shape(%Prima.Actor{}, _source_ref),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.live_shape/2")

  @doc "Match spec shape for every live shape digest of one athanor."
  def match_live_shape(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:live_shape, athanor_id, :_}

  def match_live_shape(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.match_live_shape/1")

  @doc "Component metadata row for a reference within an athanor."
  def component_meta(%Prima.Actor{athanor_id: athanor_id}, reference)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:component_meta, athanor_id, reference}

  def component_meta(%Prima.Actor{}, _reference),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.component_meta/2")

  @doc "Match spec shape for every component metadata entry of one athanor."
  def match_component_meta(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:component_meta, athanor_id, :_}

  def match_component_meta(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.match_component_meta/1")

  @doc """
  SSE replay buffer for an execution within an athanor. The athanor is
  the actor's and the execution is the argument — the two were both
  strings in the same call, either way round.
  """
  def exec_events(%Prima.Actor{athanor_id: athanor_id}, execution_id)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:exec_events, execution_id, athanor_id}

  def exec_events(%Prima.Actor{}, _execution_id),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.exec_events/2")

  @doc "The external MCP tool map of an athanor."
  def external_tools(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:external_tools, athanor_id}

  def external_tools(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.external_tools/1")

  @doc "The byte total of an athanor's whole tree, for the storage cap."
  def athanor_usage(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:athanor_usage, athanor_id}

  def athanor_usage(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.athanor_usage/1")

  # Two keys, not one {bytes, files} tuple: `bump_existing/2` is an
  # `:ets.update_counter` on the row's single value slot, so each counter
  # needs its own row to stay O(1).

  @doc "The byte total under one tenant scope of an athanor (public quota)."
  def scope_usage_bytes(%Prima.Actor{athanor_id: athanor_id}, scope)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:scope_usage, athanor_id, scope, :bytes}

  def scope_usage_bytes(%Prima.Actor{}, _scope),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.scope_usage_bytes/2")

  @doc "The file count under one tenant scope of an athanor (public quota)."
  def scope_usage_files(%Prima.Actor{athanor_id: athanor_id}, scope)
      when is_binary(athanor_id) and athanor_id != "",
      do: {:scope_usage, athanor_id, scope, :files}

  def scope_usage_files(%Prima.Actor{}, _scope),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.scope_usage_files/2")

  @doc "Match spec shape for every scope-usage counter of one athanor."
  def match_scope_usage(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:scope_usage, athanor_id, :_, :_}

  def match_scope_usage(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.match_scope_usage/1")

  @doc """
  The per-athanor tincture-scan de-dup lock (the console's refresh
  button). Used as mutual exclusion, so the Sweeper's protected-head list
  names it: an evicted lock would admit a duplicate scan.
  """
  def tincture_scan_running(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "",
      do: {:tincture_scan_running, athanor_id}

  def tincture_scan_running(%Prima.Actor{}),
    do: Arca.QueryHelpers.no_athanor!("Arca.Cache.Keys.tincture_scan_running/1")

  @doc """
  An established caller memo — `Sanctum.Caller`'s short-TTL cache of one
  finished Context, keyed by the session row hash, the surface, and the
  focus coordinate.
  """
  def established(token_hash, surface, focus_coord),
    do: {:established, token_hash, surface, focus_coord}

  @doc "Match spec shape for every established memo of one session hash."
  def match_established(token_hash), do: {:established, token_hash, :_, :_}
end
