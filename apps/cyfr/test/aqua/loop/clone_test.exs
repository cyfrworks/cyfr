# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.CloneTest do
  @moduledoc """
  The soul's own call clones it into a role: the role gets a turn of its
  own under the parent's root, runs its own loop with its own policy,
  never pauses, and its last reply is the parent's tool result. The clone
  runs under the soul's authority stepped along the soul → role consent
  edge — the soul's consent, the role's edges and keys — and pins the
  role's bytes it checked against that consent.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Loop.Clone
  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Compendium.{AgentIndex, AgentSource, AquaPath}
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.{Bootstrap, Commit, Plan, Source}

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "clone_#{System.unique_integer([:positive])}")
    keys = [:base_path, :seed_path, :consent_source, :workers]
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

    # The loops' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Threads.create(ctx)
    {:ok, ctx: ctx, thread: thread}
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

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{orchestrator: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp run!(ctx, turn),
    do: Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 120_000)

  defp clones_of(turn),
    do: Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.parent_turn_id == ^turn.id))

  defp call_under(role) do
    ref = AgentSource.ref(role)
    Enum.find(ScriptedWorker.calls(), &(ref in &1.authority.chain))
  end

  defp bind_claude!(ctx, opts) do
    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: Keyword.fetch!(opts, :name),
        kind: "api_key",
        fields: %{"ANTHROPIC_API_KEY" => Keyword.fetch!(opts, :key)}
      })

    label = Keyword.get(opts, :label, "default")
    {:ok, plan} = Plan.plan(ctx, %{ref: @model, label: label})
    decisions = %{ref: @model, label: label, bindings: [%{need: "api_key", entry_id: entry.id}]}
    commit!(ctx, plan, decisions)
    entry
  end

  defp consent!(ctx, decisions) do
    {:ok, plan} = Plan.plan(ctx, %{ref: decisions.ref})
    commit!(ctx, plan, decisions)
  end

  defp commit!(ctx, plan, decisions) do
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    committed
  end

  test "the soul clones the planner, which answers from its own turn under the soul's consent",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua plan this")

    start_supervised!({ScriptedWorker,
     ref: @model,
     script: [
       call("r1", "planner", %{"task" => "lay out the steps"}),
       # The clone's own model round: it may not ask, and it answers.
       call("p1", "files", %{"action" => "delete", "path" => "data/x"}),
       reply("Step one, step two."),
       reply("The planner says: step one, step two.")
     ]})

    assert :completed = run!(ctx, turn)

    {:ok, steps} = Tape.steps(ctx, turn)

    assert [
             %{kind: "model"},
             %{kind: "clone", tool: "planner", outcome: "ok"} = clone_step,
             %{kind: "model"}
           ] = steps

    assert {:ok, %{content: "Step one, step two."}} =
             Tape.message(ctx, clone_step.result_message_id)

    # The clone's turn: its own rows under the parent's root, closed, and
    # pinned to the soul's consent and the planner's own bytes.
    {:ok, %{root_execution_id: root, attempt: attempt} = parent} = Tape.turn(ctx, turn.id)
    [clone] = clones_of(turn)

    assert clone.status == "completed"
    assert clone.root_execution_id == root and clone.attempt == attempt
    assert clone.orchestrator == "planner"
    assert clone.profile_id == parent.profile_id and is_binary(clone.profile_id)
    assert clone.consent_id == parent.consent_id and is_binary(clone.consent_id)

    {:ok, snapshot} = AgentIndex.snapshot(ctx, "planner")
    assert clone.agent_revision_digest == snapshot.revision_digest
    assert clone.agent_capability_digest == snapshot.capability_digest
    assert {:ok, bytes} = Tape.agent_revision(ctx, clone)
    assert bytes =~ "Planner"

    # The clone's model call ran with the planner as its node, under the
    # soul's chain.
    assert %{authority: authority} = call_under("planner")
    assert authority.chain == [@soul, "agent:local.planner", @model]
    assert authority.cursor == {:bound, @model}
    assert authority.profile_id == parent.profile_id

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

  test "two roles on one catalyst run with the keys their edges select", %{
    ctx: ctx,
    thread: thread
  } do
    home = bind_claude!(ctx, name: "home key", key: "sk-home")
    work = bind_claude!(ctx, name: "work key", key: "sk-work", label: "work")

    consent!(ctx, %{
      ref: @soul,
      selections: [
        %{from: "agent:local.web", dep: @model, label: "default"},
        %{from: "agent:local.artisan", dep: @model, label: "work"}
      ]
    })

    turn = accept!(ctx, thread, "@aqua fetch, then make")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         call("r1", "web", %{"task" => "read the page"}),
         reply("The page says hello."),
         call("r2", "artisan", %{"task" => "make a thing"}),
         reply("Made."),
         reply("Fetched and made.")
       ]}
    )

    assert :completed = run!(ctx, turn)

    assert %{authority: web} = call_under("web")
    assert %{authority: artisan} = call_under("artisan")
    assert web.resources.vault.entry_id == home.id
    assert artisan.resources.vault.entry_id == work.id

    assert [_, _] = clones_of(turn)
  end

  test "a clone's authority is the soul's stepped to the role, and only along a consented edge",
       %{ctx: ctx} do
    {:ok, soul} = Cyfr.Execution.authority_for(ctx, :default, @soul)
    {:ok, roster} = AgentSource.enabled_roster(ctx)
    {:ok, planner} = AgentIndex.snapshot(ctx, "planner")
    {:ok, web} = AgentIndex.snapshot(ctx, "web")

    assert {:ok, as_planner} = Clone.authority(soul, "planner", planner, roster)
    assert as_planner.cursor == {:bound, "agent:local.planner"}
    assert as_planner.profile_id == soul.profile_id
    assert as_planner.consent_id == soul.consent_id
    assert as_planner.chain == [@soul, "agent:local.planner"]
    assert as_planner.budget == soul.budget

    # The role's own edges: the web role reaches the http hand, the
    # planner does not.
    http =
      {:invoke,
       %{reference: "catalyst:local.http", need: nil, activation_digest: nil, declared_needs: []}}

    {:ok, as_web} = Clone.authority(soul, "web", web, roster)
    assert {:child, _} = Cyfr.Authority.Transition.step(as_web, :call, http)

    refute match?(
             {:child, %{cursor: {:bound, _}}},
             Cyfr.Authority.Transition.step(as_planner, :call, http)
           )

    # A role the soul's consent does not name.
    assert {:error, {:no_role_edge, "nobody"}} = Clone.authority(soul, "nobody", planner, roster)

    # A role whose shape moved since the soul consented to it.
    moved = %{
      soul
      | activation:
          Map.put(soul.activation, "agent:local.planner", "sha256:" <> String.duplicate("0", 64))
    }

    assert {:error, {:role_shape_moved, "planner"}} =
             Clone.authority(moved, "planner", planner, roster)
  end

  test "a clone's streamed text reaches the thread on the soul's turn under its role", %{
    ctx: ctx,
    thread: thread
  } do
    :ok = Phoenix.PubSub.subscribe(Emissary.PubSub, Tape.topic(ctx, thread.id))
    turn = accept!(ctx, thread, "@aqua plan this")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         call("r1", "planner", %{"task" => "plan"}),
         {:emit, [%{"type" => "text.delta", "text" => "planning"}]},
         reply("planned"),
         {:emit, [%{"type" => "text.delta", "text" => "done"}]},
         reply("done")
       ]}
    )

    assert :completed = run!(ctx, turn)

    turn_id = turn.id

    assert_receive {:thread, _,
                    {:delta, %{text: "planning", role: "planner", turn_id: ^turn_id}}},
                   5_000

    assert_receive {:thread, _, {:delta, %{text: "done", role: nil, turn_id: ^turn_id}}}, 5_000
  end

  test "a turn cut while its clone works stops the clone, which writes nothing more", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua plan this")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         call("r1", "planner", %{"task" => "plan"}),
         {:probe, self()},
         reply("planned"),
         reply("done")
       ]}
    )

    loop = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, worker, _}, 60_000
    [clone] = clones_of(turn)
    watched = Process.monitor(worker)

    {:ok, running} = Tape.turn(ctx, turn.id)

    assert {:ok, _} =
             Aqua.Loop.abort(ctx, running, "stopped", fn ->
               {:ok, current} = Tape.turn(ctx, running.id)
               {:ok, current_clone} = Tape.turn(ctx, clone.id)
               assert current.fence > running.fence
               assert current_clone.fence > clone.fence
               Task.shutdown(loop, :brutal_kill)
             end)

    refute Process.alive?(worker)
    assert_receive {:DOWN, ^watched, :process, _, _}, 5_000

    assert [%{status: "cancelled", fence: fence}] = clones_of(turn)
    assert fence > clone.fence

    for owner <- [running, clone] do
      {:ok, steps} = Tape.steps(ctx, owner)
      refute Enum.any?(steps, &(&1.dispatch_state in ["proposed", "dispatched"]))
    end

    assert {:error, :superseded} = Tape.close_clone_turn(ctx, clone, "completed")
  end

  test "a clone runs the bytes its row pinned, not the file as it is now", %{
    ctx: ctx,
    thread: thread
  } do
    turn = accept!(ctx, thread, "@aqua plan this")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [call("r1", "planner", %{"task" => "plan"}), reply("planned"), reply("done")]}
    )

    assert :completed = run!(ctx, turn)
    [clone] = clones_of(turn)

    # A prose edit after the pin: the same capability, other bytes.
    path = AquaPath.role_file("planner")
    {:ok, bytes} = Arca.get(ctx, path)
    :ok = Arca.put(ctx, path, bytes <> "\n\nLIVE-EDIT-MARKER\n")
    {:ok, _} = AgentIndex.sync(ctx)

    {:ok, soul} = Cyfr.Execution.authority_for(ctx, :default, @soul)
    {:ok, roster} = AgentSource.enabled_roster(ctx)
    {:ok, live} = AgentIndex.snapshot(ctx, "planner")
    assert live.revision_digest != clone.agent_revision_digest
    {:ok, as_planner} = Clone.authority(soul, "planner", live, roster)

    {:ok, spec} =
      Aqua.Loop.Turn.build(ctx, clone,
        authority: as_planner,
        catalyst: @model,
        model: "claude-sonnet-4-6",
        excerpt?: false
      )

    refute spec.system =~ "LIVE-EDIT-MARKER"
    assert {:ok, pinned} = Tape.agent_revision(ctx, clone)
    refute pinned =~ "LIVE-EDIT-MARKER"
  end

  test "a soul whose consent moved mid-turn clones nothing more, and unseals no key for its next call",
       %{ctx: ctx, thread: thread} do
    turn = accept!(ctx, thread, "@aqua fetch, then make")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         call("r1", "web", %{"task" => "read the page"}),
         reply("The page says hello."),
         {:probe, self()},
         call("r2", "artisan", %{"task" => "make a thing"})
       ]}
    )

    task = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, worker, _}, 30_000

    {:ok, [soul_profile]} = Source.DB.profiles(ctx, @soul)
    :ok = Arca.ProfileStorage.set_status(ctx.athanor_id, soul_profile.id, "revoked")
    send(worker, :continue)

    # The call in flight finishes; the soul's next model call is refused at
    # attach, since its pinned consent is no longer the head.
    assert {:failed, {:setup_required, %{reason: "consent_moved"}}} = Task.await(task, 120_000)

    {:ok, steps} = Tape.steps(ctx, turn)

    assert %{tool: "web", outcome: "ok"} =
             Enum.find(steps, &(&1.kind == "clone" and &1.tool == "web"))

    assert %{tool: "artisan", outcome: "error"} =
             refused = Enum.find(steps, &(&1.kind == "clone" and &1.tool == "artisan"))

    assert {:ok, %{content: content}} = Tape.message(ctx, refused.result_message_id)
    assert content =~ "consent"
    assert [%{orchestrator: "web"}] = clones_of(turn)
  end

  test "a member's own role, consented through the soul's walk, clones under the soul's consent",
       %{ctx: ctx, thread: thread} do
    {:ok, %{"cloneable" => true}} =
      Aqua.AgentConfig.call_aqua(ctx, %{"action" => "create", "name" => "scout"})

    {:ok, %{minted: [], skipped: skipped}} = Bootstrap.run(ctx)
    assert {"agent:local.scout", :not_vouched} in skipped
    assert {:ok, []} = Source.DB.profiles(ctx, "agent:local.scout")

    bind_claude!(ctx, name: "claude key", key: "sk-test")
    consent!(ctx, %{ref: @soul, selections: [%{dep: @model, label: "default"}]})

    turn = accept!(ctx, thread, "@aqua scout ahead")

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         call("r1", "scout", %{"task" => "look"}),
         reply("clear"),
         reply("The scout says clear.")
       ]}
    )

    assert :completed = run!(ctx, turn)
    {:ok, parent} = Tape.turn(ctx, turn.id)
    [clone] = clones_of(turn)
    assert clone.orchestrator == "scout" and clone.status == "completed"
    assert clone.profile_id == parent.profile_id
    assert {:ok, []} = Source.DB.profiles(ctx, "agent:local.scout")
    assert %{authority: %{chain: [@soul, "agent:local.scout", @model]}} = call_under("scout")
  end
end
