# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.RelayFixtures do
  @moduledoc """
  Fixtures for tests of a runner's relay (`Locus.Runtime.Relay`,
  `Locus.Runtime.Relay.Runner`) joined to a scripted host.

  `attempt!/2` mints an attempt of `component_ref/0` on a
  `Locus.Runtime.Test.ScriptedHost` under an edge and limits of the test's
  choosing. `upstream!/0` and `big_upstream!/1` serve a loopback upstream
  for the calling test. `attached/2` and `attached_fetch/2` build and send
  an attached fetch as a runner's handler does. `events/4`, `body_of/1`
  and `read_granting/3` read a fetch's events to its end at the runner's
  end, granting credit back as a runner's handlers do. Each is called from
  the test's own process: servers are supervised by it and upstream
  messages go to it.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Locus.Runtime.Relay.Runner, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, ScriptedHost, ScriptedKeeper}
  alias Prima.AttachedRequest

  @ref "catalyst:local.relayed:1.0.0"

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream answering each path with its name.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:upstream, conn.method, conn.request_path, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "reached " <> conn.request_path)
    end
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
  # back as it is read, as a runner's handlers grant it, unless `grant` is
  # false: a runner that reads nothing.
  @spec events(pid(), reference(), boolean(), list()) :: {list(), term()}
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

  # A guest's request naming a connection, as the runner's handler builds it.
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
  @spec read_granting(pid(), reference(), non_neg_integer()) :: non_neg_integer()
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
