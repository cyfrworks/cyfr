# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ControlPlaneTest do
  @moduledoc """
  The `cell_leases` row a member claims, and the cached standing every
  gate in the product reads.

  The record is process-wide, so each case saves what it finds and puts it
  back: the suite's other cases read the same term, and a case that leaves
  its own standing behind would be deciding theirs. Every case names its
  own node slot for the same reason — nothing else writes that row, so
  what the case measures is its own.
  """

  # Writes the process-wide standing record and the application's claim
  # switch, so it runs alone and restores both.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease

  @standing_key {Arca.ControlPlane, :standing}
  @generation_key {Arca.ControlPlane, :generation}
  @slot_key {Arca.ControlPlane, :slot}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    standing = :persistent_term.get(@standing_key, :absent)
    generation = :persistent_term.get(@generation_key, :absent)
    slot = :persistent_term.get(@slot_key, :absent)
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      restore(@standing_key, standing)
      restore(@generation_key, generation)
      restore(@slot_key, slot)
      Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    # A slot nothing else in the suite writes, so every count and instant
    # this case measures is its own.
    {:ok, node: "node-#{System.unique_integer([:positive])}"}
  end

  describe "the hot path" do
    test "held?/0 answers without a query" do
      :ok = ControlPlane.record({:held, 60_000})

      assert assert_queries(0, fn -> ControlPlane.held?() end)

      # And the same when it answers no, whichever way it gets there.
      :ok = ControlPlane.record(:lost)
      refute assert_queries(0, fn -> ControlPlane.held?() end)

      # The one branch that reads anything outside the record reads the
      # deployment's switch, which is an application key and not a query.
      claimed_here(true)
      :ok = ControlPlane.record(:unclaimed)
      refute assert_queries(0, fn -> ControlPlane.held?() end)
    end

    test "generation/0 answers without a query" do
      :ok = ControlPlane.record_generation(7)
      assert assert_queries(0, fn -> ControlPlane.generation() end) == {:ok, 7}

      :ok = ControlPlane.forget_generation()
      claimed_here(true)
      assert assert_queries(0, fn -> ControlPlane.generation() end) == {:error, :unavailable}
    end

    test "a slot won is still answered without a query", %{node: node} do
      assert {:ok, _slot} = ControlPlane.take(node, "boot_a", 60_000)

      assert assert_queries(0, fn -> ControlPlane.held?() end)
      assert assert_queries(0, fn -> ControlPlane.generation() end) == {:ok, 1}
      assert {:ok, %{node: ^node}} = assert_queries(0, fn -> ControlPlane.held() end)
    end
  end

  describe "what a member holds" do
    test "a member that has recorded nothing holds nothing while a claimant runs here" do
      claimed_here(true)
      :ok = ControlPlane.record(:unclaimed)

      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
    end

    test "with no claimant there is no slot to take, so every boot holds and none is fenced" do
      claimed_here(false)
      :ok = ControlPlane.record(:unclaimed)
      :ok = ControlPlane.forget_generation()

      assert ControlPlane.held?()
      assert ControlPlane.generation() == :none
    end

    test "a lapse is not held, whatever the deployment's switch says" do
      :ok = ControlPlane.record(:lost)

      claimed_here(false)
      refute ControlPlane.held?()

      claimed_here(true)
      refute ControlPlane.held?()
    end

    test "an indefinite hold is the one that does not run out" do
      :ok = ControlPlane.record({:held, :indefinitely})
      assert ControlPlane.held?()
    end
  end

  describe "the local clock" do
    test "a hold is a duration counted down, and runs out on its own" do
      :ok = ControlPlane.record({:held, 60})
      assert ControlPlane.held?()

      Process.sleep(100)
      refute ControlPlane.held?()

      # Recording again is how a renewal is heard; nothing else moves it.
      :ok = ControlPlane.record({:held, 60_000})
      assert ControlPlane.held?()
    end

    test "a hold of no time left is already over" do
      :ok = ControlPlane.record({:held, 0})
      refute ControlPlane.held?()
    end

    test "the countdown is monotonic: it is stored as an instant, not a wall time" do
      :ok = ControlPlane.record({:held, 60_000})

      assert {:held, deadline} = :persistent_term.get(@standing_key)
      assert is_integer(deadline)

      # Within a lease of now on the monotonic clock, and far from any
      # value a wall clock in milliseconds would produce.
      left = deadline - System.monotonic_time(:millisecond)
      assert left > 59_000 and left <= 60_000
    end
  end

  describe "the generation" do
    test "a recorded generation is the member's, and forgetting it is not the same as none" do
      claimed_here(true)

      :ok = ControlPlane.record_generation(3)
      assert ControlPlane.generation() == {:ok, 3}

      # A successor's take raises it; nothing else does.
      :ok = ControlPlane.record_generation(4)
      assert ControlPlane.generation() == {:ok, 4}

      :ok = ControlPlane.forget_generation()
      assert ControlPlane.generation() == {:error, :unavailable}

      :ok = ControlPlane.record_generation(:none)
      assert ControlPlane.generation() == :none
    end
  end

  describe "taking a slot" do
    test "a slot nobody has held opens at generation 1 and fence 1", %{node: node} do
      before = Arca.ServerMetaStorage.now!()
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)

      assert %{node: ^node, owner: "boot_a", generation: 1, fence: 1} = slot
      assert {:ok, row} = ControlPlane.slot(node)

      # The lease is counted from the DATABASE's clock inside the write,
      # not from anything the caller passed in.
      assert DateTime.compare(row.lease_until, DateTime.add(before, 60_000, :millisecond)) != :lt
      assert DateTime.compare(row.taken_at, before) != :lt
    end

    test "a second member cannot hold a slot while the first's lease stands", %{node: node} do
      assert {:ok, %{fence: 1}} = ControlPlane.take(node, "boot_a", 60_000)

      assert {:busy, row} = ControlPlane.take(node, "boot_b", 60_000)
      assert row.owner == "boot_a"
      assert row.generation == 1
      assert row.fence == 1

      # And nothing was written: the refused taker left the row as it
      # found it.
      assert {:ok, %{owner: "boot_a", generation: 1, fence: 1}} = ControlPlane.slot(node)
    end

    test "past lease_until the takeover raises the generation and the fence, and the old " <>
           "owner's writes are refused",
         %{node: node} do
      assert {:ok, first} = ControlPlane.take(node, "boot_a", 60_000)

      # The interleaving is made here rather than waited for: the row is
      # put past its lease on the cell's clock, which is the one condition
      # a takeover turns on.
      expire(node)

      assert {:ok, second} = ControlPlane.take(node, "boot_b", 60_000)
      assert second.owner == "boot_b"
      assert second.generation == first.generation + 1
      assert second.fence == first.fence + 1

      # The predecessor's own renew names the fence it last wrote, which
      # the takeover moved: it writes nothing and it holds nothing.
      :ok = ControlPlane.record_slot(first)
      :ok = ControlPlane.record({:held, 60_000})

      assert ControlPlane.renew(60_000) == :taken
      refute ControlPlane.held?()
      taken_at = second.generation
      assert {:ok, %{owner: "boot_b", generation: ^taken_at}} = ControlPlane.slot(node)
    end

    test "the same boot taking its own live slot renews it: the fence rises, the generation " <>
           "does not",
         %{node: node} do
      assert {:ok, first} = ControlPlane.take(node, "boot_a", 60_000)
      assert {:ok, again} = ControlPlane.take(node, "boot_a", 60_000)

      assert again.generation == first.generation
      assert again.fence == first.fence + 1
      assert ControlPlane.held?()
    end

    test "a slot released is takeable at once, keeping its owner and its generation", %{node: node} do
      claimed_here(true)
      assert {:ok, first} = ControlPlane.take(node, "boot_a", 60_000)
      assert ControlPlane.release() == :ok

      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
      assert ControlPlane.held() == :none

      # The row is kept — never deleted — so the successor's generation
      # carries on from its predecessor's instead of starting again at one.
      assert {:ok, row} = ControlPlane.slot(node)
      assert row.owner == "boot_a"
      assert row.generation == first.generation

      assert {:ok, second} = ControlPlane.take(node, "boot_b", 60_000)
      assert second.generation == first.generation + 1
    end
  end

  describe "renewing" do
    test "a renew that finds a newer generation flips held?/0 to false before returning", %{
      node: node
    } do
      claimed_here(true)
      assert {:ok, mine} = ControlPlane.take(node, "boot_a", 60_000)
      assert ControlPlane.held?()

      # A successor takes the slot while this member believes it holds it.
      expire(node)
      assert {:ok, successor} = ControlPlane.take(node, "boot_b", 60_000)
      assert successor.generation > mine.generation

      :ok = ControlPlane.record_slot(mine)
      :ok = ControlPlane.record({:held, 60_000})
      assert ControlPlane.held?()

      # The renew is this member's own call, so "before returning" is
      # exactly this: nothing of this member's runs between the discovery
      # and the answer, and the answer arrives with the standing already
      # down.
      assert ControlPlane.renew(60_000) == :taken
      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
      assert ControlPlane.held() == :none
    end

    test "a lease that merely ran out is renewed while the row still reads this member", %{
      node: node
    } do
      assert {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
      expire(node)
      :ok = ControlPlane.record(:lost)

      # Nobody took it, so it is still this member's and the renew lands.
      assert {:ok, renewed} = ControlPlane.renew(60_000)
      assert renewed.owner == "boot_a"
      assert renewed.generation == 1
      assert renewed.fence == 2
      assert ControlPlane.held?()
    end

    test "a member holding nothing renews nothing" do
      :ok = ControlPlane.forget()
      assert ControlPlane.renew(60_000) == :unclaimed
      assert ControlPlane.release() == :unclaimed
    end
  end

  describe "the two clocks" do
    test "a member with a clock ahead of the database cannot hold past the point its row " <>
           "became takeable",
         %{node: node} do
      lease_ms = 60_000
      assert {:ok, _slot} = ControlPlane.take(node, "boot_a", lease_ms)

      # The member's own belief, and the row's own life, each measured as
      # this case's own delta against the clock that decides it.
      {:held, deadline} = :persistent_term.get(@standing_key)
      believes_ms = deadline - System.monotonic_time(:millisecond)

      {:ok, row} = ControlPlane.slot(node)
      row_ms = DateTime.diff(row.lease_until, Arca.ServerMetaStorage.now!(), :millisecond)

      # What the member believes runs out FIRST, by the margin it gives up
      # for the two clocks' rate difference.
      assert believes_ms < row_ms
      assert row_ms - believes_ms >= ControlPlane.margin_ms() - 500

      # And the belief is not read off the row. A member whose own wall
      # clock ran an hour ahead of the database's would have written this
      # lease for itself under the old contract; the countdown does not
      # move, because it was never a deadline taken from the row.
      far = DateTime.add(Arca.ServerMetaStorage.now!(), 3_600_000, :millisecond)
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node), set: [lease_until: far])

      {:held, unchanged} = :persistent_term.get(@standing_key)
      assert unchanged == deadline
    end
  end

  describe "the roster" do
    test "the roster is the live slots, and a lapsed member is not on it", %{node: node} do
      peer = node <> "-peer"
      assert {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
      assert {:ok, _} = ControlPlane.take(peer, "boot_b", 60_000)

      assert {:ok, members} = ControlPlane.roster()
      nodes = Enum.map(members, & &1.node)
      assert node in nodes
      assert peer in nodes

      expire(peer)
      assert {:ok, members} = ControlPlane.roster()
      nodes = Enum.map(members, & &1.node)
      assert node in nodes
      refute peer in nodes
    end

    test "live_member?/1 is asked of a boot, so an older boot of the same node is not live", %{
      node: node
    } do
      assert {:ok, _} = ControlPlane.take(node, node <> "#boot_a", 60_000)
      assert ControlPlane.live_member?(node <> "#boot_a")

      # The node came back under a new boot id; what the old boot claimed
      # is no longer held by anyone.
      expire(node)
      assert {:ok, _} = ControlPlane.take(node, node <> "#boot_b", 60_000)

      assert ControlPlane.live_member?(node <> "#boot_b")
      refute ControlPlane.live_member?(node <> "#boot_a")
      refute ControlPlane.live_member?("")
    end
  end

  describe "verifying the slot inside a transaction" do
    test "a slot this member still holds verifies, moving neither the fence nor the cache", %{
      node: node
    } do
      claimed_here(true)
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)
      cached = {ControlPlane.held(), ControlPlane.generation(), ControlPlane.held?()}

      assert {:ok, :ok} = Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(slot) end)

      assert {:ok, %{fence: fence}} = ControlPlane.slot(node)
      assert fence == slot.fence
      assert {ControlPlane.held(), ControlPlane.generation(), ControlPlane.held?()} == cached
    end

    test "the claimant's renew moving the fence does not unseat it", %{node: node} do
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)
      assert {:ok, renewed} = ControlPlane.renew(60_000)
      assert renewed.fence > slot.fence

      # Node, owner and generation name the slot; the fence is the renew's.
      assert {:ok, :ok} = Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(slot) end)
    end

    test "a successor's generation, another owner or a lapsed lease is :lost", %{node: node} do
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)
      verify = fn s -> Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(s) end) end

      assert {:ok, :lost} = verify.(%{slot | owner: "boot_other"})
      assert {:ok, :lost} = verify.(%{slot | generation: slot.generation + 1})

      expire(node)
      assert {:ok, :lost} = verify.(slot)

      assert {:ok, successor} = ControlPlane.take(node, "boot_b", 60_000)
      assert {:ok, :lost} = verify.(slot)
      assert {:ok, :ok} = verify.(successor)
    end

    test "outside a transaction it refuses to answer", %{node: node} do
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)

      assert_raise ArgumentError, ~r/inside a locking transaction/, fn ->
        ControlPlane.verify_held(slot)
      end
    end
  end

  # The row put past its lease on the cell's clock — the one condition a
  # takeover turns on, made rather than waited for.
  defp expire(node) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)
    {1, _} = Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node), set: [lease_until: past])
    :ok
  end

  defp claimed_here(enabled),
    do: Application.put_env(:arca, :control_plane_claim_enabled, enabled)

  defp restore(key, :absent), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)

  defp assert_queries(n, fun), do: Arca.Test.QueryCounter.assert_queries(n, fun)
