# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSE do
  @moduledoc """
  The endpoint's streams: the per-caller bounds every SSE surface shares
  (a concurrent-stream slot and a hard deadline), and the delivery owner
  of a stream the gate admitted (`deliver/4`).

  Each surface uses its own subscription tag and its own platform
  settings (`mcp_subscription_*` for `subscriptions/listen`,
  `crucible_events_*` for execution events, `frame_stream_max_concurrent`
  for a tincture frame's streams), read through
  `Arca.PlatformSettings.effective/1` when a stream opens: a change
  reaches the streams opened after it. Slots are counted per member, in
  this member's registry, so a caller's budget is per member of the cell.
  A slot is released when the stream releases it (`release_slot/2`) or
  when the connection process exits. Count and register are separate
  steps, so bursts can briefly exceed the cap.

  ## Delivery under a grant

  A stream the gate admitted (`Grimoire.open_stream/3`) is delivered here
  and nowhere else on the endpoint. `deliver/4` subscribes the connection
  to the one topic the grant admits (`Cyfr.Bus.granted_topic/2`), writes
  each payload projected to the grant's fields (`Prima.StreamGrant.project/2`)
  as one event of `Prima.TinctureWire`'s stream, and keeps enforcing the
  grant until it closes the stream:

    * at the grant's deadline;
    * when the caller's context no longer stands: it is established again
      (the `:revalidate` function) on every standing announcement about
      the caller, before an event is delivered once it is past the
      session-freshness bound (`Sanctum.Caller.fresh?/1`), and on a timer
      that fires within that bound, so a suspended or revoked frame's
      stream is closed within the bound, and a refusal ends the stream
      with that refusal as its last event;
    * on overflow: a connection whose mailbox holds more than the backlog
      bound has fallen too far behind to deliver faithfully, and the
      stream ends with a typed refusal event (`overflow/0`), never by
      dropping what it could not keep up with;
    * when the client goes away, which the next write finds.

  A reconnect is a new open under the gate.
  """

  alias Cyfr.Bus.{AthanorArchived, CallerInvalidated, Membership, Session}
  alias Prima.{StreamGrant, TinctureWire}
  alias Sanctum.Context

  # Intermediaries and client idle timeouts close a connection that says
  # nothing; a quiet stream is the normal state, not a broken one.
  @keep_alive_ms :timer.seconds(15)

  # The settings a surface may name: each surface's concurrent-stream cap
  # and stream lifetime.
  @limits ~w(mcp_subscription_max_concurrent crucible_events_max_concurrent frame_stream_max_concurrent)a
  @lifetimes ~w(mcp_subscription_max_ms crucible_events_max_ms)a

  # How often a delivering stream looks at its context's age. A context is
  # re-established once it is past the session-freshness bound, so a
  # standing change reaches the stream within the bound and this tick.
  @revalidate_every_ms 1_000

  # The mailbox depth past which a delivering stream has fallen too far
  # behind its topic to deliver it faithfully.
  @max_backlog 1_000

  @typedoc """
  Establish the stream's caller again: the context to keep delivering
  under, or the refusal the stream ends with.
  """
  @type revalidate :: (-> {:ok, Context.t()} | {:error, Prima.Refusal.t()})

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
  share a nil `user_id`, so without it every integration in an athanor
  drew on one budget and a single chatty one starved the rest. A frame's
  context is counted per frame credential: one frame's streams never
  draw on another's budget.
  """
  @spec claim_slot(atom(), Context.t(), atom()) :: :ok | {:error, :stream_limit}
  def claim_slot(tag, %Context{} = ctx, limit_key) when is_atom(tag) and limit_key in @limits do
    key = slot_key(tag, ctx)
    limit = setting(limit_key)

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

  defp slot_key(tag, %Context{frame: %{id: id}} = ctx), do: {tag, ctx.athanor_id, :frame, id}

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

  # Both limits serve a stale value, so a store outage answers the last
  # one read and refuses no stream for it.
  defp setting(key) do
    {:ok, value} = Arca.PlatformSettings.effective(Atom.to_string(key))
    value
  end

  # ---------------------------------------------------------------------------
  # Delivery under a grant
  # ---------------------------------------------------------------------------

  @doc "The refusal a stream that fell too far behind ends with."
  @spec overflow() :: Prima.Refusal.t()
  def overflow do
    %Prima.Refusal{
      class: :rate_limited,
      reason: :stream_overflow,
      message: "The stream fell too far behind and was closed — open it again"
    }
  end

  @doc """
  Deliver the stream `grant` admits to the client of `conn`, under `ctx`,
  until one of the close conditions above ends it; answers the conn.

  Options:

    * `:name` — the stream's name, each event's `event` (required);
    * `:revalidate` — establishes the caller again (`t:revalidate/0`,
      required);
    * `:revalidate_every` — milliseconds between looks at the context's
      age (default #{@revalidate_every_ms});
    * `:max_backlog` — the mailbox depth that is overflow (default
      #{@max_backlog}).
  """
  @spec deliver(Plug.Conn.t(), Context.t(), StreamGrant.t(), keyword()) :: Plug.Conn.t()
  def deliver(%Plug.Conn{} = conn, %Context{} = ctx, %StreamGrant{} = grant, opts) do
    name = Keyword.fetch!(opts, :name)
    revalidate = Keyword.fetch!(opts, :revalidate)
    every = Keyword.get(opts, :revalidate_every, @revalidate_every_ms)
    actor = Context.actor(ctx)
    topic = Cyfr.Bus.granted_topic(actor, grant)
    # The granted topic lies under the caller's own prefix by construction,
    # so the bus's tenant check cannot refuse it.
    :ok = Cyfr.Bus.subscribe(actor, topic)
    :ok = Cyfr.Bus.subscribe_standing(ctx.user_id)

    ref = make_ref()
    remaining = max(DateTime.diff(grant.deadline, DateTime.utc_now(), :millisecond), 0)
    deadline = Process.send_after(self(), {__MODULE__, :deadline, ref}, remaining)

    state = %{
      ctx: ctx,
      grant: grant,
      name: name,
      payload: payload_struct(grant),
      revalidate: revalidate,
      every: every,
      max_backlog: Keyword.get(opts, :max_backlog, @max_backlog),
      ref: ref
    }

    arm(state)

    conn = open(conn)

    try do
      case Plug.Conn.chunk(conn, ": open\n\n") do
        {:ok, conn} -> loop(conn, state)
        {:error, _closed} -> conn
      end
    after
      # Every exit path: the timers, the subscriptions and any timer
      # message already queued go with the stream, so a kept-alive
      # connection's next request finds none of them.
      Process.cancel_timer(deadline)
      cancel_ticks(ref)
      Cyfr.Bus.unsubscribe(actor, topic)
      Cyfr.Bus.unsubscribe_standing(ctx.user_id)
      flush(ref)
    end
  end

  # The one struct the grant's topic carries (the bus roster's); anything
  # else in the mailbox is not the stream's to deliver.
  defp payload_struct(%StreamGrant{topic: key}) do
    Enum.find_value(Cyfr.Bus.topics(), fn row -> row.key == key && row.struct end)
  end

  defp loop(conn, %{ref: ref, payload: payload} = state) do
    receive do
      {__MODULE__, :deadline, ^ref} ->
        conn

      {__MODULE__, :tick, ^ref} ->
        arm(state)

        case fresh(state) do
          {:ok, state} -> loop(conn, state)
          {:error, refusal} -> close(conn, refusal)
        end

      %{__struct__: ^payload} = message ->
        delivery(conn, state, message)

      message
      when is_struct(message, Session) or is_struct(message, CallerInvalidated) or
             is_struct(message, AthanorArchived) or is_struct(message, Membership) ->
        if about?(message, state.ctx) do
          case state.revalidate.() do
            {:ok, ctx} -> loop(conn, %{state | ctx: ctx})
            {:error, refusal} -> close(conn, refusal)
          end
        else
          loop(conn, state)
        end
    after
      @keep_alive_ms ->
        case Plug.Conn.chunk(conn, keep_alive_comment()) do
          {:ok, conn} -> loop(conn, state)
          {:error, _closed} -> conn
        end
    end
  end

  # A payload is delivered only under a context that still stands and to
  # a client that keeps up.
  defp delivery(conn, state, message) do
    with :ok <- backlog(state.max_backlog),
         {:ok, state} <- fresh(state) do
      data = StreamGrant.project(state.grant, Map.from_struct(message))

      case Plug.Conn.chunk(conn, TinctureWire.stream_event(sequence(message), state.name, data)) do
        {:ok, conn} -> loop(conn, state)
        {:error, _closed} -> conn
      end
    else
      {:error, refusal} -> close(conn, refusal)
    end
  end

  defp fresh(%{ctx: ctx} = state) do
    if Sanctum.Caller.fresh?(ctx) do
      {:ok, state}
    else
      with {:ok, ctx} <- state.revalidate.(), do: {:ok, %{state | ctx: ctx}}
    end
  end

  defp backlog(max) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, depth} when depth > max -> {:error, overflow()}
      _ -> :ok
    end
  end

  # The last event of a stream closed for a reason the client should know.
  defp close(conn, %Prima.Refusal{} = refusal) do
    case Plug.Conn.chunk(conn, TinctureWire.stream_refusal(refusal)) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  # Which standing announcements are about this caller: each holder
  # filters for its own, and anything else is ignored.
  defp about?(%Session{kind: kind, user_id: user_id}, ctx),
    do: kind != :created and user_id == ctx.user_id

  defp about?(%AthanorArchived{athanor_id: athanor_id}, ctx), do: athanor_id == ctx.athanor_id
  defp about?(%Membership{}, _ctx), do: true
  defp about?(%CallerInvalidated{}, _ctx), do: true

  # The payload's sequence number, where its topic carries one.
  defp sequence(message) do
    case Map.get(message, :sequence, Map.get(message, :seq)) do
      n when is_integer(n) and n >= 0 ->
        n

      text when is_binary(text) ->
        case Integer.parse(text) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The tick's timer is re-armed on every tick; its current reference is
  # kept in the process dictionary under the stream's own ref, so the
  # `after` block cancels the live one whatever path ended the loop.
  defp arm(%{ref: ref, every: every}) do
    timer = Process.send_after(self(), {__MODULE__, :tick, ref}, every)
    Process.put({__MODULE__, ref}, timer)
    timer
  end

  defp cancel_ticks(ref) do
    case Process.delete({__MODULE__, ref}) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end
  end

  defp flush(ref) do
    receive do
      {__MODULE__, _timer, ^ref} -> flush(ref)
    after
      0 -> :ok
    end
  end
end
