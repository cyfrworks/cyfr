# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Keys do
  @moduledoc """
  The tenant-keyed `Arca.Cache` key shapes, in one place.

  Every key that carries an athanor (and the content-addressed compiled
  component) is built here — writers, readers, the invalidation in
  `Compendium.Registry`, and the caps in `Arca.Cache.Sweeper` (which
  pattern-matches the compiled-component key) all agree on the shape
  because none of them spell it themselves.
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
  athanors.
  """
  def wasm_bytes(digest), do: {:wasm_bytes, digest}

  @doc """
  The resolved activation of a component's static closure within an
  athanor, keyed by the root's node key and release digest.
  """
  def activation(athanor_id, node_key, release_digest),
    do: {:activation, athanor_id, node_key, release_digest}

  @doc "Match spec shape for every activation of one athanor."
  def match_activation(athanor_id), do: {:activation, athanor_id, :_, :_}

  @doc "The live shape digest of a versionless source ref within an athanor."
  def live_shape(athanor_id, source_ref), do: {:live_shape, athanor_id, source_ref}

  @doc "Match spec shape for every live shape digest of one athanor."
  def match_live_shape(athanor_id), do: {:live_shape, athanor_id, :_}

  @doc "Component metadata row for a reference within an athanor."
  def component_meta(athanor_id, reference), do: {:component_meta, athanor_id, reference}

  @doc "Match spec shape for every component metadata entry of one athanor."
  def match_component_meta(athanor_id), do: {:component_meta, athanor_id, :_}

  @doc "SSE replay buffer for an execution within an athanor."
  def exec_events(execution_id, athanor_id), do: {:exec_events, execution_id, athanor_id}

  @doc "The external MCP tool map of an athanor."
  def external_tools(athanor_id), do: {:external_tools, athanor_id}

  @doc "The tool-server digest of one external server within an athanor."
  def tool_server_digest(athanor_id, server_name),
    do: {:tool_server_digest, athanor_id, server_name}

  @doc "Match spec shape for every tool-server digest of one athanor."
  def match_tool_server_digest(athanor_id), do: {:tool_server_digest, athanor_id, :_}

  @doc "The byte total of an athanor's whole tree, for the storage cap."
  def athanor_usage(athanor_id), do: {:athanor_usage, athanor_id}

  # Two keys, not one {bytes, files} tuple: `bump_existing/2` is an
  # `:ets.update_counter` on the row's single value slot, so each counter
  # needs its own row to stay O(1).

  @doc "The byte total under one tenant scope of an athanor (public quota)."
  def scope_usage_bytes(athanor_id, scope), do: {:scope_usage, athanor_id, scope, :bytes}

  @doc "The file count under one tenant scope of an athanor (public quota)."
  def scope_usage_files(athanor_id, scope), do: {:scope_usage, athanor_id, scope, :files}
end
