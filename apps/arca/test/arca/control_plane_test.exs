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

    test "a slot released is takeable at once, keeping its owner and its generation", %{
      node: node
    } do
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

  describe "the slot a host-owned write names" do
    test "member_slot/0 answers the slot this member won and still believes it holds", %{
      node: node
    } do
      claimed_here(true)
      assert {:ok, slot} = ControlPlane.take(node, "boot_a", 60_000)
      assert {:ok, ^slot} = assert_queries(0, fn -> ControlPlane.member_slot() end)

      # Its own countdown ran out: no slot to name, whatever the row says.
      :ok = ControlPlane.record(:lost)
      assert {:error, :not_owner} = ControlPlane.member_slot()
    end

    test "no slot is :none only where no claimant runs" do
      :ok = ControlPlane.forget()
      :ok = ControlPlane.forget_generation()
      :ok = ControlPlane.record(:unclaimed)

      claimed_here(false)
      refute ControlPlane.claimed?()
      assert {:ok, :none} = ControlPlane.member_slot()

      # A generation known with no slot beside it is not a deployment
      # without a claimant.
      :ok = ControlPlane.record_generation(3)
      assert {:error, :not_owner} = ControlPlane.member_slot()
      :ok = ControlPlane.forget_generation()

      claimed_here(true)
      assert ControlPlane.claimed?()
      assert {:error, :not_owner} = ControlPlane.member_slot()

      # Only an explicit false turns the claimant off.
      claimed_here(nil)
      assert ControlPlane.claimed?()
    end

    test "verify_held/1 passes :none only where no claimant runs, inside a transaction" do
      claimed_here(true)

      assert {:ok, :lost} =
               Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(:none) end)

      assert :lost = ControlPlane.check_held(:none)

      claimed_here(false)
      assert {:ok, :ok} = Arca.Repo.locking_transaction(fn -> ControlPlane.verify_held(:none) end)

      assert_raise ArgumentError, ~r/inside a locking transaction/, fn ->
        ControlPlane.verify_held(:none)
      end
    end
  end

  # The row put past its lease on the cell's clock — the one condition a
  # takeover turns on, made rather than waited for.
  defp expire(node) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node), set: [lease_until: past])

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
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
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

