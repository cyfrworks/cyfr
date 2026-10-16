# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsumerReceiptsLeaseWaitTest do
  @moduledoc """
  A receipt written alone (`Arca.ConsumerReceipts.record/4`) waits on the
  member's lease row after it has held its job claim: a claim that runs
  out during that wait, on the database clock, writes nothing, though
  the member stays live. PostgreSQL only: SQLite's one write lock leaves
  no wait between the two.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{ConsumerReceipts, ControlPlane, JobClaims}
  alias Arca.Schemas.{CellLease, ConsumerReceipt, JobClaim}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @lease_ms 1_000
  @cache_keys Enum.map([:standing, :generation, :slot], &{ControlPlane, &1})

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    athanor_id = "ath_receipt_wait_" <> suffix
    node = "node-receipt-wait-" <> suffix
    saved = Map.new(@cache_keys, &{&1, :persistent_term.get(&1, :absent)})

    # Task callbacks registered below run first, so their connections are
    # gone before this callback removes the disposable rows.
    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(r in ConsumerReceipt, where: r.athanor_id == ^athanor_id))

        Arca.Repo.delete_all(
          from(c in JobClaim, where: c.kind == "schedule_notes" and c.key == ^athanor_id)
        )

        Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node))
      end)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    assert {:ok, slot} = unboxed(fn -> ControlPlane.take(node, node <> "#boot", 60_000) end)

    {:ok,
     actor: Prima.Actor.in_athanor(athanor_id),
     athanor_id: athanor_id,
     node: node,
     slot: slot,
     source_id: "occ_receipt_wait_" <> suffix}
  end

  test "a receipt that waits past its job lease on a live member writes nothing", ctx do
    test = self()

    blocker =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            from(l in CellLease, where: l.node == ^ctx.node)
            |> Arca.QueryHelpers.for_update()
            |> Arca.Repo.one!()

            %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
            send(test, {:lease_row_locked, backend})

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    on_exit(fn -> stop_task(blocker.pid) end)
    assert_receive {:lease_row_locked, backend}, 5_000

    assert {:ok, claim} =
             unboxed(fn ->
               JobClaims.claim("schedule_notes", ctx.athanor_id, "boot_receipt_wait", @lease_ms)
             end)

    source = %{
      source_kind: "schedule_occurrence",
      source_id: ctx.source_id,
      source_revision: "r1"
    }

    receipt = Map.merge(source, %{consumer: "schedule_notes", outcome: "applied"})

    writer =
      Task.async(fn ->
        unboxed(fn -> ConsumerReceipts.record(ctx.actor, claim, ctx.slot, receipt) end)
      end)

    on_exit(fn -> stop_task(writer.pid) end)

    try do
      # Reaching this SELECT means hold/1 has already won the job row and
      # checked a live claim; only the member's lease row is blocking it.
      Prima.Test.Wait.wait_until(
        fn -> unboxed(fn -> blocked_on_lease?(backend) end) end,
        5_000,
        "the receipt writer to wait on this member's lease row"
      )

      Prima.Test.Wait.wait_until(
        fn ->
          unboxed(fn ->
            DateTime.compare(Arca.ServerMetaStorage.now!(), claim.lease_until) == :gt
          end)
        end,
        @lease_ms + 5_000,
        "the held job claim to expire on the database clock"
      )

      send(blocker.pid, :release)
      assert {:ok, :ok} = Task.await(blocker, 10_000)
      answer = Task.await(writer, 10_000)
      stored = unboxed(fn -> ConsumerReceipts.outcome(ctx.actor, "schedule_notes", source) end)

      # The member stayed live: an expired member cannot explain refusal.
      assert {:ok, :ok} =
               unboxed(fn ->
                 Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(ctx.slot) end)
               end)

      assert :lapsed = unboxed(fn -> JobClaims.renew(claim, 30_000) end)

      assert answer == :lapsed and stored == :none,
             "the job expired while the receipt waited; answered #{inspect(answer)}, stored #{inspect(stored)}"
    after
      Task.shutdown(writer, :brutal_kill)
      Task.shutdown(blocker, :brutal_kill)
    end
  end

  defp blocked_on_lease?(backend) do
    %{rows: [[count]]} =
      Arca.Repo.query!(
        """
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
          AND $1 = ANY(pg_blocking_pids(pid))
          AND query LIKE 'SELECT%cell_leases%FOR SHARE%'
        """,
        [backend]
      )

    count == 1
  end

  defp stop_task(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        5_000 -> raise "the probe's task did not stop"
      end
    end
  end
end
