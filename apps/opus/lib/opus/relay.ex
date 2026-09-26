# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Relay do
  @moduledoc """
  The worker service's end of one runner's relay (`Prima.RunnerRelay`):
  the only path a runner, which has no network of its own, has to CYFR's
  host API and to the addresses CYFR pins for its guests. The runner's
  end is `Opus.Relay.Runner`.

  One process per runner, started by its handle (`Opus.RunnerProcess`)
  when the runner attaches, and linked to it: the handle forwards what the
  keeper carries on the relay stream and hears this process stop, which
  retires the runner. What it writes goes back through the keeper
  (`c:Opus.Keeper.send_relay/2`).

  ## The attempt it is bound to

  `bind/2` binds the channel to the attempt the runner is being assigned,
  from the assignment and the keys the service opened for it, before the
  `assign` is sent, so the runner's first frame finds it; a runner the
  service assigns again is bound again, and only once nothing of the last
  subtree is open on the channel. Each child CYFR admits for the runner is
  carried too, from the `admit_child` answer this process relays and opens
  (its keys open under the parent's seal key, as the runner opens them). A
  frame naming any other attempt closes the channel.

  ## Host calls

  The runner signs and seals each host call under the attempt's keys, as
  ever. Before it posts one, this process verifies its header under the
  attempt's call key it holds (`Prima.WorkerAuth.verify_host_call_header_under/3`)
  and refuses, with a `close`, a header that names another attempt, runner,
  boot or member than the ones it holds, a body the header does not name
  or that does not open as the frame's operation, an emitted event past
  the attempt's `max_request_size`, and any `take_rate`, which is the
  service's own call. It posts the call unchanged to the member the
  attempt's assignment names (`Opus.HostClient.post_call/4`) and answers
  it once, with CYFR's status and body, or with no status when no answer
  reached it. It reads the answers it relays under the attempt's seal key:
  an `egress_pin` answer is a pin granted to that attempt, and an
  `admit_child` answer a child to carry.

  ## Fetches

  A `fetch` names a pin by id and a path, never an address. The pin must
  be one CYFR granted to the frame's attempt in an answer this process
  relayed, else the channel closes. The request is checked again against
  the attempt's edge and limits as the runner checked it (`Opus.EdgeGuard`: method, scheme, the pin's host as
  a domain, the request's size), then taken from the consented rate by a
  `take_rate` call this process signs for the attempt. It then connects
  to the address CYFR answered, with the pin's host for TLS and `Host`
  (`Opus.Egress.connect_options/3`), and streams the answer back as
  `fetch_chunk` frames: the status and headers first, then the body,
  never past the credit the runner granted for the fetch and never past
  the attempt's `max_response_size`. A refused or failed fetch ends with a
  `fetch_end` naming why. A fetch ends only once the runner has granted
  back credit for every byte it was sent, so no credit frame crosses its
  end; the deadline ends it regardless. The upstream connection waits on the runner's
  credit, and neither outlives the attempt's deadline: at the deadline
  the fetch is ended `timeout` and its connection closed.

  The relay's own bounds: at most 64 calls and 16 fetches in flight per
  runner; a frame past `Prima.RunnerRelay`'s bounds, a sequence out of
  order or a chunk past credit closes the channel as the codec refuses it.

  Keys, headers, bodies and URLs are never logged, and no status or crash
  report shows more of them than their size.
  """

  use GenServer

  require Logger

  alias Prima.{Assignment, Authority, HostAPI, PinnedTarget, RunnerRelay, WorkerAuth, WorkerWire}
  alias Prima.Authority.Blob.Edge
  alias Opus.{EdgeGuard, Egress, HostClient, HttpRequestValidation}

  @attempt_fields [:athanor_id, :execution_id, :attempt, :fence, :generation, :service]
  @assignment_fields [:athanor_id, :execution_id, :attempt, :fence, :generation]

  @max_calls 64
  @max_fetches 16
  @max_pins 256
  # The most body bytes one `fetch_chunk` carries: a slice of the credit,
  # so no one chunk holds the channel's writer for long.
  @chunk_bytes 262_144
  @fetch_timeout_ms 30_000

  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete,
    "OPTIONS" => :options
  }

  @typedoc "What `bind/2` binds the channel to: the assignment token, the opened keys and the configured host address."
  @type binding :: %{
          assignment: Assignment.token(),
          keys: WorkerAuth.attempt_keys(),
          host_url: String.t()
        }

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc """
  Start the service's end of a runner's relay. Options: `:runner`, the
  runner's id every header must name; `:write`, how bytes reach the
  runner (`iodata -> :ok | {:error, term}`); `:close`, how the stream is
  ended once this process closes the channel (default: nothing).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Bind the channel to the attempt `binding` names, before its `assign` is
  sent. Answers `{:error, :malformed}` for an assignment the keys do not
  name, and `{:error, :busy}` while the last subtree's calls or fetches
  are still open.
  """
  @spec bind(pid(), binding()) :: :ok | {:error, :malformed | :busy}
  def bind(relay, %{assignment: token, keys: %{}, host_url: host_url} = binding)
      when is_binary(token) and is_binary(host_url),
      do: GenServer.call(relay, {:bind, binding})

  @doc "Hand the relay what the runner wrote on its end."
  @spec deliver(pid(), binary()) :: :ok
  def deliver(relay, data) when is_binary(data) do
    send(relay, {:relay_in, data})
    :ok
  end

  @doc "The runner's end of the stream has ended: the relay stops."
  @spec ended(pid()) :: :ok
  def ended(relay) do
    send(relay, :relay_ended)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       runner: Keyword.fetch!(opts, :runner),
       write: Keyword.fetch!(opts, :write),
       close: Keyword.get(opts, :close, fn -> :ok end),
       channel: nil,
       root: nil,
       buffer: "",
       attempts: %{},
       calls: %{},
       fetches: %{},
       workers: %{}
     }}
  end

  @impl true
  def handle_call({:bind, binding}, _from, state) do
    with {:ok, assignment} <- Assignment.read(binding.assignment),
         host_url = HostClient.at(assignment, binding.host_url).host_url,
         {:ok, bound} <- bound(assignment, binding.keys, host_url),
         {:ok, channel} <- rebind(state, assignment.attempt) do
      {:reply, :ok,
       %{
         state
         | channel: channel,
           root: assignment.attempt,
           attempts: %{assignment.attempt => bound}
       }}
    else
      {:error, :busy} -> {:reply, {:error, :busy}, state}
      _unreadable -> {:reply, {:error, :malformed}, state}
    end
  end

  @impl true
  def handle_info({:relay_in, _data}, %{channel: nil} = state) do
    # Nothing is assigned: a runner that speaks first is not one the
    # service is running.
    Logger.warning("[Opus.Relay] runner #{state.runner} wrote before its assignment")
    {:stop, {:shutdown, {:closed, :unbound}}, state}
  end

  def handle_info({:relay_in, data}, state) do
    case RunnerRelay.decode(state.channel, state.buffer <> data) do
      {:ok, frames, rest, channel} ->
        frames
        |> Enum.reduce_while({:ok, %{state | channel: channel, buffer: rest}}, fn frame,
                                                                                  {:ok, state} ->
          case on_frame(state, frame) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:stop, _reason, _state} = stop -> {:halt, stop}
          end
        end)
        |> case do
          {:ok, state} -> {:noreply, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end

      {:error, reason} ->
        close(state, reason)
    end
  end

  def handle_info(:relay_ended, state), do: {:stop, {:shutdown, :relay_ended}, state}

  def handle_info({:posted, pid, result}, state) do
    case Map.pop(state.calls, pid) do
      {nil, _calls} -> {:noreply, state}
      {call, calls} -> answer(%{state | calls: calls}, call, result)
    end
  end

  def handle_info({:fetch_head, re, status, headers}, state),
    do: with_fetch(state, re, &head(&1, re, &2, status, headers))

  def handle_info({:fetch_data, re, data}, state),
    do:
      with_fetch(state, re, fn state, fetch ->
        pump(state, re, %{fetch | pending: data, acking: true})
      end)

  def handle_info({:fetch_done, re, error}, state),
    do:
      with_fetch(state, re, fn state, fetch -> pump(state, re, %{fetch | done: {:end, error}}) end)

  def handle_info({:fetch_deadline, re}, state),
    do: with_fetch(state, re, fn state, fetch -> finish(state, re, fetch, "timeout") end)

  # A call's poster ended without answering: the answer was lost.
  def handle_info({:EXIT, pid, reason}, state) when is_map_key(state.calls, pid) do
    {call, calls} = Map.pop(state.calls, pid)

    if reason != :normal,
      do: answer(%{state | calls: calls}, call, :error),
      else: {:noreply, %{state | calls: calls}}
  end

  def handle_info({:EXIT, pid, reason}, state) when is_map_key(state.workers, pid) do
    {re, workers} = Map.pop(state.workers, pid)
    state = %{state | workers: workers}

    case {reason, state.fetches[re]} do
      {:normal, _fetch} -> {:noreply, state}
      {_reason, nil} -> {:noreply, state}
      {_reason, fetch} -> finish(state, re, fetch, "fetch_failed")
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # The attempts' keys, the frames held and the bodies in flight are no
  # status's or crash report's: only their sizes are shown.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{} = state} ->
        {:state,
         %{
           state
           | buffer: {:redacted, byte_size(state.buffer)},
             attempts: Map.new(state.attempts, fn {id, _bound} -> {id, :redacted} end),
             fetches:
               Map.new(state.fetches, fn {re, fetch} -> {re, Map.delete(fetch, :pending)} end)
         }}

      {:message, {:relay_in, data}} ->
        {:message, {:relay_in, {:redacted, byte_size(data)}}}

      {:message, {:bind, _binding}} ->
        {:message, {:bind, :redacted}}

      {:message, {:posted, pid, _result}} ->
        {:message, {:posted, pid, :redacted}}

      {:message, {:fetch_data, re, data}} ->
        {:message, {:fetch_data, re, {:redacted, byte_size(data)}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  # ---------------------------------------------------------------------------
  # Binding
  # ---------------------------------------------------------------------------

  # What the relay holds for one attempt: its identity, its keys, where
  # its calls go and what bounds its fetches, read from its assignment.
  defp bound(%Assignment{} = assignment, %{attempt: attempt, call: call, seal: seal}, host_url) do
    with true <- Map.take(assignment, @assignment_fields) == Map.take(attempt, @assignment_fields),
         true <- assignment.service == attempt.service,
         {:ok, authority} <- Authority.from_wire(assignment.authority) do
      {:ok,
       %{
         attempt: Map.take(attempt, @attempt_fields),
         call_key: call,
         seal_key: seal,
         boot: assignment.boot,
         member: assignment.member,
         host_url: host_url,
         edge: edge(authority),
         limits: Authority.limits(authority),
         component_ref: assignment.component.ref,
         deadline: assignment.deadline,
         pins: %{}
       }}
    else
      _ -> :error
    end
  end

  defp bound(_assignment, _keys, _host_url), do: :error

  defp edge(%Authority{resources: %Edge{} = edge}), do: edge
  defp edge(%Authority{resources: :none}), do: nil

  # A new channel for the first assignment; for a runner assigned again,
  # the same channel's sequence numbers carried to the new attempt, once
  # nothing of the last subtree is open on it.
  defp rebind(%{channel: nil}, attempt), do: {:ok, RunnerRelay.new(:service, attempt)}

  defp rebind(%{channel: channel} = state, attempt) do
    if channel.calls == %{} and channel.fetches == %{} and state.calls == %{} and
         state.fetches == %{} do
      {:ok,
       %{RunnerRelay.new(:service, attempt) | sent: channel.sent, received: channel.received}}
    else
      {:error, :busy}
    end
  end

  # ---------------------------------------------------------------------------
  # The runner's frames
  # ---------------------------------------------------------------------------

  defp on_frame(state, %{kind: :host_call} = frame), do: host_call(state, frame)
  defp on_frame(state, %{kind: :fetch} = frame), do: fetch(state, frame)

  defp on_frame(state, %{kind: :credit, re: re}),
    do: with_fetch(state, re, &pump(&1, re, &2)) |> as_step()

  defp on_frame(state, %{kind: :close, reason: reason}) do
    Logger.warning("[Opus.Relay] runner #{state.runner} closed its relay: #{reason}")
    {:stop, {:shutdown, {:runner_closed, reason}}, state}
  end

  defp as_step({:noreply, state}), do: {:ok, state}
  defp as_step({:stop, _reason, _state} = stop), do: stop

  # ————— host calls —————

  defp host_call(state, %{op: :take_rate}), do: close(state, :take_rate) |> as_step()

  defp host_call(state, _frame) when map_size(state.calls) >= @max_calls,
    do: close(state, :too_many_calls) |> as_step()

  defp host_call(state, frame) do
    bound = Map.fetch!(state.attempts, frame.attempt)

    with {:ok, fields} <- verified(state, bound, frame),
         :ok <- checked_body(bound, fields, frame) do
      relay = self()
      {op, header, body, host_url} = {frame.op, frame.header, frame.body, bound.host_url}

      pid =
        spawn_link(fn ->
          send(relay, {:posted, self(), HostClient.post_call(host_url, op, header, body)})
        end)

      call = %{re: frame.seq, attempt: frame.attempt, op: op, fields: fields}
      {:ok, %{state | calls: Map.put(state.calls, pid, call)}}
    else
      {:refuse, reason} -> close(state, reason) |> as_step()
    end
  end

  # The header must verify under the attempt's call key and name exactly
  # what the relay holds: the frame's attempt, this runner, the service's
  # boot and the member the assignment names; the body must be the one it
  # names.
  defp verified(state, bound, frame) do
    now = System.system_time(:millisecond)

    case WorkerAuth.verify_host_call_header_under(bound.call_key, frame.header, now) do
      {:ok, fields, body_hash} ->
        cond do
          Map.take(fields, @attempt_fields) != bound.attempt -> {:refuse, :attempt_mismatch}
          fields.runner != state.runner -> {:refuse, :runner_mismatch}
          fields.boot != bound.boot -> {:refuse, :boot_mismatch}
          fields.member != bound.member -> {:refuse, :member_mismatch}
          WorkerAuth.verify_body(body_hash, frame.body) != :ok -> {:refuse, :bad_mac}
          true -> {:ok, fields}
        end

      {:error, reason} ->
        {:refuse, reason}
    end
  end

  # The body opens as the frame's operation at this wire's version, and an
  # emitted event is within the attempt's `max_request_size`.
  defp checked_body(bound, fields, frame) do
    with {:ok, json} <- WorkerAuth.open_call(bound.seal_key, :body, fields, frame.body),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, op, args} when op == frame.op <- WorkerWire.read_request_body(HostAPI, decoded) do
      events_within(bound, op, args)
    else
      _ -> {:refuse, :malformed_call}
    end
  end

  defp events_within(bound, :push_deltas, %{"deltas" => deltas}) when is_list(deltas) do
    oversized =
      Enum.any?(deltas, fn
        %{"event" => event} when is_binary(event) ->
          EdgeGuard.check_event_size(bound.limits, event) != :ok

        _other ->
          false
      end)

    if oversized, do: {:refuse, :request_too_large}, else: :ok
  end

  defp events_within(_bound, _op, _args), do: :ok

  defp answer(state, call, result) do
    {status, body} =
      case result do
        {:ok, status, body} -> {status, body}
        :error -> {nil, ""}
      end

    state = if status == 200, do: learn(state, call, body), else: state

    frame = %{
      kind: :host_answer,
      attempt: call.attempt,
      re: call.re,
      status: status,
      body: body
    }

    send_frame(state, frame)
  end

  # What an answer the relay passes on grants the attempt: a pin, or a
  # child the runner will run under keys sealed to this attempt.
  defp learn(state, %{op: :egress_pin} = call, sealed) do
    bound = Map.fetch!(state.attempts, call.attempt)

    with {:ok, wire} <- opened_answer(bound, call, sealed),
         {:ok, pin} <- PinnedTarget.read(wire) do
      put_bound(state, call.attempt, %{bound | pins: remember_pin(bound.pins, pin)})
    else
      _ -> state
    end
  end

  defp learn(state, %{op: :admit_child} = call, sealed) do
    parent = Map.fetch!(state.attempts, call.attempt)

    with {:ok, %{"assignment" => token, "attempt_keys" => sealed_keys}} <-
           opened_answer(parent, call, sealed),
         {:ok, assignment} <- Assignment.read(token),
         {:ok, keys} <- WorkerAuth.open_attempt_keys(parent.seal_key, sealed_keys),
         true <- child_of?(assignment, keys.attempt, parent),
         {:ok, child} <- bound(assignment, keys, parent.host_url) do
      %{
        state
        | attempts: Map.put(state.attempts, assignment.attempt, child),
          channel: RunnerRelay.admit(state.channel, assignment.attempt)
      }
    else
      _ -> state
    end
  end

  defp learn(state, _call, _sealed), do: state

  defp opened_answer(bound, call, sealed) do
    with {:ok, json} <- WorkerAuth.open_call(bound.seal_key, :answer, call.fields, sealed),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, value} <- WorkerWire.read_answer(decoded) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # A child is its parent's: on this service and boot, issued by the same
  # member and posted to the same address.
  defp child_of?(assignment, attempt, parent) do
    Map.take(assignment, @assignment_fields) == Map.take(attempt, @assignment_fields) and
      assignment.service == parent.attempt.service and attempt.service == parent.attempt.service and
      assignment.boot == parent.boot and assignment.member == parent.member and
      (assignment.host_url == nil or assignment.host_url == parent.host_url)
  end

  # A pin stays the attempt's for the attempt's life, as the runner's
  # handlers use it: a stream opened with a pin keeps its connection past
  # the pin's expiry, and whether to ask CYFR again is the runner's. Only
  # the oldest is forgotten, past the relay's bound on pins.
  defp remember_pin(pins, pin) do
    kept =
      if map_size(pins) >= @max_pins,
        do: pins |> Enum.sort_by(fn {_id, pin} -> pin.expires_at end) |> tl() |> Map.new(),
        else: pins

    Map.put(kept, pin.id, pin)
  end

  defp put_bound(state, attempt, bound),
    do: %{state | attempts: Map.put(state.attempts, attempt, bound)}

  # ————— fetches —————

  defp fetch(state, _frame) when map_size(state.fetches) >= @max_fetches,
    do: close(state, :too_many_fetches) |> as_step()

  defp fetch(state, frame) do
    bound = Map.fetch!(state.attempts, frame.attempt)

    case Map.fetch(bound.pins, frame.pin) do
      {:ok, pin} ->
        fetch = %{
          attempt: frame.attempt,
          worker: nil,
          pending: "",
          acking: false,
          done: nil,
          timer: nil
        }

        state = %{state | fetches: Map.put(state.fetches, frame.seq, fetch)}

        case admitted(bound, pin, frame) do
          {:ok, request} -> {:ok, start_fetch(state, frame.seq, bound, request)}
          {:refuse, code} -> finish(state, frame.seq, fetch, code) |> as_step()
        end

      :error ->
        close(state, :unknown_pin) |> as_step()
    end
  end

  # The checks the runner made, made again outside it: the method, the
  # pin's scheme and host and the request's size are within the attempt's
  # edge and limits, before the attempt's deadline.
  defp admitted(bound, pin, frame) do
    now = System.system_time(:millisecond)
    %URI{path: path, query: query} = URI.parse(frame.path)

    uri = %URI{
      scheme: pin.scheme,
      host: unbracket(pin.host),
      port: pin.port,
      path: path,
      query: query
    }

    url = URI.to_string(uri)
    request = %{url: url, headers: frame.headers, body: frame.body}

    cond do
      now >= bound.deadline ->
        {:refuse, "timeout"}

      EdgeGuard.check_method(bound.edge, frame.method) != :ok ->
        {:refuse, "method_blocked"}

      EdgeGuard.check_scheme(bound.edge, pin.scheme) != :ok ->
        {:refuse, "scheme_blocked"}

      EdgeGuard.check_domain(bound.edge, unbracket(pin.host)) != :ok ->
        {:refuse, "domain_blocked"}

      EdgeGuard.check_request_size(bound.limits, request) != :ok ->
        {:refuse, "request_too_large"}

      true ->
        {:ok, Map.merge(request, %{pin: pin, uri: uri, method: frame.method})}
    end
  end

  defp start_fetch(state, re, bound, request) do
    relay = self()
    client = rate_client(state, bound)

    worker =
      spawn_link(fn ->
        fetch_worker(relay, re, client, bound, request)
      end)

    timer = Process.send_after(self(), {:fetch_deadline, re}, max(bound.deadline - now(), 0))
    fetch = %{state.fetches[re] | worker: worker, timer: timer}

    %{
      state
      | fetches: Map.put(state.fetches, re, fetch),
        workers: Map.put(state.workers, worker, re)
    }
  end

  # The client the relay takes the rate with: the attempt's own keys,
  # presenting as the runner, posted to the member the assignment names.
  defp rate_client(state, bound) do
    HostClient.new(
      %{attempt: bound.attempt, call: bound.call_key, seal: bound.seal_key},
      state.runner,
      bound.boot,
      %{member: bound.member, host_url: bound.host_url}
    )
  end

  # The fetch itself, beside the relay: the rate, then the pinned connect,
  # whose answer body reaches the relay one piece at a time, each piece
  # waiting until the relay has sent it on under the runner's credit. The
  # wait is bounded by the attempt's deadline, and the relay kills this
  # process at the deadline, which closes the connection.
  defp fetch_worker(relay, re, client, bound, request) do
    case HostClient.take_rate(client, "http:" <> bound.component_ref) do
      :ok -> send(relay, {:fetch_done, re, connect(relay, re, bound, request)})
      {:error, _refused} -> send(relay, {:fetch_done, re, "rate_limited"})
    end
  end

  defp connect(relay, re, bound, request) do
    timeout = max(min(fetch_timeout(bound), bound.deadline - now()), 1)
    max_bytes = bound.limits.max_response_size

    with {:ok, pinned} <-
           Egress.connect_options(request.pin, request.uri,
             receive_timeout: timeout,
             protocols: [:http1]
           ) do
      Process.put({__MODULE__, :bytes}, 0)

      into = fn {:data, data}, {req, resp} ->
        head_once(relay, re, resp)
        bytes = Process.get({__MODULE__, :bytes}) + byte_size(data)
        Process.put({__MODULE__, :bytes}, bytes)

        cond do
          bytes > max_bytes ->
            Process.put({__MODULE__, :error}, "response_too_large")
            {:halt, {req, resp}}

          delivered?(relay, re, data, bound) ->
            {:cont, {req, resp}}

          true ->
            Process.put({__MODULE__, :error}, "timeout")
            {:halt, {req, resp}}
        end
      end

      opts =
        pinned.req_opts
        |> Keyword.put(:method, Map.fetch!(@methods, request.method))
        |> Keyword.put(:headers, request.headers)
        |> Keyword.put(:into, into)
        |> then(&if(request.body != "", do: Keyword.put(&1, :body, request.body), else: &1))

      case Req.request(opts) do
        {:ok, resp} ->
          head_once(relay, re, resp)
          Process.get({__MODULE__, :error})

        {:error, %Req.TransportError{reason: :timeout}} ->
          "timeout"

        {:error, %Req.TransportError{reason: reason}} when is_atom(reason) ->
          code(reason)

        {:error, _exception} ->
          "http_error"
      end
    else
      {:error, _type, _message} -> "private_ip_blocked"
    end
  end

  defp fetch_timeout(bound), do: HttpRequestValidation.timeout_ms(bound.limits, @fetch_timeout_ms)

  defp head_once(relay, re, resp) do
    unless Process.get({__MODULE__, :headed}) do
      Process.put({__MODULE__, :headed}, true)
      send(relay, {:fetch_head, re, resp.status, response_headers(resp.headers)})
    end
  end

  defp delivered?(relay, re, data, bound) do
    send(relay, {:fetch_data, re, data})

    receive do
      {:fetch_sent, ^re} -> true
    after
      max(bound.deadline - now(), 0) -> false
    end
  end

  # The answer's headers a frame can carry, in order: a name that is an
  # HTTP token and a value without control characters, each within the
  # relay's bounds. A header that is not is left out rather than sent.
  defp response_headers(headers) do
    headers
    |> Enum.flat_map(fn {name, values} -> Enum.map(List.wrap(values), &{name, &1}) end)
    |> Enum.filter(fn {name, value} ->
      is_binary(name) and byte_size(name) in 1..256 and
        Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) and is_binary(value) and
        byte_size(value) <= 8192 and String.valid?(value) and
        Regex.match?(~r/\A[^\x00-\x08\x0A-\x1F\x7F]*\z/u, value)
    end)
    |> Enum.take(128)
  end

  defp code(reason) do
    text = Atom.to_string(reason)
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, text), do: text, else: "http_error"
  end

  defp head(state, re, fetch, status, headers) do
    chunk = %{
      kind: :fetch_chunk,
      attempt: fetch.attempt,
      re: re,
      status: status,
      headers: headers,
      body: ""
    }

    case encode(state, chunk) do
      {:ok, state} ->
        {:noreply, state}

      # Headers the codec refuses whole are sent as none.
      {:error, :unencodable} ->
        case encode(state, %{chunk | headers: []}) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> stop_write(state, reason)
        end

      {:error, reason} ->
        stop_write(state, reason)
    end
  end

  # Send what the fetch holds as far as the runner's credit allows; the
  # worker hears its piece sent once all of it is, and the fetch ends once
  # nothing is held and the worker is done.
  defp pump(state, re, fetch) do
    credit = RunnerRelay.credit(state.channel, re) || 0

    cond do
      fetch.pending != "" and credit > 0 ->
        size = Enum.min([credit, @chunk_bytes, byte_size(fetch.pending)])
        <<piece::binary-size(^size), rest::binary>> = fetch.pending

        chunk = %{
          kind: :fetch_chunk,
          attempt: fetch.attempt,
          re: re,
          status: nil,
          headers: nil,
          body: piece
        }

        case encode(state, chunk) do
          {:ok, state} -> pump(state, re, %{fetch | pending: rest})
          {:error, reason} -> stop_write(state, reason)
        end

      fetch.pending != "" ->
        {:noreply, put_fetch(state, re, fetch)}

      # The fetch ends only once the runner has granted back every byte it
      # was sent: a runner grants credit for each chunk it reads, and a
      # grant crossing the end would name a fetch no longer open.
      match?({:end, _}, fetch.done) and credit >= RunnerRelay.initial_credit() ->
        {:end, error} = fetch.done
        finish(state, re, fetch, error)

      match?({:end, _}, fetch.done) ->
        {:noreply, put_fetch(state, re, fetch)}

      # The worker waits for its piece to be sent before it reads more,
      # so it is told once for each piece and never ahead of one.
      fetch.acking ->
        send(fetch.worker, {:fetch_sent, re})
        {:noreply, put_fetch(state, re, %{fetch | acking: false})}

      true ->
        {:noreply, put_fetch(state, re, fetch)}
    end
  end

  # The fetch ends: its worker is stopped (closing its connection), what
  # it held is dropped, and the runner hears why, or nil for an answer
  # delivered whole.
  defp finish(state, re, fetch, error) do
    if fetch.timer, do: Process.cancel_timer(fetch.timer)

    state =
      if fetch.worker && Map.has_key?(state.workers, fetch.worker) do
        Process.unlink(fetch.worker)
        Process.exit(fetch.worker, :kill)
        %{state | workers: Map.delete(state.workers, fetch.worker)}
      else
        state
      end

    state = %{state | fetches: Map.delete(state.fetches, re)}
    send_frame(state, %{kind: :fetch_end, attempt: fetch.attempt, re: re, error: error})
  end

  defp with_fetch(state, re, fun) do
    case Map.fetch(state.fetches, re) do
      {:ok, fetch} -> fun.(state, fetch)
      :error -> {:noreply, state}
    end
  end

  defp put_fetch(state, re, fetch), do: %{state | fetches: Map.put(state.fetches, re, fetch)}

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------

  defp send_frame(state, frame) do
    case encode(state, frame) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> stop_write(state, reason)
    end
  end

  defp encode(state, frame) do
    case RunnerRelay.encode(state.channel, frame) do
      {:ok, bytes, channel} ->
        case state.write.(bytes) do
          :ok -> {:ok, %{state | channel: channel}}
          {:error, reason} -> {:error, {:write, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :unencodable}
  end

  defp stop_write(state, reason) do
    Logger.warning("[Opus.Relay] runner #{state.runner}'s relay failed: #{inspect(reason)}")
    {:stop, {:shutdown, {:closed, :write_failed}}, state}
  end

  # The channel closes: the runner hears why, the stream ends, and this
  # process stops, which retires the runner.
  defp close(state, reason) do
    Logger.warning(
      "[Opus.Relay] runner #{state.runner}'s relay closed: #{RunnerRelay.close_code(reason)}"
    )

    if state.root do
      frame = %{kind: :close, attempt: state.root, reason: RunnerRelay.close_code(reason)}

      case RunnerRelay.encode(state.channel, frame) do
        {:ok, bytes, _channel} -> state.write.(bytes)
        {:error, _reason} -> :ok
      end
    end

    state.close.()
    {:stop, {:shutdown, {:closed, reason}}, state}
  end

  defp now, do: System.system_time(:millisecond)

  defp unbracket("[" <> rest), do: String.trim_trailing(rest, "]")
  defp unbracket(host), do: host
end

defmodule Opus.Relay.Runner do
  @moduledoc """
  The runner's end of its relay (`Prima.RunnerRelay`), the service's end
  being `Opus.Relay`: one process in the runner's VM, through which every
  host call the runner makes (`Opus.HostClient`) and every guest fetch
  (`Opus.HttpHandler`, `Opus.HttpStreamHandler`) leaves. The runner has no
  network: it resolves no name and connects nowhere.

  The relay is the runner's file descriptor 4, the socket the keeper gives
  every spawn of an isolated pool (`{:fd, fd}`), or, in the test build's
  direct keeper, a unix socket in the runner's home (`{:socket, path}`).

  `bind/2` binds the channel to the attempt the runner was assigned, and
  `admit/2` adds each child the runner starts; a frame for any other
  attempt is refused as the codec refuses it. `call/6` sends a host call
  and waits for its answer. `fetch/7` sends a fetch and its caller hears
  `{Opus.Relay.Runner, ref, event}`: `{:head, status, headers, body}`
  first, `{:chunk, body}` after, and `{:end, error}` last, `error` nil for
  an answer delivered whole. The service sends no more of a fetch's body
  than the caller granted with `credit/3`, past the first
  `Prima.RunnerRelay.initial_credit/0`. `cancel/2`, or the caller's end,
  lets the rest of a fetch drain unread. A frame the codec refuses, or the
  service's `close`, closes the channel: every call and fetch still open
  hears so, and none is sent again.
  """

  use GenServer

  require Logger

  alias Prima.RunnerRelay

  # How much longer than a call's own timeout a caller waits for the
  # service's answer, which the service bounds by that timeout.
  @answer_grace_ms 5_000

  @type event ::
          {:head, 100..599, [{String.t(), String.t()}], binary()}
          | {:chunk, binary()}
          | {:end, String.t() | nil}

  @doc false
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  @doc """
  Start the runner's end. Options: `:relay`, `{:fd, fd}`, `{:socket, path}`
  or, for a relay joined in this VM, `{:peer, pid}`, which is sent
  `{:relay_in, bytes}` and sends the same; `:name`.
  """
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Bind the channel to the attempt the runner was assigned; `{:error, :busy}` while the last subtree's work is open on it."
  @spec bind(GenServer.server(), String.t()) :: :ok | {:error, :busy}
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
  def fetch(endpoint, attempt, pin, method, path, headers, body) do
    GenServer.call(endpoint, {:fetch, attempt, pin, method, path, headers, body})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @doc "Grant fetch `ref` `bytes` more of its answer body."
  @spec credit(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def credit(_endpoint, _ref, 0), do: :ok

  def credit(endpoint, ref, bytes) when is_integer(bytes) and bytes > 0,
    do: GenServer.cast(endpoint, {:credit, ref, bytes})

  @doc "Stop reading fetch `ref`: what is left of it drains unread."
  @spec cancel(GenServer.server(), non_neg_integer()) :: :ok
  def cancel(endpoint, ref), do: GenServer.cast(endpoint, {:cancel, ref})

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # The relay's port is linked to this process: its end is heard as a
    # message, not an exit.
    Process.flag(:trap_exit, true)

    case open(Keyword.fetch!(opts, :relay)) do
      {:ok, transport} ->
        {:ok,
         %{
           transport: transport,
           channel: nil,
           root: nil,
           buffer: "",
           calls: %{},
           fetches: %{},
           closed: nil
         }}

      {:error, reason} ->
        {:stop, {:relay_unavailable, reason}}
    end
  end

  # The keeper's socket, the direct keeper's unix socket, or a peer in
  # this VM.
  defp open({:fd, fd}), do: {:ok, {:port, Opus.Release.open_relay(fd)}}

  defp open({:socket, path}) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :raw, active: true], 10_000) do
      {:ok, socket} -> {:ok, {:socket, socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open({:peer, pid}) when is_pid(pid) do
    Process.monitor(pid)
    {:ok, {:peer, pid}}
  end

  @impl true
  def handle_call({:bind, attempt}, _from, %{channel: nil} = state),
    do: {:reply, :ok, %{state | channel: RunnerRelay.new(:runner, attempt), root: attempt}}

  def handle_call({:bind, attempt}, _from, state) do
    if state.calls == %{} and state.fetches == %{} do
      channel = %{
        RunnerRelay.new(:runner, attempt)
        | sent: state.channel.sent,
          received: state.channel.received
      }

      {:reply, :ok, %{state | channel: channel, root: attempt}}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:admit, _attempt}, _from, %{channel: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:admit, attempt}, _from, state),
    do: {:reply, :ok, %{state | channel: RunnerRelay.admit(state.channel, attempt)}}

  def handle_call(:idle?, _from, state),
    do: {:reply, state.calls == %{} and state.fetches == %{}, state}

  def handle_call(_request, _from, %{closed: closed} = state) when closed != nil,
    do: {:reply, {:error, :closed}, state}

  def handle_call(_request, _from, %{channel: nil} = state),
    do: {:reply, {:error, :unbound}, state}

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

    case encode(state, frame) do
      {:ok, seq, state} ->
        fetch = %{
          owner: owner,
          monitor: Process.monitor(owner),
          draining: false,
          received: 0,
          granted: 0
        }

        {:reply, {:ok, seq}, %{state | fetches: Map.put(state.fetches, seq, fetch)}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:credit, ref, bytes}, state), do: {:noreply, grant(state, ref, bytes)}

  def handle_cast({:cancel, ref}, state), do: {:noreply, drain(state, ref)}

  @impl true
  def handle_info({port, {:data, data}}, %{transport: {:port, port}} = state),
    do: {:noreply, inbound(state, data)}

  def handle_info({:tcp, socket, data}, %{transport: {:socket, socket}} = state),
    do: {:noreply, inbound(state, data)}

  def handle_info({:relay_in, data}, %{transport: {:peer, _pid}} = state),
    do: {:noreply, inbound(state, data)}

  def handle_info({port, :eof}, %{transport: {:port, port}} = state),
    do: {:noreply, closed(state, :eof)}

  def handle_info({:tcp_closed, socket}, %{transport: {:socket, socket}} = state),
    do: {:noreply, closed(state, :eof)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{transport: {:peer, pid}} = state),
    do: {:noreply, closed(state, :eof)}

  # A fetch's reader is gone: the rest of it drains unread.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.fetches, fn {_ref, fetch} -> fetch.monitor == monitor end) do
      {ref, _fetch} -> {:noreply, drain(state, ref)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, closed(state, :eof)}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # A call's header and body, and a fetch's, are the attempt's: no status
  # or crash report shows more of them than their size.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{} = state} ->
        {:state, %{state | buffer: {:redacted, byte_size(state.buffer)}}}

      {:message, {:call, a, op, _header, body}} ->
        {:message, {:call, a, op, {:redacted, byte_size(body)}}}

      {:message, {:fetch, a, _pin, _m, _p, _h, body}} ->
        {:message, {:fetch, a, {:redacted, byte_size(body)}}}

      {:message, {:relay_in, data}} ->
        {:message, {:relay_in, {:redacted, byte_size(data)}}}

      {:log, _log} ->
        {:log, []}

      other ->
        other
    end)
  end

  # ————— what the service sends —————

  defp inbound(%{closed: closed} = state, _data) when closed != nil, do: state
  defp inbound(%{channel: nil} = state, _data), do: closed(state, :unbound)

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
        Process.demonitor(fetch.monitor, [:flush])
        unless fetch.draining, do: send(fetch.owner, {__MODULE__, re, {:end, error}})
        %{state | fetches: fetches}
    end
  end

  defp on_frame(%{kind: :close, reason: reason}, state) do
    Logger.error("[Opus.Relay.Runner] the service closed the relay: #{reason}")
    closed(state, {:service, reason})
  end

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

  # A fetch nobody reads is granted back what it received and nobody read,
  # and each chunk's size as it arrives, so the service is never left
  # waiting on it; the service bounds what it sends by the attempt's
  # `max_response_size`.
  defp drain(state, ref) do
    case state.fetches[ref] do
      %{draining: false} = fetch ->
        Process.demonitor(fetch.monitor, [:flush])

        state
        |> put_fetch(ref, %{fetch | draining: true})
        |> grant(ref, fetch.received - fetch.granted, true)

      _other ->
        state
    end
  end

  defp put_fetch(state, ref, fetch), do: %{state | fetches: Map.put(state.fetches, ref, fetch)}

  # ————— writing —————

  defp encode(state, frame) do
    case RunnerRelay.encode(state.channel, frame) do
      {:ok, bytes, channel} ->
        seq = state.channel.sent
        write(state.transport, bytes)
        {:ok, seq, %{state | channel: channel}}

      {:error, reason} ->
        {:error, reason, state}
    end
  rescue
    ArgumentError -> {:error, :malformed, state}
  end

  defp write({:port, port}, bytes) do
    Port.command(port, bytes)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp write({:socket, socket}, bytes) do
    _ = :gen_tcp.send(socket, bytes)
    :ok
  end

  defp write({:peer, pid}, bytes) do
    send(pid, {:relay_in, IO.iodata_to_binary(bytes)})
    :ok
  end

  defp send_close(%{root: nil} = state, _reason), do: state

  defp send_close(state, reason) do
    frame = %{kind: :close, attempt: state.root, reason: RunnerRelay.close_code(reason)}

    case RunnerRelay.encode(state.channel, frame) do
      {:ok, bytes, channel} ->
        write(state.transport, bytes)
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
