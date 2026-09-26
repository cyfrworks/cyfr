# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Subscriptions do
  @moduledoc """
  `subscriptions/listen` — the one long-lived stream this revision has.

  Clients request specific change notifications. The server acknowledges
  the supported subset and streams those events until either side closes.

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

  ## Admission

  Each acknowledged type is a declared stream (`mcp_servers.changes`, the
  servers provider's), opened through the gate's one stream entry
  (`Grimoire.open_stream/3`) before anything is subscribed: one decision
  per open, and a refusal refuses the listen. The listener subscribes to
  the topic its grant names and nothing else (`Cyfr.Bus.granted_topic/2`),
  and keeps enforcing the grant: the stream ends at the earliest grant's
  deadline (`remaining_ms/2`), on a standing change (the transport's
  watch), and on overflow (`backlog/1`), a typed refusal rather than lost
  notifications. A reconnect is a new listen and so a new admission.

  ## Tenancy

  A grant is scoped to the caller's athanor: the topic is the athanor's
  own bus topic (`Cyfr.Bus.mcp_servers/1`), and an open without an
  athanor is refused.
  """

  alias Sanctum.Context

  # `_meta` key correlating every message on a stream with the request that
  # opened it. On stdio one channel carries every subscription, so a client
  # cannot demultiplex without it.
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  # Each notification type this listener can honour, and the declared
  # stream that carries it.
  @streams [{"toolsListChanged", "mcp_servers.changes"}]

  # The listener's mailbox depth past which it has fallen too far behind
  # its stream to deliver it faithfully; the stream ends with a refusal
  # instead of dropping what it could not keep up with.
  @max_backlog 1_000

  @doc "The `_meta` key carrying a notification's subscription id."
  @spec subscription_id_key() :: String.t()
  def subscription_id_key, do: @subscription_id_key

  @doc """
  Admit and subscribe the calling process to the requested notification
  types.

  Answers the subset actually honoured, which is what the acknowledgment
  must carry, and the grants it was admitted under. An unsupported type is
  dropped rather than refused: the client asked for several things and is
  entitled to the ones that exist. A supported type the gate refuses
  refuses the listen with the gate's refusal, and nothing stays
  subscribed.
  """
  @spec listen(Context.t(), term()) ::
          {:ok, map(), [Prima.StreamGrant.t()]} | {:error, Prima.Refusal.t()}
  def listen(%Context{} = ctx, filter) when is_map(filter) do
    requested = for {type, stream} <- @streams, truthy?(filter[type]), do: {type, stream}

    Enum.reduce_while(requested, {:ok, %{}, []}, fn {type, stream}, {:ok, acknowledged, grants} ->
      case Grimoire.open_stream(ctx, stream) do
        {:ok, grant} ->
          actor = Context.actor(ctx)
          # The granted topic lies under the caller's own prefix by
          # construction, so the bus's tenant check cannot refuse it.
          :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.granted_topic(actor, grant))
          {:cont, {:ok, Map.put(acknowledged, type, true), [grant | grants]}}

        {:error, %Prima.Refusal{} = refusal} ->
          close(ctx, grants)
          {:halt, {:error, refusal}}
      end
    end)
  end

  def listen(%Context{} = ctx, _filter), do: listen(ctx, %{})

  @doc """
  Unsubscribe the calling process from every grant's topic: a stream's
  end, whatever ended it.
  """
  @spec close(Context.t(), [Prima.StreamGrant.t()]) :: :ok
  def close(%Context{} = ctx, grants) when is_list(grants) do
    actor = Context.actor(ctx)

    Enum.each(grants, fn grant ->
      Cyfr.Bus.unsubscribe(actor, Cyfr.Bus.granted_topic(actor, grant))
    end)
  end

  @doc """
  Milliseconds until the earliest of `grants` ends at `now`, `0` once one
  has, or `:infinity` for no grants.
  """
  @spec remaining_ms([Prima.StreamGrant.t()], DateTime.t()) :: non_neg_integer() | :infinity
  def remaining_ms(grants, now \\ DateTime.utc_now())

  def remaining_ms([], %DateTime{}), do: :infinity

  def remaining_ms(grants, %DateTime{} = now) when is_list(grants) do
    grants
    |> Enum.map(&DateTime.diff(&1.deadline, now, :millisecond))
    |> Enum.min()
    |> max(0)
  end

  @doc """
  Whether the listener `pid` still keeps up with its stream: `:ok`, or
  the typed overflow refusal once its mailbox holds more than the bound.
  """
  @spec backlog(pid()) :: :ok | {:error, Prima.Refusal.t()}
  def backlog(pid \\ self()) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, depth} when depth > @max_backlog -> {:error, overflow()}
      _ -> :ok
    end
  end

  @doc "The refusal a stream that fell too far behind ends with."
  @spec overflow() :: Prima.Refusal.t()
  def overflow do
    %Prima.Refusal{
      class: :rate_limited,
      reason: :stream_overflow,
      message: "The subscription fell too far behind and was closed — listen again"
    }
  end

  @doc """
  Translate a bus message into an MCP notification, or ignore it.

  Anything this stream is not carrying is dropped here rather than at the
  subscribe site, so a topic that grows a second message type cannot start
  leaking it to subscribers who asked for something else.
  """
  @spec notification_for(term()) :: {:ok, String.t(), map()} | :ignore
  def notification_for(%Cyfr.Bus.McpServers{kind: :changed}) do
    {:ok, "notifications/tools/list_changed", %{}}
  end

  def notification_for(_message), do: :ignore

  # A JSON `true` is the opt-in. Anything else — `false`, `null`, a string, a
  # missing key — is not, and is treated as not asking rather than as an error.
  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
