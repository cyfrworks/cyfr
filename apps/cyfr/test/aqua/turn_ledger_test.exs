# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TurnLedgerTest do
  @moduledoc """
  A turn and the ledgers of the children it runs (`Opus.Ledger`), through
  the real loop with a scripted model and scripted hands.

  A child of the turn's root is seeded with its own step's turn as it
  stands when the child is admitted — a source the turn read after its
  root was admitted included, on a clone's turn too — and the capability
  probe, which runs under no step, with every turn on the root.

  A model adds no source of its own and never drops one: what a model or
  hand child read joins its turn when its step closes, before its answer
  is used, by the first carrier that holds it — its completion result,
  else its row, else, for a row retention pruned meanwhile, an unnamed
  outside source. Chat, a failed step, a compaction and a note flush all
  carry it.

  A scripted child stops at `{:probe, self()}`, so the test can grow its
  ledger in its own attempt (`Opus.Ledger.join/3`, as a disclosed field
  would) before it answers.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Source
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @http "catalyst:local.http"
  @files "catalyst:local.files"
  @url "https://news.example/today"
  @window 40_000
  @full 21_000

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The test's storage is the tree of an athanor minted for it alone; it
    # is removed, and nothing else, when the test ends.
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

    # The loops' work stops before the tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, @http, @files])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread, actor: Sanctum.Context.actor(ctx)}
  end

  # ---------------------------------------------------------------------------
  # Seeds
  # ---------------------------------------------------------------------------

  describe "a child of the turn's root is seeded with its step's turn as it stands" do
    test "a source the turn read after its root was admitted reaches the next model and hand children",
         %{ctx: ctx, thread: thread, actor: actor} do
      {:ok, _} = Aqua.Notes.pin(ctx, "about-us", "We are planning a trip.")

      script!([
        calls([get("g1")]),
        %{"body" => "Fares rise"},
        calls([read("f1")]),
        %{"lines" => ["a line"]},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua read the news, then the file")
      assert :completed = run!(ctx, turn)

      [first, second, _third] = model_steps(ctx, turn)
      host = Source.outside("news.example")

      # The first model step opened with the pinned page, after the root's
      # admission: its child holds it.
      assert Source.new(:pinned) in ledger!(actor, first)
      # The news the HTTP hand read joined the turn when its step closed:
      # the next model child and the next hand child hold it.
      assert host in ledger!(actor, second)
      assert host in ledger!(actor, step!(ctx, turn, "f1"))
      refute host in ledger!(actor, first)
    end

    test "a source a clone's turn read reaches the clone's next model and hand children",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([
        calls([{"r1", "planner", %{"task" => "look into data/x"}}]),
        calls([read("p1")]),
        %{"lines" => ["a line"]},
        calls([{"p2", "files", %{"action" => "list", "path" => "data"}}]),
        %{"entries" => []},
        reply("found it"),
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua plan it")
      assert :completed = run!(ctx, turn)

      [clone] =
        Arca.Repo.all(from(t in Arca.Schemas.Turn, where: t.parent_turn_id == ^turn.id))

      {:ok, clone} = Tape.turn(ctx, clone.id)
      assert clone.root_execution_id == turn_row(ctx, turn).root_execution_id
      files = Source.new(:files_by_grant)

      [first, second, _third] = model_steps(ctx, clone)
      refute files in ledger!(actor, first)
      assert files in ledger!(actor, second)
      assert files in ledger!(actor, step!(ctx, clone, "p2"))
    end

    test "the capability probe, under no step, is seeded with every turn on the root",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([
        calls([get("g1")]),
        %{"body" => "Fares rise"},
        calls([keep("k1", "fares", "they rise")]),
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua read and keep")
      assert {:paused, :approval} = run!(ctx, turn)
      at_pause = sources(ctx, turn)
      assert Source.outside("news.example") in at_pause

      # The model's description is asked again when the turn resumes, as a
      # child of the root under no step.
      :ok = Arca.Cache.delete_match({:model_caps, ctx.athanor_id, :_, :_, :_})
      approve!(ctx, turn)
      assert :completed = resume!(ctx, turn)

      %{execution_id: probe} =
        ScriptedWorker.calls()
        |> Enum.filter(&(&1.input["operation"] == "describe"))
        |> List.last()

      assert {:ok, %{parent_execution_id: root}} = row(actor, probe)
      assert root == turn_row(ctx, turn).root_execution_id
      assert {:ok, ^at_pause} = Arca.Execution.sources(actor, probe)
    end
  end

  # ---------------------------------------------------------------------------
  # The model boundary
  # ---------------------------------------------------------------------------

  describe "a model child's ledger joins its turn when its step closes" do
    test "a chat step's, by its completion result", %{ctx: ctx, thread: thread} do
      script!([{:probe, self()}, reply("hello")])
      turn = accept!(ctx, thread, "@aqua hello")
      {result, probed} = probed_run(ctx, turn, &disclose!(ctx, &1))

      assert result == :completed
      assert [%{child_execution_id: ^probed}] = model_steps(ctx, turn)
      assert Source.new(:vault_disclosed) in sources(ctx, turn)
    end

    test "a failed step's, from its row, and a refused one's, by its result",
         %{ctx: ctx, thread: thread} do
      script!([
        {:probe, self()},
        {:error, "the model failed on what it read"},
        {:probe, self()},
        {:refuse, %{"type" => "invalid_request", "message" => "refused on what it read"}}
      ])

      failed = accept!(ctx, thread, "@aqua hello")
      {result, _probed} = probed_run(ctx, failed, &disclose!(ctx, &1))
      assert {:failed, "the model failed on what it read"} = result
      assert Source.new(:vault_disclosed) in sources(ctx, failed)

      refused = accept!(ctx, thread, "@aqua hello again")
      {result, _probed} = probed_run(ctx, refused, &disclose!(ctx, &1))
      assert {:failed, "refused on what it read"} = result
      assert Source.new(:vault_disclosed) in sources(ctx, refused)
    end

    test "a compaction's, before its summary is committed", %{ctx: ctx, thread: thread} do
      script!(
        [
          response([get("g1")], nil, @full),
          %{"body" => "Fares rise"},
          {:probe, self()},
          reply("the story so far"),
          reply("Fares rise.")
        ],
        window: @window
      )

      turn = accept_large!(ctx, thread)
      {result, probed} = probed_run(ctx, turn, &disclose!(ctx, &1))

      assert result == :completed
      assert %{child_execution_id: ^probed} = purpose!(ctx, turn, "compaction")
      assert [_compaction] = for(%{kind: "compaction"} = row <- rows(ctx, thread), do: row)
      assert Source.new(:vault_disclosed) in sources(ctx, turn)
    end

    test "a note flush's, before the notes it keeps", %{ctx: ctx, thread: thread} do
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread.id,
          agent_name: "aqua",
          tool: "notes",
          action: "keep",
          sources: []
        })

      script!(
        [
          response([read("f1")], nil, @full),
          %{"lines" => ["a line"]},
          {:probe, self()},
          response([keep("n1", "plan", "remember the line")], nil, @full),
          reply("the story so far"),
          reply("done")
        ],
        window: @window
      )

      turn = accept_large!(ctx, thread)
      {result, probed} = probed_run(ctx, turn, &disclose!(ctx, &1))

      assert result == :completed
      assert %{child_execution_id: ^probed} = purpose!(ctx, turn, "flush")
      assert %{outcome: "ok"} = step!(ctx, turn, "n1")
      assert Source.new(:vault_disclosed) in sources(ctx, turn)
    end
  end

  describe "a hand's child's ledger joins its turn when its step closes" do
    test "by its completion result, and from its row when it fails",
         %{ctx: ctx, thread: thread} do
      script!([
        calls([get("g1")]),
        {:probe, self()},
        %{"body" => "Fares rise"},
        reply("read it"),
        calls([get("g2")]),
        {:probe, self()},
        {:error, "the fetch failed on what it read"},
        reply("could not read it")
      ])

      read = accept!(ctx, thread, "@aqua read the news")
      {result, probed} = probed_run(ctx, read, &disclose!(ctx, &1))
      assert result == :completed
      assert %{child_execution_id: ^probed, outcome: "ok"} = step!(ctx, read, "g1")
      assert Source.new(:vault_disclosed) in sources(ctx, read)

      failed = accept!(ctx, thread, "@aqua read it again")
      {result, probed} = probed_run(ctx, failed, &disclose!(ctx, &1))
      assert result == :completed
      assert %{child_execution_id: ^probed, outcome: "error"} = step!(ctx, failed, "g2")
      assert Source.new(:vault_disclosed) in sources(ctx, failed)
    end
  end

  # ---------------------------------------------------------------------------
  # A child row retention pruned before its step closed
  # ---------------------------------------------------------------------------

  describe "a terminal child pruned while its turn still runs" do
    test "a failed model child whose row is gone before the loop reads it joins an unnamed " <>
           "outside source before its failure's text is written",
         %{ctx: ctx, thread: thread, actor: actor} do
      sentinel = "the model failed on vault value LEDGER-SENTINEL-7f3"
      script!([{:probe, self()}, {:error, sentinel}])
      turn = accept!(ctx, thread, "@aqua hello")

      {result, probed} =
        probed_run(ctx, turn, fn child ->
          disclose!(ctx, child)
          hold_waiter!(child)
        end)

      # The loop's worker is held after the child's terminal write and
      # before the loop reads its row; retention prunes the row meanwhile.
      prune!(actor, probed, "failed")
      release_waiter!(probed)

      # The failure's text reaches the thread only once the turn holds the
      # unnamed outside source the gone row stands for.
      assert_receive %ThreadEvent{
                       kind: :message,
                       data: %{
                         kind: "system",
                         content: "The model could not be reached: " <> said
                       }
                     },
                     30_000

      assert said == sentinel
      assert Source.outside(nil) in sources(ctx, turn)

      assert {:failed, ^sentinel} = await!(result)
      assert Source.outside(nil) in sources(ctx, turn)
      refute Source.new(:vault_disclosed) in sources(ctx, turn)
    end

    test "a completed model child carries its ledger in its result, so a row pruned before the " <>
           "step closes is never read",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([{:probe, self()}, reply("hello")])
      turn = accept!(ctx, thread, "@aqua hello")

      {result, probed} =
        probed_run(ctx, turn, fn child ->
          disclose!(ctx, child)
          hold_waiter!(child)
        end)

      prune!(actor, probed, "completed")
      release_waiter!(probed)

      assert :completed = await!(result)
      turn_sources = sources(ctx, turn)
      assert Source.new(:vault_disclosed) in turn_sources
      # No row was read for it: a read would have found none and joined
      # an unnamed outside source.
      refute Source.outside(nil) in turn_sources
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp script!(items, opts \\ []),
    do:
      start_supervised!(
        {ScriptedWorker, Keyword.merge([ref: [@model, @http, @files], script: items], opts)}
      )

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  # A message past the window's fill: once a round follows it, it is older
  # than the compaction boundary.
  defp accept_large!(ctx, thread),
    do: accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000))

  defp run!(ctx, turn),
    do: Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

  defp resume!(ctx, turn),
    do:
      Task.await(
        Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end),
        60_000
      )

  # The turn run until its scripted child stops at its probe, `on_probe`
  # run with the child's execution id, and the child let go. Answers the
  # loop's result — awaited, unless `on_probe` held the child's waiter,
  # in which case the task — and the child's id.
  defp probed_run(ctx, turn, on_probe) do
    task = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
    assert_receive {:scripted_probe, runner, child}, 30_000
    Process.put({:runner, child}, runner)
    held? = on_probe.(child) == :held
    send(runner, :continue)
    {if(held?, do: task, else: Task.await(task, 60_000)), child}
  end

  defp await!(%Task{} = task), do: Task.await(task, 60_000)

  # The child reads a disclosed vault value in its own attempt.
  defp disclose!(ctx, child),
    do: :ok = Opus.Ledger.join(Sanctum.Context.actor(ctx), child, [Source.new(:vault_disclosed)])

  # The process waiting on the child — the loop's worker, registered under
  # the child's id — stops before the child answers, so the child's
  # terminal write lands and its answer waits in the worker's mailbox. The
  # resume is registered first, so a test that fails holds nothing.
  defp hold_waiter!(child) do
    [{waiter, _}] = Registry.lookup(Opus.Registry, child)
    on_exit(fn -> if Process.alive?(waiter), do: :erlang.resume_process(waiter) end)
    true = :erlang.suspend_process(waiter)
    Process.put({:held, child}, waiter)
    :held
  end

  defp release_waiter!(child), do: true = :erlang.resume_process(Process.get({:held, child}))

  # The child's row reaches its terminal `status` and its runner, answered
  # once the child's attempt has closed, has ended; then execution
  # retention prunes the row while the turn's root still runs: the newest
  # row is kept, so the child is made the oldest first.
  defp prune!(actor, child, status) do
    runner = Process.get({:runner, child})

    Prima.Test.Wait.wait_until(
      fn ->
        match?({:ok, %{status: ^status}}, row(actor, child)) and not Process.alive?(runner)
      end,
      30_000,
      "#{child} written #{status} and its attempt closed"
    )

    {1, _} =
      Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^child),
        set: [started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
      )

    assert {:ok, pruned} = Arca.Retention.cleanup(actor, "executions", value: 1)
    assert pruned >= 1
    assert row(actor, child) == :none
  end

  defp row(actor, id) do
    case Arca.Repo.one(
           from(e in Arca.Schemas.Execution,
             where: e.athanor_id == ^actor.athanor_id and e.id == ^id,
             select: %{status: e.status, parent_execution_id: e.parent_execution_id}
           )
         ) do
      nil -> :none
      found -> {:ok, found}
    end
  end

  defp ledger!(actor, %{child_execution_id: id}) when is_binary(id) do
    {:ok, ledger} = Arca.Execution.sources(actor, id)
    ledger
  end

  defp approve!(ctx, turn) do
    {:ok, [approval]} = Tape.pending_approvals(ctx, turn_row(ctx, turn))

    assert {:ok, %{decision: "approved"}} =
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved})
  end

  defp turn_row(ctx, turn) do
    {:ok, row} = Tape.turn(ctx, turn.id)
    row
  end

  defp sources(ctx, turn), do: Source.decode(turn_row(ctx, turn).sources)

  defp model_steps(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    for %{kind: "model"} = step <- steps, do: step
  end

  defp purpose!(ctx, turn, purpose) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &(&1.purpose == purpose)) || flunk("no #{purpose} step")
  end

  # The step of one call, by the id its model gave it.
  defp step!(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)

    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id)) ||
      flunk("no step for #{call_id}")
  end

  defp rows(ctx, thread), do: Threads.messages(Sanctum.Context.actor(ctx), thread.id)

  defp get(id), do: {id, "http", %{"action" => "get", "url" => @url}}
  defp read(id), do: {id, "files", %{"action" => "read", "path" => "data/x"}}

  defp keep(id, name, content),
    do: {id, "notes", %{"action" => "keep", "name" => name, "content" => content}}

  defp calls(blocks), do: response(blocks, nil, 10)

  defp response(blocks, text, input_tokens) do
    content =
      if(text, do: [%{"type" => "text", "text" => text}], else: []) ++
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end)

    %{
      "content" => content,
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => input_tokens, "output_tokens" => 8}
    }
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }
end
