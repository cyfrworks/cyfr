# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.HostRoutingTest do
  @moduledoc """
  Where a worker's host call lands, and what the other member does with
  one that lands on it.

  `cell-ownership.md` §5 classes an attempt's host-call state **shared by
  construction** — "an attempt has exactly one process in the cell, on the
  member holding it" — and says so conditionally:

  > This holds **only if a host call reaches that member**: the assignment
  > carries the issuing member's own address, and a worker calls that
  > address directly rather than the cell's balancer.

  The assignment carries no address. A worker service's callback address
  is its own credential (`OPUS_HOST_URL`), read once at its boot, so every
  host call it makes goes to one member whichever member admitted the
  work. This file is the case that gives that exposure a name: the same
  signed call is answered by the member holding the attempt and refused by
  its peer, and the refusal is `lost` — the guest's work, not an error it
  can act on.

  It is a **pinned exposure, not a passing contract.** When the address
  rides the assignment, the second case here is what has to change.
  """

  use Cyfr.Cluster.Case, async: false

  describe "a host call" do
    test "is answered by the member holding the attempt" do
      Cell.call(:a, Cyfr.Cluster.Holder, :release!, [])
      held = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:served, []])

      # The row is the evidence, read from outside both members.
      row = Observer.attempt(held.attempt)
      assert row["state"] == "running"
      assert row["boot_id"] =~ to_string(Cell.member(:a).node)

      answer =
        Cell.call(:a, Cyfr.Cluster.Holder, :call, [
          :served,
          "renew",
          %{"attempts" => [held.attempt]}
        ])

      assert %{"ok" => renewals} = answer,
             "the holding member did not answer its own runner's renew: #{inspect(answer)}"

      assert Map.has_key?(renewals, held.attempt)
    end

    test "that reaches the peer instead is lost, and the peer settles nothing by it" do
      Cell.call(:a, Cyfr.Cluster.Holder, :release!, [])
      held = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:strayed, []])

      # One signed call, made once on the member that issued the attempt's
      # keys, and delivered to each member in turn. Nothing about the call
      # differs; only which member answers it.
      {header, body} =
        Cell.call(:a, Cyfr.Cluster.Holder, :sign, [
          :strayed,
          "renew",
          %{"attempts" => [held.attempt]}
        ])

      home = Cell.call(:a, Cyfr.Execution.Host, :call, [header, body]) |> Jason.decode!()
      assert Map.has_key?(home, "ok"), "the holding member refused its own runner: #{inspect(home)}"

      # A second delivery of the same call would be refused as a replay by
      # the member that already saw it, so the peer is given its own.
      {header, body} =
        Cell.call(:a, Cyfr.Cluster.Holder, :sign, [
          :strayed,
          "renew",
          %{"attempts" => [held.attempt]}
        ])

      away = Cell.call(:b, Cyfr.Execution.Host, :call, [header, body]) |> Jason.decode!()

      assert away == %{"error" => "lost"},
             "the peer answered a host call for an attempt it does not hold: #{inspect(away)}"

      # And the attempt is untouched by the peer's refusal: a lost call
      # settles nothing, which is the one thing that must stay true while
      # the address is not on the assignment.
      row = Observer.attempt(held.attempt)
      assert row["state"] == "running"
      assert row["ended_at"] == nil
    end

    test "cannot attach its runner on the peer either" do
      Cell.call(:a, Cyfr.Cluster.Holder, :release!, [])
      held = Cell.call(:a, Cyfr.Cluster.Holder, :attach!, [:unattached, [attach: false]])

      {header, body} =
        Cell.call(:a, Cyfr.Cluster.Holder, :sign, [:unattached, "renew", %{"attempts" => [held.attempt]}])

      assert Cell.call(:b, Cyfr.Execution.Host, :call, [header, body]) |> Jason.decode!() ==
               %{"error" => "lost"}

      # The attempt is still unclaimed, so nothing about the peer's
      # refusal left it half-held.
      assert Observer.attempt(held.attempt)["claimed_by"] == nil
    end
  end

end
