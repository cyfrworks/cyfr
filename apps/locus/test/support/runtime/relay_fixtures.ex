# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.RelayFixtures do
  @moduledoc """
  Fixtures for tests of the service's end of a runner's relay
  (`Locus.Runtime.Relay`), its peer the test's scripted runner end
  (`Locus.Runtime.Test.RunnerEnd`), joined to a scripted host.

  `attempt!/2` mints an attempt of `component_ref/0` on a
  `Locus.Runtime.Test.ScriptedHost` under an edge and limits of the test's
  choosing. `signed_call/3` builds a host call as a runner signs and seals
  it under its attempt's keys, and `call/3` sends one through the runner's
  end and opens CYFR's answer; `pin!/3` asks CYFR for a pin that way.
  `upstream!/0` and `big_upstream!/1` serve a loopback upstream for the
  calling test; the first answers `/wide-head` with a head of 64 headers
  of 2,000 bytes. `attached/2` and `attached_fetch/2` build and send an
  attached fetch as a runner does. `events/4`, `body_of/1` and
  `read_granting/3` read a fetch's events to its end at the runner's end,
  granting credit back as a runner's guest reads. Each is called from the
  test's own process: servers are supervised by it and upstream messages
  go to it.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Locus.Runtime.Test.RunnerEnd, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, ScriptedHost, ScriptedKeeper}
  alias Prima.{Assignment, AttachedRequest, PinnedTarget, WorkerAuth, WorkerWire}

  @ref "catalyst:local.relayed:1.0.0"

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream answering each path with its name; `/wide-head`
    # with `wide_head/0`'s headers too.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:upstream, conn.method, conn.request_path, conn.req_headers})

      conn =
        if conn.request_path == "/wide-head",
          do: Plug.Conn.merge_resp_headers(conn, wide_head()),
          else: conn

      Plug.Conn.send_resp(conn, 200, "reached " <> conn.request_path)
    end

    # 64 headers of 2,000 bytes: a head many times a frame's envelope, and
    # well within what the HTTP client reads of one.
    def wide_head, do: for(n <- 1..64, do: {"x-wide-#{n}", String.duplicate("w", 2_000)})
  end

  @spec component_ref() :: String.t()
  def component_ref, do: @ref

  @spec attempt!(map(), keyword()) :: map()
  def attempt!(host, opts \\ []) do
    edge = Keyword.get(opts, :edge, EdgeFixtures.edge(domains: ["api.test"], methods: ["GET"]))
    limits = Keyword.get(opts, :limits, EdgeFixtures.limits())

    ScriptedHost.attempt!(
      host,
      [component_ref: @ref, authority: ScriptedKeeper.authority(edge, limits)] ++
        Keyword.drop(opts, [:edge, :limits])
    )
  end

  @doc """
  A host call of `op` with `args` for `attempt`, as its runner signs and
  seals one: under the attempt's keys, presenting its runner and boot and
  the member its assignment names.
  """
  @spec signed_call(map(), atom(), map()) :: map()
  def signed_call(attempt, op, args), do: attempt |> sign(op, args) |> elem(0)

  @doc """
  A host call of `op` with `args`, as `attempt`'s runner makes it: signed
  and sealed (`signed_call/3`), sent through the runner's end of the relay
  (`attempt.endpoint`), and CYFR's answer opened under the attempt's seal
  key and read as the wire reads one (`Prima.WorkerWire.read_answer/1`).
  Answers `{:ok, value}`, `{:error, name, fields}` or `:lost` for a `200`
  answer, `{:status, status}` for any other, `:no_answer` for an answer
  that did not reach the service, or the runner's end's `{:error, reason}`.
  """
  @spec call(map(), atom(), map()) :: term()
  def call(attempt, op, args) do
    {frame, fields} = sign(attempt, op, args)
    timeout = Prima.HostAPI.request_timeout_ms(op)

    case Endpoint.call(attempt.endpoint, frame.attempt, op, frame.header, frame.body, timeout) do
      {:ok, 200, body} ->
        {:ok, json} = WorkerAuth.open_call(attempt.keys.seal, :answer, fields, body)
        json |> Jason.decode!() |> WorkerWire.read_answer()

      {:ok, nil, _body} ->
        :no_answer

      {:ok, status, _body} ->
        {:status, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The pin CYFR grants `attempt`'s runner for `url`, asked through its relay
  (`call/3`) as a runner asks one: for the `:purpose` `opts` names
  (default `:fetch`), from the pin `:from` names for a redirect. The
  service's end learns it as it relays the answer.
  """
  @spec pin!(map(), String.t(), keyword()) :: PinnedTarget.t()
  def pin!(attempt, url, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, :fetch)
    {:ok, args} = PinnedTarget.request_args(url, purpose, Keyword.get(opts, :from))
    {:ok, wire} = call(attempt, :egress_pin, args)
    {:ok, pin} = PinnedTarget.read(wire)
    pin
  end

  defp sign(attempt, op, args) do
    {:ok, assignment} = Assignment.read(attempt.assignment)

    fields =
      Map.merge(attempt.keys.attempt, %{
        boot: attempt.boot,
        runner: attempt.runner,
        member: assignment.member,
        ts: System.system_time(:millisecond),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })

    json = Jason.encode!(WorkerWire.request_body(op, args))
    {:ok, sealed} = WorkerAuth.seal_call(attempt.keys.seal, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(attempt.keys.call, fields, sealed)
    {%{kind: :host_call, attempt: attempt.attempt, op: op, header: header, body: sealed}, fields}
  end

  @spec upstream!() :: :inet.port_number()
  def upstream! do
    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # A fetch's events to its end, and why it ended; each chunk is granted
  # back as it is read, as a runner grants it for its guest, unless
  # `grant` is false: a runner that reads nothing.
  @spec events(pid(), non_neg_integer(), boolean(), list()) :: {list(), term()}
  def events(endpoint, ref, grant \\ true, acc \\ []) do
    receive do
      {Endpoint, ^ref, {:end, error}} ->
        {Enum.reverse(acc), error}

      {Endpoint, ^ref, event} ->
        if grant,
          do: Endpoint.credit(endpoint, ref, byte_size(elem(event, tuple_size(event) - 1)))

        events(endpoint, ref, grant, [event | acc])
    after
      10_000 -> flunk("the fetch never ended: #{inspect(Enum.reverse(acc))}")
    end
  end

  @spec body_of(list()) :: binary()
  def body_of(events) do
    Enum.map_join(events, fn
      {:head, _status, _headers, body} -> body
      {:chunk, body} -> body
    end)
  end

  # A guest's request naming a connection, as a runner builds it.
  @spec attached(String.t(), keyword()) :: AttachedRequest.t()
  def attached(url \\ "http://api.test/v1/x", opts \\ []) do
    %AttachedRequest{
      call_id: AttachedRequest.call_id(:crypto.strong_rand_bytes(16)),
      connection: "api_key",
      method: Keyword.get(opts, :method, "GET"),
      url: url,
      headers: [{"accept", "text/plain"}],
      body: Keyword.get(opts, :body, ""),
      purpose: :fetch
    }
  end

  @spec attached_fetch(map(), AttachedRequest.t()) :: term()
  def attached_fetch(attempt, request) do
    Endpoint.attached_fetch(attempt.endpoint, attempt.attempt, request, %{
      call: attempt.keys.call,
      seal: attempt.keys.seal
    })
  end

  # An upstream answering one request with `size` bytes, telling the test
  # when its connection is closed under it.
  @spec big_upstream!(non_neg_integer()) :: {:inet.port_number(), pid()}
  def big_upstream!(size) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()
    chunk = :binary.copy("0123456789abcdef", 65_536)

    server =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 10_000)
        _ = :gen_tcp.recv(sock, 0, 1_000)
        :ok = :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\ncontent-length: #{size}\r\n\r\n")
        send_body(sock, size, chunk, test)
        # sleep-ok: the upstream keeps the socket open after the body, so the relay, not a close,
        # ends the stream
        Process.sleep(5_000)
      end)

    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listen) end)
    {port, server}
  end

  defp send_body(_sock, 0, _chunk, _test), do: :ok

  defp send_body(sock, left, chunk, test) do
    piece = binary_part(chunk, 0, min(left, byte_size(chunk)))

    case :gen_tcp.send(sock, piece) do
      :ok -> send_body(sock, left - byte_size(piece), chunk, test)
      {:error, _closed} -> send(test, {:upstream_closed, self()})
    end
  end

  # Read a fetch to its end, granting back each chunk as it is read.
  @spec read_granting(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def read_granting(endpoint, ref, total) do
    receive do
      {Endpoint, ^ref, {:head, 200, _headers, body}} ->
        Endpoint.credit(endpoint, ref, byte_size(body))
        read_granting(endpoint, ref, total + byte_size(body))

      {Endpoint, ^ref, {:chunk, body}} ->
        Endpoint.credit(endpoint, ref, byte_size(body))
        read_granting(endpoint, ref, total + byte_size(body))

      {Endpoint, ^ref, {:end, nil}} ->
        total
    after
      10_000 -> flunk("the fetch stalled after #{total} bytes")
    end
  end
end
