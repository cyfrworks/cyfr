# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.ChildReadThreadsTest do
  @moduledoc """
  A turn and the read threads of the children it runs, through the real
  loop with a scripted model and scripted hands.

  A child of the turn's root is seeded with its own step's turn as it
  stands when the child is admitted — a thread the turn read after its
  root was admitted included — and the capability probe, which runs under
  no step, with every turn on the root.

  What a model or hand child read joins its turn when its step closes,
  before its answer is used, by the first carrier that holds it — its
  completion result, else its row; a row retention pruned meanwhile adds
  none. Chat, a failed step, a compaction and a note flush all carry it.

  A scripted child stops at `{:probe, self()}`, so the test can grow its
  read threads in its own attempt (`Arca.Execution.join_threads/3`, as a
  read of another thread's posts would) before it answers.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Bus.ThreadEvent
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @http "catalyst:local.http"
  @files "catalyst:local.files"
  @url "https://news.example/today"
  @window 40_000
  @full 21_000
  # The thread whose posts a probed child reads in its own attempt.
  @read "thr_read_by_child"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    # The test's storage is the tree of an athanor minted for it alone; it
    # is removed, and nothing else, when the test ends.
    ctx = ScriptedWorker.athanor!(Sanctum.TestContext.local(:prism))
    segments = Arca.Storage.physical_segments(Sanctum.Context.actor(ctx), [])
    tree = Path.join([Application.fetch_env!(:arca, :base_path) | segments])
    refute File.exists?(tree), "#{ctx.athanor_id}'s tree is left from another test"
    on_exit(fn -> File.rm_rf!(tree) end)
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))

    # The loops' work stops before the tree is removed and the seed tree restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model, @http, @files])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    :ok = Aqua.Runner.subscribe(thread.id, ctx.athanor_id)
    {:ok, ctx: ctx, thread: thread, actor: Sanctum.Context.actor(ctx)}
  end

  # ---------------------------------------------------------------------------
  # Seeds
  # ---------------------------------------------------------------------------

  describe "a child of the turn's root is seeded with its step's turn as it stands" do
    test "a thread the turn read after its root was admitted reaches the next model and hand " <>
           "children",
         %{ctx: ctx, thread: thread, actor: actor} do
      work = workspace!(ctx, "Fares")
      report!(ctx, thread, work)

      script!([
        calls([get("g1")]),
        {:probe, self()},
        %{"body" => "Fares rise"},
        calls([read("f1")]),
        %{"lines" => ["a line"]},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua read the news, then the file")
      {result, probed} = probed_run(ctx, turn, &reads!(ctx, &1))
      assert result == :completed
      assert %{child_execution_id: ^probed} = step!(ctx, turn, "g1")

      [first, second, _third] = model_steps(ctx, turn)

      # The first model step opened with the workspace thread its rows
      # carry, after the root's admission: its child holds it.
      assert read_threads!(actor, first) == [work.id]
      # The thread the HTTP hand's child read joined the turn when its
      # step closed: the next model child and the next hand child hold it.
      assert read_threads!(actor, second) == Enum.sort([@read, work.id])
      assert read_threads!(actor, step!(ctx, turn, "f1")) == Enum.sort([@read, work.id])
    end

    test "the capability probe, under no step, is seeded with every turn on the root",
         %{ctx: ctx, thread: thread, actor: actor} do
      # The second read's child dies before it answers: the turn stops on
      # the unknown outcome, having read the thread the first one read.
      script!([
        calls([get("g1")]),
        {:probe, self()},
        %{"body" => "Fares rise"},
        calls([get("g2")]),
        {:crash, :before_response},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua read twice")
      assert {{:paused, :uncertain}, _probed} = probed_run(ctx, turn, &reads!(ctx, &1))
      at_pause = read_threads(ctx, turn)
      assert at_pause == [@read]

      # The model's description is asked again when the turn resumes, as a
      # child of the root under no step.
      :ok = Arca.Cache.delete_match({:model_caps, ctx.athanor_id, :_, :_, :_})
      assert :completed = resume!(ctx, turn)

      %{execution_id: probe} =
        ScriptedWorker.calls()
        |> Enum.filter(&(&1.input["operation"] == "describe"))
        |> List.last()

      assert {:ok, %{parent_execution_id: root}} = row(actor, probe)
      assert root == turn_row(ctx, turn).root_execution_id
      assert {:ok, ^at_pause} = Arca.Execution.read_threads(actor, probe)
    end
  end

  # ---------------------------------------------------------------------------
  # The model boundary
  # ---------------------------------------------------------------------------

  describe "a model child's read threads join its turn when its step closes" do
    test "a chat step's, by its completion result", %{ctx: ctx, thread: thread} do
      script!([{:probe, self()}, reply("hello")])
      turn = accept!(ctx, thread, "@aqua hello")
      {result, probed} = probed_run(ctx, turn, &reads!(ctx, &1))

      assert result == :completed
      assert [%{child_execution_id: ^probed}] = model_steps(ctx, turn)
      assert read_threads(ctx, turn) == [@read]
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
      {result, _probed} = probed_run(ctx, failed, &reads!(ctx, &1))
      assert {:failed, "the model failed on what it read"} = result
      assert read_threads(ctx, failed) == [@read]

      refused = accept!(ctx, thread, "@aqua hello again")
      {result, _probed} = probed_run(ctx, refused, &reads!(ctx, &1))
      assert {:failed, "refused on what it read"} = result
      assert read_threads(ctx, refused) == [@read]
    end

    test "a compaction's, before its summary is committed", %{ctx: ctx, thread: thread} do
      # The note flush ahead of the compaction keeps nothing, and the window
      # it reports is still full.
      script!(
        [
          response([get("g1")], nil, @full),
          %{"body" => "Fares rise"},
          reply("nothing to keep", @full),
          {:probe, self()},
          reply("the story so far"),
          reply("Fares rise.")
        ],
        window: @window
      )

      turn = accept_large!(ctx, thread)
      {result, probed} = probed_run(ctx, turn, &reads!(ctx, &1))

      assert result == :completed
      assert %{child_execution_id: ^probed} = purpose!(ctx, turn, "compaction")
      assert [_compaction] = for(%{kind: "compaction"} = row <- rows(ctx, thread), do: row)
      assert read_threads(ctx, turn) == [@read]
    end

    test "a note flush's, before the notes it keeps", %{ctx: ctx, thread: thread} do
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
      {result, probed} = probed_run(ctx, turn, &reads!(ctx, &1))

      assert result == :completed
      assert %{child_execution_id: ^probed} = purpose!(ctx, turn, "flush")
      assert %{outcome: "ok"} = step!(ctx, turn, "n1")
      assert read_threads(ctx, turn) == [@read]
    end
  end

  describe "a hand's child's read threads join its turn when its step closes" do
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
      {result, probed} = probed_run(ctx, read, &reads!(ctx, &1))
      assert result == :completed
      assert %{child_execution_id: ^probed, outcome: "ok"} = step!(ctx, read, "g1")
      assert read_threads(ctx, read) == [@read]

      failed = accept!(ctx, thread, "@aqua read it again")
      {result, probed} = probed_run(ctx, failed, &reads!(ctx, &1))
      assert result == :completed
      assert %{child_execution_id: ^probed, outcome: "error"} = step!(ctx, failed, "g2")
      assert read_threads(ctx, failed) == [@read]
    end
  end

  # ---------------------------------------------------------------------------
  # A child row retention pruned before its step closed
  # ---------------------------------------------------------------------------

  describe "a terminal child pruned while its turn still runs" do
    test "a failed model child whose row is gone before the loop reads it adds no read thread, " <>
           "and its failure's text is written",
         %{ctx: ctx, thread: thread, actor: actor} do
      sentinel = "the model failed on READ-SENTINEL-7f3"
      script!([{:probe, self()}, {:error, sentinel}])
      turn = accept!(ctx, thread, "@aqua hello")

      {result, probed} =
        probed_run(ctx, turn, fn child ->
          reads!(ctx, child)
          hold_waiter!(child)
        end)

      # The loop's worker is held after the child's terminal write and
      # before the loop reads its row; retention prunes the row meanwhile.
      try do
        prune!(actor, probed, "failed")
      after
        release_waiter!(probed)
      end

      assert_receive %ThreadEvent{
                       kind: :message,
                       data: %{
                         kind: "system",
                         content: "The model could not be reached: " <> said
                       }
                     },
                     30_000

      assert said == sentinel
      assert {:failed, ^sentinel} = await!(result)
      assert read_threads(ctx, turn) == []
    end

    test "a completed model child carries its read threads in its result, so a row pruned " <>
           "before the step closes is never read",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([{:probe, self()}, reply("hello")])
      turn = accept!(ctx, thread, "@aqua hello")

      {result, probed} =
        probed_run(ctx, turn, fn child ->
          reads!(ctx, child)
          hold_waiter!(child)
        end)

      try do
        prune!(actor, probed, "completed")
      after
        release_waiter!(probed)
      end

      # No row was read for it: a read would have found none, and joined
      # nothing.
      assert :completed = await!(result)
      assert read_threads(ctx, turn) == [@read]
    end
  end

  describe "a child whose waiter is gone, or whose row is gone at its terminal write" do
    test "a dead hand waiter's step joins the completed child's persisted read threads",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([
        calls([read("dead-waiter")]),
        {:probe, self()},
        {:crash, :after_persist},
        %{"lines" => ["READ-DERIVED-SENTINEL"]},
        reply("done")
      ])

      turn = accept!(ctx, thread, "@aqua read the file")

      {result, child} =
        probed_run(ctx, turn, fn id ->
          :ok = Arca.Execution.join_threads(actor, id, ["thr_crash_only"])
        end)

      assert result == :completed
      assert Arca.Execution.read_threads(actor, child) == {:ok, ["thr_crash_only"]}
      assert read_threads(ctx, turn) == ["thr_crash_only"]
    end

    test "the completion result carries the read threads the terminal write itself returned, " <>
           "so retention at the terminal telemetry takes nothing back",
         %{ctx: ctx, thread: thread, actor: actor} do
      script!([{:probe, self()}, reply("READ-DERIVED-SENTINEL")])
      turn = accept!(ctx, thread, "@aqua hello")
      task = Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)
      assert_receive {:scripted_probe, runner, child}, 30_000
      :ok = Arca.Execution.join_threads(actor, child, ["thr_terminal_only"])
      owner = self()
      handler = {__MODULE__, :terminal_probe, make_ref()}
      on_exit(fn -> :telemetry.detach(handler) end)

      :ok =
        :telemetry.attach(
          handler,
          [:cyfr, :opus, :execute, :stop],
          fn _event, _measurements, metadata, _config ->
            if metadata.execution_id == child do
              send(owner, {:at_terminal, self(), child})

              receive do
                :terminal_continue -> :ok
              after
                15_000 -> :ok
              end
            end
          end,
          nil
        )

      send(runner, :continue)
      assert_receive {:at_terminal, completer, ^child}, 30_000
      assert {:ok, %{status: "completed"}} = row(actor, child)

      {1, _} =
        Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^child),
          set: [started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
        )

      assert {:ok, pruned} = Arca.Retention.cleanup(actor, "executions", value: 1)
      assert pruned >= 1
      assert row(actor, child) == :none
      send(completer, :terminal_continue)
      assert Task.await(task, 60_000) == :completed
      assert read_threads(ctx, turn) == ["thr_terminal_only"]
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
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    turn
  end

  # A message past the window's fill: once a round follows it, it is older
  # than the compaction boundary.
  defp accept_large!(ctx, thread),
    do: accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000))

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

  # The child reads the posts of the thread `@read` in its own attempt.
  defp reads!(ctx, child),
    do: :ok = Arca.Execution.join_threads(Sanctum.Context.actor(ctx), child, [@read])

  # A workspace thread of the test's athanor.
  defp workspace!(ctx, title) do
    %Arca.Schemas.Thread{}
    |> Arca.Schemas.Thread.changeset(%{
      id: Prima.UUID7.generate_id("thread"),
      athanor_id: ctx.athanor_id,
      kind: "workspace",
      workspace_state: "open",
      title: title,
      created_by: ctx.user_id
    })
    |> Arca.Repo.insert!()
  end

  # A report of `work` landed on `thread`, whose turns' requests carry it.
  defp report!(ctx, thread, work) do
    {:ok, _row} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: Prima.Author.agent(),
        sent_by: "aqua",
        kind: "report",
        workspace_id: work.id,
        content: "Fares: done.",
        payload: %{"workspace" => work.id, "title" => work.title, "outcome" => "done"}
      })
  end

  # The process waiting on the child — the loop's worker, registered under
  # the child's id — stops before the child answers, so the child's
  # terminal write lands and its answer waits in the worker's mailbox. Only
  # this process can resume it, so the test releases it in an `after`: a
  # test that fails ends the loop, and the worker with it, through its link
  # before the VM lifts the suspension.
  defp hold_waiter!(child) do
    [{waiter, _}] = Registry.lookup(Opus.Registry, child)
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

  defp read_threads!(actor, %{child_execution_id: id}) when is_binary(id) do
    {:ok, read} = Arca.Execution.read_threads(actor, id)
    read
  end

  defp turn_row(ctx, turn) do
    {:ok, row} = Tape.turn(ctx, turn.id)
    row
  end

  defp read_threads(ctx, turn), do: Threads.threads_of(turn_row(ctx, turn).read_threads)

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

  defp reply(text, input_tokens \\ 10),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => input_tokens, "output_tokens" => 5}
    }
end
