# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Cache.Keys do
  @moduledoc """
  The tenant-keyed `Arca.Cache` key shapes, in one place.

  Every key that carries an athanor is built here — writers, readers, the
  invalidation in `Compendium.Registry`, and the caps in `Arca.Cache.Sweeper`
  (which pattern-matches the compiled-component key) all agree on the shape
  because none of them spell it themselves.
  """

  @doc "Compiled (NIF) component for a reference within an athanor."
  def compiled_component(athanor_id, reference), do: {:compiled_component, athanor_id, reference}

  @doc "Match spec shape for every compiled component (Sweeper cap)."
  def match_compiled_component, do: {:compiled_component, :_, :_}

  @doc "Match spec shape for every compiled component of one athanor."
  def match_compiled_component(athanor_id), do: {:compiled_component, athanor_id, :_}

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
end