defmodule Arca.ControlPlaneOwnPoolTest do
  @moduledoc """
  The control plane's writes on a pool of their own, outside the sandbox
  and on node rows of the case's own: an exhausted ordinary pool delays no
  renewal; an own pool configured and not running fails the write and
  never falls back; a failure after the update and before the commit
  publishes nothing. On SQLite a writer the arbiter does not order delays
  a renewal only while it holds the lock, and under the recorded audit
  burst every renewal lands. The renewal latencies under the burst and
  under a sustained non-audit burst are printed as measured.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Ecto.Adapters.SQL.Sandbox

  @sqlite? Arca.Repo.adapter() == Ecto.Adapters.SQLite3

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup do
    saved = standing()
    pool = Application.get_env(:arca, :control_plane_pool)
    turn = Application.get_env(:arca, :write_turn)
    node = "node-own-#{System.unique_integer([:positive])}"

    # Every process takes a real connection of its own, as a deployment's
    # does; the suite's mode is put back after.
    Sandbox.mode(Arca.Repo, :auto)

    on_exit(fn ->
      Application.put_env(:arca, :control_plane_pool, pool)
      Application.put_env(:arca, :write_turn, turn)
      run(fn -> Arca.Repo.delete_all(from(l in CellLease, where: l.node == ^node)) end)
      Sandbox.mode(Arca.Repo, :manual)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end
    end)

    # The control plane on its own pool, and on SQLite the writers taking
    # turns at the write lock, as a deployment's do.
    Application.put_env(:arca, :control_plane_pool, true)
    Application.put_env(:arca, :write_turn, true)
    {:ok, node: node}
  end

  test "an exhausted ordinary pool delays no renewal: the writes have their own connection", %{
    node: node
  } do
    own_pool!()
    {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
    test = self()

    holders =
      for _ <- 1..Arca.Repo.config()[:pool_size] do
        pid =
          spawn(fn ->
            Arca.Repo.checkout(
              fn ->
                send(test, :out)
                receive do: (:go -> :ok)
              end,
              timeout: :infinity
            )
          end)

        on_exit(fn -> Process.exit(pid, :kill) end)
        pid
      end

    for _ <- holders, do: assert_receive(:out, 10_000)

    # Every ordinary connection is out and stays out until the renewal has
    # answered: one waiting for the ordinary pool could not answer at all.
    assert {:ok, _slot} = ControlPlane.renew(60_000)
    assert {:ok, _slot} = ControlPlane.member_slot()

    for pid <- holders, do: send(pid, :go)
  end

  test "an own pool configured and not running fails the write, and nothing falls back", %{
    node: node
  } do
    :ok = ControlPlane.forget()

    log =
      capture_log(fn ->
        assert {:error, :database_error} = ControlPlane.take(node, "boot_a", 60_000)
      end)

    assert log =~ "own pool is not running"
    assert ControlPlane.held() == :none
    assert {:error, :not_found} = run(fn -> ControlPlane.slot(node) end)

    # A member already holding a slot keeps its standing: the failed renew
    # publishes nothing and the countdown runs on.
    slot = %{
      node: node,
      owner: "boot_a",
      generation: 1,
      fence: 1,
      lease_until: DateTime.utc_now()
    }

    :ok = ControlPlane.record_slot(slot)
    :ok = ControlPlane.record({:held, 60_000})
    before = standing()

    capture_log(fn -> assert {:error, :database_error} = ControlPlane.renew(60_000) end)
    assert standing() == before
    assert {:error, :not_found} = run(fn -> ControlPlane.slot(node) end)

    # A name that is taken but names no started repo fails the same way.
    squatter = start_supervised!({Agent, fn -> :not_a_pool end})
    true = Process.register(squatter, ControlPlane.pool_spec().id)

    capture_log(fn -> assert {:error, :database_error} = ControlPlane.renew(60_000) end)
    assert standing() == before
  end

  @tag capture_log: true
  test "an own pool that stops while a write waits for its connection fails the write", %{
    node: node
  } do
    own_pool!()
    {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
    before = standing()
    pool = ControlPlane.pool_spec().id
    test = self()

    # The pool's one connection is out, so the renewal waits for it.
    holder =
      spawn(fn ->
        Arca.Repo.put_dynamic_repo(pool)

        Arca.Repo.checkout(
          fn ->
            send(test, :holding)
            receive do: (:never -> :ok)
          end,
          timeout: :infinity
        )
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive :holding, 5_000
    renewal = Task.async(fn -> ControlPlane.renew(60_000) end)
    await(fn -> checking_out?(renewal.pid) end)

    :ok = stop_supervised(pool)
    assert {:error, :database_error} = Task.await(renewal, 10_000)
    assert standing() == before
  end

  test "a write failing after its update and before its commit publishes nothing", %{
    node: node
  } do
    own_pool!()
    {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
    {:ok, row} = run(fn -> ControlPlane.slot(node) end)
    before = standing()

    # SQLite raises in the update's own statement, after the row changed;
    # PostgreSQL raises at the commit, from a trigger deferred to it.
    fail_after_update!(node)

    capture_log(fn ->
      assert {:error, :database_error} = ControlPlane.renew(60_000)
      assert {:error, :database_error} = ControlPlane.take(node, "boot_a", 60_000)
    end)

    assert standing() == before
    assert {:ok, %{fence: fence, generation: generation}} = run(fn -> ControlPlane.slot(node) end)
    assert {fence, generation} == {row.fence, row.generation}
  end

  test "a writer killed after its update and before its commit publishes nothing", %{
    node: node
  } do
    own_pool!()
    {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
    {:ok, row} = run(fn -> ControlPlane.slot(node) end)
    before = standing()
    test = self()

    renewer =
      spawn(fn ->
        receive do: (:go -> ControlPlane.renew(60_000))
        send(test, :returned)
      end)

    handler = {__MODULE__, renewer}

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.kill_after_update/4, renewer)

    on_exit(fn -> :telemetry.detach(handler) end)
    ref = Process.monitor(renewer)
    send(renewer, :go)

    assert_receive {:DOWN, ^ref, :process, ^renewer, :killed}, 10_000
    refute_received :returned
    assert standing() == before
    assert {:ok, %{fence: fence}} = run(fn -> ControlPlane.slot(node) end)
    assert fence == row.fence

    # The pool's connection comes back, and the next renewal lands.
    :telemetry.detach(handler)
    assert {:ok, %{fence: renewed}} = ControlPlane.renew(60_000)
    assert renewed == row.fence + 1
  end

  @doc false
  # Kills `target` as its lease update returns, inside its transaction.
  def kill_after_update(_event, _measurements, %{query: query}, target) do
    if self() == target and String.starts_with?(query, ~s(UPDATE "cell_leases")),
      do: Process.exit(self(), :kill)
  end

  @tag timeout: 180_000
  test "under the recorded audit burst, 200 calls at concurrency 16, every renewal lands", %{
    node: node
  } do
    own_pool!()
    {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
    prefix = "call_burst_#{System.unique_integer([:positive])}_"

    on_exit(fn ->
      run(fn ->
        Arca.Repo.delete_all(from(r in "decision_logs", where: like(r.call_id, ^"#{prefix}%")))
      end)
    end)

    sampler = sample(&Arca.DecisionLog.writers/0)
    # Back to back, so the burst never passes between two renewals.
    renewer = renew_every(10)
    actor = Prima.Actor.in_athanor("ath_test")
    started = System.monotonic_time(:millisecond)

    answers =
      1..200
      |> Task.async_stream(fn i -> audited_call(actor, prefix <> "#{i}") end,
        max_concurrency: 16,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    burst_ms = System.monotonic_time(:millisecond) - started
    renewals = stop(renewer)
    writers = stop(sampler)

    assert renewals != []
    assert Enum.all?(renewals, &match?({{:ok, _slot}, _ms}, &1)), inspect(renewals)
    latencies = renewals |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert Enum.max(writers) <= Arca.DecisionLog.max_writers()
    assert ControlPlane.held?()

    lost = for {a, f} <- answers, answer <- [a, f], answer != :ok, do: elem(answer, 1).kind

    IO.puts(
      "control plane: under the audit burst (#{burst_ms} ms, #{adapter()}) #{length(latencies)} " <>
        "renewals, p50/p95/max #{percentile(latencies, 50)}/#{percentile(latencies, 95)}/" <>
        "#{List.last(latencies)} ms; at most #{Enum.max(writers)} audit writers; lost " <>
        inspect(Enum.frequencies(lost))
    )
  end

  if @sqlite? do
    test "a writer the arbiter does not order delays a renewal only while it holds the lock", %{
      node: node
    } do
      own_pool!()
      {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
      blocker = hold_write_lock()

      # The renewal holds its turn and steps its lock attempt inside the
      # driver before the lock goes: it waits only for the lock's holder,
      # and then at most a lock quantum.
      renewal = Task.async(fn -> timed(fn -> ControlPlane.renew(60_000) end) end)
      await(fn -> match?(%{holder: %{kind: :control_plane}}, Arca.WriteTurn.status()) end)
      await(fn -> stepping?(renewal.pid) end)
      released = unlock(blocker)

      assert {{:ok, _slot}, _ms, done} = Task.await(renewal, 15_000)
      assert done >= released
      assert done - released < 100, "the renewal came #{done - released} ms after"
    end

    # Inside the driver running a statement: stepping it, not preparing it.
    defp stepping?(pid) do
      case Process.info(pid, :current_function) do
        {:current_function, {Exqlite.Sqlite3NIF, step, _arity}} -> step in [:step, :multi_step]
        _elsewhere -> false
      end
    end

    test "a standalone write racing a renewal delays it by that statement and a quantum", %{
      node: node
    } do
      own_pool!()
      {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)

      # A standalone write that holds the lock for a while, standing in for
      # any ordinary write outside the arbiter's order
      # (`Arca.BuildRecords`' `update_all` among them).
      writer =
        Task.async(fn ->
          Arca.Repo.query!(long_statement(400), [], log: false, timeout: 15_000)
          System.monotonic_time(:millisecond)
        end)

      await_held!()
      {result, _ms, done} = timed(fn -> ControlPlane.renew(60_000) end)
      ended = Task.await(writer, 15_000)

      # That statement and at most a lock quantum more.
      assert {:ok, _slot} = result
      assert done - ended < 100, "the renewal came #{done - ended} ms after"
    end

    @tag timeout: 120_000
    test "a sustained non-audit write burst is measured, never prioritized", %{node: node} do
      own_pool!()
      {:ok, _} = ControlPlane.take(node, "boot_a", 60_000)
      noise = node <> "-noise"
      until = System.monotonic_time(:millisecond) + 2_000
      renewer = renew_every(100)

      writers =
        for _ <- 1..16 do
          Task.async(fn -> standalone_writes(noise, until, []) end)
        end

      writes = writers |> Enum.flat_map(&Task.await(&1, 60_000))
      renewals = stop(renewer)

      # Outside the audit's guarantee: every renewal answered, and what it
      # answered is recorded, not bounded. Standalone writers take the lock
      # through the lock step and no turn, so a renewal waits for them as
      # for any writer, within its lock step's deadline.
      assert renewals != []
      latencies = renewals |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      failed = Enum.count(renewals, fn {answer, _ms} -> not match?({:ok, _}, answer) end)
      refused = for {:busy, ms} <- writes, do: ms

      IO.puts(
        "control plane: under #{length(writes)} standalone writes from 16 writers in 2 s " <>
          "(#{length(refused)} refused busy, after at most #{Enum.max(refused, fn -> 0 end)} ms) " <>
          "#{length(latencies)} renewals, p50/p95/max #{percentile(latencies, 50)}/" <>
          "#{percentile(latencies, 95)}/#{List.last(latencies)} ms, #{failed} failed"
      )
    end

    # Standalone writes until `until`, each answered or refused busy by its
    # lock step; the refusals are part of what is measured, with how long
    # each waited first.
    defp standalone_writes(node, until, answered) do
      if System.monotonic_time(:millisecond) >= until do
        answered
      else
        started = System.monotonic_time(:millisecond)

        answer =
          try do
            Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
              set: [updated_at: DateTime.utc_now()]
            )

            :ok
          rescue
            _e in Arca.Repo.BusyTimeoutError ->
              {:busy, System.monotonic_time(:millisecond) - started}
          end

        standalone_writes(node, until, [answer | answered])
      end
    end

    defp database, do: Arca.Repo.config()[:database]

    defp hold_write_lock do
      {:ok, conn} = Exqlite.Sqlite3.open(database())
      :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")
      conn
    end

    defp unlock(conn) do
      :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
      released = System.monotonic_time(:millisecond)
      :ok = Exqlite.Sqlite3.close(conn)
      released
    end

    # A write that takes the lock when it starts and then runs for about
    # `ms`: a recursive count that inserts nothing.
    defp long_statement(ms) do
      {:ok, conn} = Exqlite.Sqlite3.open(database())

      {us, :ok} =
        :timer.tc(fn ->
          Exqlite.Sqlite3.execute(
            conn,
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 500000) " <>
              "SELECT count(*) FROM c WHERE x < 0"
          )
        end)

      :ok = Exqlite.Sqlite3.close(conn)
      rows = max(ms * div(500_000 * 1_000, max(us, 1)), 1_000)

      "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < #{rows}) " <>
        ~s|INSERT INTO "schema_migrations" (version) SELECT x FROM c WHERE x < 0|
    end

    # Until a connection of the repo's holds the lock, a probe outside every
    # pool takes and gives it back; then it finds it busy.
    defp await_held!(tries \\ 3_000) do
      {:ok, probe} = Exqlite.Sqlite3.open(database())
      :ok = Exqlite.Sqlite3.execute(probe, "PRAGMA busy_timeout = 0")

      try do
        probe(probe, tries)
      after
        Exqlite.Sqlite3.close(probe)
      end
    end

    defp probe(_probe, 0), do: flunk("no other connection took the lock")

    defp probe(probe, tries) do
      case Exqlite.Sqlite3.execute(probe, "BEGIN IMMEDIATE") do
        :ok ->
          :ok = Exqlite.Sqlite3.execute(probe, "ROLLBACK")
          Process.sleep(1)
          probe(probe, tries - 1)

        {:error, _busy} ->
          :ok
      end
    end

    # A trigger on the own pool's one connection, gone with it.
    defp fail_after_update!(node) do
      pool = ControlPlane.pool_spec().id

      run(fn ->
        Arca.Repo.put_dynamic_repo(pool)

        Arca.Repo.query!(
          "CREATE TEMP TRIGGER r0_fail_after_update AFTER UPDATE ON cell_leases " <>
            "WHEN NEW.node = '#{node}' BEGIN SELECT RAISE(ABORT, 'failed after the update'); END"
        )
      end)
    end
  else
    # A trigger deferred to the commit, for the case's own row alone, and
    # dropped after the case.
    defp fail_after_update!(node) do
      name = "r0_fail_#{System.unique_integer([:positive])}"

      run(fn ->
        Arca.Repo.query!(
          "CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS " <>
            "$$ BEGIN RAISE EXCEPTION 'failed at the commit'; END $$"
        )

        Arca.Repo.query!(
          "CREATE CONSTRAINT TRIGGER #{name} AFTER UPDATE ON cell_leases " <>
            "DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.node = '#{node}') " <>
            "EXECUTE FUNCTION #{name}()"
        )
      end)

      on_exit(fn ->
        run(fn ->
          Arca.Repo.query!("DROP TRIGGER IF EXISTS #{name} ON cell_leases")
          Arca.Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
        end)
      end)
    end
  end

  # ---- helpers ------------------------------------------------------------------

  defp own_pool!,
    do: start_supervised!(ControlPlane.pool_spec(pool: DBConnection.ConnectionPool))

  # Waiting in the pool's checkout for a connection.
  defp checking_out?(pid) do
    match?(
      {:current_function, {DBConnection.Holder, :checkout_call, _arity}},
      Process.info(pid, :current_function)
    )
  end

  defp await(fun, within_ms \\ 5_000),
    do: await_until(fun, System.monotonic_time(:millisecond) + within_ms)

  defp await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the condition never held")

      true ->
        Process.sleep(1)
        await_until(fun, deadline)
    end
  end

  defp standing, do: Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})

  defp run(fun), do: fun |> Task.async() |> Task.await(:infinity)

  defp adapter, do: if(@sqlite?, do: "SQLite", else: "PostgreSQL")

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    done = System.monotonic_time(:millisecond)
    {result, done - started, done}
  end

  # One call as the gate records it: its decision, then its completion.
  defp audited_call(actor, call_id) do
    decision =
      Prima.Decision.new(
        call_id: call_id,
        plane: :external,
        tool: "vault",
        action: "status",
        admission: :admitted,
        inserted_at: DateTime.utc_now()
      )

    appended = Arca.DecisionLog.append(actor, decision)
    {appended, Arca.DecisionLog.finish(actor, call_id, %{completion: :succeeded, duration_ms: 1})}
  end

  # A process renewing this member's slot every `ms` until stopped, keeping
  # each answer and how long it took.
  defp renew_every(ms) do
    spawn_link(fn -> renewing(ms, []) end)
  end

  defp renewing(ms, done) do
    {answer, took, _} = timed(fn -> ControlPlane.renew(60_000) end)
    done = [{answer, took} | done]

    receive do
      {:stop, from} -> send(from, {:stopped, Enum.reverse(done)})
    after
      ms -> renewing(ms, done)
    end
  end

  # A process reading `fun` every 5 ms until stopped, keeping each value.
  defp sample(fun), do: spawn_link(fn -> sampling(fun, []) end)

  defp sampling(fun, seen) do
    receive do
      {:stop, from} -> send(from, {:stopped, [fun.() | seen]})
    after
      5 -> sampling(fun, [fun.() | seen])
    end
  end

  defp stop(pid) do
    send(pid, {:stop, self()})
    assert_receive {:stopped, values}, 30_000
    values
  end

  defp percentile(sorted, p) do
    Enum.at(sorted, max(0, min(length(sorted) - 1, ceil(p / 100 * length(sorted)) - 1)))
  end
end
