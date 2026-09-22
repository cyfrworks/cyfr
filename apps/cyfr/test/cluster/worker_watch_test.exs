# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.WorkerWatchTest do
  @moduledoc """
  A member that cannot reach a worker its peer can.

  This is the fault `cell-ownership.md` §4.4 exists to close: every member
  used to poll every worker and lapse the attempts of whatever boot it
  stopped hearing from, **whoever claimed them**, so a member partitioned
  from a worker lapsed a healthy peer's running work. The answer is a
  claim whose lease a **miss does not renew**, and a cascade:

  > a miss does not renew, so a member that cannot reach a worker loses
  > the watch within one lease. The next rendezvous candidate takes it,
  > and if *it* can reach the worker it hears a status and resets `misses`
  > to zero.

  Two members here have **different paths to one worker service**: one
  reaches it directly, the other through a wire this suite can cut
  (`Cyfr.Cluster.Wire`). Cutting the wire is not killing the worker, and
  the difference is the whole of §4.4.

  The last case is the deliberately broken variant. The roster gate
  `Cyfr.Cell.mine?/1` was **not** applied to the watch, and this is why:
  with an argmax-only gate there is no next candidate, so the member that
  cannot hear the worker retakes its own lapsed row past the grace and
  drives `misses` to the threshold — which is the fault, back again. The
  case runs a cell in which no peer can take the row and shows the count
  reaching the threshold, so the reason the gate was declined is
  something the suite demonstrates rather than something the roster
  merely asserts.
  """

  use Cyfr.Cluster.Case, async: false

  @kind "worker_watch"
  @reference "reagent:local.cluster-watch:1.0.0"

  # The case's watch: a 1 s poll, a 2 s lease (twice the poll, as §4.4
  # says), and three misses to the threshold.
  @poll_ms 1_000
  @lease_ms 2_000
  @misses 3

  # §4.4's bound for a genuinely dead worker: the claim rotates at most
  # once per miss, so `misses × (lease + poll)`.
  @detection_bound_ms @misses * (@lease_ms + @poll_ms)

  setup do
    on_exit(fn ->
      for id <- [:a, :b], do: safe(id, Cyfr.Cluster.Boot, :stop_watch!, [])
      safe(:b, Cyfr.Cluster.Boot, :stop_worker!, [])
      Wire.close(:worker)
    end)

    :ok
  end

  describe "one worker service, two paths" do
    test "is watched by one member; the other polls it and writes nothing" do
      %{service: service, direct: direct, through_wire: through_wire} = wired()

      # The member that reaches the worker through the wire takes the
      # watch; the other polls the same service directly and finds a live
      # claim, which it does not take.
      Cell.call(:a, Cyfr.Cluster.Boot, :watch_worker!, [through_wire, watch_opts()])
      holder = live_holder!(service)

      Cell.call(:b, Cyfr.Cluster.Boot, :watch_worker!, [direct, watch_opts()])
      before = Observer.fence(@kind, service)

      # Three renewals is the wait, not three seconds: the fence rises on
      # every write, so waiting for it to rise three times is waiting for
      # the holder to have polled three times with the peer beside it.
      Wait.until!(
        fn -> Observer.fence(@kind, service) >= before + 3 end,
        "the holder stopped renewing a watch it holds"
      )

      assert Observer.claim(@kind, service)["owner"] == holder,
             "the watch changed hands while both members could hear the worker"

      assert misses(service) == 0
    end

    test "moves to the member that can still hear it, and the count is not raised against it" do
      %{service: service, direct: direct, through_wire: through_wire} = wired()

      # The member behind the wire takes the watch first, so the cut is
      # made against the holder and not against a bystander.
      Cell.call(:a, Cyfr.Cluster.Boot, :watch_worker!, [through_wire, watch_opts()])
      holder = live_holder!(service)
      assert holder =~ to_string(node_of(:a))

      Cell.call(:b, Cyfr.Cluster.Boot, :watch_worker!, [direct, watch_opts()])

      # Cut the wire. The worker is untouched and the member is alive: it
      # keeps its database, keeps its slot and keeps polling, and hears
      # nothing.
      Wire.cut(:worker)

      {moved_ms, _} =
        Wait.measure!(
          fn -> Observer.claim(@kind, service)["owner"] =~ to_string(node_of(:b)) end,
          "the watch never moved to the member that could still hear the worker",
          @detection_bound_ms * 4
        )

      Wait.report("the watch moves off a member that cannot hear", moved_ms, @detection_bound_ms)

      # The peer can hear the worker, so it resets the count: three misses
      # require three failures from whichever member held the watch at the
      # time, and the watch moves away from a member that misses.
      Wait.until!(
        fn -> misses(service) == 0 end,
        "the member that could hear the worker did not reset the miss count"
      )

      Wait.never!(
        fn -> misses(service) >= @misses end,
        "a member partitioned from a worker its peer can hear reached the threshold",
        @detection_bound_ms
      )
    end
  end

  describe "the broken variant: a watch nobody else can take" do
    test "reaches the threshold, which is what an argmax-only gate would leave" do
      %{service: service, through_wire: through_wire} = wired()

      # One watcher, and no peer watching this service at all — which is
      # the cell an argmax-only gate produces, since only the argmax would
      # ever propose itself for the row.
      Cell.call(:a, Cyfr.Cluster.Boot, :watch_worker!, [through_wire, watch_opts()])
      assert live_holder!(service) =~ to_string(node_of(:a))

      Wire.cut(:worker)

      {reached_ms, _} =
        Wait.measure!(
          fn -> misses(service) >= @misses end,
          "the sole watcher never reached the threshold",
          @detection_bound_ms * 4
        )

      Wait.report("a sole watcher reaches the threshold", reached_ms, @detection_bound_ms)

      # The count is the cell's, carried on the claim's `detail`, and it
      # is what the lapse is measured on. With a peer able to take the row
      # — the case above — it never gets here.
      assert Observer.claim(@kind, service)["owner"] =~ to_string(node_of(:a))
    end
  end

  # One scripted worker service on the second member, reached two ways:
  # directly, and through a wire the case can cut.
  defp wired do
    Cell.call(:b, Cyfr.Cluster.Boot, :stop_worker!, [])

    direct =
      Cell.call(:b, Cyfr.Cluster.Boot, :start_worker!, [[ref: @reference, script: []]])

    # The claim is keyed by the service id alone, and this database
    # outlives the run: a case that read a row an earlier one left would
    # be watching a boot that is gone.
    Observer.forget_claim(@kind, direct.id)

    %URI{host: host, port: port} = URI.parse(direct.url)
    {:ok, wire_port} = Wire.open(:worker, String.to_charlist(host), port)

    %{
      service: direct.id,
      direct: direct,
      through_wire: %{direct | url: "http://127.0.0.1:#{wire_port}"}
    }
  end

  # The owner of a claim that is live right now. A row that exists is not
  # a row somebody holds: a lapsed one is about to change hands, and a
  # case that read it would be recording a holder that is already gone.
  defp live_holder!(service) do
    Wait.until!(
      fn ->
        case Observer.row(
               "SELECT owner FROM job_claims WHERE kind = $1 AND key = $2 " <>
                 "AND lease_until > timezone('UTC', clock_timestamp())",
               [@kind, service]
             ) do
          %{"owner" => owner} -> owner
          nil -> false
        end
      end,
      "no member ever held the worker's claim"
    )
  end

  defp watch_opts, do: [poll_ms: @poll_ms, lease_ms: @lease_ms, misses: @misses]

  # The count the cell carries on the claim's `detail`, which is what the
  # threshold is measured on — not either member's own unheard answers.
  defp misses(service) do
    case Observer.claim(@kind, service) do
      %{"detail" => detail} when is_binary(detail) -> Jason.decode!(detail)["misses"] || 0
      _none -> 0
    end
  end

  defp node_of(id), do: Cell.member(id).node

  defp safe(id, module, function, args) do
    Cell.call(id, module, function, args)
  catch
    _kind, _reason -> :ok
  end
end
