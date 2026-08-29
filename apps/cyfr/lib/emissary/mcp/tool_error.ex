# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolError do
  @moduledoc """
  Typed tool-refusal vocabulary: reasons stay data until a renderer.

  The heavy-traffic providers produce this vocabulary now — `component`,
  `mcp_servers`, `vault`, the records provider, `build` (Locus) and the
  execution tool's validation arms — with `{:invalid_argument, msg}`
  chosen where the wire sentence had to stay byte-identical, and
  `{:not_found, …}` / `{:unavailable, …}` where the typed sentence is the
  better one. Crafted operator sentences that fit no member (compiler
  output, remediation hints) deliberately stay strings, as do the
  registry's "Unknown tool" spelling and the consent-tag wire forms.
  Remaining string-heavy surfaces: `athanor`/`member`/`door`/`session`
  tools, `registry_tool`, `aqua_tool`, and `Sanctum.ComponentRef`'s parse
  prose (pinned by exact-string tests; convert with its own renderer when
  a caller needs to branch). `Sanctum.Unauthorized` and
  `Compendium.OCI.Errors` prove the same shape end-to-end.

  Adoption stays incremental — a provider converts an action by returning
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
          | {:crashed, message :: String.t()}
          | {:exit, message :: String.t()}
          | {:timeout, message :: String.t()}

  @doc "Whether a term is this vocabulary — the renderers' dispatch test."
  @spec reason?(term()) :: boolean()
  def reason?({:not_found, resource, id}) when is_binary(resource) and is_binary(id), do: true
  def reason?({:invalid_argument, message}) when is_binary(message), do: true
  def reason?({:unavailable, what}) when is_binary(what), do: true
  def reason?({:crashed, message}) when is_binary(message), do: true
  def reason?({:exit, message}) when is_binary(message), do: true
  def reason?({:timeout, message}) when is_binary(message), do: true
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

  # `Emissary.MCP.ToolRegistry` mints these three when a tool crashes, exits
  # or overruns its deadline. Each already carries a crafted, client-safe
  # sentence (the tool's name and what happened, never the exception's own
  # message), so rendering is the identity — the point of naming them here is
  # that all three surfaces recognise them. Only the router did: the console
  # collapsed them into "The request failed — try again.", losing the
  # timeout-vs-crash distinction, and the guest saw Elixir term syntax.
  def message({:crashed, message}), do: message
  def message({:exit, message}), do: message
  def message({:timeout, message}), do: message

  @doc """
  The client-safe sentence for ANY refusal a tool can produce, or `nil` when
  the term is internal and must not be reflected.

  The three consumers named above each used to carry their own `cond` over
  the same vocabularies, and they had drifted: the console knew nothing of
  the crash tuples, and the guest view `inspect`ed whatever it did not
  recognise. This is that decision, once — so a surface only has to decide
  what to say when the answer is `nil` (log it, and offer its own generic
  sentence), not what each vocabulary means.

  Keeping it here also keeps `apps/opus` off the vocabularies' own modules:
  `Opus.HostSurfaceTest` pins what opus may reach into, and a renderer is
  not a reason to widen that.
  """
  @spec render(term(), atom() | nil) :: String.t() | nil
  def render(reason, auth_method \\ nil)

  def render(reason, _auth_method) when is_binary(reason), do: reason

  def render(reason, auth_method) do
    cond do
      # The method rides along so the API-key remediation hint renders on
      # every surface, not only the wire router's own refusal path.
      Sanctum.Unauthorized.reason?(reason) -> Sanctum.Unauthorized.message(reason, auth_method)
      reason?(reason) -> message(reason)
      match?(%Compendium.OCI.Errors{}, reason) -> Compendium.MCP.Shared.to_error_string(reason)
      true -> nil
    end
  end
end
