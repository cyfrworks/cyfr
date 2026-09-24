# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.WorkerServiceWireTest do
  @moduledoc """
  The worker service as CYFR drives it, over the wire and with real
  runners; `Opus.WorkerServiceTest` in `apps/opus` is the service's own
  suite, against a scripted host, and the umbrella runs both in one VM,
  so the two carry different module names.

  A run lives only as long as what waits for it and what runs it, across
  the runner boundary: every run here runs in a runner that is an OS
  process of its own. A waiter that is killed kills its run: the attempt
  lapses at once, the worker service is asked to end its runner and
  reports the runner's exit, and the in-flight count, the execution slot
  and the charge row the run held all go back. A runner whose process
  dies is reported at once: its attempt lapses and its waiter answers,
  while a sibling run in another runner keeps running and completes. A
  formula's runner that dies while its children run in it takes them
  with it: the service reports the formula and every child it said it
  started, every row fails, and the invoke slots, charge rows and
  execution slots they held all go back. The worker service starts only
  an assignment addressed to it, with the input its digest binds and keys
  sealed for it that open as its attempt, as CYFR asks it over the wire.

  The runs are the `nested-probe` formula as a child of an admitted root,
  or as a root fanning out to children, each child asking for a catalog
  tool and held at that host call on the suite's wire until the test lets
  it go. What happened is read at the wire, the status the service
  answers and the rows.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Prima.Authority.Budget
  alias Crucible.{Attempt, Keys}
  alias Prima.Slots
  alias Cyfr.Test.{AttemptFixtures, OpusService, TwoServices}
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @slots Crucible.Slots
  @lapsed "Execution terminated: runner stopped without cleanup"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "worker_service_#{System.unique_integer([:positive])}")

    keys = [:base_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Slots.forgive_unreaped(@slots, ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, authority} = Crucible.authority_for(ctx, :default, @probe_node)
    authority = %{authority | budget: Budget.new(2)}
    root_id = Prima.UUID7.execution_id()

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: Probe.probe_ref(),
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: authority.budget.id, cap: 2},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, ctx: ctx, authority: authority, root_id: root_id, attempt: attempt.attempt}
  end

  test "a killed waiter's run stops, its attempt lapses at once, its runner ends and what it held goes back",
       %{ctx: ctx, authority: authority, root_id: root_id, attempt: attempt} do
    children_before = Slots.status(@slots).child_active
    hold_children!(root_id)
    test_pid = self()

    waiter =
      spawn(fn ->
        send(test_pid, {:ran, child!(ctx, authority, root_id, attempt, guest_fn: :spawn)})
      end)

    assert_receive {:held, id, _held}, 30_000
    runner = runner_of(ctx, id)

    assert Sanctum.Authority.budget(authority).in_flight == 1
    assert Slots.status(@slots).child_active == children_before + 1
    assert [%{admitted_at: %DateTime{}}] = charges(ctx, authority)

    Process.exit(waiter, :kill)

    wait_until(fn -> row(id).status == "failed" end, 5_000)
    assert %{error_message: @lapsed} = row(id)
    assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(ctx, id)
    assert "execution.lapsed" in event_types(ctx, id)

    # Its attempt stops, and the service was asked to end its runner,
    # whose exit it reports: nothing of the run is left running.
    wait_until(fn -> Attempt.whereis(id) == nil end)
    wait_until(fn -> reported_exit?(runner) end, 10_000, "the runner's exit report")
    wait_until(fn -> OpusService.status().attempts == [] end, 10_000)
    wait_until(fn -> Slots.status(@slots).child_active == children_before end)
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert charges(ctx, authority) == []
    refute_received {:ran, _}
  end

  test "a runner whose process dies is reported at once: its attempt lapses, and a sibling in another runner keeps running",
       %{ctx: ctx, authority: authority, root_id: root_id, attempt: attempt} do
    hold_children!(root_id)
    test_pid = self()

    for _ <- 1..2 do
      spawn_link(fn ->
        id = Prima.UUID7.execution_id()
        ran = child!(ctx, authority, root_id, attempt, execution_id: id)
        send(test_pid, {:ran, id, ran})
      end)
    end

    assert_receive {:held, exited, _held}, 30_000
    assert_receive {:held, sibling, sibling_held}, 30_000
    exited_runner = runner_of(ctx, exited)
    refute runner_of(ctx, sibling) == exited_runner
    sibling_attempt = Attempt.whereis(sibling)

    kill_runner_process!(exited_runner)

    assert_receive {:ran, ^exited, {:error, @lapsed}}, 10_000
    assert %{status: "failed", error_message: @lapsed} = row(exited)
    assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(ctx, exited)
    wait_until(fn -> reported_exit?(exited_runner) end, 10_000, "the runner's exit report")
    wait_until(fn -> Attempt.whereis(exited) == nil end)

    assert Attempt.whereis(sibling) == sibling_attempt
    assert row(sibling).status == "running"

    TwoServices.release!(sibling_held)
    assert_receive {:ran, ^sibling, {:ok, %{status: :completed}}}, 30_000
    assert row(sibling).status == "completed"
  end

  test "a formula's runner dying mid-fan-out takes its children with it and reclaims every hold they took",
       %{ctx: ctx} do
    children_before = Slots.status(@slots).child_active
    slots_before = Slots.status(@slots).active
    root_id = Prima.UUID7.execution_id()
    hold_children!(root_id)
    test_pid = self()

    request = %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{"reference" => Probe.probe_ref(), "input" => Probe.held_input()}
    }

    spawn(fn ->
      send(
        test_pid,
        {:root,
         Crucible.run_root(
           ctx,
           :default,
           Probe.probe_ref(),
           %{"op" => "spawn_await_all", "requests" => List.duplicate(request, 3)},
           execution_id: root_id
         )}
      )
    end)

    ids =
      for _ <- 1..3 do
        assert_receive {:held, id, _held}, 30_000
        id
      end

    # The children run in their formula's runner.
    runner = runner_of(ctx, root_id)
    assert Enum.all?(ids, &(runner_of(ctx, &1) == runner))
    root_authority = reserved_authority(ctx, root_id)

    assert Sanctum.Authority.budget(root_authority).in_flight == 3
    assert length(charges(ctx, root_authority)) == 3
    assert Slots.status(@slots).child_active == children_before + 3

    # The service has heard of every child its runner started.
    held_attempts = for id <- [root_id | ids], do: row(id).current_attempt
    wait_until(fn -> Enum.all?(held_attempts, &(&1 in OpusService.status().attempts)) end)

    kill_runner_process!(runner)

    assert_receive {:root, {:error, @lapsed}}, 10_000
    assert %{status: "failed", error_message: @lapsed} = row(root_id)

    # The service reported the formula and every child it said it started.
    wait_until(fn -> reported_exit?(runner) end, 10_000, "the runner's exit report")

    reported =
      for %{callback: :runner_exited, args: %{"runner" => ^runner, "attempts" => held}} <-
            TwoServices.calls(),
          attempt <- held,
          do: attempt

    assert Enum.sort(Enum.uniq(reported)) == Enum.sort(held_attempts)

    for id <- ids do
      wait_until(fn -> row(id).status == "failed" end, 10_000)
      wait_until(fn -> Attempt.whereis(id) == nil end)
    end

    wait_until(fn -> Slots.status(@slots).child_active == children_before end)
    wait_until(fn -> Slots.status(@slots).active == slots_before end)

    wait_until(fn -> Sanctum.Authority.budget(root_authority).in_flight == 0 end)
    wait_until(fn -> charges(ctx, root_authority) == [] end)
  end

  describe "start, over the wire" do
    setup do
      %{service: service, boot: boot} = OpusService.status()
      {:ok, service: service, boot: boot}
    end

    test "refuses an assignment addressed to another worker service, or another boot of this one",
         %{service: service, boot: boot} do
      assert service != "wrk_other"

      other_service =
        AttemptFixtures.attached!(service_id: "wrk_other", boot_id: boot, attach: false)

      assert {:error, :malformed} =
               OpusService.start!(
                 other_service.assignment,
                 input(other_service),
                 sealed(other_service)
               )

      other_boot =
        AttemptFixtures.attached!(service_id: service, boot_id: "boot_other", attach: false)

      assert {:error, :malformed} =
               OpusService.start!(
                 other_boot.assignment,
                 input(other_boot),
                 sealed(other_boot)
               )

      Attempt.refuse(other_service.pid, "not started")
      Attempt.refuse(other_boot.pid, "not started")
    end

    test "refuses input its assignment's digest does not bind", %{service: service, boot: boot} do
      fixture = AttemptFixtures.attached!(service_id: service, boot_id: boot, attach: false)

      assert {:error, :malformed} =
               OpusService.start!(fixture.assignment, ~s({"fixture":false}), sealed(fixture))

      Attempt.refuse(fixture.pid, "not started")
    end

    test "refuses keys that do not open as the assignment's attempt on this worker service", %{
      service: service,
      boot: boot
    } do
      fixture = AttemptFixtures.attached!(service_id: service, boot_id: boot, attach: false)
      other = AttemptFixtures.attached!(service_id: service, boot_id: boot, attach: false)
      elsewhere = Prima.WorkerAuth.dispatch_seal_key(worker_key!("wrk_other"))
      signing = Prima.WorkerAuth.dispatch_key(worker_key!(service))

      for sealed <- [
            sealed(other),
            sealed(fixture, elsewhere),
            sealed(fixture, signing),
            "not sealed"
          ] do
        assert {:error, :malformed} =
                 OpusService.start!(fixture.assignment, input(fixture), sealed)
      end

      assert %{runners: %{busy: 0}, attempts: []} = OpusService.status()
      Attempt.refuse(fixture.pid, "not started")
      Attempt.refuse(other.pid, "not started")
    end
  end

  # A child of the root: the probe asking for a catalog tool, held there.
  defp child!(ctx, authority, root_id, attempt, opts) do
    Crucible.run_child(
      authority,
      Probe.probe_ref(),
      nil,
      Probe.held_input(),
      Keyword.merge(
        [
          ctx: Sanctum.Context.enter_guest(ctx),
          attempt: attempt,
          parent_execution_id: root_id,
          root_execution_id: root_id,
          declared_needs: []
        ],
        opts
      )
    )
  end

  # Children of `root_id` are held at their catalog tool call: the test
  # receives `{:held, id, held}` for each and lets the call go with
  # `Cyfr.Test.TwoServices.release!/1`.
  defp hold_children!(root_id) do
    TwoServices.hold!(
      :tool_call,
      fn row, _call -> row != nil and row.parent_execution_id == root_id end,
      []
    )
  end

  # The runner that claimed the run's attempt, as its host calls present it.
  defp runner_of(ctx, id), do: attempt_row(ctx, id).claimed_by

  # Whether the Opus service reported `runner`'s exit over the wire.
  defp reported_exit?(runner) do
    Enum.any?(
      TwoServices.calls(),
      &match?(%{callback: :runner_exited, args: %{"runner" => ^runner}}, &1)
    )
  end

  # The runner's process dies as a crashed or OOM-killed one does: killed
  # outright, with nothing written on its channel.
  defp kill_runner_process!(runner) do
    %{pid: handle} = Enum.find(Opus.RunnerPool.runners(Opus.RunnerPool), &(&1.id == runner))
    %{os_pid: os_pid} = Opus.RunnerProcess.info(handle)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    :ok
  end

  defp input(fixture), do: Jason.encode!(fixture.input)

  # The fixture's attempt keys, sealed with `key` (default the dispatch seal
  # key of the worker service the attempt is dispatched to).
  defp sealed(fixture, key \\ nil) do
    key = key || Prima.WorkerAuth.dispatch_seal_key(worker_key!(fixture.service))
    {:ok, sealed} = Prima.WorkerAuth.seal_attempt_keys(key, fixture.keys)
    sealed
  end

  defp worker_key!(worker) do
    {:ok, key} = Keys.opus_key(worker)
    key
  end

  defp row(id), do: Arca.Repo.get!(Arca.Schemas.Execution, id)

  # An authority naming the invocation reservation a root was admitted
  # with, for reading its budget.
  defp reserved_authority(ctx, root_id) do
    import Ecto.Query, only: [from: 2]

    reservation =
      Arca.Repo.one!(
        from(r in Arca.Schemas.BudgetReservation,
          where: r.athanor_id == ^ctx.athanor_id and r.root_execution_id == ^root_id
        )
      )

    %{Prima.Authority.zero() | budget: %Budget{id: reservation.id, cap: reservation.cap}}
  end

  defp attempt_row(ctx, id),
    do: Arca.ExecutionAttempts.get(Sanctum.Context.actor(ctx), row(id).current_attempt)

  defp event_types(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(Sanctum.Context.actor(ctx), id, 0)
    Enum.map(rows, & &1.type)
  end

  defp charges(ctx, authority) do
    {:ok, charges} =
      Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)

    charges
  end
end
