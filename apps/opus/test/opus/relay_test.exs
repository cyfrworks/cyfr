# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.RelayTest do
  @moduledoc """
  A runner's relay (`Opus.Relay`, `Opus.Relay.Runner`), joined in this VM
  to a scripted host: the service's end verifies each host call a runner
  hands it under the attempt's keys and posts it unchanged, naming the
  service's runner id; it refuses, closing the channel, a frame for an
  attempt the channel does not carry, a header naming another runner or
  signed under another attempt's key, a `take_rate` of the runner's own,
  a fetch naming a pin CYFR never granted to the frame's attempt and a
  frame past the relay's bound. A child CYFR admits is carried, with pins
  of its own. A fetch through a granted pin connects to the pinned address
  after the relay takes the rate itself, is checked again against the
  attempt's edge and limits, and streams back never past the runner's
  credit: a slow runner holds the service waiting, and the attempt's
  deadline ends the fetch and closes the upstream connection. Neither end
  shows an attempt's keys in its status.
  """

  use ExUnit.Case, async: true

  alias Prima.{Assignment, RunnerRelay, WorkerAuth, WorkerWire}
  alias Opus.{Egress, HostClient}
  alias Opus.Relay.Runner, as: Endpoint
  alias Opus.Test.{EdgeFixtures, ScriptedHost, ScriptedKeeper}

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

  setup do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, %{"api.test" => "127.0.0.1"})
    {:ok, host: host}
  end

  defp attempt!(host, opts \\ []) do
    edge = Keyword.get(opts, :edge, EdgeFixtures.edge(domains: ["api.test"], methods: ["GET"]))
    limits = Keyword.get(opts, :limits, EdgeFixtures.limits())

    ScriptedHost.attempt!(
      host,
      [component_ref: @ref, authority: ScriptedKeeper.authority(edge, limits)] ++
        Keyword.drop(opts, [:edge, :limits])
    )
  end

  defp upstream! do
    server =
      start_supervised!(
        {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  # The service's end alone, bound to `attempt`, writing what it sends the
  # runner to the test as `{:to_runner, bytes}`: the test plays the runner.
  defp service_end!(host, attempt, runner \\ nil) do
    test = self()

    relay =
      start_supervised!(
        {Opus.Relay,
         runner: runner || attempt.runner,
         write: fn data ->
           send(test, {:to_runner, IO.iodata_to_binary(data)})
           :ok
         end},
        id: make_ref()
      )

    :ok =
      Opus.Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: host.url
      })

    relay
  end

  # A host call as a runner signs and seals it, under `keys`, naming
  # `fields` over the attempt's own.
  defp signed_call(attempt, op, args, fields \\ %{}, keys \\ nil) do
    keys = keys || attempt.keys
    {:ok, assignment} = Assignment.read(attempt.assignment)

    call =
      keys.attempt
      |> Map.merge(%{
        boot: attempt.boot,
        runner: attempt.runner,
        member: assignment.member,
        ts: System.system_time(:millisecond),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })
      |> Map.merge(fields)

    json = Jason.encode!(WorkerWire.request_body(op, args))
    {:ok, sealed} = WorkerAuth.seal_call(keys.seal, :body, call, json)
    {:ok, header} = WorkerAuth.host_call_header(keys.call, call, sealed)
    %{kind: :host_call, attempt: attempt.attempt, op: op, header: header, body: sealed}
  end

  defp frame_bytes(channel, frame) do
    {:ok, bytes, channel} = RunnerRelay.encode(channel, frame)
    {IO.iodata_to_binary(bytes), channel}
  end

  # The service's end closes the channel for `reason`: the runner hears a
  # `close` naming it, and the process stops.
  defp assert_closed(relay, attempt, reason) do
    monitor = Process.monitor(relay)
    assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:closed, ^reason}}}, 5_000
    assert_receive {:to_runner, bytes}, 1_000
    runner = RunnerRelay.new(:runner, attempt.attempt)
    assert {:ok, [%{kind: :close, reason: code}], "", _} = RunnerRelay.decode(runner, bytes)
    assert code == RunnerRelay.close_code(reason)
  end

  # A fetch's events to its end, and why it ended; each chunk is granted
  # back as it is read, as a runner's handlers grant it, unless `grant` is
  # false: a runner that reads nothing.
  defp events(endpoint, ref, grant \\ true, acc \\ []) do
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

  defp body_of(events) do
    Enum.map_join(events, fn
      {:head, _status, _headers, body} -> body
      {:chunk, body} -> body
    end)
  end

  describe "host calls" do
    test "are posted by the service, unchanged, naming the service's runner", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      assert {:ok, %{}} = HostClient.attach(attempt.client, attempt.assignment)
      assert {:ok, _renewals} = HostClient.renew(attempt.client, [attempt.attempt])

      assert [%{caller: %{runner: runner, attempt: id}}] = ScriptedHost.requests(host, "attach")
      assert runner == attempt.runner and id == attempt.attempt
      assert [%{caller: %{runner: ^runner}}] = ScriptedHost.requests(host, "renew")
    end

    test "a frame for an attempt the channel does not carry closes it", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)
      other = attempt!(host)

      {bytes, _} =
        frame_bytes(
          RunnerRelay.new(:runner, other.attempt),
          signed_call(other, :renew, %{"attempts" => []})
        )

      Opus.Relay.deliver(relay, bytes)
      assert_closed(relay, attempt, :unknown_attempt)
      assert ScriptedHost.requests(host) == []
    end

    test "a header naming another runner than the service's closes the channel", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt, "runner_the_service_started")
      frame = signed_call(attempt, :renew, %{"attempts" => [attempt.attempt]})
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      Opus.Relay.deliver(relay, bytes)
      assert_closed(relay, attempt, :runner_mismatch)
      assert ScriptedHost.requests(host) == []
    end

    test "a header signed under another attempt's key, or naming another boot, closes it", %{
      host: host
    } do
      attempt = attempt!(host)
      stranger = attempt!(host)

      for {frame, reason} <- [
            {signed_call(attempt, :renew, %{"attempts" => []}, %{}, %{
               stranger.keys
               | attempt: attempt.keys.attempt
             }), :bad_mac},
            {signed_call(attempt, :renew, %{"attempts" => []}, %{boot: "boot_elsewhere"}),
             :boot_mismatch}
          ] do
        relay = service_end!(host, attempt)
        {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)
        Opus.Relay.deliver(relay, bytes)
        assert_closed(relay, attempt, reason)
      end

      assert ScriptedHost.requests(host) == []
    end

    test "a runner's own take_rate is refused: the rate is the service's to take", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)
      frame = signed_call(attempt, :take_rate, %{"bucket" => "http:" <> @ref})
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      Opus.Relay.deliver(relay, bytes)
      assert_closed(relay, attempt, :take_rate)
      assert ScriptedHost.requests(host, "take_rate") == []
    end

    test "a body that is not the frame's operation closes the channel", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)
      frame = %{signed_call(attempt, :renew, %{"attempts" => []}) | op: :attach}
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      Opus.Relay.deliver(relay, bytes)
      assert_closed(relay, attempt, :malformed_call)
    end

    test "a frame past the relay's bound closes the channel as soon as its length is in", %{
      host: host
    } do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)

      Opus.Relay.deliver(relay, <<RunnerRelay.max_frame_bytes() + 1::32>>)
      assert_closed(relay, attempt, :frame_too_large)
    end

    test "a child CYFR admits is carried, with calls and pins of its own", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      child = attempt!(host, boot: attempt.boot)
      {:ok, sealed} = WorkerAuth.seal_attempt_keys(attempt.keys.seal, child.keys)

      ScriptedHost.script(host, "admit_child", fn _args, _caller ->
        {:ok,
         %{
           "assignment" => child.assignment,
           "attempt_keys" => sealed,
           "input" => child.input,
           "secrets" => %{}
         }}
      end)

      assert {:ok, admitted} =
               HostClient.admit_child(attempt.client, @ref, nil, %{"fixture" => true}, :call)

      assert {:ok, %{}} = HostClient.attach(admitted.client, admitted.token)

      assert [%{caller: %{attempt: child_attempt, runner: runner}}] =
               ScriptedHost.requests(host, "attach")

      assert child_attempt == child.attempt and runner == attempt.runner

      # A pin CYFR granted the parent is not the child's.
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test/x")
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 child.attempt,
                 pinned.target.id,
                 "GET",
                 "/x",
                 [],
                 ""
               )

      assert_receive {Endpoint, ^ref, {:end, "relay_closed"}}, 5_000

      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:closed, :unknown_pin}}},
                     5_000
    end
  end

  describe "fetches" do
    test "go to the pinned address, the rate taken by the service first", %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/hello?q=1",
                 [{"x-trace", "t"}],
                 ""
               )

      {events, nil} = events(attempt.endpoint, ref)
      assert [{:head, 200, headers, _} | _] = events
      assert Enum.any?(headers, fn {name, _} -> name == "content-length" end)
      assert body_of(events) == "reached /hello"

      assert_received {:upstream, "GET", "/hello", upstream_headers}
      assert {"host", "api.test:#{port}"} in upstream_headers
      assert {"x-trace", "t"} in upstream_headers

      assert [%{args: %{"bucket" => bucket}, caller: %{runner: runner}}] =
               ScriptedHost.requests(host, "take_rate")

      assert bucket == "http:" <> @ref and runner == attempt.runner
    end

    test "a pin CYFR never granted closes the channel", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, "pin_never", "GET", "/", [], "")

      assert_receive {Endpoint, ^ref, {:end, "relay_closed"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:closed, :unknown_pin}}}, 5_000
      # Nothing more crosses the closed channel.
      assert {:error, :lost} = HostClient.attach(attempt.client, attempt.assignment)
      assert ScriptedHost.requests(host, "attach") == []
    end

    test "a rate the host refuses ends the fetch before any connection", %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      ScriptedHost.script(host, "take_rate", {:error, {:guest_error, "rate_limited", "no"}})
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/x",
                 [],
                 ""
               )

      assert {[], "rate_limited"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
    end

    test "the attempt's edge and limits are checked again, outside the runner", %{host: host} do
      port = upstream!()

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_request_size: 64))
        |> ScriptedKeeper.relayed!()

      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")
      pin = pinned.target.id

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, pin, "POST", "/x", [], "")

      assert {[], "method_blocked"} = events(attempt.endpoint, ref)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin,
                 "GET",
                 "/x",
                 [],
                 String.duplicate("a", 100)
               )

      assert {[], "request_too_large"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []
    end

    test "an answer past the attempt's max_response_size ends the fetch", %{host: host} do
      port = upstream!()

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 4))
        |> ScriptedKeeper.relayed!()

      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/long")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/long",
                 [],
                 ""
               )

      {events, "response_too_large"} = events(attempt.endpoint, ref)
      assert byte_size(body_of(events)) <= 4
    end

    test "a body past one credit window completes as the runner grants credit", %{host: host} do
      size = RunnerRelay.initial_credit() * 2 + 12_345
      {port, _server} = big_upstream!(size)

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 4 * size))
        |> ScriptedKeeper.relayed!()

      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/big")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/big",
                 [],
                 ""
               )

      assert read_granting(attempt.endpoint, ref, 0) == size
    end

    test "a slow runner holds the service at its credit until the deadline, which closes the upstream",
         %{host: host} do
      size = RunnerRelay.initial_credit() * 6
      {port, server} = big_upstream!(size)

      attempt =
        attempt!(host,
          timeout_ms: 1_500,
          limits: EdgeFixtures.limits(max_response_size: 2 * size)
        )
        |> ScriptedKeeper.relayed!()

      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/big")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/big",
                 [],
                 ""
               )

      # Nothing is granted: the service sends one window and waits.
      Process.sleep(500)

      assert Opus.Relay.bind(attempt.relay, %{
               assignment: attempt.assignment,
               keys: attempt.keys,
               host_url: host.url
             }) == {:error, :busy}

      {events, "timeout"} = events(attempt.endpoint, ref, false)
      assert byte_size(body_of(events)) == RunnerRelay.initial_credit()
      assert_receive {:upstream_closed, ^server}, 5_000
    end
  end

  test "neither end shows an attempt's keys in its status", %{host: host} do
    attempt = attempt!(host) |> ScriptedKeeper.relayed!()
    assert {:ok, %{}} = HostClient.attach(attempt.client, attempt.assignment)

    for process <- [attempt.relay, attempt.endpoint],
        key <- [attempt.keys.call, attempt.keys.seal] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
    end
  end

  # An upstream answering one request with `size` bytes, telling the test
  # when its connection is closed under it.
  defp big_upstream!(size) do
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
        Process.sleep(5_000)
      end)

    on_exit(fn -> :gen_tcp.close(listen) end)
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
  defp read_granting(endpoint, ref, total) do
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
