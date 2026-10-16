# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.HttpStreamHandlerBoundaryTest do
  @moduledoc """
  The streaming imports keep the promise every host import keeps: a host
  function never raises into WASM. A malformed request, a handle that does
  not exist and a stream that cannot be started each answer the guest a
  typed error, with a host client that holds no context of its own. A
  stream's address is asked of CYFR when it opens and again right before
  it is sent, and the relay asks once more before it connects: no stream
  is sent on another's pin, and a stream that outlives its pin keeps the
  connection it opened.
  """
  use ExUnit.Case, async: true

  import Prima.Test.Wait

  alias Locus.Runtime.HttpStreamHandler
  alias Locus.Runtime.Test.{ScriptedHost, ScriptedKeeper}

  defp imports do
    attempt =
      ScriptedHost.attempt!(ScriptedHost.start!(), component_ref: "catalyst:local.streamer:0.1.0")

    {imports, exec_ref} =
      HttpStreamHandler.build_stream_imports(
        nil,
        Prima.Limits.defaults(:catalyst),
        attempt.client,
        "catalyst:local.streamer:0.1.0"
      )

    {imports["cyfr:http/streaming@0.1.0"], exec_ref}
  end

  defp call(ns, name, arg) do
    {:fn, fun} = ns[name]
    fun.(arg)
  end

  defmodule Upstream do
    @moduledoc false
    # A loopback upstream answering each path with its name.
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "streamed " <> conn.request_path)
  end

  defp read_all(read, handle, acc \\ "", attempts \\ 100)
  defp read_all(_read, _handle, _acc, 0), do: flunk("the stream never completed")

  defp read_all(read, handle, acc, attempts) do
    case read.(handle) |> Jason.decode!() do
      %{"done" => true, "data" => data} -> acc <> data
      %{"data" => data} -> read_all(read, handle, acc <> data, attempts - 1)
    end
  end

  # A client routed as a runner's is, through a relay whose service end
  # keeps each pin CYFR grants the attempt, for an attempt allowed to reach
  # `stream.test`; the streaming imports over it, cleaned up with the test.
  defp relayed_streams(host) do
    ref = "catalyst:local.streamer:0.1.0"
    edge = Locus.Runtime.Test.EdgeFixtures.edge(domains: ["stream.test"], methods: ["GET"])
    authority = ScriptedKeeper.authority(edge, Prima.Limits.defaults(:catalyst))

    client =
      host
      |> ScriptedHost.attempt!(component_ref: ref, authority: authority)
      |> ScriptedKeeper.relayed!()
      |> Map.fetch!(:client)

    {imports, exec_ref} =
      HttpStreamHandler.build_stream_imports(edge, Prima.Limits.defaults(:catalyst), client, ref)

    on_exit(fn -> HttpStreamHandler.cleanup_registry(exec_ref) end)
    imports["cyfr:http/streaming@0.1.0"]
  end

  defp open(ns, url) do
    request = Jason.encode!(%{"method" => "GET", "url" => url})
    assert %{"handle" => handle} = ns |> call("request", request) |> Jason.decode!()
    handle
  end

  test "each stream asks for its own pin when it opens and again before it is sent, and the relay once more" do
    server =
      start_supervised!({Bandit, plug: Upstream, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, %{"stream.test" => "127.0.0.1"}, expires_in: 60_000)
    ns = relayed_streams(host)
    {:fn, read} = ns["read"]

    first = open(ns, "http://stream.test:#{port}/one")
    assert read_all(read, first) == "streamed /one"
    second = open(ns, "http://stream.test:#{port}/two")
    assert read_all(read, second) == "streamed /two"

    asked = ScriptedHost.requests(host, "egress_pin")
    assert length(asked) == 6

    for %{args: args} <- asked, do: assert(args["purpose"] == "stream")

    assert asked |> Enum.map(& &1.args["url"]) |> Enum.frequencies() == %{
             "http://stream.test:#{port}/one" => 3,
             "http://stream.test:#{port}/two" => 3
           }
  end

  test "a stream that outlives its pin keeps the connection it opened" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)
    test = self()

    # Answers the head and a first chunk at once, and the rest only when
    # the test says so.
    server =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen, 10_000)
        _ = :gen_tcp.recv(sock, 0, 5_000)

        :ok =
          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n6\r\nfirst \r\n"
          )

        send(test, :headed)

        receive do
          :rest -> :ok = :gen_tcp.send(sock, "4\r\nlast\r\n0\r\n\r\n")
        end

        receive do
          :done -> :ok
        end
      end)

    host = ScriptedHost.start!()

    ScriptedHost.script(host, "egress_pin", fn args, _caller ->
      {:ok, %{"expires_at" => expires_at}} =
        answer = ScriptedHost.pin(%{"stream.test" => "127.0.0.1"}, args, 1_500)

      send(test, {:expires_at, expires_at})
      answer
    end)

    ns = relayed_streams(host)
    {:fn, read} = ns["read"]
    handle = open(ns, "http://stream.test:#{port}/long")
    assert_receive :headed, 10_000

    # Every pin the stream was answered, when it opened, before its send
    # and the relay's own, is past its expires_at before the rest of the
    # answer is sent.
    latest =
      for _pin <- 1..3 do
        assert_received {:expires_at, expires_at}
        expires_at
      end
      |> Enum.max()

    wait_until(fn -> System.system_time(:millisecond) > latest end, 5_000, "the pins to expire")
    send(server, :rest)

    assert read_all(read, handle) == "first last"
    send(server, :done)
  end

  test "a malformed request is a typed error, not a raise" do
    {ns, _ref} = imports()

    for bad <- ["not json", "{", Jason.encode!(%{"url" => 42}), Jason.encode!([1, 2, 3])] do
      result = call(ns, "request", bad)
      assert is_binary(result), "request/1 did not answer a string for #{inspect(bad)}"
      assert %{"error" => _} = Jason.decode!(result)
    end
  end

  test "read and close answer for handles that do not exist" do
    {ns, _ref} = imports()

    assert %{"error" => _} = ns |> call("read", "nope") |> Jason.decode!()
    assert %{"ok" => true} = ns |> call("close", "nope") |> Jason.decode!()
  end

  test "a non-string handle does not raise either" do
    {ns, _ref} = imports()

    for bad <- [42, nil, %{"a" => 1}] do
      assert is_binary(call(ns, "read", bad)), "read/1 raised for #{inspect(bad)}"
      assert is_binary(call(ns, "close", bad)), "close/1 raised for #{inspect(bad)}"
    end
  end

  test "the streaming task supervisor being down is a refusal, not a fault" do
    # `Task.Supervisor.start_child/2` answers `{:error, …}` rather than
    # raising, and the hard match turned that into a MatchError inside the
    # host function. Simulated by asking for a stream while the supervisor is
    # not there to take it.
    {ns, _ref} = imports()

    request =
      Jason.encode!(%{
        "url" => "https://example.invalid/stream",
        "method" => "GET"
      })

    result = call(ns, "request", request)

    assert is_binary(result)
    assert %{"error" => _} = Jason.decode!(result)
  end
end
