# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.Error do
  @moduledoc """
  Typed tool-refusal vocabulary: reasons stay data until a renderer.

  The heavy-traffic providers produce this vocabulary now — `component`,
  `mcp_servers`, `vault`, the records provider, `build` (Locus), the
  execution tool's validation arms, and the tenancy and registry surfaces
  (`athanor`, `member`, `door`, `session`, `registry`, `aqua`) — with
  `{:invalid_argument, msg}` chosen where the wire sentence had to stay
  byte-identical, and `{:not_found, …}` / `{:unavailable, …}` where the
  typed sentence is the better one. Crafted operator sentences that fit no
  member (compiler output, remediation hints, an upstream provider's own
  error code, a partial-failure count) deliberately stay strings, as does
  the registry's "Unknown tool" spelling.
  What is left is NOT listed here. A migration in progress cannot be
  recorded in prose — this paragraph named `Opus.MCP` as the remaining
  surface long after two larger ones had appeared — so the worklist lives
  in `Cyfr.Ops.ErrorAdoptionTest`, where every module and its
  count are checked against the tree and may only go down. Read it for the
  real number and the order worth working in.

  `Sanctum.ComponentRef`'s parse prose stays as it is (pinned by
  exact-string tests; convert with its own renderer when a caller needs to
  branch). `Sanctum.Unauthorized` and `Compendium.OCI.Errors` prove the
  same shape end-to-end.

  Adoption stays incremental — a provider converts an action by returning
  one of these tuples instead of a sentence; unconverted strings keep
  flowing through the renderers' binary clauses unchanged. The three
  consumers of a provider's error all render it:

    * `Emissary.MCP.Router.format_error_reason/1` (the external wire)
    * `PrismWeb.Ops.error_message/1` (the console)
    * `Opus.FormulaHandler.stringify_reason/1` (the in-chain guest view)

  The §4.3 consent signals are their own vocabulary
  (`Emissary.MCP.ConsentSignal`): protocol-level errors with a -335xx code
  and the payload in `error.data`. `render/2` gives them their sentence for
  the console and the guest; the wire router promotes them past isError
  entirely.
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

  # `Cyfr.Ops.Catalog` mints these three when a tool crashes, exits
  # or overruns its deadline. Each already carries a crafted, client-safe
  # sentence (the tool's name and what happened, never the exception's own
  # message), so rendering is the identity — the point of naming them here is
  # that all three surfaces recognise them. Only the router did: the console
  # collapsed them into "The request failed — try again.", losing the
  # timeout-vs-crash distinction, and the guest saw Elixir term syntax.
  def message({:crashed, message}), do: message
  def message({:exit, message}), do: message
  def message({:timeout, message}), do: message

  # `Arca.Overlay.UnitLock` timed out waiting for another writer on the
  # same unit. It escapes every overlay `put`/`append`/`delete`/
  # `delete_tree` now that the lock sits on the callbacks, and it rendered
  # as `nil` — so a caller saw whatever generic "failed" sentence its
  # surface had, on exactly the paths (component publish, aqua edit) where
  # concurrent contention is the expected case. Contention is retryable
  # and an outage is not; the two must not read the same.
  def message(:unit_locked),
    do: "Another write to this component is in progress — retry shortly"

  # The registry's own dispatch refusals. They used to be rendered by the
  # wire router alone, so the console and the guest showed a generic
  # sentence where the wire named the missing/unknown action.
  def message(:action_missing), do: "Missing required argument: action"
  def message({:unknown_action, name_action}), do: "Unknown action: #{name_action}"

  # `Cyfr.ControlPlane.assert_owner/0`: this boot's lease on the database
  # lapsed, so it admits nothing until it wins the claim back. Retryable,
  # and worth saying so on every surface — the chat pane rendered it as a
  # generic failure.
  def message(:control_plane_lost),
    do: "This server does not currently own its database's control plane — retry shortly"

  @doc """
  The client-safe sentence for ANY refusal a tool can produce, or `nil` when
  the term is internal and must not be reflected.

  The rendering surfaces named above each used to carry their own `cond`
  over the same vocabularies, and they had drifted: the console knew
  nothing of the crash tuples, and the guest view `inspect`ed whatever it
  did not recognise. (Many more modules call this today — every consumer
  renders through those surfaces' rule.) This is that decision, once — so a surface only has to decide
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
      Emissary.MCP.ConsentSignal.signal?(reason) -> Emissary.MCP.ConsentSignal.message(reason)
      true -> nil
    end
  end
end
