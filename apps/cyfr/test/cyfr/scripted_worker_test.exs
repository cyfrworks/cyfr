# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedWorkerTest do
  @moduledoc """
  The scripted worker service runs a child's whole lifecycle for real but
  its component. CYFR steps the chain and charges the invoke budget, admits
  the run with its hold barrier and dispatches it; the runner attaches with
  its signed assignment under the attempt's keys and claims the row; the
  attempt holds the slot, the charge and the masking set and closes the
  run. Only the answer is scripted. A waiter that dies kills its runner
  through the worker service, a cancel's kill is reported back under the
  worker service's own key, and a reference it does not script runs on
  the real worker service.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Cyfr.Authority
  alias Cyfr.Execution.{Attempt, Dispatch}
  alias Cyfr.Test.{AttemptFixtures, AuthorityFixtures, ScriptedWorker}

  @scripted "reagent:local.ta"
  @unscripted "reagent:local.scripted-worker-unscripted"
  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path =
      Path.join(System.tmp_dir!(), "scripted_worker_#{System.unique_integer([:positive])}")

    keys = [:base_path, :workers]
    previous = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :workers, [ScriptedWorker])
    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Cyfr.Execution.Semaphore.forgive_unreaped(ctx.athanor_id)
      File.rm_rf!(test_path)
      for {key, value} <- previous, do: Application.put_env(:cyfr, key, value)
    end)

    wasm = File.read!(@math_wasm_path)

    for name <- ["ta", "scripted-worker-unscripted"] do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: name,
          version: "1.0.0",
          type: "reagent"
        })
    end

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
      declared_needs: [],
      retention_class: "chat_step",
      charge: charge,
      guest_fn: :spawn
    )
  end

  defp boot do
    {:ok, %{boot: boot}} = ScriptedWorker.status()
    boot
  end

  test "a scripted child's attempt holds the charge, the claimed row and a child slot for the run",
       fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!(
      {ScriptedWorker,
       ref: @scripted,
       script: [{:probe, self()}, %{"content" => [%{"type" => "text", "text" => "hi"}]}]}
    )

    task = Task.async(fn -> run(fx) end)
    assert_receive {:scripted_probe, runner, ^child_id}, 5_000
    refute runner == task.pid

    assert Sanctum.Authority.budget(auth).in_flight == 1
    assert {:ok, [charge_row]} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)
    assert charge_row.admitted_at != nil
    assert charge_row.holder_execution_id == child_id

    # Claimed at attach by the runner, on the worker service it was sent to.
    assert %{state: "running", claimed_by: "runner" <> _, runner_id: runner_id} =
             Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert runner_id == boot()

    status = Cyfr.Execution.Semaphore.status()
    attempt = Attempt.whereis(child_id)
    assert status.child_active == 1
    assert Enum.any?(status.holders, &(&1.pid == inspect(attempt) and &1.class == :child))

    send(runner, :continue)

    assert {:ok, %{status: :completed, output: %{"status" => 200, "data" => data}}} =
             Task.await(task)

    assert data["content"] == [%{"type" => "text", "text" => "hi"}]

    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert {:ok, []} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)

    assert %{state: "completed", outcome: "ok"} =
             Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert %{status: "completed"} = Arca.Repo.get(Arca.Execution, child_id)
    assert Cyfr.Execution.Semaphore.status().child_active == 0

    assert [%{execution_id: ^child_id, input: %{"messages" => []}, authority: %Authority{}}] =
             ScriptedWorker.calls()
  end

  test "a waiter killed after attach kills its runner, and its attempt lapses with everything given back",
       fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: [{:crash, :before_response}]})

    {_pid, ref} = spawn_monitor(fn -> run(fx) end)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000

    wait_until(fn -> child_id in ScriptedWorker.kills() end)

    wait_until(fn ->
      match?(%{state: "lapsed"}, Arca.ExecutionAttempts.current(athanor_id, child_id))
    end)

    assert %{status: "failed"} = Arca.Repo.get(Arca.Execution, child_id)

    wait_until(fn -> Sanctum.Authority.budget(auth).in_flight == 0 end)
    wait_until(fn -> Cyfr.Execution.Semaphore.status().child_active == 0 end)
    assert {:ok, []} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)
  end

  test "an exhausted script fails the child and releases everything", fx do
    %{ctx: ctx, auth: auth, child_id: child_id} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: []})

    assert {:error, "script exhausted"} = run(fx)

    assert %{state: "failed", outcome: "error"} =
             Arca.ExecutionAttempts.current(athanor_id, child_id)

    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert {:ok, []} = Arca.BudgetReservations.charges(athanor_id, auth.budget.id)
  end

  test "an expired hold refuses admission before anything is dispatched", fx do
    %{ctx: ctx, auth: auth, child_id: child_id, charge: charge} = fx
    athanor_id = ctx.athanor_id

    start_supervised!({ScriptedWorker, ref: @scripted, script: [%{"content" => []}]})

    :ok = Arca.BudgetReservations.charge(athanor_id, auth.budget.id, charge, 1)
    expire_hold(athanor_id, charge.id)

    assert {:error, :hold_expired} = run(fx)
    assert Arca.ExecutionAttempts.current(athanor_id, child_id) == nil
    assert Arca.Repo.get(Arca.Execution, child_id) == nil
    assert Sanctum.Authority.budget(auth).in_flight == 0
    assert ScriptedWorker.calls() == []
  end

  test "what the runner emits and answers is masked with the key its attempt unsealed", %{
    ctx: ctx
  } do
    secret = "sk-scripted-secret"

    {authority, _entry} =
      AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: %{"KEY" => secret}})

    start_supervised!(
      {ScriptedWorker,
       ref: @scripted,
       script: [
         {:emit, [%{"type" => "text.delta", "text" => "the key is #{secret}"}]},
         %{"echo" => secret}
       ]}
    )

    id = Cyfr.UUID7.execution_id()

    assert {:ok, %{output: %{"data" => %{"echo" => "[REDACTED]"}}}} =
             Dispatch.run(ctx, "#{@scripted}:1.0.0", %{}, authority: authority, execution_id: id)

    emitted =
      for %{type: "emit", data: data} <- Cyfr.Execution.events_since(id, {0, 0}, ctx.athanor_id),
          do: data

    assert [%{"type" => "text.delta", "text" => "the key is [REDACTED]"}] = emitted
  end

  test "a cancel kills the runner through the worker service, and its exit report stops the attempt",
       %{ctx: ctx} do
    start_supervised!({ScriptedWorker, ref: @scripted, script: [:hang]})
    id = Cyfr.UUID7.execution_id()

    task =
      Task.async(fn ->
        Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
          authority: Authority.zero(),
          execution_id: id
        )
      end)

    wait_until(fn -> match?([_], ScriptedWorker.calls()) end, 5_000)

    assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(ctx, id)
    assert {:error, _cancelled} = Task.await(task)

    assert id in ScriptedWorker.kills()
    assert %{status: "cancelled"} = Arca.Repo.get(Arca.Execution, id)
    assert Attempt.whereis(id) == nil
    assert {:ok, %{attempts: []}} = ScriptedWorker.status()
  end

  test "a waiter is killed once the answer it waits for is written, before it returns it", %{
    ctx: ctx
  } do
    start_supervised!(
      {ScriptedWorker, ref: @scripted, script: [{:crash, :after_persist}, %{"done" => true}]}
    )

    id = Cyfr.UUID7.execution_id()
    test = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        answer =
          Dispatch.run(ctx, "#{@scripted}:1.0.0", %{},
            authority: Authority.zero(),
            execution_id: id
          )

        send(test, {:returned, answer})
      end)

    assert_receive {:DOWN, ^ref, :process, _, :killed}, 5_000
    refute_received {:returned, _}
    assert %{status: "completed"} = Arca.Repo.get(Arca.Execution, id)
  end

  @tag :requires_opus
  test "a reference it does not script runs on the real worker service", %{ctx: ctx} do
    start_supervised!({ScriptedWorker, ref: @scripted, script: []})

    assert {:error, message} =
             Dispatch.run(ctx, "#{@unscripted}:1.0.0", %{}, authority: Authority.zero())

    # math.wasm is a core module: the real runtime refuses it.
    assert message =~ "Component Model"
    assert ScriptedWorker.calls() == []
  end
end
