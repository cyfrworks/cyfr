# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RelayTest do
  @moduledoc """
  A runner's relay (`Locus.Runtime.Relay`, `Locus.Runtime.Relay.Runner`), joined in this VM
  to a scripted host: the service's end verifies each host call a runner
  hands it under the attempt's keys and posts it unchanged, naming the
  service's runner id; it refuses, closing the channel, a frame for an
  attempt the channel does not carry, a header naming another runner or
  signed under another attempt's key, a `take_rate` of the runner's own,
  a fetch naming a pin CYFR never granted to the frame's attempt and a
  frame past the relay's bound. A child CYFR admits is carried, with pins
  of its own. A granted pin serves one fetch, and only before its
  `expires_at`: a fetch naming it again closes the channel. A fetch
  through a granted pin is checked again against the attempt's edge and
  limits, taken from the rate by the relay itself, then decided by CYFR
  again as it leaves — the relay asks `egress_pin` itself, as the runner
  asked it, and connects only to the address of that answer, so a host
  CYFR refuses since the runner's pin, an answer naming another target and
  a lost answer each end the fetch with nothing connected. The answer
  streams back never past the runner's credit: a slow runner holds the
  service waiting, and the attempt's deadline ends the fetch and closes
  the upstream connection. Neither end shows an attempt's keys in its
  status.

  A fetch naming a connection is posted by the service as the host call
  `attached_fetch`, taking no rate and asking no pin, after the attempt's
  edge and limits are checked again; CYFR's sealed frames are relayed
  unopened, never past the runner's credit nor the attempt's
  `max_response_size`, and the runner's end opens them in order for the
  call id it chose. CYFR's refusal is taken only as the answer to the
  fetch's own call, naming its call id; a frame that does not read, or an
  answer that ends short, ends the fetch with nothing more of it handed
  on.
  """

  use ExUnit.Case, async: true

  import Prima.Test.Wait

  alias Prima.{Assignment, AttachedRequest, RunnerRelay, WorkerAuth, WorkerWire}
  alias Locus.Runtime.{Egress, HostClient, HttpHandler}
  alias Locus.Runtime.Relay.Runner, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, RelayFixtures, ScriptedHost, ScriptedKeeper}

  import RelayFixtures

  @ref RelayFixtures.component_ref()

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

      assert_closes(relay, bytes, attempt, :unknown_attempt)
      assert ScriptedHost.requests(host) == []
    end

    test "a header naming another runner than the service's closes the channel", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt, "runner_the_service_started")
      frame = signed_call(attempt, :renew, %{"attempts" => [attempt.attempt]})
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      assert_closes(relay, bytes, attempt, :runner_mismatch)
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
        assert_closes(relay, bytes, attempt, reason)
      end

      assert ScriptedHost.requests(host) == []
    end

    test "a runner's own take_rate is refused: the rate is the service's to take", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)
      frame = signed_call(attempt, :take_rate, %{"bucket" => "http:" <> @ref})
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      assert_closes(relay, bytes, attempt, :take_rate)
      assert ScriptedHost.requests(host, "take_rate") == []
    end

    test "a body that is not the frame's operation closes the channel", %{host: host} do
      attempt = attempt!(host)
      relay = service_end!(host, attempt)
      frame = %{signed_call(attempt, :renew, %{"attempts" => []}) | op: :attach}
      {bytes, _} = frame_bytes(RunnerRelay.new(:runner, attempt.attempt), frame)

      assert_closes(relay, bytes, attempt, :malformed_call)
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

      assert {:ok, admitted} =
               HostClient.admit_child(attempt.client, @ref, nil, %{"fixture" => true}, :call, nil)

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

    test "the upstream sees exactly one Host, the pin's host and port, never the guest's",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      # A runner sending the guest's Host and X-Forwarded-Host itself, past
      # the runner's own validation: the relay refuses the fetch.
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/hello",
                 [{"host", "admin.internal"}, {"x-forwarded-host", "admin.internal"}],
                 ""
               )

      assert {[], "invalid_request"} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []

      # Without one, the relay sets Host from the pin, port included.
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/hello")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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
        assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pinned.target.id,
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

    test "a guest's Host on a POST is refused before its pin, and without it the POST reaches the pinned host",
         %{host: host} do
      port = upstream!()
      edge = EdgeFixtures.edge(domains: ["api.test"], methods: ["POST"])
      limits = EdgeFixtures.limits()
      attempt = attempt!(host, edge: edge, limits: limits) |> ScriptedKeeper.relayed!()

      for headers <- [
            %{"Host" => "blocked.test"},
            %{"X-Forwarded-Host" => "blocked.test"},
            %{"X-Real-IP" => "127.0.0.1"},
            %{"True-Client-IP" => "10.0.0.1"}
          ] do
        [{name, _value}] = Map.to_list(headers)

        request =
          Jason.encode!(%{
            "method" => "POST",
            "url" => "http://api.test:#{port}/",
            "headers" => headers,
            "body" => "sample"
          })

        assert %{"error" => %{"type" => "invalid_request", "message" => message}} =
                 request
                 |> HttpHandler.execute(edge, limits, attempt.client, @ref)
                 |> Jason.decode!()

        assert message == "A request cannot set the #{name} header."
      end

      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "egress_pin") == []
      assert ScriptedHost.requests(host, "take_rate") == []

      request =
        Jason.encode!(%{
          "method" => "POST",
          "url" => "http://api.test:#{port}/",
          "body" => "sample"
        })

      assert %{"status" => 200, "body" => "reached /"} =
               request
               |> HttpHandler.execute(edge, limits, attempt.client, @ref)
               |> Jason.decode!()

      assert_received {:upstream, "POST", "/", upstream_headers}
      assert {"content-length", "6"} in upstream_headers

      assert Enum.filter(upstream_headers, fn {name, _value} -> name == "host" end) ==
               [{"host", "api.test:#{port}"}]
    end

    test "a runner's header the relay refuses answers the guest invalid_request, not an HTTP failure",
         %{host: host} do
      port = upstream!()
      limits = EdgeFixtures.limits()
      attempt = attempt!(host, limits: limits) |> ScriptedKeeper.relayed!()
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "GET",
                 "/",
                 [{"Host", "admin.internal"}],
                 ""
               )

      assert {[], "invalid_request" = code} = events(attempt.endpoint, ref)
      refute_received {:upstream, _, _, _}
      assert ScriptedHost.requests(host, "take_rate") == []

      assert {:error, :invalid_request, message} =
               HttpHandler.relay_ended(code, %{hostname: "api.test"}, limits)

      assert message =~ "worker service's check"
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

    test "a pin serves one fetch: a second fetch naming it closes the channel and connects nowhere",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/once")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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
                 pinned.target.id,
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
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")

      fetch =
        &Endpoint.fetch(attempt.endpoint, attempt.attempt, pinned.target.id, &1, "/x", [], "")

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
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/late")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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
      assert {:ok, pinned} = Egress.pin(attempt.client, url)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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

      assert {:ok, %{ip: "127.0.0.2"} = pinned} =
               Egress.pin(attempt.client, "http://api.test:#{port}/fresh")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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
      assert {:ok, origin} = Egress.pin(attempt.client, origin_url)
      :ok = Egress.redirected(attempt.client, origin, origin_url, "/moved")
      assert {:ok, hop} = Egress.pin(attempt.client, "http://api.test:#{port}/moved")
      assert hop.from == origin.target

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 hop.target.id,
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
        "from" => origin.target.id
      }

      assert [_origin, %{args: ^expected}, %{args: ^expected}] =
               ScriptedHost.requests(host, "egress_pin")
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

      # Each fetch is a request of its own, pinned for itself.
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
                 "POST",
                 "/x",
                 [],
                 ""
               )

      assert {[], "method_blocked"} = events(attempt.endpoint, ref)
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/x")

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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

        assert {:ok, pinned} =
                 Egress.pin(attempt.client, "#{unquote(scheme)}://api.test:#{port}/")

        assert {:ok, ref} =
                 Endpoint.fetch(
                   attempt.endpoint,
                   attempt.attempt,
                   pinned.target.id,
                   "GET",
                   "/",
                   [],
                   ""
                 )

        assert {[], unquote(code)} = events(attempt.endpoint, ref)
      end
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

    test "a refusal naming another call, or not the fetch's call's answer, does not read", %{
      host: host
    } do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      other = AttachedRequest.call_id(:crypto.strong_rand_bytes(16))

      ScriptedHost.script(host, "attached_fetch", [
        {:answer,
         Jason.encode!(
           WorkerWire.error(:guest_error, %{
             "type" => "destination_mismatch",
             "message" => "Outside the destination.",
             "call_id" => other
           })
         )},
        {:answer,
         Jason.encode!(
           WorkerWire.error(:guest_error, %{"type" => "dispatch_error", "message" => "no call id"})
         )},
        {:error, :unavailable}
      ])

      for _answer <- 1..2 do
        assert {:ok, ref} = attached_fetch(attempt, attached())
        assert {[], "bad_frame"} = events(attempt.endpoint, ref)
      end

      # The third: CYFR answered `unavailable`, which an attached fetch is
      # not answered by.
      assert {:ok, ref} = attached_fetch(attempt, attached())
      assert {[], "bad_frame"} = events(attempt.endpoint, ref)
    end

    test "a frame out of order, under another call or with a bad tag ends the fetch, and nothing of it is handed on",
         %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      seal = attempt.keys.seal

      sealed = fn call_id, seq, kind, plaintext ->
        {:ok, <<_length::32, frame::binary>> = bytes} =
          WorkerAuth.seal_frame(seal, :answer, call_id, seq, kind, plaintext, iv())

        {bytes, frame}
      end

      request = attached()
      {_bytes, chunk} = sealed.(request.call_id, 1, :chunk, "secret part")
      <<kind, value::binary>> = chunk
      tampered = <<byte_size(chunk)::32, kind, flip(value)::binary>>

      {another, _} =
        sealed.(AttachedRequest.call_id(:crypto.strong_rand_bytes(16)), 1, :chunk, "x")

      for {name, frames, heard} <- [
            {"a bad tag", [{:head, 200, []}, {:raw, tampered}, :end], [{:head, 200, [], ""}]},
            {"another call", [{:head, 200, []}, {:raw, another}, :end], [{:head, 200, [], ""}]},
            {"out of order", [{:chunk, "first"}, :end], []}
          ] do
        request = if name == "a bad tag", do: request, else: attached()
        ScriptedHost.script(host, "attached_fetch", {:frames, frames})
        assert {:ok, ref} = attached_fetch(attempt, request)
        assert {^heard, "bad_frame"} = events(attempt.endpoint, ref), name
      end

      # Each ended fetch drained to its end on the channel.
      wait_until(fn -> Endpoint.idle?(attempt.endpoint) end)
    end

    test "an answer that ends before its end or error is an error at the runner", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      ScriptedHost.script(host, "attached_fetch", {:frames, [{:head, 200, []}, {:chunk, "part"}]})

      assert {:ok, ref} = attached_fetch(attempt, attached())

      assert {[{:head, 200, [], ""}, {:chunk, "part"}], "truncated"} =
               events(attempt.endpoint, ref)
    end

    test "an error frame ends the fetch with CYFR's type and sentence", %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:error, "response_too_large", "Past the bound."}]}
      )

      assert {:ok, ref} = attached_fetch(attempt, attached())

      assert {[{:head, 200, [], ""}], {:guest_error, "response_too_large", "Past the bound."}} =
               events(attempt.endpoint, ref)
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

    test "neither end shows the keys, and the runner's end drops them with the fetch", %{
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

      for process <- [attempt.relay, attempt.endpoint],
          key <- [attempt.keys.call, attempt.keys.seal] do
        status = :erlang.term_to_binary(:sys.get_status(process))
        assert :binary.match(status, key) == :nomatch
      end

      send(held, :go)
      assert {[{:head, 200, [], ""}], nil} = events(attempt.endpoint, ref)
      wait_until(fn -> Endpoint.idle?(attempt.endpoint) end)
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
        asked = Locus.Runtime.Relay.held(byte_size(held), 1) - byte_size(held) + over
        {{frame.kind, byte_size(bytes), asked}, service}
      end)
      |> elem(0)

    for {kind, bytes, asked} <- written do
      assert bytes <= asked,
             "a #{kind} frame of #{bytes} bytes, #{asked} asked for beside its body"
    end
  end

  defp iv, do: :crypto.strong_rand_bytes(12)

  # A sealed value with one bit of its tag changed.
  defp flip(sealed) do
    <<iv::binary-size(12), first, tag::binary-size(15), ciphertext::binary>> =
      Base.url_decode64!(sealed, padding: false)

    Base.url_encode64(<<iv::binary, Bitwise.bxor(first, 1), tag::binary, ciphertext::binary>>,
      padding: false
    )
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
end

