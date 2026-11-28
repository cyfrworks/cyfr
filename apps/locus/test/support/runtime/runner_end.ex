# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.RunnerEnd do
  @moduledoc """
  A test's scripted runner end of a runner's relay (`Prima.RunnerRelay`),
  the peer a test of the service's end (`Locus.Runtime.Relay`) drives in
  this VM. The runner's own end is the runner program's
  (`apps/locus/runner`); this one plays only what those tests ask of a
  peer, over the real codec.

  It is joined to the service's end through `{:peer, pid}`, which it
  sends `{:relay_in, bytes}` for every frame it writes, and it reads every
  `{:relay_in, bytes}` it is sent. `bind/2` binds the channel to the
  attempt the test assigned, and `admit/2` adds a child CYFR admitted; a
  frame for any other attempt is refused as the codec refuses it.
  `call/6` sends a host call, signed and sealed by the test, and waits for
  the service's answer. `fetch/7` sends a pinned fetch, and its caller
  hears `{Locus.Runtime.Test.RunnerEnd, ref, event}`:
  `{:head, status, headers, body}` first, `{:chunk, body}` after, and
  `{:end, error}` last, `error` nil for an answer delivered whole. The
  service sends no more of a fetch's body than the caller granted with
  `credit/3`, past the first `Prima.RunnerRelay.initial_credit/0`. A frame
  the codec refuses, or the service's `close`, closes the channel: every
  call and fetch still open hears so, and none is sent again.

  `attached_fetch/4` sends a fetch naming a connection, and its caller
  hears the same events, each frame of CYFR's answer opened here under
  the attempt's seal key for the request's call id, in sequence
  (`Prima.WorkerAuth.read_frame/2`): a `head` is `{:head, status, headers,
  ""}`, a `chunk` `{:chunk, body}`, the `end` `{:end, nil}` and an
  `error` `{:end, {:guest_error, type, message}}`. CYFR's refusal, relayed
  as the service received it, reads as `{:end, {:guest_error, type,
  message}}` when its header verifies under the attempt's call key, its
  answer opens as that call's and it names the fetch's call id, and as
  `{:end, "lost"}` for CYFR's `lost`. A frame or refusal that does not
  read ends the fetch `{:end, "bad_frame"}`, and an answer the service
  ends before its `end` or `error` ends with the service's code, or
  `"truncated"`. Once a fetch has ended here, every byte the service still
  sends of it is granted back as it arrives, so the service is never left
  waiting on it.
  """

  use GenServer

  alias Prima.{AttachedRequest, RunnerRelay, WorkerAuth, WorkerWire}

  # How much longer than a call's own timeout a caller waits for the
  # service's answer, which the service bounds by that timeout.
  @answer_grace_ms 5_000

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc "Start the runner's end joined to the peer `relay: {:peer, pid}`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Bind the channel to the attempt the test assigned the runner."
  @spec bind(GenServer.server(), String.t()) :: :ok
  def bind(endpoint, attempt) when is_binary(attempt),
    do: GenServer.call(endpoint, {:bind, attempt})

  @doc "Carry the child `attempt` of the assigned subtree too."
  @spec admit(GenServer.server(), String.t()) :: :ok
  def admit(endpoint, attempt) when is_binary(attempt),
    do: GenServer.call(endpoint, {:admit, attempt})

  @doc "Whether nothing is open on the channel: no call unanswered and no fetch unended."
  @spec idle?(GenServer.server()) :: boolean()
  def idle?(endpoint), do: GenServer.call(endpoint, :idle?)

  @doc """
  Send a host call of `op` for `attempt`, its signed `header` and sealed
  `body`, and wait for the service's answer: `{:ok, status, body}`, the
  status nil when no answer reached the service, or `{:error, reason}`.
  """
  @spec call(GenServer.server(), String.t(), atom(), String.t(), binary(), pos_integer()) ::
          {:ok, 100..599 | nil, binary()} | {:error, term()}
  def call(endpoint, attempt, op, header, body, timeout_ms) do
    GenServer.call(endpoint, {:call, attempt, op, header, body}, timeout_ms + @answer_grace_ms)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  @doc """
  Send a fetch for `attempt` through the pin `pin` (its id) of `method`,
  `path` (path and query), `headers` and `body`. The caller hears its
  events; answers the fetch's ref, or `{:error, reason}` for a request
  the relay cannot carry.
  """
  @spec fetch(
          GenServer.server(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          binary()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def fetch(endpoint, attempt, pin, method, path, headers, body),
    do: GenServer.call(endpoint, {:fetch, attempt, pin, method, path, headers, body})

  @doc """
  Send, for `attempt`, a guest's request naming a connection (`request`),
  each frame of its answer opened under `keys`: the attempt's call key
  (`:call`), which a refusal's header verifies under, and its seal key
  (`:seal`). Answers the fetch's ref, or `{:error, reason}`.
  """
  @spec attached_fetch(GenServer.server(), String.t(), AttachedRequest.t(), %{
          call: binary(),
          seal: binary()
        }) :: {:ok, non_neg_integer()} | {:error, term()}
  def attached_fetch(endpoint, attempt, %AttachedRequest{} = request, %{call: call, seal: seal})
      when is_binary(call) and is_binary(seal),
      do: GenServer.call(endpoint, {:attached_fetch, attempt, request, %{call: call, seal: seal}})

  @doc "Grant fetch `ref` `bytes` more of its answer body."
  @spec credit(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def credit(_endpoint, _ref, 0), do: :ok

  def credit(endpoint, ref, bytes) when is_integer(bytes) and bytes > 0,
    do: GenServer.cast(endpoint, {:credit, ref, bytes})

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:peer, peer} = Keyword.fetch!(opts, :relay)

    {:ok,
     %{peer: peer, channel: nil, root: nil, buffer: "", calls: %{}, fetches: %{}, closed: nil}}
  end

  @impl true
  def handle_call({:bind, attempt}, _from, %{channel: nil} = state),
    do: {:reply, :ok, %{state | channel: RunnerRelay.new(:runner, attempt), root: attempt}}

  def handle_call({:admit, attempt}, _from, state),
    do: {:reply, :ok, %{state | channel: RunnerRelay.admit(state.channel, attempt)}}

  def handle_call(:idle?, _from, state),
    do: {:reply, state.calls == %{} and state.fetches == %{}, state}

  def handle_call(_request, _from, %{closed: closed} = state) when closed != nil,
    do: {:reply, {:error, :closed}, state}

  def handle_call({:call, attempt, op, header, body}, from, state) do
    frame = %{kind: :host_call, attempt: attempt, op: op, header: header, body: body}

    case encode(state, frame) do
      {:ok, seq, state} -> {:noreply, %{state | calls: Map.put(state.calls, seq, from)}}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, attempt, pin, method, path, headers, body}, {owner, _tag}, state) do
    frame = %{
      kind: :fetch,
      attempt: attempt,
      pin: pin,
      method: method,
      path: path,
      headers: headers,
      body: body
    }

    opened(state, frame, %{owner: owner, draining: false, received: 0, granted: 0})
  end

  def handle_call({:attached_fetch, attempt, request, keys}, {owner, _tag}, state) do
    frame = %{
      kind: :fetch,
      attempt: attempt,
      call_id: request.call_id,
      connection: request.connection,
      purpose: Atom.to_string(request.purpose),
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body
    }

    opened(state, frame, %{
      owner: owner,
      draining: false,
      received: 0,
      granted: 0,
      attempt: attempt,
      call_id: request.call_id,
      keys: keys,
      reader: WorkerAuth.frame_reader(keys.seal, request.call_id)
    })
  end

  @impl true
  def handle_cast({:credit, ref, bytes}, state), do: {:noreply, grant(state, ref, bytes)}

  @impl true
  def handle_info({:relay_in, data}, state), do: {:noreply, inbound(state, data)}

  defp opened(state, frame, fetch) do
    case encode(state, frame) do
      {:ok, seq, state} ->
        {:reply, {:ok, seq}, %{state | fetches: Map.put(state.fetches, seq, fetch)}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  # ————— what the service sends —————

  defp inbound(%{closed: closed} = state, _data) when closed != nil, do: state

  defp inbound(state, data) do
    case RunnerRelay.decode(state.channel, state.buffer <> data) do
      {:ok, frames, rest, channel} ->
        Enum.reduce(frames, %{state | channel: channel, buffer: rest}, &on_frame/2)

      {:error, reason} ->
        state
        |> send_close(reason)
        |> closed(reason)
    end
  end

  defp on_frame(_frame, %{closed: closed} = state) when closed != nil, do: state

  defp on_frame(%{kind: :host_answer, re: re, status: status, body: body}, state) do
    {from, calls} = Map.pop(state.calls, re)
    if from, do: GenServer.reply(from, {:ok, status, body})
    %{state | calls: calls}
  end

  defp on_frame(%{kind: :fetch_chunk, re: re} = frame, state) do
    case state.fetches[re] do
      %{draining: true} = fetch ->
        state
        |> put_fetch(re, %{fetch | received: fetch.received + byte_size(frame.body)})
        |> grant(re, byte_size(frame.body), true)

      %{owner: owner} = fetch ->
        event =
          if frame.status,
            do: {:head, frame.status, frame.headers, frame.body},
            else: {:chunk, frame.body}

        send(owner, {__MODULE__, re, event})
        put_fetch(state, re, %{fetch | received: fetch.received + byte_size(frame.body)})

      nil ->
        state
    end
  end

  defp on_frame(%{kind: :fetch_end, re: re, error: error}, state) do
    case Map.pop(state.fetches, re) do
      {nil, _fetches} ->
        state

      {fetch, fetches} ->
        unless fetch.draining,
          do: send(fetch.owner, {__MODULE__, re, {:end, ended(fetch, error)}})

        %{state | fetches: fetches}
    end
  end

  defp on_frame(%{kind: :attached_frame, re: re, frame: bytes}, state) do
    case state.fetches[re] do
      %{draining: true} = fetch ->
        state
        |> put_fetch(re, %{fetch | received: fetch.received + byte_size(bytes)})
        |> grant(re, byte_size(bytes), true)

      %{reader: reader} = fetch ->
        fetch = %{fetch | received: fetch.received + byte_size(bytes)}

        case WorkerAuth.read_frame(reader, bytes) do
          {:ok, read, reader} -> hand_on(state, re, %{fetch | reader: reader}, read, bytes)
          {:error, _refusal} -> last(state, re, fetch, {:end, "bad_frame"})
        end

      _gone ->
        state
    end
  end

  defp on_frame(%{kind: :attached_refusal, re: re, header: header, body: body}, state) do
    case state.fetches[re] do
      %{draining: false, keys: keys} = fetch ->
        last(state, re, fetch, {:end, refusal(fetch, keys, header, body)})

      _drained_or_gone ->
        state
    end
  end

  defp on_frame(%{kind: :close, reason: reason}, state), do: closed(state, {:service, reason})

  # ————— attached fetches —————

  # An attached fetch the service ended before its answer's `end` or
  # `error` ended short: what it carried is never a whole answer.
  defp ended(%{reader: %{state: reading}}, code) when reading != :done, do: code || "truncated"
  defp ended(_fetch, code), do: code

  # A frame read, handed on as a pinned fetch's events are. Every byte of
  # a head, and a chunk's framing, is granted back at once; the owner
  # grants a chunk's body as it reads it.
  defp hand_on(state, re, fetch, %{kind: :head, status: status, headers: headers}, bytes) do
    send(fetch.owner, {__MODULE__, re, {:head, status, headers, ""}})

    state
    |> put_fetch(re, fetch)
    |> grant(re, byte_size(bytes))
  end

  defp hand_on(state, re, fetch, %{kind: :chunk, body: body}, bytes) do
    send(fetch.owner, {__MODULE__, re, {:chunk, body}})

    state
    |> put_fetch(re, fetch)
    |> grant(re, byte_size(bytes) - byte_size(body))
  end

  defp hand_on(state, re, fetch, %{kind: :end}, _bytes),
    do: last(state, re, fetch, {:end, nil})

  defp hand_on(state, re, fetch, %{kind: :error, type: type, message: message}, _bytes),
    do: last(state, re, fetch, {:end, {:guest_error, type, message}})

  # The fetch's last event: its owner hears it and nothing of the fetch
  # after it, and every byte it received, or receives until the service
  # ends it, is granted back unread.
  defp last(state, re, fetch, event) do
    send(fetch.owner, {__MODULE__, re, event})
    fetch = fetch |> Map.drop([:keys, :reader]) |> Map.put(:draining, true)

    state
    |> put_fetch(re, fetch)
    |> grant(re, fetch.received - fetch.granted, true)
  end

  # CYFR's refusal of an attached request, taken only as the answer to the
  # call this fetch's attempt posted: its header verifies under the
  # attempt's call key and names the attempt, its answer opens as that
  # call's, and a guest error names the fetch's call id.
  defp refusal(fetch, keys, header, body) do
    now = System.system_time(:millisecond)

    with {:ok, fields, _body_hash} <-
           WorkerAuth.verify_host_call_header_under(keys.call, header, now),
         true <- fields.attempt == fetch.attempt,
         {:ok, json} <- WorkerAuth.open_call(keys.seal, :answer, fields, body),
         {:ok, decoded} <- Jason.decode(json) do
      refused(WorkerWire.read_answer(decoded), fetch.call_id)
    else
      _unread -> "bad_frame"
    end
  end

  defp refused(
         {:error, "guest_error", %{"type" => type, "message" => message, "call_id" => call_id}},
         call_id
       )
       when is_binary(type) and is_binary(message),
       do: {:guest_error, type, message}

  defp refused({:error, "lost", _fields}, _call_id), do: "lost"
  defp refused(_answer, _call_id), do: "bad_frame"

  # ————— credit —————

  # Credit is only ever granted back for bytes received, never ahead of
  # them: the service ends a fetch once every byte it sent was granted
  # back, so no grant can follow the end it waits for.
  defp grant(state, ref, bytes, draining \\ false)
  defp grant(state, _ref, 0, _draining), do: state

  defp grant(%{closed: nil} = state, ref, bytes, draining) do
    with %{draining: ^draining} = fetch <- state.fetches[ref],
         amount when amount > 0 <- min(bytes, fetch.received - fetch.granted),
         %{attempt: attempt} <- state.channel.fetches[ref],
         {:ok, _seq, granted} <-
           encode(state, %{kind: :credit, attempt: attempt, re: ref, bytes: amount}) do
      put_fetch(granted, ref, %{fetch | granted: fetch.granted + amount})
    else
      _not_granted -> state
    end
  end

  defp grant(state, _ref, _bytes, _draining), do: state

  defp put_fetch(state, ref, fetch), do: %{state | fetches: Map.put(state.fetches, ref, fetch)}

  # ————— writing —————

  defp encode(state, frame) do
    case RunnerRelay.encode(state.channel, frame) do
      {:ok, bytes, channel} ->
        seq = state.channel.sent
        send(state.peer, {:relay_in, IO.iodata_to_binary(bytes)})
        {:ok, seq, %{state | channel: channel}}

      {:error, reason} ->
        {:error, reason, state}
    end
  rescue
    ArgumentError -> {:error, :malformed, state}
  end

  defp send_close(%{root: nil} = state, _reason), do: state

  defp send_close(state, reason) do
    frame = %{kind: :close, attempt: state.root, reason: RunnerRelay.close_code(reason)}

    case RunnerRelay.encode(state.channel, frame) do
      {:ok, bytes, channel} ->
        send(state.peer, {:relay_in, IO.iodata_to_binary(bytes)})
        %{state | channel: channel}

      {:error, _reason} ->
        state
    end
  end

  # The channel is closed: every call still waiting and every fetch still
  # open hears so, and nothing is sent on it again.
  defp closed(%{closed: closed} = state, _reason) when closed != nil, do: state

  defp closed(state, reason) do
    for {_seq, from} <- state.calls, do: GenServer.reply(from, {:error, :closed})

    for {ref, fetch} <- state.fetches,
        not fetch.draining,
        do: send(fetch.owner, {__MODULE__, ref, {:end, "relay_closed"}})

    %{state | closed: reason, calls: %{}, fetches: %{}}
  end
end
