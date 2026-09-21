# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)
Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Opus.BudgetConcurrencyCharacterizationTest do
  @moduledoc """
  A root's invoke budget bounds a formula's spawned children however they
  race: under a cap of 2, five concurrent admissions of a child, asked
  over the wire as a formula's runner asks for a spawn (`admit_child`,
  spawn-shaped), never hold more than 2 in flight or 2 admitted charges,
  the rest are refused `resource_limit`, and once the admitted children
  close every hold is given back — the in-flight count, the charge rows,
  the reservation's count and the child slots. CYFR decides each
  admission under the authority it holds for the formula's attempt.

  A guest spawns one child at a time, so the race is the host's: five
  runners' worth of admissions at once, each made by the test with the
  client of the formula's attempt (`Opus.Test.FormulaHost`), and each
  admitted child closed by the test as the runner it was handed to does,
  its outcome sent with the keys its admission handed over.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority.Budget
  alias Opus.Test.FormulaHost
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap}

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

    keys = [:base_path]
    previous = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
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
    sampler = sample(ctx, authority)
    test_pid = self()

    for n <- 1..@spawns do
      spawn_link(fn ->
        admitted =
          Opus.HostClient.admit_child(
            formula.host,
            Probe.probe_ref(),
            nil,
            %{"op" => "echo", "n" => n},
            :spawn
          )

        send(test_pid, {:admitted, admitted})
      end)
    end

    answers =
      for _ <- 1..@spawns do
        assert_receive {:admitted, answer}, 30_000
        answer
      end

    children = for {:ok, child} <- answers, do: child
    refused = for {:error, refusal} <- answers, do: refusal

    assert length(children) == @cap

    assert refused ==
             List.duplicate(
               {:guest_error, "resource_limit", "Invocation denied: invoke_budget_exhausted"},
               @spawns - @cap
             )

    assert Sanctum.Authority.budget(authority).in_flight == @cap
    assert length(admitted(ctx, authority)) == @cap

    assert Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), authority.budget.id).charged ==
             @cap

    assert Cyfr.Slots.status(Cyfr.Execution.Slots).child_active == children_before + @cap

    # Each admitted child closes as the runner it was handed to closes it.
    for child <- children do
      assert {:ok, _recorded} = Opus.HostClient.complete(child.client, %{"echoed" => true})
      id = child.assignment.execution_id

      assert %{status: "completed", parent_execution_id: ^root_id} =
               Arca.Repo.get!(Arca.Execution, id)
    end

    wait_until(fn ->
      Cyfr.Slots.status(Cyfr.Execution.Slots).child_active == children_before
    end)

    wait_until(fn -> Sanctum.Authority.budget(authority).in_flight == 0 end)

    assert {:ok, []} =
             Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)

    assert Arca.BudgetReservations.lookup(Sanctum.Context.actor(ctx), authority.budget.id).charged ==
             0

    assert %{in_flight: in_flight, admitted: admitted} = stop_sampling(sampler)
    assert in_flight <= @cap
    assert admitted <= @cap
  end

  defp admitted(ctx, authority) do
    {:ok, charges} =
      Arca.BudgetReservations.charges(Sanctum.Context.actor(ctx), authority.budget.id)

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
