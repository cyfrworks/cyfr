# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.AgentWideAutoPolicyTest do
  @moduledoc """
  An agent's policy holds for every thread, so its `auto` is an
  agent-wide standing allow: an action declared to take none
  (`standing: false`: a pin, a scroll's write) or one only for a thread
  (`standing: :thread`: a kept note) is asked on a card at its call,
  whatever the agent's own file says. The `aqua` tool's door refuses an
  `auto` for it with the person's sentence, and a stored file that says
  `auto` anyway reaches the turn demoted to `ask`.

  The loop, the door, the gate and the cards are real; the model is
  scripted.
  """

  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Tape
  alias Compendium.{AquaAgent, AquaPath}
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  @not_agent_wide [
    {"notes.pin", %{"name" => "page", "content" => "the pinned page"}},
    {"notes.keep", %{"name" => "status", "content" => "all well"}},
    {"aqua.skill_create", %{"name" => "tidy", "description" => "Tidy up", "content" => "# Tidy"}}
  ]

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
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  describe "the aqua tool's door" do
    for {key, _args} <- @not_agent_wide do
      test "refuses #{key} at auto on the soul with a sentence, and leaves the file as it was",
           %{ctx: ctx} do
        key = unquote(key)
        before = soul_file!(ctx)

        assert {:error, {:invalid_argument, sentence}} =
                 Cyfr.Test.AquaTool.call(ctx, %{
                   "action" => "update",
                   "name" => "aqua",
                   "tool_policy_patch" => %{key => "auto"}
                 })

        assert sentence == "#{key} always asks — it cannot be set to auto"
        assert soul_file!(ctx) == before
      end
    end

    test "refuses a glob at auto that covers notes.pin, naming it", %{ctx: ctx} do
      assert {:error, {:invalid_argument, sentence}} =
               Cyfr.Test.AquaTool.call(ctx, %{
                 "action" => "update",
                 "name" => "aqua",
                 "tool_policy_patch" => %{"notes.*" => "auto"}
               })

      assert sentence =~ "notes.* at auto would cover "
      assert sentence =~ "notes.pin"
      refute sentence =~ "notes.read"
    end
  end

  describe "a stored policy that says auto" do
    for {key, args} <- @not_agent_wide do
      test "for #{key} still raises a card at the call", %{ctx: ctx, thread: thread} do
        key = unquote(key)
        args = unquote(Macro.escape(args))

        # Written past the door, as a hand-edited file or one stored
        # before the action took no standing allow.
        stored_soul_policy!(ctx, %{key => "auto"})

        turn = accept!(ctx, thread, "@aqua do it")
        script!([calls([{"c1", key, args}]), reply("done")])

        assert {:paused, :approval} = run(ctx, turn)

        assert %{dispatch_state: "proposed", approval_id: approval_id} = step(ctx, turn, "c1")
        assert is_binary(approval_id)

        {:ok, fresh} = Tape.turn(ctx, turn.id)
        assert {:ok, [%{id: ^approval_id}]} = Tape.pending_approvals(ctx, fresh)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp soul_file!(ctx) do
    {:ok, binary} = Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file())
    binary
  end

  # The soul's own file gains `patch`, written straight to storage, and its
  # grant is walked again for the shape that moved.
  defp stored_soul_policy!(ctx, patch) do
    {:ok, soul} = AquaAgent.parse(AquaPath.soul_name(), soul_file!(ctx))
    soul = %{soul | tool_policy: Map.merge(soul.tool_policy, patch)}
    :ok = Arca.put(Sanctum.Context.actor(ctx), AquaPath.soul_file(), AquaAgent.serialize(soul))
    {:ok, _} = Compendium.AgentIndex.sync(ctx)

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
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(60_000)

  # The step of one call, by the id its model gave it.
  defp step(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
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
