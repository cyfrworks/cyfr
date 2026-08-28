# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolError do
  @moduledoc """
  Typed tool-refusal vocabulary: reasons stay data until a renderer.

  Providers largely return `{:error, "English sentence"}` today — ~280
  literals across 17 providers — and several translate a typed reason
  they RECEIVED (`:not_found` from a record module, `:builder_unreachable`
  from the build client) into prose on the way out, discarding the type
  one layer before the boundary. `Sanctum.Unauthorized` and
  `Compendium.OCI.Errors` already prove the better shape end-to-end:
  data until the wire, prose at one renderer.

  This module is that shape for ordinary tool refusals. Adoption is
  deliberately incremental — a provider converts an action by returning
  one of these tuples instead of a sentence; unconverted strings keep
  flowing through the renderers' binary clauses unchanged. The three
  consumers of a provider's error all render it:

    * `Emissary.MCP.Router.format_error_reason/1` (the external wire)
    * `PrismWeb.MCPHelpers.error_message/1` (the console)
    * `Opus.FormulaHandler.stringify_reason/1` (the in-chain guest view)

  Do NOT reshape the consent-tag wire form (`"tag: {json}"` strings from
  `Opus.MCP`) into this vocabulary: `Cyfr.CrossLanguageDriftTest` pins
  those literals against the Go CLI's parser.
  """

  @type t ::
          {:not_found, resource :: String.t(), id :: String.t()}
          | {:invalid_argument, message :: String.t()}
          | {:unavailable, what :: String.t()}

  @doc "Whether a term is this vocabulary — the renderers' dispatch test."
  @spec reason?(term()) :: boolean()
  def reason?({:not_found, resource, id}) when is_binary(resource) and is_binary(id), do: true
  def reason?({:invalid_argument, message}) when is_binary(message), do: true
  def reason?({:unavailable, what}) when is_binary(what), do: true
  def reason?(_), do: false

  @doc """
  The client-safe sentence for a reason — one spelling, whichever surface
  renders it. Every message here is client-safe by construction: the
  tuple carries only what the caller already named.
  """
  @spec message(t()) :: String.t()
  def message({:not_found, resource, id}), do: "#{resource} not found: #{id}"
  def message({:invalid_argument, message}), do: message
  def message({:unavailable, what}), do: "#{what} is unavailable — retry shortly"
end
