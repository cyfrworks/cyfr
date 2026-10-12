# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ListenerTest do
  @moduledoc """
  What each of the island's three signed listeners answers before a
  request runs, as one table: the runtime's worker listener
  (`Locus.Runtime.WorkerListener`, cases R), the builds service
  (`Locus.BuilderService`, cases B and BH) and the backends service's
  control and MCP routes (`Locus.Backends.Service`, cases C, M and MH).
  Each case is driven against the real plug on a loopback port and asserts
  the answer's status, its exact body and its connection handling: "close"
  is a `connection: close` header and a socket the listener closed, "open"
  is no such header and a second request on the same socket answered.

  Every role refuses a request whose header does not verify before it
  reads a byte of the body: those cases promise a body and never send it,
  and the answer must come within 2 s. The cases whose body cannot be read
  call the plug on a connection whose adapter answers every read with
  `{:error, :closed}`, since Bandit raises instead of answering one.

  The checks the listeners share (`Locus.Listener`) are held on their own
  too: the one header, each answer of the bounded read, a drain that
  reads nothing of a connection that is not Bandit's, and a nonce's first
  use, its replay and its expiry.
  """

  use ExUnit.Case, async: false

  alias Locus.Backends.{Owners, Service}
  alias Locus.Listener
  alias Locus.Runtime.Test.ScriptedHost
  alias Locus.Test.Wire
  alias Prima.{BuilderProtocol, HostAPI, WorkerAuth, WorkerWire}
  alias Prima.LocusBackends, as: LB
  alias Prima.MCP.Protocol, as: MCPProtocol

  @vectors Path.expand("../../../../tests/fixtures/locus_backends.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @key Base.decode16!(@vectors["key_hex"], case: :lower)
  @boot @vectors["sync"]["fields"]["boot"]
  @cyfr_boot @vectors["sync"]["fields"]["cyfr_boot"]
  @athanor @vectors["owner"]["athanor"]
  @server @vectors["owner"]["server"]
  @g @vectors["owner"]["generation"]
  @e @vectors["owner"]["epoch"]
  @instant @vectors["hello"]["ts"]
  @lease_ms 30_000

  # An answer that must come before the body it waits on would arrive.
  @unread_ms 2_000

  defmodule Unread do
    @moduledoc false
    # A connection whose body cannot be read, as a peer that left mid-body
    # leaves one; every other callback is Plug's test adapter's.
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: TestConn

    @impl true
    def read_req_body(_state, _opts), do: {:error, :closed}

    @impl true
    defdelegate send_resp(state, status, headers, body), to: TestConn
    @impl true
    defdelegate send_file(state, status, headers, path, offset, length), to: TestConn
    @impl true
    defdelegate send_chunked(state, status, headers), to: TestConn
    @impl true
    defdelegate chunk(state, body), to: TestConn
    @impl true
    defdelegate inform(state, status, headers), to: TestConn
    @impl true
    defdelegate upgrade(state, protocol, opts), to: TestConn
    @impl true
    defdelegate push(state, path, headers), to: TestConn
    @impl true
    defdelegate get_peer_data(state), to: TestConn
    @impl true
    defdelegate get_sock_data(state), to: TestConn
    @impl true
    defdelegate get_ssl_data(state), to: TestConn
    @impl true
    defdelegate get_http_protocol(state), to: TestConn
  end

  defmodule Refusing do
    @moduledoc false
    # Refuses a body past one byte on a closing connection and drains the
    # rest, as the island's listeners do.
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      {:too_large, conn, :read} = Locus.Listener.read_bounded(conn, 1, false)

      conn
      |> put_resp_header("connection", "close")
      |> send_resp(413, "")
      |> Locus.Listener.drain(65_536)
    end
  end

  defmodule Launcher do
    @moduledoc false
    # Starts nothing: a spawn answers a handle whose process never speaks,
    # and a release is never reported.
    import Kernel, except: [send: 2]

    def pool_stats(_server, "backends"), do: {:ok, %{size: 64, free: 64, quarantined: 0}}
    def spawn(_server, _spec), do: {:ok, %{ref: make_ref(), spawn_id: nil, uid: nil, pid: nil}}
    def send(_handle, _data), do: :ok
    def signal(_handle, _sig), do: :ok
    def release(_server, _handle, _grace_ms), do: :ok
  end

  # ————— a client of the wire, over a plain socket —————

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    %{socket: socket, buffer: ""}
  end

  # Writes a request: its head, declaring the length of `body` unless
  # `headers` declare a length or an encoding of their own, then `sent`
  # (the whole body unless the case leaves it unsent).
  defp send_request(client, method, path, headers, body, sent \\ :all) do
    framed? =
      Enum.any?(headers, fn {name, _} -> name in ["content-length", "transfer-encoding"] end)

    headers =
      if framed?, do: headers, else: [{"content-length", "#{byte_size(body)}"} | headers]

    head = [
      "#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    sent =
      case sent do
        :all -> body
        :none -> ""
        bytes when is_binary(bytes) -> bytes
      end

    :ok = :gen_tcp.send(client.socket, [head, sent])
    client
  end

  defp send_bytes(client, bytes) do
    :ok = :gen_tcp.send(client.socket, bytes)
    client
  end

  # The next final answer on the connection, past any `100 Continue`: its
  # status, its headers by lower-case name and its body, read to its
  # length within `timeout_ms`.
  defp answer(client, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    {status, headers, client} = head(client, deadline)

    if status == 100 do
      answer(client, max(deadline - System.monotonic_time(:millisecond), 0))
    else
      length = String.to_integer(headers["content-length"] || "0")
      {body, client} = take(client, length, deadline)
      {%{status: status, headers: headers, body: body}, client}
    end
  end

  # The listener's informational `100 Continue`, which it sends once it
  # asks for a held request's body: the checks before the body passed.
  defp continued(client) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    {status, _headers, client} = head(client, deadline)
    assert status == 100
    client
  end

  defp head(client, deadline) do
    case :erlang.decode_packet(:http_bin, client.buffer, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        headers(%{client | buffer: rest}, status, %{}, deadline)

      {:more, _} ->
        head(more(client, deadline), deadline)
    end
  end

  defp headers(client, status, acc, deadline) do
    case :erlang.decode_packet(:httph_bin, client.buffer, []) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        name = name |> to_string() |> String.downcase()
        headers(%{client | buffer: rest}, status, Map.put(acc, name, value), deadline)

      {:ok, :http_eoh, rest} ->
        {status, acc, %{client | buffer: rest}}

      {:more, _} ->
        headers(more(client, deadline), status, acc, deadline)
    end
  end

  defp take(client, length, _deadline) when byte_size(client.buffer) >= length do
    <<body::binary-size(^length), rest::binary>> = client.buffer
    {body, %{client | buffer: rest}}
  end

  defp take(client, length, deadline), do: take(more(client, deadline), length, deadline)

  defp more(client, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(client.socket, 0, left) do
      {:ok, bytes} -> %{client | buffer: client.buffer <> bytes}
      {:error, :timeout} -> flunk("no whole answer within the bound; read: #{client.buffer}")
      {:error, reason} -> flunk("the connection ended before its answer: #{inspect(reason)}")
    end
  end

  # Nothing arrives on the connection for `ms`.
  defp silent(client, ms) do
    assert client.buffer == ""
    assert :gen_tcp.recv(client.socket, 0, ms) == {:error, :timeout}
    client
  end

  defp assert_closed(client) do
    assert client.buffer == ""
    assert {:error, reason} = :gen_tcp.recv(client.socket, 0, 5_000)
    assert reason in [:closed, :econnreset]
  end

  # The answer's status, exact body and connection handling. An open
  # connection's second request is the case's to send.
  defp assert_answer(answer, status, body, connection) do
    assert {answer.status, answer.body} == {status, body}

    case connection do
      :close -> assert answer.headers["connection"] == "close"
      :open -> assert answer.headers["connection"] == nil
    end
  end

  defp assert_refused(client, status, body, connection, timeout_ms \\ 10_000) do
    {answer, client} = answer(client, timeout_ms)
    assert_answer(answer, status, body, connection)
    if connection == :close, do: assert_closed(client)
    {answer, client}
  end

  # A plug called on a connection whose body cannot be read.
  defp unread(plug, opts, path, headers) do
    conn = Plug.Test.conn("POST", path, "")
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    {Plug.Adapters.Test.Conn, state} = conn.adapter
    conn = %{conn | adapter: {Unread, state}}
    conn = plug.call(conn, plug.init(opts))

    connection =
      case Plug.Conn.get_resp_header(conn, "connection") do
        [] -> nil
        [value] -> value
      end

    %{status: conn.status, body: conn.resp_body, headers: %{"connection" => connection}}
  end

  # A ref the test process is sent `{ref, :start | :socket_shutdown, span}`
  # under as a listener connection starts, with its span the remote port
  # the connection is from, and each time its socket is shut, as the
  # server's telemetry reports them.
  defp connection_events do
    ref = make_ref()
    handler = {__MODULE__, ref}

    events = [
      [:thousand_island, :connection, :start],
      [:thousand_island, :connection, :socket_shutdown]
    ]

    :ok = :telemetry.attach_many(handler, events, &__MODULE__.connection_event/4, {self(), ref})
    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  @doc false
  def connection_event(event, _measurements, metadata, {test, ref}),
    do: send(test, {ref, List.last(event), metadata})

  # The process `module`'s drain started to shut `connection`'s socket at
  # its deadline, found among those monitoring it before `until`, or nil.

  defp reporting_socket do
    %ThousandIsland.Socket{
      socket: self(),
      transport_module: __MODULE__.ShutReporter,
      read_timeout: 1_000,
      silent_terminate_on_error: false,
      span:
        ThousandIsland.Telemetry.start_span(:connection, %{}, %{handler: __MODULE__.ShutReporter})
    }
  end

  defp shut_process(connection, module, until) do
    shut =
      for pid <- Process.info(connection, :monitored_by) |> elem(1),
          is_pid(pid),
          Process.info(pid, :initial_call) == {:initial_call, {module, :shut_at, 3}},
          do: pid

    cond do
      shut != [] ->
        hd(shut)

      System.monotonic_time(:millisecond) < until ->
        receive do
        after
          10 -> shut_process(connection, module, until)
        end

      true ->
        nil
    end
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp system_now, do: System.system_time(:millisecond)

  # ————— the runtime —————

  # A socket whose transport reports a shut to the test instead of making
  # one, so the deadline's helper can be observed without a connection.
  defmodule ShutReporter do
    @moduledoc false
    def shutdown(test, way), do: send(test, {:shut, way})
  end

  describe "the runtime's worker listener" do
    setup do
      host = ScriptedHost.start!()

      server =
        start_supervised!(
          {Bandit,
           plug: Locus.Runtime.WorkerListener, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, %{boot: boot}} = Locus.Runtime.WorkerService.status()
      {:ok, port: port, host: host, key: ScriptedHost.dispatch_key(host), boot: boot}
    end

    test "R1: a method or path that is no worker route is not_found", ctx do
      for {method, path} <- [{"GET", "/worker/v1/status"}, {"POST", "/host/v1/status"}] do
        client = ctx.port |> connect() |> send_request(method, path, [], "")
        assert_refused(client, 404, wl(:not_found), :close)
      end
    end

    test "R2: an unsigned request to a path that is no callback is not_found", ctx do
      client =
        ctx.port
        |> connect()
        |> send_request("POST", "/worker/v1/attach", [], status_body(), :none)

      assert_refused(client, 404, wl(:not_found), :close, @unread_ms)
    end

    test "R3: a service without its credentials is unavailable before any header", ctx do
      credentials = Locus.Runtime.Credentials.current()
      :persistent_term.erase({Locus.Runtime.Credentials, :current})

      try do
        client =
          ctx.port
          |> connect()
          |> send_request("POST", status_route(), [], status_body(), :none)

        assert_refused(client, 503, wl(:unavailable), :close, @unread_ms)
      after
        Locus.Runtime.Credentials.install(credentials)
      end
    end

    test "R4: no header, or two, is malformed", ctx do
      header = runtime_header(ctx, status_body())

      for headers <- [[], [{"x-cyfr-auth", header}, {"x-cyfr-auth", header}]] do
        client =
          ctx.port
          |> connect()
          |> send_request("POST", status_route(), headers, status_body(), :none)

        assert_refused(client, 401, wl(:malformed), :close, @unread_ms)
      end
    end

    test "R5: a header at another version is unknown_version, answered before the body", ctx do
      "v1 " <> rest = runtime_header(ctx, status_body())

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          status_route(),
          [{"x-cyfr-auth", "v2 " <> rest}],
          status_body(),
          :none
        )

      assert_refused(client, 401, wl(:unknown_version), :close, @unread_ms)
    end

    test "R6: a header that does not parse is malformed", ctx do
      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          status_route(),
          [{"x-cyfr-auth", "v1 kind=request mac=x"}],
          status_body(),
          :none
        )

      assert_refused(client, 401, wl(:malformed), :close, @unread_ms)
    end

    test "R7: a header two windows old is outside_window", ctx do
      header = runtime_header(ctx, status_body(), ts: system_now() - 2 * WorkerAuth.window_ms())

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], status_body(), :none)

      assert_refused(client, 401, wl(:outside_window), :close, @unread_ms)
    end

    test "R8: another service's key is bad_mac, answered before the body", ctx do
      stranger = ScriptedHost.dispatch_key(ctx.host, "wrk_other")
      header = runtime_header(ctx, status_body(), key: stranger)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], status_body(), :none)

      assert_refused(client, 401, wl(:bad_mac), :close, @unread_ms)
    end

    test "R9: a header for another service is malformed, and keeps no nonce", ctx do
      nonce = nonce()
      header = runtime_header(ctx, status_body(), service: "wrk_other", nonce: nonce)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], status_body(), :none)

      assert_refused(client, 401, wl(:malformed), :close, @unread_ms)

      # The same nonce, addressed to this service, is its first use.
      assert_status_answered(ctx, connect(ctx.port), nonce: nonce)
    end

    test "R10: a nonce presented twice is replayed", ctx do
      nonce = nonce()
      assert_status_answered(ctx, connect(ctx.port), nonce: nonce)

      header = runtime_header(ctx, status_body(), nonce: nonce)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], status_body(), :none)

      assert_refused(client, 401, wl(:replayed), :close, @unread_ms)
    end

    test "R10b: a verified header's nonce is spent before its body is checked", ctx do
      header = runtime_header(ctx, status_body())
      other = kill_body()

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], other)

      {_answer, client} = assert_refused(client, 401, wl(:bad_mac), :open)

      # Its own body, under the same header, on the same connection.
      client =
        send_request(client, "POST", status_route(), [{"x-cyfr-auth", header}], status_body())

      assert_refused(client, 401, wl(:replayed), :close)
    end

    test "R11: an over-bound body is read to the bound before it is refused", ctx do
      max = HostAPI.max_body_bytes()
      huge = String.duplicate("x", max + 1)
      header = runtime_header(ctx, huge)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], huge, :none)
        |> silent(500)
        |> send_bytes(binary_part(huge, 0, max))

      {answer, client} = answer(client)
      assert_answer(answer, 413, wl(:malformed), :close)

      # The byte past the bound, sent after the refusal, is read and dropped
      # before the listener closes the connection.
      client |> send_bytes(binary_part(huge, max, 1)) |> assert_closed()
    end

    test "R12: a body that cannot be read is malformed", ctx do
      answer =
        unread(Locus.Runtime.WorkerListener, [], status_route(), [
          {"x-cyfr-auth", runtime_header(ctx, status_body())}
        ])

      assert_answer(answer, 400, wl(:malformed), :close)
    end

    test "R13: a body other than the signed one is bad_mac, the connection kept", ctx do
      header = runtime_header(ctx, status_body())

      client =
        ctx.port
        |> connect()
        |> send_request("POST", status_route(), [{"x-cyfr-auth", header}], kill_body())

      {_answer, client} = assert_refused(client, 401, wl(:bad_mac), :open)
      assert_status_answered(ctx, client)
    end

    test "R14: a body without the wire's version, or at another, is unknown_version", ctx do
      client =
        Enum.reduce(
          [
            ~s({"op":"status","args":{}}),
            ~s({"v":2,"op":"status","args":{}}),
            ~s({"v":"1","op":"status","args":{}})
          ],
          connect(ctx.port),
          fn body, client ->
            headers = [{"x-cyfr-auth", runtime_header(ctx, body)}]
            client = send_request(client, "POST", status_route(), headers, body)
            {_answer, client} = assert_refused(client, 400, wl(:unknown_version), :open)
            client
          end
        )

      assert_status_answered(ctx, client)
    end

    test "R15: a body naming another callback, or not JSON, is malformed", ctx do
      client =
        Enum.reduce([kill_body(), "not json"], connect(ctx.port), fn body, client ->
          headers = [{"x-cyfr-auth", runtime_header(ctx, body)}]
          client = send_request(client, "POST", status_route(), headers, body)
          {_answer, client} = assert_refused(client, 400, wl(:malformed), :open)
          client
        end)

      assert_status_answered(ctx, client)
    end
  end

  defp status_route, do: WorkerWire.worker_route(:status)
  defp status_body, do: Jason.encode!(WorkerWire.request_body(:status, %{}))

  defp kill_body,
    do: Jason.encode!(WorkerWire.request_body(:kill, %{"execution_id" => "exec_x"}))

  defp wl(reason), do: ~s({"v":1,"error":"#{reason}"})

  defp runtime_header(ctx, body, opts \\ []) do
    request = %{
      service: Keyword.get(opts, :service, "wrk_local"),
      boot: ctx.boot,
      ts: Keyword.get_lazy(opts, :ts, &system_now/0),
      nonce: Keyword.get_lazy(opts, :nonce, &nonce/0)
    }

    {:ok, header} = WorkerAuth.request_header(Keyword.get(opts, :key, ctx.key), request, body)
    header
  end

  # A signed status request on `client` is answered with the service's state.
  defp assert_status_answered(ctx, client, opts \\ []) do
    header = runtime_header(ctx, status_body(), opts)

    client =
      send_request(client, "POST", status_route(), [{"x-cyfr-auth", header}], status_body())

    {answer, client} = answer(client)
    assert answer.status == 200
    assert %{"v" => 1, "ok" => %{"service" => "wrk_local"}} = Jason.decode!(answer.body)
    client
  end

  # ————— builds —————

  describe "the builds service" do
    setup do
      {:ok, port: Wire.serve!()}
    end

    test "B1: a method or path that is no operation is malformed", ctx do
      for {method, path, headers} <- [
            {"GET", BuilderProtocol.route(:build), []},
            {"POST", "/locus/v1/builds/other", []}
          ] do
        client = ctx.port |> connect() |> send_request(method, path, headers, "")
        sentence = "#{method} on this path is no operation of the builds service"
        {_answer, client} = assert_refused(client, 400, bs(:malformed, sentence), :open)
        assert_health_answered(client)
      end
    end

    test "B2: a service without a key refuses bad_mac before any header", ctx do
      Application.delete_env(:locus, :request_key)
      body = build_body()

      client = ctx.port |> connect() |> send_request("POST", build_route(), [], body)
      {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :bad_mac), :open)
      assert_health_answered(client)
    end

    test "B3: no header, two, or one that is no header, is malformed", ctx do
      body = build_body()
      header = Wire.header(body)

      for headers <- [
            [],
            [{"x-cyfr-auth", header}, {"x-cyfr-auth", header}],
            [{"x-cyfr-auth", "Bearer test-builder-token"}]
          ] do
        client = ctx.port |> connect() |> send_request("POST", build_route(), headers, body)
        {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :malformed), :open)
        assert_health_answered(client)
      end
    end

    test "B4: a header at another version is unknown_version, answered before the body", ctx do
      body = build_body()
      "v1 " <> rest = Wire.header(body)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", build_route(), [{"x-cyfr-auth", "v2 " <> rest}], body, :none)

      {_answer, client} =
        assert_refused(client, 401, bs(:unauthorized, :unknown_version), :open, @unread_ms)

      # The body the request promised, then another request on the same connection.
      client |> send_bytes(body) |> assert_health_answered()
    end

    test "B5: a timestamp outside the window, either side, is outside_window", ctx do
      body = build_body()
      window = BuilderProtocol.window_ms()

      for ts <- [system_now() - window - 5_000, system_now() + window + 5_000] do
        client =
          ctx.port
          |> connect()
          |> send_request(
            "POST",
            build_route(),
            [{"x-cyfr-auth", Wire.header(body, ts: ts)}],
            body
          )

        {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :outside_window), :open)
        assert_health_answered(client)
      end
    end

    test "B6: another key is bad_mac, answered before the body", ctx do
      body = build_body()
      header = Wire.header(body, key: :binary.copy(<<1>>, 32))

      client =
        ctx.port
        |> connect()
        |> send_request("POST", build_route(), [{"x-cyfr-auth", header}], body, :none)

      {_answer, client} =
        assert_refused(client, 401, bs(:unauthorized, :bad_mac), :open, @unread_ms)

      client |> send_bytes(body) |> assert_health_answered()
    end

    test "B7: a nonce presented twice is replayed, whatever became of the first", ctx do
      body = build_body(%{deadline: system_now() - 1})
      nonce = Wire.nonce()

      for {status, expected} <- [
            {504, bs(:timeout, %{"budget_ms" => 0})},
            {401, bs(:unauthorized, :replayed)}
          ] do
        client =
          ctx.port
          |> connect()
          |> send_request(
            "POST",
            build_route(),
            [{"x-cyfr-auth", Wire.header(body, nonce: nonce)}],
            body
          )

        {_answer, client} = assert_refused(client, status, expected, :open)
        assert_health_answered(client)
      end
    end

    test "B7b: a verified header's nonce is spent before its body is checked", ctx do
      body = build_body(%{deadline: system_now() - 1})
      header = Wire.header(body)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", build_route(), [{"x-cyfr-auth", header}], body <> " ")

      {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :bad_mac), :open)
      client = send_request(client, "POST", build_route(), [{"x-cyfr-auth", header}], body)
      {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :replayed), :open)
      assert_health_answered(client)
    end

    test "B8: a declared length past the bound is refused unread, naming both sizes", ctx do
      max = BuilderProtocol.max_request_bytes()
      header = Wire.header("whatever was signed")

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          build_route(),
          [{"content-length", "#{max + 1}"}, {"x-cyfr-auth", header}],
          "",
          :none
        )

      sentence = "the request is #{max + 1} bytes; at most #{max} are read"
      assert_refused(client, 400, bs(:malformed, sentence), :close, @unread_ms)
    end

    test "B9: a chunked body past the bound is malformed", ctx do
      max = BuilderProtocol.max_request_bytes()
      body = String.duplicate("x", max + 1)
      chunk = [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n0\r\n\r\n"]

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          build_route(),
          [{"transfer-encoding", "chunked"}, {"x-cyfr-auth", Wire.header(body)}],
          "",
          :none
        )
        |> send_bytes(chunk)

      sentence = "the request runs past #{max} bytes; at most #{max} are read"
      assert_refused(client, 400, bs(:malformed, sentence), :close)
    end

    test "B10: a body that cannot be read is malformed, the connection kept", _ctx do
      body = build_body()

      answer =
        unread(Locus.BuilderService, [], build_route(), [{"x-cyfr-auth", Wire.header(body)}])

      assert_answer(answer, 400, bs(:malformed, "the body could not be read"), :open)
    end

    test "B11: a body other than the signed one is bad_mac", ctx do
      body = build_body()

      client =
        ctx.port
        |> connect()
        |> send_request("POST", build_route(), [{"x-cyfr-auth", Wire.header(body)}], body <> " ")

      {_answer, client} = assert_refused(client, 401, bs(:unauthorized, :bad_mac), :open)
      assert_health_answered(client)
    end

    test "B12: a body at another version, at none, or not an object", ctx do
      wire = build_body() |> Jason.decode!()

      for {body, status, expected} <- [
            {Jason.encode!(%{wire | "version" => 2}), 409,
             bs(:protocol_mismatch, %{"builder" => 1, "client" => 2})},
            {Jason.encode!(Map.delete(wire, "version")), 409,
             bs(:protocol_mismatch, %{"builder" => 1, "client" => nil})},
            {"[]", 400, bs(:malformed, "the body is not a JSON object")}
          ] do
        client =
          ctx.port
          |> connect()
          |> send_request("POST", build_route(), [{"x-cyfr-auth", Wire.header(body)}], body)

        {_answer, client} = assert_refused(client, status, expected, :open)
        assert_health_answered(client)
      end
    end

    test "BH: health past its bound, at another version, or with a field it lacks", ctx do
      over = String.duplicate(" ", 5_000)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", health_route(), [], over, :none)

      sentence = "the request is 5000 bytes; at most 4096 are read"
      assert_refused(client, 400, bs(:malformed, sentence), :close, @unread_ms)

      for {body, status, expected} <- [
            {~s({"version":2}), 409, bs(:protocol_mismatch, %{"builder" => 1, "client" => 2})},
            {~s({"version":1,"verbose":true}), 400,
             bs(:malformed, "verbose is not a field of this message")}
          ] do
        client = ctx.port |> connect() |> send_request("POST", health_route(), [], body)
        {_answer, client} = assert_refused(client, status, expected, :open)
        assert_health_answered(client)
      end
    end
  end

  defp build_route, do: BuilderProtocol.route(:build)
  defp health_route, do: BuilderProtocol.route(:health)
  defp build_body(fields \\ %{}), do: Wire.body(Wire.request("true", fields))

  # A builds refusal line, exactly as the wire writes it.
  defp bs(class, reason) do
    reason = if is_atom(reason), do: Atom.to_string(reason), else: reason

    ~s({"class":"#{class}","diagnostics":[],"reason":#{Jason.encode!(reason)},) <>
      ~s("type":"refusal","version":1}\n)
  end

  defp assert_health_answered(client) do
    body = BuilderProtocol.encode_health_request()
    client = send_request(client, "POST", health_route(), [], body)
    {answer, client} = answer(client)
    assert answer.status == 200

    assert {:ok, {:health, _}} =
             answer.body |> String.trim_trailing() |> BuilderProtocol.read_line()

    client
  end

  # ————— backends —————

  defp backends(context) do
    :ets.delete_all_objects(Service.Nonces)

    clock = start_supervised!({Agent, fn -> 1_000_000 end}, id: :clock)
    now = start_supervised!({Agent, fn -> @instant end}, id: :now)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :backends)

    owners =
      start_supervised!(
        {Owners,
         boot: @boot,
         supervisor: supervisor,
         clock: fn -> Agent.get(clock, & &1) end,
         stop_grace_ms: 100,
         launcher: Launcher,
         launcher_server: :none}
      )

    opts = [
      owners: owners,
      key: Map.get(context, :key, @key),
      now: fn -> Agent.get(now, & &1) end
    ]

    server =
      start_supervised!(
        Locus.Backends.listener(
          plug: {Service, opts},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{port: port, clock: clock, now: now, opts: opts}
  end

  defp control_route, do: LB.route(:control)
  defp mcp_route, do: LB.route(:mcp)
  defp backends_health_route, do: LB.route(:health)

  defp lb(code), do: ~s({"error":"#{code}","version":1})

  defp rpc(code, message),
    do: ~s({"error":{"code":#{code},"message":"#{message}"},"id":null,"jsonrpc":"2.0"})

  defp seq, do: System.unique_integer([:positive, :monotonic]) + 1_000

  defp status_message do
    {:ok, body} = LB.encode_control(%{type: :status, owners: []})
    body
  end

  defp control_header(ctx, body, opts \\ []) do
    fields = %{
      generation: Keyword.get(opts, :generation, @g),
      seq: Keyword.get_lazy(opts, :seq, &seq/0),
      cyfr_boot: @cyfr_boot,
      boot: Keyword.get(opts, :boot, @boot),
      ts: Keyword.get_lazy(opts, :ts, fn -> Agent.get(ctx.now, & &1) end)
    }

    {:ok, header} = LB.control_header(LB.control_key(@key), fields, body)
    header
  end

  defp sync!(ctx) do
    owner = %{athanor: @athanor, server: @server}

    {:ok, sealed} =
      LB.seal(
        LB.seal_key(@key),
        Map.merge(owner, %{generation: @g, epoch: @e}),
        @boot,
        Jason.encode!(%{"fetch" => %{}})
      )

    message = %{
      type: :sync,
      owner: owner,
      e: @e,
      lease_ms: @lease_ms,
      idle_ms: 600_000,
      backends: [%{name: "fetch", command: "exec cat", env_names: []}],
      sealed: sealed
    }

    {:ok, body} = LB.encode_control(message)

    client =
      ctx.port
      |> connect()
      |> send_request("POST", control_route(), [{"x-cyfr-auth", control_header(ctx, body)}], body)

    {answer, _client} = answer(client)
    assert answer.status == 200, answer.body
    :ok
  end

  defp tools_list, do: mcp_message("tools/list")

  defp mcp_message(method) do
    meta = %{
      MCPProtocol.meta_protocol_version_key() => MCPProtocol.version(),
      MCPProtocol.meta_client_capabilities_key() => %{}
    }

    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => %{"_meta" => meta}
    })
  end

  defp mcp_headers(method),
    do: [{"mcp-protocol-version", MCPProtocol.version()}, {"mcp-method", method}]

  defp invoke_header(ctx, body, opts \\ []) do
    owner = %{
      athanor: @athanor,
      server: Keyword.get(opts, :server, @server),
      generation: @g,
      epoch: Keyword.get(opts, :epoch, @e)
    }

    {:ok, owner_key} = LB.owner_key(Keyword.get(opts, :key, @key), owner)

    fields =
      Map.merge(owner, %{
        boot: Keyword.get(opts, :boot, @boot),
        ts: Keyword.get_lazy(opts, :ts, fn -> Agent.get(ctx.now, & &1) end),
        nonce: Keyword.get_lazy(opts, :nonce, &nonce/0)
      })

    {:ok, header} = LB.invoke_header(owner_key, fields, body)
    header
  end

  defp assert_backends_health_answered(client) do
    client = send_request(client, "POST", backends_health_route(), [], ~s({"version":1}))
    {answer, client} = answer(client)
    assert answer.status == 200
    assert answer.headers["x-cyfr-boot"] == @boot
    client
  end

  describe "the backends service's control route" do
    setup context, do: {:ok, backends(context)}

    test "C1: a method or path that is no operation is bad_request, naming the lifetime", ctx do
      for {method, path} <- [{"GET", control_route()}, {"POST", "/locus/v1/backends/nope"}] do
        client = ctx.port |> connect() |> send_request(method, path, [], "")
        {answer, _client} = assert_refused(client, 400, lb(:bad_request), :close)
        assert answer.headers["x-cyfr-boot"] == @boot
      end
    end

    test "C3: a header that does not verify is unauthorized, answered before the body", ctx do
      body = status_message()
      header = control_header(ctx, body)
      [_, mac] = String.split(header, " mac=")
      "v1 " <> rest = header
      stale = control_header(ctx, body, ts: @instant - LB.window_ms() - 1)

      for headers <- [
            [],
            [{"x-cyfr-auth", header}, {"x-cyfr-auth", header}],
            [{"x-cyfr-auth", Wire.header(body)}],
            [{"x-cyfr-auth", invoke_header(ctx, body)}],
            [{"x-cyfr-auth", String.replace(header, mac, String.reverse(mac))}],
            [{"x-cyfr-auth", "v2 " <> rest}],
            [{"x-cyfr-auth", stale}]
          ] do
        client =
          ctx.port |> connect() |> send_request("POST", control_route(), headers, body, :none)

        assert_refused(client, 401, lb(:unauthorized), :close, @unread_ms)
      end
    end

    test "C4: a header naming neither this lifetime nor none is stale_boot", ctx do
      body = status_message()
      header = control_header(ctx, body, boot: "bb_" <> String.duplicate("0", 32))

      client =
        ctx.port
        |> connect()
        |> send_request("POST", control_route(), [{"x-cyfr-auth", header}], body, :none)

      assert_refused(client, 409, lb(:stale_boot), :close, @unread_ms)
    end

    test "C5: an applied header again is stale_control", ctx do
      body = status_message()
      header = control_header(ctx, body)

      client =
        ctx.port
        |> connect()
        |> send_request("POST", control_route(), [{"x-cyfr-auth", header}], body)

      {answer, _client} = answer(client)
      assert answer.status == 200

      client =
        ctx.port
        |> connect()
        |> send_request("POST", control_route(), [{"x-cyfr-auth", header}], body, :none)

      assert_refused(client, 409, lb(:stale_control), :close, @unread_ms)
    end

    test "C6: a body past its bound, declared or chunked, is too_large", ctx do
      max = LB.max_control_bytes()
      body = status_message()

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          control_route(),
          [{"content-length", "#{max + 1}"}, {"x-cyfr-auth", control_header(ctx, body)}],
          "",
          :none
        )

      assert_refused(client, 413, lb(:too_large), :close, @unread_ms)

      over = String.duplicate(" ", max + 1)

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          control_route(),
          [{"transfer-encoding", "chunked"}, {"x-cyfr-auth", control_header(ctx, over)}],
          "",
          :none
        )
        |> send_bytes([Integer.to_string(max + 1, 16), "\r\n", over, "\r\n0\r\n\r\n"])

      assert_refused(client, 413, lb(:too_large), :close)
    end

    test "C7: a body that cannot be read is bad_request", ctx do
      body = status_message()

      answer =
        unread(Service, ctx.opts, control_route(), [{"x-cyfr-auth", control_header(ctx, body)}])

      assert_answer(answer, 400, lb(:bad_request), :close)
    end

    test "C8: a body other than the hashed one is unauthorized, the connection kept", ctx do
      body = status_message()

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          control_route(),
          [{"x-cyfr-auth", control_header(ctx, body)}],
          body <> " "
        )

      {_answer, client} = assert_refused(client, 401, lb(:unauthorized), :open)
      assert_backends_health_answered(client)
    end

    test "C9: a body at another version is version", ctx do
      body = ~s({"owners":[],"type":"status","version":2})

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          control_route(),
          [{"x-cyfr-auth", control_header(ctx, body)}],
          body
        )

      {_answer, client} = assert_refused(client, 409, lb(:version), :open)
      assert_backends_health_answered(client)
    end

    test "C10: a message naming the other lifetime than its type does is stale_boot", ctx do
      {:ok, hello} = LB.encode_control(%{type: :hello, g: @g, cyfr_boot: @cyfr_boot})

      for {body, boot} <- [{status_message(), "-"}, {hello, @boot}] do
        client =
          ctx.port
          |> connect()
          |> send_request(
            "POST",
            control_route(),
            [{"x-cyfr-auth", control_header(ctx, body, boot: boot)}],
            body
          )

        {_answer, client} = assert_refused(client, 409, lb(:stale_boot), :open)
        assert_backends_health_answered(client)
      end
    end
  end

  describe "the backends service without a key" do
    @describetag key: nil
    setup context, do: {:ok, backends(context)}

    test "C2: a control message is unauthorized before its header is read", ctx do
      body = status_message()

      client =
        ctx.port
        |> connect()
        |> send_request(
          "POST",
          control_route(),
          [{"x-cyfr-auth", control_header(ctx, body)}],
          body,
          :none
        )

      assert_refused(client, 401, lb(:unauthorized), :close, @unread_ms)
    end

    test "M2: an MCP request is -33001 before its header is read", ctx do
      body = tools_list()
      headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]

      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
      assert_refused(client, 401, rpc(-33_001, "unauthorized"), :close, @unread_ms)
    end
  end

  describe "the backends service's MCP route" do
    setup context do
      ctx = backends(context)
      :ok = sync!(ctx)
      {:ok, ctx}
    end

    test "M1: a method other than POST is 405, allowing POST", ctx do
      client = ctx.port |> connect() |> send_request("GET", mcp_route(), [], "")

      {answer, _client} =
        assert_refused(
          client,
          405,
          rpc(-32_600, "GET is not supported on the MCP endpoint."),
          :close
        )

      assert answer.headers["allow"] == "POST"
    end

    test "M3: a header that does not verify is -33001, answered before the body", ctx do
      body = tools_list()
      header = invoke_header(ctx, body)
      "v1 " <> rest = header

      for auth <- [
            [],
            [{"x-cyfr-auth", control_header(ctx, body)}],
            [{"x-cyfr-auth", invoke_header(ctx, body, key: :binary.copy(<<7>>, 32))}],
            [{"x-cyfr-auth", "v2 " <> rest}],
            [{"x-cyfr-auth", invoke_header(ctx, body, ts: @instant - LB.window_ms() - 1)}]
          ] do
        client =
          ctx.port
          |> connect()
          |> send_request("POST", mcp_route(), auth ++ mcp_headers("tools/list"), body, :none)

        assert_refused(client, 401, rpc(-33_001, "unauthorized"), :close, @unread_ms)
      end
    end

    test "M4: an invoke naming another lifetime is stale_boot", ctx do
      body = tools_list()
      header = invoke_header(ctx, body, boot: "bb_" <> String.duplicate("0", 32))
      headers = [{"x-cyfr-auth", header} | mcp_headers("tools/list")]

      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
      assert_refused(client, 409, lb(:stale_boot), :close, @unread_ms)
    end

    test "M5: an owner the invoke does not reach is refused with its code", ctx do
      body = tools_list()
      other = "mcp_01a09fee-1b2c-7d3e-8f40-5a6b7c8d9e0f"

      for {opts, code} <- [
            {[server: other], :unknown_owner},
            {[epoch: @e - 1], :stale_epoch},
            {[epoch: @e + 1], :epoch_ahead}
          ] do
        headers = [{"x-cyfr-auth", invoke_header(ctx, body, opts)} | mcp_headers("tools/list")]
        client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
        assert_refused(client, 409, lb(code), :close, @unread_ms)
      end

      Agent.update(ctx.clock, &(&1 + @lease_ms))
      headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]
      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
      assert_refused(client, 409, lb(:lapsed), :close, @unread_ms)
    end

    test "M6: a recorded nonce is replay, and an owner at its nonce cap nonce_cache_full", ctx do
      body = tools_list()
      header = invoke_header(ctx, body)
      headers = [{"x-cyfr-auth", header} | mcp_headers("tools/list")]

      {answer, _client} =
        ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body) |> answer()

      assert answer.status == 200

      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
      assert_refused(client, 409, lb(:replay), :close, @unread_ms)

      live = System.system_time(:millisecond) * 2

      rows =
        for i <- 1..LB.max_nonces(), do: {{@athanor, @server, @g, @e, "held_#{i}"}, live}

      true = :ets.insert(Service.Nonces, rows)

      headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]
      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body, :none)
      assert_refused(client, 503, lb(:nonce_cache_full), :close, @unread_ms)
    end

    test "M7: a body past its bound, declared or chunked, is -32600 at 413", ctx do
      max = LB.max_mcp_bytes()
      body = tools_list()

      headers =
        [{"content-length", "#{max + 1}"}, {"x-cyfr-auth", invoke_header(ctx, body)}] ++
          mcp_headers("tools/list")

      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, "", :none)
      assert_refused(client, 413, rpc(-32_600, "Request body too large"), :close, @unread_ms)

      over = String.duplicate(" ", max + 1)

      headers =
        [{"transfer-encoding", "chunked"}, {"x-cyfr-auth", invoke_header(ctx, over)}] ++
          mcp_headers("tools/list")

      client =
        ctx.port
        |> connect()
        |> send_request("POST", mcp_route(), headers, "", :none)
        |> send_bytes([Integer.to_string(max + 1, 16), "\r\n", over, "\r\n0\r\n\r\n"])

      assert_refused(client, 413, rpc(-32_600, "Request body too large"), :close)
    end

    test "M8: a body that cannot be read is -32600", ctx do
      body = tools_list()
      headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]
      answer = unread(Service, ctx.opts, mcp_route(), headers)
      assert_answer(answer, 400, rpc(-32_600, "The request body could not be read"), :close)
    end

    test "M9: a nonce is recorded only once its body was the one signed", ctx do
      body = tools_list()
      headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]

      client = ctx.port |> connect() |> send_request("POST", mcp_route(), headers, body <> " ")
      {_answer, client} = assert_refused(client, 401, rpc(-33_001, "unauthorized"), :open)

      client = send_request(client, "POST", mcp_route(), headers, body)
      {answer, client} = answer(client)
      assert answer.status == 200
      assert answer.headers["connection"] == nil

      client = send_request(client, "POST", mcp_route(), headers, body)
      assert_refused(client, 409, lb(:replay), :close)
    end

    test "M10: an owner whose lease passes while its body arrives is lapsed", ctx do
      body = tools_list()

      headers =
        [{"expect", "100-continue"}, {"x-cyfr-auth", invoke_header(ctx, body)}] ++
          mcp_headers("tools/list")

      client =
        ctx.port
        |> connect()
        |> send_request("POST", mcp_route(), headers, body, :none)
        |> continued()

      Agent.update(ctx.clock, &(&1 + @lease_ms))
      client = send_bytes(client, body)
      {_answer, client} = assert_refused(client, 409, lb(:lapsed), :open)
      assert_backends_health_answered(client)
    end

    test "M11: a body that is not JSON, or a batch, is a JSON-RPC error at 400", ctx do
      batch = "[" <> tools_list() <> "]"

      client =
        Enum.reduce(
          [
            {"{nope", rpc(-32_700, "Parse error: body is not valid JSON")},
            {batch, rpc(-32_600, "Expected a single JSON-RPC message")}
          ],
          connect(ctx.port),
          fn {body, expected}, client ->
            headers = [{"x-cyfr-auth", invoke_header(ctx, body)} | mcp_headers("tools/list")]
            client = send_request(client, "POST", mcp_route(), headers, body)
            {_answer, client} = assert_refused(client, 400, expected, :open)
            client
          end
        )

      assert_backends_health_answered(client)
    end

    test "MH: health past its bound, at another version or none, or with a field it lacks",
         ctx do
      over = String.duplicate(" ", 4_097)

      client =
        ctx.port |> connect() |> send_request("POST", backends_health_route(), [], over, :none)

      assert_refused(client, 413, lb(:too_large), :close, @unread_ms)

      for {body, status, code} <- [
            {~s({"version":2}), 409, :version},
            {~s({}), 409, :version},
            {~s({"version":1,"x":1}), 400, :bad_request}
          ] do
        client = ctx.port |> connect() |> send_request("POST", backends_health_route(), [], body)
        {_answer, client} = assert_refused(client, status, lb(code), :open)
        assert_backends_health_answered(client)
      end
    end
  end

  # ————— the shared checks —————

  @window_ms 30_000

  defp posted(body, headers \\ []) do
    Enum.reduce(headers, Plug.Test.conn("POST", "/", body), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
  end

  # A nonce table of the calling test's own, gone with its process.
  defp nonce_table do
    table = :"#{__MODULE__}.Nonces#{System.unique_integer([:positive])}"
    :ok = Listener.init_nonces(table)
    table
  end

  describe "Locus.Listener" do
    test "the auth header is the request's one x-cyfr-auth header" do
      assert Listener.auth_header(posted("")) == :error
      assert Listener.auth_header(posted("", [{"x-cyfr-auth", "v1 a"}])) == {:ok, "v1 a"}

      two = %{posted("") | req_headers: [{"x-cyfr-auth", "v1 a"}, {"x-cyfr-auth", "v1 b"}]}
      assert Listener.auth_header(two) == :error
    end

    test "a body within its bound is read whole" do
      assert {:ok, "0123456789", _conn} = Listener.read_bounded(posted("0123456789"), 10, true)

      conn = posted("0123456789", [{"content-length", "10"}])
      assert {:ok, "0123456789", _conn} = Listener.read_bounded(conn, 10, true)
    end

    test "a declared length past the bound is refused before a byte is read" do
      conn = posted("0123456789a", [{"content-length", "11"}])
      assert {:too_large, conn, {:declared, 11}} = Listener.read_bounded(conn, 10, true)

      # Every byte is still there to be read.
      assert {:ok, "0123456789a", _conn} = Plug.Conn.read_body(conn)
    end

    test "a body past the bound as it is read is too large, declared or not" do
      for {headers, declared?} <- [{[{"content-length", "11"}], false}, {[], true}] do
        conn = posted("0123456789a", headers)
        assert {:too_large, conn, :read} = Listener.read_bounded(conn, 10, declared?)

        # Read up to the bound, and no further.
        assert {:ok, "a", _conn} = Plug.Conn.read_body(conn)
      end
    end

    test "a drain on a connection that is not Bandit's socket reads nothing" do
      conn = posted("0123456789a")
      assert {:too_large, conn, :read} = Listener.read_bounded(conn, 10, false)

      assert Listener.drain(conn, 10) == conn
      assert {:ok, "a", _conn} = Plug.Conn.read_body(conn)
    end

    test "a drain's shut ends with the connection's process, and nothing fires after it" do
      timeout = 1_000
      events = connection_events()

      server =
        start_supervised!(
          {Bandit,
           plug: Refusing,
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [read_timeout: timeout]},
          id: :refusing
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)
      {:ok, client_port} = :inet.port(client)

      assert_receive {^events, :start,
                      %{remote_port: ^client_port, telemetry_span_context: connection_span}},
                     5_000

      # One byte of a longer body: the refusal, then a drain waiting for the
      # rest, which never comes.
      :ok = :gen_tcp.send(client, "POST / HTTP/1.1\r\nhost: l\r\ncontent-length: 9\r\n\r\nx")
      assert {:ok, "HTTP/1.1 413 " <> _} = :gen_tcp.recv(client, 0, 5_000)
      deadline = System.monotonic_time(:millisecond) + timeout
      {:ok, [connection]} = ThousandIsland.connection_pids(server)

      helper = shut_process(connection, Locus.Listener, deadline - div(timeout, 2))
      helper_watch = if helper, do: Process.monitor(helper)
      watch = Process.monitor(connection)
      Process.exit(connection, :kill)
      assert_receive {:DOWN, ^watch, :process, ^connection, :killed}, 5_000

      # Past the drain's deadline, no shut was made for the connection.
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      refute_receive {^events, :socket_shutdown, %{telemetry_span_context: ^connection_span}},
                     left + 500

      # It was the drain's own process, and it ended with the connection's.
      assert is_pid(helper), "no process of the drain's monitored the connection's"
      assert_receive {:DOWN, ^helper_watch, :process, ^helper, _reason}, 1_000
      :gen_tcp.close(client)
    end

    test "a drain's shut waits only for the time left to its one deadline" do
      socket = reporting_socket()
      now = System.monotonic_time(:millisecond)

      # Started past its deadline (a delayed schedule), the helper shuts at
      # once: its wait is what is left, never a fresh duration of its own.
      late = spawn(Locus.Listener, :shut_at, [self(), socket, now - 1])
      assert_receive {:shut, :read}, 1_000
      late_watch = Process.monitor(late)
      assert_receive {:DOWN, ^late_watch, :process, ^late, _}, 1_000

      # Started with time left, it shuts when the deadline comes, not before.
      deadline = System.monotonic_time(:millisecond) + 150
      timely = spawn(Locus.Listener, :shut_at, [self(), socket, deadline])
      assert_receive {:shut, :read}, 5_000
      assert System.monotonic_time(:millisecond) >= deadline
      timely_watch = Process.monitor(timely)
      assert_receive {:DOWN, ^timely_watch, :process, ^timely, _}, 1_000

      # Told to stop before its deadline, it shuts nothing and ends.
      stopped =
        spawn(Locus.Listener, :shut_at, [
          self(),
          socket,
          System.monotonic_time(:millisecond) + 60_000
        ])

      stopped_watch = Process.monitor(stopped)
      send(stopped, :stop)
      assert_receive {:DOWN, ^stopped_watch, :process, ^stopped, _}, 1_000
      refute_received {:shut, _}
    end

    test "a body that cannot be read is unread" do
      conn = posted("")
      {Plug.Adapters.Test.Conn, state} = conn.adapter
      conn = %{conn | adapter: {Unread, state}}
      assert {:unread, ^conn} = Listener.read_bounded(conn, 10, true)
    end

    test "a nonce is fresh once, replayed for two windows, and fresh again past them" do
      table = nonce_table()
      now = 1_000_000
      past = now + 2 * @window_ms + 1

      assert Listener.fresh(table, "n1", now, @window_ms) == :ok
      assert Listener.fresh(table, "n1", now, @window_ms) == {:error, :replayed}
      assert Listener.fresh(table, "n1", now + 2 * @window_ms, @window_ms) == {:error, :replayed}

      # Past its two windows the row is swept, by any nonce's check.
      assert Listener.fresh(table, "n2", past, @window_ms) == :ok
      assert :ets.lookup(table, "n1") == []
      assert Listener.fresh(table, "n1", past, @window_ms) == :ok
    end

    test "the nonce table is created once, and a second creation keeps what it holds" do
      table = nonce_table()
      assert :ets.info(table, :type) == :set
      assert :ets.info(table, :protection) == :public
      assert Listener.fresh(table, "kept", 0, @window_ms) == :ok

      :ok = Listener.init_nonces(table)
      assert Listener.fresh(table, "kept", 0, @window_ms) == {:error, :replayed}
    end

    test "the clock is the plug's own when it was given one, the system's otherwise" do
      given = Plug.Conn.assign(posted(""), :service_opts, now: fn -> 42 end)
      assert Listener.now(given) == 42

      before = System.system_time(:millisecond)
      read = Listener.now(Plug.Conn.assign(posted(""), :service_opts, []))
      assert read >= before and read <= System.system_time(:millisecond)
    end
  end
end
