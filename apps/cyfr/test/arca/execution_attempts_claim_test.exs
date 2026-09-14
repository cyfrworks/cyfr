# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionAttemptsClaimTest do
  @moduledoc """
  An attempt is claimed once, by the runner that attaches to it: a repeated
  claim by that runner holds, another runner's is `:replayed`, and an
  attempt that is not the running owner at the named fence is `:lost`. An
  attempt is held only by its claimant, at its fence, while it runs and
  owns its execution; a turn root is never claimed and so never held.
  """

  use ExUnit.Case, async: false

  alias Arca.ExecutionAttempts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp admit!(ctx, attrs \\ %{}) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        Map.merge(
          %{
            id: "exec_claim_#{System.unique_integer([:positive])}",
            reference: "catalyst:local.claim:0.1.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            component_type: "catalyst",
            input: "{}"
          },
          attrs
        )
      )

    {execution, attempt}
  end

  defp claimed_by(attempt), do: Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, attempt).claimed_by

  test "an admitted attempt is unclaimed until a runner claims it", %{ctx: ctx} do
    {_execution, attempt} = admit!(ctx)
    assert claimed_by(attempt.attempt) == nil

    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")
    assert claimed_by(attempt.attempt) == "runner_a"
  end

  test "a repeated claim by the claimant holds; another runner's is replayed", %{ctx: ctx} do
    {_execution, attempt} = admit!(ctx)
    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert {:error, :replayed} =
             ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_b")

    assert claimed_by(attempt.attempt) == "runner_a"
  end

  test "a claim at another fence, in another athanor or of a closed attempt is lost", %{ctx: ctx} do
    {execution, attempt} = admit!(ctx)

    assert {:error, :lost} =
             ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 2, "runner_a")

    assert {:error, :lost} = ExecutionAttempts.claim("ath_gamma", attempt.attempt, 1, "runner_a")

    {:ok, _} =
      Arca.Execution.record_end(
        ctx,
        execution.id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        attempt.attempt
      )

    assert {:error, :lost} =
             ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert claimed_by(attempt.attempt) == nil
  end

  test "an attempt a takeover retired can no longer be claimed or held", %{ctx: ctx} do
    {execution, attempt} = admit!(ctx)
    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")
    assert ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(ctx.athanor_id, execution.id,
        runner_id: Cyfr.Boot.id(),
        lease_until: ExecutionAttempts.lease_until()
      )

    assert successor.fence == 2
    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert {:error, :lost} =
             ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_b")

    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, successor.attempt, 2, "runner_b")
  end

  test "an attempt is held only by its claimant, at its fence, while it runs", %{ctx: ctx} do
    {execution, attempt} = admit!(ctx)

    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")
    assert :ok = ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")
    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_b")
    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 2, "runner_a")
    refute ExecutionAttempts.held?("ath_gamma", attempt.attempt, 1, "runner_a")

    {:ok, _} =
      Arca.Execution.record_end(
        ctx,
        execution.id,
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "stopped"},
        attempt.attempt
      )

    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")
  end

  test "a turn root's attempt is never claimed, so no runner holds it", %{ctx: ctx} do
    {_execution, attempt} = admit!(ctx, %{kind: "turn", component_type: "agent"})

    assert claimed_by(attempt.attempt) == nil
    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, Cyfr.Boot.id())
    refute ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, attempt.runner_id)
  end

  @tag :capture_log
  test "a store that cannot answer is an error, not an answer", %{ctx: ctx} do
    {_execution, attempt} = admit!(ctx)
    drop_executions!()

    assert {:error, :database_error} =
             ExecutionAttempts.claim(ctx.athanor_id, attempt.attempt, 1, "runner_a")

    assert {:error, :database_error} =
             ExecutionAttempts.held?(ctx.athanor_id, attempt.attempt, 1, "runner_a")
  end

  # An outage, simulated: the table is gone. Postgres drops the tables that
  # reference `executions` along with it.
  defp drop_executions! do
    if Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.Postgres,
      do: Arca.Repo.query!("DROP TABLE executions CASCADE"),
      else: Arca.Repo.query!("DROP TABLE executions")
  end
end
