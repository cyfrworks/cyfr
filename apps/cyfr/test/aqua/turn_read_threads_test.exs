# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TurnReadThreadsTest do
  @moduledoc """
  A turn's read threads (`turns.read_threads`): the ids of the threads
  whose posts it came to hold, grown through the real loop by every way
  those posts reach it — a read or a search of a thread, an earlier turn
  of its own thread whose rows it sends, a report a
  workspace thread delivered, another turn's reply, a file a launched app
  wrote, the answer of a launched app that read it and a listing of the
  turn's own runs, whose errors may quote them — and what deleting one of
  them undoes: each result that carried its posts is blanked, and each
  thread with a turn that read it loses the compactions written since and
  its brain session. A file read and a run's logs, which declare the
  threads they carry too, are refused to a turn.

  The model and a launched app are scripted, and so are the HTTP and
  files hands unless a test runs the files catalyst on the runtime;
  everything else — the loop, the gate and the crew's delivery — is real.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.{Crew, Tape}
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @http "catalyst:local.http"
  @files "catalyst:local.files"
  @model_id "scripted-small"
  @window 40_000
  @full 21_000

  setup %{conn: conn} do
    Arca.Cache.init()
    test_path = Path.join(System.tmp_dir!(), "read_threads_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)

    user = test_user()

    own = Sanctum.Test.People.athanor!(user.user_id)
    conn = log_in_user(conn, user, athanor_id: own.id)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(own)
    ctx = ready_athanor!(own.id, user.user_id)
    # The loops' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()
    ScriptedWorker.fresh_limits!(ctx, [@model, @http, @files])

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, conn: conn, ctx: ctx, own: own, thread: thread}
  end

  describe "how a turn reads" do
    test "a search that finds a post with a screenshot joins the threads its picture carries",
         %{ctx: ctx, thread: thread} do
      # The turn that took it read nothing: only the picture names the
      # thread its page was taken after.
      seen = workspace!(ctx, "Seen")
      first = running!(ctx, thread)
      file = %{"filename" => "screenshot.png", "media_type" => "image/png", "bytes" => "PNG"}
      {:ok, shot, _ref} = Aqua.Attachments.draft(ctx, first, file, [seen.id])

      lineage = %{
        "thread_id" => thread.id,
        "root_execution_id" => first.root_execution_id,
        "parent_execution_id" => first.root_execution_id,
        "attempt" => first.attempt
      }

      guest = Sanctum.Context.enter_guest(ctx)

      assert {:ok, %{files: 1}} =
               Aqua.Providers.Thread.handle(
                 "thread",
                 guest,
                 Map.merge(lineage, %{
                   "action" => "post",
                   "text" => "the moon tonight",
                   "screenshot" => shot
                 })
               )

      {:ok, _} = Tape.finish(ctx, first, "cancelled")

      # A turn of another thread finds the post, and joins the thread the
      # picture carries with the post's own.
      reader = running!(ctx, workspace!(ctx, "Elsewhere"))

      assert {:ok, %{count: 1}} =
               Aqua.Providers.Thread.handle("thread", guest, %{
                 "action" => "search",
                 "q" => "moon tonight",
                 "thread_id" => reader.thread_id,
                 "root_execution_id" => reader.root_execution_id
               })

      assert read_threads(ctx, reader) == Enum.sort([thread.id, seen.id])
    end

    test "the room excerpt is sent once, marked excluded, and adds no read thread",
         %{ctx: ctx, thread: thread} do
      # A shared thread the person sits in, beside their own thread.
      {:ok, beside} = Sanctum.SharedThreads.create(ctx.user_id, "Beside")
      {:ok, _} = Sanctum.SharedThreads.post(ctx.user_id, beside.id, "ROOM-ONLY-LINE")

      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "@aqua what did they say?"},
          turn: %{
            agent: "aqua",
            requested_by: ctx.user_id,
            model: @model_id,
            options: %{"room" => %{"shared_thread_id" => beside.id, "title" => "Beside"}}
          }
        })

      script!([
        calls([{"f1", "files", %{"action" => "list", "path" => "data"}}]),
        %{"entries" => []},
        reply("They said hello.")
      ])

      assert :completed = run(ctx, turn)
      [first, second] = chat_requests()
      assert Jason.encode!(first) =~ "ROOM-ONLY-LINE"
      refute Jason.encode!(second) =~ "ROOM-ONLY-LINE"

      [opened | _] = for %{kind: "model"} = s <- steps(ctx, turn), do: s
      assert opened.excluded =~ "room_excerpt"
      [_ | later] = for %{kind: "model"} = s <- steps(ctx, turn), do: s
      refute Enum.any?(later, fn s -> (s.excluded || "") =~ "room_excerpt" end)

      # Neither the excerpt nor the files list carried a thread's posts.
      assert read_threads(ctx, turn) == []
    end

    test "an earlier turn's read in the thread's history joins a new turn before any call",
         %{ctx: ctx, thread: thread} do
      gone = fares!(ctx)
      first = accept!(ctx, thread, "@aqua what do the fares say?")

      script!([
        calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}]),
        reply("They rise on Monday.")
      ])

      assert :completed = run(ctx, first)
      assert read_threads(ctx, first) == [gone.id]
      stop_script!()

      # The second turn calls nothing: what it read is what its rows carried.
      second = accept!(ctx, thread, "@aqua and now?")
      script!([reply("still the fares")])
      assert :completed = run(ctx, second)
      assert read_threads(ctx, second) == [gone.id]
      assert [] = for(%{kind: kind} = s <- steps(ctx, second), kind != "model", do: s)
    end

    test "a compaction summary carries its turn's read threads into the next turn",
         %{ctx: ctx, thread: thread} do
      gone = fares!(ctx)
      # The first turn reads the thread, then compacts its own older rows.
      first = accept_large!(ctx, thread)

      # The note flush ahead of the compaction keeps nothing, and the window
      # it reports is still full.
      script!([
        filling(calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}])),
        filling(reply("nothing to keep")),
        reply("the story so far"),
        reply("They rise on Monday.")
      ])

      assert :completed = run(ctx, first)
      assert %{turn_id: by} = ctx |> rows(thread) |> Enum.find(&(&1.kind == "compaction"))
      assert by == first.id
      assert read_threads(ctx, first) == [gone.id]
      stop_script!()

      second = accept!(ctx, thread, "@aqua and now?")
      script!([reply("still the fares")])
      assert :completed = run(ctx, second)
      assert read_threads(ctx, second) == [gone.id]
    end
  end

  # Two reads that declare the threads their answers carry, which a turn
  # cannot make: each is refused before its handler answers, so nothing
  # its declaration would name joins the turn.
  describe "a read a turn cannot make" do
    test "a file read is refused: the action is not reachable from a running chain",
         %{ctx: ctx, thread: daily} do
      actor = Sanctum.Context.actor(ctx)
      :ok = Arca.put(actor, ["data", "fares.txt"], "the fares rise", threads: ["thr_fares"])
      read = %{"action" => "read", "path" => "data/fares.txt"}

      # Read from outside a chain, its answer carries the file's thread.
      assert {:ok, %{read_threads: ["thr_fares"]}} =
               Arca.Providers.Files.handle("file", actor, read)

      soul!(ctx, %{"tools_add" => ["file.read"]})
      turn = accept!(ctx, daily, "@aqua read the fares file")

      script!([
        calls([{"r1", "file.read", %{"path" => "data/fares.txt"}}]),
        reply("I could not read it.")
      ])

      assert :completed = run(ctx, turn)
      assert %{outcome: "error"} = step(ctx, turn, "r1")

      # Refused at admission, by the action's plane.
      assert result(ctx, turn, "r1").content ==
               "Tool action 'file.read' is not reachable from a running chain"

      assert read_threads(ctx, turn) == []
    end

    test "a run's logs are refused: a call from inside a running component cannot use " <>
           "storage_read",
         %{ctx: ctx, thread: daily} do
      logged = started!(ctx, ["thr_fares"])
      actor = Sanctum.Context.actor(ctx)
      assert Arca.Execution.read_threads(actor, logged) == {:ok, ["thr_fares"]}
      turn = accept!(ctx, daily, "@aqua show that run's logs")

      script!([
        calls([{"g1", "execution.logs", %{"execution_id" => logged}}]),
        reply("I could not read them.")
      ])

      assert :completed = run(ctx, turn)
      assert %{outcome: "error"} = step(ctx, turn, "g1")

      assert result(ctx, turn, "g1").content ==
               "Error: Unauthorized: a call from inside a running component cannot use " <>
                 "'storage_read'"

      assert read_threads(ctx, turn) == []
    end
  end

  describe "a read of the athanor's threads, and forgetting it" do
    test "a search and a read join the threads they carry; deleting the thread they read blanks " <>
           "those results alone, deletes the reader's later compactions and clears its session",
         %{ctx: ctx, thread: daily} do
      actor = Sanctum.Context.actor(ctx)
      work = workspace!(ctx, "Fares")
      say!(ctx, work, "the fares rise on Monday")
      say!(ctx, daily, "call the plumber on Thursday")

      turn = accept!(ctx, daily, "@aqua what did we find about fares?")

      script!([
        calls([
          {"s1", "thread", %{"action" => "search", "q" => "fares rise"}},
          {"s2", "thread", %{"action" => "search", "q" => "plumber"}}
        ]),
        calls([{"e1", "thread", %{"action" => "events", "thread" => work.id}}]),
        reply("They rise on Monday.")
      ])

      assert :completed = run(ctx, turn)
      assert read_threads(ctx, turn) == Enum.sort([daily.id, work.id])

      read = result(ctx, turn, "s1")
      other = result(ctx, turn, "s2")
      opened = result(ctx, turn, "e1")
      assert read.content =~ "the fares rise on Monday"
      assert opened.content =~ "the fares rise on Monday"
      assert other.content =~ "plumber"

      # What the reader kept of the thread since it first read it.
      {:ok, summary} =
        Threads.append(actor, daily.id, %{
          author: "system",
          sent_by: "aqua",
          kind: "compaction",
          content: "they rise on Monday"
        })

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Thread, where: c.id == ^daily.id),
          set: [brain_session: "sess_fares"]
        )

      {:ok, %{brain_generation: generation}} = Threads.get(actor, daily.id)

      assert {:ok, _} = Tape.delete_thread(ctx, work.id)

      assert result(ctx, turn, "s1").content == Threads.forgotten_read()
      assert result(ctx, turn, "e1").content == Threads.forgotten_read()
      assert result(ctx, turn, "s2").content == other.content
      assert {:error, :not_found} = Threads.get_message(actor, summary.id)
      assert {:ok, %{brain_session: nil, brain_generation: raised}} = Threads.get(actor, daily.id)
      assert raised == generation + 1
    end

    test "deletion blanks a long events result even when its thread id was clipped",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Private research")
      for n <- 1..25, do: say!(ctx, work, "private-fact-#{n}: " <> String.duplicate("x", 12_000))
      turn = accept!(ctx, daily, "@aqua read that research")

      # A window the long answer fits, so no compaction summarizes it first.
      start_supervised!(
        {ScriptedWorker,
         ref: [@model, @http, @files],
         script: [
           calls([{"e1", "thread", %{"action" => "events", "thread" => work.id}}]),
           reply("Read it.")
         ],
         window: 1_000_000},
        id: :script
      )

      assert :completed = run(ctx, turn)
      read = result(ctx, turn, "e1")
      assert read.content =~ "private-fact-1"
      # The binding cut the answer, the thread's id with it.
      refute String.contains?(read.content, work.id)
      assert read_threads(ctx, turn) == [work.id]

      assert {:ok, _} = Tape.delete_thread(ctx, work.id)
      assert result(ctx, turn, "e1").content == Threads.forgotten_read()
    end

    test "a search answer that carried two threads is blanked whole when one of them is deleted",
         %{ctx: ctx, thread: daily} do
      gone = workspace!(ctx, "Fares, first")
      kept = workspace!(ctx, "Fares, second")
      say!(ctx, gone, "the fares rise on Monday")
      say!(ctx, kept, "the fares fall on Friday")
      turn = accept!(ctx, daily, "@aqua what about fares?")

      script!([
        calls([{"s1", "thread", %{"action" => "search", "q" => "the fares"}}]),
        reply("Up Monday, down Friday.")
      ])

      assert :completed = run(ctx, turn)
      read = result(ctx, turn, "s1")
      assert read.content =~ "rise on Monday" and read.content =~ "fall on Friday"

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)
      assert result(ctx, turn, "s1").content == Threads.forgotten_read()
      assert {:ok, _} = Threads.get(Sanctum.Context.actor(ctx), kept.id)
    end

    test "a thread deleted before a turn's read joins it is neither joined nor answered",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Gone first")
      turn = running!(ctx, daily)
      assert {:ok, _} = Tape.delete_thread(ctx, work.id)

      assert {:ok, %{threads: [standing], read_threads: joined}} =
               Tape.join_read(ctx, turn, [work.id, daily.id], [])

      assert standing == daily.id
      assert joined == [daily.id]
      assert read_threads(ctx, turn) == [daily.id]
    end

    test "a thread deleted after a turn's read joined it, before the read's step closed, stops " <>
           "that turn, and the read's result is never written",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Gone after")
      say!(ctx, work, "a secret of the thread")
      turn = running!(ctx, daily)
      step = read_step!(ctx, turn)

      assert {:ok, %{threads: [_]}} = Tape.join_read(ctx, turn, [work.id], [])
      assert {:ok, %{cancelled: [_ | _]}} = Tape.delete_thread(ctx, work.id)
      assert {:ok, %{status: "cancelled"}} = Tape.turn(ctx, turn.id)

      assert {:error, _} =
               Tape.close_step(ctx, turn, step, "ok", %{
                 result: %{content: "a secret of the thread", payload: %{}}
               })

      refute Enum.any?(rows(ctx, daily), &(&1.content == "a secret of the thread"))
    end

    test "a holder whose fence moved joins nothing", %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Fenced")
      turn = running!(ctx, daily)

      assert {:error, :superseded} =
               Tape.join_read(ctx, %{turn | fence: turn.fence + 1}, [work.id], [])

      assert read_threads(ctx, turn) == []
    end
  end

  # Each proof deletes `gone` and holds three things: before the deletion
  # the reading turn's row names exactly the threads it read, `gone` among
  # them; after it, the reader's result that carried `gone`'s posts holds
  # the deletion's sentence while a result of the same turn that did not
  # is untouched; and the reader was found, so its thread's compaction
  # since is gone and its brain session cleared.
  describe "deleting a thread, through each way its posts reach another turn" do
    test "a direct read: the turn read the thread's events", %{ctx: ctx, thread: daily} do
      gone = fares!(ctx)
      say!(ctx, daily, "call the plumber on Thursday")
      reader = accept!(ctx, daily, "@aqua what do the fares say?")

      script!([
        calls([
          {"e1", "thread", %{"action" => "events", "thread" => gone.id}},
          {"s1", "thread", %{"action" => "search", "q" => "plumber"}}
        ]),
        reply("They rise on Monday.")
      ])

      assert :completed = run(ctx, reader)
      assert read_threads(ctx, reader) == Enum.sort([daily.id, gone.id])

      read = result(ctx, reader, "e1")
      control = result(ctx, reader, "s1")
      assert read.content =~ "the fares rise on Monday"
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, daily)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "e1", read)
      assert result(ctx, reader, "s1") == control
      assert_forgotten(ctx, daily, kept)
    end

    test "a report: a workspace thread's turn read the thread and reported, and a daily turn " <>
           "searched the report",
         %{ctx: ctx} do
      gone = fares!(ctx)
      work = workspace!(ctx, "Fare table", "open")
      writer = accept!(ctx, work, "@aqua write up what the fares do")

      # The writer reads the thread and reports; the daily turn the
      # report's delivery opens answers it.
      script!([
        calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}]),
        calls([
          {"r1", "workspace",
           %{
             "action" => "report",
             "outcome" => "done",
             "summary" => "The fare table is written up."
           }}
        ]),
        reply("Reported."),
        reply("Noted.")
      ])

      assert :completed = run(ctx, writer)
      assert read_threads(ctx, writer) == [gone.id]

      assert %{} = Crew.drain_all()
      {:ok, today} = Aqua.Day.current(ctx)
      assert [%{turn_id: delivered}] = Enum.filter(rows(ctx, today), &(&1.kind == "report"))
      await_status(ctx, delivered, "completed")
      stop_script!()

      say!(ctx, today, "call the plumber on Thursday")
      reader = accept!(ctx, today, "@aqua is the write-up done?")

      script!([
        calls([
          {"s1", "thread", %{"action" => "search", "q" => "fare table"}},
          {"s2", "thread", %{"action" => "search", "q" => "plumber"}}
        ]),
        reply("It is written up.")
      ])

      assert :completed = run(ctx, reader)
      assert read_threads(ctx, reader) == Enum.sort([today.id, work.id, gone.id])

      read = result(ctx, reader, "s1")
      control = result(ctx, reader, "s2")
      assert read.content =~ "The fare table is written up."
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, today)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "s1", read)
      assert result(ctx, reader, "s2") == control
      assert_forgotten(ctx, today, kept)
    end

    test "a reader's words: another turn read the thread and replied, and the turn read that reply",
         %{ctx: ctx, thread: daily} do
      gone = fares!(ctx)
      asked = workspace!(ctx, "Asked")
      writer = accept!(ctx, asked, "@aqua what do the fares say?")

      script!([
        calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}]),
        reply("They rise on Monday, it says.")
      ])

      assert :completed = run(ctx, writer)
      assert read_threads(ctx, writer) == [gone.id]
      stop_script!()

      say!(ctx, daily, "call the plumber on Thursday")
      reader = accept!(ctx, daily, "@aqua what did the other thread find?")

      script!([
        calls([
          {"e1", "thread", %{"action" => "events", "thread" => asked.id}},
          {"s1", "thread", %{"action" => "search", "q" => "plumber"}}
        ]),
        reply("That they rise.")
      ])

      assert :completed = run(ctx, reader)
      assert read_threads(ctx, reader) == Enum.sort([daily.id, asked.id, gone.id])

      # What reached the reader of `gone` is the writer's words alone.
      read = result(ctx, reader, "e1")
      control = result(ctx, reader, "s1")
      assert read.content =~ "They rise on Monday, it says."
      refute read.content =~ "the fares rise on Monday"
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, daily)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "e1", read)
      assert result(ctx, reader, "s1") == control
      assert_forgotten(ctx, daily, kept)
    end

    test "a launched component's object: an app launched from a turn that read the thread wrote " <>
           "a file, and the turn read the file",
         %{ctx: ctx, thread: daily} do
      gone = fares!(ctx)
      %{launcher: launcher, root: root} = launched_writing!(ctx, gone, "data/fares.txt")
      assert read_threads(ctx, launcher) == [gone.id]
      assert Arca.Execution.read_threads(Sanctum.Context.actor(ctx), root) == {:ok, [gone.id]}

      say!(ctx, daily, "call the plumber on Thursday")
      reader = accept!(ctx, daily, "@aqua what is in the fares file?")

      # Only the model is scripted: the files hand reads on the runtime.
      script!(
        [
          calls([
            {"f1", "files.read", %{"path" => "data/fares.txt"}},
            {"s1", "thread", %{"action" => "search", "q" => "plumber"}}
          ]),
          reply("They rise on Monday.")
        ],
        [@model]
      )

      assert :completed = run(ctx, reader)
      assert read_threads(ctx, reader) == Enum.sort([daily.id, gone.id])

      read = result(ctx, reader, "f1")
      control = result(ctx, reader, "s1")
      assert read.content =~ "the fares rise on Monday"
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, daily)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "f1", read)
      assert result(ctx, reader, "s1") == control
      assert_forgotten(ctx, daily, kept)
    end

    test "a launched component's output: a turn launched an app whose run read the file an app " <>
           "launched from a turn that read the thread wrote, and the turn read its answer",
         %{ctx: ctx, thread: daily} do
      actor = Sanctum.Context.actor(ctx)
      gone = fares!(ctx)
      %{launcher: launcher, root: writer} = launched_writing!(ctx, gone, "data/fares.txt")
      assert read_threads(ctx, launcher) == [gone.id]
      assert Arca.Execution.read_threads(actor, writer) == {:ok, [gone.id]}

      reading = app!(ctx, ["read"])
      say!(ctx, daily, "call the plumber on Thursday")
      reader = accept!(ctx, daily, "@aqua run the app that reads the fares file")

      # The reader's turn read nothing of `gone` when it launched: only the
      # app's answer brings it.
      script!(
        [
          calls([{"c1", "execution.run", %{"reference" => reading <> ":1.0.0", "input" => %{}}}]),
          {:hold, self()},
          %{"read" => "the fares rise on Monday"},
          calls([{"s1", "thread", %{"action" => "search", "q" => "plumber"}}]),
          reply("It read that they rise.")
        ],
        [@model, reading]
      )

      root =
        run_holding_launch!(ctx, reader, fn held ->
          assert %{"ok" => %{"content" => _}} =
                   AttemptFixtures.call(held, "storage", %{
                     "action" => "read",
                     "path" => "data/fares.txt"
                   })
        end)

      assert Arca.Execution.read_threads(actor, root) == {:ok, [gone.id]}
      assert read_threads(ctx, reader) == Enum.sort([daily.id, gone.id])

      read = result(ctx, reader, "c1")
      control = result(ctx, reader, "s1")
      assert read.content =~ "the fares rise on Monday"
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, daily)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "c1", read)
      assert result(ctx, reader, "s1") == control
      assert_forgotten(ctx, daily, kept)
    end

    test "a listing of the turn's runs: a run of its chain failed quoting the thread, and the " <>
           "turn listed its runs",
         %{ctx: ctx, thread: daily} do
      gone = fares!(ctx)
      say!(ctx, daily, "call the plumber on Thursday")
      soul!(ctx, %{"tools_add" => ["execution.list"]})
      reader = accept!(ctx, daily, "@aqua fetch what the fares say, then list your runs")

      # The fetch, a hand child of the turn's root, fails quoting the
      # thread's words; the listing answers each run of the root's tree
      # with its error.
      failure = "the fetch failed on: the fares rise on Monday"

      script!([
        calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}]),
        calls([{"h1", "http", %{"action" => "get", "url" => "https://fares.example/today"}}]),
        {:error, failure},
        calls([{"l1", "execution.list", %{}}]),
        calls([{"s1", "thread", %{"action" => "search", "q" => "plumber"}}]),
        reply("The fetch failed.")
      ])

      assert :completed = run(ctx, reader)
      assert read_threads(ctx, reader) == Enum.sort([daily.id, gone.id])

      %{child_execution_id: failed} = step(ctx, reader, "h1")
      listed = result(ctx, reader, "l1")
      control = result(ctx, reader, "s1")
      %{"executions" => runs} = Jason.decode!(listed.content)

      assert [%{"status" => "failed", "error" => ^failure}] =
               Enum.filter(runs, &(&1["execution_id"] == failed))

      assert Threads.payload(listed)["threads"] == [gone.id]
      assert control.content =~ "plumber"
      kept = kept_since_reading!(ctx, daily)

      assert {:ok, _} = Tape.delete_thread(ctx, gone.id)

      assert_blanked(ctx, reader, "l1", listed)
      assert result(ctx, reader, "s1") == control
      assert_forgotten(ctx, daily, kept)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp script!(items, refs \\ [@model, @http, @files]) do
    start_supervised!(
      {ScriptedWorker, ref: refs, script: items, window: @window},
      id: :script
    )
  end

  defp stop_script!, do: stop_supervised!(:script)

  defp start_run(ctx, turn), do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end)

  defp run(ctx, turn), do: ctx |> start_run(turn) |> Task.await(120_000)

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}
      })

    turn
  end

  defp await_status(ctx, turn_id, status) do
    wait_until(
      fn -> match?({:ok, %{status: ^status}}, Tape.turn(ctx, turn_id)) end,
      45_000,
      "turn #{turn_id} to be #{status}"
    )
  end

  # A message past the window's fill: the first round has nothing older to
  # summarize; once a round follows it, the message is older than the
  # boundary.
  defp accept_large!(ctx, thread),
    do: accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000))

  # A model answer reporting the window as full.
  defp filling(answer), do: put_in(answer, ["usage", "input_tokens"], @full)

  # A running turn on a root of its own, as the loop holds one.
  defp running!(ctx, thread) do
    turn = accept!(ctx, thread, "@aqua launch it")

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_src_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_src",
        consent_id: "consent_src",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    turn
  end

  # A turn of a daily thread of its own that reads `gone`'s events and
  # then launches an app of the person's own through the loop
  # (`execution.run`, decided and run at once by `Aqua.Launch`,
  # which seeds the root with the turn's read threads), whose run writes
  # `path` through its own guest storage call before it answers. Answers
  # the launching turn and the root's id.
  defp launched_writing!(ctx, gone, path) do
    app = app!(ctx, ["write"])
    {:ok, launching} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    launcher = accept!(ctx, launching, "@aqua read the fares, then run the app")

    script!(
      [
        calls([{"e1", "thread", %{"action" => "events", "thread" => gone.id}}]),
        calls([{"c1", "execution.run", %{"reference" => app <> ":1.0.0", "input" => %{}}}]),
        {:hold, self()},
        %{"answered" => true},
        reply("Launched.")
      ],
      [@model, app]
    )

    write = %{
      "action" => "write",
      "path" => path,
      "content" => Base.encode64("the fares rise on Monday")
    }

    root =
      run_holding_launch!(ctx, launcher, fn held ->
        assert %{"ok" => %{"written" => true}} = AttemptFixtures.call(held, "storage", write)
      end)

    stop_script!()
    %{launcher: launcher, root: root}
  end

  # `turn` run through the loop while its script holds the run of the app
  # it launches once that run attached: `as_run` acts as the run, with the
  # host-call fields of its attempt, before it answers. Answers the
  # launched root's id.
  defp run_holding_launch!(ctx, turn, as_run) do
    task = start_run(ctx, turn)
    assert_receive {:scripted_probe, runner, root}, 60_000
    as_run.(AttemptFixtures.current!(ctx.athanor_id, root))
    send(runner, :continue)
    assert :completed = Task.await(task, 120_000)
    root
  end

  # An app of the person's own whose one ask is `actions` under `data/`,
  # granted through the consent walk as a person grants it.
  defp app!(ctx, actions) do
    name = "data-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "caps" => %{"storage" => %{"paths" => ["data/"], "actions" => actions}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:reagent), %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    app = "reagent:local." <> name
    decisions = %{ref: app, bindings: []}
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: app})
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _granted} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    app
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

  # A run of the athanor's own whose launch stamped it with `threads`,
  # admitted as it is.
  defp started!(ctx, threads) do
    id = Opus.Record.generate_id()

    record =
      Opus.Record.new(ctx, "formula:local.read-threads:0.1.0", %{},
        component_type: :formula,
        execution_id: id,
        launch: %{read_threads: threads, execution_id: id, agent: "aqua"}
      )

    :ok = Opus.Record.write_started(ctx, record)
    id
  end

  defp workspace!(ctx, title, state \\ "done") do
    %Arca.Schemas.Thread{}
    |> Arca.Schemas.Thread.changeset(%{
      id: Prima.UUID7.generate_id("thread"),
      athanor_id: ctx.athanor_id,
      kind: "workspace",
      workspace_state: state,
      title: title,
      created_by: ctx.user_id
    })
    |> Arca.Repo.insert!()
    |> Map.from_struct()
  end

  # The thread each deletion proof deletes: a workspace thread holding
  # one post of the person's.
  defp fares!(ctx) do
    gone = workspace!(ctx, "Fares")
    say!(ctx, gone, "the fares rise on Monday")
    gone
  end

  defp say!(ctx, thread, content) do
    {:ok, row} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: ctx.user_id,
        sent_by: "person",
        content: content
      })

    row
  end

  # What a reader's thread keeps after its turn read: a compaction, which
  # may summarize what was read, and a brain session, which may hold it.
  # Answers the compaction's id and the session's generation.
  defp kept_since_reading!(ctx, thread) do
    actor = Sanctum.Context.actor(ctx)

    {:ok, summary} =
      Threads.append(actor, thread.id, %{
        author: "system",
        sent_by: "aqua",
        kind: "compaction",
        content: "what the turn read"
      })

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Thread, where: c.id == ^thread.id),
        set: [brain_session: "sess_#{System.unique_integer([:positive])}"]
      )

    {:ok, %{brain_generation: generation}} = Threads.get(actor, thread.id)
    %{compaction: summary.id, generation: generation}
  end

  # The deletion found the reader: its thread's compaction is gone and
  # its session cleared, the generation raised by one.
  defp assert_forgotten(ctx, thread, kept) do
    actor = Sanctum.Context.actor(ctx)
    assert {:error, :not_found} = Threads.get_message(actor, kept.compaction)
    assert {:ok, %{brain_session: nil, brain_generation: raised}} = Threads.get(actor, thread.id)
    assert raised == kept.generation + 1
  end

  # The result row of `call_id` holds the deletion's sentence in place of
  # what it answered, and nothing else of `before`, the row read before
  # the deletion, changed.
  defp assert_blanked(ctx, turn, call_id, before) do
    blanked = result(ctx, turn, call_id)
    assert blanked.content == Threads.forgotten_read()
    assert %{blanked | content: before.content} == before
  end

  # The result row of one call, by the id its model gave it.
  defp result(ctx, turn, call_id) do
    %{result_message_id: id} = step(ctx, turn, call_id)
    {:ok, row} = Tape.message(ctx, id)
    row
  end

  # A dispatched `thread.search` step of a running turn, as the loop
  # leaves one while the call runs.
  defp read_step!(ctx, turn) do
    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "r1",
            name: "thread",
            tool: "thread",
            action: "search",
            arguments: %{"action" => "search", "q" => "secret"},
            kind: "read"
          }
        ]
      })

    {:ok, step} = Tape.mark_dispatched(ctx, turn, step)
    step
  end

  # The turn's read threads as its row stores them, the JSON list read
  # as it is, unsorted text included.
  defp read_threads(ctx, turn) do
    {:ok, %{read_threads: text}} = Tape.turn(ctx, turn.id)
    Jason.decode!(text)
  end

  defp steps(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    steps
  end

  # The step of one call, by the id its model gave it.
  defp step(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
  end

  defp rows(ctx, thread), do: Threads.messages(Sanctum.Context.actor(ctx), thread.id)

  defp calls(blocks) do
    %{
      "content" =>
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end),
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 8}
    }
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp chat_requests do
    for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
        do: params
  end
end
