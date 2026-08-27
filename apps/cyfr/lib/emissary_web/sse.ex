# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.SSE do
  @moduledoc """
  The per-caller bounds every SSE surface shares: a concurrent-stream slot
  and a hard deadline.

  Each surface claims a slot under its OWN tag with its own configured
  budget — sharing a key would let one surface starve the other, which is
  the collision the exec-events tag was invented to prevent while the
  listen key stayed untagged. The slot is a `Emissary.MCP.SubscriptionRegistry`
  entry that dies with the conn process, so a vanished client frees itself.
  The window between count and register can briefly overshoot under a
  burst — acceptable slack for a bound whose job is stopping unbounded
  socket pinning.

  What happens ON the stream stays per-surface (JSON-RPC notifications vs
  execution events, and their renderers) — only the bounds are one thing.
  """

  # Intermediaries and client idle timeouts close a connection that says
  # nothing; a quiet stream is the normal state, not a broken one.
  @keep_alive_ms :timer.seconds(15)

  @default_max_concurrent 8
  @default_max_ms :timer.minutes(30)

  @doc "How long to wait before writing a keep-alive comment."
  @spec keep_alive_ms() :: pos_integer()
  def keep_alive_ms, do: @keep_alive_ms

  @doc """
  Claim a stream slot for the caller under `tag`, bounded by the
  `limit_key` app-config budget (default #{@default_max_concurrent}).
  """
  @spec claim_slot(atom(), Sanctum.Context.t(), atom()) :: :ok | {:error, :stream_limit}
  def claim_slot(tag, %Sanctum.Context{} = ctx, limit_key) when is_atom(tag) do
    key = {tag, ctx.athanor_id, ctx.user_id}
    limit = Application.get_env(:cyfr, limit_key, @default_max_concurrent)

    if length(Registry.lookup(Emissary.MCP.SubscriptionRegistry, key)) >= limit do
      {:error, :stream_limit}
    else
      {:ok, _} = Registry.register(Emissary.MCP.SubscriptionRegistry, key, :stream)
      :ok
    end
  end

  @doc """
  The monotonic deadline for a stream opened now, from the `max_ms_key`
  app-config window (default 30 minutes). A stream does not live forever:
  an unbounded one means a client that vanished uncleanly holds a process
  and a socket until the VM restarts; the client reconnects.
  """
  @spec deadline(atom()) :: integer()
  def deadline(max_ms_key) do
    System.monotonic_time(:millisecond) +
      Application.get_env(:cyfr, max_ms_key, @default_max_ms)
  end
end
