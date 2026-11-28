# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RelayTest do
  @moduledoc """
  The service's end of a runner's relay (`Locus.Runtime.Relay`), joined
  in this VM to the test's scripted runner end
  (`Locus.Runtime.Test.RunnerEnd`) and to a scripted host: it verifies
  each host call a runner hands it under the attempt's keys and posts it
  unchanged, naming the service's runner id; it refuses, closing the
  channel, a frame for an attempt the channel does not carry, each call
  `tests/fixtures/runner_relay.json`'s `call_checks` refuse, in the order
  they are decided, a fetch naming a pin CYFR never granted to the
  frame's attempt and a frame past the relay's bound, and answers CYFR's
  413 to a runner's call as that status. A child CYFR admits is carried, with pins
  of its own. A granted pin serves one fetch, and only before its
  `expires_at`: a fetch naming it again closes the channel, and a stream
  it opened is read on past it. A fetch
  through a granted pin is checked again against the attempt's edge and
  limits, taken from the rate by the relay itself, then decided by CYFR
  again as it leaves — the relay asks `egress_pin` itself, as the runner
  asked it, and connects only to the address of that answer, so a host
  CYFR refuses since the runner's pin, an answer naming another target and
  a lost answer each end the fetch with nothing connected, and an answer
  naming a metadata address ends it `private_ip_blocked`, nothing
  connected either. The answer
  streams back never past the runner's credit: a slow runner holds the
  service waiting, and the attempt's deadline ends the fetch and closes
  the upstream connection. A fetch's wait for its answer ends at its
  node's consented timeout when that comes before the deadline. The
  service's end shows none of an attempt's keys in its status.

  A fetch naming a connection is posted by the service as the host call
  `attached_fetch`, taking no rate and asking no pin, after the attempt's
  edge and limits are checked again; CYFR's sealed frames are relayed
  unopened, never past the runner's credit nor the attempt's
  `max_response_size`, and its refusal before admission is relayed as
  the answer to the fetch's own call, its `unavailable` among them, which
  reads as no answer.
  """

  use ExUnit.Case, async: true

  import Prima.Test.Wait

  alias Prima.{Assignment, AttachedRequest, RunnerRelay, WorkerAuth, WorkerWire}
  alias Locus.Runtime.Test.RunnerEnd, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, RelayFixtures, ScriptedHost, ScriptedKeeper}

  import RelayFixtures

  @ref RelayFixtures.component_ref()

  @call_checks Path.expand("../../../../../tests/fixtures/runner_relay.json", __DIR__)
               |> File.read!()
               |> Jason.decode!()
               |> Map.fetch!("call_checks")
  @call_cases Map.fetch!(@call_checks, "cases")
  @call_request_bound Map.fetch!(@call_checks, "max_request_size")

  defmodule HeldUpstream do
    @moduledoc false
    # A loopback upstream that streams its head and a first piece, then
    # holds its answer open until the test says, and ends it with a last.
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "first ")
      send(test, {:holding, self()})

      receive do
        :more -> :ok
      after
        30_000 -> :ok
      end

      {:ok, conn} = Plug.Conn.chunk(conn, "last")
      conn
    end
  end

  @doc false
  # Each connection the HTTP client opens, told to the test that attached it.
  def connecting(_event, _measurements, %{host: host, port: port}, test),
    do: send(test, {:connecting, host, port})

  setup do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, %{"api.test" => "127.0.0.1"})
    {:ok, host: host}
  end

  # The service's end alone, bound to `attempt`, writing what it sends the
  # runner to the test as `{:to_runner, bytes}`: the test plays the runner.
  defp service_end!(host, attempt, runner \\ nil) do
    test = self()

    relay =
      start_supervised!(
        {Locus.Runtime.Relay,
         runner: runner || attempt.runner,
         write: fn data ->
           send(test, {:to_runner, IO.iodata_to_binary(data)})
           :ok
         end},
        id: make_ref()
      )

    :ok =
      Locus.Runtime.Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: host.url
      })

    relay
  end

  # A case of runner_relay.json's call_checks as a runner sends it, and
  # the plaintext its body seals: the
  # header signed under the attempt's call key (another for `call_key`
  # other) over the attempt's own fields with the case's `fields` over
  # them, its ts `ts_ms` from now; the body `op`'s request body of `args`
  # (or `plaintext`), sealed under the attempt's seal key (another for
  # `seal_key` other) over the header's fields with `seal_fields` over
  # them; the header naming another sealing of it for `body_hash` other,
  # or the case's `header` text in its place; the frame naming `frame_op`
  # where the case gives one.
  defp checked_call(attempt, check) do
    {:ok, assignment} = Assignment.read(attempt.assignment)
    other = &(check[&1] == "other")
    call_key = if other.("call_key"), do: :crypto.strong_rand_bytes(32), else: attempt.keys.call
    seal_key = if other.("seal_key"), do: :crypto.strong_rand_bytes(32), else: attempt.keys.seal
    op = String.to_existing_atom(check["op"])

    fields =
      attempt.keys.attempt
      |> Map.merge(%{
        boot: attempt.boot,
        runner: attempt.runner,
        member: assignment.member,
        ts: System.system_time(:millisecond) + Map.get(check, "ts_ms", 0),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })
      |> Map.merge(atoms(check["fields"]))

    sealed_under = Map.merge(fields, atoms(check["seal_fields"]))
    plaintext = check["plaintext"] || Jason.encode!(WorkerWire.request_body(op, check["args"]))
    {:ok, body} = WorkerAuth.seal_call(seal_key, :body, sealed_under, plaintext)

    {:ok, named} =
      if other.("body_hash"),
        do: WorkerAuth.seal_call(seal_key, :body, sealed_under, plaintext),
        else: {:ok, body}

    {:ok, header} = WorkerAuth.host_call_header(call_key, fields, named)

    {%{
       kind: :host_call,
       attempt: attempt.attempt,
       op: String.to_existing_atom(check["frame_op"] || check["op"]),
       header: check["header"] || header,
       body: body
     }, plaintext}
  end

  defp atoms(nil), do: %{}

  defp atoms(fields),
    do: Map.new(fields, fn {name, value} -> {String.to_existing_atom(name), value} end)

  # `count` frames the service writes the runner, read on the runner's
  # `channel`, which sent the calls they answer.
  defp answers!(channel, count, why, read \\ []) do
    if length(read) >= count do
      read
    else
      assert_receive {:to_runner, bytes}, 5_000, why
      {:ok, frames, "", channel} = RunnerRelay.decode(channel, bytes)
      assert Enum.all?(frames, &(&1.kind == :host_answer)), why
      answers!(channel, count, why, read ++ frames)
    end
  end

  # A request the host saw, as its operation, args, header and body, or as
  # it refused it.
  defp posted(%{op: op, args: args, header: header, body: body}), do: {op, args, header, body}
  defp posted(refused), do: refused

  defp frame_bytes(channel, frame) do
    {:ok, bytes, channel} = RunnerRelay.encode(channel, frame)
    {IO.iodata_to_binary(bytes), channel}
  end

  # `bytes` delivered to the service's end close the channel for `reason`:
  # the runner hears a `close` naming it, and the process stops. The
  # monitor is taken before the bytes go in: a refusal read from a frame's
  # length alone stops the relay before the test's next call, and a
  # monitor taken after it would see only `:noproc`.
  defp assert_closes(relay, bytes, attempt, reason) do
    monitor = Process.monitor(relay)
    Locus.Runtime.Relay.deliver(relay, bytes)
    assert_receive {:DOWN, ^monitor, :process, ^relay, {:shutdown, {:closed, ^reason}}}, 5_000
    assert_receive {:to_runner, bytes}, 1_000
    runner = RunnerRelay.new(:runner, attempt.attempt)
    assert {:ok, [%{kind: :close, reason: code}], "", _} = RunnerRelay.decode(runner, bytes)
    assert code == RunnerRelay.close_code(reason)
  end

  describe "host calls" do
    test "are posted by the service, unchanged, naming the service's runner", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      assert {:ok, %{}} = call(attempt, :attach, %{"assignment" => attempt.assignment})
      assert {:ok, %{}} = call(attempt, :renew, %{"attempts" => [attempt.attempt]})

      assert [%{caller: %{runner: runner, attempt: id}}] = ScriptedHost.requests(host, "attach")
      assert runner == attempt.runner and id == attempt.attempt
      assert [%{caller: %{runner: ^runner}}] = ScriptedHost.requests(host, "renew")
    end

    test "CYFR's 413 crosses to the runner as that status, posted once, whatever its body", %{
      host: host
    } do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      over = String.duplicate("x", Prima.HostAPI.max_answer_bytes() + 1)

      for {body, posted} <- [{~s({"v":3,"error":"lost"}), 1}, {over, 2}] do
        ScriptedHost.script(host, "renew", {:raw, 413, body})
        assert {:status, 413} = call(attempt, :renew, %{"attempts" => [attempt.attempt]})
        assert length(ScriptedHost.requests(host, "renew")) == posted
      end
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

      assert_closes(relay, bytes, attempt, :unknown_attempt)
      assert ScriptedHost.requests(host) == []
    end

    # Each case is played on a host and a relay of its own, its attempt
    # bound to the section's max_request_size: the calls `unanswered`
    # before it and the case's own, sent `sent` times, go in as one
    # delivery, so the relay reads the case's call with every call before
    # it posted and none answered.
    test "decides every call check of the vectors as the vectors decide it" do
      assert length(@call_cases) == 44
      limits = EdgeFixtures.limits(max_request_size: @call_request_bound)

      for check <- @call_cases do
        # A case is its members and no other: a marker or member a case
        # does not take fails here.
        assert Map.keys(check) --
                 ~w(why relay op args reason fields ts_ms call_key seal_key seal_fields plaintext header body_hash frame_op unanswered sent) ==
                 [],
               inspect(check)

        %{"why" => why, "relay" => true, "op" => op, "args" => args, "reason" => reason} = check
        host = ScriptedHost.start!()

        # Each op the cases post is answered with a value naming it, which
        # the runner is handed as CYFR sealed it.
        for posted <- ~w(renew push_deltas),
            do:
              ScriptedHost.script(host, posted, fn _args, _caller -> {:ok, %{"op" => posted}} end)

        attempt = attempt!(host, limits: limits)
        relay = service_end!(host, attempt)
        unanswered = Map.get(check, "unanswered", 0)
        renew = Jason.encode!(WorkerWire.request_body(:renew, %{"attempts" => []}))

        before =
          for _ <- 1..unanswered//1,
              do:
                {signed_call(attempt, :renew, %{"attempts" => []}),
                 {"renew", %{"attempts" => []}, renew}}

        {frame, plaintext} = checked_call(attempt, check)
        own = {frame, {op, args, plaintext}}
        frames = before ++ List.duplicate(own, Map.get(check, "sent", 1))

        {sent, channel} =
          Enum.map_reduce(frames, RunnerRelay.new(:runner, attempt.attempt), fn {f, _}, ch ->
            frame_bytes(ch, f)
          end)

        bytes = IO.iodata_to_binary(sent)

        case reason do
          nil ->
            Locus.Runtime.Relay.deliver(relay, bytes)

            seqs =
              for <<size::32, json::binary-size(size)>> <- sent, do: Jason.decode!(json)["seq"]

            by_seq = Map.new(Enum.zip(seqs, frames))
            answers = answers!(channel, length(seqs), why)
            assert Enum.sort(for %{re: re} <- answers, do: re) === Enum.sort(seqs), why

            # Each answer is CYFR's, as the host sealed it for its call.
            for %{re: re, status: status, body: body} <- answers do
              {%{header: header}, {posted_op, _args, _plain}} = Map.fetch!(by_seq, re)
              assert status === 200, why
              now = System.system_time(:millisecond)

              {:ok, fields, _hash} =
                WorkerAuth.verify_host_call_header_under(attempt.keys.call, header, now)

              {:ok, opened} = WorkerAuth.open_call(attempt.keys.seal, :answer, fields, body)
              assert Jason.decode!(opened) === %{"v" => 3, "ok" => %{"op" => posted_op}}, why
            end

            # Each call reached CYFR whole: its op, args, header and body as
            # the runner wrote them.
            assert ScriptedHost.requests(host) |> Enum.map(&posted/1) |> Enum.sort() ===
                     frames
                     |> Enum.map(fn {f, {o, a, plain}} -> {o, a, f.header, plain} end)
                     |> Enum.sort(),
                   why

          reason ->
            assert_closes(relay, bytes, attempt, String.to_existing_atom(reason))

            # Nothing of the case's own call reached CYFR, refused or not;
            # whatever reached it is a call before it, by its header.
            earlier = MapSet.new(before, fn {f, _} -> f.header end)

            for request <- ScriptedHost.requests(host) do
              assert %{header: header} = request, why
              assert MapSet.member?(earlier, header) and header != frame.header, why
            end
        end
      end
    end

    test "a frame past the relay's bound closes the channel as soon as its length is in", %{
      host: host
    } do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)

      assert_closes(relay, <<RunnerRelay.max_frame_bytes() + 1::32>>, attempt, :frame_too_large)
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

      admit = %{
        "reference" => @ref,
        "need" => nil,
        "input" => %{"fixture" => true},
        "guest_fn" => "call",
        "child_key" => Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      }

      # The runner carries the child as it starts it, and presents it as
      # the parent's runner.
      assert {:ok, %{"assignment" => token}} = call(attempt, :admit_child, admit)
      :ok = Endpoint.admit(attempt.endpoint, child.attempt)

      as_parent = Map.merge(child, %{runner: attempt.runner, endpoint: attempt.endpoint})
      assert {:ok, %{}} = call(as_parent, :attach, %{"assignment" => token})

      assert [%{caller: %{attempt: child_attempt, runner: runner}}] =
               ScriptedHost.requests(host, "attach")

      assert child_attempt == child.attempt and runner == attempt.runner

      # A pin CYFR granted the parent is not the child's.
      pin = pin!(attempt, "http://api.test/x")
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 child.attempt,
                 pin.id,
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
      pin = pin!(attempt, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
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

    test "the upstream sees exactly one Host, the pin's host and port, never the guest's",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      # A runner sending the guest's Host and X-Forwarded-Host itself, past
      # the runner's own validation: the relay refuses the fetch.
      pin = pin!(attempt, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/hello",
                 [{"host", "admin.internal"}, {"x-forwarded-host", "admin.internal"}],
                 ""
               )

      assert {[], "invalid_request"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []

      # Without one, the relay sets Host from the pin, port included.
      pin = pin!(attempt, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/hello",
                 [{"x-trace", "t"}],
                 ""
               )

      {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == "reached /hello"
      assert_received {:upstream, "GET", "/hello", upstream_headers}

      assert Enum.filter(upstream_headers, fn {name, _value} -> name == "host" end) ==
               [{"host", "api.test:#{port}"}]
    end

    test "a runner's fetch naming a header that frames, routes or overrides the request ends invalid_request before the rate, nothing connected",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      names = [
        "host",
        "HOST",
        "Content-Length",
        "transfer-encoding",
        "Connection",
        "Forwarded",
        "Via",
        "X-Real-IP",
        "True-Client-IP",
        "X-Forwarded-Host",
        "x-forwarded-for",
        "X-Forwarded-Ssl",
        "X-HTTP-Method-Override",
        "x-original-url"
      ]

      for name <- names do
        pin = pin!(attempt, "http://api.test:#{port}/x")

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pin.id,
                   "GET",
                   "/x",
                   [{"x-trace", "t"}, {name, "admin.internal"}],
                   ""
                 )

        assert {[], "invalid_request"} = events(attempt.endpoint, ref), name
      end

      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []
      # Only the runner's pins were asked: the relay asked none of its own.
      assert length(ScriptedHost.requests(host, "egress_pin")) == length(names)
    end

    test "a POST reaches the pinned host with its body's length and the pin's Host alone",
         %{host: host} do
      port = upstream!()
      edge = EdgeFixtures.edge(domains: ["api.test"], methods: ["POST"])
      attempt = attempt!(host, edge: edge) |> ScriptedKeeper.relayed!()
      pin = pin!(attempt, "http://api.test:#{port}/")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "POST",
                 "/",
                 [],
                 "sample"
               )

      {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == "reached /"
      assert_received {:upstream, "POST", "/", upstream_headers}
      assert {"content-length", "6"} in upstream_headers

      assert Enum.filter(upstream_headers, fn {name, _value} -> name == "host" end) ==
               [{"host", "api.test:#{port}"}]
    end

    test "a pin CYFR never granted closes the channel", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, "pin_never", "GET", "/", [], "")

      assert_receive {Endpoint, ^ref, {:end, "relay_closed"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:closed, :unknown_pin}}}, 5_000
      # Nothing more crosses the closed channel.
      assert {:error, :closed} = call(attempt, :attach, %{"assignment" => attempt.assignment})
      assert ScriptedHost.requests(host, "attach") == []
    end

    test "a pin serves one fetch: a second fetch naming it closes the channel and connects nowhere",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      pin = pin!(attempt, "http://api.test:#{port}/once")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/once",
                 [],
                 ""
               )

      assert {_events, nil} = events(attempt.endpoint, ref)
      assert_received {:upstream, "GET", "/once", _headers}
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/twice",
                 [],
                 ""
               )

      assert_receive {Endpoint, ^ref, {:end, "relay_closed"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:closed, :unknown_pin}}}, 5_000
      refute_received {:upstream, _, "/twice", _}
      assert [_once] = ScriptedHost.requests(host, "take_rate")
    end

    test "a pin a refused fetch named is spent all the same", %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      pin = pin!(attempt, "http://api.test:#{port}/x")

      fetch =
        &Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, &1, "/x", [], "")

      assert {:ok, ref} = fetch.("POST")
      assert {[], "method_blocked"} = events(attempt.endpoint, ref)
      monitor = Process.monitor(attempt.relay)

      assert {:ok, ref} = fetch.("GET")
      assert_receive {Endpoint, ^ref, {:end, "relay_closed"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, {:closed, :unknown_pin}}}, 5_000
      refute_received {:upstream, _, _, _}
    end

    test "a pin past its expires_at is refused before the rate, and nothing is asked or connected",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      ScriptedHost.pins(host, %{"api.test" => "127.0.0.1"}, expires_in: -1)
      pin = pin!(attempt, "http://api.test:#{port}/late")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/late",
                 [],
                 ""
               )

      assert {[], "pin_expired"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []
      assert [_runner_ask] = ScriptedHost.requests(host, "egress_pin")
    end

    test "CYFR decides the send itself, after the rate: a host it refuses since the runner's pin connects nowhere",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      # The runner's pin is taken first; by the send, CYFR refuses the host.
      ScriptedHost.script(host, "egress_pin", [
        fn args, _caller -> ScriptedHost.pin(%{"api.test" => "127.0.0.1"}, args, 30_000) end,
        {:error, :denied}
      ])

      url = "http://api.test:#{port}/send?q=1"
      pin = pin!(attempt, url)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/send?q=1",
                 [],
                 ""
               )

      assert {[], "pin_denied"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}

      # Asked for the request's own URL and purpose, presenting as the
      # runner under the attempt's keys, once the rate was taken.
      assert [_runner_ask, relay_ask] = ScriptedHost.requests(host, "egress_pin")
      assert relay_ask.args == %{"url" => url, "purpose" => "fetch"}
      assert relay_ask.caller.runner == attempt.runner
      assert relay_ask.caller.attempt == attempt.attempt

      assert for(%{op: op} <- ScriptedHost.requests(host), op in ~w(egress_pin take_rate), do: op) ==
               ~w(egress_pin take_rate egress_pin)
    end

    test "the connection goes to the address of the relay's own answer, never the runner's pin's",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      # The runner's pin names a loopback address nothing listens on; the
      # answer to the relay's own ask names the upstream's.
      ScriptedHost.script(host, "egress_pin", [
        fn args, _caller -> ScriptedHost.pin(%{"api.test" => "127.0.0.2"}, args, 30_000) end,
        fn args, _caller -> ScriptedHost.pin(%{"api.test" => "127.0.0.1"}, args, 30_000) end
      ])

      assert %{ip: "127.0.0.2"} = pin = pin!(attempt, "http://api.test:#{port}/fresh")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/fresh",
                 [],
                 ""
               )

      {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == "reached /fresh"
      assert_received {:upstream, "GET", "/fresh", _headers}
    end

    test "an answer naming another target, or a lost one, ends the fetch and connects nowhere",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      pin = fn args, _caller -> ScriptedHost.pin(%{"api.test" => "127.0.0.1"}, args, 30_000) end

      elsewhere = fn args, caller ->
        {:ok, wire} = pin.(args, caller)
        {:ok, %{wire | "host" => "elsewhere.test"}}
      end

      # A lost answer is asked once more, and lost again.
      ScriptedHost.script(host, "egress_pin", [pin, elsewhere, pin, :drop, :drop])

      for code <- ["pin_elsewhere", "pin_lost"] do
        pin = pin!(attempt, "http://api.test:#{port}/x")

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pin.id,
                   "GET",
                   "/x",
                   [],
                   ""
                 )

        assert {[], ^code} = events(attempt.endpoint, ref)
      end

      refute_received {:upstream, _, _, _}
    end

    test "a redirect's hop is asked again as the runner asked it, from the pin it came from", %{
      host: host
    } do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      origin_url = "http://api.test:#{port}/start"
      origin = pin!(attempt, origin_url)
      hop = pin!(attempt, "http://api.test:#{port}/moved", purpose: :redirect, from: origin.id)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 hop.id,
                 "GET",
                 "/moved",
                 [],
                 ""
               )

      {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == "reached /moved"

      expected = %{
        "url" => "http://api.test:#{port}/moved",
        "purpose" => "redirect",
        "from" => origin.id
      }

      assert [_origin, %{args: ^expected}, %{args: ^expected}] =
               ScriptedHost.requests(host, "egress_pin")
    end

    test "a rate the host refuses ends the fetch before any connection", %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      ScriptedHost.script(host, "take_rate", {:error, {:guest_error, "rate_limited", "no"}})
      pin = pin!(attempt, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
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

      # Each fetch is a request of its own, pinned for itself.
      pin = pin!(attempt, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "POST",
                 "/x",
                 [],
                 ""
               )

      assert {[], "method_blocked"} = events(attempt.endpoint, ref)
      pin = pin!(attempt, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
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

      pin = pin!(attempt, "http://api.test:#{port}/long")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/long",
                 [],
                 ""
               )

      {events, "response_too_large"} = events(attempt.endpoint, ref)
      assert byte_size(body_of(events)) <= 4
    end

    test "a stream's answer past the attempt's max_response_size ends it, as a fetch's", %{
      host: host
    } do
      port = upstream!()

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 4))
        |> ScriptedKeeper.relayed!()

      pin = pin!(attempt, "http://api.test:#{port}/long", purpose: :stream)

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, "GET", "/long", [], "")

      {events, "response_too_large"} = events(attempt.endpoint, ref)
      assert byte_size(body_of(events)) <= 4

      assert [%{args: %{"purpose" => "stream"}}, %{args: %{"purpose" => "stream"}}] =
               ScriptedHost.requests(host, "egress_pin")
    end

    test "a stream outlives its pin: it is read on past the pin's expires_at to its end", %{
      host: host
    } do
      server =
        start_supervised!(
          {Bandit, plug: {HeldUpstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :held_upstream
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      test = self()

      ScriptedHost.script(host, "egress_pin", fn args, _caller ->
        {:ok, %{"expires_at" => expires_at}} =
          answer = ScriptedHost.pin(%{"api.test" => "127.0.0.1"}, args, 1_000)

        send(test, {:expires_at, expires_at})
        answer
      end)

      pin = pin!(attempt, "http://api.test:#{port}/held", purpose: :stream)
      assert_received {:expires_at, runners}

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, "GET", "/held", [], "")

      assert_receive {:holding, upstream}, 5_000

      # The relay's own pin, asked as it connected, expires after the
      # runner's: both are past their expires_at before the rest is sent.
      assert_received {:expires_at, relays}
      assert relays >= runners
      wait_until(fn -> System.system_time(:millisecond) > relays end, 5_000)
      send(upstream, :more)

      {events, nil} = events(attempt.endpoint, ref)
      assert [{:head, 200, _headers, _body} | _] = events
      assert body_of(events) == "first last"
    end

    test "a pin CYFR grants for a metadata address ends the fetch private_ip_blocked after the " <>
           "rate, and nothing connects",
         %{host: host} do
      port = upstream!()
      id = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(id, [:finch, :connect, :start], &__MODULE__.connecting/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      # The control: a fetch to a pin of a loopback address connects there.
      pin = pin!(attempt, "http://api.test:#{port}/near")

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, "GET", "/near", [], "")

      assert {[_ | _], nil} = events(attempt.endpoint, ref)
      assert_received {:connecting, "127.0.0.1", ^port}

      for ip <- ["169.254.169.254", "fd00:ec2::254"] do
        ScriptedHost.pins(host, %{"api.test" => ip})
        pin = pin!(attempt, "http://api.test:#{port}/meta")
        assert pin.ip == ip

        assert {:ok, ref} =
                 Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, "GET", "/meta", [], "")

        assert {[], "private_ip_blocked"} = events(attempt.endpoint, ref), ip
      end

      # Nothing connected again to the fetches' port, whatever its address.
      refute_received {:connecting, _host, ^port}
      refute_received {:upstream, _, "/meta", _}
      # Each was taken from the rate, and asked of CYFR again by the relay.
      assert length(ScriptedHost.requests(host, "take_rate")) == 3
      assert length(ScriptedHost.requests(host, "egress_pin")) == 6
    end

    test "a runner's stream naming a header that frames, routes or overrides the request ends " <>
           "invalid_request before the rate, nothing connected, as a fetch",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      names = Prima.Network.framing_headers() ++ Prima.Network.override_headers()

      for name <- names, spelled <- [name, String.upcase(name)] do
        pin = pin!(attempt, "http://api.test:#{port}/x", purpose: :stream)

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pin.id,
                   "GET",
                   "/x",
                   [{"accept", "*/*"}, {spelled, "admin.internal"}],
                   ""
                 )

        assert {[], "invalid_request"} = events(attempt.endpoint, ref), spelled
      end

      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []
    end

    test "a body past one credit window completes as the runner grants credit", %{host: host} do
      size = RunnerRelay.initial_credit() * 2 + 12_345
      {port, _server} = big_upstream!(size)

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 4 * size))
        |> ScriptedKeeper.relayed!()

      pin = pin!(attempt, "http://api.test:#{port}/big")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
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

      pin = pin!(attempt, "http://api.test:#{port}/big")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/big",
                 [],
                 ""
               )

      # Nothing is granted: the service sends one window and waits.
      # sleep-ok: 500 ms in which the service, granted nothing, must send no more than its one
      # window
      Process.sleep(500)

      assert Locus.Runtime.Relay.bind(attempt.relay, %{
               assignment: attempt.assignment,
               keys: attempt.keys,
               host_url: host.url
             }) == {:error, :busy}

      {events, "timeout"} = events(attempt.endpoint, ref, false)
      assert byte_size(body_of(events)) == RunnerRelay.initial_credit()
      assert_receive {:upstream_closed, ^server}, 5_000
    end
  end

  # A peer that completes TCP and never speaks: an HTTPS fetch's TLS
  # handshake never finishes, so its connect times out; a plain fetch's
  # request goes out and no answer comes, so its wait for the answer does.
  # Both under a one-second request limit, where the connect's limit and
  # the request's are the same and only the connect's own report tells
  # them apart.
  describe "a fetch to a peer that never speaks" do
    setup do
      # Listening is enough: the kernel completes the handshake from the
      # backlog, and nothing ever reads or writes.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen)
      {:ok, port: port}
    end

    for {scheme, code} <- [{"https", "connect_timeout"}, {"http", "timeout"}] do
      test "over #{scheme} ends #{code}", %{host: host, port: port} do
        attempt =
          attempt!(host, limits: EdgeFixtures.limits(timeout: "1s")) |> ScriptedKeeper.relayed!()

        pin = pin!(attempt, "#{unquote(scheme)}://api.test:#{port}/")

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pin.id,
                   "GET",
                   "/",
                   [],
                   ""
                 )

        assert {[], unquote(code)} = events(attempt.endpoint, ref)
      end
    end

    test "over http ends timeout at its node's consented timeout, long before the attempt's deadline",
         %{host: host, port: port} do
      attempt =
        attempt!(host, timeout_ms: 60_000, limits: EdgeFixtures.limits(timeout: "1s"))
        |> ScriptedKeeper.relayed!()

      pin = pin!(attempt, "http://api.test:#{port}/")
      started = System.monotonic_time(:millisecond)

      assert {:ok, ref} =
               Endpoint.fetch(attempt.endpoint, attempt.attempt, pin.id, "GET", "/", [], "")

      assert_receive {Endpoint, ^ref, {:end, "timeout"}}, 10_000
      assert System.monotonic_time(:millisecond) - started >= 1_000
    end
  end

  describe "attached fetches" do
    test "is posted by the service as the host call attached_fetch, its frames relayed unopened and read by the runner",
         %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      request = attached()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, [{"x-up", "1"}]}, {:chunk, "hello "}, {:chunk, "world"}, :end]}
      )

      assert {:ok, ref} = attached_fetch(attempt, request)

      assert {[{:head, 200, [{"x-up", "1"}], ""}, {:chunk, "hello "}, {:chunk, "world"}], nil} =
               events(attempt.endpoint, ref)

      # Posted once, as the runner, the request member for member; the
      # control plane takes the rate for it, the service none.
      assert [%{args: args, caller: caller}] = ScriptedHost.requests(host, "attached_fetch")
      assert args == AttachedRequest.to_args(request)
      assert caller.runner == attempt.runner and caller.attempt == attempt.attempt
      assert ScriptedHost.requests(host, "take_rate") == []
      wait_until(fn -> Endpoint.idle?(attempt.endpoint) end)
    end

    test "a refusal is taken as the answer to the fetch's own call, naming its call id", %{
      host: host
    } do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      ScriptedHost.script(host, "attached_fetch", [
        {:error, {:guest_error, "destination_mismatch", "Outside the destination."}},
        {:error, :lost}
      ])

      assert {:ok, ref} = attached_fetch(attempt, attached())

      assert {[], {:guest_error, "destination_mismatch", "Outside the destination."}} =
               events(attempt.endpoint, ref)

      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert {[], "lost"} = events(attempt.endpoint, ref)
    end

    test "CYFR's unavailable is no answer of an attached fetch: relayed once to the fetch's own " <>
           "call, it reads as none, and the channel goes idle",
         %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      ScriptedHost.script(host, "attached_fetch", {:error, :unavailable})

      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert {[], "bad_frame"} = events(attempt.endpoint, ref)
      assert [_once] = ScriptedHost.requests(host, "attached_fetch")
      wait_until(fn -> Endpoint.idle?(attempt.endpoint) end)
    end

    test "the attempt's edge and limits are checked again, outside the runner, before any call",
         %{host: host} do
      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_request_size: 64))
        |> ScriptedKeeper.relayed!()

      for {request, code} <- [
            {attached("http://api.test/x", method: "POST"), "method_blocked"},
            {attached("http://elsewhere.test/x"), "domain_blocked"},
            {attached("http://api.test/x", body: String.duplicate("a", 100)), "request_too_large"}
          ] do
        assert {:ok, ref} = attached_fetch(attempt, request)
        assert {[], ^code} = events(attempt.endpoint, ref)
      end

      https_only =
        attempt!(host,
          edge: EdgeFixtures.edge(domains: ["api.test"], methods: ["GET"], schemes: ["https"])
        )
        |> ScriptedKeeper.relayed!()

      assert {:ok, ref} = attached_fetch(https_only, attached("http://api.test/x"))
      assert {[], "scheme_blocked"} = events(https_only.endpoint, ref)

      assert ScriptedHost.requests(host, "attached_fetch") == []
    end

    test "a body past one credit window completes as the runner grants credit", %{host: host} do
      chunks = div(RunnerRelay.initial_credit(), WorkerAuth.max_chunk_bytes()) + 20
      piece = String.duplicate("z", WorkerAuth.max_chunk_bytes())

      attempt =
        attempt!(host,
          limits: EdgeFixtures.limits(max_response_size: 4 * chunks * byte_size(piece))
        )
        |> ScriptedKeeper.relayed!()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}] ++ List.duplicate({:chunk, piece}, chunks) ++ [:end]}
      )

      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert read_granting(attempt.endpoint, ref, 0) == chunks * byte_size(piece)
    end

    test "a runner that grants nothing holds the service at its credit until the deadline", %{
      host: host
    } do
      chunks = div(RunnerRelay.initial_credit(), WorkerAuth.max_chunk_bytes()) + 20
      piece = String.duplicate("z", WorkerAuth.max_chunk_bytes())

      attempt =
        attempt!(host,
          timeout_ms: 1_500,
          limits: EdgeFixtures.limits(max_response_size: 4 * chunks * byte_size(piece))
        )
        |> ScriptedKeeper.relayed!()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}] ++ List.duplicate({:chunk, piece}, chunks) ++ [:end]}
      )

      assert {:ok, ref} = attached_fetch(attempt, attached())
      {events, "timeout"} = events(attempt.endpoint, ref, false)
      body = body_of(events)

      # Never past the credit the runner granted: the body's bytes and
      # each frame's sealing, the head's included.
      assert byte_size(body) < RunnerRelay.initial_credit()
      assert byte_size(body) > RunnerRelay.initial_credit() - 2 * byte_size(piece) - 4_096
    end

    test "the chunks' body is bounded by the attempt's max_response_size", %{host: host} do
      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 8))
        |> ScriptedKeeper.relayed!()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:chunk, "12345"}, {:chunk, "67890"}, :end]}
      )

      assert {:ok, ref} = attached_fetch(attempt, attached())

      assert {[{:head, 200, [], ""}, {:chunk, "12345"}], "response_too_large"} =
               events(attempt.endpoint, ref)
    end

    test "the service's end shows none of the keys while the fetch is held", %{
      host: host
    } do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      test = self()

      ScriptedHost.script(host, "attached_fetch", fn _args, _caller ->
        send(test, {:held, self()})

        receive do
          :go -> {:frames, [{:head, 200, []}, :end]}
        end
      end)

      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert_receive {:held, held}, 5_000

      status = :erlang.term_to_binary(:sys.get_status(attempt.relay))

      for key <- [attempt.keys.call, attempt.keys.seal],
          do: assert(:binary.match(status, key) == :nomatch)

      send(held, :go)
      assert {[{:head, 200, [], ""}], nil} = events(attempt.endpoint, ref)
    end
  end

  test "a frame is written a chunk at a time at most, and the runner reads it whole", %{
    host: host
  } do
    answer = String.duplicate("a", 600_000)
    ScriptedHost.script(host, "tool_call", {:ok, answer})
    attempt = attempt!(host)
    relay = service_end!(host, attempt)
    runner = RunnerRelay.new(:runner, attempt.attempt)
    args = %{"name" => "t", "args" => %{}, "guest_fn" => "call"}
    {bytes, runner} = frame_bytes(runner, signed_call(attempt, :tool_call, args))
    Locus.Runtime.Relay.deliver(relay, bytes)

    read = fn read, parts ->
      assert_receive {:to_runner, part}, 10_000
      parts = parts ++ [part]

      case RunnerRelay.decode(runner, Enum.join(parts)) do
        {:ok, [], _rest, _channel} -> read.(read, parts)
        {:ok, frames, "", _channel} -> {parts, frames}
      end
    end

    {parts, [%{kind: :host_answer, status: 200, body: body}]} = read.(read, [])
    assert byte_size(body) > 262_144
    assert Enum.all?(parts, &(byte_size(&1) <= 262_144)), inspect(Enum.map(parts, &byte_size/1))
  end

  test "a frame of a body holds no more beside it than the runtime's count asks for it" do
    # The longest the channel carries: an attempt id of 256 characters,
    # each one escaped in a frame, and sequence numbers of 16 digits.
    attempt = String.duplicate(~s("), 256)
    far = 9_007_199_254_740_980
    runner = %{RunnerRelay.new(:runner, attempt) | sent: far}
    service = %{RunnerRelay.new(:service, attempt) | received: far, sent: far}
    call_id = fn -> AttachedRequest.call_id(:crypto.strong_rand_bytes(16)) end

    attached = %{
      kind: :fetch,
      attempt: attempt,
      connection: "api_key",
      purpose: "fetch",
      method: "GET",
      url: "https://api.test/x",
      headers: [],
      body: ""
    }

    {sent, _runner} =
      Enum.map_reduce(
        [
          %{kind: :host_call, attempt: attempt, op: :renew, header: "v1 x", body: "b"},
          %{
            kind: :fetch,
            attempt: attempt,
            pin: "pin_x",
            method: "GET",
            path: "/",
            headers: [],
            body: ""
          },
          Map.put(attached, :call_id, call_id.()),
          Map.put(attached, :call_id, call_id.())
        ],
        runner,
        &frame_bytes(&2, &1)
      )

    assert {:ok, [_call, _fetch, _attached, _refused], "", service} =
             RunnerRelay.decode(service, Enum.join(sent))

    header = String.duplicate("x", WorkerAuth.max_host_call_header_bytes())
    body = :crypto.strong_rand_bytes(262_144)
    frame = :crypto.strong_rand_bytes(WorkerAuth.max_frame_bytes())

    # A fetch's head comes before its body, and is not counted.
    {_head, service} =
      frame_bytes(service, %{
        kind: :fetch_chunk,
        attempt: attempt,
        re: far + 1,
        status: 200,
        headers: [],
        body: ""
      })

    written =
      [
        {%{kind: :host_answer, attempt: attempt, re: far, status: 599, body: body}, body, 0},
        {%{
           kind: :fetch_chunk,
           attempt: attempt,
           re: far + 1,
           status: nil,
           headers: nil,
           body: body
         }, body, 0},
        {%{kind: :attached_frame, attempt: attempt, re: far + 2, frame: frame}, frame, 0},
        {%{kind: :attached_refusal, attempt: attempt, re: far + 3, header: header, body: body},
         body, 2 * byte_size(header)}
      ]
      |> Enum.map_reduce(service, fn {frame, held, over}, service ->
        {bytes, service} = frame_bytes(service, frame)
        asked = RunnerRelay.held(byte_size(held), 1) - byte_size(held) + over
        {{frame.kind, byte_size(bytes), asked}, service}
      end)
      |> elem(0)

    for {kind, bytes, asked} <- written do
      assert bytes <= asked,
             "a #{kind} frame of #{bytes} bytes, #{asked} asked for beside its body"
    end
  end

  test "the service's end shows none of an attempt's keys in its status", %{host: host} do
    attempt = attempt!(host) |> ScriptedKeeper.relayed!()
    assert {:ok, %{}} = call(attempt, :attach, %{"assignment" => attempt.assignment})
    status = :erlang.term_to_binary(:sys.get_status(attempt.relay))

    for key <- [attempt.keys.call, attempt.keys.seal],
        do: assert(:binary.match(status, key) == :nomatch)
  end
end

defmodule Locus.Runtime.RelayCountTest do
  @moduledoc """
  What the service's end of a runner's relay holds to answer or send its
  runner (the test's scripted runner end) is counted under the runtime's
  count (`Locus.Output.server(:runtime)`), which these tests fill or read
  whole, so they run alone. A pinned fetch's head and piece and an
  attached fetch's frame are asked for before they are handed on and
  given back once written; a host call's answer is asked for whole as its
  reading begins and freed once written, and the service's own call's
  once it is read. No room by the deadline ends a fetch `timeout`
  with nothing of the piece or frame handed on, and makes a host call's
  answer one that did not arrive: the runner hears no status. A worker
  or a poster killed while it holds frees what it held. Once the relay
  says a piece or an answer is written it holds none of it.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.{Assignment, RunnerRelay, WorkerAuth}
  alias Locus.Runtime.{HostClient, Relay}
  alias Locus.Runtime.Test.RunnerEnd, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, RelayFixtures, ScriptedHost, ScriptedKeeper}

  import RelayFixtures

  @count Locus.Output.server(:runtime)

  # A runner's tool call, as its guest makes one.
  @tool_call %{"name" => "t", "args" => %{}, "guest_fn" => "call"}

  setup do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, %{"api.test" => "127.0.0.1"})
    {:ok, host: host}
  end

  defp answering, do: Locus.Output.held(@count).answering

  # The read size of the one TCP socket `worker` reads.
  defp read_buffer(worker) do
    [socket] =
      for port <- Port.list(),
          Port.info(port, :connected) == {:connected, worker},
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          do: port

    {:ok, [buffer: buffer]} = :inet.getopts(socket, [:buffer])
    buffer
  end

  # The whole bound but `room`, held by the test: nothing else holds any
  # of it.
  defp fill!(room \\ 0) do
    assert %{answering: 0, waiting: 0} = Locus.Output.held(@count)
    bound = Locus.Output.bounds().runtime.answering

    assert {:ok, grant} =
             Locus.Output.reserve(
               @count,
               bound - room,
               System.monotonic_time(:millisecond) + 5_000
             )

    grant
  end

  # The processes beside the relay that hold what it is given: its posters
  # and its fetches' workers, linked to it.
  defp holders(relay) do
    {:links, links} = Process.info(relay, :links)
    {:parent, parent} = Process.info(relay, :parent)
    links -- [parent]
  end

  # The bytes of the host's sealed answer `answer` to one of `attempt`'s
  # calls, as the scripted host seals it: a seal's length is its
  # plaintext's, whatever call it is sealed to.
  defp sealed_bytes(attempt, answer) do
    {:ok, assignment} = Assignment.read(attempt.assignment)

    fields =
      Map.merge(attempt.keys.attempt, %{
        boot: attempt.boot,
        runner: attempt.runner,
        member: assignment.member,
        ts: System.system_time(:millisecond),
        nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      })

    json = Jason.encode!(ScriptedHost.encode(answer))
    {:ok, sealed} = WorkerAuth.seal_call(attempt.keys.seal, :answer, fields, json)
    byte_size(sealed)
  end

  # Whether the relay holds a binary of `bytes` or more.
  defp holds?(relay, bytes) do
    {:binary, binaries} = Process.info(relay, :binary)
    Enum.any?(binaries, fn {_id, size, _refs} -> size >= bytes end)
  end

  # `attempt` with a relay joined in this VM, as `ScriptedKeeper.relayed!/1`
  # joins one, whose service end holds its first write of `gate` bytes or
  # more as a keeper's write that has not returned: the test hears
  # `{:writing, relay, bytes}` and lets it go with `:go`.
  defp gated!(attempt, gate) do
    test = self()
    {:ok, assignment} = Assignment.read(attempt.assignment)
    forwarder = spawn_link(fn -> forward(nil) end)
    endpoint = start_supervised!({Endpoint, relay: {:peer, forwarder}}, id: make_ref())

    write = fn data ->
      bytes = IO.iodata_to_binary(data)

      if byte_size(bytes) >= gate and Process.get({__MODULE__, :gated}) == nil do
        Process.put({__MODULE__, :gated}, true)
        send(test, {:writing, self(), bytes})

        receive do
          :go -> :ok
        end
      end

      send(endpoint, {:relay_in, bytes})
      :ok
    end

    relay = start_supervised!({Relay, runner: attempt.runner, write: write}, id: make_ref())
    send(forwarder, {:to, relay})

    :ok =
      Relay.bind(relay, %{
        assignment: attempt.assignment,
        keys: attempt.keys,
        host_url: assignment.host_url || "http://127.0.0.1:9"
      })

    :ok = Endpoint.bind(endpoint, attempt.attempt)
    Map.merge(attempt, %{relay: relay, endpoint: endpoint})
  end

  defp forward(nil) do
    receive do
      {:to, relay} -> forward(relay)
    end
  end

  defp forward(relay) do
    receive do
      {:relay_in, data} ->
        Relay.deliver(relay, data)
        forward(relay)
    end
  end

  defp pinned_fetch!(attempt, port, path) do
    pin = pin!(attempt, "http://api.test:#{port}#{path}")

    assert {:ok, ref} =
             Endpoint.fetch(
               attempt.endpoint,
               attempt.attempt,
               pin.id,
               "GET",
               path,
               [],
               ""
             )

    ref
  end

  describe "a pinned fetch's piece" do
    test "waits for room, and none by the deadline ends the fetch timeout with nothing of it handed on",
         %{host: host} do
      size = 262_144
      {port, _server} = big_upstream!(size)

      attempt =
        attempt!(host,
          timeout_ms: 1_500,
          limits: EdgeFixtures.limits(max_response_size: 2 * size)
        )
        |> ScriptedKeeper.relayed!()

      # Room for the calls' answers and the head, and none for a piece.
      full = fill!(8_192)
      ref = pinned_fetch!(attempt, port, "/big")

      assert {[{:head, 200, _headers, ""}], "timeout"} = events(attempt.endpoint, ref)

      Locus.Output.return(full)

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end

    test "is counted until the relay has written it, then given back, and the relay keeps none of it",
         %{host: host} do
      size = 3 * 262_144 + 12_345
      {port, _server} = big_upstream!(size)

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 2 * size))
        |> gated!(16_384)

      baseline = answering()
      ref = pinned_fetch!(attempt, port, "/big")

      assert_receive {:writing, relay, base64}, 10_000
      assert answering() > baseline
      assert answering() - baseline >= RunnerRelay.held(byte_size(Base.decode64!(base64)), 1)

      send(relay, :go)
      assert read_granting(attempt.endpoint, ref, 0) == size
      wait_until(fn -> answering() == baseline end)
      refute holds?(relay, 16_384)
    end

    # A fetch's largest body, 50 MiB, comes within a catalyst's 3 minutes
    # over a 300 ms round trip only through a receive window past one
    # 64 KiB read's (`Prima.LocusRoles`, `fetch_read_ahead_bytes`).
    test "reads ahead with room for its read and the queue behind it, and beside them the answer room and its next piece's, asked without waiting and given back at its end, and 64 KiB at a time without",
         %{host: host} do
      size = 3 * 262_144
      ahead = Prima.LocusRoles.role!(:runtime).memory.fetch_read_ahead_bytes
      # Beside the read-ahead, the answers' room and one larger read's
      # piece, in one frame.
      ahead_room = 2 * ahead + RunnerRelay.answer_room() + RunnerRelay.held(ahead, 1)

      for {room, buffer} <- [{nil, ahead}, {ahead_room, ahead}, {ahead_room - 1, 65_536}] do
        {port, _server} = big_upstream!(size)

        attempt =
          attempt!(host, limits: EdgeFixtures.limits(max_response_size: 2 * size))
          |> gated!(16_384)

        full = room && fill!(room)
        baseline = answering()
        ref = pinned_fetch!(attempt, port, "/big")

        assert_receive {:writing, relay, _base64}, 10_000
        assert [worker] = holders(relay)
        assert read_buffer(worker) == buffer
        if buffer == ahead, do: assert(answering() - baseline >= 2 * ahead)

        send(relay, :go)
        assert read_granting(attempt.endpoint, ref, 0) == size
        wait_until(fn -> answering() == baseline end)
        if full, do: Locus.Output.return(full)
      end
    end

    # Read-ahead leaves a larger read's piece room beside the answers': a
    # fetch holding it can always hand its next piece on, and so seven
    # fetches at once hold it, not the eight the answers' room alone
    # would leave, which could each wait on a piece room no read-ahead
    # leaves.
    test "is read ahead for seven fetches at once, and the eighth reads 64 KiB at a time",
         %{host: host} do
      ahead = Prima.LocusRoles.role!(:runtime).memory.fetch_read_ahead_bytes
      {port, handlers} = holding_upstream!(8, :held_call)
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      refs = for _n <- 1..8, do: pinned_fetch!(attempt, port, "/held")
      for handler <- handlers, do: assert_receive({:holding, ^handler}, 10_000)

      buffers = attempt.relay |> holders() |> Enum.map(&read_buffer/1) |> Enum.frequencies()
      assert buffers == %{ahead => 7, 65_536 => 1}

      for handler <- handlers, do: send(handler, :close)
      for ref <- refs, do: assert({_events, _error} = events(attempt.endpoint, ref))

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end

    test "held by a worker killed while it waits is freed", %{host: host} do
      size = 3 * 262_144
      {port, _server} = big_upstream!(size)

      attempt =
        attempt!(host, limits: EdgeFixtures.limits(max_response_size: 2 * size))
        |> gated!(16_384)

      baseline = answering()
      ref = pinned_fetch!(attempt, port, "/big")

      assert_receive {:writing, relay, _base64}, 10_000
      assert answering() > baseline
      assert [worker] = holders(relay)
      Process.exit(worker, :kill)
      wait_until(fn -> answering() == baseline end)

      send(relay, :go)
      assert {_events, "fetch_failed"} = events(attempt.endpoint, ref)
    end
  end

  # A fetch holds its read-ahead while its upstream thinks before it
  # answers, a model's or a feed's call, and for the whole of an answer
  # it streams: 32 of either at the read-ahead's 512 KiB once filled the
  # count, and every host call's answer then waited for room until its
  # window lost it.
  describe "fetches held open" do
    for shape <- [:held_call, :long_stream] do
      test "leave the largest host call answer its room, however many (#{shape})", %{host: host} do
        answer = String.duplicate("a", 3_300_000)
        ScriptedHost.script(host, "tool_call", {:ok, answer})
        {port, handlers} = holding_upstream!(32, unquote(shape))

        # Two runners at the relay's 16 fetches each, every fetch held
        # past the call's window; each runner's fetches are read by a
        # process of their own, since a fetch's ref is its runner's.
        test = self()

        runners =
          for _runner <- 1..2 do
            attempt =
              attempt!(host, timeout_ms: 120_000, limits: EdgeFixtures.limits(timeout: "90s"))
              |> ScriptedKeeper.relayed!()

            reader =
              Task.async(fn ->
                refs = for _n <- 1..16, do: pinned_fetch!(attempt, port, "/held")

                if unquote(shape) == :long_stream,
                  do:
                    for(
                      ref <- refs,
                      do: assert_receive({Endpoint, ^ref, {:head, 200, _, _}}, 10_000)
                    )

                send(test, {:fetching, self()})

                receive do
                  :read -> for ref <- refs, do: events(attempt.endpoint, ref)
                end
              end)

            {attempt, reader}
          end

        for handler <- handlers, do: assert_receive({:holding, ^handler}, 10_000)
        for {_attempt, %{pid: pid}} <- runners, do: assert_receive({:fetching, ^pid}, 10_000)

        [{attempt, _reader} | _] = runners
        call = Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

        assert {:ok, ^answer} =
                 Task.await(call, Prima.HostAPI.request_timeout_ms(:tool_call) + 10_000)

        for handler <- handlers, do: send(handler, :close)

        for {_attempt, reader} <- runners do
          send(reader.pid, :read)
          assert length(Task.await(reader, 30_000)) == 16
        end

        wait_until(fn ->
          Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
            answering: 0,
            waiting: 0
          }
        end)
      end
    end
  end

  # A guest gives a fetch's credit back by reading its stream, so a guest
  # that stops reading keeps, until its attempt's deadline, the piece or
  # frame the relay holds past its credit window, and a pinned fetch its
  # read-ahead beside it.
  describe "guests that stop reading" do
    test "leave the largest host call answer its room, on pinned and attached streams alike",
         %{host: host} do
      credit = RunnerRelay.initial_credit()
      size = credit + 1_048_576
      chunks = div(credit, WorkerAuth.max_chunk_bytes()) + 20
      piece = String.duplicate("z", WorkerAuth.max_chunk_bytes())

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}] ++ List.duplicate({:chunk, piece}, chunks) ++ [:end]}
      )

      limits = EdgeFixtures.limits(timeout: "90s", max_response_size: 4 * size)
      test = self()

      # Three runners of sixteen attached fetches, then, once they hold
      # what a fetch's asks may, two of eight pinned ones: more held past
      # their windows than that, so some fetches wait for room. A pinned
      # fetch's window is sent to the byte, an attached one's to its last
      # whole frame.
      attached = List.duplicate({:attached, 16, credit - 2 * byte_size(piece) - 4_096}, 3)
      pinned = List.duplicate({:pinned, 8, credit}, 2)

      runners =
        for phase <- [attached, pinned], reduce: [] do
          started ->
            runners = started ++ Enum.map(phase, &stop_reading!(host, test, limits, size, &1))
            fetches = runners |> Enum.map(&elem(&1, 2)) |> Enum.sum()

            # Every fetch has read its window or waits for room.
            wait_until(
              fn -> settled(runners) == fetches end,
              60_000,
              "every fetch past its window or waiting for room"
            )

            runners
        end

      [{attempt, _reader, _count} | _] = runners
      answer = largest_answer(attempt)
      ScriptedHost.script(host, "tool_call", {:ok, answer})
      call = Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

      assert {:ok, ^answer} =
               Task.await(call, Prima.HostAPI.request_timeout_ms(:tool_call) + 10_000)

      # Every runner reads again at once: one runner's guests that stop
      # reading hold back the others' fetches until they read or end.
      for {_attempt, reader, _count} <- runners, do: send(reader.pid, :read)

      for {_attempt, reader, _count} <- runners,
          do: assert(reader |> Task.await(60_000) |> Enum.all?(&match?({_events, nil}, &1)))

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end
  end

  # A runner whose `count` fetches of `kind` are read by guests that stop
  # reading once they have `window` bytes: its attempt, the reader and
  # the count.
  defp stop_reading!(host, test, limits, size, {kind, count, window}) do
    attempt = attempt!(host, timeout_ms: 120_000, limits: limits) |> ScriptedKeeper.relayed!()
    ports = if kind == :pinned, do: for(_n <- 1..count, do: elem(big_upstream!(size), 0))

    reader =
      Task.async(fn ->
        refs =
          case kind do
            :pinned ->
              for port <- ports, do: pinned_fetch!(attempt, port, "/big")

            :attached ->
              for _n <- 1..count do
                assert {:ok, ref} = attached_fetch(attempt, attached())
                ref
              end
          end

        unread(test, attempt.endpoint, Map.new(refs, &{&1, 0}), window)
      end)

    {attempt, reader, count}
  end

  # A runner's guests reading their fetches' bodies, granting nothing
  # back, and telling `test` on its word how many have read their window;
  # on `:read`, they grant back what they read and read each fetch to its
  # end, granting as they go: each fetch's events and end.
  defp unread(test, endpoint, read, window) do
    receive do
      {Endpoint, ref, {:head, _status, _headers, body}} when is_map_key(read, ref) ->
        unread(test, endpoint, Map.update!(read, ref, &(&1 + byte_size(body))), window)

      {Endpoint, ref, {:chunk, body}} when is_map_key(read, ref) ->
        unread(test, endpoint, Map.update!(read, ref, &(&1 + byte_size(body))), window)

      {Endpoint, ref, {:end, error}} when is_map_key(read, ref) ->
        flunk("a fetch ended at #{read[ref]} bytes: #{inspect(error)}")

      {:windows, ^test} ->
        send(test, {:windows, self(), for({ref, bytes} <- read, bytes >= window, do: ref)})
        unread(test, endpoint, read, window)

      :read ->
        for {ref, bytes} <- read, do: Endpoint.credit(endpoint, ref, bytes)
        for {ref, _bytes} <- read, do: events(endpoint, ref)
    end
  end

  # How many of the runners' fetches have read their window or wait at
  # the count for room, each counted once: a fetch's asks are its worker's
  # (the relay's `workers`, by the fetch's ref), and a waiting ask is the
  # count's waiter.
  defp settled(runners) do
    waiting = MapSet.new(Map.values(:sys.get_state(@count).waiters), & &1.pid)

    for {attempt, %{pid: pid}, _count} <- runners, reduce: 0 do
      sum ->
        send(pid, {:windows, self()})
        assert_receive {:windows, ^pid, past}, 5_000

        waits =
          for {worker, ref} <- :sys.get_state(attempt.relay).workers,
              MapSet.member?(waiting, worker),
              do: ref

        sum + MapSet.size(MapSet.new(past ++ waits))
    end
  end

  # A tool call's answer as long as a host call's answer may be, sealed
  # for `attempt`: a seal's length grows as the answer's does, by about
  # four bytes for three.
  defp largest_answer(attempt) do
    max = Prima.HostAPI.max_answer_bytes()
    base = 3_000_000
    sealed = sealed_bytes(attempt, {:ok, String.duplicate("a", base)})
    answer = String.duplicate("a", base + div(3 * (max - sealed), 4) - 16)
    assert sealed_bytes(attempt, {:ok, answer}) in (max - 64)..max
    answer
  end

  # An upstream holding each of `n` requests open, with no answer yet
  # (`:held_call`) or with an answer begun (`:long_stream`, a head and
  # its first kilobyte of a megabyte): each connection tells the test
  # `{:holding, handler}` once it holds, and closes on `:close` or when
  # the test ends.
  defp holding_upstream!(n, shape) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: n])
    {:ok, port} = :inet.port(listen)
    test = self()

    handlers =
      for _n <- 1..n do
        spawn(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, 10_000)
          {:ok, _request} = :gen_tcp.recv(sock, 0, 10_000)

          if shape == :long_stream,
            do:
              :ok =
                :gen_tcp.send(sock, [
                  "HTTP/1.1 200 OK\r\ncontent-length: 1048576\r\n\r\n",
                  :binary.copy("s", 1024)
                ])

          send(test, {:holding, self()})

          receive do
            :close -> :gen_tcp.close(sock)
          end
        end)
      end

    on_exit(fn ->
      Enum.each(handlers, &Process.exit(&1, :kill))
      :gen_tcp.close(listen)
    end)

    {port, handlers}
  end

  describe "a pinned fetch's head" do
    test "waits for room before it is handed on, and none by the deadline ends the fetch timeout with no head handed on",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host, timeout_ms: 1_500) |> ScriptedKeeper.relayed!()

      # Room for the pin's answer and other small answers, and none for the head.
      held = fill!(65_536)
      pin = pin!(attempt, "http://api.test:#{port}/wide-head")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pin.id,
                 "GET",
                 "/wide-head",
                 [],
                 ""
               )

      assert {[], "timeout"} = events(attempt.endpoint, ref)

      Locus.Output.return(held)

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end
  end

  describe "the service's own calls' answers" do
    test "wait for room, whole, as their reading begins, and are freed once read", %{host: host} do
      attempt = attempt!(host)
      full = fill!()

      rate = Task.async(fn -> HostClient.take_rate(attempt.client, "http:own") end)
      wait_until(fn -> Locus.Output.held(@count).waiting == 1 end)
      Locus.Output.return(full)
      assert :ok = Task.await(rate, 10_000)

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end
  end

  describe "an attached fetch's frame" do
    test "waits for room, and none by the deadline ends the fetch timeout with nothing of it handed on",
         %{host: host} do
      attempt = attempt!(host, timeout_ms: 1_500) |> ScriptedKeeper.relayed!()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:chunk, "x"}, :end]}
      )

      full = fill!()
      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert {[], "timeout"} = events(attempt.endpoint, ref)

      Locus.Output.return(full)

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end

    test "is counted until the relay has written it, then given back, and the relay keeps none of it",
         %{host: host} do
      piece = String.duplicate("z", WorkerAuth.max_chunk_bytes())

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:chunk, piece}, {:chunk, piece}, :end]}
      )

      attempt = attempt!(host) |> gated!(40_000)
      baseline = answering()
      assert {:ok, ref} = attached_fetch(attempt, attached())

      assert_receive {:writing, relay, base64}, 10_000
      assert answering() > baseline
      assert answering() - baseline == RunnerRelay.held(byte_size(Base.decode64!(base64)), 1)

      send(relay, :go)
      assert {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == piece <> piece
      wait_until(fn -> answering() == baseline end)
      refute holds?(relay, 40_000)
    end
  end

  describe "a host call's answer" do
    test "waits for room, whole, as its reading begins, and none by the call's own deadline is an answer that did not arrive",
         %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      full = fill!()

      # Posted once, its answer finds no room by the call's own timeout:
      # the runner hears no status.
      never = Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

      assert :no_answer =
               Task.await(never, Prima.HostAPI.request_timeout_ms(:tool_call) + 10_000)

      assert [_once] = ScriptedHost.requests(host, "tool_call")

      # One that waits for room is answered once there is room.
      renew = %{"attempts" => [attempt.attempt]}
      waiting = Task.async(fn -> call(attempt, :renew, renew) end)
      wait_until(fn -> Locus.Output.held(@count).waiting == 1 end, 10_000)
      Locus.Output.return(full)

      assert {:ok, %{}} = Task.await(waiting, Prima.HostAPI.request_timeout_ms(:renew) + 10_000)
      assert [_once] = ScriptedHost.requests(host, "renew")
    end

    test "is counted until the relay has written it, then freed as its poster exits, and the relay keeps none of it",
         %{host: host} do
      answer = String.duplicate("a", 600_000)
      ScriptedHost.script(host, "tool_call", {:ok, answer})
      attempt = attempt!(host) |> gated!(65_536)
      baseline = answering()
      call = Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

      assert_receive {:writing, relay, _base64}, 10_000
      assert answering() > baseline
      assert answering() - baseline == RunnerRelay.held(sealed_bytes(attempt, {:ok, answer}), 1)
      assert [poster] = holders(relay)
      monitor = Process.monitor(poster)

      send(relay, :go)
      assert {:ok, ^answer} = Task.await(call)
      assert_receive {:DOWN, ^monitor, :process, ^poster, :normal}, 5_000
      wait_until(fn -> answering() == baseline end)
      refute holds?(relay, 65_536)
    end

    test "held by a poster killed while it waits is freed, and the answer it handed over still reaches the runner",
         %{host: host} do
      answer = String.duplicate("a", 600_000)
      ScriptedHost.script(host, "tool_call", {:ok, answer})
      attempt = attempt!(host) |> gated!(65_536)
      baseline = answering()
      call = Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

      assert_receive {:writing, relay, _base64}, 10_000
      assert answering() > baseline
      assert [poster] = holders(relay)
      Process.exit(poster, :kill)
      wait_until(fn -> answering() == baseline end)

      send(relay, :go)
      assert {:ok, ^answer} = Task.await(call)
    end

    test "answers asking together for several times the count are each answered once, one after another",
         %{host: host} do
      # Each answer, sealed, is most of the largest a host call's may be:
      # the count holds one of them at a time.
      answer = String.duplicate("a", 3_300_000)
      ScriptedHost.script(host, "tool_call", {:ok, answer})
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      calls =
        for _n <- 1..6,
            do: Task.async(fn -> call(attempt, :tool_call, @tool_call) end)

      for call <- calls, do: assert({:ok, ^answer} = Task.await(call, 30_000))
      assert length(ScriptedHost.requests(host, "tool_call")) == 6

      wait_until(fn ->
        Locus.Output.held(@count) |> Map.take([:answering, :waiting]) == %{
          answering: 0,
          waiting: 0
        }
      end)
    end
  end
end
