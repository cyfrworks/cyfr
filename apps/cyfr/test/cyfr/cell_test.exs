# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CellTest do
  @moduledoc """
  This member's place in the cell: the claimant of its `cell_leases` slot,
  the rendezvous proposal over the live roster, and the seven conditions
  `CYFR_CLUSTER=1` boots only under.

  The claimant writes the process-wide standing record, so this file runs
  alone and puts back what it found. Every case that touches a row names a
  node slot of its own: `cell_leases` is cell-global, and a case asserting
  an absolute over it would be testing the suite's ordering rather than
  its own run.
  """

  # Starts the claimant against the sandbox and flips the process-wide
  # standing record, so it owns both for its run.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ControlPlane
  alias Arca.Schemas.CellLease
  alias Cyfr.Cell

  @standing_key {Arca.ControlPlane, :standing}
  @generation_key {Arca.ControlPlane, :generation}
  @slot_key {Arca.ControlPlane, :slot}
  @roster_key {Cyfr.Cell, :roster}

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Process.flag(:trap_exit, true)

    saved = for key <- keys(), do: {key, :persistent_term.get(key, :absent)}
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved, do: restore(key, value)
      Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    {:ok, node: "node-#{System.unique_integer([:positive])}"}
  end

  defp keys, do: [@standing_key, @generation_key, @slot_key, @roster_key]

  defp restore(key, :absent), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)

  defp me, do: Cyfr.Boot.id()

  # One renew tick, sent and then waited on: the claimant's own timer is
  # set beyond every case in this file, so a tick happens when a case
  # makes one and at no other moment.
  defp tick(pid) do
    send(pid, :renew)
    _ = :sys.get_state(pid)
    :ok
  end

  defp claim_enabled(enabled) do
    previous = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, enabled)
    on_exit(fn -> Application.put_env(:arca, :control_plane_claim_enabled, previous) end)
  end

  defp expire(node) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
        set: [lease_until: past]
      )

    :ok
  end

  # ---------------------------------------------------------------------------
  # The claimant
  # ---------------------------------------------------------------------------

  describe "the claimant" do
    test "a member takes its slot at start and gives it back at stop", %{node: node} do
      claim_enabled(true)

      {:ok, pid} =
        Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)

      assert ControlPlane.held?()
      assert {:ok, generation} = ControlPlane.generation()
      assert {:ok, %{node: ^node, owner: owner}} = ControlPlane.held()
      assert owner == me()

      :ok = GenServer.stop(pid)
      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
      assert ControlPlane.held() == :none

      # The row is left with its lease run out, so a successor takes it at
      # once — one generation up, because a take past the lease is a
      # takeover whoever made it.
      assert {:ok, next} = ControlPlane.take(node, "boot-next", 60_000)
      assert next.generation == generation + 1
    end

    test "a member believes it holds for less than its row lives", %{node: node} do
      claim_enabled(true)

      {:ok, pid} =
        Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)

      {:held, deadline} = :persistent_term.get(@standing_key)
      believes_ms = deadline - System.monotonic_time(:millisecond)

      {:ok, row} = ControlPlane.slot(node)
      row_ms = DateTime.diff(row.lease_until, Arca.ServerMetaStorage.now!(), :millisecond)

      assert believes_ms < row_ms
      :ok = GenServer.stop(pid)
    end

    test "a renew tick after a lapse wins the slot back", %{node: node} do
      claim_enabled(true)

      # The tick is driven here rather than waited for: the member's own
      # timer is set beyond every case in this file, so a tick happens
      # when a case makes one and at no other moment.
      {:ok, pid} = Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)
      assert ControlPlane.held?()

      # The member's countdown ran out — a database it could not reach for
      # longer than a lease — while nobody took its row.
      ControlPlane.record(:lost)
      ControlPlane.forget_generation()
      expire(node)
      refute ControlPlane.held?()

      tick(pid)
      assert ControlPlane.held?()
      assert {:ok, %{generation: 1, fence: 2}} = ControlPlane.held()

      :ok = GenServer.stop(pid)
    end

    test "a member taken over by a successor admits nothing and does not take a live slot back",
         %{node: node} do
      claim_enabled(true)

      {:ok, pid} = Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)
      assert {:ok, mine} = ControlPlane.held()

      # The interleaving is made: the row goes past its lease and a
      # successor takes it while this member still believes it holds.
      expire(node)
      assert {:ok, successor} = ControlPlane.take(node, "boot-successor", 60_000)
      assert successor.generation == mine.generation + 1

      # The take above wrote this VM's one standing record, which is the
      # test standing in for a second member; put back what the
      # taken-over member still believed.
      ControlPlane.record_slot(mine)
      ControlPlane.record_generation(mine.generation)
      ControlPlane.record({:held, 60_000})

      tick(pid)
      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}

      # And it does not take the successor's live slot back on the tick
      # after.
      tick(pid)
      refute ControlPlane.held?()
      assert {:ok, %{owner: "boot-successor"}} = ControlPlane.slot(node)

      :ok = GenServer.stop(pid)
    end

    test "a successor's take is refused while the predecessor's lease stands", %{node: node} do
      claim_enabled(true)
      assert {:ok, _} = ControlPlane.take(node, "boot-live", 60_000)

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Cell.start_link(name: nil, node_name: node, lease_ms: 500, renew_ms: 60_000)

      assert message =~ "another control plane (boot-live)"
    end

    test "a slot whose holder stopped without releasing is waited out and taken", %{node: node} do
      claim_enabled(true)
      assert {:ok, _} = ControlPlane.take(node, "boot-killed", 300)

      started = System.monotonic_time(:millisecond)
      {:ok, pid} = Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)
      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 250
      assert ControlPlane.held?()
      assert {:ok, %{owner: owner}} = ControlPlane.held()
      assert owner == me()

      :ok = GenServer.stop(pid)
    end

    test "a member that finds a live peer refuses to boot without the cluster flag", %{node: node} do
      claim_enabled(true)
      peer = node <> "-peer"

      # A peer holding a lease longer than this member's own is a live
      # server, not a predecessor to wait out: refused at once.
      assert {:ok, _} = ControlPlane.take(peer, "boot-peer", 60_000)

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Cell.start_link(name: nil, node_name: node, lease_ms: 500, renew_ms: 60_000)

      assert message =~ "another control plane (boot-peer on #{peer})"
      assert message =~ "CYFR_CLUSTER=1"

      # The refused member gave its own slot back, so it left the row as
      # it found it.
      assert {:ok, %{lease_until: until}} = ControlPlane.slot(node)
      assert DateTime.compare(until, Arca.ServerMetaStorage.now!()) != :gt
    end

    @tag :capture_log
    test "a peer whose name changed under it is waited out, not refused", %{node: node} do
      claim_enabled(true)
      peer = node <> "-peer"

      # The predecessor came back on a new address, so its old slot is a
      # row nobody renews: waited out once, within a lease of our own.
      assert {:ok, _} = ControlPlane.take(peer, "boot-gone", 300)

      started = System.monotonic_time(:millisecond)
      {:ok, pid} = Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)
      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 250
      assert ControlPlane.held?()

      :ok = GenServer.stop(pid)
    end

    @tag :capture_log
    test "a member that cannot read its slot refuses to start and holds no generation", %{
      node: node
    } do
      claim_enabled(true)
      Arca.Repo.query!("DROP TABLE cell_leases")

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Cell.start_link(name: nil, node_name: node, lease_ms: 60_000, renew_ms: 60_000)

      assert message =~ "could not be read or written"
      refute ControlPlane.held?()
      assert ControlPlane.generation() == {:error, :unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # The roster and the proposal
  # ---------------------------------------------------------------------------

  describe "rendezvous" do
    test "an empty roster proposes nothing" do
      assert Cell.owner_of("retention:cell", []) == {:error, :no_roster}
    end

    test "every member computes the same owner from the same roster" do
      members = for n <- 1..6, do: "m#{n}@cell"

      for subject <- subjects(50) do
        {:ok, owner} = Cell.owner_of(subject, members)
        assert {:ok, ^owner} = Cell.owner_of(subject, Enum.shuffle(members))
        assert owner in members
      end
    end

    test "losing a member moves only that member's subjects" do
      members = for n <- 1..6, do: "m#{n}@cell"
      gone = "m3@cell"
      remaining = members -- [gone]
      subjects = subjects(400)

      before = Map.new(subjects, &{&1, elem(Cell.owner_of(&1, members), 1)})
      after_ = Map.new(subjects, &{&1, elem(Cell.owner_of(&1, remaining), 1)})

      moved = for s <- subjects, before[s] != after_[s], do: s
      assert Enum.all?(moved, &(before[&1] == gone))

      # And a subject that was not the lost member's did not move at all.
      for s <- subjects, before[s] != gone, do: assert(after_[s] == before[s])
    end

    test "gaining a member moves about one subject in N, and every one of them to the newcomer" do
      members = for n <- 1..5, do: "m#{n}@cell"
      newcomer = "m6@cell"
      joined = members ++ [newcomer]
      subjects = subjects(600)

      before = Map.new(subjects, &{&1, elem(Cell.owner_of(&1, members), 1)})
      after_ = Map.new(subjects, &{&1, elem(Cell.owner_of(&1, joined), 1)})

      moved = for s <- subjects, before[s] != after_[s], do: s

      # Every subject that moved went TO the newcomer: no peer's
      # assignment changed hands with any other peer's.
      assert Enum.all?(moved, &(after_[&1] == newcomer))

      # And about one in six did, which is what makes a join cheap. The
      # band is wide enough for 600 samples of a hash.
      share = length(moved) / length(subjects)
      assert share > 1 / 12 and share < 1 / 3
    end

    test "the roster is this member's own read of the live slots, refreshed on its tick" do
      claim_enabled(true)
      here = Atom.to_string(node())
      subject = "worker_watch:wrk_#{System.unique_integer([:positive])}"

      # Before a roster is read, a proposal cannot be computed and is
      # therefore not made: a member that does not know the cell claims
      # nothing.
      :persistent_term.erase(@roster_key)
      assert Cell.owner_of(subject) == {:error, :no_roster}
      refute Cell.mine?(subject)

      {:ok, pid} = Cell.start_link(name: nil, lease_ms: 60_000, renew_ms: 60_000)

      # The only live slot is this member's, so every subject proposes it.
      assert Cell.roster() == [here]
      assert Cell.owner_of(subject) == {:ok, here}
      assert Cell.mine?(subject)

      # A peer joins; the member picks it up on its next tick and the
      # proposal follows the wider roster.
      peer = "peer-#{System.unique_integer([:positive])}@cell"
      assert {:ok, _} = ControlPlane.take(peer, "boot-peer", 60_000)
      tick(pid)
      assert Enum.sort(Cell.roster()) == Enum.sort([here, peer])
      assert Cell.mine?(subject) == (Cell.owner_of(subject) == {:ok, here})

      :ok = GenServer.stop(pid)
      assert Cell.roster() == []
      refute Cell.mine?(subject)
    end

    test "with no claimant there is no cell to defer to, so every subject is this member's" do
      claim_enabled(false)
      :persistent_term.erase(@roster_key)

      assert Cell.owner_of("retention:cell") == {:error, :no_roster}
      assert Cell.mine?("retention:cell")
    end
  end

  defp subjects(n), do: for(i <- 1..n, do: "subject-#{i}")

  # ---------------------------------------------------------------------------
  # The boot refusals
  # ---------------------------------------------------------------------------

  describe "the boot refusals" do
    @cell_facts %{
      repo_adapter: Ecto.Adapters.Postgres,
      storage_adapter: Arca.Adapters.S3,
      proto_dist: :inet_tls,
      dist_certificates?: true,
      cell_cookie: String.duplicate("c", 40),
      node_cookie: String.duplicate("c", 40),
      topologies: [cyfr: [strategy: Cluster.Strategy.Epmd, config: [hosts: [:a@h]]]],
      worker_key: :crypto.strong_rand_bytes(32),
      host_api_url: "http://member-1:4300"
    }

    test "a deployment that satisfies all seven is refused nothing" do
      assert Cell.refusals(@cell_facts) == []
    end

    test "SQLite is refused, naming the adapter and what to set" do
      assert [message] = Cell.refusals(%{@cell_facts | repo_adapter: Ecto.Adapters.SQLite3})
      assert message =~ "needs Postgres"
      assert message =~ "Ecto.Adapters.SQLite3"
      assert message =~ "CYFR_DATABASE=postgres"
    end

    test "local storage is refused, naming the adapter and what to set" do
      assert [message] = Cell.refusals(%{@cell_facts | storage_adapter: Arca.Adapters.Local})
      assert message =~ "shared object storage"
      assert message =~ "Arca.Adapters.Local"
      assert message =~ "CYFR_STORAGE=s3"
    end

    test "plain distribution is refused, naming the protocol and what to start with" do
      assert [message] = Cell.refusals(%{@cell_facts | proto_dist: :inet_tcp})
      assert message =~ "TLS distribution"
      assert message =~ ":inet_tcp"
      assert message =~ "-proto_dist inet_tls"
    end

    test "TLS distribution without certificates is refused" do
      assert [message] = Cell.refusals(%{@cell_facts | dist_certificates?: false})
      assert message =~ "certificates"
      assert message =~ "-ssl_dist_optfile"
    end

    test "inet6_tls is TLS too" do
      assert Cell.refusals(%{@cell_facts | proto_dist: :inet6_tls}) == []
    end

    test "an unset, a short and an ambient cookie are each refused" do
      assert [unset] = Cell.refusals(%{@cell_facts | cell_cookie: nil})
      assert unset =~ "CYFR_CELL_COOKIE is not"
      assert unset =~ "32 random characters"

      short = String.duplicate("c", 31)
      assert [message] = Cell.refusals(%{@cell_facts | cell_cookie: short, node_cookie: short})
      assert message =~ "at least 32 characters"
      assert message =~ "is 31"

      assert [ambient] = Cell.refusals(%{@cell_facts | node_cookie: "the-machines-own-cookie"})
      assert ambient =~ "distribution cookie"
      assert ambient =~ "RELEASE_COOKIE"
    end

    test "no discovery topology is refused, naming both ways to set one" do
      assert [message] = Cell.refusals(%{@cell_facts | topologies: []})
      assert message =~ "discovery topology"
      assert message =~ "CYFR_CLUSTER_NODES"
      assert message =~ "CYFR_CLUSTER_DNS_QUERY"
    end

    test "an unset or malformed worker root is refused, naming what a peer cannot verify" do
      assert [message] = Cell.refusals(%{@cell_facts | worker_key: nil})
      assert message =~ "CYFR_WORKER_KEY"
      assert message =~ "MAC verification"

      assert [_short] = Cell.refusals(%{@cell_facts | worker_key: <<1, 2, 3>>})
    end

    test "a member with no address of its own is refused, naming what a worker falls back to" do
      assert [message] = Cell.refusals(%{@cell_facts | host_api_url: nil})
      assert message =~ "CYFR_HOST_API_URL"
      assert message =~ "THIS member"
      assert message =~ "falls back"
    end

    test "each refusal fires on its own, and all of them together name all seven" do
      broken = %{
        repo_adapter: Ecto.Adapters.SQLite3,
        storage_adapter: Arca.Adapters.Local,
        proto_dist: :inet_tcp,
        dist_certificates?: false,
        cell_cookie: nil,
        node_cookie: nil,
        topologies: [],
        worker_key: nil,
        host_api_url: nil
      }

      assert length(Cell.refusals(broken)) == 7
    end

    test "a cluster member boots once every condition holds", %{node: node} do
      claim_enabled(true)

      {:ok, pid} =
        Cell.start_link(
          name: nil,
          node_name: node,
          cluster: true,
          facts: fn -> @cell_facts end,
          lease_ms: 60_000,
          renew_ms: 60_000
        )

      assert ControlPlane.held?()
      assert {:ok, _generation} = ControlPlane.generation()

      # A cluster member claims its slot like any other: no
      # `{:held, :forever}`, and a real generation to stamp outward.
      assert {:held, deadline} = :persistent_term.get(@standing_key)
      assert is_integer(deadline)

      :ok = GenServer.stop(pid)
    end

    test "a cluster member that misses one condition refuses to boot", %{node: node} do
      claim_enabled(true)
      facts = %{@cell_facts | topologies: []}

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Cell.start_link(
                 name: nil,
                 node_name: node,
                 cluster: true,
                 facts: fn -> facts end,
                 lease_ms: 60_000,
                 renew_ms: 60_000
               )

      assert message =~ "cannot form a cell"
      assert message =~ "discovery topology"

      # Nothing was written: the refusal comes before the claim.
      assert ControlPlane.slot(node) == {:error, :not_found}
    end

    test "a cluster member does not refuse a live peer: that is the point of the flag", %{
      node: node
    } do
      claim_enabled(true)
      peer = node <> "-peer"
      assert {:ok, _} = ControlPlane.take(peer, "boot-peer", 60_000)

      {:ok, pid} =
        Cell.start_link(
          name: nil,
          node_name: node,
          cluster: true,
          facts: fn -> @cell_facts end,
          lease_ms: 60_000,
          renew_ms: 60_000
        )

      assert ControlPlane.held?()
      assert peer in Cell.roster()
      assert node in Cell.roster()

      :ok = GenServer.stop(pid)
    end
  end

  describe "live_member?/1" do
    test "answers the cell's roster, not this node's processes", %{node: node} do
      assert {:ok, _} = ControlPlane.take(node, "boot-live", 60_000)
      assert Cell.live_member?("boot-live")

      expire(node)
      refute Cell.live_member?("boot-live")
    end
  end
end
