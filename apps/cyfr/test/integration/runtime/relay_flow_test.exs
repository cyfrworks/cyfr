# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.RelayFlowTest do
  @moduledoc """
  A pin a runner took before its run read a source sends nothing after the
  read: the worker service's relay (`Locus.Runtime.Relay`), joined to this
  application's host over the wire, asks CYFR for the send itself as the
  request leaves, and CYFR decides it on the run's ledger as it stands
  then (`Opus.Host.Egress`). The runner here is the test, speaking the
  relay's frames through `Locus.Runtime.Relay.Runner` under the attempt's
  own keys; the host, the relay, the attempt and the upstream are real.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.AttemptFixtures
  alias Locus.Runtime.{Egress, HostClient}
  alias Locus.Runtime.Relay.Runner, as: Endpoint
  alias Locus.Runtime.Test.ScriptedKeeper
  alias Prima.Authority
  alias Prima.Authority.Blob.Edge

  defmodule Upstream do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:upstream, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "reached " <> conn.request_path)
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "relay_flow_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf!(dir)

      if previous,
        do: Application.put_env(:arca, :base_path, previous),
        else: Application.delete_env(:arca, :base_path)
    end)

    File.mkdir_p!(dir)
    Application.put_env(:arca, :base_path, dir)

    server =
      start_supervised!(
        {Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, port: port}
  end

  # A real attempt whose edge reaches the loopback upstream and reads
  # data/, declaring no flow, joined to a relay of its own.
  defp relayed! do
    edge = %Edge{
      egress: %{
        domains: ["127.0.0.1"],
        methods: ["GET"],
        schemes: ["http"],
        private_ips: ["127.0.0.1"]
      },
      storage: %{paths: ["data/"], actions: ["read"]}
    }

    fixture =
      AttemptFixtures.attached!(
        ctx: Sanctum.TestContext.local(:api),
        authority: %{Authority.zero() | resources: edge}
      )

    :ok = Arca.put(Sanctum.Context.actor(fixture.ctx), ["data", "notes.txt"], "restricted")

    # The relay posts to this application's host listener, as a worker
    # service posts to the member its assignment names.
    {:ok, assignment} = Prima.Assignment.read(fixture.assignment)
    %{endpoint: endpoint, relay: relay} = ScriptedKeeper.relay!(fixture.runner)

    :ok =
      Locus.Runtime.Relay.bind(relay, %{
        assignment: fixture.assignment,
        keys: fixture.keys,
        host_url: Cyfr.Test.RuntimeService.host_url()
      })

    :ok = Endpoint.bind(endpoint, fixture.attempt)

    client =
      HostClient.new(fixture.keys, fixture.runner, fixture.boot, %{
        member: assignment.member,
        relay: endpoint
      })

    Map.merge(fixture, %{client: client, relay: relay, endpoint: endpoint})
  end

  defp send!(attempt, pinned, path) do
    {:ok, ref} =
      Endpoint.fetch(attempt.endpoint, attempt.attempt, pinned.target.id, "GET", path, [], "")

    events(attempt.endpoint, ref, [])
  end

  defp events(endpoint, ref, acc) do
    receive do
      {Endpoint, ^ref, {:end, error}} ->
        {Enum.reverse(acc), error}

      {Endpoint, ^ref, event} ->
        Endpoint.credit(endpoint, ref, byte_size(elem(event, tuple_size(event) - 1)))
        events(endpoint, ref, [event | acc])
    after
      15_000 -> flunk("the fetch never ended")
    end
  end

  test "a pin taken before a restricted read is refused at the send, and nothing reaches the upstream",
       %{port: port} do
    attempt = relayed!()
    assert {:ok, pinned} = Egress.pin(attempt.client, "http://127.0.0.1:#{port}/send")

    assert {:ok, %{"content" => _}} =
             HostClient.storage(attempt.client, :read, %{"path" => "data/notes.txt"})

    assert {[], "pin_flow"} = send!(attempt, pinned, "/send")
    refute_received {:upstream, _path}
  end

  test "the same send with no read between reaches the upstream", %{port: port} do
    attempt = relayed!()
    assert {:ok, pinned} = Egress.pin(attempt.client, "http://127.0.0.1:#{port}/send")

    assert {[{:head, 200, _headers, _body} | _], nil} = send!(attempt, pinned, "/send")
    assert_received {:upstream, "/send"}
  end
end
