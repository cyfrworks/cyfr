# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.FilesHandHostRootsTest do
  @moduledoc """
  The assistant cannot rewrite its own definition through the files hand:
  a `files.write` to the soul's file, run end to end from a turn through
  the files catalyst and its guest storage door, is refused and leaves the
  file as it was, while the same hand writes under `data/`.

  The loop, the gate, the files catalyst (run on the runtime) and its
  storage door are real; the model is scripted.
  """

  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Tape
  alias Compendium.AquaPath
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @files "catalyst:local.files"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    ctx = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"

    prev = Application.get_env(:arca, :seed_path)

    on_exit(fn ->
      File.rm_rf!(tree)

      if prev,
        do: Application.put_env(:arca, :seed_path, prev),
        else: Application.delete_env(:arca, :seed_path)
    end)

    Application.put_env(:arca, :seed_path, @seed_root)

    # The loops' work stops before their tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, @files])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  test "a files.write to the soul's file is refused at the storage door, and one under data/ is made",
       %{ctx: ctx, thread: thread} do
    soul_policy!(ctx, %{"files.write" => "auto"})
    before = soul_file!(ctx)

    turn = accept!(ctx, thread, "@aqua rewrite yourself")

    # Only the model is scripted: the files catalyst runs on the runtime.
    script!([
      calls([
        {"c1", "files.write",
         %{"path" => "aqua/aqua.md", "content" => "---\ntool_policy:\n  notes.pin: auto\n---\n"}}
      ]),
      calls([{"c2", "files.write", %{"path" => "data/control.md", "content" => "control"}}]),
      reply("done")
    ])

    assert :completed = run(ctx, turn)

    assert %{outcome: "error", content: refused} = step_result(ctx, turn, "c1")
    # The guest storage door's own refusal, after the catalyst asked it.
    assert %{"type" => "storage_path_denied", "message" => message} = Jason.decode!(refused)
    assert message =~ "aqua/aqua.md"
    assert soul_file!(ctx) == before

    # The positive control: the same hand, run the same way, writes data/.
    assert %{outcome: "ok"} = step_result(ctx, turn, "c2")
    assert {:ok, "control"} = Arca.get(Sanctum.Context.actor(ctx), ["data", "control.md"])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp soul_file!(ctx) do
    {:ok, binary} = Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file())
    binary
  end

  # The soul's own definition gains `patch` through the door, and its grant
  # is walked again for the shape that moved.
  defp soul_policy!(ctx, patch) do
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "tool_policy_patch" => patch
      })

    decisions = %{ref: @soul, selections: [%{dep: @model, label: "default"}]}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp run(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(120_000)

  # The outcome a call's step closed with and the text its result row holds.
  defp step_result(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    step = Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
    {:ok, result} = Tape.message(ctx, step.result_message_id)
    %{outcome: step.outcome, content: result.content}
  end

  defp calls(blocks) do
    %{
      "content" =>
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end),
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
    }
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
end
