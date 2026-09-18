# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)
Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Opus.BudgetConcurrencyCharacterizationTest do
  @moduledoc """
  A root's invoke budget bounds a formula's spawned children however they
  race: under a cap of 2, five concurrent spawns of a real child through the
  formula's `spawn` host function never hold more than 2 in flight or 2
  admitted charges, the rest are refused, and once the admitted children
  finish every hold is given back — the in-flight count, the charge rows,
  the reservation's count and the child slots. CYFR decides each spawn
  under the authority it holds for the formula's attempt, and the children
  run in runners of the formula's group.

  The children are the `nested-probe` formula, held at the entry to their
  guest until the test lets them go, so the two admitted runs overlap the
  three refused ones.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority.Budget
  alias Opus.Test.FormulaHost
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000
  @moduletag :capture_log

  @probe_node "formula:local.nested-probe"
  @cap 2
  @spawns 5

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path =
      Path.join(System.tmp_dir!(), "budget_concurrency_#{System.unique_integer([:positive])}")

    keys = [:base_path, :consent_source]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @probe_node)
    authority = %{authority | budget: Budget.new(@cap)}

    formula =
      FormulaHost.attached!(ctx: ctx, authority: authority, component_ref: Probe.probe_ref())

    {:ok, ctx: ctx, authority: authority, formula: formula}
  end

  test "five concurrent spawns under a cap of 2 never hold more than 2, and give everything back",
       %{ctx: ctx, authority: authority, formula: formula} do
    root_id = formula.execution_id
    children_before = Cyfr.Slots.status(Cyfr.Execution.Slots).child_active
    hold_children!(root_id)
    sampler = sample(ctx, authority)

    {imports, tracker} =
      Opus.FormulaHandler.build_formula_imports(formula.host, FormulaHost.opts(authority))

    %{"spawn" => {:fn, spawn_fn}, "await" => {:fn, await_fn}} =
      imports["cyfr:formula/invoke@0.1.0"]

    request =
      Jason.encode!(%{
        "tool" => "execution",
        "action" => "run",
        "args" => %{"reference" => Probe.probe_ref(), "input" => %{"op" => "echo"}}
      })

    test_pid = self()

    for _ <- 1..@spawns do
      spawn_link(fn -> send(test_pid, {:spawned, Jason.decode!(spawn_fn.(request))}) end)
    end

    spawned =
      for _ <- 1..@spawns do
        assert_receive {:spawned, answer}, 30_000
        answer
      end

    held =
      for _ <- 1..@cap do
        assert_receive {:held, runner, execution_id}, 30_000
        {runner, execution_id}
      end

    task_ids = for %{"task_id" => task_id} <- spawned, do: task_id
    refused = for %{"error" => error} <- spawned, do: error

    assert length(task_ids) == @cap

    assert refused ==
             List.duplicate(
               %{
                 "type" => "resource_limit",
                 "message" => "Invocation denied: invoke_budget_exhausted"
               },
               @spawns - @cap
             )

    refute_received {:held, _, _}
    assert Sanctum.Authority.budget(authority).in_flight == @cap
    assert length(admitted(ctx, authority)) == @cap
    assert Arca.BudgetReservations.lookup(ctx.athanor_id, authority.budget.id).charged == @cap
    assert Cyfr.Slots.status(Cyfr.Execution.Slots).child_active == children_before + @cap

    for {runner, _execution_id} <- held, do: send(runner, :continue)

    for task_id <- task_ids do
      assert %{"status" => "completed"} = Jason.decode!(await_fn.(task_id))
    end

    for {_runner, execution_id} <- held do
      assert %{status: "completed", parent_execution_id: ^root_id} =
               Arca.Repo.get!(Arca.Execution, execution_id)
    end

    wait_until(fn -> Cyfr.Slots.status(Cyfr.Execution.Slots).child_active == children_before end)
    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)
    assert {:ok, []} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    assert Arca.BudgetReservations.lookup(ctx.athanor_id, authority.budget.id).charged == 0

    assert %{in_flight: in_flight, admitted: admitted} = stop_sampling(sampler)
    assert in_flight <= @cap
    assert admitted <= @cap

    Opus.FormulaHandler.cleanup_registry(tracker)
  end

  # Children of `root_id` wait at their guest's entry for `:continue`.
  defp hold_children!(root_id) do
    test_pid = self()
    handler = "budget-concurrency-hold-#{System.unique_integer([:positive])}"

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

  defp admitted(ctx, authority) do
    {:ok, charges} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    Enum.filter(charges, & &1.admitted_at)
  end

  # The highest in-flight count and admitted-charge count seen while the
  # spawns race.
  defp sample(ctx, authority) do
    test_pid = self()

    spawn_link(fn ->
      sample_loop(ctx, authority, test_pid, %{in_flight: 0, admitted: 0})
    end)
  end

  defp sample_loop(ctx, authority, test_pid, seen) do
    seen = %{
      in_flight: max(seen.in_flight, Sanctum.Authority.budget(authority).in_flight),
      admitted: max(seen.admitted, length(admitted(ctx, authority)))
    }

    receive do
      {:stop, ^test_pid} -> send(test_pid, {:sampled, seen})
    after
      2 -> sample_loop(ctx, authority, test_pid, seen)
    end
  end

  defp stop_sampling(sampler) do
    send(sampler, {:stop, self()})
    assert_receive {:sampled, seen}, 5_000
    seen
  end
end
