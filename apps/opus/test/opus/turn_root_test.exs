# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.TurnRootTest do
  @moduledoc """
  A turn's logical root: claimed without a guest, with its row, attempt,
  reservation and a `:root` slot on the calling process; paused and
  resumed with the turn, its attempt and its root moving together and the
  slot let go in between; lost with its lease; adopted after a takeover.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ExecutionAttempts
  alias Arca.TurnStorage
  alias Opus.ExecutionSemaphore
  alias Sanctum.Consent.{Bootstrap, Source}

  @seed_root Path.expand("../../../../seed", __DIR__)
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

  defp roots, do: ExecutionSemaphore.status().root_active

  defp me_holding?,
    do: Enum.any?(ExecutionSemaphore.status().holders, &(&1.pid == inspect(self())))

  defp execution(id), do: Arca.Repo.get!(Arca.Execution, id)

  defp claim!(ctx, turn, opts \\ []) do
    {:ok, claim} =
      Cyfr.Execution.claim_turn_root(
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
    :ok = Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: claim)
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
             Cyfr.Execution.pause_turn_root(ctx, claim.execution_id,
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
    :ok = Opus.ExecutionSweeper.sweep()
    assert execution(claim.execution_id).status == "paused"
    assert {:ok, []} = Arca.Execution.stale_ids(0, athanor_id: ctx.athanor_id)

    # Resume from a fresh process: the slot is taken there, the rows move,
    # the keeper renews a new lease.
    test_pid = self()

    task =
      Task.async(fn ->
        {:ok, resumed} =
          Cyfr.Execution.resume_turn_root(ctx, claim.execution_id,
            turn_id: turn.id,
            fence: started.fence
          )

        send(test_pid, {:resumed, resumed, ExecutionSemaphore.status().root_active})
        receive do: (:done -> :ok)
        Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: resumed)
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
    Opus.TurnRoot.Lease.stop(claim.keeper)
    Opus.Slot.release(claim.token)

    lapsed = DateTime.add(DateTime.utc_now(), -1, :second)

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.ExecutionAttempt, where: a.attempt == ^claim.attempt),
        set: [lease_until: lapsed]
      )

    :ok = Opus.ExecutionSweeper.sweep()
    assert execution(claim.execution_id).status == "failed"
    assert %{state: "lapsed"} = ExecutionAttempts.get(ctx.athanor_id, claim.attempt)

    {:ok, taken} = TurnStorage.takeover(ctx, turn.id, %{fence: started.fence})
    assert taken.attempt != claim.attempt
    assert execution(claim.execution_id).status == "running"

    {:ok, adopted} =
      Cyfr.Execution.adopt_turn_root(ctx, claim.execution_id, attempt: taken.attempt, tick_ms: 50)

    assert adopted.attempt == taken.attempt
    assert roots() == before + 1
    assert Process.alive?(adopted.keeper)
    Process.sleep(120)
    # The keeper renews the successor's lease, not the predecessor's.
    assert %{state: "running"} = ExecutionAttempts.get(ctx.athanor_id, taken.attempt)
    assert Process.alive?(self())

    {:ok, _} = TurnStorage.finish(ctx, turn.id, "uncertain", %{fence: taken.fence})
    :ok = Cyfr.Execution.release_turn_root(ctx, claim.execution_id, claim: adopted)
    assert roots() == before
    _ = started
  end
end
