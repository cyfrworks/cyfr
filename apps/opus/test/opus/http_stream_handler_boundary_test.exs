# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HttpStreamHandlerBoundaryTest do
  @moduledoc """
  The streaming imports keep the promise every host import keeps: a host
  function never raises into WASM. A malformed request, a handle that does
  not exist and a stream that cannot be started each answer the guest a
  typed error, with a host client that holds no context of its own. A
  stream's address is pinned when it opens: a stream that outlives its pin
  keeps the connection it opened, and a stream opened past the pin's
  `expires_at` is pinned again.
  """
  use ExUnit.Case, async: true

  alias Opus.HttpStreamHandler
  alias Opus.Test.ScriptedHost

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

  test "a stream that outlives its pin keeps its connection; one opened past it is pinned again" do
    server =
      start_supervised!({Bandit, plug: Upstream, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    host = ScriptedHost.start!()
    ref = "catalyst:local.streamer:0.1.0"
    client = ScriptedHost.attempt!(host, component_ref: ref).client
    edge = Opus.Test.EdgeFixtures.edge(domains: ["stream.test"], methods: ["GET"])

    {imports, exec_ref} =
      HttpStreamHandler.build_stream_imports(edge, Prima.Limits.defaults(:catalyst), client, ref)

    on_exit(fn -> HttpStreamHandler.cleanup_registry(exec_ref) end)
    ns = imports["cyfr:http/streaming@0.1.0"]
    {:fn, read} = ns["read"]

    open = fn path ->
      request = Jason.encode!(%{"method" => "GET", "url" => "http://stream.test:#{port}#{path}"})
      assert %{"handle" => handle} = ns |> call("request", request) |> Jason.decode!()
      handle
    end

    pins = fn -> length(ScriptedHost.requests(host, "egress_pin")) end

    # A pin already past its expires_at when it is answered: its own
    # stream connects with it, and the next stream asks again.
    ScriptedHost.pins(host, %{"stream.test" => "127.0.0.1"}, expires_in: -1)
    first = open.("/one")
    second = open.("/two")
    assert pins.() == 2

    for %{args: args} <- ScriptedHost.requests(host, "egress_pin"),
        do: assert(args["purpose"] == "stream")

    # The first stream outlived its pin, and reads to its end all the same.
    assert read_all(read, first) == "streamed /one"
    assert read_all(read, second) == "streamed /two"
    call(ns, "close", first)
    call(ns, "close", second)

    # A pin that holds is the next stream's too.
    ScriptedHost.pins(host, %{"stream.test" => "127.0.0.1"}, expires_in: 60_000)
    third = open.("/three")
    fourth = open.("/four")
    assert pins.() == 3
    assert read_all(read, third) == "streamed /three"
    assert read_all(read, fourth) == "streamed /four"
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
