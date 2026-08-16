# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Subscriptions do
  @moduledoc """
  `subscriptions/listen` — the one long-lived stream this revision has.

  A client opts into specific change notifications; the server acknowledges the
  subset it can actually honour and then pushes those, and only those, until one
  side closes. It replaces both the standalone `GET` stream and
  `resources/subscribe`.

  ## Only what can be delivered is acknowledged

  The specification is explicit that the acknowledgment reflects the subset the
  server agreed to honour, and that a server **MUST NOT** send a type the client
  did not request. The inverse matters just as much: acknowledging a type this
  server cannot produce would leave a client waiting for an event that is never
  coming, which is worse than being told no — it looks like "nothing has
  changed" rather than "nobody is watching".

  So the map below is the honest inventory, and it has exactly one entry.
  `tools/list_changed` is real because the tool catalogue genuinely changes:
  registering, removing, enabling or disabling an external MCP server changes
  which `server:tool` names exist. Prompts are unimplemented, the resource list
  is a fixed set of providers, and no resource has a change feed — so those are
  requested-but-not-acknowledged rather than silently accepted.

  ## Tenancy

  Subscriptions ride tenant-scoped PubSub topics, so a listener receives events
  for its own athanor and no other. That is a property of
  `Sanctum.PubSub.topic/2` rather than of this module, which is why the context
  is required to open a stream at all.
  """

  alias Sanctum.Context
  alias Sanctum.PubSub, as: Topics

  @pubsub Emissary.PubSub

  # `_meta` key correlating every message on a stream with the request that
  # opened it. On stdio one channel carries every subscription, so a client
  # cannot demultiplex without it.
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  @doc "The `_meta` key carrying a notification's subscription id."
  @spec subscription_id_key() :: String.t()
  def subscription_id_key, do: @subscription_id_key

  @doc """
  Subscribe the calling process to the requested notification types.

  Returns the subset actually honoured, which is what the acknowledgment must
  carry. An unsupported type is dropped rather than refused: the client asked
  for several things and is entitled to the ones that exist.
  """
  @spec listen(Context.t(), map()) :: {:ok, map()}
  def listen(%Context{} = ctx, filter) when is_map(filter) do
    acknowledged =
      if truthy?(filter["toolsListChanged"]) do
        Phoenix.PubSub.subscribe(@pubsub, Topics.topic("mcp_servers", ctx))
        %{"toolsListChanged" => true}
      else
        %{}
      end

    {:ok, acknowledged}
  end

  def listen(%Context{} = ctx, _filter), do: listen(ctx, %{})

  @doc """
  Translate a PubSub message into an MCP notification, or ignore it.

  Anything this stream is not carrying is dropped here rather than at the
  subscribe site, so a topic that grows a second message type cannot start
  leaking it to subscribers who asked for something else.
  """
  @spec notification_for(term()) :: {:ok, String.t(), map()} | :ignore
  def notification_for(:mcp_servers_changed) do
    {:ok, "notifications/tools/list_changed", %{}}
  end

  def notification_for(_message), do: :ignore

  # A JSON `true` is the opt-in. Anything else — `false`, `null`, a string, a
  # missing key — is not, and is treated as not asking rather than as an error.
  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
