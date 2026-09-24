# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.CellTest do
  @moduledoc """
  The cell itself, on two real members: who holds a slot, what a member's
  death costs a successor, what a live partition costs nobody, and which
  member proposes itself for a singleton.

  Every bound here is `docs/plans/cell-ownership.md` §4.1's, measured
  rather than assumed, and every measurement is reported with the margin
  it had.
  """

  use Cyfr.Cluster.Case, async: false

  # §4.1: lease 15 s, renew tick 5 s, so a member that stops without
  # releasing is taken over within lease + one tick.
  @lease_ms 15_000
  @tick_ms 5_000
  @takeover_bound_ms @lease_ms + @tick_ms

  describe "the cell" do
    test "two members hold one slot each, and the roster is the rows' answer" do
      nodes = Cell.nodes() |> Enum.map(&to_string/1)

      # Read from outside both members: what each believes is not evidence.
      assert Enum.sort(Observer.roster()) == Enum.sort(nodes)

      for node <- nodes do
        slot = Observer.slot(node)
        assert slot["owner"] =~ node
        assert slot["generation"] >= 1
      end

      # And each member's own copy agrees with the rows, because it came
      # from them.
      for id <- [:a, :b] do
        assert Enum.sort(Cell.call(id, Cyfr.Cell, :roster, [])) == Enum.sort(nodes)
        assert Cell.call(id, Arca.ControlPlane, :held?, [])
      end
    end

    test "a member holds its own generation, and a peer's join moves nobody's" do
      before = for id <- [:a, :b], into: %{}, do: {id, generation(id)}

      # A peer leaving and coming back raises only its own slot's
      # generation: there is no cell-wide epoch, which is what lets a
      # join invalidate nothing a peer already issued (§2.1).
      Cell.stop(:b)
      Cell.start(:b)

      assert generation(:a) == before[:a],
             "member a's generation moved when its peer restarted"

      assert generation(:b) > before[:b],
             "member b's successor did not raise its own slot's generation"
    end

    test "a live partition costs the cell nothing: neither member takes the other's slot" do
      fences = for id <- [:a, :b], into: %{}, do: {id, Observer.slot(node_of(id))["owner"]}

      Cell.partition(:a, :b)

      # A partition is a failure of a link, not of a peer (§7.2). Both
      # members keep their database connection, so both keep renewing,
      # and neither may infer from "I cannot see you" that the other has
      # stopped.
      Wait.never!(
        fn -> Observer.takeable?(node_of(:a)) or Observer.takeable?(node_of(:b)) end,
        "a partitioned member's slot became takeable while it was still renewing",
        @lease_ms + @tick_ms
      )

      for id <- [:a, :b] do
        assert Cell.call(id, Arca.ControlPlane, :held?, []),
               "member #{id} gave up its slot over a partition it had no part in"

        assert Observer.slot(node_of(id))["owner"] == fences[id]
      end

      assert Cell.call(:a, Node, :list, []) == [],
             "the partition did not cut distribution"
    end
  end

  describe "losing a member" do
    test "a clean stop gives the slot up at once, and a kill is waited out to the bound" do
      # A clean stop: `Cyfr.Cell.terminate/2` releases the slot, so it is
      # takeable the moment the member is gone — no lease to wait out.
      Cell.stop(:b)

      {released_ms, _} =
        Wait.measure!(
          fn -> Observer.takeable?(node_of(:b)) end,
          "a cleanly stopped member did not give its slot up"
        )

      Wait.report("a clean stop's slot becomes takeable", released_ms, @takeover_bound_ms)
      assert released_ms < @tick_ms, "a release should not need a lease to run out"

      Cell.start(:b)

      # Process death: nothing is released and nothing is logged. The
      # lease is the only thing a successor can wait on, and §4.1 bounds
      # that wait at lease + one tick.
      Cell.kill(:b)

      {lapsed_ms, _} =
        Wait.measure!(
          fn -> Observer.takeable?(node_of(:b)) end,
          "a killed member's slot never became takeable"
        )

      Wait.report("a killed member's slot becomes takeable", lapsed_ms, @takeover_bound_ms)

      assert lapsed_ms <= @takeover_bound_ms,
             "a killed member's slot took #{lapsed_ms} ms to lapse, past §4.1's #{@takeover_bound_ms} ms"

      # And the peer notices from the rows alone: its roster drops the
      # dead member without anything telling it.
      {noticed_ms, _} =
        Wait.measure!(
          fn -> Cell.call(:a, Cyfr.Cell, :roster, []) == [to_string(node_of(:a))] end,
          "the surviving member never dropped the dead one from its roster"
        )

      Wait.report("the survivor's roster drops the dead member", noticed_ms, @takeover_bound_ms)
    end

    test "a member that comes back takes its own row over rather than opening a second" do
      rows = length(Observer.slots())
      before = Observer.slot(node_of(:b))

      Cell.kill(:b)
      Cell.start(:b)

      assert length(Observer.slots()) == rows,
             "a restarted member opened a second row beside its predecessor's"

      after_restart = Observer.slot(node_of(:b))

      # The slot is keyed by node name and not by boot, so a successor's
      # generation carries on from its predecessor's: a member that came
      # back must never reissue a generation a worker has already retired
      # (§2.1). Measured as a delta, never against an absolute — the row
      # outlives every run against this database.
      assert after_restart["generation"] == before["generation"] + 1
      assert after_restart["owner"] != before["owner"]
    end
  end

  describe "the singleton proposal" do
    test "both members compute one owner for a subject, from their own roster copies" do
      subject = "retention:cell"

      a = Cell.call(:a, Cyfr.Cluster.Boot, :proposal, [subject])
      b = Cell.call(:b, Cyfr.Cluster.Boot, :proposal, [subject])

      assert a.owner == b.owner, "two members proposed different owners for one subject"
      assert [a.mine, b.mine] |> Enum.count(& &1) == 1, "the subject is exactly one member's"

      owner = elem(a.owner, 1)
      assert owner in Enum.map(Cell.nodes(), &to_string/1)
    end

    test "only the proposed member asks for the retention claim; the other writes nothing" do
      # The row is the disposition and the proposal is only a hint, so the
      # evidence that a member "did not write at all" is the fence: it
      # rises on every write, including a losing one.
      Observer.forget_claim("retention", "cell")

      {owner, bystander} = proposed(:a, :b, "retention:cell")

      before = Observer.fence("retention", "cell")

      # The bystander is asked for a tick of its own, as its timer would.
      # It holds its slot and the row is free, so the only thing stopping
      # it is the proposal.
      Cell.call(bystander, Cyfr.Cluster.Boot, :retention_tick, [])

      assert Observer.fence("retention", "cell") == before,
             "a member that is not the proposed owner wrote to the claim row"

      assert Observer.claim("retention", "cell") == nil,
             "a member that is not the proposed owner opened the claim row"

      # The proposed owner does the work, and the row is its evidence.
      Cell.call(owner, Cyfr.Cluster.Boot, :retention_tick, [])

      claim = Observer.claim("retention", "cell")
      assert claim, "the proposed owner did not ask for the claim row"
      assert claim["owner"] =~ to_string(node_of(owner))
    end

    test "without the proposal both members write, which is what the proposal removes" do
      # The broken-ownership variant: a tick that asks for the row
      # regardless of the roster is what the code did before this slice,
      # and it is still what `cycle/1` does for a caller that asks
      # directly. Two members doing it is safe — the row admits one — but
      # contended, and the fence counts the contention the gate removes.
      Observer.forget_claim("retention", "cell")

      {_owner, bystander} = proposed(:a, :b, "retention:cell")

      assert {:ok, _summary} = Cell.call(bystander, Cyfr.RetentionScheduler, :cycle, [[]]),
             "an ungated cycle should still run on any member that holds its slot"

      claim = Observer.claim("retention", "cell")

      assert claim["owner"] =~ to_string(node_of(bystander)),
             "the ungated path did not write the row, so the gated case proves nothing"
    end
  end

  describe "what a cell does not run" do
    test "no member runs a bridge controller, so no member claims a backend" do
      # `Emissary.External.Backends.start_link/1` answers `:ignore` while
      # `:cluster` is on: a cluster of control planes runs no stdio
      # servers. That is why the `mcp_backend` claim has no roster gate —
      # there is no controller in a cell to gate — and it is what the
      # shipped guides say.
      for id <- [:a, :b] do
        refute Cell.call(id, Emissary.External.Backends, :running?, []),
               "member #{id} started a bridge controller in a cell"
      end

      assert Observer.claims("mcp_backend") == []
    end
  end

  defp generation(id) do
    Observer.slot(node_of(id))["generation"]
  end

  defp node_of(id), do: Cell.member(id).node

  # The member the cell proposes for `subject`, and the one it does not.
  defp proposed(one, other, subject) do
    if Cell.call(one, Cyfr.Cell, :mine?, [subject]), do: {one, other}, else: {other, one}
  end
end
