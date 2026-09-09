# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Error do
  @moduledoc """
  Typed tool-refusal vocabulary: reasons stay data until a renderer.

  Providers return typed errors for invalid arguments, missing resources
  and unavailable services. Compiler output, upstream error codes and
  other specific diagnostics may remain client-safe strings.

  Renderers accept typed refusals and client-safe strings. The three
  consumers of a provider's error are:

    * `Emissary.MCP.Router.format_error_reason/1` (the external wire)
    * `PrismWeb.Ops.error_message/1` (the console)
    * `Opus.FormulaHandler.render_reason/1` (the in-chain guest view)

  Consent signals use `Emissary.MCP.ConsentSignal`: protocol errors with a
  -335xx code and structured `error.data`. `render/2` provides their console
  and guest text; the wire router emits them as JSON-RPC errors.
  """

  @type t ::
          {:not_found, resource :: String.t(), id :: String.t()}
          | {:invalid_argument, message :: String.t()}
          | {:unavailable, what :: String.t()}
          | {:corrupt, what :: String.t()}
          | {:crashed, message :: String.t()}
          | {:exit, message :: String.t()}
          | {:timeout, message :: String.t()}
          | :action_missing
          | {:unknown_action, name_action :: String.t()}
          | :control_plane_lost
          | :not_provisioned

  @doc "Whether a term is this vocabulary — the renderers' dispatch test."
  @spec reason?(term()) :: boolean()
  def reason?({:not_found, resource, id}) when is_binary(resource) and is_binary(id), do: true
  def reason?({:invalid_argument, message}) when is_binary(message), do: true
  def reason?({:conflict, message}) when is_binary(message), do: true
  def reason?({:unavailable, what}) when is_binary(what), do: true
  def reason?({:corrupt, what}) when is_binary(what), do: true
  def reason?({:crashed, message}) when is_binary(message), do: true
  def reason?({:exit, message}) when is_binary(message), do: true
  def reason?({:timeout, message}) when is_binary(message), do: true
  def reason?(:unit_locked), do: true
  def reason?(:action_missing), do: true
  def reason?({:unknown_action, name_action}) when is_binary(name_action), do: true
  def reason?(:control_plane_lost), do: true
  def reason?(:not_provisioned), do: true
  def reason?(_), do: false

  @doc """
  The client-safe sentence for a reason — one spelling, whichever surface
  renders it. Every message here is client-safe by construction: the
  tuple carries only what the caller already named.
  """
  @spec message(t()) :: String.t()
  def message({:not_found, resource, id}), do: "#{resource} not found: #{id}"
  def message({:invalid_argument, message}), do: message
  # The write met a newer version than the one the caller edited.
  def message({:conflict, message}), do: message
  def message({:unavailable, what}), do: "#{what} is unavailable — retry shortly"
  # Stored bytes that no longer match the digest their row recorded: an
  # integrity refusal, not an outage — a retry will not help, and the
  # bytes are not served under the digest a caller would trust.
  def message({:corrupt, what}),
    do: "#{what} does not match its recorded digest and was not served"

  # Catalog failures carry client-safe messages without raw exception details.
  def message({:crashed, message}), do: message
  def message({:exit, message}), do: message
  def message({:timeout, message}), do: message

  # An overlay unit-lock timeout is retryable write contention.
  def message(:unit_locked),
    do: "Another write to this component is in progress — retry shortly"

  # Render registry dispatch refusals consistently across all surfaces.
  def message(:action_missing), do: "Missing required argument: action"
  def message({:unknown_action, name_action}), do: "Unknown action: #{name_action}"

  # A lost control-plane lease blocks admission until ownership is restored.
  def message(:control_plane_lost),
    do: "This server does not currently own its database's control plane — retry shortly"

  # The estate exists and is being filled; the read is not refused, only early.
  def message(:not_provisioned),
    do: "This estate is still being prepared — retry shortly"

  @doc """
  The client-safe sentence for ANY refusal a tool can produce, or `nil` when
  the term is internal and must not be reflected.

  Returns a client-safe sentence for recognized errors, or `nil` for an
  unknown term. Callers log unknown terms and provide a generic fallback.

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
      Emissary.MCP.ConsentSignal.signal?(reason) -> Emissary.MCP.ConsentSignal.message(reason)
      true -> nil
    end
  end
end
