# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.FrameSocket do
  @moduledoc """
  A frame's stream connection, `Prima.TinctureWire`'s: one WebSocket per
  frame carrying every stream its page subscribes to, upgraded on the data
  routes (`Emissary.Web.TinctureDataController`) at `/_f/v1/socket` for an
  app and at a canvas open's own `/_f/v1/o/<frame id>/socket`. It is the
  delivery owner of every stream a frame reads.

  ## The connection

  The upgrade admits nothing: the connection reads no cookie and no
  session, and the frame credential travels in each `subscribe`, never in
  the connection's URL. A connection is one frame's: the first
  subscription whose credential establishes binds it to that frame
  credential and is charged one request of the frame's rate
  (`Emissary.Web.FrameAdmission.charge/1`); later subscriptions are not
  charged, and one presenting another frame's credential is refused
  `forbidden` (`frame_connection_mismatch`). A frame holds one connection:
  binding closes every older connection of the same frame credential on
  this member (`replaced`). A connection carries at most
  `Prima.TinctureWire.max_subscriptions/0` subscriptions at once and takes
  no message over `Prima.TinctureWire.max_message_bytes/0` payload bytes,
  however many frames it arrives in (`too_big`); one that does not read as
  the wire's closes it (`unreadable`), and a connection that
  has held no subscription for `Prima.TinctureWire.idle_ms/0` closes
  (`idle`). The endpoint pings it every 15 seconds, so a quiet connection
  never looks idle to an intermediary, and one that answers nothing for a
  minute is closed.

  ## A subscription

  Each `subscribe` is admitted as a request is, in order: room on the
  connection; the credential established as a request's, never held, and
  on a canvas path held to the frame the path names, then the version
  and the grant (`Emissary.Web.FrameAdmission.frame/3`); where it may
  read (a canvas on its own path alone, `not_a_canvas` and
  `canvas_path_required`); the bind; the declaration (a stream the
  tincture declares with a subject that declaration takes, and none for a
  stream bound to its holder, whose subject the gate supplies); and what
  its events may carry to the origins the frame connects to
  (`Emissary.Web.FrameAdmission.flowing/2`). Then the gate's one stream
  entry opens it (`Sanctum.Gate.open_stream/3`), which records it. A
  refusal before the gate is recorded once as an admission decision of
  its own, and the gate's is the gate's; either is answered `ended` with
  its error and holds nothing.

  An admitted subscription is delivered here. Its forwarder
  (`Emissary.Web.StreamForwarder`) is subscribed to the one topic the
  grant admits (`Cyfr.Bus.granted_topic/2`) before `subscribed` is sent,
  and the stream's declared refresh is read after that, each item
  projected and marked `"refresh": true`, so a fact published between the
  subscription and the read arrives after it: the frame may see an item
  twice and never misses one. A refresh is read by a task of its own
  (`Emissary.Web.TaskSupervisor`), never by the connection, within a
  deadline (30 seconds, a canvas-readable stream's bound when shorter),
  so the connection keeps answering whatever the provider does; the
  facts of a stream whose read runs are held and follow its picture. A
  read past its deadline is stopped, so nothing it would have answered
  later is applied, and one whose subscription or connection ends is
  stopped with it. A refresh that cannot be read, or not within its
  deadline, ends the subscription `unavailable`. Each fact of the topic follows as an
  `event`, projected to the grant's fields (`Prima.StreamGrant.project/2`)
  and tagged with the stream and the subject the frame asked for. A
  filtering stream's subject selects payloads on its row's one topic, so
  the topic is resolved with the subject set aside and every item of
  another subject is dropped.

  A canvas-readable stream is delivered by the delivery contract
  (`Compendium.Canvas.catalog/1`): its refresh ends with `snapshot`, the
  time the read began, and no item of it is stamped later than that,
  `at` in whatever form it takes. On the subscription, a change of an
  item delivered after another carries a higher revision: one lower than
  the item's last is raised past it, and an equal one is the same change
  again. Its picture is read again and handed as a `resync` at half the
  stream's `stale_after`, and once a change of a `reread` kind settles,
  in the change's place. A picture `stale_after` old with no fresh one
  is told `stale` once, whatever its read does; a read again at the bound
  that fails leaves the picture, with the facts held meanwhile, and is
  tried again at half the bound or after 30 seconds, whichever is
  sooner. One the frame holds a hole without, after a reread or an
  overflow, that fails ends the subscription with the refusal, which the
  frame opens again.

  `unsubscribe` ends a subscription at once, its forwarder with it, and
  its place on the connection is free for the next `subscribe`.

  A canvas version's validation trial (a frame whose mode is
  `:validation`) is answered from fixtures and admits nothing: no gate,
  no forwarder and no place on the connection. The stream it names is
  answered `subscribed`, its fixtures, `snapshot` at the epoch for a
  canvas-readable stream, and `ended`: for a feed's results,
  the envelope of the feed the athanor binds under that name
  (`Opus.feeds/1`), its result the fixture of the binding's result shape,
  and no event for a name the athanor does not bind; for another stream,
  the fixture of its shape (`Prima.Canvas.Shape.fixture/1`), and no event
  for a stream that declares none.

  ## The grant, held

  The connection holds its frame's context, and every subscription to
  its grant until it ends:

    * at the grant's deadline. A frame's subscriptions are held to its
      frame credential's row rather than to the bearers they opened with:
      each revalidation reads the row's current deadline, which a renewal
      moves, and each grant's deadline follows it up to the stream's own
      bound from its open (`Prima.StreamGrant`). At a grant's deadline
      before that bound the row is read again whatever the context's
      freshness, so a renewal the last revalidation did not see still
      keeps it; at the bound the subscription ends;
    * when the frame's context no longer stands. It is established again,
      held to the row, under the newest bearer the frame sent, on every
      standing announcement about the frame's person and on its own
      credential suspended or revoked (`Cyfr.Bus.FrameCredential`), before
      an event is delivered once it is past the session-freshness bound
      (`Sanctum.Caller.fresh?/1`), and on a timer within that bound while
      any subscription is held. One revalidation serves every
      subscription: a refusal ends each with it as its error, and a flow
      that no longer covers a stream ends that subscription with the
      flow's refusal;
    * on overflow: a connection whose mailbox holds more than 1,000
      messages has fallen too far behind to deliver faithfully. It lets
      go of every fact it has not delivered: a canvas-readable stream is
      handed a fresh picture in their place, and every other subscription
      ends with a typed refusal (`overflow/0`), never by dropping what it
      could not keep up with unannounced;
    * when the frame unsubscribes, or the connection closes.

  A reconnect is a new connection, and each of its subscriptions a new
  open under the gate: nothing published while the frame was away is kept
  for it beyond the declared refresh. A resync is read under the frame's
  context established again first, as an open's is, and projected and
  selected as the first picture was, so it hands nothing the grant does
  not cover.
  """

  @behaviour WebSock

  alias Cyfr.Bus.{AthanorArchived, CallerInvalidated, FrameCredential, Session}
  alias Emissary.Web.{FrameAdmission, StreamForwarder}
  alias Prima.{StreamGrant, TinctureWire}
  alias Sanctum.Context

  @keep_alive_ms 15_000

  # A connection's read timeout: above the ping's interval, whose pong a
  # browser answers on its own.
  @timeout_ms 60_000

  # How often a connection holding a subscription looks at its context's
  # age. A context is established again once it is past the
  # session-freshness bound, so a standing change reaches every
  # subscription within the bound and this tick.
  @revalidate_every_ms 1_000

  # The mailbox depth past which a connection has fallen too far behind
  # its topics to deliver them faithfully.
  @max_backlog 1_000

  # How long a reread waits for the changes that came with it, so a burst
  # of them is answered with one fresh picture.
  @reread_settle_ms 250

  # The longest a picture's read may take, and the longest a picture whose
  # read failed waits before it is read again; a canvas-readable stream
  # whose bound is shorter takes its bound for the first and half of it
  # for the second.
  @read_ms 30_000
  @stale_retry_ms 30_000

  # The stream a canvas reads a feed's results on, by the feed's name as
  # its subject.
  @feed_stream Prima.Manifest.Tincture.feed_results()

  # A validation answer's feed envelope is the binding's first revision at
  # the epoch: a fixture, never a result the feed produced.
  @fixture_revision 0
  @fixture_at DateTime.from_unix!(0)

  @typedoc "Where the connection was opened: the shared route, or a canvas open's own path."
  @type path :: :shared | {:canvas, String.t()}

  # The largest header a client's frame carries: two bytes, a 64-bit
  # length and the mask. A frame's bound is the message bound with room
  # for it, so a message exactly at the bound arrives in one frame.
  @max_frame_header 14
  @max_message_bytes TinctureWire.max_message_bytes()

  @doc """
  Hand `conn`, a WebSocket upgrade on `path` its caller has found to be
  one (`WebSockAdapter.UpgradeValidation`), to a new stream connection. The wire's
  message bound counts a message's payload bytes: the listener refuses a
  message reassembled from fragments over it, and a frame too large to
  carry it, and the connection refuses a whole message over it
  (`handle_in/2`).
  """
  @spec upgrade(Plug.Conn.t(), path()) :: Plug.Conn.t()
  def upgrade(%Plug.Conn{} = conn, path) do
    state = %{
      path: path,
      client_ip: Sanctum.ClientIp.resolve(conn),
      request_id: conn.assigns[:request_id]
    }

    # The options go to the listener as given: Bandit reads
    # `max_fragmented_message_size`, which WebSockAdapter's option type
    # does not name.
    opts = [
      timeout: @timeout_ms,
      max_frame_size: @max_message_bytes + @max_frame_header,
      max_fragmented_message_size: @max_message_bytes,
      compress: false
    ]

    conn
    |> Plug.Conn.upgrade_adapter(:websocket, {__MODULE__, state, opts})
    |> Plug.Conn.halt()
  end

  @doc "The refusal every subscription of a connection that fell too far behind ends with."
  @spec overflow() :: Prima.Refusal.t()
  def overflow do
    %Prima.Refusal{
      class: :rate_limited,
      reason: :stream_overflow,
      message: "The stream fell too far behind and was closed — open it again"
    }
  end

  # ---------------------------------------------------------------------------
  # The connection
  # ---------------------------------------------------------------------------

  @impl WebSock
  def init(state) do
    if state.request_id, do: Prima.LoggerContext.set_request_id(state.request_id)

    state =
      Map.merge(state, %{
        caller: nil,
        bound: nil,
        subs: %{},
        ref: make_ref(),
        idle: nil,
        ticking: false
      })

    {:ok, state |> arm_keep_alive() |> idle_if_empty()}
  end

  @impl WebSock
  def handle_in({text, opcode: :text}, state)
      when byte_size(text) > @max_message_bytes,
      do: {:stop, :normal, {TinctureWire.close_code(:too_big), "too big"}, state}

  def handle_in({text, opcode: :text}, state) do
    case Jason.decode(text) do
      {:ok, message} -> message |> TinctureWire.decode_message() |> received(state)
      {:error, _not_json} -> unreadable(state, "a message is a JSON object")
    end
  end

  def handle_in({_data, opcode: :binary}, state),
    do: unreadable(state, "a message is a text frame")

  @impl WebSock
  def handle_info({__MODULE__, :fact, sub, message}, state) do
    case Map.get(state.subs, sub) do
      nil ->
        {:ok, state}

      entry ->
        data = StreamGrant.project(entry.grant, Map.from_struct(message))

        cond do
          overflowing?() -> fell_behind(state)
          not selected?(entry, data) -> {:ok, state}
          rereads?(entry, data) -> {:ok, settle_reread(state, sub)}
          entry.read != nil -> {:ok, hold(state, sub, message, data)}
          true -> deliver(sub, message, data, state)
        end
    end
  end

  def handle_info({__MODULE__, :deadline, sub, token}, state) do
    case Map.get(state.subs, sub) do
      %{timer: {^token, _timer}} = entry -> at_deadline(sub, entry, state)
      _another -> {:ok, state}
    end
  end

  def handle_info({__MODULE__, :reread, sub, token}, state) do
    case Map.get(state.subs, sub) do
      %{reread: {^token, _timer, why}} = entry ->
        reread(sub, why, %{state | subs: Map.put(state.subs, sub, %{entry | reread: nil})})

      _another ->
        {:ok, state}
    end
  end

  def handle_info({__MODULE__, :stale, sub, token}, state) do
    case Map.get(state.subs, sub) do
      %{stale_timer: {^token, _timer}} = entry -> stale(sub, entry, state)
      _another -> {:ok, state}
    end
  end

  # A picture's read answered, or its reader ended without an answer.
  def handle_info({ref, answer}, state) when is_reference(ref) do
    case reading(state, ref) do
      {:ok, sub} ->
        Process.demonitor(ref, [:flush])
        read_done(sub, answer, state)

      :error ->
        {:ok, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case reading(state, ref) do
      {:ok, sub} -> read_done(sub, :ended, state)
      :error -> {:ok, state}
    end
  end

  def handle_info({__MODULE__, :tick, ref}, %{ref: ref} = state) do
    if state.subs == %{} do
      {:ok, %{state | ticking: false}}
    else
      {frames, state} = fresh(state)
      push(frames, state |> arm_tick() |> idle_if_empty())
    end
  end

  def handle_info({__MODULE__, :ping, ref}, %{ref: ref} = state),
    do: {:push, {:ping, ""}, arm_keep_alive(state)}

  def handle_info({__MODULE__, :idle, token}, %{idle: {token, _timer}} = state),
    do: {:stop, :normal, {TinctureWire.close_code(:idle), "idle"}, state}

  def handle_info({__MODULE__, :replaced}, state),
    do: {:stop, :normal, {TinctureWire.close_code(:replaced), "replaced"}, state}

  def handle_info(message, %{caller: %{ctx: ctx}} = state)
      when is_struct(message, Session) or is_struct(message, CallerInvalidated) or
             is_struct(message, AthanorArchived) or is_struct(message, FrameCredential) do
    if state.subs != %{} and about?(message, ctx) do
      {frames, state} = revalidate(state)
      push(frames, idle_if_empty(state))
    else
      {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  # Every forwarder monitors the connection and ends with it, and its
  # registration under the frame goes with the process.
  @impl WebSock
  def terminate(_reason, _state), do: :ok

  defp received({:ok, {:subscribe, fields}}, state), do: subscribe(fields, state)

  defp received({:ok, {:unsubscribe, sub}}, state),
    do: {:ok, state |> drop(sub) |> idle_if_empty()}

  defp received({:refused, sub, sentence}, state),
    do: refuse(sub, Prima.Refusal.classify({:invalid_argument, sentence}), drop(state, sub))

  defp received({:error, sentence}, state), do: unreadable(state, sentence)

  # A message no subscription can be told of: recorded as the connection's
  # refusal, its sentence in the record, and the connection closes.
  defp unreadable(state, sentence) do
    refusal = Prima.Refusal.classify({:invalid_argument, sentence})
    record(state, refusal, state.caller && state.caller.ctx)
    {:stop, :normal, {TinctureWire.close_code(:unreadable), "unreadable"}, state}
  end

  # ---------------------------------------------------------------------------
  # A subscription's admission
  # ---------------------------------------------------------------------------

  # A number already live ends that subscription first: the frame numbers
  # each of its subscriptions anew, so its own is no longer what it holds.
  defp subscribe(%{sub: sub}, %{subs: subs} = state) when is_map_key(subs, sub) do
    refusal = Prima.Refusal.classify({:invalid_argument, "sub names a subscription still open"})
    refuse(sub, refusal, drop(state, sub))
  end

  defp subscribe(%{sub: sub, credential: bearer} = fields, state) do
    with :ok <- room(state),
         {:ok, caller} <- FrameAdmission.frame(bearer, state.client_ip, path: state.path) do
      # A refusal of either leaves the connection as it was.
      with :ok <- placed(caller, state.path),
           {:ok, bound} <- bind(caller, state) do
        admitted(fields, caller, bound)
      else
        {:error, refusal} -> refuse(sub, refusal, state, caller.ctx)
      end
    else
      {:error, refusal} -> refuse(sub, refusal, state)
    end
  end

  defp admitted(%{sub: sub, stream: name, subject: subject} = fields, caller, state) do
    with :ok <- granted(name, subject, caller),
         :ok <- FrameAdmission.flowing({:stream, name}, caller) do
      case caller.ctx.frame.mode do
        :validation -> validation(fields, caller, state)
        :live -> open(fields, caller, state)
      end
    else
      {:error, refusal} -> refuse(sub, refusal, state, caller.ctx)
    end
  end

  defp room(%{subs: subs}) do
    if map_size(subs) < TinctureWire.max_subscriptions(),
      do: :ok,
      else: {:error, Prima.Refusal.classify(:stream_limit)}
  end

  # Where a frame may read: a canvas on its own path alone, and on that
  # path only a canvas.
  defp placed(%{declaration: declaration}, :shared) do
    if FrameAdmission.canvas?(declaration),
      do: {:error, FrameAdmission.canvas_path_required()},
      else: :ok
  end

  defp placed(%{declaration: declaration}, {:canvas, _frame_id}) do
    if FrameAdmission.canvas?(declaration), do: :ok, else: {:error, FrameAdmission.not_a_canvas()}
  end

  # The connection is the first established frame's; every later
  # admission of it is held as the frame's newest context and bearer.
  defp bind(%{ctx: %Context{frame: %{id: id}}} = caller, %{bound: id} = state),
    do: {:ok, %{state | caller: caller}}

  defp bind(%{ctx: %Context{frame: %{id: id}} = ctx} = caller, %{bound: nil} = state) do
    with :ok <- FrameAdmission.charge(caller) do
      :ok = claim_frame(ctx)
      :ok = Cyfr.Bus.subscribe_standing()
      :ok = subscribe_frame(ctx)
      {:ok, %{state | bound: id, caller: caller}}
    end
  end

  defp bind(_another_frame, _state), do: {:error, frame_connection_mismatch()}

  # One connection per frame on this member: the newest is the frame's,
  # and every older one is told to close. The lock makes two connections
  # binding at once take their turns.
  defp claim_frame(%Context{athanor_id: athanor_id, frame: %{id: id}}) do
    key = {:frame_socket, athanor_id, id}

    :global.trans(
      {{__MODULE__, key}, self()},
      fn ->
        for {pid, _value} <- Registry.lookup(CyfrWeb.SSE.Registry, key),
            pid != self(),
            do: send(pid, {__MODULE__, :replaced})

        {:ok, _owner} = CyfrWeb.SSE.Registry.register(key, :connection)
      end,
      [node()]
    )

    :ok
  end

  # A frame's connection also hears its own person's frame credentials
  # suspended or revoked, so its subscriptions end at once rather than at
  # their next revalidation.
  defp subscribe_frame(%Context{user_id: user_id}) when is_binary(user_id),
    do: Cyfr.Bus.subscribe_global(Cyfr.Bus.frame_credentials(user_id))

  defp subscribe_frame(%Context{}), do: :ok

  defp granted(name, subject, %{declaration: declaration}) do
    if Enum.any?(declaration.streams, &(&1.name == name and takes?(&1.subject, subject))) and
         not (is_binary(subject) and holder_bound?(name)),
       do: :ok,
       else: {:error, FrameAdmission.undeclared(:stream)}
  end

  # A declared subject is a literal, `*` for any literal the provider's
  # grammar admits (which the gate checks), or none.
  defp takes?(nil, subject), do: is_nil(subject)
  defp takes?(_declared, nil), do: false

  defp takes?(declared, subject),
    do: declared == Prima.Manifest.Tincture.any_subject() or declared == subject

  # A stream bound to its holder takes no subject from the frame: the
  # gate supplies the holder's own.
  defp holder_bound?(name) do
    case Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), name) do
      {:ok, stream} -> Prima.Provider.Stream.holder_bound?(stream)
      {:error, :undeclared_stream} -> false
    end
  end

  # A refusal made here, before the gate, is an admission's: recorded
  # once, under the frame's context once one is established, then
  # answered.
  defp refuse(sub, refusal, state, ctx \\ nil) do
    refusal = %{refusal | stage: :admission}
    record(state, refusal, ctx || (state.caller && state.caller.ctx))
    {:push, [text(TinctureWire.ended(sub, refusal))], idle_if_empty(state)}
  end

  defp record(state, refusal, ctx) do
    decision =
      Sanctum.Decisions.refused(ctx, refusal,
        call_id: Prima.UUID7.generate_id("call"),
        request_id: state.request_id,
        plane: :external,
        tool: "tincture",
        action: "stream"
      )

    Sanctum.Decisions.open(ctx, decision, %{method: "stream", input: %{}})
  end

  # ---------------------------------------------------------------------------
  # A subscription's open
  # ---------------------------------------------------------------------------

  defp open(%{sub: sub, stream: name, subject: subject}, caller, state) do
    case Sanctum.Gate.open_stream(caller.ctx, name, subject) do
      {:ok, grant} -> deliver_open(sub, name, subject, grant, state)
      {:error, refusal} -> {:push, [text(TinctureWire.ended(sub, refusal))], idle_if_empty(state)}
    end
  end

  # The forwarder is subscribed before `subscribed` is sent, and the
  # declared refresh read after it.
  defp deliver_open(sub, name, subject, grant, state) do
    stream = declared(name)
    actor = Context.actor(state.caller.ctx)
    topic = Cyfr.Bus.granted_topic(actor, topic_grant(grant, stream))

    case StreamForwarder.start(self(), __MODULE__, sub, actor, topic, payload_struct(grant)) do
      {:ok, forwarder} ->
        entry = %{
          stream: name,
          subject: subject,
          grant: grant,
          filter: stream && stream.filter,
          delivery: delivery(stream),
          forwarder: forwarder,
          timer: nil,
          reread: nil,
          stale_timer: nil,
          picture: nil,
          stale: false,
          read: nil,
          held: [],
          again: false,
          told: %{}
        }

        {frames, state} = state |> put_sub(sub, entry) |> start_read(sub, :first)
        {:push, [text(TinctureWire.subscribed(sub)) | frames], idle_if_empty(state)}

      {:error, _unstarted} ->
        {:push, [text(TinctureWire.ended(sub, undeliverable()))], idle_if_empty(state)}
    end
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

  # The one struct the grant's topic carries (the bus roster's); anything
  # else the topic carries is not the stream's to deliver.
  defp payload_struct(%StreamGrant{topic: key}),
    do: Enum.find_value(Cyfr.Bus.topics(), fn row -> row.key == key && row.struct end)

  # What a canvas-readable stream delivers by (`Compendium.Canvas.catalog/1`):
  # the kinds answered with a fresh picture and how long a picture stands.
  # Any other stream has no picture.
  defp delivery(%Prima.Provider.Stream{shape: %{}, stale_after: stale_after} = stream),
    do: %{key: stream.key, reread: stream.reread, stale_after: stale_after}

  defp delivery(_stream), do: nil

  # ---------------------------------------------------------------------------
  # A picture's read
  # ---------------------------------------------------------------------------

  # The stream's current state is read by a task of its own, never by the
  # connection, under the context the subscription holds and within a
  # deadline, so the connection keeps answering whatever the provider does.
  # A fact of the stream that comes while its read runs is held and handed
  # after the picture, so the picture always comes first. `why` is the
  # read's cause: `:first` after `subscribed`, `:periodic` and `:retry` at
  # the stream's bound, `:needed` when the frame holds a hole.
  defp start_read(state, sub, why) do
    entry = Map.fetch!(state.subs, sub)

    case declared(entry.stream) do
      %Prima.Provider.Stream{refresh: {_module, _function} = refresh} ->
        began = DateTime.utc_now()
        task = reader(state.caller.ctx, refresh, entry.grant.subject, read_ms(entry))
        read = %{ref: task.ref, pid: task.pid, why: why, began: began}
        entry = %{entry | read: read, held: [], again: false}
        {[], %{state | subs: Map.put(state.subs, sub, entry)}}

      _no_refresh ->
        {frames, entry} = picture(sub, entry, [], DateTime.utc_now(), why)
        {frames, %{state | subs: Map.put(state.subs, sub, entry)}}
    end
  end

  # The read under a task that answers the connection by its reference:
  # the provider's answer, `:timeout` once the deadline passed (the read
  # stopped, so an answer it would have given later is never applied), or
  # nothing when the connection is gone, which stops the read with it.
  defp reader(ctx, {module, function}, subject, deadline) do
    owner = self()

    Task.Supervisor.async_nolink(Emissary.Web.TaskSupervisor, fn ->
      watch = Process.monitor(owner)
      tag = make_ref()
      task = self()
      # The read's process carries the callers a task's would, so it reads
      # as the connection may.
      callers = [task | Process.get(:"$callers", [])]

      read =
        spawn_link(fn ->
          Process.put(:"$callers", callers)
          send(task, {tag, current(module, function, ctx, subject)})
        end)

      receive do
        {^tag, answer} ->
          answer

        {:DOWN, ^watch, :process, _pid, _reason} ->
          exit(:shutdown)
      after
        deadline ->
          Process.unlink(read)
          Process.exit(read, :kill)
          :timeout
      end
    end)
  end

  defp current(module, function, ctx, subject) do
    apply(module, function, [ctx, subject])
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # How long a read may take: a canvas-readable stream's bound, at most
  # the connection's own limit.
  defp read_ms(%{delivery: %{stale_after: seconds}}), do: min(seconds * 1_000, @read_ms)
  defp read_ms(_entry), do: @read_ms

  defp reading(state, ref) do
    Enum.find_value(state.subs, :error, fn
      {sub, %{read: %{ref: ^ref}}} -> {:ok, sub}
      _other -> nil
    end)
  end

  # A read's answer. Read, the picture is handed (a `resync` first unless
  # it is the first), each item projected, selected and marked `refresh`,
  # then the facts held while it ran. A first read, or one the frame holds
  # a hole without, that is not answered ends the subscription
  # `unavailable`, which the frame opens again; one at the bound leaves the
  # picture as it is, with the facts held meanwhile, and is tried again.
  defp read_done(sub, answer, state) do
    %{read: %{why: why, began: began}} = entry = Map.fetch!(state.subs, sub)
    state = %{state | subs: Map.put(state.subs, sub, %{entry | read: nil})}

    case answer do
      {:ok, items} when is_list(items) ->
        {frames, state} = fresh(state)

        case Map.get(state.subs, sub) do
          nil ->
            push(frames, idle_if_empty(state))

          entry ->
            {handed, entry} = handed(sub, entry, items, began, why)
            state = pictured(%{state | subs: Map.put(state.subs, sub, entry)}, sub, began)
            state = if entry.again, do: settle_reread(state, sub), else: state
            push(frames ++ handed, state)
        end

      _unread when why in [:first, :needed] ->
        ended = text(TinctureWire.ended(sub, unread()))
        push([ended], state |> drop(sub) |> idle_if_empty())

      _unread ->
        {frames, entry} = release(sub, Map.fetch!(state.subs, sub))
        state = %{state | subs: Map.put(state.subs, sub, entry)}
        push(frames, settle_reread(state, sub, :retry, retry_ms(entry)))
    end
  end

  # The picture's frames and the held facts after them, the entry they
  # leave, and its picture's timers armed again.
  defp handed(sub, entry, items, began, why) do
    projected =
      for item <- items,
          data = StreamGrant.project(entry.grant, item),
          selected?(entry, data),
          do: data |> clamped(entry, began) |> Map.put("refresh", true)

    {pictured, entry} = picture(sub, entry, projected, began, why)
    {held, entry} = release(sub, entry)
    {pictured ++ held, entry}
  end

  defp unread, do: Prima.Refusal.classify({:unavailable, "The stream's current state"})

  # A canvas-readable item of a snapshot is stamped no later than its read
  # began, whichever form its time takes, so it never outranks a change
  # the read did not see.
  defp clamped(data, %{delivery: nil}, _began), do: data

  defp clamped(data, _entry, began) do
    latest = DateTime.to_unix(began, :microsecond)

    data
    |> Map.update!("revision", fn
      revision when is_integer(revision) -> min(revision, latest)
      other -> other
    end)
    |> Map.update!("at", &no_later(&1, began))
  end

  defp no_later(%DateTime{} = at, began), do: Enum.min([at, began], DateTime)

  defp no_later(at, began) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} ->
        if DateTime.compare(parsed, began) == :gt, do: DateTime.to_iso8601(began), else: at

      {:error, _unparsed} ->
        at
    end
  end

  defp no_later(at, _began), do: at

  # A picture as the frame is handed it: a `resync` before any but the
  # first, its items, and for a canvas-readable stream the `snapshot` that
  # says it is whole.
  defp picture(sub, entry, items, began, why) do
    {events, entry} =
      Enum.map_reduce(items, entry, fn data, entry ->
        {data, entry} = revisioned(entry, data)
        {event(sub, entry, data), entry}
      end)

    resync = if why == :first, do: [], else: [text(TinctureWire.resync(sub))]
    snapshot = if entry.delivery, do: [text(TinctureWire.snapshot(sub, began))], else: []
    {resync ++ events ++ snapshot, entry}
  end

  # The facts held while a read ran, as events after its picture.
  defp release(sub, %{held: held} = entry) do
    {events, entry} =
      held
      |> Enum.reverse()
      |> Enum.map_reduce(entry, fn {message, data}, entry ->
        {data, entry} = revisioned(entry, data)
        {event(sub, entry, data, sequence(message)), entry}
      end)

    {events, %{entry | held: []}}
  end

  # A fact of a stream whose read runs, held for after its picture. Past
  # the backlog bound the held facts go, and the picture is read again
  # once the running read has answered.
  defp hold(state, sub, message, data) do
    entry = Map.fetch!(state.subs, sub)

    entry =
      if length(entry.held) >= @max_backlog,
        do: %{entry | held: [], again: true},
        else: %{entry | held: [{message, data} | entry.held]}

    %{state | subs: Map.put(state.subs, sub, entry)}
  end

  # On one subscription, a later change of an item always carries a
  # higher revision than the one before it, whatever the clock of the
  # member that told it: a revision lower than the item's last is raised
  # past it. An equal one is the same change heard again, and keeps it.
  # An item is named by the stream's key, the stream itself when it has
  # none.
  defp revisioned(%{delivery: %{key: key}, told: told} = entry, %{"revision" => revision} = data)
       when is_integer(revision) do
    item = if key, do: Map.get(data, key), else: :stream

    revision =
      case Map.fetch(told, item) do
        {:ok, last} when revision < last -> last + 1
        _first_or_later -> revision
      end

    {%{data | "revision" => revision},
     %{entry | told: Map.update(told, item, revision, &max(&1, revision))}}
  end

  defp revisioned(entry, data), do: {data, entry}

  # An admitted open no forwarder could hear: nothing waits on it.
  defp undeliverable,
    do: Prima.Refusal.classify({:unavailable, "This CYFR could not deliver the stream now"})

  # A filtering stream delivers only the payloads whose filter field is
  # the grant's subject.
  defp selected?(%{filter: nil}, _data), do: true

  defp selected?(%{filter: filter, grant: %StreamGrant{subject: subject}}, data),
    do: is_binary(subject) and Map.get(data, filter) == subject

  # The stream a validation trial names, answered once from its fixtures
  # and ended, under no grant and in no place on the connection. A feed's
  # bindings the store cannot read are refused before anything opens.
  defp validation(%{sub: sub, stream: name, subject: subject}, caller, state) do
    case fixtures(caller.ctx, name, subject) do
      {:ok, items} ->
        entry = %{stream: name, subject: subject, delivery: delivery(declared(name)), told: %{}}
        {pictured, _entry} = picture(sub, entry, items, @fixture_at, :first)

        {:push,
         [text(TinctureWire.subscribed(sub))] ++ pictured ++ [text(TinctureWire.ended(sub, nil))],
         idle_if_empty(state)}

      {:error, refusal} ->
        refuse(sub, refusal, state, caller.ctx)
    end
  end

  # A feed's results: the envelope of the feed the athanor binds under the
  # subject's name, its result the fixture of the binding's result shape;
  # none for a name the athanor does not bind.
  defp fixtures(ctx, @feed_stream, subject) do
    case Opus.feeds(ctx) do
      {:ok, feeds} ->
        {:ok,
         for %{binding_id: id, binding: %{name: ^subject} = binding} <- feeds do
           result = Prima.Canvas.Shape.fixture(binding.result_shape)
           Prima.Feed.envelope(id, binding, @fixture_revision, @fixture_at, result)
         end}

      {:error, _unanswered} ->
        {:error, Prima.Refusal.classify(:unavailable)}
    end
  end

  # Another stream: the fixture of its shape, and none for a stream that
  # declares no shape.
  defp fixtures(_ctx, name, _subject) do
    case Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), name) do
      {:ok, %Prima.Provider.Stream{shape: %{} = shape}} ->
        {:ok, [Prima.Canvas.Shape.fixture(shape)]}

      _shapeless ->
        {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Delivery under the grant
  # ---------------------------------------------------------------------------

  # A payload is delivered only under a context that still stands and to
  # a frame that keeps up.
  defp deliver(sub, message, data, state) do
    {frames, state} = fresh(state)

    case Map.get(state.subs, sub) do
      nil ->
        push(frames, idle_if_empty(state))

      entry ->
        {data, entry} = revisioned(entry, data)
        state = %{state | subs: Map.put(state.subs, sub, entry)}
        push(frames ++ [event(sub, entry, data, sequence(message))], state)
    end
  end

  defp event(sub, entry, data, id \\ nil),
    do: text(TinctureWire.event(sub, entry.stream, entry.subject, id, data))

  defp overflowing? do
    {:message_queue_len, depth} = Process.info(self(), :message_queue_len)
    depth > @max_backlog
  end

  defp fresh(%{caller: %{ctx: ctx}} = state) do
    if Sanctum.Caller.fresh?(ctx), do: {[], state}, else: revalidate(state)
  end

  # The frame established again, held to its credential's row under the
  # newest bearer it sent, with its version and grant: a refusal ends every
  # subscription, a flow that no longer covers a stream ends that one, and
  # each grant's deadline follows the row's.
  defp revalidate(%{caller: caller} = state) do
    case FrameAdmission.frame(caller.bearer, state.client_ip, path: state.path, held: true) do
      {:ok, held} ->
        state = %{state | caller: held}

        Enum.reduce(state.subs, {[], state}, fn {sub, entry}, {frames, state} ->
          case FrameAdmission.flowing({:stream, entry.stream}, held) do
            :ok ->
              {frames, extend(state, sub, entry, held.ctx)}

            {:error, refusal} ->
              {frames ++ [text(TinctureWire.ended(sub, refusal))], drop(state, sub)}
          end
        end)

      {:error, refusal} ->
        frames = for {sub, _entry} <- state.subs, do: text(TinctureWire.ended(sub, refusal))
        {frames, Enum.reduce(Map.keys(state.subs), state, &drop(&2, &1))}
    end
  end

  # A grant's deadline moves with its frame credential's row, never past
  # the stream's own bound from its open, and its timer is armed again for
  # the later one.
  defp extend(state, sub, %{grant: grant} = entry, %Context{credential_deadline: %DateTime{} = c}) do
    next = Enum.min([grant.bound, c], DateTime)

    if DateTime.compare(next, grant.deadline) == :gt,
      do: arm_deadline(state, sub, %{entry | grant: %{grant | deadline: next}}),
      else: state
  end

  defp extend(state, _sub, _entry, %Context{}), do: state

  # At a grant's deadline before its own bound from the open, the row is
  # read again whatever the context's freshness: a renewal moved the
  # deadline, and the timer is armed again for it. At the bound, the
  # subscription ends.
  defp at_deadline(sub, %{grant: %StreamGrant{bound: bound}}, state) do
    if DateTime.compare(DateTime.utc_now(), bound) == :lt do
      {frames, state} = revalidate(state)

      case Map.get(state.subs, sub) do
        %{grant: %StreamGrant{deadline: deadline}} ->
          if DateTime.compare(deadline, DateTime.utc_now()) == :gt,
            do: push(frames, state),
            else: ended(frames, sub, state)

        nil ->
          push(frames, idle_if_empty(state))
      end
    else
      ended([], sub, state)
    end
  end

  defp ended(frames, sub, state),
    do:
      push(frames ++ [text(TinctureWire.ended(sub, nil))], state |> drop(sub) |> idle_if_empty())

  # A connection that fell too far behind lets go of every fact it has
  # not delivered: a canvas-readable stream is handed a fresh picture in
  # their place, and any other ends with the overflow, since nothing could
  # say what it missed.
  defp fell_behind(state) do
    :ok = flush_facts()

    {frames, state} =
      Enum.reduce(state.subs, {[], state}, fn
        {sub, %{delivery: nil}}, {frames, state} ->
          {frames ++ [text(TinctureWire.ended(sub, overflow()))], drop(state, sub)}

        {sub, %{read: %{}} = entry}, {frames, state} ->
          entry = %{entry | held: [], again: true}
          {frames, %{state | subs: Map.put(state.subs, sub, entry)}}

        {sub, _entry}, {frames, state} ->
          {frames, settle_reread(state, sub, :needed, 0)}
      end)

    push(frames, idle_if_empty(state))
  end

  defp flush_facts do
    receive do
      {__MODULE__, :fact, _sub, _message} -> flush_facts()
    after
      0 -> :ok
    end
  end

  # Which standing announcements are about this frame: each holder filters
  # for its own, and anything else is ignored.
  defp about?(%Session{kind: kind, user_id: user_id}, ctx),
    do: kind != :created and user_id == ctx.user_id

  defp about?(%AthanorArchived{athanor_id: athanor_id}, ctx), do: athanor_id == ctx.athanor_id
  defp about?(%CallerInvalidated{}, _ctx), do: true

  defp about?(%FrameCredential{id: id}, %Context{frame: %{id: frame_credential}}),
    do: id == frame_credential

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

  # ---------------------------------------------------------------------------
  # The subscriptions and their timers
  # ---------------------------------------------------------------------------

  defp put_sub(state, sub, entry) do
    state = %{state | subs: Map.put(state.subs, sub, entry)}
    state |> arm_deadline(sub, entry) |> cancel_idle() |> start_ticking()
  end

  # A subscription ends at once: its forwarder stops and its timer goes,
  # and its place is free.
  defp drop(state, sub) do
    case Map.pop(state.subs, sub) do
      {nil, _subs} ->
        state

      {entry, subs} ->
        cancel(entry.timer)
        cancel_reread(entry)
        cancel(Map.get(entry, :stale_timer))
        stop_read(entry)
        StreamForwarder.stop(entry.forwarder)
        %{state | subs: subs}
    end
  end

  # ---------------------------------------------------------------------------
  # A canvas-readable stream's picture
  # ---------------------------------------------------------------------------

  # A picture was handed: it is read again at half the stream's bound, so
  # a read that answers lands before the bound, and is told stale at the
  # bound unless a fresh picture came first, whatever its read does.
  defp pictured(state, sub, began) do
    case Map.get(state.subs, sub) do
      %{delivery: %{stale_after: seconds}} = entry ->
        cancel(entry.stale_timer)
        token = make_ref()
        timer = Process.send_after(self(), {__MODULE__, :stale, sub, token}, seconds * 1_000)
        entry = %{entry | picture: began, stale: false, stale_timer: {token, timer}}
        state = %{state | subs: Map.put(state.subs, sub, entry)}
        settle_reread(state, sub, :periodic, div(seconds * 1_000, 2))

      _no_picture ->
        state
    end
  end

  # The picture is older than its bound and no fresh one came: told once.
  defp stale(sub, %{stale: true}, state), do: {:ok, clear_stale_timer(state, sub)}

  defp stale(sub, entry, state) do
    entry = %{entry | stale: true, stale_timer: nil}

    push([text(TinctureWire.stale(sub, entry.picture))], %{
      state
      | subs: Map.put(state.subs, sub, entry)
    })
  end

  defp clear_stale_timer(state, sub),
    do: %{state | subs: Map.update!(state.subs, sub, &%{&1 | stale_timer: nil})}

  defp retry_ms(%{delivery: %{stale_after: seconds}}),
    do: min(div(seconds * 1_000, 2), @stale_retry_ms)

  defp rereads?(%{delivery: %{reread: kinds}}, %{"kind" => kind}) when not is_nil(kind),
    do: to_string(kind) in kinds

  defp rereads?(_entry, _data), do: false

  # A change that says only that the picture moved: the picture is read
  # again once the burst it came in settles, ahead of any later read; one
  # that comes while a read runs is read again after it.
  defp settle_reread(state, sub) do
    case Map.get(state.subs, sub) do
      %{read: %{}} = entry -> %{state | subs: Map.put(state.subs, sub, %{entry | again: true})}
      %{reread: {_token, _timer, :needed}} -> state
      %{} -> settle_reread(state, sub, :needed, @reread_settle_ms)
      nil -> state
    end
  end

  # The next read of the picture, `why` it is read: `:needed` when the
  # frame holds a hole, `:periodic` before the stream's bound, `:retry`
  # after that read failed. One replaces whichever was due.
  defp settle_reread(state, sub, why, ms) do
    case Map.get(state.subs, sub) do
      nil ->
        state

      entry ->
        cancel_reread(entry)
        token = make_ref()
        timer = Process.send_after(self(), {__MODULE__, :reread, sub, token}, ms)
        %{state | subs: Map.put(state.subs, sub, %{entry | reread: {token, timer, why}})}
    end
  end

  defp cancel_reread(%{reread: {_token, timer, _why}}), do: Process.cancel_timer(timer)
  defp cancel_reread(_entry), do: false

  # A read that runs when its subscription ends goes with it.
  defp stop_read(%{read: %{ref: ref, pid: pid}}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp stop_read(_entry), do: false

  # The picture read again under the frame's context established again
  # first, as an open is, handed as a resync once the read answers. One
  # that comes while a read runs waits for it, and a hole the frame holds
  # is read again after it.
  defp reread(sub, why, state) do
    case Map.get(state.subs, sub) do
      %{read: %{}} = entry when why == :needed ->
        {:ok, %{state | subs: Map.put(state.subs, sub, %{entry | again: true})}}

      %{read: %{}} ->
        {:ok, state}

      %{} ->
        {frames, state} = revalidate(state)

        case Map.get(state.subs, sub) do
          nil ->
            push(frames, idle_if_empty(state))

          _held ->
            {more, state} = start_read(state, sub, why)
            push(frames ++ more, state)
        end

      nil ->
        {:ok, state}
    end
  end

  defp arm_deadline(state, sub, entry) do
    cancel(entry.timer)
    token = make_ref()
    remaining = max(DateTime.diff(entry.grant.deadline, DateTime.utc_now(), :millisecond), 0)
    timer = Process.send_after(self(), {__MODULE__, :deadline, sub, token}, remaining)
    %{state | subs: Map.put(state.subs, sub, %{entry | timer: {token, timer}})}
  end

  # A timer cancelled after it fired has queued its message, which its
  # token no longer matches.
  defp cancel({_token, timer}), do: Process.cancel_timer(timer)
  defp cancel(nil), do: false

  defp start_ticking(%{ticking: true} = state), do: state
  defp start_ticking(state), do: arm_tick(%{state | ticking: true})

  defp arm_tick(state) do
    Process.send_after(self(), {__MODULE__, :tick, state.ref}, @revalidate_every_ms)
    state
  end

  defp arm_keep_alive(state) do
    Process.send_after(self(), {__MODULE__, :ping, state.ref}, @keep_alive_ms)
    state
  end

  defp idle_if_empty(%{subs: subs, idle: nil} = state) when subs == %{} do
    token = make_ref()
    timer = Process.send_after(self(), {__MODULE__, :idle, token}, TinctureWire.idle_ms())
    %{state | idle: {token, timer}}
  end

  defp idle_if_empty(state), do: state

  defp cancel_idle(%{idle: nil} = state), do: state

  defp cancel_idle(%{idle: idle} = state) do
    cancel(idle)
    %{state | idle: nil}
  end

  defp push([], state), do: {:ok, state}
  defp push(frames, state), do: {:push, frames, state}

  defp text(message), do: {:text, Jason.encode!(message)}

  defp frame_connection_mismatch do
    %Prima.Refusal{
      class: :forbidden,
      reason: :frame_connection_mismatch,
      message: "This connection carries one frame's streams (frame_connection_mismatch)"
    }
  end
end
