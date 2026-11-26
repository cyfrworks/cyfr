# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.MemoryRecordTest do
  @moduledoc """
  The host's record of who used what (`Arca.MemoryRecord`): a page is
  stored only under the poller's claim and its member's slot, a counter
  is replaced only by a higher rev, a cursor of another boot stores
  nothing, every athanor reads its own and the platform all of them, and
  the days go by retention.
  """
  use ExUnit.Case, async: false

  alias Arca.{JobClaims, MemoryRecord}

  @boot String.duplicate("a", 32)
  @other_boot String.duplicate("b", 32)
  @endpoint "wrk_test"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    {:ok, claim} = JobClaims.claim("memory", JobClaims.cell_key(), "boot_test", 60_000)
    {:ok, claim: claim}
  end

  defp today, do: Date.utc_today()

  defp counter(rev, athanor, opts \\ []) do
    %{
      rev: rev,
      day: Keyword.get(opts, :day, today()),
      athanor: athanor,
      kind: Keyword.get(opts, :kind, "program"),
      subject: Keyword.get(opts, :subject, "srv_#{rev}"),
      bytes: Keyword.get(opts, :bytes, 1_000 * rev),
      mib_ms: Keyword.get(opts, :mib_ms, rev),
      measured_ms: Keyword.get(opts, :measured_ms, 2_000),
      peak_bytes: Keyword.get(opts, :peak_bytes, 2_000 * rev),
      cap: Keyword.get(opts, :cap, 0),
      machine: 0,
      either: 0
    }
  end

  defp report(counters, opts \\ []) do
    %{
      boot: Keyword.get(opts, :boot, @boot),
      budget: 8_000,
      work: 6_000,
      floor: 164,
      used: 1_000,
      counters: counters,
      next: Keyword.get(opts, :next)
    }
  end

  defp store(claim, after_rev, report, names \\ %{}),
    do: MemoryRecord.store(claim, :none, @endpoint, after_rev, report, names)

  defp all, do: elem(MemoryRecord.counters(Prima.Actor.system()), 1)

  defp endpoint,
    do:
      Enum.find(
        elem(MemoryRecord.endpoints(Prima.Actor.system()), 1),
        &(&1.endpoint == @endpoint)
      )

  describe "store/6" do
    test "stores each athanor's counter and drops one of no athanor or of an athanor this CYFR does not hold",
         %{claim: claim} do
      page =
        report([
          counter(1, "ath_a"),
          counter(2, nil, kind: "warm", subject: nil),
          counter(3, "ath_nowhere"),
          counter(4, "ath_b", kind: "run", subject: nil)
        ])

      assert {:ok, %{after: 4, stored: 2, dropped: 2}} = store(claim, 0, page)

      assert [
               %{
                 athanor_id: "ath_a",
                 kind: "program",
                 shown: "program",
                 subject: "srv_1",
                 rev: 1
               },
               %{athanor_id: "ath_b", kind: "run", shown: "run", subject: nil, rev: 4}
             ] = Enum.sort_by(all(), & &1.athanor_id)

      assert %{boot: @boot, after: 4, budget: 8_000, work: 6_000, floor: 164, used: 1_000} =
               endpoint()
    end

    test "a higher rev replaces a counter, and a lower or equal one adds nothing", %{claim: claim} do
      assert {:ok, %{after: 5}} =
               store(claim, 0, report([counter(5, "ath_a", subject: "srv_x", bytes: 10)]))

      assert {:ok, %{after: 9}} =
               store(claim, 5, report([counter(9, "ath_a", subject: "srv_x", bytes: 90, cap: 1)]))

      assert [%{rev: 9, bytes: 90, cap: 1}] = all()

      # The same key asked again from the start, at the rev it has and at a
      # lower one: nothing changes.
      assert {:ok, _} = store(claim, 0, report([counter(9, "ath_a", subject: "srv_x", bytes: 1)]))
      assert {:ok, _} = store(claim, 0, report([counter(3, "ath_a", subject: "srv_x", bytes: 2)]))
      assert [%{rev: 9, bytes: 90, cap: 1}] = all()
    end

    test "513 counters arrive whole across pages", %{claim: claim} do
      counters = for rev <- 1..513, do: counter(rev, "ath_a")
      [first, second, third] = Enum.chunk_every(counters, 256)

      assert {:ok, %{after: 256, stored: 256}} = store(claim, 0, report(first, next: 256))
      assert {:ok, %{after: 512, stored: 256}} = store(claim, 256, report(second, next: 512))
      assert {:ok, %{after: 513, stored: 1}} = store(claim, 512, report(third))

      assert length(all()) == 513
      assert all() |> Enum.map(& &1.rev) |> Enum.sort() == Enum.to_list(1..513)
      assert %{after: 513} = endpoint()
    end

    test "a page of a new boot asked with an old cursor stores nothing, and the boot starts again from 0",
         %{claim: claim} do
      assert {:ok, %{after: 7}} =
               store(claim, 0, report([counter(7, "ath_a", subject: "srv_old")]))

      # The keeper restarted: its counters start again at rev 1, so a page
      # past 7 of the new boot would be taken for later ones.
      new = report([counter(8, "ath_a", subject: "srv_new")], boot: @other_boot)
      assert {:ok, %{after: 0, boot: :new}} = store(claim, 7, new)
      assert [%{subject: "srv_old", boot: @boot}] = all()
      assert %{boot: @other_boot, after: 0} = endpoint()

      from_start = report([counter(1, "ath_a", subject: "srv_new")], boot: @other_boot)
      assert {:ok, %{after: 1, stored: 1}} = store(claim, 0, from_start)

      assert [%{boot: @boot, subject: "srv_old"}, %{boot: @other_boot, subject: "srv_new"}] =
               Enum.sort_by(all(), & &1.boot)
    end

    test "a page asked after another cursor than the stored one is another writer's and stores nothing",
         %{claim: claim} do
      assert {:ok, %{after: 4}} = store(claim, 0, report([counter(4, "ath_a")]))
      assert {:error, :moved} = store(claim, 2, report([counter(6, "ath_a")]))
      assert [%{rev: 4}] = all()
      assert %{after: 4} = endpoint()
    end

    test "a claim taken by another member stores and advances nothing", %{claim: claim} do
      assert {:ok, %{after: 1}} = store(claim, 0, report([counter(1, "ath_a")]))
      :ok = JobClaims.release(claim)
      {:ok, _peer} = JobClaims.claim("memory", JobClaims.cell_key(), "boot_peer", 60_000)

      assert :taken = store(claim, 1, report([counter(2, "ath_a")]))
      assert [%{rev: 1}] = all()
      assert %{after: 1} = endpoint()
    end

    test "a claim whose lease ran out stores and advances nothing", %{claim: claim} do
      Arca.Repo.update_all(Arca.Schemas.JobClaim,
        set: [lease_until: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert :lapsed = store(claim, 0, report([counter(1, "ath_a")]))
      assert all() == []
      assert endpoint() == nil
    end

    test "a member that holds no slot stores and advances nothing", %{claim: claim} do
      previous = Application.get_env(:arca, :control_plane_claim_enabled)
      Application.put_env(:arca, :control_plane_claim_enabled, true)

      try do
        assert {:error, :not_owner} = store(claim, 0, report([counter(1, "ath_a")]))
      after
        Application.put_env(:arca, :control_plane_claim_enabled, previous)
      end

      assert all() == []
      assert endpoint() == nil
    end

    test "what was read of a subject's row is kept after the row is gone", %{claim: claim} do
      names = %{{"ath_a", "srv_x"} => %{name: "Claude Code", shown: "program"}}
      assert {:ok, _} = store(claim, 0, report([counter(1, "ath_a", subject: "srv_x")]), names)
      assert {:ok, _} = store(claim, 1, report([counter(2, "ath_a", subject: "srv_x")]), %{})
      assert [%{rev: 2, name: "Claude Code", shown: "program"}] = all()

      browser = %{{"ath_a", "srv_b"} => %{name: "aqua-browser", shown: "browser"}}

      assert {:ok, _} =
               store(
                 claim,
                 2,
                 report([counter(3, "ath_a", subject: "srv_b", kind: "terminal")]),
                 browser
               )

      assert %{shown: "terminal", name: "aqua-browser"} =
               Enum.find(all(), &(&1.subject == "srv_b"))
    end
  end

  describe "the reads" do
    setup %{claim: claim} do
      page =
        report([
          counter(1, "ath_a", subject: "srv_a", bytes: 100),
          counter(2, "ath_b", subject: "srv_b", bytes: 300),
          counter(3, "ath_b", kind: "build", subject: nil, bytes: 50)
        ])

      {:ok, _} =
        store(claim, 0, page, %{{"ath_b", "srv_b"} => %{name: "Codex", shown: "program"}})

      :ok
    end

    test "an athanor reads its own counters alone, and the platform every athanor's" do
      assert {:ok, [%{athanor_id: "ath_a", subject: "srv_a"}]} =
               MemoryRecord.counters(Arca.Test.Actor.local(athanor_id: "ath_a"))

      assert {:ok, b} = MemoryRecord.counters(Arca.Test.Actor.local(athanor_id: "ath_b"))
      assert b |> Enum.map(& &1.athanor_id) |> Enum.uniq() == ["ath_b"]

      assert {:ok, every} = MemoryRecord.counters(Prima.Actor.system())
      assert every |> Enum.map(& &1.athanor_id) |> Enum.sort() == ~w(ath_a ath_b ath_b)

      assert {:error, :no_athanor} =
               MemoryRecord.counters(%Prima.Actor{athanor_id: nil, scope: :athanor})
    end

    test "every other athanor's use reaches a person as one sum per endpoint, of its current boot alone",
         %{claim: claim} do
      assert {:ok, %{@endpoint => 350}} =
               MemoryRecord.others_bytes(Arca.Test.Actor.local(athanor_id: "ath_a"))

      assert {:ok, %{@endpoint => 100}} =
               MemoryRecord.others_bytes(Arca.Test.Actor.local(athanor_id: "ath_b"))

      # The keeper restarted: what the old boot held is held no more.
      {:ok, %{boot: :new}} = store(claim, 3, report([], boot: @other_boot))
      assert {:ok, others} = MemoryRecord.others_bytes(Arca.Test.Actor.local(athanor_id: "ath_a"))
      assert Map.get(others, @endpoint, 0) == 0
    end

    test "only the platform purges, and the purge takes the days before the one named" do
      assert {:error, :cross_tenant} =
               MemoryRecord.purge(Arca.Test.Actor.local(athanor_id: "ath_a"), today())

      assert {:ok, 0} = MemoryRecord.purge(Prima.Actor.system(), today())
      assert length(all()) == 3

      assert {:ok, 4} = MemoryRecord.purge(Prima.Actor.system(), Date.add(today(), 2))
      assert all() == []
      assert endpoint() == nil
    end

    test "a past day goes and today stays", %{claim: claim} do
      yesterday = Date.add(today(), -1)

      {:ok, _} =
        store(claim, 3, report([counter(4, "ath_a", subject: "srv_old", day: yesterday)]))

      assert {:ok, 1} = MemoryRecord.purge(Prima.Actor.system(), today())
      assert all() |> Enum.map(& &1.day) |> Enum.uniq() == [today()]
      assert %{after: 4} = endpoint()
    end
  end
end
