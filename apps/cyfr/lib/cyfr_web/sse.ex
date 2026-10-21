# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.SSE do
  @moduledoc """
  The endpoint's streams: the per-caller bounds every SSE surface shares
  (a concurrent-stream slot and a hard deadline), and the delivery owner
  of a stream the gate admitted (`deliver/4`).

  Each surface uses its own subscription tag and its own platform
  settings (`mcp_subscription_*` for `subscriptions/listen`,
  `opus_events_*` for execution events, `frame_stream_max_concurrent`
  for a tincture frame's streams), read through
  `Arca.PlatformSettings.effective/1` when a stream opens: a change
  reaches the streams opened after it. Slots are counted per member, in
  this member's registry, so a caller's budget is per member of the cell.
  A slot is released when the stream releases it (`release_slot/2`) or
  when the connection process exits. A claim counts the key's slots and
  registers its own under one lock on the key (`claim_slot/3`), so
  concurrent opens never take more slots than the cap.

  ## Delivery under a grant

  A stream the gate admitted (`Sanctum.Gate.open_stream/3`) is delivered here
  and nowhere else on the endpoint. `deliver/4` subscribes the connection
  to the one topic the grant admits (`Cyfr.Bus.granted_topic/2`), writes
  each payload projected to the grant's fields (`Prima.StreamGrant.project/2`)
  as one event of `Prima.TinctureWire`'s stream, and keeps enforcing the
  grant until it closes the stream.

  The stream's declaration (`Prima.Provider.Stream`, read from the table
  the gate admitted it from) may add two things. A `refresh` is read once
  the subscription is in place and delivered before any live event, each
  item projected and marked `"refresh": true`, so an event published
  between the subscription and the read is delivered as well, after it,
  and the subscriber deduplicates it; a refresh that cannot be read ends
  the stream as `unavailable`. A `filter` names the payload field that
  must equal the grant's subject: the topic is the row's one topic,
  resolved with the subject set aside, and every refresh item and live
  payload of another subject is dropped.

  The grant is enforced until the stream closes:

    * at the grant's deadline. A frame's stream is held to its frame
      credential's row rather than to the bearer it opened with: each
      revalidation reads the row's current deadline, which a renewal
      moves, and the grant's deadline follows it up to the stream's own
      bound from the open (`Prima.StreamGrant`), so a renewal keeps every
      open stream of the frame with no new connection. At the grant's
      deadline before that bound, the row is read again whatever the
      context's freshness, so a renewal the last revalidation did not see
      still keeps the stream;
    * when the caller's context no longer stands: it is established again
      (the `:revalidate` function) on every standing announcement about
      the caller (a frame's stream hears its own credential suspended or
      revoked, `Cyfr.Bus.FrameCredential`), before an event is delivered
      once it is past the session-freshness bound
      (`Sanctum.Caller.fresh?/1`), and on a timer that fires within that
      bound, so a suspended or revoked frame's stream is closed at its
      announcement and within the bound without one, and a refusal ends
      the stream with that refusal as its last event;
    * on overflow: a connection whose mailbox holds more than the backlog
      bound has fallen too far behind to deliver faithfully, and the
      stream ends with a typed refusal event (`overflow/0`), never by
      dropping what it could not keep up with;
    * when the client goes away, which the next write finds.

  A reconnect is a new open under the gate. Nothing published while the
  subscriber was away is kept for it: the reopened stream hands it the
  declared refresh, if any, and then only what is published after its
  new subscription.
  """

  alias Cyfr.Bus.{AthanorArchived, CallerInvalidated, FrameCredential, Membership, Session}
  alias Prima.{StreamGrant, TinctureWire}
  alias Sanctum.Context

  # Intermediaries and client idle timeouts close a connection that says
  # nothing; a quiet stream is the normal state, not a broken one.
  @keep_alive_ms :timer.seconds(15)

  # The settings a surface may name: each surface's concurrent-stream cap
  # and stream lifetime.
  @limits ~w(mcp_subscription_max_concurrent opus_events_max_concurrent frame_stream_max_concurrent)a
  @lifetimes ~w(mcp_subscription_max_ms opus_events_max_ms)a

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
  share a nil `user_id`, and each key has its own budget, so one chatty
  integration never starves the others of its athanor. A frame's
  context is counted per frame credential: one frame's streams never
  draw on another's budget.

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

  # Every limit and lifetime is an integer setting. Each serves a stale
  # value, so a store outage answers the last one read and refuses no
  # stream for it.
  defp setting(key) do
    case Arca.PlatformSettings.effective(Atom.to_string(key)) do
      {:ok, value} when is_integer(value) -> value
    end
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
    stream = declared(name)
    actor = Context.actor(ctx)
    topic = Cyfr.Bus.granted_topic(actor, topic_grant(grant, stream))
    # The granted topic lies under the caller's own prefix by construction,
    # so the bus's tenant check cannot refuse it.
    :ok = Cyfr.Bus.subscribe(actor, topic)
    :ok = Cyfr.Bus.subscribe_standing(ctx.user_id)
    :ok = subscribe_frame(ctx)

    ref = make_ref()
    arm_deadline(ref, grant.deadline)

    state = %{
      ctx: ctx,
      grant: grant,
      name: name,
      payload: payload_struct(grant),
      filter: stream && stream.filter,
      refresh: stream && stream.refresh,
      revalidate: revalidate,
      every: every,
      max_backlog: Keyword.get(opts, :max_backlog, @max_backlog),
      ref: ref
    }

    arm(state)

    conn = open(conn)

    try do
      case Plug.Conn.chunk(conn, ": open\n\n") do
        {:ok, conn} -> refreshed(conn, state)
        {:error, _closed} -> conn
      end
    after
      # Every exit path: the timers, the subscriptions and any timer
      # message already queued go with the stream, so a kept-alive
      # connection's next request finds none of them.
      cancel_deadline(ref)
      cancel_ticks(ref)
      Cyfr.Bus.unsubscribe(actor, topic)
      Cyfr.Bus.unsubscribe_standing(ctx.user_id)
      unsubscribe_frame(ctx)
      flush(ref)
    end
  end

  # The one struct the grant's topic carries (the bus roster's); anything
  # else in the mailbox is not the stream's to deliver.
  defp payload_struct(%StreamGrant{topic: key}) do
    Enum.find_value(Cyfr.Bus.topics(), fn row -> row.key == key && row.struct end)
  end

  # The stream's declaration, from the table the gate admitted it from: its
  # refresh and its filter. A name the table does not hold delivers as a
  # stream with neither.
  defp declared(name) do
    case Sanctum.Catalog.lookup_stream(name) do
      {:ok, {_provider, %Prima.Provider.Stream{} = stream}} -> stream
      :miss -> nil
    end
  end

  # A filtering stream's subject selects payloads on the row's one topic,
  # so the topic is resolved with the subject set aside; it never names a
  # topic of its own.
  defp topic_grant(grant, %Prima.Provider.Stream{filter: filter}) when is_binary(filter),
    do: %{grant | subject: nil}

  defp topic_grant(grant, _stream), do: grant

  # The stream's current state, read after the subscription is in place
  # and delivered before any live event, each item marked `refresh`. An
  # event published between the subscription and the read is delivered
  # too, after it: the subscriber sees it twice and never misses it. A
  # refresh that cannot be read ends the stream.
  defp refreshed(conn, %{refresh: nil} = state), do: loop(conn, state)

  defp refreshed(conn, %{refresh: {module, function}} = state) do
    case fresh(state) do
      {:ok, state} ->
        case apply(module, function, [state.ctx, state.grant.subject]) do
          {:ok, items} when is_list(items) -> refresh_items(conn, state, items)
          _unread -> close(conn, refresh_unavailable())
        end

      {:error, refusal} ->
        close(conn, refusal)
    end
  end

  defp refresh_unavailable,
    do: Prima.Refusal.classify({:unavailable, "The stream's current state"})

  defp refresh_items(conn, state, []), do: loop(conn, state)

  defp refresh_items(conn, state, [item | rest]) do
    data = StreamGrant.project(state.grant, item)

    if selected?(state, data) do
      event = TinctureWire.stream_event(nil, state.name, Map.put(data, "refresh", true))

      case Plug.Conn.chunk(conn, event) do
        {:ok, conn} -> refresh_items(conn, state, rest)
        {:error, _closed} -> conn
      end
    else
      refresh_items(conn, state, rest)
    end
  end

  # A filtering stream delivers only the payloads whose filter field is
  # the grant's subject.
  defp selected?(%{filter: nil}, _data), do: true

  defp selected?(%{filter: filter, grant: %StreamGrant{subject: subject}}, data),
    do: is_binary(subject) and Map.get(data, filter) == subject

  defp loop(conn, %{ref: ref, payload: payload} = state) do
    receive do
      {__MODULE__, :deadline, ^ref} ->
        at_deadline(conn, state)

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
             is_struct(message, AthanorArchived) or is_struct(message, Membership) or
             is_struct(message, FrameCredential) ->
        if about?(message, state.ctx) do
          case state.revalidate.() do
            {:ok, ctx} -> loop(conn, revalidated(state, ctx))
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
    data = StreamGrant.project(state.grant, Map.from_struct(message))

    if selected?(state, data),
      do: deliver_selected(conn, state, message, data),
      else: loop(conn, state)
  end

  defp deliver_selected(conn, state, message, data) do
    with :ok <- backlog(state.max_backlog),
         {:ok, state} <- fresh(state) do
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
      with {:ok, ctx} <- state.revalidate.(), do: {:ok, revalidated(state, ctx)}
    end
  end

  # A frame's stream at its grant's deadline, before its own bound from the
  # open, reads its credential's row again whatever the context's
  # freshness: a renewal moved the deadline, and the timer is armed again
  # for it, never past the bound; a credential that no longer stands
  # closes the stream with its refusal. At the bound, and for any other
  # stream, the deadline ends it.
  defp at_deadline(
         conn,
         %{grant: %StreamGrant{bound: %DateTime{} = bound}, ctx: %Context{frame: %{}}} = state
       ) do
    if DateTime.compare(DateTime.utc_now(), bound) == :lt do
      case state.revalidate.() do
        {:ok, ctx} -> held_on(conn, revalidated(state, ctx))
        {:error, refusal} -> close(conn, refusal)
      end
    else
      conn
    end
  end

  defp at_deadline(conn, _state), do: conn

  defp held_on(conn, %{grant: %StreamGrant{deadline: deadline}, ref: ref} = state) do
    if DateTime.compare(deadline, DateTime.utc_now()) == :gt do
      arm_deadline(ref, deadline)
      loop(conn, state)
    else
      conn
    end
  end

  # The context established again, and for a frame's stream the grant's
  # deadline moved with its credential's row, never past the stream's own
  # bound from the open: the timer is armed again for the later deadline.
  defp revalidated(%{grant: grant, ref: ref} = state, ctx) do
    case extended(grant, ctx) do
      nil ->
        %{state | ctx: ctx}

      deadline ->
        arm_deadline(ref, deadline)
        %{state | ctx: ctx, grant: %{grant | deadline: deadline}}
    end
  end

  defp extended(
         %StreamGrant{deadline: current, bound: %DateTime{} = bound},
         %Context{frame: %{}, credential_deadline: %DateTime{} = credential}
       ) do
    next = Enum.min([bound, credential], DateTime)
    if DateTime.compare(next, current) == :gt, do: next
  end

  defp extended(_grant, _ctx), do: nil

  # The deadline's one timer, kept under the stream's ref like its ticks,
  # so arming it again cancels the earlier one and every exit cancels it.
  defp arm_deadline(ref, deadline) do
    cancel_deadline(ref)
    remaining = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)
    timer = Process.send_after(self(), {__MODULE__, :deadline, ref}, remaining)
    Process.put({__MODULE__, :deadline, ref}, timer)
    timer
  end

  # A timer that fired before it was cancelled has queued its message,
  # which goes with it: a deadline armed again is never met by the old one.
  defp cancel_deadline(ref) do
    with timer when timer != nil <- Process.delete({__MODULE__, :deadline, ref}),
         false <- Process.cancel_timer(timer) do
      receive do
        {__MODULE__, :deadline, ^ref} -> :ok
      after
        0 -> :ok
      end
    end

    :ok
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

  defp about?(%FrameCredential{id: id}, %Context{frame: %{id: frame_credential}}),
    do: id == frame_credential

  defp about?(%FrameCredential{}, _ctx), do: false

  # A frame's stream also hears its own person's frame credentials
  # suspended or revoked, so it ends at once rather than at its next
  # revalidation.
  defp subscribe_frame(%Context{frame: %{}, user_id: user_id}) when is_binary(user_id),
    do: Cyfr.Bus.subscribe_global(Cyfr.Bus.frame_credentials(user_id))

  defp subscribe_frame(%Context{}), do: :ok

  defp unsubscribe_frame(%Context{frame: %{}, user_id: user_id}) when is_binary(user_id),
    do: Cyfr.Bus.unsubscribe_global(Cyfr.Bus.frame_credentials(user_id))

  defp unsubscribe_frame(%Context{}), do: :ok

  # The payload's sequence number, where its topic carries one: an
  # execution event's `sequence` (`Cyfr.Bus.ExecutionEvent`), the text of a
  # durable event's number. A delta's `<durable>.<n>` is no number, so its
  # event carries no id, as a payload of any other topic does not.
  defp sequence(%{sequence: sequence}) when is_binary(sequence) do
    case Integer.parse(sequence) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp sequence(_message), do: nil

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
