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
  work. This file gives that exposure a name, and it is sharper than "the
  call is lost", because **what a host call does on the wrong member
  depends on what it needs**:

    * an op that needs the attempt's **process** — the guest's result,
      its deltas, its children — is lost there, and the run's answer with
      it;
    * an op answered from the attempt's **row** — a lease renewal — lands
      on any member whose generation matches the one the call was signed
      under, and in a freshly formed cell every member's generation is 1.

  Both are pinned here as exposures, not contracts. When the address rides
  the assignment, these are the cases that have to change.
  """

  use Cyfr.Cluster.Case, async: false

  describe "a host call the member holds" do
    test "is answered by the member that issued the attempt's keys" do
      held = attempt(:a, :served)

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
  end

  describe "a host call that carries the run's answer" do
    test "is lost on the peer, and the run is still the holding member's to finish" do
      held = attempt(:a, :strayed)

      # The same signed call, made once on the member that issued the
      # attempt's keys, delivered to the peer. Nothing about the call
      # differs; only which member answers it.
      {header, body} = complete_call(:a, :strayed)
      away = deliver(:b, header, body)

      refute Map.has_key?(away, "ok"),
             "the peer answered a host call for an attempt it does not hold: #{inspect(away)}"

      # A completion an attempt's process never saw is a completion that
      # did not happen: the execution is still running, and the guest's
      # answer is gone.
      assert Observer.execution(held.execution_id)["status"] == "running"
      assert Observer.execution(held.execution_id)["output"] == nil
      assert Observer.attempt(held.attempt)["state"] == "running"

      # And the member that holds it finishes the run, so the case is not
      # passing because the call was malformed.
      {header, body} = complete_call(:a, :strayed)
      assert %{"ok" => _} = deliver(:a, header, body)

      Wait.until!(
        fn -> Observer.execution(held.execution_id)["status"] == "completed" end,
        "the holding member did not finish its own run"
      )
    end

    test "cannot attach a runner on the peer either" do
      held = attempt(:a, :unattached, attach: false)

      {header, body} = complete_call(:a, :unattached)
      refute Map.has_key?(deliver(:b, header, body), "ok")

      # The attempt is still unclaimed, so nothing about the peer's
      # refusal left it half-held.
      assert Observer.attempt(held.attempt)["claimed_by"] == nil
      assert Observer.attempt(held.attempt)["state"] == "running"
    end
  end

  describe "a lease renewal" do
    test "is answered from the rows, so only the generation keeps it on one member" do
      held = attempt(:a, :renewed)
      issuer = Cell.call(:a, Arca.ControlPlane, :generation, [])
      assert {:ok, generation} = issuer

      # A freshly formed cell has every member at generation 1, since a
      # slot's generation rises only when that slot is taken over. This
      # database outlives the run, so the two members have drifted apart;
      # the peer is put back at the issuer's generation, which is the
      # state a new deployment starts in.
      peer = Cell.call(:b, Arca.ControlPlane, :generation, [])
      Cell.call(:b, Arca.ControlPlane, :record_generation, [generation])

      on_exit(fn ->
        case peer do
          {:ok, was} -> Cell.call(:b, Arca.ControlPlane, :record_generation, [was])
          _none -> :ok
        end
      end)

      before = Observer.attempt(held.attempt)["lease_until"]

      {header, body} =
        Cell.call(:a, Cyfr.Cluster.Holder, :sign, [
          :renewed,
          "renew",
          %{"attempts" => [held.attempt]}
        ])

      answer = deliver(:b, header, body)

      assert %{"ok" => renewals} = answer,
             "the peer refused a renewal it can answer from the row: #{inspect(answer)}"

      assert Map.has_key?(renewals, held.attempt)

      # The row moved, on a member that holds none of the work. This is
      # the exposure: a lease is not member-bound, so the generation is
      # the only thing between a peer and an attempt's lease.
      assert NaiveDateTime.compare(Observer.attempt(held.attempt)["lease_until"], before) == :gt
    end
  end

  # An attempt held open on `id` under `label`, with nothing of an earlier
  # case still held there.
  defp attempt(id, label, opts \\ []) do
    Cell.call(id, Cyfr.Cluster.Holder, :release!, [])
    Cell.call(id, Cyfr.Cluster.Holder, :attach!, [label, opts])
  end

  defp complete_call(id, label),
    do: Cell.call(id, Cyfr.Cluster.Holder, :sign_complete, [label])

  defp deliver(id, header, body),
    do: id |> Cell.call(Cyfr.Execution.Host, :call, [header, body]) |> Jason.decode!()
end
