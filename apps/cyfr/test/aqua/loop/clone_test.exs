# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.CloneTest do
  @moduledoc """
  The soul's own call clones it into a role: the role gets a turn of its
  own under the parent's root, runs its own loop with its own policy,
  never pauses, and its last reply is the parent's tool result.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ConversationStorage, as: Conversations
  alias Cyfr.Test.ScriptedExecution
  alias Sanctum.Consent.{Bootstrap, Source}

  @moduletag :requires_opus_modules

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "clone_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :execution_impl]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :seed_path, @seed_root)
    Application.put_env(:cyfr, :consent_source, Source.DB)
    Application.put_env(:cyfr, :execution_impl, ScriptedExecution)

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

    {:ok, conv} = Conversations.create(ctx)
    {:ok, ctx: ctx, conv: conv}
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
    }

  defp call(id, name, args),
    do: %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
    }

  test "the soul clones the planner, which answers from its own turn", %{ctx: ctx, conv: conv} do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, conv.id, %{
        message: %{author: ctx.user_id, content: "@aqua plan this"},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    start_supervised!({ScriptedExecution,
     ref: @model,
     script: [
       call("r1", "planner", %{"task" => "lay out the steps"}),
       # The clone's own model round: it may not ask, and it answers.
       call("p1", "files", %{"action" => "delete", "path" => "data/x"}),
       reply("Step one, step two."),
       reply("The planner says: step one, step two.")
     ]})

    assert :completed =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 120_000)

    {:ok, steps} = Tape.steps(ctx, turn)

    assert [
             %{kind: "model"},
             %{kind: "clone", tool: "planner", outcome: "ok"} = clone_step,
             %{kind: "model"}
           ] = steps

    assert {:ok, %{content: "Step one, step two."}} =
             Tape.message(ctx, clone_step.result_message_id)

    # The clone's turn: its own rows under the parent's root, closed.
    {:ok, %{root_execution_id: root, attempt: attempt}} = Tape.turn(ctx, turn.id)

    [clone] =
      Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.parent_turn_id == ^turn.id))

    assert clone.status == "completed"
    assert clone.root_execution_id == root and clone.attempt == attempt
    assert clone.orchestrator == "planner"

    {:ok, clone_steps} = Tape.steps(ctx, clone)

    assert [
             %{kind: "model"},
             %{tool: "files", action: "delete", outcome: "denied"},
             %{kind: "model"}
           ] = clone_steps

    # The parent reads the summary only; the clone's own rows are its own.
    {:ok, parent_rows} = Tape.projection(ctx, turn)
    refute Enum.any?(parent_rows, &(&1.turn_id == clone.id))
    {:ok, clone_rows} = Tape.projection(ctx, clone)
    assert Enum.all?(clone_rows, &(&1.turn_id == clone.id))
    assert [%{content: "lay out the steps"} | _] = clone_rows
  end
end
