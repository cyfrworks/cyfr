# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.CatalogSourcesTest do
  @moduledoc """
  A catalog call's answer joins its turn as its operation declares it,
  read under the caller's actor, before the next call is decided; and a
  registry mutation reaching the registry is approved one card at a time,
  whatever allow a thread holds for it.

  The loop, the gate, the cards and the standing rule are real; the model
  is scripted and the registry is a Bypass server.
  """

  # The registry's address is global configuration, so the module runs
  # alone.
  use ExUnit.Case, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Source
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    ctx = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
    tree = own_tree!(ctx)

    keys = [
      arca: :seed_path,
      cyfr: :locus_runtime_workers,
      cyfr: :registry_url,
      cyfr: :registry_scheme
    ]

    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    on_exit(fn ->
      File.rm_rf!(tree)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    Application.put_env(:arca, :seed_path, @seed_root)
    bypass = Bypass.open()
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
    Application.put_env(:cyfr, :registry_scheme, "http")

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
    {:ok, ctx: ctx, thread: thread, bypass: bypass}
  end

  describe "the soul's own catalog reads" do
    test "carry nothing into the turn, so a thread's allow still covers the next call",
         %{ctx: ctx, thread: thread} do
      {:ok, _} = allow!(ctx, thread, "notes", "keep")
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

      assert %{outcome: "ok", approval_id: nil} = step(ctx, turn, "c4")
      refute Enum.any?(sources(ctx, turn), &Source.outside?/1)
    end
  end

  describe "a local component's inspection" do
    # Sol's T6b review regression (F1): the inspection of a local root
    # carries the entries a pulled dependency's own manifest declares.
    test "keeps a pulled dependency's prose outside before a standing allow is judged",
         %{ctx: ctx, thread: thread} do
      remote_reason = "REMOTE_PROSE_FROM_ACME"

      entries = [
        {"acme", "sol-loop-dep",
         %{
           "dependencies" => %{
             "static" => [
               %{
                 "ref" => "reagent:local.sol-optional-leaf:1.0.0",
                 "optional" => true,
                 "reason" => remote_reason
               }
             ]
           }
         }},
        {"local", "sol-loop-root",
         %{"dependencies" => %{"static" => [%{"ref" => "reagent:acme.sol-loop-dep:1.0.0"}]}}}
      ]

      wasm = File.read!(Path.expand("../../support/test_wasm/math.wasm", __DIR__))

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

      {:ok, _} = allow!(ctx, thread, "notes", "keep")
      turn = accept!(ctx, thread, "@aqua inspect the local root and keep what it says")

      script!([
        calls([
          {"c1", "component.inspect", %{"reference" => "reagent:local.sol-loop-root:1.0.0"}}
        ]),
        calls([{"c2", "notes.keep", %{"name" => "dependency-info", "content" => remote_reason}}]),
        reply("kept")
      ])

      outcome = run(ctx, turn)

      # The inspection answered, and its answer carries the pulled
      # dependency's prose.
      assert %{outcome: "ok", content: content} = step_result(ctx, turn, "c1")
      assert content =~ remote_reason

      assert Source.outside("reagent:acme.sol-loop-dep") in sources(ctx, turn)
      assert outcome == {:paused, :approval}
      assert %{approval_id: approval_id} = step(ctx, turn, "c2")
      assert is_binary(approval_id)
    end
  end

  describe "a registry read" do
    test "is outside material on the turn before the next call is decided, so a thread's allow that names no outside source asks",
         %{ctx: ctx, thread: thread, bypass: bypass} do
      soul_policy!(ctx, %{"registry.get_namespace" => "auto"})

      Bypass.expect_once(bypass, "GET", "/v1/namespaces/acme", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"slug" => "acme", "about" => "from the registry"}))
      end)

      {:ok, _} = allow!(ctx, thread, "notes", "keep")
      turn = accept!(ctx, thread, "@aqua look up acme and keep it")

      script!([
        calls([{"c1", "registry.get_namespace", %{"slug" => "acme"}}]),
        calls([
          {"c2", "notes.keep", %{"name" => "acme", "content" => "acme: from the registry"}}
        ]),
        reply("kept")
      ])

      assert {:paused, :approval} = run(ctx, turn)
      assert %{outcome: "ok"} = step(ctx, turn, "c1")
      assert Source.outside(nil) in sources(ctx, turn)

      # The keep the allow would have run asks, and its card names the
      # registry's answer as outside material.
      assert %{approval_id: approval_id} = step(ctx, turn, "c2")
      assert is_binary(approval_id)
      assert %{"sources" => shown} = pending_intent(ctx, turn)
      assert Source.to_json(Source.outside(nil)) in shown
    end

    test "an answer whose execution is another athanor's carries no ledger of it, only an unnamed outside source",
         %{ctx: ctx} do
      other = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
      foreign = execution!(other, [Source.outside("news.example")])
      own = execution!(ctx, [Source.outside("own.example")])
      call = %Aqua.Loop.Binding.Call{kind: :catalog, tool: "execution", action: "logs", args: %{}}

      assert Aqua.Loop.Policy.sources_of(call, {:ok, %{execution_id: own}}, ctx) ==
               [Source.outside("own.example")]

      assert Aqua.Loop.Policy.sources_of(call, {:ok, %{execution_id: foreign}}, ctx) ==
               [Source.outside(nil)]

      # The same answer read as the other athanor is that athanor's ledger.
      assert Aqua.Loop.Policy.sources_of(call, {:ok, %{execution_id: foreign}}, other) ==
               [Source.outside("news.example")]
    end
  end

  describe "a registry mutation" do
    for {action, args, kind} <- [
          {"tokens_revoke", %{"slug" => "acme", "token_id" => "tok_1"}, :destructive},
          {"report", %{"category" => "spam", "details" => "junk", "target_namespace" => "acme"},
           :external}
        ] do
      test "registry.#{action} asks on a card under a thread allow stored before it took none, and runs once approved",
           %{ctx: ctx, thread: thread} do
        action = unquote(action)
        args = unquote(Macro.escape(args))
        kind = unquote(kind)
        soul_policy!(ctx, %{"registry.#{action}" => "ask"})

        # A row written past the rule that now refuses it, as one written
        # while the action was declared a write.
        {:ok, _} =
          Arca.ToolGrantStorage.put(%{
            athanor_id: ctx.athanor_id,
            scope: "thread",
            effect: "allow",
            thread_id: thread.id,
            agent_name: "aqua",
            tool: "registry",
            action: action,
            granted_by: ctx.user_id
          })

        # The rule refuses to write one now, at either scope.
        for place <- [%{scope: "thread", thread_id: thread.id}, %{scope: "agent"}] do
          assert {:error, {:scope_not_permitted, ^kind}} =
                   Sanctum.ToolGrants.put(
                     ctx,
                     Map.merge(place, %{
                       effect: "allow",
                       agent_name: "aqua",
                       tool: "registry",
                       action: action
                     })
                   )
        end

        turn = accept!(ctx, thread, "@aqua do it")
        script!([calls([{"c1", "registry.#{action}", args}]), reply("done")])

        assert {:paused, :approval} = run(ctx, turn)
        assert %{dispatch_state: "proposed", approval_id: approval_id} = step(ctx, turn, "c1")
        assert is_binary(approval_id)

        # Approved for this one call, the call is made: no push token is
        # held here, so the registry is never reached and the handler
        # answers the refusal.
        approve_once!(ctx, turn)
        assert :completed = resume(ctx, turn)
        assert %{outcome: "error", content: content} = step_result(ctx, turn, "c1")
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

  # The soul's own definition gains `patch`, and its grant is walked again
  # for the shape that moved.
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

  # A thread allow with no bounds, naming no outside source.
  defp allow!(ctx, thread, tool, action) do
    Aqua.ToolGrants.put(ctx, %{
      scope: "thread",
      effect: "allow",
      thread_id: thread.id,
      agent_name: "aqua",
      tool: tool,
      action: action
    })
  end

  # A completed execution of the athanor whose ledger holds `sources`.
  defp execution!(ctx, sources) do
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

    :ok = Opus.Ledger.join(Sanctum.Context.actor(ctx), id, sources)

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
        message: %{author: ctx.user_id, content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  defp script!(items), do: start_supervised!({ScriptedWorker, ref: @model, script: items})

  defp run(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(60_000)

  defp resume(ctx, turn) do
    Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)
    |> Task.await(60_000)
  end

  defp sources(ctx, turn) do
    {:ok, %{sources: sources}} = Tape.turn(ctx, turn.id)
    Source.decode(sources)
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

  defp pending_card(ctx, turn) do
    {:ok, fresh} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, fresh)
    {:ok, card} = Tape.message(ctx, approval.message_id)
    %{approval: approval, intent: Tape.payload(card)["intent"]}
  end

  defp pending_intent(ctx, turn), do: pending_card(ctx, turn).intent

  defp approve_once!(ctx, turn) do
    %{approval: approval} = pending_card(ctx, turn)

    assert {:ok, %{decision: "approved"}} =
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved})
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
