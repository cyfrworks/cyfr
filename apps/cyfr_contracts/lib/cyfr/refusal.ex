# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Refusal do
  @moduledoc """
  The one refusal vocabulary: what a call can be refused for, and the
  client-safe sentence each refusal reads as.

  Reasons stay data until a renderer. Three renderers read this module and
  no other holds a sentence of its own:

    * `Emissary.MCP.Router.format_error_reason/1` — the external wire
    * `PrismWeb.Ops.error_message/1` — the console
    * `Opus.FormulaHandler.render_reason/1` — the in-chain guest, through
      `Cyfr.GuestError`

  It lives in the contracts because the runner's renderer must reach it
  and the runner names nothing of the control plane. `Cyfr.Ops.Error` is
  the host's renderer over this vocabulary and the product ones beside it
  (an unauthorized caller, an OCI registry's own error, a consent signal);
  `Cyfr.GuestError` is the runner's, over this vocabulary and the shapes
  that arrive on the worker wire.

  Two vocabularies is what this replaces. They restated each other's
  sentences, and where they disagreed a guest in a chain saw an internal
  atom name — `:busy`, `:archived`, `:not_member` — where a person at the
  console saw a sentence.
  """

  @type t ::
          {:not_found, resource :: String.t(), id :: String.t()}
          | {:invalid_argument, message :: String.t()}
          | {:conflict, message :: String.t()}
          | {:unavailable, what :: String.t()}
          | {:corrupt, what :: String.t()}
          | {:crashed, message :: String.t()}
          | {:exit, message :: String.t()}
          | {:timeout, message :: String.t()}
          | :action_missing
          | {:unknown_action, name_action :: String.t()}
          | :control_plane_lost
          | :not_provisioned
          | :busy
          | :not_member
          | :archived
          | :no_agent
          | :execution_unavailable
          | :message_too_long
          | :client_id_reused
          | :message_id_reused
          | {:uncertain, message :: String.t()}
          | {:result_lost, message :: String.t()}
          | {:not_recorded, message :: String.t()}
          | :stale_writer
          | :stale_revision
          | :missing_unit
          | :invalid_objects
          | :unavailable
          | {:finish_failed, reason :: term()}

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
  # A unit commit's own refusals (`Arca.StorageUnits`), each a different
  # thing to do about it.
  def reason?(:stale_writer), do: true
  def reason?(:stale_revision), do: true
  def reason?(:missing_unit), do: true
  def reason?(:invalid_objects), do: true
  # The store could not say what it did. Distinct from `{:unavailable,
  # what}`, which names a service that answered nothing.
  def reason?(:unavailable), do: true
  def reason?({:finish_failed, _reason}), do: true
  def reason?(:action_missing), do: true
  def reason?({:unknown_action, name_action}) when is_binary(name_action), do: true
  def reason?(:control_plane_lost), do: true
  def reason?(:not_provisioned), do: true
  # A thread's own refusals: what a send or a decision is held to.
  def reason?(:busy), do: true
  def reason?(:not_member), do: true
  def reason?(:archived), do: true
  def reason?(:no_agent), do: true
  def reason?(:client_id_reused), do: true
  def reason?(:message_id_reused), do: true
  def reason?(:execution_unavailable), do: true
  def reason?(:message_too_long), do: true
  # An effect that may have happened with no result to show for it; one
  # that happened whose result could not be kept; one whose record of
  # ending could not be written.
  def reason?({:uncertain, message}) when is_binary(message), do: true
  def reason?({:result_lost, message}) when is_binary(message), do: true
  def reason?({:not_recorded, message}) when is_binary(message), do: true
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

  # What a unit commit refused, and what the caller does about it. A
  # writer that died holding a unit's draft blocks the unit until the
  # draft expires (`Arca.StorageUnits.draft_ttl_ms/0`, fifteen minutes),
  # so the sentence says how long rather than "retry shortly".
  def message(:stale_writer),
    do:
      "Another write to this unit holds it — retry once its draft expires (up to fifteen minutes)"

  def message(:stale_revision),
    do: "Another write to this unit landed first — read it again and retry"

  def message(:missing_unit), do: "This unit was removed while it was being written"

  def message(:invalid_objects),
    do: "What was staged for this unit is not what was written — nothing was published"

  # A call that could not be answered at all, with no service named.
  # More than one thing produces it — a unit commit whose store could not
  # say what it did, a host call CYFR refused — so the sentence names
  # none of them and takes the safe direction of the two: it asks the
  # caller to look rather than to retry, because retrying an effect that
  # may have happened is the dangerous mistake and looking at one that
  # did not is only a wasted read. `{:unavailable, what}` is the other
  # shape: a named service that was reached and gave nothing, where
  # retrying is the right advice.
  def message(:unavailable),
    do: "Unavailable — what was asked may or may not have been done; check before asking again"

  # The row is committed. The unit is published; only the move of its
  # objects to where readers read did not finish, and the repair the
  # storage sweep runs finishes it.
  def message({:finish_failed, _reason}),
    do: "This unit is published; serving its files did not finish and will be repaired"

  # Render registry dispatch refusals consistently across all surfaces.
  def message(:action_missing), do: "Missing required argument: action"
  def message({:unknown_action, name_action}), do: "Unknown action: #{name_action}"

  # A lost control-plane lease blocks admission until ownership is restored.
  def message(:control_plane_lost),
    do: "This server does not currently own its database's control plane — retry shortly"

  # The estate exists and is being filled. A turn waits for that; reads of
  # the tree answer meanwhile.
  def message(:not_provisioned),
    do: "This estate is still being prepared — retry shortly"

  # A thread's own refusals, one sentence each, the same on the
  # wire and on the page.
  def message(:busy), do: "The turn queue is full — send again after the current turn"
  def message(:not_member), do: "Only a member of the estate can act in its threads"
  def message(:archived), do: "This estate is archived — nothing runs in it"

  def message(:no_agent),
    do: "This estate has no assistant to address — reset its AQUA tree"

  def message(:execution_unavailable), do: "The execution engine is unavailable — retry shortly"
  def message(:message_too_long), do: "The message is longer than the 32 KiB bound"

  def message(:client_id_reused),
    do: "That client id already names a different send — offer the same send, or a new client id"

  def message(:message_id_reused), do: "That message id already names another message"
  def message({:uncertain, message}), do: message
  def message({:result_lost, message}), do: message
  def message({:not_recorded, message}), do: message
end
