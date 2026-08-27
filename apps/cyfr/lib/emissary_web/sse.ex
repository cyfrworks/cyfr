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
  Open a chunked `text/event-stream` response with the headers every SSE
  surface needs.

  Both surfaces set these by hand and disagreed: one added `connection:
  keep-alive`, which is a hop-by-hop header HTTP/2 forbids a server to send
  and which the connection handling does not read anyway. `x-accel-buffering`
  is the one that matters — a reverse proxy buffers by default, which turns a
  stream into a single delivery at the end, the exact thing a client opening
  one asked to avoid.

  The framing that follows stays per-surface, deliberately: JSON-RPC
  notifications have nothing to resume to, while execution events carry a
  sequence and answer `Last-Event-ID`.
  """
  @spec open(Plug.Conn.t()) :: Plug.Conn.t()
  def open(%Plug.Conn{state: :chunked} = conn), do: conn

  def open(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
    |> Plug.Conn.send_chunked(200)
  end

  @doc """
  The keep-alive comment. An SSE comment is any line beginning with `:` —
  it exists to keep intermediaries and idle timeouts from closing a stream
  that is legitimately quiet, and doubles as the disconnect probe, since a
  quiet subscription and a dead client look identical until something is
  written.
  """
  @spec keep_alive_comment() :: String.t()
  def keep_alive_comment, do: ": keep-alive\n\n"

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