end

defmodule Arca.ControlPlaneLockTest do
  @moduledoc """
  `Arca.ControlPlane.verify_held/1` under two real connections, outside
  the sandbox: a verify that waited behind a release decides on the
  database's clock read after the wait, so it answers `:lost` rather
  than passing on an instant taken before the slot was given up.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Ecto.Adapters.SQL.Sandbox

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    node = "node-lock-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      unboxed(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)

      for {key, value} <- saved do
        if value == :absent, do: :persistent_term.erase(key), else: :persistent_term.put(key, value)
      end
    end)

    {:ok, node: node}
  end

  test "a verify waiting behind a release answers :lost on the clock read after its wait", %{
    node: node
  } do
    {:ok, slot} = unboxed(fn -> ControlPlane.take(node, "boot_a", 60_000) end)
    test = self()

    releaser =
      Task.async(fn ->
        unboxed(fn ->
          Arca.Repo.locking_transaction(fn ->
            now = Arca.ServerMetaStorage.now!()

            {1, _} =
              Arca.Repo.update_all(
                from(l in CellLease, where: l.node == ^node),
                set: [lease_until: now, fence: slot.fence + 1]
              )

            send(test, :releasing)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :releasing, 5_000

    verifier =
      Task.async(fn ->
        unboxed(fn -> Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(slot) end) end)
      end)

    refute Task.yield(verifier, 300), "the verify answered while the release held the row"
    # The release instant is now in the past on every clock the verify
    # could read after its wait.
    Process.sleep(20)
    send(releaser.pid, :commit)
    assert {:ok, :ok} = Task.await(releaser, 25_000)
    assert {:ok, :lost} = Task.await(verifier, 25_000)
  end
end
