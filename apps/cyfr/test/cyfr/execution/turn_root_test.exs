# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.TurnRootTest do
  @moduledoc """
  A turn's logical root: claimed without a guest, with its row, attempt,
  reservation and a `:root` slot on the calling process; paused and
  resumed with the turn, its attempt and its root moving together, the
  slot let go in between and held once while it runs; lost with its lease,
  claimed or resumed; adopted after a takeover.
  """

  use ExUnit.Case, async: false

  import Cyfr.Test.Wait
  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Arca.TurnStorage
  alias Cyfr.Execution.{LeaseWatch, Semaphore, TurnRoot}
  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "turn_root_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted

    {:ok, thread} = Arca.ThreadStorage.create(ctx)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua go"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    {:ok, ctx: ctx, turn: turn}
  end

  defp roots, do: Semaphore.status().root_active

  defp me_holding?,
    do: Enum.any?(Semaphore.status().holders, &(&1.pid == inspect(self())))

  defp holders(pid),
    do: Enum.count(Semaphore.status().holders, &(&1.pid == inspect(pid)))

  defp execution(id), do: Arca.Repo.get!(Arca.Execution, id)

  defp claim!(ctx, turn, opts \\ []) do
    {:ok, claim} =
      TurnRoot.claim(
        ctx,
        @soul,
        [turn_id: turn.id, envelope: %{"task" => "go"}] ++ opts
      )

    {:ok, started} =
      TurnStorage.start(ctx, turn.id, %{
        root_execution_id: claim.execution_id,
        attempt: claim.attempt,
        budget_id: claim.budget_id,
        profile_id: claim.authority.profile_id,
        consent_id: claim.authority.consent_id,
        fence: turn.fence
      })

    {claim, started}
  end

  test "a claim admits the turn root and holds one root slot on the calling process", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    row = execution(claim.execution_id)
    assert row.kind == "turn"
    assert row.component_type == "agent"
    assert row.reference =~ "agent:local.aqua"
    assert row.profile_id == claim.authority.profile_id
    assert is_binary(row.activation_digest)
    assert row.current_attempt == claim.attempt
    assert row.turn_id == turn.id
    assert %{fence: 1, state: "running"} = ExecutionAttempts.get(ctx.athanor_id, claim.attempt)

    assert %{cap: cap, released_at: nil} =
             Arca.BudgetReservations.lookup(ctx.athanor_id, claim.budget_id)

    assert cap == claim.authority.budget.cap
    assert roots() == before + 1
    assert me_holding?()
    assert Process.alive?(claim.keeper)
    assert started.status == "running"

    # No guest ran: the row has no output and the turn holds the slot
    # itself, so the children it dispatches from workers class as `:child`.
    assert is_nil(row.output)

    {:ok, _} = TurnStorage.finish(ctx, turn.id, "completed", %{fence: started.fence})
    :ok = TurnRoot.release(ctx, claim.execution_id, claim: claim)
    assert roots() == before
    refute Process.alive?(claim.keeper)
    assert execution(claim.execution_id).status == "completed"
  end

  test "pause lets the slot go with the rows out of running, and resume takes it back first", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    assert {:ok, %{turn: paused}} =
             TurnRoot.pause(ctx, claim.execution_id,
               claim: claim,
               turn_id: turn.id,
               fence: started.fence,
               reason: "approval"
             )

    assert paused.status == "paused"
    assert roots() == before
    refute Process.alive?(claim.keeper)
    assert execution(claim.execution_id).status == "paused"
    assert %{state: "paused"} = ExecutionAttempts.get(ctx.athanor_id, claim.attempt)

    # A lapsed lease on a paused attempt is nobody's business: neither the
    # sweeper nor retention touches it.
    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: DateTime.add(DateTime.utc_now(), -600, :second)]
      )

    assert [] = Arca.Execution.list_stale_running(DateTime.utc_now())
    :ok = Cyfr.Execution.Sweeper.sweep()
    assert execution(claim.execution_id).status == "paused"
    assert {:ok, []} = Arca.Execution.stale_ids(0, athanor_id: ctx.athanor_id)

    # Resume from a fresh process: the slot is taken there, the rows move,
    # the keeper renews a new lease.
    test_pid = self()

    task =
      Task.async(fn ->
        {:ok, resumed} =
          TurnRoot.resume(ctx, claim.execution_id,
            turn_id: turn.id,
            fence: started.fence
          )

        send(test_pid, {:resumed, resumed, Semaphore.status().root_active})
        receive do: (:done -> :ok)
        TurnRoot.release(ctx, claim.execution_id, claim: resumed)
      end)

    assert_receive {:resumed, resumed, roots_while}, 5_000
    assert roots_while == before + 1
    assert resumed.turn.status == "running"
    assert execution(claim.execution_id).status == "running"
    attempt = ExecutionAttempts.get(ctx.athanor_id, claim.attempt)
    assert attempt.state == "running"
    assert DateTime.compare(attempt.lease_until, DateTime.utc_now()) == :gt

    send(task.pid, :done)
    Task.await(task)
    assert roots() == before
  end

  test "a lost lease exits the holder, and the semaphore's monitor releases the slot", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {claim, _started} = claim!(ctx, turn, tick_ms: 50)
        send(test_pid, {:claimed, claim})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, claim}, 10_000
    assert roots() == before + 1

    # The attempt is retired underneath the holder.
    {:ok, _} = ExecutionAttempts.close(ctx.athanor_id, claim.attempt, "failed", "error")

    assert_receive {:DOWN, ^ref, :process, ^holder, {:lease_lost, id}}, 5_000
    assert id == claim.execution_id
    Process.sleep(50)
    assert roots() == before
  end

  test "a resumed root that loses its lease exits its holder, and its slot is released", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)

    {:ok, _} =
      TurnRoot.pause(ctx, claim.execution_id,
        claim: claim,
        turn_id: turn.id,
        fence: started.fence,
        reason: "approval"
      )

    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {:ok, resumed} =
          TurnRoot.resume(ctx, claim.execution_id,
            turn_id: turn.id,
            fence: started.fence,
            tick_ms: 50
          )

        send(test_pid, {:resumed, resumed})
        Process.sleep(:infinity)
      end)

    assert_receive {:resumed, resumed}, 10_000
    assert roots() == before + 1

    {:ok, _} = ExecutionAttempts.close(ctx.athanor_id, resumed.attempt, "failed", "error")

    assert_receive {:DOWN, ^ref, :process, ^holder, {:lease_lost, id}}, 5_000
    assert id == claim.execution_id
    wait_until(fn -> roots() == before end)
    refute Process.alive?(resumed.keeper)
  end

  test "pause and resume, repeated from fresh holders, hold exactly one root slot while running",
       %{ctx: ctx, turn: turn} do
    before = roots()
    active = Semaphore.status().active
    {claim, started} = claim!(ctx, turn)
    assert roots() == before + 1

    pause = fn holding ->
      {:ok, %{turn: paused}} =
        TurnRoot.pause(ctx, claim.execution_id,
          claim: holding,
          turn_id: turn.id,
          fence: started.fence,
          reason: "approval"
        )

      paused
    end

    assert pause.(claim).status == "paused"
    assert roots() == before

    for _cycle <- 1..3 do
      test_pid = self()

      holder =
        Task.async(fn ->
          {:ok, resumed} =
            TurnRoot.resume(ctx, claim.execution_id,
              turn_id: turn.id,
              fence: started.fence
            )

          send(test_pid, {:holding, self()})
          receive do: (:pause -> :ok)
          pause.(resumed)
        end)

      assert_receive {:holding, pid}, 10_000
      assert roots() == before + 1
      assert holders(pid) == 1

      # A second resume while the root runs is refused, and gives back the
      # slot it took before asking.
      assert {:error, _} =
               Task.await(
                 Task.async(fn ->
                   TurnRoot.resume(ctx, claim.execution_id,
                     turn_id: turn.id,
                     fence: started.fence
                   )
                 end)
               )

      wait_until(fn -> roots() == before + 1 end)

      send(pid, :pause)
      assert Task.await(holder).status == "paused"
      wait_until(fn -> roots() == before end)
      assert holders(pid) == 0
    end

    assert execution(claim.execution_id).status == "paused"
    wait_until(fn -> Semaphore.status().active == active end)
  end

  test "a cancel asked of the attempt exits the holder at the next tick", %{ctx: ctx, turn: turn} do
    test_pid = self()

    {holder, ref} =
      spawn_monitor(fn ->
        {claim, _} = claim!(ctx, turn, tick_ms: 50)
        send(test_pid, {:claimed, claim})
        Process.sleep(:infinity)
      end)

    assert_receive {:claimed, claim}, 10_000
    {:ok, 1} = ExecutionAttempts.request_cancel(ctx.athanor_id, claim.execution_id)
    assert_receive {:DOWN, ^ref, :process, ^holder, {:cancel_requested, _}}, 5_000
  end

  test "a takeover's successor is adopted with a slot and a keeper of its own", %{
    ctx: ctx,
    turn: turn
  } do
    before = roots()
    {claim, started} = claim!(ctx, turn)
    LeaseWatch.stop(claim.keeper)
    Cyfr.Execution.Slot.release(claim.token)

    lapsed = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: lapsed]
      )

    :ok = Cyfr.Execution.Sweeper.sweep()
    assert execution(claim.execution_id).status == "failed"
    assert %{state: "lapsed"} = ExecutionAttempts.get(ctx.athanor_id, claim.attempt)

    {:ok, taken} = TurnStorage.takeover(ctx, turn.id, %{fence: started.fence})
    assert taken.attempt != claim.attempt
    assert execution(claim.execution_id).status == "running"

    {:ok, adopted} =
      TurnRoot.adopt(ctx, claim.execution_id, attempt: taken.attempt, tick_ms: 50)

    assert adopted.attempt == taken.attempt
    assert roots() == before + 1
    assert Process.alive?(adopted.keeper)
    Process.sleep(120)
    # The keeper renews the successor's lease, not the predecessor's.
    assert %{state: "running"} = ExecutionAttempts.get(ctx.athanor_id, taken.attempt)
    assert Process.alive?(self())

    {:ok, _} = TurnStorage.finish(ctx, turn.id, "uncertain", %{fence: taken.fence})
    :ok = TurnRoot.release(ctx, claim.execution_id, claim: adopted)
    assert roots() == before
    _ = started
  end
end
