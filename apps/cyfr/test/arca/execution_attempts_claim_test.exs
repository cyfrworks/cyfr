# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ExecutionAttemptsClaimTest do
  @moduledoc """
  An attempt is claimed once, by the runner that attaches to it: a repeated
  claim by that runner holds, another runner's is `:replayed`, and an
  attempt that is not the running owner at the named fence is `:lost`. An
  attempt is held only by its claimant, at its fence, while it runs and
  owns its execution; a turn root is never claimed and so never held. A
  held attempt is live while no cancel is asked of it and its execution
  runs.
  A storage write's store call runs only once its attempt was found held;
  `Arca.ExecutionAttemptsWriteTest` covers the rest of that protocol.
  """

  use ExUnit.Case, async: false

  alias Arca.ExecutionAttempts

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local())}
  end

  defp admit!(actor, attrs \\ %{}) do
    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        Map.merge(
          %{
            id: "exec_claim_#{System.unique_integer([:positive])}",
            reference: "catalyst:local.claim:0.1.0",
            user_id: actor.user_id,
            athanor_id: actor.athanor_id,
            component_type: "catalyst",
            input: "{}"
          },
          attrs
        ),
        Arca.Test.Actor.standing(actor.athanor_id)
      )

    {execution, attempt}
  end

  defp claimed_by(attempt), do: Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, attempt).claimed_by

  test "an admitted attempt is unclaimed until a runner claims it", %{actor: actor} do
    {_execution, attempt} = admit!(actor)
    assert claimed_by(attempt.attempt) == nil

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert claimed_by(attempt.attempt) == "runner_a"
  end

  test "a repeated claim by the claimant holds; another runner's is replayed", %{actor: actor} do
    {_execution, attempt} = admit!(actor)

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert {:error, :replayed} =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_b",
               Arca.Test.Actor.stored()
             )

    assert claimed_by(attempt.attempt) == "runner_a"
  end

  test "a claim at another fence, in another athanor or of a closed attempt is lost", %{
    actor: actor
  } do
    {execution, attempt} = admit!(actor)

    assert {:error, :lost} =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               2,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert {:error, :lost} =
             ExecutionAttempts.claim(
               Prima.Actor.in_athanor("ath_gamma"),
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        execution.id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        attempt.attempt,
        Arca.Test.Actor.stored()
      )

    assert {:error, :lost} =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert claimed_by(attempt.attempt) == nil
  end

  test "an attempt a takeover retired can no longer be claimed or held", %{actor: actor} do
    {execution, attempt} = admit!(actor)

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")

    {:ok, %{attempt: successor}} =
      ExecutionAttempts.takeover(actor, execution.id,
        boot_id: Prima.Boot.id(),
        lease_until: ExecutionAttempts.lease_until(),
        grant: :stored,
        verify: &Arca.Test.Actor.admits/1
      )

    assert successor.fence == 2
    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")

    assert {:error, :lost} =
             ExecutionAttempts.while_held(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               write(),
               Arca.Test.Actor.stored()
             )

    refute_received :ran

    assert {:error, :lost} =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_b",
               Arca.Test.Actor.stored()
             )

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               successor.attempt,
               2,
               "runner_b",
               Arca.Test.Actor.stored()
             )
  end

  test "an attempt is held only by its claimant, at its fence, while it runs", %{actor: actor} do
    {execution, attempt} = admit!(actor)

    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")
    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_b")
    refute ExecutionAttempts.held?(actor, attempt.attempt, 2, "runner_a")

    refute ExecutionAttempts.held?(
             Prima.Actor.in_athanor("ath_gamma"),
             attempt.attempt,
             1,
             "runner_a"
           )

    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        execution.id,
        "failed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "stopped"},
        attempt.attempt,
        Arca.Test.Actor.stored()
      )

    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")
  end

  test "work runs while its claimant holds the attempt, and not once the attempt closed",
       %{actor: actor} do
    {execution, attempt} = admit!(actor)

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert {:ok, {:confirmed, :ok}} =
             ExecutionAttempts.while_held(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               write(),
               Arca.Test.Actor.stored()
             )

    assert_received :ran

    for {athanor, fence, runner} <- [
          {actor.athanor_id, 1, "runner_b"},
          {actor.athanor_id, 2, "runner_a"},
          {"ath_gamma", 1, "runner_a"}
        ] do
      assert {:error, :lost} =
               ExecutionAttempts.while_held(
                 Prima.Actor.in_athanor(athanor),
                 attempt.attempt,
                 fence,
                 runner,
                 write(),
                 Arca.Test.Actor.stored()
               )
    end

    refute_received :ran
    assert Arca.Repo.get!(Arca.Schemas.ExecutionAttempt, attempt.attempt).fence == 1

    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        execution.id,
        "cancelled",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        nil,
        Arca.Test.Actor.stored()
      )

    assert {:error, :lost} =
             ExecutionAttempts.while_held(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               write(),
               Arca.Test.Actor.stored()
             )

    refute_received :ran
  end

  test "a held attempt is live until it is cancelled or its execution ends", %{actor: actor} do
    {_execution, attempt} = admit!(actor)

    refute ExecutionAttempts.live?(actor, attempt.attempt, 1, "runner_a")

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert ExecutionAttempts.live?(actor, attempt.attempt, 1, "runner_a")
    refute ExecutionAttempts.live?(actor, attempt.attempt, 1, "runner_b")
    refute ExecutionAttempts.live?(actor, attempt.attempt, 2, "runner_a")

    refute ExecutionAttempts.live?(
             Prima.Actor.in_athanor("ath_gamma"),
             attempt.attempt,
             1,
             "runner_a"
           )

    # A cancel is a terminal write: nothing is held or live after it.
    assert {:ok, _ran} =
             ExecutionAttempts.close(
               actor,
               attempt.attempt,
               "cancelled",
               "cancelled",
               Arca.Test.Actor.stored()
             )

    refute ExecutionAttempts.live?(actor, attempt.attempt, 1, "runner_a")
    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")

    {other, other_attempt} = admit!(actor)

    assert :ok =
             ExecutionAttempts.claim(
               actor,
               other_attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    {:ok, _} =
      Arca.Execution.record_end(
        actor,
        other.id,
        "cancelled",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        nil,
        Arca.Test.Actor.stored()
      )

    refute ExecutionAttempts.live?(
             actor,
             other_attempt.attempt,
             1,
             "runner_a"
           )
  end

  test "a turn root's attempt is never claimed, so no runner holds it", %{actor: actor} do
    {_execution, attempt} = admit!(actor, %{kind: "turn", component_type: "agent"})

    assert claimed_by(attempt.attempt) == nil
    refute ExecutionAttempts.held?(actor, attempt.attempt, 1, Prima.Boot.id())

    refute ExecutionAttempts.held?(
             actor,
             attempt.attempt,
             1,
             attempt.boot_id
           )
  end

  @tag :capture_log
  test "a store that cannot answer is an error, not an answer", %{actor: actor} do
    {_execution, attempt} = admit!(actor)
    drop_executions!()

    assert {:error, :database_error} =
             ExecutionAttempts.claim(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               Arca.Test.Actor.stored()
             )

    assert {:error, :database_error} =
             ExecutionAttempts.held?(actor, attempt.attempt, 1, "runner_a")

    assert {:error, :database_error} =
             ExecutionAttempts.live?(actor, attempt.attempt, 1, "runner_a")

    assert {:error, :database_error} =
             ExecutionAttempts.while_held(
               actor,
               attempt.attempt,
               1,
               "runner_a",
               write(),
               Arca.Test.Actor.stored()
             )

    refute_received :ran
  end

  # A storage write whose store call only reports that it ran.
  defp write, do: %{op: :put, path: ["data", "claim.txt"], io: &ran/0}

  defp ran do
    send(self(), :ran)
    :ok
  end

  # An outage, simulated: the table is gone. Postgres drops the tables that
  # reference `executions` along with it.
  defp drop_executions! do
    if Cyfr.RuntimeConfig.repo_adapter() == Ecto.Adapters.Postgres,
      do: Arca.Repo.query!("DROP TABLE executions CASCADE"),
      else: Arca.Repo.query!("DROP TABLE executions")
  end
end
