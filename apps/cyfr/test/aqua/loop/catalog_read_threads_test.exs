# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.CatalogReadThreadsTest do
  @moduledoc """
  A catalog call's answer joins its turn's read threads as its operation
  declares them, read under the caller's actor, and one that declares
  none joins nothing; and a registry mutation the soul is offered is
  made.

  The loop and the gate are real; the model is scripted and the registry
  is an HTTP stub.
  """

  # The registry's address is global configuration, so the module runs
  # alone.
  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Cyfr.Test.HTTPStub
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    ctx = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
    tree = own_tree!(ctx)

    keys = [cyfr: :locus_runtime_workers, cyfr: :registry_url]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      File.rm_rf!(tree)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Cyfr.Test.SeedBundle.lay!(~w(claude files http))
    stub = HTTPStub.open()
    # A loopback registry is reached over http (`Compendium.RegistryHost.base_url/1`).
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{stub.port}")

    # The loops' work stops before their tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, "catalyst:local.files", "catalyst:local.http"])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread, stub: stub}
  end

  describe "the soul's own catalog reads" do
    test "carry no thread into the turn, and the next call runs",
         %{ctx: ctx, thread: thread} do
      turn = accept!(ctx, thread, "@aqua look around and keep a note")

      script!([
        calls([
          {"c1", "system.status", %{}},
          {"c2", "component.list", %{}},
          {"c3", "aqua.list", %{}}
        ]),
        calls([{"c4", "notes.keep", %{"name" => "status", "content" => "all well"}}]),
        reply("kept")
      ])

      assert :completed = run(ctx, turn)

      for call <- ["c1", "c2", "c3"],
          do: assert(%{outcome: "ok"} = step(ctx, turn, call), call)

      assert %{outcome: "ok"} = step(ctx, turn, "c4")
      assert read_threads(ctx, turn) == []
    end
  end

  describe "a local component's inspection" do
    # The inspection of a local root carries the entries a pulled
    # dependency's own manifest declares.
    test "answers a pulled dependency's own entries, and the keep after it runs",
         %{ctx: ctx, thread: thread} do
      remote_reason = "REMOTE_PROSE_FROM_ACME"

      entries = [
        {"acme", "loop-dep",
         %{
           "dependencies" => %{
             "static" => [
               %{
                 "ref" => "reagent:local.optional-leaf:1.0.0",
                 "optional" => true,
                 "reason" => remote_reason
               }
             ]
           }
         }},
        {"local", "loop-root",
         %{"dependencies" => %{"static" => [%{"ref" => "reagent:acme.loop-dep:1.0.0"}]}}}
      ]

      wasm = Cyfr.Test.Guests.wasm(:reagent)

      for {publisher, name, extra} <- entries do
        manifest =
          Map.merge(
            %{
              "name" => name,
              "version" => "1.0.0",
              "type" => "reagent",
              "publisher" => publisher
            },
            extra
          )

        assert {:ok, _} =
                 Compendium.Registry.publish_bytes(
                   ctx,
                   wasm,
                   %{
                     name: name,
                     version: "1.0.0",
                     type: "reagent",
                     publisher: publisher,
                     manifest: Jason.encode!(manifest)
                   },
                   origin: if(publisher == "local", do: :local, else: :remote)
                 )
      end

      turn = accept!(ctx, thread, "@aqua inspect the local root and keep what it says")

      script!([
        calls([
          {"c1", "component.inspect", %{"reference" => "reagent:local.loop-root:1.0.0"}}
        ]),
        calls([{"c2", "notes.keep", %{"name" => "dependency-info", "content" => remote_reason}}]),
        reply("kept")
      ])

      assert :completed = run(ctx, turn)

      assert %{outcome: "ok", content: content} = step_result(ctx, turn, "c1")
      assert content =~ remote_reason
      assert %{outcome: "ok"} = step(ctx, turn, "c2")
      assert {:ok, %{content: ^remote_reason}} = Aqua.Notes.read(ctx, "dependency-info")
      assert read_threads(ctx, turn) == []
    end
  end

  describe "an execution read" do
    test "carries the read threads of its athanor's execution, and none of another athanor's",
         %{ctx: ctx} do
      other = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
      foreign = execution!(other, ["thr_theirs"])
      own = execution!(ctx, ["thr_own"])
      call = %Aqua.Loop.Binding.Call{kind: :catalog, tool: "execution", action: "logs", args: %{}}

      assert Aqua.Loop.Policy.threads_of(call, {:ok, %{execution_id: own}}, ctx) == ["thr_own"]
      assert Aqua.Loop.Policy.threads_of(call, {:ok, %{execution_id: foreign}}, ctx) == []

      # The same answer read as the other athanor carries that athanor's.
      assert Aqua.Loop.Policy.threads_of(call, {:ok, %{execution_id: foreign}}, other) ==
               ["thr_theirs"]
    end
  end

  describe "a registry mutation" do
    for {action, args} <- [
          {"tokens_revoke", %{"slug" => "acme", "token_id" => "tok_1"}},
          {"report", %{"category" => "spam", "details" => "junk", "target_namespace" => "acme"}}
        ] do
      test "registry.#{action} the soul is offered is made", %{ctx: ctx, thread: thread} do
        action = unquote(action)
        args = unquote(Macro.escape(args))
        soul!(ctx, %{"tools_add" => ["registry.#{action}"]})
        script!([calls([{"c1", "registry.#{action}", args}]), reply("done")])

        # The call is made: no push token is held here, so the registry is
        # never reached and the handler answers the refusal.
        ran = accept!(ctx, thread, "@aqua do it")
        assert :completed = run(ctx, ran)
        assert %{outcome: "error", content: content} = step_result(ctx, ran, "c1")
        assert content =~ "no push token"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp own_tree!(ctx) do
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    tree
  end

  # The soul's own file takes `edit` through the `aqua` tool, as the Aqua
  # page edits it, and its grant is walked again for the capability that
  # moved.
  defp soul!(ctx, edit) do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, Map.merge(%{"action" => "update", "name" => "aqua"}, edit))

    decisions = %{ref: @soul}
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

  # A completed execution of the athanor whose read threads are `threads`.
  defp execution!(ctx, threads) do
    id = "exec_cs_#{System.unique_integer([:positive])}"
    grant = Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id)

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: id,
          reference: "formula:local.reader",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula",
          origin: :interactive
        },
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    :ok = Arca.Execution.join_threads(Sanctum.Context.actor(ctx), id, threads)

    {:ok, _} =
      Arca.Execution.record_end(
        Sanctum.Context.actor(ctx),
        id,
        "completed",
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        attempt.attempt,
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    id
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp run(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(60_000)

  defp read_threads(ctx, turn) do
    {:ok, %{read_threads: read}} = Tape.turn(ctx, turn.id)
    Arca.ThreadStorage.threads_of(read)
  end

  # The step of one call, by the id its model gave it.
  defp step(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
  end

  # The outcome a call's step closed with and the text its result row holds.
  defp step_result(ctx, turn, call_id) do
    %{outcome: outcome} = step = step(ctx, turn, call_id)
    {:ok, result} = Tape.message(ctx, step.result_message_id)
    %{outcome: outcome, content: result.content}
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