defmodule Locus.Runtime.RelayCountTest do
  @moduledoc """
  What a runner's relay holds to answer or send its runner is counted
  under the runtime's count (`Locus.Output.server(:runtime)`), which these
  tests fill or read whole, so they run alone. A pinned fetch's head and
  piece and an attached fetch's frame are asked for before they are handed
  on and given back once written; a host call's answer is asked for whole
  as its reading begins and freed once written, and the service's own
  call's once it is read. No room by the deadline ends a fetch `timeout`
  with nothing of the piece or frame handed on, and makes a host call's
  answer one that did not arrive, under the call's retry class. A worker
  or a poster killed while it holds frees what it held. Once the relay
  says a piece or an answer is written it holds none of it.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.{Assignment, WorkerAuth}
  alias Locus.Runtime.{Egress, HostClient, Relay}
  alias Locus.Runtime.Relay.Runner, as: Endpoint
  alias Locus.Runtime.Test.{EdgeFixtures, RelayFixtures, ScriptedHost, ScriptedKeeper}

  import RelayFixtures

  @count Locus.Output.server(:runtime)

  setup do
    host = ScriptedHost.start!()
    ScriptedHost.pins(host, %{"api.test" => "127.0.0.1"})
    {:ok, host: host}
  end

  defp answering, do: Locus.Output.held(@count).answering

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

  # `attempt` routed through a relay joined in this VM, as
  # `ScriptedKeeper.relayed!/2` routes one, whose service end holds its
  # first write of `gate` bytes or more as a keeper's write that has not
  # returned: the test hears `{:writing, relay, bytes}` and lets it go
  # with `:go`.
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

    client =
      HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
        member: assignment.member,
        relay: endpoint
      })

    Map.merge(attempt, %{client: client, relay: relay, endpoint: endpoint})
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
    assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}#{path}")

    assert {:ok, ref} =
             Endpoint.fetch(
               attempt.endpoint,
               attempt.attempt,
               pinned.target.id,
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
      assert answering() - baseline >= Relay.held(byte_size(Base.decode64!(base64)), 1)

      send(relay, :go)
      assert read_granting(attempt.endpoint, ref, 0) == size
      wait_until(fn -> answering() == baseline end)
      refute holds?(relay, 16_384)
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

  describe "a pinned fetch's head" do
    test "waits for room before it is handed on, and none by the deadline ends the fetch timeout with no head handed on",
         %{host: host} do
      port = upstream!()
      attempt = attempt!(host, timeout_ms: 1_500) |> ScriptedKeeper.relayed!()
      assert {:ok, pinned} = Egress.pin(attempt.client, "http://api.test:#{port}/wide-head")

      # Room for the calls' small answers, and none for the head.
      held = fill!(65_536)

      assert {:ok, ref} =
               Endpoint.fetch(
                 attempt.endpoint,
                 attempt.attempt,
                 pinned.target.id,
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
      assert answering() - baseline == Relay.held(byte_size(Base.decode64!(base64)), 1)

      send(relay, :go)
      assert {events, nil} = events(attempt.endpoint, ref)
      assert body_of(events) == piece <> piece
      wait_until(fn -> answering() == baseline end)
      refute holds?(relay, 40_000)
    end
  end

  describe "a host call's answer" do
    test "waits for room, whole, as its reading begins, and none by the call's own deadline is an answer that did not arrive, under the call's retry class",
         %{host: host} do
      attempt = attempt!(host) |> ScriptedKeeper.relayed!()
      full = fill!()

      never = Task.async(fn -> HostClient.tool_call(attempt.client, "t", %{}, :call) end)
      idempotent = Task.async(fn -> HostClient.renew(attempt.client, [attempt.attempt]) end)

      # A call whose effect may have happened is never asked again.
      assert {:error, {:uncertain, _sentence}} =
               Task.await(never, Prima.HostAPI.request_timeout_ms(:tool_call) + 10_000)

      assert [_once] = ScriptedHost.requests(host, "tool_call")

      # An idempotent one is asked once more, and answered once there is
      # room: the count stays full until it has been asked again.
      wait_until(fn -> length(ScriptedHost.requests(host, "renew")) == 2 end, 10_000)
      Locus.Output.return(full)

      assert {:ok, _renewals} =
               Task.await(idempotent, Prima.HostAPI.request_timeout_ms(:renew) + 10_000)

      assert [_first, _second] = ScriptedHost.requests(host, "renew")
    end

    test "is counted until the relay has written it, then freed as its poster exits, and the relay keeps none of it",
         %{host: host} do
      answer = String.duplicate("a", 600_000)
      ScriptedHost.script(host, "tool_call", {:ok, answer})
      attempt = attempt!(host) |> gated!(65_536)
      baseline = answering()
      call = Task.async(fn -> HostClient.tool_call(attempt.client, "t", %{}, :call) end)

      assert_receive {:writing, relay, _base64}, 10_000
      assert answering() > baseline
      assert answering() - baseline == Relay.held(sealed_bytes(attempt, {:ok, answer}), 1)
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
      call = Task.async(fn -> HostClient.tool_call(attempt.client, "t", %{}, :call) end)

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
            do: Task.async(fn -> HostClient.tool_call(attempt.client, "t", %{}, :call) end)

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
