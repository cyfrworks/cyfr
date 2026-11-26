# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.MemoryTest do
  @moduledoc """
  Who used what (`Opus.Memory`): a poll stores what each endpoint reports
  under the poller's claim, with each program's name read in its own
  athanor's scope; a person reads their own and everyone else's only as
  one sum; the platform administrator reads everyone's, by standing the
  store confirms; and nothing of a key or header reaches a log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.JobClaims
  alias Cyfr.Test.ShareFixtures

  @boot String.duplicate("c", 32)
  @new_boot String.duplicate("d", 32)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    terry = ShareFixtures.person!("Terry")
    alice = ShareFixtures.person!("Alice")
    admin = ShareFixtures.person!("Admin")
    {:ok, _mark} = Sanctum.TestContext.ensure_platform(admin.user.id)

    {:ok, claim} = JobClaims.claim("memory", JobClaims.cell_key(), "boot_test", 60_000)

    {:ok, terry: terry, alice: alice, admin: %{admin.ctx | platform_admin: true}, claim: claim}
  end

  defp row!(person, name, mark) do
    {:ok, row} =
      Arca.McpServerStorage.insert(person.actor, %{
        cap: 0,
        name: name,
        transport: "program",
        mark: mark,
        url: nil,
        config_json: Jason.encode!(%{"command" => "npx -y some-server", "timeout_ms" => 5_000})
      })

    row
  end

  defp counter(rev, athanor, opts) do
    %{
      rev: rev,
      day: Keyword.get(opts, :day, Date.utc_today()),
      athanor: athanor,
      kind: Keyword.get(opts, :kind, "program"),
      subject: Keyword.get(opts, :subject),
      bytes: Keyword.get(opts, :bytes, 0),
      mib_ms: Keyword.get(opts, :mib_ms, 0),
      measured_ms: Keyword.get(opts, :measured_ms, 0),
      peak_bytes: Keyword.get(opts, :peak_bytes, 0),
      cap: Keyword.get(opts, :cap, 0),
      machine: 0,
      either: 0
    }
  end

  defp report(counters, opts \\ []) do
    %{
      boot: Keyword.get(opts, :boot, @boot),
      budget: 8_000_000,
      work: 6_000_000,
      floor: 164,
      used: 2_000,
      counters: counters,
      next: Keyword.get(opts, :next)
    }
  end

  # An endpoint that answers each ask from `pages`, a function of the rev
  # asked after, and tells the test what it was asked.
  defp endpoint(name, service, pages) do
    test = self()

    %{
      name: name,
      service: service,
      ask: fn after_rev ->
        send(test, {:asked, name, after_rev})
        pages.(after_rev)
      end
    }
  end

  defp once(report), do: fn _after -> {:ok, report} end

  describe "a poll" do
    test "stores what each endpoint reports, each program named from its own athanor's row",
         %{terry: terry, alice: alice, claim: claim} do
      tool = row!(alice, "github", "mcp")
      program = row!(terry, "claude", "driven")

      runtime =
        endpoint(
          "wrk_local",
          :runtime,
          once(report([counter(1, alice.actor.athanor_id, kind: "run", bytes: 40)]))
        )

      backends =
        endpoint(
          "local",
          :backends,
          once(
            report([
              counter(1, alice.actor.athanor_id, subject: tool.id, bytes: 300),
              counter(2, terry.actor.athanor_id, subject: program.id, bytes: 500),
              # A subject named as another athanor's is no row of that one.
              counter(3, terry.actor.athanor_id, subject: tool.id, bytes: 7)
            ])
          )
        )

      assert %{"wrk_local" => {:ok, 1}, "local" => {:ok, 3}} =
               Opus.Memory.poll([runtime, backends], claim, :none)

      assert {:ok, %{machines: [machine], days: days}} = Opus.Memory.read(alice.ctx, :mine)
      assert machine.machine == "wrk_local"
      assert machine.others == 507

      assert Enum.sort_by(machine.holders, & &1.bytes) == [
               %{person: person(alice), kind: :run, name: nil, bytes: 40},
               %{person: person(alice), kind: :tool, name: "github", bytes: 300}
             ]

      assert days |> Enum.map(& &1.person.athanor) |> Enum.uniq() == [alice.actor.athanor_id]

      assert {:ok, %{machines: [terrys]}} = Opus.Memory.read(terry.ctx, :mine)
      assert terrys.others == 340

      assert Enum.sort_by(terrys.holders, & &1.bytes) == [
               %{person: person(terry), kind: :program, name: nil, bytes: 7},
               %{person: person(terry), kind: :program, name: "claude", bytes: 500}
             ]
    end

    test "pages an endpoint by rev until its last page: 513 counters arrive whole",
         %{alice: alice, claim: claim} do
      athanor = alice.actor.athanor_id

      counters =
        for rev <- 1..513,
            do: counter(rev, athanor, kind: "build", day: Date.add(Date.utc_today(), -rev))

      pages = fn after_rev ->
        page = counters |> Enum.filter(&(&1.rev > after_rev)) |> Enum.take(256)
        next = if List.last(page).rev < 513, do: List.last(page).rev
        {:ok, report(page, next: next)}
      end

      assert %{"builds" => {:ok, 513}} =
               Opus.Memory.poll([endpoint("builds", :builds, pages)], claim, :none)

      assert_received {:asked, "builds", 0}
      assert_received {:asked, "builds", 256}
      assert_received {:asked, "builds", 512}

      assert {:ok, %{days: days}} = Opus.Memory.read(alice.ctx, :mine)
      assert length(days) == 513

      # The next poll asks after the last rev stored.
      assert %{"builds" => {:ok, 513}} =
               Opus.Memory.poll([endpoint("builds", :builds, once(report([])))], claim, :none)

      assert_received {:asked, "builds", 513}
    end

    test "a new boot drops the cursor: its page is not stored under the old one, and the boot is read from 0",
         %{alice: alice, claim: claim} do
      athanor = alice.actor.athanor_id
      first = report([counter(9, athanor, kind: "run", bytes: 10)])

      assert %{"wrk_local" => {:ok, 9}} =
               Opus.Memory.poll([endpoint("wrk_local", :runtime, once(first))], claim, :none)

      restarted = fn
        # Asked past 9 of the old boot, the new boot answers its own
        # counters past 9: never stored.
        9 -> {:ok, report([counter(10, athanor, kind: "build", bytes: 99)], boot: @new_boot)}
        0 -> {:ok, report([counter(1, athanor, kind: "run", bytes: 20)], boot: @new_boot)}
      end

      assert %{"wrk_local" => {:ok, 1}} =
               Opus.Memory.poll([endpoint("wrk_local", :runtime, restarted)], claim, :none)

      assert_received {:asked, "wrk_local", 9}
      assert_received {:asked, "wrk_local", 0}

      assert {:ok, %{machines: [machine], days: days}} = Opus.Memory.read(alice.ctx, :mine)
      assert machine.boot == @new_boot
      assert [%{kind: :run, bytes: 20}] = machine.holders
      refute Enum.any?(days, &(&1.kind == :build))
    end

    test "a claim taken by another member stores nothing and stops the poll",
         %{alice: alice, claim: claim} do
      :ok = JobClaims.release(claim)
      {:ok, _peer} = JobClaims.claim("memory", JobClaims.cell_key(), "boot_peer", 60_000)

      page = once(report([counter(1, alice.actor.athanor_id, kind: "run", bytes: 10)]))

      assert %{"wrk_local" => {:lost, :taken}} =
               Opus.Memory.poll(
                 [endpoint("wrk_local", :runtime, page), endpoint("builds", :builds, page)],
                 claim,
                 :none
               )

      refute_received {:asked, "builds", _}
      assert {:ok, %{machines: [], days: []}} = Opus.Memory.read(alice.ctx, :mine)
    end

    test "a member that holds no slot stores nothing", %{alice: alice, claim: claim} do
      page = once(report([counter(1, alice.actor.athanor_id, kind: "run", bytes: 10)]))

      Prima.Test.Env.with_app_env(:arca, :control_plane_claim_enabled, true, fn ->
        assert %{"wrk_local" => {:lost, :not_owner}} =
                 Opus.Memory.poll([endpoint("wrk_local", :runtime, page)], claim, :none)
      end)

      assert {:ok, %{machines: [], days: []}} = Opus.Memory.read(alice.ctx, :mine)
    end
  end

  describe "read/2" do
    test "a deleted row's name stays, read by its person and the administrator, never by another person",
         %{terry: terry, alice: alice, admin: admin, claim: claim} do
      tool = row!(alice, "github", "mcp")
      athanor = alice.actor.athanor_id

      page = fn rev ->
        once(report([counter(rev, athanor, subject: tool.id, bytes: 300, mib_ms: rev)]))
      end

      Opus.Memory.poll([endpoint("local", :backends, page.(1))], claim, :none)

      {:ok, _gone} = Arca.McpServerStorage.delete(alice.actor, "github")
      Opus.Memory.poll([endpoint("local", :backends, page.(2))], claim, :none)

      assert {:ok, %{days: [%{name: "github", kind: :tool, mib_ms: 2}]}} =
               Opus.Memory.read(alice.ctx, :mine)

      assert {:ok, %{days: days, machines: [machine]}} = Opus.Memory.read(admin, :everyone)
      assert [%{name: "github", person: %{athanor: ^athanor}}] = days
      assert machine.others == 0
      assert [%{name: "github", bytes: 300}] = machine.holders

      assert {:ok, %{days: [], machines: [terrys]}} = Opus.Memory.read(terry.ctx, :mine)
      assert terrys.holders == []
      assert terrys.others == 300
      refute inspect(terrys) =~ "github"
    end

    test ":everyone is the administrator's alone, their standing read from the store",
         %{terry: terry, alice: alice, admin: admin} do
      assert {:ok, %{machines: [], days: []}} = Opus.Memory.read(admin, :everyone)

      # A context that says it administers, of a person who does not, reads nothing.
      assert {:error, :forbidden} =
               Opus.Memory.read(%{alice.ctx | platform_admin: true}, :everyone)

      assert {:error, :forbidden} = Opus.Memory.read(terry.ctx, :everyone)
    end

    test "a day sums one program's use across machines and boots, and keeps the most it held",
         %{alice: alice, claim: claim} do
      tool = row!(alice, "github", "mcp")
      athanor = alice.actor.athanor_id
      day = Date.utc_today()

      one = fn bytes, peak ->
        [
          counter(1, athanor,
            subject: tool.id,
            bytes: bytes,
            mib_ms: 10,
            measured_ms: 4,
            peak_bytes: peak,
            cap: 1
          )
        ]
      end

      Opus.Memory.poll(
        [
          endpoint("local", :backends, once(report(one.(5, 50)))),
          endpoint("wrk_two", :runtime, once(report(one.(6, 70), boot: @new_boot)))
        ],
        claim,
        :none
      )

      assert {:ok, %{machines: machines, days: [today]}} = Opus.Memory.read(alice.ctx, :mine)
      assert machines |> Enum.map(& &1.machine) |> Enum.sort() == ["local", "wrk_two"]

      assert today == %{
               day: day,
               person: person(alice),
               kind: :tool,
               name: "github",
               mib_ms: 20,
               measured_ms: 8,
               peak_bytes: 70,
               ended: %{cap: 2, machine: 0, either: 0}
             }
    end
  end

  describe "the pool request" do
    test "is signed with the worker service's pool key, and the poller logs its failure without key or header" do
      stub = Cyfr.Test.HTTPStub.open()
      test = self()

      Cyfr.Test.HTTPStub.expect(stub, "POST", Prima.LocusPool.route(), fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [header] = Plug.Conn.get_req_header(conn, "x-cyfr-auth")
        send(test, {:pool, header, body})
        Plug.Conn.send_resp(conn, 503, "no")
      end)

      worker = %{id: "wrk_local", url: "http://127.0.0.1:#{stub.port}", components: nil}

      endpoints = [
        %{name: worker.id, service: :runtime, ask: &Opus.WorkerClient.pool(worker, &1)}
      ]

      log =
        capture_log(fn ->
          poller =
            start_supervised!(
              {Opus.Memory, endpoints: endpoints, owner: "boot_test", name: :memory_test}
            )

          eventually(
            fn -> :sys.get_state(poller).failing != %{} end,
            "the poller to fail its ask"
          )

          stop_supervised!(Opus.Memory)
        end)

      assert_received {:pool, header, body}
      {:ok, worker_key} = Opus.Keys.locus_runtime_key(worker.id)
      pool_key = Prima.LocusPool.pool_key(:runtime, worker_key)
      now = System.system_time(:millisecond)

      assert {:ok, hash} = Prima.LocusPool.verify_header(:runtime, pool_key, header, now)
      assert :ok = Prima.LocusPool.verify_body(hash, body)
      assert {:ok, 0} = Prima.LocusPool.read_request_body(body)

      assert log =~ "wrk_local did not report who used what"

      for secret <- [
            header,
            Base.encode16(pool_key, case: :lower),
            Base.encode16(worker_key, case: :lower)
          ] do
        refute log =~ secret
      end
    end

    test "reads the worker service's report", %{alice: alice, claim: claim} do
      stub = Cyfr.Test.HTTPStub.open()

      answer =
        Prima.LocusPool.answer(
          report([counter(4, alice.actor.athanor_id, kind: "run", bytes: 12)])
        )

      Cyfr.Test.HTTPStub.expect(stub, "POST", Prima.LocusPool.route(), fn conn ->
        Plug.Conn.send_resp(conn, 200, answer)
      end)

      worker = %{id: "wrk_local", url: "http://127.0.0.1:#{stub.port}", components: nil}

      endpoints = [
        %{name: worker.id, service: :runtime, ask: &Opus.WorkerClient.pool(worker, &1)}
      ]

      assert %{"wrk_local" => {:ok, 4}} = Opus.Memory.poll(endpoints, claim, :none)

      assert {:ok, %{machines: [%{holders: [%{kind: :run, bytes: 12}]}]}} =
               Opus.Memory.read(alice.ctx, :mine)
    end
  end

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    if check.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline,
        do: flunk("timed out waiting for #{what}")

      # sleep-ok: poll interval of eventually's bounded wait (5 s)
      Process.sleep(10)
      eventually(check, what, deadline)
    end
  end

  defp person(who), do: %{athanor: who.actor.athanor_id, name: who.athanor.slug}
end
