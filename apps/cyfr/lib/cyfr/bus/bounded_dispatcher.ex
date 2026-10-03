# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Bus.BoundedDispatcher do
  @moduledoc """
  The dispatcher `Cyfr.Bus` hands `Phoenix.PubSub` for progress: each
  subscriber on this node receives the message only while its mailbox
  holds fewer than 100 messages. Past that it is dropped and counted as
  `[:cyfr, :mcp, :progress, :dropped]`.

  An MCP connection writes each notification with a blocking chunk, so
  against a stalled socket a chatty tool would otherwise grow its mailbox
  for the life of the request. Progress is idempotent display state:
  dropping under pressure is the honest policy, counted, never queued
  without bound.
  """

  @max_pending_messages 100

  @doc "The mailbox depth at which progress is dropped instead of queued."
  @spec max_pending_messages() :: pos_integer()
  def max_pending_messages, do: @max_pending_messages

  @doc false
  # Called by `Phoenix.PubSub` on each node with that node's subscribers.
  @spec dispatch([{pid(), term()}], pid() | :none, term()) :: :ok
  def dispatch(entries, from, message) do
    for {pid, _value} <- entries, pid != from do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} when len < @max_pending_messages ->
          send(pid, message)

        {:message_queue_len, _backed_up} ->
          :telemetry.execute([:cyfr, :mcp, :progress, :dropped], %{count: 1}, %{
            request_id: Map.get(message, :request_id),
            athanor_id: Map.get(message, :athanor_id)
          })

        # The subscriber died between the registry's answer and here.
        nil ->
          :ok
      end
    end

    :ok
  end
end
