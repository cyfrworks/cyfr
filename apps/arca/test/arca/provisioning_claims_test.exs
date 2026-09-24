# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ProvisioningClaimsTest do
  @moduledoc """
  The estate's one claim row: taken at a new fence, held against another
  owner while its lease stands, re-entered by its own owner, taken over
  once the lease ran out or the outcome settled — and written only by
  the owner and fence it still reads.
  """
  # Eight writers race one claim row. On SQLite that is eight write
  # transactions queueing on one lock for as long as the busy timeout
  # allows, which is long enough that a neighbouring case's write is told
  # the database is busy — so this one runs alone.
  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Arca.ProvisioningClaims, as: Claims

  @lease_ms 60_000

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    athanor_id = "ath_claims_#{System.unique_integer([:positive])}"
    {:ok, actor: %Prima.Actor{athanor_id: athanor_id}, athanor_id: athanor_id}
  end

  # A claim with a lease this short has run out by the time anyone looks.
  defp lapsed!(actor, owner, entry_kind \\ "first_need") do
    {:ok, claim} = Claims.claim(actor, owner, entry_kind, 1)
    wait_until(fn -> not Claims.live?(claim) end, 2_000, "the lease to run out")
    claim
  end

  test "an actor without an athanor is refused by every function, before any query" do
    nobody = %Prima.Actor{athanor_id: nil, user_id: "someone"}
    handler = "claims-no-athanor-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      # The event fires in the querying process; a neighbour's query is not
      # this test's.
      fn _event, _measure, _meta, _config -> if self() == parent, do: send(parent, :queried) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :no_athanor} = Claims.claim(nobody, "boot_1/a", "provision", @lease_ms)
    assert {:error, :no_athanor} = Claims.renew(nobody, "boot_1/a", 1, @lease_ms)
    assert {:error, :no_athanor} = Claims.settle(nobody, "boot_1/a", 1, "ready", nil)
    assert {:error, :no_athanor} = Claims.release(nobody, "boot_1/a", 1)
    assert {:error, :no_athanor} = Claims.current(nobody)
    refute_received :queried

    # The probe is live: an actor with an athanor does query.
    assert {:error, :not_found} = Claims.current(%Prima.Actor{athanor_id: "ath_claims_probe"})
    assert_received :queried
  end

  test "a lease is compared on the cell's one clock, and this module keeps no copy of it", %{
    actor: actor
  } do
    # The lease `claim/4` wrote is bracketed by two readings of the shared
    # clock, so it was taken on that clock and on no other. A member whose
    # own clock had drifted would land outside the bracket.
    before = Arca.ServerMetaStorage.now!()
    assert {:ok, claim} = Claims.claim(actor, "boot_1/a", "first_need", @lease_ms)
    later = Arca.ServerMetaStorage.now!()

    assert DateTime.compare(claim.lease_until, DateTime.add(before, @lease_ms, :millisecond)) !=
             :lt

    assert DateTime.compare(claim.lease_until, DateTime.add(later, @lease_ms, :millisecond)) != :gt

    # `age_ms/1` is measured on the same clock: the row was written between
    # the two readings, so its age cannot exceed the span between them.
    assert Claims.age_ms(claim) <= DateTime.diff(Arca.ServerMetaStorage.now!(), before, :millisecond)

    # And the clock is read, not reimplemented: a second copy of it here
    # is a second answer to which member holds a row.
    source = File.read!(Path.expand("../../lib/arca/provisioning_claims.ex", __DIR__))
    assert source =~ "Arca.ServerMetaStorage.now!()"
    refute source =~ "Arca.Repo.query!"
  end

  test "the first claim is fence 1, and reads back as the athanor's current claim", %{
    actor: actor,
    athanor_id: athanor_id
  } do
    assert {:error, :not_found} = Claims.current(actor)

    assert {:ok, claim} = Claims.claim(actor, "boot_1/a", "sign_in", @lease_ms)
    assert claim.athanor_id == athanor_id
    assert claim.owner == "boot_1/a"
    assert claim.entry_kind == "sign_in"
    assert claim.fence == 1
    assert claim.outcome == nil
    assert "att_" <> _ = claim.attempt
    assert Claims.live?(claim)

    assert {:ok, current} = Claims.current(actor)
    assert current.id == claim.id
  end

  test "a live claim is busy to another owner and re-entrant to its own", %{actor: actor} do
    {:ok, claim} = Claims.claim(actor, "boot_1/a", "first_need", @lease_ms)

    assert {:busy, holder} = Claims.claim(actor, "boot_1/b", "provision", @lease_ms)
    assert holder.owner == "boot_1/a"
    assert holder.fence == 1

    # The same owner gets its own claim back: same attempt, same fence, and
    # the entry kind it came in through first.
    assert {:ok, again} = Claims.claim(actor, "boot_1/a", "install_shipped", @lease_ms)
    assert again.attempt == claim.attempt
    assert again.fence == 1
    assert again.entry_kind == "first_need"
  end

  test "one estate's claim is nothing to another's", %{actor: actor} do
    other = %Prima.Actor{athanor_id: "ath_claims_other_#{System.unique_integer([:positive])}"}

    {:ok, _} = Claims.claim(actor, "boot_1/a", "first_need", @lease_ms)
    assert {:ok, %{fence: 1}} = Claims.claim(other, "boot_1/b", "first_need", @lease_ms)

    # And an owner's writes land only on the estate its actor names.
    assert :stale = Claims.settle(other, "boot_1/a", 1, "ready", nil)
    assert {:ok, %{outcome: nil}} = Claims.current(actor)
  end

  test "a settled claim is taken at the next fence, under a new attempt", %{actor: actor} do
    {:ok, first} = Claims.claim(actor, "boot_1/a", "first_need", @lease_ms)
    assert :ok = Claims.settle(actor, "boot_1/a", first.fence, "failed", "closure: :timeout")

    assert {:ok, %{outcome: "failed", outcome_detail: "closure: :timeout"} = settled} =
             Claims.current(actor)

    refute Claims.live?(settled)

    assert {:ok, second} = Claims.claim(actor, "boot_1/b", "provision", @lease_ms)
    assert second.id == first.id
    assert second.fence == 2
    assert second.owner == "boot_1/b"
    assert second.entry_kind == "provision"
    assert second.attempt != first.attempt
    assert second.outcome == nil
    assert second.outcome_detail == nil
  end

  test "a claim whose lease ran out is taken over, and its old owner is stale everywhere", %{
    actor: actor
  } do
    old = lapsed!(actor, "boot_1/a")

    assert {:ok, new} = Claims.claim(actor, "boot_2/b", "first_need", @lease_ms)
    assert new.fence == old.fence + 1

    # The old owner renews nothing, settles nothing and releases nothing —
    assert :stale = Claims.renew(actor, old.owner, old.fence, @lease_ms)
    assert :stale = Claims.settle(actor, old.owner, old.fence, "ready", nil)
    assert :stale = Claims.settle(actor, old.owner, old.fence, "failed", "late")
    assert :stale = Claims.release(actor, old.owner, old.fence)

    # — not under the successor's fence either: owner and fence both bind.
    assert :stale = Claims.settle(actor, old.owner, new.fence, "ready", nil)
    assert :stale = Claims.settle(actor, new.owner, old.fence, "ready", nil)

    assert {:ok, %{owner: "boot_2/b", outcome: nil, outcome_detail: nil}} = Claims.current(actor)
  end

  test "a stale owner cannot overwrite its successor's failure", %{actor: actor} do
    old = lapsed!(actor, "boot_1/a")
    {:ok, new} = Claims.claim(actor, "boot_1/b", "provision", @lease_ms)
    :ok = Claims.settle(actor, new.owner, new.fence, "failed", "seed: :bundle_missing")

    assert :stale = Claims.settle(actor, old.owner, old.fence, "ready", nil)
    assert :stale = Claims.settle(actor, old.owner, old.fence, "failed", "mine")

    assert {:ok, %{outcome: "failed", outcome_detail: "seed: :bundle_missing"}} =
             Claims.current(actor)
  end

  test "a renewal keeps a claim that would have run out", %{actor: actor} do
    {:ok, claim} = Claims.claim(actor, "boot_1/a", "sign_in", 1)
    assert :ok = Claims.renew(actor, claim.owner, claim.fence, @lease_ms)

    {:ok, renewed} = Claims.current(actor)
    assert DateTime.compare(renewed.lease_until, claim.lease_until) == :gt
    assert Claims.live?(renewed)
    assert {:busy, _} = Claims.claim(actor, "boot_1/b", "provision", @lease_ms)
  end

  test "a claim settles once: the outcome it carries is not settled over", %{actor: actor} do
    {:ok, claim} = Claims.claim(actor, "boot_1/a", "install_shipped", @lease_ms)
    assert :ok = Claims.release(actor, claim.owner, claim.fence)
    assert {:ok, %{outcome: "released"}} = Claims.current(actor)

    assert :stale = Claims.settle(actor, claim.owner, claim.fence, "ready", nil)
    assert :stale = Claims.renew(actor, claim.owner, claim.fence, @lease_ms)
    assert {:ok, %{outcome: "released"}} = Claims.current(actor)
  end

  test "of several first claims at once, one wins and the rest are busy", %{actor: actor} do
    results =
      1..8
      |> Task.async_stream(
        fn n -> Claims.claim(actor, "boot_1/racer-#{n}", "first_need", @lease_ms) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert winner.fence == 1
    assert Enum.count(results, &match?({:busy, _}, &1)) == 7
  end

  test "an entry kind or an outcome the schema does not name is a caller's bug", %{actor: actor} do
    assert_raise ArgumentError, fn -> Claims.claim(actor, "boot_1/a", "whenever", @lease_ms) end

    {:ok, claim} = Claims.claim(actor, "boot_1/a", "provision", @lease_ms)

    assert_raise ArgumentError, fn ->
      Claims.settle(actor, claim.owner, claim.fence, "finished", nil)
    end
  end
end
