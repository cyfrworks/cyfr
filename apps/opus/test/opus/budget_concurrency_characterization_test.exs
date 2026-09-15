# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.BudgetConcurrencyCharacterizationTest do
  @moduledoc """
  A root's invoke budget bounds its spawned children however they race:
  under a cap of 2, five concurrent spawns of a real child never hold more
  than 2 in flight or 2 admitted charges, the rest are refused, and once
  the admitted children finish every hold is given back — the in-flight
  count, the charge rows, the reservation's count and the child slots.

  The children are the `nested-probe` formula, held at the entry to their
  guest until the test lets them go, so the two admitted runs overlap the
  three refused ones.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority.Budget
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"
  @cap 2
  @spawns 5

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    {:ok, authority} = Cyfr.Execution.authority_for(ctx, :default, @probe_node)
    authority = %{authority | budget: Budget.new(@cap)}
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
        reservation: %{budget_id: authority.budget.id, cap: @cap}
      )

    {:ok, ctx: ctx, authority: authority, root_id: root_id, attempt: attempt.attempt}
  end

  test "five concurrent spawns under a cap of 2 never hold more than 2, and give everything back",
       %{ctx: ctx, authority: authority, root_id: root_id, attempt: attempt} do
    children_before = Cyfr.Execution.Semaphore.status().child_active
    hold_children!(root_id)
    sampler = sample(ctx, authority)

    test_pid = self()

    for _ <- 1..@spawns do
      spawn_link(fn ->
        result =
          Cyfr.Execution.run_child(authority, Probe.probe_ref(), nil, %{"op" => "echo"},
            ctx: Sanctum.Context.enter_guest(ctx),
            attempt: attempt,
            parent_execution_id: root_id,
            root_execution_id: root_id,
            declared_needs: [],
            guest_fn: :spawn
          )

        send(test_pid, {:spawned, result})
      end)
    end

    held =
      for _ <- 1..@cap do
        assert_receive {:held, runner, execution_id}, 30_000
        {runner, execution_id}
      end

    for _ <- 1..(@spawns - @cap) do
      assert_receive {:spawned, {:error, {:invoke_denied, :invoke_budget_exhausted}}}, 30_000
    end

    refute_received {:held, _, _}
    assert Sanctum.Authority.budget(authority).in_flight == @cap
    assert length(admitted(ctx, authority)) == @cap
    assert Arca.BudgetReservations.lookup(ctx.athanor_id, authority.budget.id).charged == @cap
    assert Cyfr.Execution.Semaphore.status().child_active == children_before + @cap

    for {runner, _execution_id} <- held, do: send(runner, :continue)

    for _ <- 1..@cap do
      assert_receive {:spawned, {:ok, %{status: :completed}}}, 60_000
    end

    for {_runner, execution_id} <- held do
      assert %{status: "completed", parent_execution_id: ^root_id} =
               Arca.Repo.get!(Arca.Execution, execution_id)
    end

    wait_until(fn -> Cyfr.Execution.Semaphore.status().child_active == children_before end)
    assert Sanctum.Authority.budget(authority).in_flight == 0
    assert {:ok, []} = Arca.BudgetReservations.charges(ctx.athanor_id, authority.budget.id)
    assert Arca.BudgetReservations.lookup(ctx.athanor_id, authority.budget.id).charged == 0

    assert %{in_flight: in_flight, admitted: admitted} = stop_sampling(sampler)
    assert in_flight <= @cap
    assert admitted <= @cap
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
