# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RetentionSchedulerTest do
  @moduledoc """
  The retention cycle is the cell's, not each member's: one claimant acts,
  a member that loses the claim stops where it stands, and the cursor it
  leaves on the row is what its successor carries on from.

  `job_claims` is shared, cross-node, node-global state that many test
  files write. Every case here takes a claim key of its own and measures
  the row it wrote, never a count of rows.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.JobClaims
  alias Arca.Schemas.JobClaim
  alias Cyfr.RetentionScheduler

  @kind "retention"

  setup do
    # Ensure no lingering scheduler
    case GenServer.whereis(RetentionScheduler) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # handle_continue(:first_run, ...) runs a cycle, which hits the DB
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, key: "cell-retention-#{System.unique_integer([:positive])}"}
  end

  describe "init/1" do
    test "starts with {:continue, :first_run}" do
      prev_interval = Application.get_env(:cyfr, :retention_scheduler_interval)

      # Use a very long interval to avoid actual cleanup during test
      Application.put_env(:cyfr, :retention_scheduler_interval, :timer.hours(999))

      on_exit(fn ->
        if prev_interval,
          do: Application.put_env(:cyfr, :retention_scheduler_interval, prev_interval),
          else: Application.delete_env(:cyfr, :retention_scheduler_interval)
      end)

      assert {:ok, %{interval: _}, {:continue, :first_run}} = RetentionScheduler.init([])
    end
  end

  describe "handle_continue/2" do
    test "returns {:noreply, state}" do
      state = %{interval: :timer.hours(999)}
      assert {:noreply, ^state} = RetentionScheduler.handle_continue(:first_run, state)
    end
  end

  describe "handle_info/2" do
    test "handles unexpected messages gracefully" do
      state = %{interval: :timer.hours(6)}
      assert {:noreply, ^state} = RetentionScheduler.handle_info(:unexpected, state)
    end
  end

  describe "the cell's claim" do
    test "two members on one sweep: one acts, and the loser can tell which case it is", %{
      key: key
    } do
      {:ok, held} = JobClaims.claim(@kind, key, "member-a", 60_000)

      assert {:busy, "member-a"} = RetentionScheduler.cycle(key: key, owner: "member-b")

      # Nothing is written under a claim this member never held: same
      # fence, same (absent) cursor.
      assert {:ok, untouched} = JobClaims.read(@kind, key)
      assert untouched.fence == held.fence
      assert untouched.owner == "member-a"
      assert untouched.detail == nil
    end

    test "a tick on a member that holds no slot asks the store nothing", %{key: key} do
      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)

      state = %{interval: :timer.hours(999), job: [key: key, owner: "member-a"]}

      assert {:noreply, ^state} =
               Arca.Test.QueryCounter.assert_queries(0, fn ->
                 RetentionScheduler.handle_info(:run_cleanup, state)
               end)

      assert {:error, :not_found} = JobClaims.read(@kind, key)
    end

    test "a cycle that completes releases the row and records that it finished", %{key: key} do
      assert {:ok, summary} = RetentionScheduler.cycle(key: key, owner: "member-a")

      refute summary.resumed
      assert "flush" in summary.steps
      assert "blobs" in summary.steps

      assert {:ok, done} = JobClaims.read(@kind, key)
      assert done.owner == "member-a"
      refute JobClaims.live?(done)
      assert %{"step" => nil} = Jason.decode!(done.detail)
    end
  end

  describe "losing the claim mid-cycle" do
    test "a lapse stops the cycle and still records the cursor a successor inherits", %{key: key} do
      first = List.first(active_ids())

      # The lease runs out under the walk, with nobody taking the row:
      # the write that expires it touches no fence, so the row still reads
      # this member at the fence it holds — which is what `:lapsed` means.
      expire_on_first_athanor(key)

      assert {:stopped, :lapsed, summary} =
               RetentionScheduler.cycle(key: key, owner: "member-a", renew_ms: 0)

      # It stopped where it stood rather than finishing under a lease it
      # no longer held.
      refute "sessions" in summary.steps
      assert summary.athanors == [first]

      # Recording is an act of evidence, so it lands lease or no lease.
      assert {:ok, row} = JobClaims.read(@kind, key)
      assert row.owner == "member-a"
      assert %{"step" => "retention", "athanor" => ^first} = Jason.decode!(row.detail)
    end

    test "a claim a peer took stops the cycle, and the loser writes nothing more", %{key: key} do
      steal_on_first_athanor(key, "member-b")

      assert {:stopped, :taken, summary} =
               RetentionScheduler.cycle(key: key, owner: "member-a", renew_ms: 0)

      refute "sessions" in summary.steps

      assert {:ok, row} = JobClaims.read(@kind, key)
      assert row.owner == "member-b"
      assert JobClaims.live?(row)

      # The cursor on the peer's row is the one the loser wrote while it
      # still held the claim — the athanor it finished afterwards never
      # landed. Nothing issued under the old claim reaches the row.
      assert %{"step" => "retention", "athanor" => nil} = Jason.decode!(row.detail)
    end

    test "the successor resumes from the cursor rather than restarting or skipping", %{key: key} do
      active = active_ids()
      assert length(active) > 1, "this case needs more than one active athanor to resume inside"

      cursor_at = Enum.at(active, div(length(active), 2) - 1)
      left = Enum.filter(active, &(&1 > cursor_at))

      # A predecessor that reached `cursor_at` and then lapsed. The
      # takeover leaves `detail` exactly as it found it.
      {:ok, lapsing} = JobClaims.claim(@kind, key, "member-a", 1)

      {:ok, _} =
        JobClaims.record(
          lapsing,
          Jason.encode!(%{
            "cycle" => DateTime.to_iso8601(Arca.ServerMetaStorage.now!()),
            "step" => "retention",
            "athanor" => cursor_at
          })
        )

      Process.sleep(10)

      assert {:ok, summary} =
               RetentionScheduler.cycle(
                 key: key,
                 owner: "member-b",
                 renew_ms: 0,
                 interval: :timer.hours(1)
               )

      assert summary.resumed
      # Neither restarted (the steps before the cursor are not repeated,
      # nor the athanors already swept) nor skipped (every athanor after
      # the cursor is).
      refute "flush" in summary.steps
      refute cursor_at in summary.athanors
      assert summary.athanors == left
      assert "sessions" in summary.steps
    end

    test "a cycle older than the tick interval is due again, not resumed", %{key: key} do
      {:ok, stale} = JobClaims.claim(@kind, key, "member-a", 1)

      {:ok, _} =
        JobClaims.record(
          stale,
          Jason.encode!(%{
            "cycle" =>
              Arca.ServerMetaStorage.now!()
              |> DateTime.add(-2, :hour)
              |> DateTime.to_iso8601(),
            "step" => "retention",
            "athanor" => List.first(active_ids())
          })
        )

      Process.sleep(10)

      assert {:ok, summary} =
               RetentionScheduler.cycle(
                 key: key,
                 owner: "member-b",
                 renew_ms: 0,
                 interval: :timer.minutes(30)
               )

      refute summary.resumed
      assert "flush" in summary.steps
      assert summary.athanors == active_ids()
    end
  end

  defp active_ids,
    do: Sanctum.Tenancy.Athanors.list_active() |> Enum.map(& &1.id) |> Enum.sort()

  # `[:cyfr, :storage_gc, :sweep]` fires inside the staged-revision
  # retention kind, synchronously in the sweeping process, once per
  # athanor. It is the observable event this member reaching its first
  # athanor produces, so what these hooks do to the row lands before the
  # renew that follows that athanor — no sleeping on a race.
  defp on_first_athanor(fun) do
    handler = "retention-claim-#{System.unique_integer([:positive])}"
    once = :counters.new(1, [:atomics])

    :telemetry.attach(
      handler,
      [:cyfr, :storage_gc, :sweep],
      fn _event, _measurements, _metadata, _config ->
        if :counters.get(once, 1) == 0 do
          :counters.add(once, 1, 1)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  # Time passing under the holder: the lease runs out and no fence moves,
  # so the row still reads the holder at the fence it carries.
  defp expire_on_first_athanor(key) do
    on_first_athanor(fn ->
      Arca.Repo.update_all(
        from(c in JobClaim, where: c.kind == ^@kind and c.key == ^key),
        set: [lease_until: DateTime.add(Arca.ServerMetaStorage.now!(), -1, :second)]
      )
    end)
  end

  # The same lapse, and then a peer that takes the row.
  defp steal_on_first_athanor(key, peer) do
    on_first_athanor(fn ->
      Arca.Repo.update_all(
        from(c in JobClaim, where: c.kind == ^@kind and c.key == ^key),
        set: [lease_until: DateTime.add(Arca.ServerMetaStorage.now!(), -1, :second)]
      )

      {:ok, _} = JobClaims.claim(@kind, key, peer, 60_000)
    end)
  end
end
