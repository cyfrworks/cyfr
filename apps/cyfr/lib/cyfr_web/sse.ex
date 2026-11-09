# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSE do
  @moduledoc """
  The endpoint's SSE streams: the per-caller bounds every SSE surface
  shares, a concurrent-stream slot and a hard deadline, and the headers
  and keep-alive each one opens and holds a stream with.

  Each surface uses its own subscription tag and its own platform
  settings (`mcp_subscription_*` for `subscriptions/listen`,
  `opus_events_*` for execution events), read through
  `Arca.PlatformSettings.effective/1` when a stream opens: a change
  reaches the streams opened after it. Slots are counted per member, in
  this member's registry, so a caller's budget is per member of the cell.
  A slot is released when the stream releases it (`release_slot/2`) or
  when the connection process exits. A claim counts the key's slots and
  registers its own under one lock on the key (`claim_slot/3`), so
  concurrent opens never take more slots than the cap.

  A tincture frame reads its streams over its own stream connection
  (`Emissary.Web.FrameSocket`), not here.
  """

  alias Sanctum.Context

  # Intermediaries and client idle timeouts close a connection that says
  # nothing; a quiet stream is the normal state, not a broken one.
  @keep_alive_ms :timer.seconds(15)

  # The settings a surface may name: each surface's concurrent-stream cap
  # and stream lifetime.
  @limits ~w(mcp_subscription_max_concurrent opus_events_max_concurrent)a
  @lifetimes ~w(mcp_subscription_max_ms opus_events_max_ms)a

  @doc "How long to wait before writing a keep-alive comment."
  @spec keep_alive_ms() :: pos_integer()
  def keep_alive_ms, do: @keep_alive_ms

  @doc """
  Open a chunked `text/event-stream` response with the headers every SSE
  surface needs.

  Sets SSE headers, including x-accel-buffering: no for reverse proxies.
  Omits hop-by-hop connection headers for HTTP/2 compatibility.

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
  `limit_key` platform setting (8 streams by default).

  The key carries the credential, not only the person: API-key callers
  share a nil `user_id`, and each key has its own budget, so one chatty
  integration never starves the others of its athanor.

  A claim is one reservation: the slots held under the key are counted
  and the new one registered under one lock on the key, so two claims
  never both take the last slot.
  """
  @spec claim_slot(atom(), Context.t(), atom()) :: :ok | {:error, :stream_limit}
  def claim_slot(tag, %Context{} = ctx, limit_key) when is_atom(tag) and limit_key in @limits do
    key = slot_key(tag, ctx)
    limit = setting(limit_key)
    :global.trans({{__MODULE__, key}, self()}, fn -> reserve(key, limit) end, [node()])
  end

  defp reserve(key, limit) do
    if CyfrWeb.SSE.Registry.count(key) >= limit do
      {:error, :stream_limit}
    else
      {:ok, _} = CyfrWeb.SSE.Registry.register(key, :stream)
      :ok
    end
  end

  @doc """
  Release the calling process's slots under `tag` for the caller: a stream
  that ended while its connection lives on (a kept-alive connection serves
  the next request in the same process) frees its count at once.
  """
  @spec release_slot(atom(), Context.t()) :: :ok
  def release_slot(tag, %Context{} = ctx) when is_atom(tag),
    do: CyfrWeb.SSE.Registry.unregister(slot_key(tag, ctx))

  defp slot_key(tag, %Context{} = ctx),
    do: {tag, ctx.athanor_id, ctx.user_id, ctx.api_key_id || ctx.session_token_hash}

  @doc """
  The monotonic deadline for a stream opened now, from the `max_ms_key`
  platform setting (30 minutes by default). A stream does not live
  forever: an unbounded one means a client that vanished uncleanly holds
  a process and a socket until the VM restarts; the client reconnects.
  """
  @spec deadline(atom()) :: integer()
  def deadline(max_ms_key) when max_ms_key in @lifetimes do
    System.monotonic_time(:millisecond) + setting(max_ms_key)
  end

  # Every limit and lifetime is an integer setting. Each serves a stale
  # value, so a store outage answers the last one read and refuses no
  # stream for it.
  defp setting(key) do
    case Arca.PlatformSettings.effective(Atom.to_string(key)) do
      {:ok, value} when is_integer(value) -> value
    end
  end
end
