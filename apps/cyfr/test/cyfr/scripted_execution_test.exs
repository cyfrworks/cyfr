# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedExecutionTest do
  @moduledoc """
  The scripted engine runs a child's whole lifecycle for real — transition
  and invoke charge, admission with the hold barrier, a `:child` slot on
  the calling process, the terminal attempt write — and only the answer
  is scripted. A killed caller leaves exactly what a killed guest would.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Test.AuthorityFixtures
  alias Cyfr.Test.ScriptedExecution

  @moduletag :requires_opus_modules

  @scripted "reagent:local.ta"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    previous = Application.get_env(:cyfr, :execution_impl)
    Application.put_env(:cyfr, :execution_impl, ScriptedExecution)
    on_exit(fn -> Application.put_env(:cyfr, :execution_impl, previous) end)

    ctx = Sanctum.TestContext.local()
    auth = AuthorityFixtures.root!()
    root_id = "exec_scripted_root_#{System.unique_integer([:positive])}"

    {:ok, %{attempt: root_attempt}} =
      Arca.Execution.admit(
        %{
          id: root_id,
          reference: "#{AuthorityFixtures.formula_ref()}:1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula"
        },
        reservation: %{budget_id: auth.budget.id, cap: 2}
      )

    child_id = Cyfr.UUID7.execution_id()

    charge = %{
      id: "call:t:1:c1:g0",
      attempt: root_attempt.attempt,
      generation: 0,
      holder_execution_id: child_id
    }

    {:ok, ctx: ctx, auth: auth, root_id: root_id, child_id: child_id, charge: charge}
  end

  # The hold's admission window has passed.
  defp expire_hold(athanor_id, charge_id) do
    import Ecto.Query, only: [from: 2]
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      from(c in Arca.Schemas.BudgetCharge,
        where: c.athanor_id == ^athanor_id and c.id == ^charge_id
      )
      |> Arca.Repo.update_all(set: [admit_by: past])

    :ok
  end

  defp run(%{ctx: ctx, auth: auth, root_id: root_id, child_id: child_id, charge: charge}) do
    Cyfr.Execution.run_child(auth, "#{@scripted}:1.0.0", nil, %{"messages" => []},
      ctx: ctx,
      execution_id: child_id,
      parent_execution_id: root_id,
      root_execution_id: root_id,
      parent_reference: "agent:local.aqua",
      declared_needs: [],
      retention_class: "chat_step",
      charge: charge,
      guest_fn: :spawn
    )
  end

  test "a scripted child holds the charge, the row and a child slot for the call", fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!(
      {ScriptedExecution,
       ref: @scripted,
       script: [{:probe, self()}, %{"content" => [%{"type" => "text", "text" => "hi"}]}]}
    )

    task = Task.async(fn -> run(fx) end)

    assert_receive {:scripted_probe, worker, ^child_id}, 5_000
    assert worker == task.pid

    assert Sanctum.Authority.budget(auth).in_flight == 1
    assert {:ok, [charge_row]} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)
    assert charge_row.admitted_at != nil
    assert charge_row.holder_execution_id == child_id
    assert %{state: "running"} = Arca.ExecutionAttempts.current(athanor_id, child_id)

    status = Opus.ExecutionSemaphore.status()
    assert status.child_active == 1
    assert Enum.any?(status.holders, &(&1.pid == inspect(worker) and &1.class == :child))

    send(worker, :continue)

    assert {:ok, %{status: :completed, output: %{"status" => 200, "data" => data}}} =
             Task.await(task)

    assert data["content"] == [%{"type" => "text", "text" => "hi"}]

    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert {:ok, []} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)

    assert %{state: "completed", outcome: "ok"} =
             Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert %{status: "completed"} = Arca.Repo.get(Arca.Execution, child_id)
    assert Opus.ExecutionSemaphore.status().child_active == 0
    assert [%{execution_id: ^child_id, input: %{"messages" => []}}] = ScriptedExecution.calls()
  end

  test "a caller killed after admission leaves the attempt open and the hold admitted", fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedExecution, ref: @scripted, script: [{:crash, :before_response}]})

    {_pid, ref} = spawn_monitor(fn -> run(fx) end)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000

    assert %{state: "running"} = Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert {:ok, [%{admitted_at: admitted_at}]} =
             Arca.BudgetReservations.charges(athanor_id, auth.budget.id)

    assert admitted_at != nil

    wait_until(fn -> Sanctum.Authority.budget(auth).in_flight == 0 end)
    wait_until(fn -> Opus.ExecutionSemaphore.status().child_active == 0 end)
  end

  test "an exhausted script fails the child and releases everything", fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedExecution, ref: @scripted, script: []})

    assert {:error, "script exhausted"} = run(fx)

    assert %{state: "failed", outcome: "error"} =
             Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert {:ok, []} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)
  end

  test "an expired hold refuses admission before anything runs", fx do
    %{ctx: ctx, auth: auth, child_id: child_id, charge: charge} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedExecution, ref: @scripted, script: [%{"content" => []}]})

    :ok = Arca.BudgetReservations.charge(athanor_id, auth.budget.id, charge, 1)
    expire_hold(athanor_id, charge.id)

    assert {:error, :hold_expired} = run(fx)
    assert Arca.ExecutionAttempts.current(athanor_id, child_id) == nil
    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert ScriptedExecution.calls() == []
  end

  test "hands still reach the engine, and a scripted root is refused", fx do
    start_supervised!({ScriptedExecution, ref: @scripted, script: []})

    assert {:error, "the scripted engine roots nothing"} =
             Cyfr.Execution.run_root(fx.ctx, :default, "#{@scripted}:1.0.0", %{})

    # An unscripted reference goes to the engine, which answers for itself.
    result =
      Cyfr.Execution.run_child(fx.auth, "catalyst:local.http:1.0.0", nil, %{},
        ctx: fx.ctx,
        guest_fn: :call
      )

    assert match?({:error, _}, result) or match?({:ok, _}, result)
    assert ScriptedExecution.calls() == []
  end
end
