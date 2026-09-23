# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.ArchiveFenceTest do
  @moduledoc """
  An archive on one member of work the other member runs, with the
  control channel cut so the archive is never heard there.

  The archive retires the grant every attempt in the estate stores, in the
  archiving member's transaction. What keeps the other member's attempt
  from acting on is the rows, not the announcement: its renewal, its
  storage write and its completion are refused `lost` under a grant that
  no longer stands, and a reopen brings none of them back. The sweep on
  the archiving member finds the retired attempt by its stamp alone and
  cancels it once; the member that never heard overwrites nothing after.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Cluster.{Fixtures, Holder}

  test "a missed archive retires the peer's running work, and the sweep settles it once" do
    Cell.call(:a, Holder, :release!, [])
    estate = Cell.call(:a, Fixtures, :athanor!, ["fence"])

    ctx =
      Sanctum.internal_context(
        user_id: "usr_cluster",
        athanor_id: estate.id,
        scope: :athanor,
        permissions: [:*]
      )

    edge = %Edge{storage: %{paths: ["data/"], actions: ["read", "write"]}}

    held =
      Cell.call(:a, Holder, :attach!, [
        :fenced,
        [ctx: ctx, authority: %{Authority.zero() | resources: edge}]
      ])

    assert %{"lease_until" => _} =
             Cell.call(:a, Holder, :call, [:fenced, "renew", %{"attempts" => [held.attempt]}])
             |> renewal(held.attempt)

    # The archive is made where the peer cannot hear it, and its
    # announcement is lost everywhere: the transition commits and nobody
    # is told.
    Cell.partition(:a, :b)
    assert Cell.call(:b, Fixtures, :archive_unheard!, [estate.id]) == "archived"

    # The member running the work never heard, and its host calls are
    # refused by the rows alone.
    assert Cell.call(:a, Holder, :call, [:fenced, "renew", %{"attempts" => [held.attempt]}])
           |> renewal(held.attempt) == "lost"

    assert %{"error" => "lost"} =
             Cell.call(:a, Holder, :call, [
               :fenced,
               "storage",
               %{"action" => "write", "path" => "data/late.txt", "content" => Base.encode64("x")}
             ])

    refute Observer.execution(held.execution_id)["status"] == "completed"

    # The archiving member's sweep finds it by its stamp and cancels it.
    assert Cell.call(:b, Cyfr.Cluster.Boot, :sweep, []) == :ok
    assert Observer.execution(held.execution_id)["status"] == "cancelled"
    assert Observer.attempt(held.attempt)["state"] == "cancelled"
    cancelled_at = Observer.execution(held.execution_id)["completed_at"]

    Cell.heal(:a, :b)

    # The member that never heard can neither complete it nor move it: the
    # cancel stands as the one terminal write.
    assert %{"error" => "lost"} = Cell.call(:a, Holder, :complete, [:fenced])
    assert Cell.call(:a, Cyfr.Cluster.Boot, :sweep, []) == :ok
    assert Observer.execution(held.execution_id)["status"] == "cancelled"
    assert Observer.execution(held.execution_id)["completed_at"] == cancelled_at
  end

  test "a reopen admits fresh work and revives none of the old" do
    Cell.call(:a, Holder, :release!, [])
    estate = Cell.call(:a, Fixtures, :athanor!, ["reopen"])

    ctx =
      Sanctum.internal_context(
        user_id: "usr_cluster",
        athanor_id: estate.id,
        scope: :athanor,
        permissions: [:*]
      )

    old = Cell.call(:a, Holder, :attach!, [:old, [ctx: ctx]])

    Cell.partition(:a, :b)
    assert Cell.call(:b, Fixtures, :archive_unheard!, [estate.id]) == "archived"
    assert Cell.call(:b, Fixtures, :reopen!, [estate.id]) == "active"
    Cell.heal(:a, :b)

    assert Cell.call(:a, Holder, :call, [:old, "renew", %{"attempts" => [old.attempt]}])
           |> renewal(old.attempt) == "lost"

    fresh = Cell.call(:a, Holder, :attach!, [:fresh, [ctx: ctx]])

    assert %{"lease_until" => _} =
             Cell.call(:a, Holder, :call, [:fresh, "renew", %{"attempts" => [fresh.attempt]}])
             |> renewal(fresh.attempt)
  end

  defp renewal(%{"ok" => renewals}, attempt), do: renewals[attempt]
  defp renewal(other, _attempt), do: other
end
