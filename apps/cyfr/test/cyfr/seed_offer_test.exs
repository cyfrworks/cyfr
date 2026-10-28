# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.SeedOfferTest do
  @moduledoc """
  The boot's seed offer is optional work: it runs under a claim of its
  own, a peer holding that claim is not waited for, and nothing that goes
  wrong in it stops the boot.

  Its start returns before the offer runs, so what starts after it — the
  endpoint, at boot — answers while the sync is still working. The claim's
  lease is renewed while the sync runs, and the claim is given back only
  once the sync's task is dead, whichever way the offer ends. A sign-in
  meanwhile finds the athanor claim the sync holds and skips its fill.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Arca.JobClaims
  alias Arca.ProvisioningClaims
  alias Cyfr.SeedOffer
  alias Prima.Test.Wait
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  @events [[:cyfr, :seed_offer, :completed], [:cyfr, :seed_offer, :aborted]]

  # A blocked sync gives up on its own past this, so a start that waits
  # for it returns and fails on what it asserts rather than hanging.
  @gives_up_ms 3_000

  # Short enough that renewals land within a test, at a third of it.
  @lease_ms 600

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test = self()
    handler = "seed-offer-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach_many(
        handler,
        @events,
        fn event, measurements, metadata, _ ->
          send(test, {:event, event, measurements, metadata})
        end,
        nil
      )

    # `job_claims` is shared, cross-node state; each case claims under a
    # key of its own.
    {:ok, key: "cell-seed-#{System.unique_integer([:positive])}"}
  end

  test "the offer runs under its own claim and gives it up for the next boot", %{key: key} do
    test = self()

    {pid, ref} = offer!(key: key, owner: "member-a", sync: fn -> send(test, :synced) end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :ok}}, 5_000
    assert_received :synced
    assert_received {:event, [:cyfr, :seed_offer, :completed], %{duration: _}, %{key: ^key}}
    assert {:ok, row} = JobClaims.read("seed_release", key)
    assert row.owner == "member-a"
    refute JobClaims.live?(row), "seed_release was left claimed"
  end

  test "the seed offer is the cell's: a member that loses it does not wait", %{key: key} do
    {:ok, _peer} = JobClaims.claim("seed_release", key, "member-b", 60_000)

    began = System.monotonic_time(:millisecond)

    {pid, ref} =
      offer!(key: key, owner: "member-a", sync: fn -> flunk("synced a peer's offer") end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :skipped}}, 5_000
    waited = System.monotonic_time(:millisecond) - began

    assert waited < 1_000
    assert {:ok, %{owner: "member-b"}} = JobClaims.read("seed_release", key)
    refute_received {:event, _, _, _}
  end

  @tag :capture_log
  test "a failed offer is logged and never stops the boot", %{key: key} do
    for failure <- [
          fn -> raise "registry unreachable" end,
          fn -> raise DBConnection.ConnectionError, "connection lost" end,
          fn -> exit(:boom) end
        ] do
      {:ok, log} =
        with_log(fn ->
          {pid, ref} = offer!(key: key, sync: failure)
          assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:error, :exception}}}, 5_000
          :ok
        end)

      assert_received {:event, [:cyfr, :seed_offer, :aborted], _, %{reason: :exception}}

      # The claim is given back even though the work failed.
      assert {:ok, row} = JobClaims.read("seed_release", key)
      refute JobClaims.live?(row)

      # Nothing of an exception is printed but its module.
      assert log =~ "seed offer failed"
      refute log =~ "registry unreachable"
      refute log =~ "connection lost"
    end
  end

  test "after the gate's declared-restore step answers, a failing offer still leaves the boot standing",
       %{key: key} do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          # The gate's step as the boot starts it: it answers and leaves no
          # process, so the offer after it starts.
          %{
            id: :declared_restore,
            start: {Cyfr.Application, :declared_restore, []},
            restart: :temporary
          },
          Supervisor.child_spec({SeedOffer, key: key, sync: fn -> raise "boom" end},
            restart: :temporary
          ),
          {Agent, fn -> :after_the_offer end}
        ],
        strategy: :one_for_one
      )

    # The offer ends by itself, and takes nothing with it.
    Wait.wait_until(
      fn -> match?([{Agent, _, :worker, _}], Supervisor.which_children(supervisor)) end,
      5_000,
      "the failed offer to end and leave the Agent alone"
    )

    assert [{Agent, pid, :worker, _}] = Supervisor.which_children(supervisor)
    assert Agent.get(pid, & &1) == :after_the_offer
    Supervisor.stop(supervisor)
  end

  describe "while the sync runs" do
    test "what starts after the offer answers before the sync has finished", %{key: key} do
      test = self()

      # The offer and a listener after it, as the infra tier and the web
      # tier with the endpoint start at boot.
      tier = [
        {SeedOffer, key: key, lease_ms: @lease_ms, sync: blocked_sync(test, key)},
        Supervisor.child_spec(
          {Bandit,
           plug: CyfrWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :listener
        )
      ]

      {:ok, supervisor} =
        start_supervised(%{
          id: :tier,
          start: {Supervisor, :start_link, [tier, [strategy: :rest_for_one]]},
          type: :supervisor
        })

      assert_receive {:syncing, sync, {:ok, _held}}, 5_000

      refute_received {:gave_up, ^sync},
                      "the start waited for the sync: the listener started only once it gave up"

      {:listener, server, _, _} =
        List.keyfind(Supervisor.which_children(supervisor), :listener, 0)

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      assert get(port, "/api/health") =~ ~r{\AHTTP/1\.1 200 }
      assert Process.alive?(sync)
      refute_received {:synced, ^sync}

      send(sync, :release)
      assert_receive {:synced, ^sync}, 5_000
    end

    test "the claim's lease advances, and the renewed claim is the one given back", %{key: key} do
      test = self()

      started =
        start_supervised(
          {SeedOffer, key: key, lease_ms: @lease_ms, sync: blocked_sync(test, key)}
        )

      assert_receive {:syncing, sync, {:ok, first}}, 5_000

      # Two renewals at a third of the lease, the claim live after each.
      Wait.wait_until(
        fn ->
          {:ok, row} = JobClaims.read("seed_release", key)

          row.fence >= first.fence + 2 and JobClaims.live?(row) and
            DateTime.compare(row.lease_until, first.lease_until) == :gt
        end,
        5_000,
        "the claim's lease to advance while the sync runs"
      )

      assert {:ok, pid} = started
      ref = Process.monitor(pid)
      send(sync, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :ok}}, 5_000

      # A release under the first fence would answer `:taken` and leave the
      # renewed lease standing.
      assert {:ok, row} = JobClaims.read("seed_release", key)
      refute JobClaims.live?(row), "the renewed claim was not given back"
      assert row.fence > first.fence + 2
    end

    @tag :capture_log
    test "a killed sync's claim is given back only after its task is dead", %{key: key} do
      test = self()
      trace_releases!()

      {pid, sync} = running!(key, test)
      ref = Process.monitor(pid)
      1 = :erlang.trace(pid, true, [:receive, :call])

      Process.exit(sync, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:error, :died}}}, 5_000
      assert_received {:event, [:cyfr, :seed_offer, :aborted], _, %{reason: :died}}

      assert died_then_released(pid, sync) == [:task_down, :release]
      assert {:ok, row} = JobClaims.read("seed_release", key)
      refute JobClaims.live?(row)
    end

    @tag :capture_log
    test "a stop while the sync runs stops its task before the claim is given back", %{key: key} do
      test = self()
      trace_releases!()

      {pid, sync} = running!(key, test)
      1 = :erlang.trace(pid, true, [:receive, :call])
      sync_ref = Process.monitor(sync)

      :ok = stop_supervised(SeedOffer)
      assert_receive {:DOWN, ^sync_ref, :process, ^sync, :killed}, 5_000
      assert_received {:event, [:cyfr, :seed_offer, :aborted], _, %{reason: :shutdown}}

      assert died_then_released(pid, sync) == [:task_down, :release]
      assert {:ok, row} = JobClaims.read("seed_release", key)
      refute JobClaims.live?(row)
    end

    @tag :capture_log
    test "a renewal a peer has taken stops the sync and gives back nothing of the peer's",
         %{key: key} do
      test = self()
      trace_releases!()

      {pid, sync} = running!(key, test)
      ref = Process.monitor(pid)
      1 = :erlang.trace(pid, true, [:receive, :call])
      sync_ref = Process.monitor(sync)

      # A peer takes the claim from under the offer: the offer's fence is
      # gone, and the peer holds the row live.
      {:ok, row} = JobClaims.read("seed_release", key)
      :ok = JobClaims.release(row)
      {:ok, peer} = JobClaims.claim("seed_release", key, "member-b", 60_000)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, {:error, :claim_lost}}}, 5_000
      assert_receive {:DOWN, ^sync_ref, :process, ^sync, :killed}, 5_000
      assert_received {:event, [:cyfr, :seed_offer, :aborted], _, %{reason: :claim_lost}}
      refute_received {:synced, ^sync}

      assert died_then_released(pid, sync) == [:task_down]
      assert {:ok, ^peer} = JobClaims.read("seed_release", key)
      assert JobClaims.live?(peer)
    end
  end

  describe "a sign-in during the sync" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cyfr_seed_offer_#{System.unique_integer([:positive])}")
      seed = Path.join(dir, "seed")
      File.mkdir_p!(Path.join(seed, "components"))
      prev_base = Application.get_env(:arca, :base_path)
      prev_seed = Application.get_env(:arca, :seed_path)

      on_exit(fn ->
        Application.put_env(:arca, :base_path, prev_base)
        Application.put_env(:arca, :seed_path, prev_seed)
        File.rm_rf!(dir)
      end)

      Cyfr.Test.Sandbox.stop_work_on_exit()
      Application.put_env(:arca, :base_path, dir)
      Application.put_env(:arca, :seed_path, seed)
      :ok
    end

    @tag :capture_log
    test "skips the fill of the athanor the sync holds, without waiting", %{key: key} do
      test = self()
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|seed-offer-#{n}",
          provider: "github",
          email: "seed-offer-#{n}@example.com",
          verified: true,
          name: "Seed Offer #{n}"
        })

      # The person's own athanor, which their admission made unfilled.
      {:ok, athanor_id} = Sanctum.Tenancy.Users.personal_athanor_id(user.id)
      {:ok, athanor} = Athanors.get(athanor_id)
      refute athanor.provisioned_at

      actor = %Prima.Actor{athanor_id: athanor.id}
      assert Arca.ControlPlane.held?(), "a member without the slot fills nothing at sign-in"

      # The sync walks one athanor under its claim, as `Compendium.sync_seeds/0` does.
      sync = fn ->
        Provisioning.await_claim(athanor.id, "seed_sync", 0, 10, fn claim ->
          send(test, {:holding, self(), claim})

          receive do
            :release -> :ok
          after
            @gives_up_ms -> send(test, {:gave_up, self()})
          end
        end)
      end

      started = start_supervised({SeedOffer, key: key, lease_ms: @lease_ms, sync: sync})
      assert_receive {:holding, holder, claim}, 5_000
      refute_received {:gave_up, ^holder}, "the start waited for the sync"
      assert {:ok, pid} = started

      began = System.monotonic_time(:millisecond)
      assert :ok = Provisioning.after_sign_in(user.id)
      assert System.monotonic_time(:millisecond) - began < 2_000

      # The fill found the sync's claim and did nothing: the claim is the
      # sync's at its fence, and the athanor is neither filled nor failed.
      assert {:ok, %{entry_kind: "seed_sync", owner: owner, fence: fence, outcome: nil}} =
               ProvisioningClaims.current(actor)

      assert {owner, fence} == {claim.owner, claim.fence}
      assert {:ok, unfilled} = Athanors.get(athanor.id)
      refute unfilled.provisioned_at
      refute Athanors.provisioning_failure(unfilled)

      ref = Process.monitor(pid)
      send(holder, :release)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :ok}}, 5_000

      assert {:ok, %{entry_kind: "seed_sync", outcome: "released"}} =
               ProvisioningClaims.current(actor)

      # Once the sync has let go, the next sign-in's fill runs: the skip was
      # the held claim and nothing else. This seed tree ships no bundle, so
      # the fill fails at its first step, which it records.
      assert :ok = Provisioning.after_sign_in(user.id)

      assert {:ok, %{entry_kind: "sign_in", fence: later}} = ProvisioningClaims.current(actor)
      assert later > fence
      assert {:ok, attempted} = Athanors.get(athanor.id)
      assert %{step: "seed"} = Athanors.provisioning_failure(attempted)
    end
  end

  # The work the boot's offer runs is the component domain's facade entry,
  # and the composition root names it: the host names no domain. A capture
  # is no call, so it is read off the compiled definitions of the offer
  # (`seed_offer/0`) and of the spec it starts (`seed_offer_spec/0`, which
  # the shutdown census reads too), and off the spec itself.
  test "the composition root offers Compendium.sync_seeds/0" do
    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(Cyfr.Application), [:debug_info])

    {:ok, %{definitions: definitions}} =
      backend.debug_info(:elixir_v1, Cyfr.Application, data, [])

    captured =
      for name <- [:seed_offer, :seed_offer_spec],
          {_offer, _kind, _meta, clauses} =
            Enum.find(definitions, &match?({{^name, 0}, _, _, _}, &1)) ||
              flunk("Cyfr.Application defines no #{name}/0"),
          {_meta, _args, _guards, body} <- clauses,
          {_ast, found} = Macro.prewalk(body, [], &capture/2),
          mfa <- found,
          do: mfa

    assert captured == [{Compendium, :sync_seeds, 0}]

    assert %{id: SeedOffer, start: {SeedOffer, :start_link, [[sync: sync]]}} =
             Cyfr.Application.seed_offer_spec()

    assert sync == (&Compendium.sync_seeds/0)
  end

  defp capture({:&, _, [{:/, _, [{{:., _, [module, fun]}, _, []}, arity]}]} = node, acc),
    do: {node, [{module, fun, arity} | acc]}

  defp capture(node, acc), do: {node, acc}

  # Start an offer under the test's supervisor and monitor it: it stops by
  # itself, with `{:shutdown, outcome}`.
  defp offer!(opts) do
    {:ok, pid} = start_supervised({SeedOffer, opts})
    {pid, Process.monitor(pid)}
  end

  # An offer whose sync is running and blocked: its start has returned
  # while the sync still runs.
  defp running!(key, test) do
    started =
      start_supervised({SeedOffer, key: key, lease_ms: @lease_ms, sync: blocked_sync(test, key)})

    assert_receive {:syncing, sync, {:ok, _held}}, 5_000
    refute_received {:gave_up, ^sync}, "the start waited for the sync"
    {:ok, pid} = started
    {pid, sync}
  end

  # A sync that reports itself and the claim row as it reads, then waits
  # for the test, giving up past `@gives_up_ms`.
  defp blocked_sync(test, key) do
    fn ->
      send(test, {:syncing, self(), JobClaims.read("seed_release", key)})

      receive do
        :release -> send(test, {:synced, self()})
      after
        @gives_up_ms -> send(test, {:gave_up, self()})
      end
    end
  end

  # `Arca.JobClaims.release/1` is traced, the trace pattern cleared when
  # the test ends however it ends. A pattern matches only loaded code, and
  # the case may be the first to reach the module.
  defp trace_releases! do
    on_exit(fn -> :erlang.trace_pattern({JobClaims, :release, 1}, false, []) end)
    Code.ensure_loaded!(JobClaims)
    1 = :erlang.trace_pattern({JobClaims, :release, 1}, true, [])
    :ok
  end

  # What the traced offer saw of the sync's task dying and what it gave
  # back, in the order it happened: a trace from one process arrives in
  # order. A task stopped by `Task.shutdown/2` is monitored twice, so its
  # death is told once.
  defp died_then_released(pid, sync), do: pid |> traced(sync, []) |> Enum.dedup()

  defp traced(pid, sync, acc) do
    receive do
      {:trace, ^pid, :receive, {:DOWN, _ref, :process, ^sync, _reason}} ->
        traced(pid, sync, [:task_down | acc])

      {:trace, ^pid, :call, {JobClaims, :release, [_claim]}} ->
        traced(pid, sync, [:release | acc])

      {:trace, ^pid, _kind, _what} ->
        traced(pid, sync, acc)
    after
      200 -> Enum.reverse(acc)
    end
  end

  # One GET over a real connection, answered and closed.
  defp get(port, path) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 5_000)

    :ok =
      :gen_tcp.send(socket, [
        "GET #{path} HTTP/1.1\r\n",
        "host: localhost\r\n",
        "accept: application/json\r\n",
        "connection: close\r\n\r\n"
      ])

    read_until_closed(socket, "", System.monotonic_time(:millisecond) + 5_000)
  end

  defp read_until_closed(socket, received, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, data} ->
        read_until_closed(socket, received <> data, deadline)

      {:error, _closed_or_timeout} ->
        :gen_tcp.close(socket)
        received
    end
  end
end
