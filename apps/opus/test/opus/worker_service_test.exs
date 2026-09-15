# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.WorkerServiceTest do
  @moduledoc """
  A run lives only as long as what waits for it and what runs it. A waiter
  that is killed kills its run: the runner and its component process stop,
  the attempt lapses at once, and the in-flight count, the execution slot
  and the charge row the run held all go back. Neither the worker service
  nor its runners' supervisor shows a runner's attempt keys. A runner that
  exits is reported at once: its attempt lapses and its waiter answers,
  while a sibling run on the same worker service keeps running and
  completes. The worker service starts only an assignment addressed to it,
  with the input its digest binds and keys sealed for it that open as its
  attempt.

  The runs are the `nested-probe` formula as a child of an admitted root,
  held at the entry to their guest until the test lets them go.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority.Budget
  alias Cyfr.Execution.{Attempt, Keys, Semaphore}
  alias Cyfr.Test.AttemptFixtures
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @lapsed "Execution terminated: runner stopped without cleanup"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "worker_service_#{System.unique_integer([:positive])}")

    keys = [:base_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Semaphore.forgive_unreaped(ctx.athanor_id)
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @probe_node)
    authority = %{authority | budget: Budget.new(2)}
    root_id = Cyfr.UUID7.execution_id()

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: Probe.probe_ref(),
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: authority.budget.id, cap: 2}
      )

    {:ok, ctx: ctx, authority: authority, root_id: root_id, attempt: attempt.attempt}
  end

  test "a killed waiter's run stops, its attempt lapses at once and what it held goes back", %{
    ctx: ctx,
    authority: authority,
    root_id: root_id,
    attempt: attempt
  } do
    children_before = Semaphore.status().child_active
    hold_children!(root_id)
    test_pid = self()

    waiter =
      spawn(fn ->
        send(test_pid, {:ran, child!(ctx, authority, root_id, attempt, guest_fn: :spawn)})
      end)

    assert_receive {:held, component, id}, 30_000
    attempt_pid = Attempt.whereis(id)
    runner = runner_of(id)

    assert Sanctum.Authority.budget(authority).in_flight == 1
    assert Semaphore.status().child_active == children_before + 1
    assert [%{admitted_at: %DateTime{}}] = charges(ctx, authority)

    # The runner's attempt keys are in neither the worker service's status
    # nor its runners' supervisor's.
    %{keys: keys} = AttemptFixtures.current!(ctx.athanor_id, id)

    for process <- [Opus.WorkerService, Opus.WorkerService.Runners],
        key <- [keys.call, keys.seal] do
      status = :erlang.term_to_binary(:sys.get_status(process))
      assert :binary.match(status, key) == :nomatch
    end

    Process.exit(waiter, :kill)

    wait_until(fn -> row(id).status == "failed" end, 5_000)
    assert %{error_message: @lapsed} = row(id)
    assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(ctx, id)
    assert "execution.lapsed" in event_types(ctx, id)

    wait_until(fn -> not Enum.any?([attempt_pid, runner.pid, component], &Process.alive?/1) end)
    wait_until(fn -> Semaphore.status().child_active == children_before end)
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert charges(ctx, authority) == []
    refute_received {:ran, _}
  end

  test "a runner's exit is reported at once: its attempt lapses, and a sibling keeps running", %{
    ctx: ctx,
    authority: authority,
    root_id: root_id,
    attempt: attempt
  } do
    hold_children!(root_id)
    test_pid = self()

    for _ <- 1..2 do
      spawn_link(fn ->
        id = Cyfr.UUID7.execution_id()
        ran = child!(ctx, authority, root_id, attempt, execution_id: id)
        send(test_pid, {:ran, id, ran})
      end)
    end

    assert_receive {:held, exited_component, exited}, 30_000
    assert_receive {:held, sibling_component, sibling}, 30_000
    exited_runner = runner_of(exited)
    sibling_attempt = Attempt.whereis(sibling)

    Process.exit(exited_runner.pid, :kill)

    assert_receive {:ran, ^exited, {:error, @lapsed}}, 5_000
    assert %{status: "failed", error_message: @lapsed} = row(exited)
    assert %{state: "lapsed", outcome: "uncertain"} = attempt_row(ctx, exited)
    wait_until(fn -> not Process.alive?(exited_component) end)
    assert Attempt.whereis(exited) == nil

    assert Process.alive?(sibling_component)
    assert Attempt.whereis(sibling) == sibling_attempt
    assert row(sibling).status == "running"

    send(sibling_component, :continue)
    assert_receive {:ran, ^sibling, {:ok, %{status: :completed}}}, 30_000
    assert row(sibling).status == "completed"
  end

  describe "start/3" do
    setup do
      {:ok, %{boot: boot}} = Opus.WorkerService.status()
      {:ok, boot: boot}
    end

    test "refuses an assignment addressed to another worker service", %{boot: boot} do
      assert boot != "worker_other"
      fixture = AttemptFixtures.attached!(runner_id: "worker_other", attach: false)

      assert {:error, :malformed} =
               Opus.WorkerService.start(fixture.assignment, input(fixture), sealed(fixture))

      Attempt.refuse(fixture.pid, "not started")
    end

    test "refuses input its assignment's digest does not bind", %{boot: boot} do
      fixture = AttemptFixtures.attached!(runner_id: boot, attach: false)

      assert {:error, :malformed} =
               Opus.WorkerService.start(
                 fixture.assignment,
                 ~s({"fixture":false}),
                 sealed(fixture)
               )

      Attempt.refuse(fixture.pid, "not started")
    end

    test "refuses keys that do not open as the assignment's attempt on this worker service", %{
      boot: boot
    } do
      fixture = AttemptFixtures.attached!(runner_id: boot, attach: false)
      other = AttemptFixtures.attached!(runner_id: boot, attach: false)
      elsewhere = Cyfr.WorkerAuth.dispatch_seal_key(worker_key!("worker_other"))
      signing = Cyfr.WorkerAuth.dispatch_key(worker_key!(boot))

      for sealed <- [
            sealed(other),
            sealed(fixture, elsewhere),
            sealed(fixture, signing),
            "not sealed"
          ] do
        assert {:error, :malformed} =
                 Opus.WorkerService.start(fixture.assignment, input(fixture), sealed)
      end

      assert %{busy: 0} = elem(Opus.WorkerService.status(), 1).runners
      Attempt.refuse(fixture.pid, "not started")
      Attempt.refuse(other.pid, "not started")
    end
  end

  # A child of the root: the probe echoing, held at its guest's entry.
  defp child!(ctx, authority, root_id, attempt, opts) do
    Opus.Chain.run_child(
      authority,
      Probe.probe_ref(),
      nil,
      %{"op" => "echo"},
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

  # Children of `root_id` wait at their guest's entry for `:continue`.
  defp hold_children!(root_id) do
    test_pid = self()
    handler = "worker-service-hold-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :opus, :runtime, :authority_entered],
        fn _event, _measurements, %{execution_id: id}, _config ->
          case Arca.Repo.get(Arca.Execution, id) do
            %{parent_execution_id: ^root_id} ->
              send(test_pid, {:held, self(), id})

              receive do
                :continue -> :ok
              after
                60_000 -> :ok
              end

            _ ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp runner_of(id) do
    :sys.get_state(Opus.WorkerService).runners
    |> Map.values()
    |> Enum.find(&(&1.execution_id == id))
  end

  defp input(fixture), do: Jason.encode!(fixture.input)

  # The fixture's attempt keys, sealed with `key` (default the dispatch seal
  # key of the worker service the attempt is dispatched to).
  defp sealed(fixture, key \\ nil) do
    key = key || Cyfr.WorkerAuth.dispatch_seal_key(worker_key!(fixture.worker))
    {:ok, sealed} = Cyfr.WorkerAuth.seal_attempt_keys(key, fixture.keys)
    sealed
  end

  defp worker_key!(worker) do
    {:ok, key} = Keys.worker_key(worker)
    key
  end

  defp row(id), do: Arca.Repo.get!(Arca.Execution, id)

  defp attempt_row(ctx, id),
    do: Arca.ExecutionAttempts.get(ctx.athanor_id, row(id).current_attempt)

  defp event_types(ctx, id) do
    {:ok, rows} = Arca.ExecutionEvents.since(ctx.athanor_id, id, 0)
    Enum.map(rows, & &1.type)
  end

  defp charges(ctx, authority) do
    {:ok, charges} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    charges
  end
end
