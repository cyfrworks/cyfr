# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.BrowserTest do
  @moduledoc """
  Aqua's browser (`Opus.Browser`, through the `browser` tool's provider)
  against the scripted backends service, its driver a script that speaks
  the driver's framing (`Cyfr.Test.ScriptedDriver`): a window per thread,
  named from the proved turn's lineage; a caller the session owner does
  not prove reaches no window and starts nothing; the browser is the
  person's, so it outlasts the turn that started it; the person's
  setting refuses every action while it is off and closes the browser
  when it goes off; a response arrives whole in acknowledged chunks, is
  asked for again after a tail and never run twice, and one the driver no
  longer holds is refused. A page's call naming a put of its window,
  answered or still on its way, is held and announced on the bus with
  that put, answered once, and its end announced when it ends unanswered.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Aqua.Providers.Browser, as: Provider
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Bus.PageCall
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedDriver, as: Driver
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)

  # The driver's vectors (`Opus.Browser.Frame`): this case reads the plain
  # entry the host hands, which the driver loads in the image suite.
  @vectors Path.expand("../../../../tests/fixtures/browser_frames.json", __DIR__)
  @external_resource @vectors

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    test = self()
    answers = :ets.new(:answers, [:public])
    driver = Driver.start(test, answer: &answer(answers, &1))
    Scripted.set(fake, :terminal, driver)

    {ctx, user} = person!("browser-person")
    row = browser_row!(ctx)
    {turn, lineage} = turn!(ctx)

    :ok =
      Cyfr.Bus.subscribe(
        Sanctum.Context.actor(ctx),
        Cyfr.Bus.programs(Sanctum.Context.actor(ctx), ctx.user_id)
      )

    {:ok,
     fake: fake,
     controller: controller,
     driver: driver,
     answers: answers,
     ctx: ctx,
     user: user,
     row: row,
     turn: turn,
     lineage: lineage}
  end

  # What the scripted Chrome answers an operation: set per test, an
  # empty answer otherwise.
  defp answer(answers, %{"op" => op} = request) do
    case :ets.lookup(answers, op) do
      [{^op, answer}] when is_function(answer, 1) -> answer.(request)
      [{^op, answer}] -> answer
      [] -> {:ok, %{"url" => "https://example.com/", "title" => "Example"}}
    end
  end

  defp answers(%{answers: answers}, op, answer), do: :ets.insert(answers, {op, answer})

  defp person!(key) do
    {:ok, user} = Sanctum.Test.People.linked(%{id: key, provider: "local", verified: true})
    athanor = Sanctum.Test.People.athanor!(user)

    # A person on a page of theirs, as the console admits one.
    ctx = %{
      Sanctum.TestContext.local(:prism)
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    {ctx, user}
  end

  defp browser_row!(ctx, over \\ %{}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(
        Sanctum.Context.actor(ctx),
        Map.merge(
          %{
            cap: 0,
            name: Programs.Definition.browser_name(),
            transport: "program",
            mark: "driven",
            url: nil,
            home: "kept",
            memory_bytes: 1_073_741_824,
            config_json: Jason.encode!(%{"command" => "cyfr-browser", "env" => %{}})
          },
          over
        )
      )

    row
  end

  defp turn!(ctx, opts \\ []) do
    actor = Sanctum.Context.actor(ctx)

    thread =
      Keyword.get_lazy(opts, :thread, fn ->
        {:ok, thread} = Arca.Test.Days.thread(actor)
        thread
      end)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "look it up"},
        turn: %{
          agent: "aqua",
          requested_by: ctx.user_id,
          origin: Keyword.get(opts, :origin, :interactive)
        }
      })

    root = "exe_turn_root_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, status: "running"]
      )

    lineage = %{
      "thread_id" => thread.id,
      "root_execution_id" => root,
      "parent_execution_id" => root
    }

    {%{turn | root_execution_id: root, status: "running"}, lineage}
  end

  defp set_status(turn, status) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [status: status]
      )
  end

  defp guest(ctx), do: Sanctum.Context.enter_guest(ctx)

  # Put `args` into the caller's window: the id of the put's request, which
  # the driver names in the calls of its documents.
  defp put!(ctx, lineage, args) do
    assert {:ok, _} = call(ctx, lineage, "page", args)
    assert_receive {:driver, :put, _s, %{"id" => id}, _bytes}, 5_000
    id
  end

  defp call(ctx, lineage, action, args \\ %{}),
    do:
      Provider.handle("browser", guest(ctx), Map.merge(args, Map.put(lineage, "action", action)))

  defp holder(ctx, chrome \\ :person) do
    case Registry.lookup(Opus.Browser.Registry, {ctx.athanor_id, ctx.user_id, chrome}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp browser_sessions(ctx) do
    {:ok, sessions} = Programs.running(ctx)
    Enum.filter(sessions, &(&1.by == :browser))
  end

  # The session of the browser row `row` that runs now, or nil.
  defp session_of(ctx, row),
    do: Enum.find_value(browser_sessions(ctx), &(&1.row_id == row.id && &1.session))

  # A running turn of crew member planner, in its thread under workspace
  # thread `room`: its lineage.
  defp crew!(ctx, room) do
    {:ok, thread} = Threads.crew_thread(Sanctum.Context.actor(ctx), room, "planner")
    {turn, lineage} = turn!(ctx, thread: thread)

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [agent: "planner"]
      )

    lineage
  end

  # The names of the browser rows whose sessions run now, in order.
  defp running_rows(ctx), do: ctx |> browser_sessions() |> Enum.map(& &1.name) |> Enum.sort()

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for #{what}")

        # sleep-ok: poll interval of eventually's bounded wait (5 s)
        Process.sleep(10)
        eventually(check, what, deadline)

      truthy ->
        truthy
    end
  end

  defp refusal({:error, reason}), do: Sanctum.Refusals.render(reason)

  defp post(ctx, lineage, args) do
    Aqua.Providers.Thread.handle(
      "thread",
      guest(ctx),
      Map.merge(args, Map.put(lineage, "action", "post"))
    )
  end

  defp not_a_draft, do: Aqua.Providers.Thread.not_a_draft()

  # The turn holding `thread_id` among its read threads, as the loop
  # joins what a step read when the step closes.
  defp read_thread!(ctx, turn, thread_id) do
    {:ok, turn} = Aqua.Tape.turn(ctx, turn.id)
    :ok = Aqua.Tape.join_threads(ctx, turn, [thread_id])
  end

  defp attempt!(turn, attempt) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [attempt: attempt]
      )
  end

  defp posts(ctx, thread_id) do
    Sanctum.Context.actor(ctx)
    |> Threads.messages(thread_id)
    |> Enum.filter(&(&1.sent_by != "person"))
  end

  defp gone?(ctx, thread_id, id) do
    case Arca.list(Sanctum.Context.actor(ctx), Threads.blob_root(thread_id) ++ [id]) do
      {:ok, []} -> true
      {:error, :not_found} -> true
      _held -> false
    end
  end

  describe "a turn's actions" do
    test "run in the window of the turn's thread, named from the lineage, in one browser of the person's",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, %{url: "https://example.com/", title: "Example"}} =
               call(ctx, lineage, "open", %{"url" => "https://example.com/", "win" => "forged"})

      assert_receive {:driver, :req, session, %{"op" => "open", "win" => win, "args" => args}},
                     5_000

      assert win == lineage["thread_id"]
      assert args == %{"url" => "https://example.com/"}

      # A turn in another thread acts in its own window of the same browser.
      {_other, other} = turn!(ctx)
      assert {:ok, _} = call(ctx, other, "open", %{"url" => "https://example.org/"})
      assert_receive {:driver, :req, ^session, %{"op" => "open", "win" => other_win}}, 5_000
      assert other_win == other["thread_id"]

      assert [%{by: :browser, name: "aqua-browser"}] = browser_sessions(ctx)
      assert_received {:session, "open", _open, _fields}
      refute_received {:session, "open", _another, _fields}
    end

    test "click, type, key and close reach the driver with their own arguments",
         %{ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert {:ok, _} = call(ctx, lineage, "click", %{"ref" => "12"})

      assert_receive {:driver, :req, _s,
                      %{"op" => "click", "win" => ^win, "args" => %{"ref" => "12"}}}

      assert {:ok, _} = call(ctx, lineage, "type", %{"ref" => "12", "text" => "café"})

      assert_receive {:driver, :req, _s,
                      %{"op" => "type", "args" => %{"ref" => "12", "text" => "café"}}}

      assert {:ok, _} = call(ctx, lineage, "key", %{"key" => "Enter"})
      assert_receive {:driver, :req, _s, %{"op" => "key", "args" => %{"key" => "Enter"}}}

      assert {:ok, _} = call(ctx, lineage, "close")
      assert_receive {:driver, :req, _s, %{"op" => "close", "win" => ^win, "args" => %{}}}
    end

    test "read answers the page as text in parts, read on from the next an answer gave",
         %{ctx: ctx, lineage: lineage} = context do
      text = String.duplicate("é", 100_000)

      answers(
        context,
        "read",
        {:ok, %{"url" => "https://example.com/", "title" => "T", "text" => text}}
      )

      assert {:ok, %{text: first, from: 0, next: next, total: 100_000}} =
               call(ctx, lineage, "read")

      assert String.length(first) == 65_536 and next == 65_536

      assert {:ok, %{text: rest, from: ^next, next: 100_000}} =
               call(ctx, lineage, "read", %{"from" => next})

      assert first <> rest == text
    end

    test "a fifth window is refused with a sentence the person can act on, and a closed one frees its place",
         %{ctx: ctx, lineage: lineage} = context do
      others = for _ <- 1..3, do: elem(turn!(ctx), 1)

      for each <- [lineage | others],
          do: assert({:ok, _} = call(ctx, each, "open", %{"url" => "https://a.example/"}))

      {_fifth, fifth} = turn!(ctx)
      refused = call(ctx, fifth, "open", %{"url" => "https://a.example/"})
      assert refusal(refused) =~ "Aqua's browser has its 4 windows open"

      # Acting again in a thread that already has a window is no fifth.
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://b.example/"})

      answers(context, "close", {:ok, %{"closed" => true}})
      assert {:ok, %{closed: true}} = call(ctx, lineage, "close")
      assert {:ok, _} = call(ctx, fifth, "open", %{"url" => "https://a.example/"})
    end

    test "the driver's refusal is said in its own words",
         %{ctx: ctx, lineage: lineage} = context do
      answers(
        context,
        "open",
        {:error, "bad_url", "Only http and https addresses open in the browser."}
      )

      assert refusal(call(ctx, lineage, "open", %{"url" => "file:///etc/passwd"})) ==
               "Only http and https addresses open in the browser."
    end
  end

  describe "a screenshot" do
    test "is stored under a message of its own that is not sent, in the turn's thread",
         %{ctx: ctx, lineage: lineage} = context do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, "picture">>

      answers(
        context,
        "screenshot",
        {:ok, %{"png" => Base.encode64(png), "width" => 1280, "height" => 900}}
      )

      assert {:ok, %{message_id: message_id, attachment: ref, width: 1280, height: 900}} =
               call(ctx, lineage, "screenshot")

      assert %{"media_type" => "image/png", "filename" => "screenshot.png"} = ref
      thread_id = lineage["thread_id"]
      data = Base.encode64(png)

      assert [%{"data" => ^data, "media_type" => "image/png"}] =
               Aqua.Attachments.load(ctx, thread_id, [%{message_id: message_id, ref: ref}])

      # The message is not sent: no message holds that id.
      assert {:error, :not_found} =
               Arca.ThreadStorage.get_message(Sanctum.Context.actor(ctx), message_id)
    end

    test "answered after its turn was superseded stores nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} = context do
      answers(context, "screenshot", :hold)
      task = Task.async(fn -> call(ctx, lineage, "screenshot") end)
      assert_receive {:driver, :holding, _session, id}, 5_000

      set_status(turn, "cancelled")

      answers(
        context,
        "screenshot",
        {:ok, %{"png" => Base.encode64("png"), "width" => 1, "height" => 1}}
      )

      :ok = Driver.release(context.driver, id)

      assert refusal(Task.await(task, 10_000)) == "This turn no longer owns the work."

      assert {:ok, []} =
               Arca.list(
                 Sanctum.Context.actor(ctx),
                 Arca.ThreadStorage.blob_root(lineage["thread_id"])
               )
    end
  end

  describe "a posted screenshot" do
    setup context do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, "the moon">>

      answers(
        context,
        "screenshot",
        {:ok, %{"png" => Base.encode64(png), "width" => 1280, "height" => 900}}
      )

      {:ok, png: png}
    end

    test "is the post's own file, carrying the threads its turn read; the draft goes and posts once",
         %{ctx: ctx, turn: turn, lineage: lineage, png: png} do
      {:ok, read} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
      read_thread!(ctx, turn, read.id)
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      thread_id = lineage["thread_id"]

      assert {:ok, %{posted: post_id, thread: ^thread_id, files: 1}} =
               post(ctx, lineage, %{"text" => "The moon", "screenshot" => shot})

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), post_id)

      assert [%{"filename" => "screenshot.png", "media_type" => "image/png"} = ref] =
               Aqua.Attachments.refs_of(row)

      # The threads the turn had read when the screenshot was taken.
      assert Aqua.Attachments.copied_threads(ref) == [read.id]

      # Readable from the post alone.
      data = Base.encode64(png)

      assert [%{"data" => ^data}] =
               Aqua.Attachments.load(ctx, thread_id, [%{message_id: post_id, ref: ref}])

      # The draft's bytes went; the post kept its copy.
      assert gone?(ctx, thread_id, shot)
      assert post(ctx, lineage, %{"screenshot" => shot}) |> refusal() == not_a_draft()
      assert [_one] = posts(ctx, thread_id)
    end

    test "of a turn that read no thread carries none",
         %{ctx: ctx, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      {:ok, %{posted: post_id}} = post(ctx, lineage, %{"screenshot" => shot})
      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), post_id)
      [ref] = Aqua.Attachments.refs_of(row)
      assert Aqua.Attachments.copied_threads(ref) == []
    end

    test "is refused, in one sentence, to another turn, thread, person or athanor, and when it is not there",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      thread_id = lineage["thread_id"]

      # Another turn of the same thread, the first one ended.
      set_status(turn, "completed")
      {:ok, thread} = Threads.get(Sanctum.Context.actor(ctx), thread_id)
      {_next, next} = turn!(ctx, thread: thread)
      assert post(ctx, next, %{"screenshot" => shot}) |> refusal() == not_a_draft()

      # A turn of another thread of the same person.
      {_elsewhere, elsewhere} = turn!(ctx)
      assert post(ctx, elsewhere, %{"screenshot" => shot}) |> refusal() == not_a_draft()

      # Another person speaking as the turn that took it.
      someone = %{ctx | user_id: "usr_someone_else"}
      set_status(turn, "running")
      assert post(someone, lineage, %{"screenshot" => shot}) |> refusal() == not_a_draft()

      # A turn of another person in an athanor of their own.
      {other, _user} = person!("screenshot-other")
      {_theirs, theirs} = turn!(other)
      assert post(other, theirs, %{"screenshot" => shot}) |> refusal() == not_a_draft()

      # None by that id, an id that is no message id, and a sent message.
      for missing <- [Prima.UUID7.generate_id("msg"), "../" <> shot, "draft"],
          do: assert(post(ctx, lineage, %{"screenshot" => missing}) |> refusal() == not_a_draft())

      {:ok, %{posted: sent}} = post(ctx, lineage, %{"text" => "sent"})
      assert post(ctx, lineage, %{"screenshot" => sent}) |> refusal() == not_a_draft()

      # Refused every time, the turn's own draft is still its to post.
      assert {:ok, %{files: 1}} = post(ctx, lineage, %{"screenshot" => shot})
    end

    test "whose bytes are gone is refused, and the post writes nothing",
         %{ctx: ctx, lineage: lineage} do
      {:ok, %{message_id: shot, attachment: ref}} = call(ctx, lineage, "screenshot")
      thread_id = lineage["thread_id"]
      {:ok, blob} = Aqua.Attachments.blob_path(thread_id, shot, ref)
      :ok = Arca.delete(Sanctum.Context.actor(ctx), blob)

      assert post(ctx, lineage, %{"text" => "look", "screenshot" => shot}) |> refusal() ==
               not_a_draft()

      assert posts(ctx, thread_id) == []
    end

    test "taken by an attempt a takeover replaced, or by a turn since cancelled, publishes nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      attempt!(turn, "att_first")
      first = Map.put(lineage, "attempt", "att_first")
      {:ok, %{message_id: shot}} = call(ctx, first, "screenshot")

      # The takeover's holder runs the next attempt: the draft is not its.
      attempt!(turn, "att_second")
      second = Map.put(lineage, "attempt", "att_second")
      assert post(ctx, second, %{"screenshot" => shot}) |> refusal() == not_a_draft()

      # The holder it replaced is superseded.
      assert {:error, _superseded} = post(ctx, first, %{"screenshot" => shot})

      # The first attempt back, the turn cancelled: nothing posts.
      attempt!(turn, "att_first")
      set_status(turn, "cancelled")
      assert {:error, _not_in_a_turn} = post(ctx, first, %{"screenshot" => shot})
      assert posts(ctx, lineage["thread_id"]) == []
    end

    test "of a deleted thread is gone with it", %{ctx: ctx, turn: turn, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      set_status(turn, "completed")
      assert {:ok, _} = Threads.delete(Sanctum.Context.actor(ctx), lineage["thread_id"])
      assert gone?(ctx, lineage["thread_id"], shot)
    end

    test "posted by two posts at once is one picture, in one post",
         %{ctx: ctx, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")

      answers =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> post(ctx, lineage, %{"screenshot" => shot}) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert [{:ok, %{posted: post_id, files: 1}}] = Enum.filter(answers, &match?({:ok, _}, &1))
      assert [{:error, _}] = Enum.reject(answers, &match?({:ok, _}, &1))
      assert [%{id: ^post_id}] = posts(ctx, lineage["thread_id"])
      assert gone?(ctx, lineage["thread_id"], shot)
    end

    test "a post refused for its bounds copies nothing and leaves the draft to post",
         %{ctx: ctx, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      thread_id = lineage["thread_id"]
      %{max_files: max} = Aqua.Attachments.limits()

      files =
        for n <- 1..max,
            do: %{
              "filename" => "f#{n}.txt",
              "media_type" => "text/plain",
              "data" => Base.encode64("x")
            }

      assert {:error, _too_many} = post(ctx, lineage, %{"files" => files, "screenshot" => shot})
      assert posts(ctx, thread_id) == []

      {:ok, entries} = Arca.list(Sanctum.Context.actor(ctx), Threads.blob_root(thread_id))
      assert entries == [shot]

      assert {:ok, %{files: 1}} = post(ctx, lineage, %{"screenshot" => shot})
    end
  end

  describe "who reaches it" do
    test "a caller that is no running turn of the person reaches no window and starts nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      {other, _user} = person!("someone-else")
      {_their_turn, theirs} = turn!(other)

      # A component the turn started (its parent is not the root), another
      # person's turn naming this person's thread, and the turn paused.
      child = %{lineage | "parent_execution_id" => "exe_child"}
      forged = %{theirs | "thread_id" => lineage["thread_id"]}

      assert refusal(call(ctx, child, "open", %{"url" => "https://example.com/"})) ==
               "This turn no longer owns the work."

      assert refusal(call(other, forged, "open", %{"url" => "https://example.com/"})) ==
               "This turn no longer owns the work."

      set_status(turn, "paused")

      assert refusal(call(ctx, lineage, "read")) == "This turn no longer owns the work."
      assert refusal(call(ctx, %{}, "read")) == "This turn no longer owns the work."

      refute_received {:session, "open", _open, _fields}
      refute_received {:driver, :req, _session, _request}
      assert holder(ctx) == nil
    end

    test "another person's turn reaches their own browser, never this person's windows",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, mine, %{"win" => win}}, 5_000
      assert win == lineage["thread_id"]

      {other, _user} = person!("second-athanor")
      browser_row!(other)
      {_their_turn, theirs} = turn!(other)

      assert {:ok, _} = call(other, theirs, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, their_session, %{"win" => their_win}}, 5_000
      assert their_session != mine
      assert their_win == theirs["thread_id"]
      assert holder(ctx) != holder(other)
    end

    test "a request that waited for the start is proved again: a turn superseded meanwhile sends nothing",
         %{fake: fake, ctx: ctx, turn: turn, lineage: lineage} do
      Scripted.hold(fake, "opened")
      task = Task.async(fn -> call(ctx, lineage, "open", %{"url" => "https://example.com/"}) end)
      assert_receive {:held, "opened", held}, 5_000

      set_status(turn, "cancelled")
      send(held, :go)

      assert refusal(Task.await(task, 10_000)) == "This turn no longer owns the work."
      refute_received {:driver, :req, _session, _request}
    end
  end

  describe "what the browser starts with" do
    test "a schedule's turn, with no screen open, starts the browser in the person's stored language and zone",
         %{ctx: ctx} do
      [%{"person" => %{"locale" => locale, "time_zone" => zone}, "argv" => argv} | _] =
        (@vectors |> File.read!() |> Jason.decode!())["person"]["accept"]

      assert :ok = Aqua.put_reading(ctx.user_id, %{"locale" => locale})
      assert :ok = Aqua.put_reading(ctx.user_id, %{"time_zone" => zone})
      {_turn, lineage} = turn!(ctx, origin: :schedule)

      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:session, "open", %{"program" => _, "argv" => ^argv}, _fields}, 5_000
    end

    test "a person with neither stored starts it with Chrome's own", %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:session, "open", %{"program" => _, "argv" => []}, _fields}, 5_000
    end
  end

  describe "the person's setting" do
    test "off, every action is refused before any browser starts", %{ctx: ctx, lineage: lineage} do
      assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)

      for {action, args} <- [
            {"open", %{"url" => "https://example.com/"}},
            {"read", %{}},
            {"screenshot", %{}}
          ],
          do: assert(refusal(call(ctx, lineage, action, args)) == "The browser is turned off.")

      refute_received {:session, "open", _open, _fields}
      assert holder(ctx) == nil
    end

    test "turned off, the browser closes at once with nothing left waiting; its folder is kept",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert [%{session: session}] = browser_sessions(ctx)

      assert {:ok, %{on: false}} = Provider.handle("browser", ctx, %{"action" => "turn_off"})

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^session, reason: :closed}, 5_000
      assert browser_sessions(ctx) == []
      eventually(fn -> holder(ctx) == nil end, "the holder to stop")
      refute_received {:control, "home", _message, _fields}

      assert {:ok, %{on: false, browser: "added", running: false}} =
               Provider.handle("browser", ctx, %{"action" => "status"})
    end

    test "a turn turns it off at once; turning it on is the person's alone",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, %{on: false}} = call(ctx, lineage, "turn_off")
      assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)

      # Turning it on reaches no chain, so no turn calls it; turning it off
      # is a turn's to call.
      refute Sanctum.Catalog.chain_reachable?("browser", "turn_on")
      assert Sanctum.Catalog.chain_reachable?("browser", "turn_off")

      # A component the turn started turns nothing on or off.
      child = %{lineage | "parent_execution_id" => "exe_child"}
      assert refusal(call(ctx, child, "turn_on")) == "This turn no longer owns the work."
      assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)
    end
  end

  describe "the driver's framing" do
    test "a megabyte's answer arrives whole, in numbered chunks the host acknowledges",
         %{ctx: ctx, lineage: lineage} = context do
      text = :crypto.strong_rand_bytes(600_000) |> Base.encode64()
      answers(context, "read", {:ok, %{"text" => text}})

      assert {:ok, %{"text" => ^text}} =
               Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
                 {:ok, %{}}
               end)
    end

    test "after a replacement tail it asks again from the first missing chunk, takes the answer whole and runs the action once",
         %{ctx: ctx, lineage: lineage, driver: driver} = context do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      text = :crypto.strong_rand_bytes(600_000) |> Base.encode64()
      answers(context, "read", :hold)

      task =
        Task.async(fn ->
          Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
            {:ok, %{}}
          end)
        end)

      assert_receive {:driver, :holding, _session, id}, 5_000

      # The holder takes nothing while the driver pours the whole answer
      # out: more than the terminal keeps for it, so it is handed the last
      # of it, a replacement tail, in place of what it missed.
      holder = holder(ctx)
      :sys.suspend(holder)
      :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "noise"}))
      eventually(fn -> outstanding?(ctx) end, "a delivery outstanding")

      answers(context, "read", {:ok, %{"text" => text}})
      :ok = Driver.flood(driver)
      :ok = Driver.release(driver, id)
      eventually(fn -> lost?(ctx) end, "the tail")
      :sys.resume(holder)

      assert {:ok, %{"text" => ^text}} = Task.await(task, 20_000)
      assert_receive {:driver, :again, _session, ^id, _seq}, 5_000
      assert [_one] = for({:driver, :req, _s, %{"op" => "read"}} <- drain(), do: :read)
    end

    test "an answer the driver no longer holds is refused unavailable, never asked for twice",
         %{fake: fake, ctx: ctx, lineage: lineage} = context do
      driver = Driver.start(self(), keep_ms: 50, answer: &answer(context.answers, &1))
      Scripted.set(fake, :terminal, driver)
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      answers(context, "read", :hold)

      task =
        Task.async(fn ->
          Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
            {:ok, %{}}
          end)
        end)

      assert_receive {:driver, :holding, _session, id}, 5_000
      holder = holder(ctx)
      :sys.suspend(holder)
      :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "noise"}))
      eventually(fn -> outstanding?(ctx) end, "a delivery outstanding")

      answers(context, "read", {:ok, %{"text" => String.duplicate("x", 600_000)}})
      :ok = Driver.flood(driver)
      :ok = Driver.release(driver, id)
      eventually(fn -> lost?(ctx) end, "the tail")

      # Past the time the driver keeps an answer it was not told was held.
      # sleep-ok: the driver's 50 ms keep_ms passes, so it no longer holds the answer
      Process.sleep(200)
      :sys.resume(holder)

      assert {:error, :unavailable} = Task.await(task, 20_000)
      assert_receive {:driver, :again, _session, ^id, _seq}, 5_000
      assert [_one] = for({:driver, :req, _s, %{"op" => "read"}} <- drain(), do: :read)
    end
  end

  describe "its life" do
    test "it outlasts the turn that started it and serves the next turn of the person",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert [%{session: session}] = browser_sessions(ctx)

      set_status(turn, "completed")
      :ok = Programs.end_turn(ctx.athanor_id, turn.id)
      # sleep-ok: 100 ms after the turn ended in which its browser session must not close
      Process.sleep(100)
      assert [%{session: ^session}] = browser_sessions(ctx)

      {:ok, thread} = Threads.get(Sanctum.Context.actor(ctx), lineage["thread_id"])
      {_next, next} = turn!(ctx, thread: thread)
      assert {:ok, _} = call(ctx, next, "read")
      assert [%{session: ^session}] = browser_sessions(ctx)
    end

    test "the person lists it as Aqua's browser and closes it; the next action starts it again",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert [%{session: session, by: :browser}] = browser_sessions(ctx)

      assert {:ok, :closed} = Programs.close(ctx, session)
      eventually(fn -> holder(ctx) == nil end, "the holder to stop")

      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert [%{session: again}] = browser_sessions(ctx)
      assert again != session
    end

    test "it stops at its idle time with nothing waiting", %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      [%{session: session}] = browser_sessions(ctx)
      holder = holder(ctx)

      :sys.replace_state(holder, &%{&1 | last_act: &1.last_act - 86_400_000})
      {_timer, token} = :sys.get_state(holder).idle
      send(holder, {:idle, token})

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^session, reason: :closed}, 5_000
      eventually(fn -> holder(ctx) == nil end, "the holder to stop")
    end

    test "it ends when its person no longer stands", %{ctx: ctx, user: user, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      [%{session: session}] = browser_sessions(ctx)

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^session, reason: :standing}, 5_000
      eventually(fn -> holder(ctx) == nil end, "the holder to stop")
    end
  end

  describe "review round one" do
    # Finding 1: a request that waited in the holder's mailbox is proved
    # again just before it is sent.
    test "a request that waited is proved again before it is sent: a turn cancelled meanwhile, or a caller gone, sends nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      holder = holder(ctx)

      :sys.suspend(holder)
      task = Task.async(fn -> call(ctx, lineage, "click", %{"ref" => "12"}) end)
      eventually(fn -> mailbox(holder) >= 1 end, "the click to wait for the holder")
      set_status(turn, "cancelled")
      :sys.resume(holder)

      assert refusal(Task.await(task, 10_000)) == "This turn no longer owns the work."

      {_next, next} = turn!(ctx)
      :sys.suspend(holder)
      caller = spawn(fn -> call(ctx, next, "click", %{"ref" => "13"}) end)
      eventually(fn -> mailbox(holder) >= 1 end, "the second click to wait for the holder")
      Process.exit(caller, :kill)
      :sys.resume(holder)

      # The holder answers what came after them, so both were decided.
      assert {:ok, _} = call(ctx, next, "read")
      clicks = for {:driver, :req, _s, %{"op" => "click"} = request} <- drain(), do: request
      assert clicks == []
    end

    # Finding 2: the host holds every response to the bound the vector file
    # states, while it assembles it, whatever the driver sends.
    test "a response past the bound is refused as it is assembled, and nothing of it is kept",
         %{fake: fake, ctx: ctx, lineage: lineage} do
      past = String.duplicate("x", Opus.Browser.Frame.max_response())

      driver =
        Driver.start(self(),
          chunk: 98_112,
          answer: fn
            %{"op" => "read"} -> {:ok, %{"text" => past}}
            _other -> {:ok, %{"url" => "https://example.com/", "title" => "Example"}}
          end
        )

      Scripted.set(fake, :terminal, driver)
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})

      assert {:error, :response_too_large} =
               Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
                 {:ok, %{}}
               end)

      assert :sys.get_state(holder(ctx)).pending == %{}

      # The driver was told to let it go: the next answer comes at once.
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.org/"})
    end

    # Finding 3: what a turn types and what a page shows are in no status,
    # last message or debug log of the holder.
    test "what a turn types and what a page shows are in no status or debug log of the holder",
         %{ctx: ctx, lineage: lineage} = context do
      typed = "typed-#{System.unique_integer([:positive])}-private"
      shown = "shown-#{System.unique_integer([:positive])}-private"

      answers(
        context,
        "read",
        {:ok, %{"url" => "https://example.com/", "title" => "T", "text" => shown}}
      )

      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      holder = holder(ctx)
      :ok = :sys.log(holder, true)
      assert {:ok, _} = call(ctx, lineage, "type", %{"ref" => "12", "text" => typed})
      assert {:ok, %{text: ^shown}} = call(ctx, lineage, "read")

      status = inspect(:sys.get_status(holder), limit: :infinity, printable_limit: :infinity)
      :ok = :sys.log(holder, false)

      refute status =~ typed
      refute status =~ shown
    end

    # Finding 4: the browser's session lives as long as its holder.
    test "a holder killed takes the browser's session with it", %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert [%{session: session}] = browser_sessions(ctx)

      Process.exit(holder(ctx), :kill)

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^session, reason: :closed}, 5_000
      assert browser_sessions(ctx) == []
    end
  end

  describe "review round two" do
    # Finding 7: a request is decided where its first byte leaves for the
    # driver, after the writer's queue too.
    test "a request queued behind a held input, its turn cancelled meanwhile, sends nothing",
         %{fake: fake, ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      {other_turn, other} = turn!(ctx)
      holder = holder(ctx)

      Scripted.hold(fake, "input", 30_000)
      first = Task.async(fn -> call(ctx, lineage, "read") end)
      assert_receive {:held, "input", held}, 5_000

      click = Task.async(fn -> call(ctx, other, "click", %{"ref" => "12"}) end)

      eventually(
        fn -> map_size(:sys.get_state(holder).pending) == 2 end,
        "the click to wait for the writer"
      )

      set_status(other_turn, "cancelled")
      send(held, :go)

      assert {:ok, _} = Task.await(first, 10_000)
      assert refusal(Task.await(click, 10_000)) == "This turn no longer owns the work."

      clicks = for {:driver, :req, _s, %{"op" => "click"} = request} <- drain(), do: request
      assert clicks == []
    end

    # Finding 8: the session hangs on its holder from the moment its start
    # is asked, not from its attachment.
    test "a holder killed while its start waits leaves no session running",
         %{fake: fake, ctx: ctx, lineage: lineage} do
      Scripted.hold(fake, "opened", 30_000)
      Task.start(fn -> call(ctx, lineage, "open", %{"url" => "https://example.com/"}) end)
      assert_receive {:held, "opened", held}, 5_000

      Process.exit(holder(ctx), :kill)
      send(held, :go)

      # The session ends with its holder: the box closes the late session,
      # or releases the owner held for it alone, which ends what runs
      # under it on the service, whichever comes first.
      assert_receive {kind, type, _message, _fields}
                     when {kind, type} in [{:session, "close"}, {:control, "release"}],
                     10_000

      eventually(
        fn -> browser_sessions(ctx) == [] end,
        "the started session to end with its holder"
      )

      # Its terminal is gone once it has let its owner go, which it waits
      # for on its way out.
      eventually(
        fn ->
          Registry.select(Opus.Programs.Registry, [
            {{{:terminal, :_}, :"$1", {ctx.athanor_id, ctx.user_id, :browser}}, [], [:"$1"]}
          ]) == []
        end,
        "the browser's terminal to end"
      )
    end
  end

  describe "review round three" do
    # Finding 10: a request already answered, its time run out, is wanted
    # no more, and the writer does not write it.
    test "a request whose time ran out while it waited for the writer sends nothing",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      holder = holder(ctx)
      writer = :sys.get_state(holder).writer

      # Suspended only once it waits for its next write: suspended in the
      # middle of one, it would hold the test's one database connection.
      eventually(
        fn ->
          Process.info(writer, [:status, :current_function]) ==
            [status: :waiting, current_function: {Opus.Browser, :write_loop, 3}]
        end,
        "the writer to wait for its next write"
      )

      true = :erlang.suspend_process(writer)

      # A caller that stays alive once it is answered.
      test = self()

      {:ok, _caller} =
        Task.start(fn ->
          send(test, {:answered, call(ctx, lineage, "click", %{"ref" => "12"})})
          Process.sleep(:infinity)
        end)

      id =
        eventually(
          fn -> Enum.find(Map.keys(:sys.get_state(holder).pending), & &1) end,
          "the click to wait for the writer"
        )

      # Its time runs out, as its timer would say.
      send(holder, {:expired, id})
      assert_receive {:answered, answered}, 5_000
      assert refusal(answered) == "The browser's response is unavailable."
      assert :sys.get_state(holder).pending == %{}

      true = :erlang.resume_process(writer)
      assert {:ok, _} = call(ctx, lineage, "read")

      clicks = for {:driver, :req, _s, %{"op" => "click"} = request} <- drain(), do: request
      assert clicks == []
    end
  end

  describe "review round four" do
    # Finding 11: once turning the setting off has returned, nothing
    # reaches Chrome, even for an action whose holder had not yet been
    # started when the stop looked for it.
    test "an action whose holder waited to start while the setting went off sends nothing and starts no browser",
         %{ctx: ctx, lineage: lineage} do
      holders = Process.whereis(Opus.Browser.Holders)
      :ok = :sys.suspend(holders)

      on_exit(fn ->
        try do
          :sys.resume(holders)
        catch
          :exit, _resumed_or_gone -> :ok
        end
      end)

      open = Task.async(fn -> call(ctx, lineage, "open", %{"url" => "https://example.com/"}) end)

      eventually(
        fn ->
          {:messages, messages} = Process.info(holders, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _from, {:start_child, _spec}}, &1))
        end,
        "the holder's start to wait in its supervisor's mailbox"
      )

      assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)
      assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)
      :ok = :sys.resume(holders)

      assert refusal(Task.await(open, 10_000)) == "The browser is turned off."
      refute_received {:session, "open", _open, _fields}
      refute_received {:driver, :req, _session, %{"op" => "open"}}
      assert browser_sessions(ctx) == []
      eventually(fn -> holder(ctx) == nil end, "the holder to end")
    end
  end

  describe "review round five" do
    # Finding 13, the rule restated: turning the setting off holds at once;
    # nothing new starts after it and nothing reaches Chrome, and a session
    # that a start already in flight creates is sent nothing and is closed
    # as soon as that start answers.
    test "off returns while a start waits on the service; the session it then makes is closed with nothing written, and so for a second start held longer",
         %{fake: fake, ctx: ctx, lineage: lineage} do
      for held_ms <- [0, 1_500] do
        assert {:ok, true} = Aqua.BrowserSetting.put(ctx, true)
        Scripted.hold(fake, "open", 30_000)

        open =
          Task.async(fn -> call(ctx, lineage, "open", %{"url" => "https://example.com/"}) end)

        assert_receive {:held, "open", service}, 5_000

        # Off returns, and the action is answered, while the start still
        # waits on the service.
        assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)
        assert refusal(Task.await(open, 5_000)) == "The browser is turned off."
        refute_received {:session, "open", _open, _fields}

        # sleep-ok: the start held held_ms (0 or 1,500) on the service, the hold under test
        Process.sleep(held_ms)
        send(service, :go)
        assert_receive {:session, "open", _open, _fields}, 5_000
        assert_receive {:session, "close", _close, _fields}, 5_000
        refute_received {:session, "input", _input, _fields}
        refute_received {:driver, :req, _session, _request}
        eventually(fn -> browser_sessions(ctx) == [] end, "the late session to be closed")
        eventually(fn -> holder(ctx) == nil end, "no holder to remain")
        refute_received {:session, "input", _input, _fields}
      end
    end
  end

  describe "a page put into the window" do
    test "files Aqua hands are put: the request's arguments are their manifest and its parts their bytes, in its order",
         %{ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      root = root(ctx, "demo")
      png = :crypto.strong_rand_bytes(Opus.Browser.Frame.put_part_bytes() * 2 + 17)

      assert {:ok, %{url: "https://example.com/", title: "Example"}} =
               call(ctx, lineage, "page", %{
                 "name" => "demo",
                 "files" => [
                   %{"path" => "index.html", "content" => "<p>hello</p>"},
                   %{
                     "path" => "js/app.js",
                     "content" => "console.log('é')",
                     "encoding" => "text"
                   },
                   %{
                     "path" => "img/big.png",
                     "content" => Base.encode64(png),
                     "encoding" => "base64"
                   }
                 ]
               })

      assert_receive {:driver, :req, session,
                      %{"op" => "page", "win" => ^win, "of" => 3, "args" => args} = request},
                     5_000

      id = request["id"]
      assert_receive {:driver, :put, ^session, ^request, bytes}, 5_000

      # The entry is handed with a head first, then the <base> and the SDK.
      entry = handed_entry(bytes, "<p>hello</p>")
      assert entry == plain_handed("<p>hello</p>", root <> "/", nonce_of(entry))

      assert args == %{
               "root" => root,
               "entry" => "index.html",
               "files" => [
                 %{"path" => "index.html", "type" => "text/html", "size" => byte_size(entry)},
                 %{"path" => "js/app.js", "type" => "text/javascript", "size" => 17},
                 %{"path" => "img/big.png", "type" => "image/png", "size" => byte_size(png)}
               ]
             }

      assert bytes == entry <> "console.log('é')" <> png

      # The parts came in order, each the next at most a part's bytes.
      parts = for {:driver, :part, ^session, ^id, seq, part} <- drain(), do: {seq, part}
      assert [{0, _}, {1, _}, {2, _}] = parts

      assert Enum.all?(parts, fn {_seq, part} ->
               byte_size(part) <= Opus.Browser.Frame.put_part_bytes()
             end)
    end

    test "a plain page's entry is the vector's, at the vector's address and at the page's own",
         %{ctx: ctx, lineage: lineage} do
      %{"document" => document, "href" => href, "nonce" => nonce, "entry" => entry} =
        @vectors |> File.read!() |> Jason.decode!() |> Map.fetch!("plain_entry")

      expected = String.replace(entry, "{sdk}", Compendium.tincture_sdk())

      assert Compendium.tincture_head_tags(Compendium.plain_entry(document), href, nonce) ==
               expected

      # Put as html, and as files under the vector's name: each entry is the
      # vector's, its <base> the page's own root and its nonce the put's.
      at = fn root, handed ->
        expected
        |> String.replace(~s(<base href="#{href}">), ~s(<base href="#{root}/">))
        |> String.replace(~s(<script nonce="#{nonce}">), ~s(<script nonce="#{nonce_of(handed)}">))
      end

      assert {:ok, _} = call(ctx, lineage, "page", %{"html" => document})
      assert_receive {:driver, :put, _s, _request, handed}, 5_000
      assert handed == at.(root(ctx, "page"), handed)

      png = <<137, 80, 78, 71, 13, 10, 26, 10>>

      assert {:ok, _} =
               call(ctx, lineage, "page", %{
                 "name" => "plain",
                 "files" => [
                   %{"path" => "index.html", "content" => document},
                   %{"path" => "pic.png", "content" => Base.encode64(png), "encoding" => "base64"}
                 ]
               })

      assert_receive {:driver, :put, _s, _request, bytes}, 5_000
      handed = binary_part(bytes, 0, byte_size(bytes) - byte_size(png))
      assert handed == at.(root(ctx, "plain"), handed)
    end

    test "a page of one file is put as the index.html of the page named page",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "page", %{"html" => "<h1>Results</h1>"})

      assert_receive {:driver, :req, _s, %{"op" => "page", "of" => 1, "args" => args}}, 5_000
      assert_receive {:driver, :put, _s, _request, entry}, 5_000

      assert entry == plain_handed("<h1>Results</h1>", root(ctx, "page") <> "/", nonce_of(entry))

      assert args == %{
               "root" => root(ctx, "page"),
               "entry" => "index.html",
               "files" => [
                 %{"path" => "index.html", "type" => "text/html", "size" => byte_size(entry)}
               ]
             }
    end

    test "an unsafe path, an unserved type, a malformed encoding or a twice-given path is refused, and nothing is put",
         %{ctx: ctx, lineage: lineage} do
      page = %{"path" => "index.html", "content" => "<p>x</p>"}

      for {files, sentence} <- [
            {[page, %{"path" => "../up.js", "content" => ""}],
             "../up.js: Path traversal rejected"},
            {[page, %{"path" => "/abs.js", "content" => ""}],
             "/abs.js: Absolute paths are not allowed."},
            {[page, %{"path" => "a\\b.js", "content" => ""}], "a\\b.js: Path traversal rejected"},
            {[page, %{"path" => "notes.md", "content" => ""}],
             "notes.md is not a type a page serves"},
            {[page, %{"path" => "run.exe", "content" => ""}],
             "run.exe is not a type a page serves"},
            {[page, %{"path" => "a.png", "content" => "not base64!", "encoding" => "base64"}],
             "The content of a.png is not base64."},
            {[page, %{"path" => "a.png", "content" => "", "encoding" => "hex"}],
             "The encoding of a.png is text or base64."},
            {[page, %{"path" => "a.js", "content" => "1"}, %{"path" => "a.js", "content" => "2"}],
             "a.js is given twice."},
            {[%{"path" => "app.js", "content" => ""}], "The entry is not among the files."}
          ] do
        assert refusal(call(ctx, lineage, "page", %{"name" => "demo", "files" => files})) =~
                 sentence,
               sentence
      end

      assert refusal(
               call(ctx, lineage, "page", %{
                 "name" => "demo",
                 "entry" => "app.js",
                 "files" => [page, %{"path" => "app.js", "content" => ""}]
               })
             ) == "The entry app.js is not an html file."

      assert refusal(
               call(ctx, lineage, "page", %{
                 "html" => "<p/>",
                 "tincture" => "tincture:local.x:1.0.0"
               })
             ) ==
               "browser.page takes exactly one of html, files and tincture"

      assert refusal(call(ctx, lineage, "page", %{"name" => "Not A Name", "files" => [page]})) =~
               "name: "

      # Nothing was put: an action after them all is the driver's first page.
      assert {:ok, _} = call(ctx, lineage, "read")
      assert for({:driver, :req, _s, %{"op" => "page"}} <- drain(), do: :put) == []
    end

    test "a local tincture is put as the endpoint reads it, its entry carrying the <base> and the SDK as the endpoint serves it",
         %{ctx: ctx, lineage: lineage} do
      entry = "<html><head><title>Viewer</title></head><body>v</body></html>"

      {unit, manifest} =
        tincture!(
          ctx,
          "viewer",
          %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}},
          [
            {"dist/index.html", entry},
            {"dist/assets/app.js", "export const a = 1"},
            {"public/media/icon.svg", "<svg/>"},
            {"src/main.ts", "const a: number = 1"},
            {"package.json", "{}"},
            {"package-lock.json", "{}"}
          ]
        )

      assert {:ok, _} = call(ctx, lineage, "page", %{"tincture" => "tincture:local.viewer:1.0.0"})
      root = root(ctx, "viewer")

      assert_receive {:driver, :req, _s, %{"op" => "page", "args" => args}}, 5_000
      assert_receive {:driver, :put, _s, _request, bytes}, 5_000

      # Every file the endpoint serves by its name, in path order: not the
      # manifest, and no file of a type it does not serve.
      assert %{"root" => ^root, "entry" => "dist/index.html", "files" => files} = args

      assert Enum.map(files, &{&1["path"], &1["type"]}) == [
               {"dist/assets/app.js", "text/javascript"},
               {"dist/index.html", "text/html"},
               {"package-lock.json", "application/json"},
               {"package.json", "application/json"},
               {"public/media/icon.svg", "image/svg+xml"}
             ]

      [app, handed, lock, package, icon] = split(bytes, Enum.map(files, & &1["size"]))
      assert {app, lock, package, icon} == {"export const a = 1", "{}", "{}", "<svg/>"}

      # The entry as the endpoint serves it at the same address, the nonce
      # apart: no head is put before the tincture's own.
      served =
        Plug.Test.conn(:get, "/")
        |> Emissary.Web.TinctureAssets.serve(
          ctx,
          %{segments: unit, manifest: manifest},
          ["dist", "index.html"],
          cache: :revalidate,
          base: root <> "/"
        )

      assert served.status == 200
      assert without_nonce(handed) == without_nonce(served.resp_body)
      assert handed =~ ~s(<base href="#{root}/dist/">)
      assert [_once] = :binary.matches(handed, Compendium.tincture_sdk())
      assert String.starts_with?(handed, "<html><head>\n<base href=")
    end

    test "another publisher's tincture is refused as source refuses it, and nothing is put",
         %{ctx: ctx, lineage: lineage} do
      path = "components/tinctures/acme/viewer/1.0.0"

      {:error, source_refusal} =
        Compendium.Providers.Source.handle("source", guest(ctx), %{
          "action" => "tree",
          "path" => path
        })

      refused = call(ctx, lineage, "page", %{"tincture" => "tincture:acme.viewer:1.0.0"})
      assert refusal(refused) == Sanctum.Refusals.render(source_refusal)
      assert refusal(refused) =~ "'acme' is another publisher's component"
      refute_received {:session, "open", _open, _fields}
    end

    test "a tincture of a second athanor is not found, and nothing is put",
         %{ctx: ctx, lineage: lineage} do
      {other, _user} = person!("browser-other-athanor")
      browser_row!(other)
      tincture!(other, "viewer", %{}, [{"index.html", "<html><head></head></html>"}])

      assert refusal(call(ctx, lineage, "page", %{"tincture" => "tincture:local.viewer:1.0.0"})) ==
               "Component not found: tincture:local.viewer:1.0.0"

      # The same reference in its own athanor is put.
      {_turn, other_lineage} = turn!(other)

      assert {:ok, _} =
               call(other, other_lineage, "page", %{"tincture" => "tincture:local.viewer:1.0.0"})

      assert_receive {:driver, :req, _s, %{"op" => "page", "win" => win}}, 5_000
      assert win == other_lineage["thread_id"]
      refute_received {:driver, :req, _s, %{"op" => "page"}}
    end

    test "a canvas is refused, as it is not served, and nothing is put",
         %{ctx: ctx, lineage: lineage} do
      tincture!(ctx, "home", %{"desktop" => %{}, "entry" => "index.html"}, [
        {"index.html", "<html><head></head></html>"}
      ])

      assert refusal(call(ctx, lineage, "page", %{"tincture" => "tincture:local.home:1.0.0"})) ==
               "tincture:local.home:1.0.0 is a canvas, which holds no page"

      refute_received {:session, "open", _open, _fields}
    end

    test "a put past the bound is refused before anything is written, and Aqua is told",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      %{files: max_files, bytes: max_bytes} = Opus.Browser.put_bound()

      assert {max_files, max_bytes} ==
               {Opus.Browser.Frame.put_max_files(), Opus.Browser.Frame.put_max_bytes()}

      many =
        [%{"path" => "index.html", "content" => "<p/>"}] ++
          for(n <- 1..max_files, do: %{"path" => "f#{n}.js", "content" => ""})

      assert refusal(call(ctx, lineage, "page", %{"name" => "demo", "files" => many})) ==
               "That page is too large to show: the browser takes at most #{max_files} files " <>
                 "and #{div(max_bytes, 1_048_576)} MiB in one page."

      caller = Opus.Browser.caller(guest(ctx), lineage)
      large = %{path: "index.html", type: "text/html", bytes: :binary.copy("x", max_bytes + 1)}

      assert {:error, :put_too_large} =
               Opus.Browser.put(
                 caller,
                 %{root: "/t/x/local/p", entry: "index.html", files: [large]},
                 fn -> {:ok, %{}} end
               )

      at_bound = %{large | bytes: :binary.copy("x", max_bytes)}

      assert {:ok, _} =
               Opus.Browser.put(
                 caller,
                 %{root: "/t/x/local/p", entry: "index.html", files: [at_bound]},
                 fn -> {:ok, %{}} end
               )

      # Of the three, only the one within the bound reached the driver.
      assert [%{"args" => %{"files" => [%{"size" => ^max_bytes}]}}] =
               for({:driver, :req, _s, %{"op" => "page"} = request} <- drain(), do: request)
    end

    test "a tincture past the bound is refused, Aqua is told, and nothing starts",
         %{ctx: ctx, lineage: lineage} do
      %{files: max_files, bytes: max_bytes} = Opus.Browser.put_bound()
      many = for n <- 1..max_files, do: {"f#{n}.js", ""}
      tincture!(ctx, "many", %{}, [{"index.html", "<html><head></head></html>"} | many])

      assert refusal(call(ctx, lineage, "page", %{"tincture" => "tincture:local.many:1.0.0"})) ==
               "That page is too large to show: the browser takes at most #{max_files} files " <>
                 "and #{div(max_bytes, 1_048_576)} MiB in one page."

      refute_received {:session, "open", _open, _fields}
    end

    test "a put by a turn that lost the work while it waited for the writer hands over nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, _s, %{"op" => "open"}}, 5_000
      holder = holder(ctx)
      writer = :sys.get_state(holder).writer

      eventually(
        fn ->
          Process.info(writer, [:status, :current_function]) ==
            [status: :waiting, current_function: {Opus.Browser, :write_loop, 3}]
        end,
        "the writer to wait for its next write"
      )

      true = :erlang.suspend_process(writer)

      task =
        Task.async(fn ->
          call(ctx, lineage, "page", %{"html" => String.duplicate("<p>page</p>", 200_000)})
        end)

      eventually(
        fn -> map_size(:sys.get_state(holder).pending) == 1 end,
        "the put to wait for the writer"
      )

      set_status(turn, "cancelled")
      true = :erlang.resume_process(writer)

      assert refusal(Task.await(task, 10_000)) == "This turn no longer owns the work."

      {_next, next} = turn!(ctx)
      assert {:ok, _} = call(ctx, next, "read")

      handed =
        for m <- drain(),
            is_tuple(m) and tuple_size(m) > 2 and elem(m, 0) == :driver and
              elem(m, 1) in [:req, :part, :put],
            do: m

      assert [{:driver, :req, _s, %{"op" => "read"}}] = handed
    end
  end

  describe "a page's call" do
    # The browser alone: the application's `Aqua.PageCalls`, which answers
    # every call it hears, is stopped for each case and started after it.
    setup do
      on_exit(&restart_page_calls/0)
      :ok = Supervisor.terminate_child(Aqua.Supervisor, Aqua.PageCalls)
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.page_calls())
    end

    test "naming its window's put is held and announced once, with its window, op, bytes and the put's turn and tincture",
         %{driver: driver, ctx: ctx, turn: turn, lineage: lineage} do
      win = lineage["thread_id"]

      tincture!(ctx, "viewer", %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}, [
        {"dist/index.html", "<html><head></head><body>v</body></html>"}
      ])

      put = put!(ctx, lineage, %{"tincture" => "tincture:local.viewer:1.0.0"})
      body = ~s({"v":1,"ref":"reagent:local.x:1.0.0","operation":"run","args":{}})

      # The call as the vectors spell it, which the driver marshals to.
      %{"fields" => fields, "example" => example} =
        @vectors
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("messages")
        |> Map.fetch!("call")

      frame =
        Map.merge(example, %{"id" => 3, "win" => win, "put" => put, "body" => Base.encode64(body)})

      assert Enum.sort(Map.keys(frame)) == Enum.sort(fields)
      :ok = Driver.write(driver, Opus.Browser.Frame.message(frame))

      assert_receive %PageCall{kind: :call, request: "pgc_" <> _ = request} = page_call, 5_000

      assert page_call == %PageCall{
               kind: :call,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               thread_id: win,
               request: request,
               op: "invoke",
               body: body,
               put: %{turn_id: turn.id, tincture: "tincture:local.viewer:1.0.0"}
             }

      # A page Aqua wrote, put by a turn of another thread, has no tincture.
      {other_turn, other} = turn!(ctx)
      other_put = put!(ctx, other, %{"html" => "<p>hello</p>"})
      :ok = Driver.call(driver, 4, other["thread_id"], other_put, "action", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: second} = plain, 5_000
      assert second != request

      assert {plain.thread_id, plain.op, plain.body, plain.put} ==
               {other["thread_id"], "action", ~s({"v":1}),
                %{turn_id: other_turn.id, tincture: nil}}

      # Both are held: nothing answered them, and nothing more was said.
      assert {:ok, _} = call(ctx, lineage, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :answer, _s, _id, _status, _body}
      refute_received %PageCall{}
    end

    test "from a window with no put is answered unavailable at once, one that does not read is refused, and neither is announced",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      unavailable = Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, _s, %{"op" => "open", "id" => opened}}, 5_000

      # The open's request is no put.
      for {id, window} <- [{3, win}, {4, "thr_never_opened"}] do
        :ok = Driver.call(driver, id, window, opened, "invoke", ~s({"v":1}))
        assert_receive {:driver, :answer, _s, ^id, 503, body}, 5_000
        assert Jason.decode!(body) == unavailable
      end

      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      bound = Opus.Browser.Frame.call_max_body()

      for {id, call} <- [
            {5, %{"win" => win, "put" => put, "op" => "delete", "body" => Base.encode64("{}")}},
            {6, %{"win" => win, "put" => put, "op" => "invoke", "body" => "not base64!"}},
            {7, %{"put" => put, "op" => "invoke", "body" => Base.encode64("{}")}},
            {8,
             %{
               "win" => win,
               "put" => put,
               "op" => "invoke",
               "body" => Base.encode64(:binary.copy("a", bound + 1))
             }},
            {10, %{"win" => win, "op" => "invoke", "body" => Base.encode64("{}")}},
            {11,
             %{
               "win" => win,
               "put" => Integer.to_string(put),
               "op" => "invoke",
               "body" => Base.encode64("{}")
             }}
          ] do
        frame = Map.merge(call, %{"t" => "call", "id" => id})
        :ok = Driver.write(driver, Opus.Browser.Frame.message(frame))
        assert_receive {:driver, :answer, _s, ^id, 400, body}, 5_000

        assert %{"ok" => false, "error" => %{"class" => "invalid_argument"}} =
                 Jason.decode!(body)
      end

      refute_received %PageCall{}

      # A body of the bound's bytes is held.
      :ok = Driver.call(driver, 9, win, put, "invoke", :binary.copy("a", bound))
      assert_receive %PageCall{kind: :call, body: held}, 5_000
      assert byte_size(held) == bound
    end

    test "from a window whose put is gone, by its close or a window that does not stand, is answered unavailable",
         %{driver: driver, ctx: ctx, lineage: lineage} = context do
      win = lineage["thread_id"]
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      assert {:ok, _} = call(ctx, lineage, "close")
      :ok = Driver.call(driver, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive {:driver, :answer, _s, 3, 503, _body}, 5_000

      put = put!(ctx, lineage, %{"html" => "<p>again</p>"})
      answers(context, "read", {:error, "no_window", "The window is gone."})
      assert {:error, _} = call(ctx, lineage, "read")
      :ok = Driver.call(driver, 4, win, put, "invoke", ~s({"v":1}))
      assert_receive {:driver, :answer, _s, 4, 503, _body}, 5_000

      refute_received %PageCall{}
    end

    test "is answered once through answer/5; a second answer, or one for a request not held, writes nothing",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      :ok = Driver.call(driver, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: request}, 5_000

      answer = Jason.encode!(Prima.TinctureWire.result(%{"n" => 1}))
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, answer)
      assert_receive {:driver, :answer, _s, 3, 200, ^answer}, 5_000

      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, answer)
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, "pcl_unknown", 200, answer)
      assert :ok = Opus.Browser.answer(ctx.athanor_id, "usr_another", request, 200, answer)

      # An answer one frame does not hold is answered with a refusal.
      :ok = Driver.call(driver, 4, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: large}, 5_000
      huge = :binary.copy("a", Opus.Browser.Frame.max_to_driver())
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, large, 200, huge)
      assert_receive {:driver, :answer, _s, 4, 400, body}, 5_000
      assert %{"ok" => false, "error" => %{"class" => "invalid_argument"}} = Jason.decode!(body)

      # What was written since reaches the driver before this action does.
      assert {:ok, _} = call(ctx, lineage, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :answer, _s, _id, _status, _body}
      refute_received %PageCall{kind: :ended}
    end

    test "held by a process that dies is answered unavailable and its end announced; a later answer writes nothing",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      :ok = Driver.call(driver, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: request}, 5_000

      first = spawn(fn -> Process.sleep(:infinity) end)
      runner = spawn(fn -> Process.sleep(:infinity) end)
      holder = holder(ctx)
      assert {:ok, ^holder} = Opus.Browser.held(ctx.athanor_id, ctx.user_id, request, first)
      assert {:ok, ^holder} = Opus.Browser.held(ctx.athanor_id, ctx.user_id, request, runner)
      assert :gone = Opus.Browser.held(ctx.athanor_id, ctx.user_id, "pcl_unknown", first)

      # The process that held it before the runner no longer does.
      Process.exit(first, :kill)
      refute_receive {:driver, :answer, _s, 3, _status, _body}, 300

      Process.exit(runner, :kill)
      assert_receive {:driver, :answer, _s, 3, 503, body}, 5_000

      assert Jason.decode!(body) ==
               Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))

      assert_receive %PageCall{kind: :ended, request: ^request} = ended, 5_000

      assert ended == %PageCall{
               kind: :ended,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               thread_id: win,
               request: request
             }

      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, ~s({"v":1}))
      assert {:ok, _} = call(ctx, lineage, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :answer, _s, _id, _status, _body}
      refute_received %PageCall{}
    end

    test "given up by the driver has its end announced once; its answer then writes nothing",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      :ok = Driver.call(driver, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: request}, 5_000

      callend = &Opus.Browser.Frame.message(%{"t" => "callend", "id" => &1})
      :ok = Driver.write(driver, callend.(3))
      assert_receive %PageCall{kind: :ended, request: ^request, thread_id: ^win}, 5_000

      # A second end, or one of a call not held, says nothing.
      :ok = Driver.write(driver, callend.(3))
      :ok = Driver.write(driver, callend.(99))
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, ~s({"v":1}))
      assert {:ok, _} = call(ctx, lineage, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :answer, _s, _id, _status, _body}
      refute_received %PageCall{}
    end

    test "held when the session ends, the browser stops or it stops at its idle time, each ends with its holder, " <>
           "which its holder's monitor hears and nothing announces",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      {_other_turn, other} = turn!(ctx)

      # Each call held here, as its runner holds it, monitoring the
      # browser's holder that `held/4` answers.
      held = fn ids ->
        for {id, lineage} <- ids do
          put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
          :ok = Driver.call(driver, id, lineage["thread_id"], put, "invoke", ~s({"v":1}))
          assert_receive %PageCall{kind: :call, request: request}, 5_000
          {:ok, holder} = Opus.Browser.held(ctx.athanor_id, ctx.user_id, request, self())
          Process.monitor(holder)
        end
      end

      ends = fn monitors ->
        for monitor <- monitors,
            do: assert_receive({:DOWN, ^monitor, :process, _pid, _reason}, 5_000)

        eventually(fn -> holder(ctx) == nil end, "the holder to stop")
      end

      # The session ends.
      monitors = held.([{3, lineage}, {4, other}])
      [%{session: session}] = browser_sessions(ctx)
      assert {:ok, :closed} = Programs.close(ctx, session)
      ends.(monitors)

      # The browser stops, its setting off.
      monitors = held.([{5, lineage}])
      :ok = Opus.Browser.stop(ctx.athanor_id, ctx.user_id)
      ends.(monitors)

      # Its idle stop.
      monitors = held.([{6, lineage}])
      holder = holder(ctx)
      :sys.replace_state(holder, &%{&1 | last_act: &1.last_act - 86_400_000})
      {_timer, token} = :sys.get_state(holder).idle
      send(holder, {:idle, token})
      ends.(monitors)

      refute_receive %PageCall{}, 200
    end

    test "naming a put sent and not yet answered is announced with it, the earlier put still its own; the later's success forgets the earlier",
         %{driver: driver, ctx: ctx, turn: turn, lineage: lineage} = context do
      win = lineage["thread_id"]
      unavailable = Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))

      tincture!(ctx, "viewer", %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}, [
        {"dist/index.html", "<html><head></head><body>v</body></html>"}
      ])

      earlier = put!(ctx, lineage, %{"tincture" => "tincture:local.viewer:1.0.0"})

      # A later turn of the thread puts a page whose document calls before
      # the driver answers the put, while the earlier document still calls.
      set_status(turn, "completed")
      {later_turn, later_lineage} = turn!(ctx, thread: %{id: win})
      answers(context, "page", :hold)
      putting = Task.async(fn -> call(ctx, later_lineage, "page", %{"html" => "<p>next</p>"}) end)
      assert_receive {:driver, :holding, _s, later}, 5_000

      :ok = Driver.call(driver, 3, win, later, "invoke", ~s({"v":"later"}))
      :ok = Driver.call(driver, 4, win, earlier, "action", ~s({"v":"earlier"}))
      assert_receive %PageCall{kind: :call, body: ~s({"v":"later"})} = from_later, 5_000
      assert_receive %PageCall{kind: :call, body: ~s({"v":"earlier"})} = from_earlier, 5_000

      assert from_later == %PageCall{
               kind: :call,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               thread_id: win,
               request: from_later.request,
               op: "invoke",
               body: ~s({"v":"later"}),
               put: %{turn_id: later_turn.id, tincture: nil}
             }

      assert from_earlier == %PageCall{
               kind: :call,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               thread_id: win,
               request: from_earlier.request,
               op: "action",
               body: ~s({"v":"earlier"}),
               put: %{turn_id: turn.id, tincture: "tincture:local.viewer:1.0.0"}
             }

      assert from_later.request != from_earlier.request

      :ok = Driver.release(driver, later)
      assert {:ok, _} = Task.await(putting)

      :ok = Driver.call(driver, 5, win, earlier, "invoke", ~s({"v":"earlier"}))
      assert_receive {:driver, :answer, _s, 5, 503, body}, 5_000
      assert Jason.decode!(body) == unavailable

      :ok = Driver.call(driver, 6, win, later, "invoke", ~s({"v":"after"}))
      assert_receive %PageCall{kind: :call, body: ~s({"v":"after"})} = after_success, 5_000

      assert after_success == %{
               from_later
               | request: after_success.request,
                 body: ~s({"v":"after"})
             }

      # Calls 3, 4 and 6 are held: nothing answered them.
      assert {:ok, _} = call(ctx, later_lineage, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :answer, _s, _id, _status, _body}
      refute_received %PageCall{}
    end

    test "naming a put that failed, a put of another window or a request never sent is answered unavailable and not announced",
         %{driver: driver, ctx: ctx, lineage: lineage} = context do
      win = lineage["thread_id"]
      unavailable = Prima.TinctureWire.refusal(Sanctum.Refusals.classify(:unavailable))
      {other_turn, other} = turn!(ctx)
      theirs = put!(ctx, other, %{"html" => "<p>theirs</p>"})

      answers(context, "page", {:error, "unreachable", "The page could not be loaded."})
      assert {:error, _} = call(ctx, lineage, "page", %{"html" => "<p>failed</p>"})
      assert_receive {:driver, :put, _s, %{"id" => failed}, _bytes}, 5_000

      for {id, put} <- [{3, failed}, {4, theirs}, {5, 9_999}] do
        :ok = Driver.call(driver, id, win, put, "invoke", ~s({"v":1}))
        assert_receive {:driver, :answer, _s, ^id, 503, body}, 5_000
        assert Jason.decode!(body) == unavailable
      end

      refute_received %PageCall{}

      # The other window's call naming its own put is held.
      :ok = Driver.call(driver, 6, other["thread_id"], theirs, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call} = held, 5_000

      assert held == %PageCall{
               kind: :call,
               athanor_id: ctx.athanor_id,
               user_id: ctx.user_id,
               thread_id: other["thread_id"],
               request: held.request,
               op: "invoke",
               body: ~s({"v":1}),
               put: %{turn_id: other_turn.id, tincture: nil}
             }
    end

    test "its bytes and its answer's are in no inspect of its announcement and no status or debug log of the holder",
         %{driver: driver, ctx: ctx, lineage: lineage} do
      sent = "sent-#{System.unique_integer([:positive])}-private"
      answered = "answered-#{System.unique_integer([:positive])}-private"
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      holder = holder(ctx)
      :ok = :sys.log(holder, true)

      :ok =
        Driver.call(driver, 3, lineage["thread_id"], put, "invoke", ~s({"v":1,"note":"#{sent}"}))

      assert_receive %PageCall{kind: :call, request: request, body: body} = page_call, 5_000
      assert body =~ sent
      refute inspect(page_call, limit: :infinity, printable_limit: :infinity) =~ sent
      held = inspect(:sys.get_status(holder), limit: :infinity, printable_limit: :infinity)

      answer = Jason.encode!(Prima.TinctureWire.result(answered))
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, answer)
      assert_receive {:driver, :answer, _s, 3, 200, ^answer}, 5_000

      status = inspect(:sys.get_status(holder), limit: :infinity, printable_limit: :infinity)
      :ok = :sys.log(holder, false)

      refute held =~ sent
      refute status =~ sent
      refute status =~ answered
    end
  end

  describe "the browser's row" do
    test "with none, the browser was not found", %{ctx: ctx, row: row, lineage: lineage} do
      {:ok, _} =
        Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), row.name, %{
          id: row.id,
          epoch: row.epoch
        })

      assert refusal(call(ctx, lineage, "open", %{"url" => "https://example.com/"})) =~
               "The browser was not found."
    end

    test "a row of its name with another definition is not Aqua's browser and does not start",
         %{ctx: ctx, row: row, lineage: lineage} do
      {:ok, _} =
        Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), row.name, %{
          id: row.id,
          epoch: row.epoch
        })

      browser_row!(ctx, %{config_json: Jason.encode!(%{"command" => "sh", "env" => %{}})})

      assert refusal(call(ctx, lineage, "open", %{"url" => "https://example.com/"})) ==
               "This program is not Aqua's browser."

      refute_received {:session, "open", _open, _fields}
    end
  end

  describe "a window whose thread is put away" do
    # The browser alone, as in "a page's call": a call held in a window is
    # seen to end.
    setup do
      on_exit(&restart_page_calls/0)
      :ok = Supervisor.terminate_child(Aqua.Supervisor, Aqua.PageCalls)
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.page_calls())
    end

    test "its thread archived by the person is closed by its holder and the call held there ends; " <>
           "another thread's window stays",
         %{driver: driver, ctx: ctx, turn: turn, lineage: lineage} do
      win = lineage["thread_id"]
      {_other_turn, other} = turn!(ctx)
      assert {:ok, _} = call(ctx, other, "open", %{"url" => "https://example.org/"})
      put = put!(ctx, lineage, %{"html" => "<p>hello</p>"})
      :ok = Driver.call(driver, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, request: request}, 5_000

      # Its turn over, no work remains there, and the person archives it.
      set_status(turn, "completed")
      assert {:ok, %{archived_at: %DateTime{}}} = Threads.archive(Sanctum.Context.actor(ctx), win)

      assert_receive {:driver, :req, _s, %{"op" => "close", "win" => ^win, "args" => %{}}}, 5_000

      # The driver gives up the closed window's calls (cyfr-browser's
      # TestCallsEndWithTheirDocument), and the holder announces the end.
      :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "callend", "id" => 3}))
      assert_receive %PageCall{kind: :ended, request: ^request, thread_id: ^win}, 5_000

      # The other thread's window stands, and nothing else was closed.
      assert {:ok, _} = call(ctx, other, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read", "win" => other_win}}, 5_000
      assert other_win == other["thread_id"]
      refute_received {:driver, :req, _s, %{"op" => "close"}}
      assert :sys.get_state(holder(ctx)).windows == MapSet.new([other_win])
    end

    test "its thread archived by the setting is closed as one the person archived; " <>
           "a thread at work is neither archived nor closed",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      win = lineage["thread_id"]
      {_other_turn, other} = turn!(ctx)

      for each <- [lineage, other],
          do: assert({:ok, _} = call(ctx, each, "open", %{"url" => "https://example.com/"}))

      set_status(turn, "completed")
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert {:ok, 1} = Threads.archive_idle(Sanctum.Context.actor(ctx), future)

      assert_receive {:driver, :req, _s, %{"op" => "close", "win" => ^win}}, 5_000
      assert {:ok, _} = call(ctx, other, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read"}}, 5_000
      refute_received {:driver, :req, _s, %{"op" => "close"}}
      assert :sys.get_state(holder(ctx)).windows == MapSet.new([other["thread_id"]])
    end

    test "a crew member's window is closed when its room is archived, and a thread's window " <>
           "when the person deletes the thread",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      actor = Sanctum.Context.actor(ctx)
      win = lineage["thread_id"]
      {:ok, room} = Arca.Test.Days.thread(actor)
      crew = crew!(ctx, room.id)
      crew_win = crew["thread_id"]

      for each <- [lineage, crew],
          do: assert({:ok, _} = call(ctx, each, "open", %{"url" => "https://example.com/"}))

      # The crew member's turn over, nothing works in the room or under it.
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.thread_id == ^crew_win),
          set: [status: "completed"]
        )

      assert {:ok, _} = Threads.archive(actor, room.id)
      assert_receive {:driver, :req, _s, %{"op" => "close", "win" => ^crew_win}}, 5_000
      eventually(fn -> :sys.get_state(holder(ctx)).windows == MapSet.new([win]) end, "the close")

      # Deleted by hand. (Its turn's root is this case's stand-in, which no
      # cancel could reach.)
      set_status(turn, "completed")
      assert {:ok, _} = Aqua.Tape.delete_thread(ctx, win)
      assert_receive {:driver, :req, _s, %{"op" => "close", "win" => ^win}}, 5_000
      eventually(fn -> :sys.get_state(holder(ctx)).windows == MapSet.new() end, "the close")
      refute_received {:driver, :req, _s, %{"op" => "close"}}
    end

    test "an archive whose announcement is read after new work took the thread out again " <>
           "closes nothing",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      actor = Sanctum.Context.actor(ctx)
      win = lineage["thread_id"]
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      set_status(turn, "completed")

      # The holder hears the archive only once the person's next post has
      # taken the thread out of the archive again.
      holder = holder(ctx)
      :ok = :sys.suspend(holder)
      assert {:ok, _} = Threads.archive(actor, win)

      eventually(
        fn ->
          {:messages, messages} = Process.info(holder, :messages)
          Enum.any?(messages, &match?(%Cyfr.Bus.ThreadListed{id: ^win, archived: true}, &1))
        end,
        "the archive's announcement to reach the holder"
      )

      {_next, next} = turn!(ctx, thread: %{id: win})
      assert {:ok, %{archived_at: nil}} = Threads.get(actor, win)
      :ok = :sys.resume(holder)

      # The holder takes its mailbox in order: the announcement, then this.
      assert {:ok, _} = call(ctx, next, "read")
      assert_receive {:driver, :req, _s, %{"op" => "read", "win" => ^win}}, 5_000
      refute_received {:driver, :req, _s, %{"op" => "close"}}
      assert :sys.get_state(holder).windows == MapSet.new([win])
    end
  end

  describe "the second Chrome" do
    # A workspace thread opened apart, a turn running in it, and the row of
    # the person's second browser beside their own.
    setup %{ctx: ctx} do
      room = workspace!(ctx, true)
      {_turn, apart} = turn!(ctx, thread: %{id: room})
      apart_row = browser_row!(ctx, %{name: Programs.Definition.browser_name(:apart)})
      {:ok, apart: apart, apart_row: apart_row}
    end

    test "a thread opened apart gets a window of the second Chrome, and never one of the person's",
         %{ctx: ctx, lineage: lineage, apart: apart} do
      win = apart["thread_id"]
      assert {:ok, _} = call(ctx, apart, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, apart_session, %{"op" => "open", "win" => ^win}}, 5_000
      assert running_rows(ctx) == ["aqua-browser-apart"]

      # The person's own thread opens in their Chrome, a session of its own.
      own = lineage["thread_id"]
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.org/"})
      assert_receive {:driver, :req, person_session, %{"op" => "open", "win" => ^own}}, 5_000
      refute person_session == apart_session

      # Every later action of the thread kept apart reaches the second alone.
      assert {:ok, _} = call(ctx, apart, "click", %{"ref" => "12"})
      assert_receive {:driver, :req, ^apart_session, %{"op" => "click", "win" => ^win}}, 5_000
      refute_received {:driver, :req, ^person_session, %{"win" => ^win}}
      refute_received {:driver, :req, ^apart_session, %{"win" => ^own}}

      assert Enum.sort(Opus.Browser.windows(ctx.athanor_id, ctx.user_id)) == Enum.sort([win, own])
      assert running_rows(ctx) == ["aqua-browser", "aqua-browser-apart"]
    end

    test "without the second browser's row, a thread opened apart is refused and the person's Chrome does not start",
         %{ctx: ctx, apart: apart, apart_row: apart_row} do
      {:ok, _} =
        Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), apart_row.name, %{
          id: apart_row.id,
          epoch: apart_row.epoch
        })

      assert refusal(call(ctx, apart, "open", %{"url" => "https://example.com/"})) ==
               "This thread's work is kept apart, in Aqua's second browser, which was not found. " <>
                 "The person adds it from the Aqua page, once."

      refute_received {:session, "open", _open, _fields}
      assert browser_sessions(ctx) == []

      assert {:ok, %{browser: "added", apart: "not_added"}} =
               Provider.handle("browser", ctx, %{"action" => "status"})
    end

    test "a crew member working under a thread opened apart has its window in the second Chrome alone",
         %{ctx: ctx} do
      crew = crew!(ctx, workspace!(ctx, true))
      assert {:ok, _} = call(ctx, crew, "open", %{"url" => "https://example.com/"})
      win = crew["thread_id"]
      assert_receive {:driver, :req, _session, %{"op" => "open", "win" => ^win}}, 5_000
      assert running_rows(ctx) == ["aqua-browser-apart"]
    end

    test "without the second browser's row, a crew member under a thread opened apart is refused as that thread is",
         %{ctx: ctx, apart: apart, apart_row: apart_row} do
      {:ok, _} =
        Arca.McpServerStorage.delete(Sanctum.Context.actor(ctx), apart_row.name, %{
          id: apart_row.id,
          epoch: apart_row.epoch
        })

      crew = crew!(ctx, workspace!(ctx, true))
      refused = refusal(call(ctx, crew, "open", %{"url" => "https://example.com/"}))
      assert refused == refusal(call(ctx, apart, "open", %{"url" => "https://example.com/"}))
      assert refused =~ "kept apart, in Aqua's second browser, which was not found"
      refute_received {:driver, :req, _session, %{"op" => "open"}}
      refute_received {:session, "open", _open, _fields}
      assert browser_sessions(ctx) == []
    end

    test "a crew member's thread whose workspace thread opened apart was removed is refused, and the person's Chrome does not start",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      room = workspace!(ctx, true)
      {:ok, _child} = Threads.crew_thread(actor, room, "planner")
      [opening] = Threads.messages(actor, room)

      {:ok, %{turn: own}} =
        TurnStorage.accept_message(actor, room, %{
          opening_id: opening.id,
          message: %{author: ctx.user_id, sent_by: "person", content: "look it up"},
          turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
        })

      set_status(own, "running")

      assert {:ok, %{workspace_state: "done"}} =
               TurnStorage.report_workspace(actor, own.id, "done", %{
                 fence: own.fence,
                 summary: "Done"
               })

      set_status(own, "completed")

      # The person speaks to the crew member directly after the work ended.
      crew = crew!(ctx, room)
      assert {:ok, _} = call(ctx, crew, "open", %{"url" => "https://example.com/"})
      assert running_rows(ctx) == ["aqua-browser-apart"]

      # The workspace thread's row goes while the crew turn lives on: what
      # the browser reads when a deletion of the room commits between its
      # read of the crew member's thread and its read of the room.
      {1, _} = Arca.Repo.delete_all(from(c in Arca.Schemas.Thread, where: c.id == ^room))
      assert {:error, :not_found} = Threads.get(actor, room)
      assert {:ok, {_, _, _}} = Opus.Browser.turn(Opus.Browser.caller(guest(ctx), crew))

      assert refusal(call(ctx, crew, "open", %{"url" => "https://example.org/"})) ==
               "The browser's response is unavailable."

      assert running_rows(ctx) == ["aqua-browser-apart"]
      assert holder(ctx, :person) == nil
    end

    test "a window of a thread that is gone is refused, and no Chrome starts", %{ctx: ctx} do
      gone = Prima.UUID7.generate_id("thread")

      assert {:error, :unavailable} =
               Opus.Browser.watch(ctx, gone, %{width: 1280, height: 720}, fn -> {:ok, %{}} end)

      refute_received {:session, "open", _open, _fields}
      assert browser_sessions(ctx) == []
      assert holder(ctx, :person) == nil and holder(ctx, :apart) == nil
    end

    test "a workspace thread whose first row is not its opening is refused, and no Chrome starts",
         %{ctx: ctx} do
      bare =
        %Arca.Schemas.Thread{}
        |> Arca.Schemas.Thread.changeset(%{
          id: Prima.UUID7.generate_id("thread"),
          athanor_id: ctx.athanor_id,
          kind: "workspace",
          workspace_state: "open",
          title: "No opening",
          created_by: ctx.user_id
        })
        |> Arca.Repo.insert!()

      {_turn, lineage} = turn!(ctx, thread: bare)

      assert refusal(call(ctx, lineage, "open", %{"url" => "https://example.com/"})) ==
               "The browser's response is unavailable."

      refute_received {:session, "open", _open, _fields}
      assert browser_sessions(ctx) == []
    end

    test "the person watches a window kept apart and acts in it, in the second Chrome",
         %{ctx: ctx, driver: driver, apart: apart} do
      win = apart["thread_id"]
      assert {:ok, _} = call(ctx, apart, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, apart_session, %{"op" => "open", "win" => ^win}}, 5_000
      watch = watch!(ctx, win, %{width: 390, height: 844})

      assert_receive {:driver, :req, ^apart_session,
                      %{"op" => "cast", "id" => cast, "win" => ^win}},
                     5_000

      image = jpeg()
      :ok = Driver.image(driver, cast, 1, image)
      assert_receive {Opus.Browser, _ref, {:image, 1, %Programs.Output{bytes: ^image}}}, 5_000
      :ok = Opus.Browser.seen(watch, 1)
      assert_receive {:driver, :seen, ^apart_session, ^cast, 1}, 5_000

      events = [
        %{
          "k" => "mouse",
          "type" => "down",
          "x" => 0.25,
          "y" => 0.5,
          "button" => "left",
          "clicks" => 1,
          "mods" => 0
        }
      ]

      assert :ok = Opus.Browser.input(watch, events)
      assert_receive {:driver, :input, ^apart_session, ^cast, ^events}, 5_000
      assert running_rows(ctx) == ["aqua-browser-apart"]
    end

    test "a page put into a window kept apart is handed to the second Chrome, and its call is answered there",
         %{ctx: ctx, driver: driver, apart: apart} do
      on_exit(&restart_page_calls/0)
      :ok = Supervisor.terminate_child(Aqua.Supervisor, Aqua.PageCalls)
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.page_calls())
      win = apart["thread_id"]

      assert {:ok, _} = call(ctx, apart, "page", %{"html" => "<p>hello</p>"})
      assert_receive {:driver, :put, apart_session, %{"id" => put}, _bytes}, 5_000
      assert running_rows(ctx) == ["aqua-browser-apart"]

      :ok = Driver.call(driver, apart_session, 3, win, put, "invoke", ~s({"v":1}))
      assert_receive %PageCall{kind: :call, thread_id: ^win, request: request}, 5_000

      # Its holder is the second Chrome's, which whoever holds the call monitors.
      holder = holder(ctx, :apart)
      assert {:ok, ^holder} = Opus.Browser.held(ctx.athanor_id, ctx.user_id, request, self())
      assert :ok = Opus.Browser.answer(ctx.athanor_id, ctx.user_id, request, 200, ~s({"v":1}))
      assert_receive {:driver, :answer, ^apart_session, 3, 200, ~s({"v":1})}, 5_000
      assert holder(ctx, :person) == nil
    end

    test "the browser setting turning off closes both Chromes, and the second stops at its own idle time",
         %{ctx: ctx, lineage: lineage, row: row, apart: apart, apart_row: apart_row} do
      assert {:ok, _} = call(ctx, apart, "open", %{"url" => "https://example.com/"})
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.org/"})
      person_session = session_of(ctx, row)
      apart_session = session_of(ctx, apart_row)

      # The second's idle stop ends it alone.
      holder = holder(ctx, :apart)
      :sys.replace_state(holder, &%{&1 | last_act: &1.last_act - 86_400_000})
      {_timer, token} = :sys.get_state(holder).idle
      send(holder, {:idle, token})

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^apart_session, reason: :closed},
                     5_000

      eventually(fn -> holder(ctx, :apart) == nil end, "the second's holder to stop")
      assert [%{session: ^person_session}] = browser_sessions(ctx)

      # Opened again, both close when the setting goes off.
      assert {:ok, _} = call(ctx, apart, "open", %{"url" => "https://example.com/"})
      apart_session = session_of(ctx, apart_row)
      assert {:ok, %{on: false}} = Provider.handle("browser", ctx, %{"action" => "turn_off"})

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^person_session, reason: :closed},
                     5_000

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^apart_session, reason: :closed},
                     5_000

      assert browser_sessions(ctx) == []

      eventually(
        fn -> holder(ctx, :apart) == nil and holder(ctx, :person) == nil end,
        "both holders to stop"
      )

      assert refusal(call(ctx, apart, "open", %{"url" => "https://example.com/"})) ==
               "The browser is turned off."
    end
  end

  describe "the person's watch" do
    test "a window's images go to the page that asked, one at a time, the driver told only once each was drawn",
         %{ctx: ctx, driver: driver, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      win = lineage["thread_id"]
      watch = watch!(ctx, win, %{width: 390, height: 844})

      assert_receive {:driver, :req, _session,
                      %{"op" => "cast", "id" => cast, "win" => ^win, "args" => args}},
                     5_000

      assert args == %{"width" => 390, "height" => 844}

      first = jpeg()
      :ok = Driver.image(driver, cast, 1, first)
      assert_receive {Opus.Browser, _ref, {:image, 1, %Programs.Output{bytes: ^first}}}, 5_000
      refute_receive {:driver, :seen, _s, ^cast, _seq}, 200

      :ok = Opus.Browser.seen(watch, 1)
      assert_receive {:driver, :seen, _s, ^cast, 1}, 5_000

      second = jpeg()
      :ok = Driver.image(driver, cast, 2, second)
      assert_receive {Opus.Browser, _ref, {:image, 2, %Programs.Output{bytes: ^second}}}, 5_000

      # A stale acknowledgement, of the first again, tells the driver nothing.
      :ok = Opus.Browser.seen(watch, 1)
      refute_receive {:driver, :seen, _s, ^cast, _seq}, 200
    end

    test "a viewer that does not say it drew an image is handed no further one, and an action's response arrives whole beside it",
         %{ctx: ctx, driver: driver, lineage: lineage} = context do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      _watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000

      :ok = Driver.image(driver, cast, 1, jpeg())
      assert_receive {Opus.Browser, _ref, {:image, 1, _first}}, 5_000

      # A driver that sends past the one unacknowledged image has it held,
      # not handed; the newest replaces the one held before it.
      :ok = Driver.image(driver, cast, 2, jpeg())
      :ok = Driver.image(driver, cast, 3, jpeg())

      text = :crypto.strong_rand_bytes(600_000) |> Base.encode64()
      answers(context, "read", {:ok, %{"text" => text}})

      assert {:ok, %{"text" => ^text}} =
               Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
                 {:ok, %{}}
               end)

      refute_received {Opus.Browser, _ref, {:image, _n, _held}}
      refute_received {:driver, :seen, _s, _cast, _seq}
      assert {_cast, 3, %Programs.Output{}} = only_watch(ctx).held
    end

    test "a second workspace thread's page receives nothing of the first's window",
         %{ctx: ctx, driver: driver, lineage: lineage} do
      {_other_turn, other} = turn!(ctx)
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert {:ok, _} = call(ctx, other, "open", %{"url" => "https://example.org/"})

      _mine = watch!(ctx, lineage["thread_id"])
      mine_win = lineage["thread_id"]

      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => mine, "win" => ^mine_win}},
                     5_000

      theirs = viewer(ctx, other["thread_id"])
      other_win = other["thread_id"]

      assert_receive {:driver, :req, _s,
                      %{"op" => "cast", "id" => their_cast, "win" => ^other_win}},
                     5_000

      shown = jpeg()
      :ok = Driver.image(driver, mine, 1, shown)
      assert_receive {Opus.Browser, _ref, {:image, 1, %Programs.Output{bytes: ^shown}}}, 5_000
      refute_receive {:viewer, ^theirs, {:image, _n, _image}}, 200

      theirs_shown = jpeg()
      :ok = Driver.image(driver, their_cast, 1, theirs_shown)

      assert_receive {:viewer, ^theirs, {:image, 1, %Programs.Output{bytes: ^theirs_shown}}},
                     5_000

      refute_received {Opus.Browser, _ref, {:image, _n, _theirs}}
    end

    test "a turn's, a component's or a key's watch is refused; the person is proved at a screen",
         %{ctx: ctx, lineage: lineage} do
      key = %{guest(ctx) | auth_method: :api_key, api_key_id: "key_1"}
      size = %{width: 1280, height: 720}

      for caller <- [guest(ctx), key],
          do:
            assert(
              {:error, :not_owned} =
                Opus.Browser.watch(caller, lineage["thread_id"], size, fn -> {:ok, %{}} end)
            )

      assert {:error, :not_owned} =
               Opus.Browser.watch(ctx, lineage["thread_id"], %{width: 1280, height: 9000}, fn ->
                 {:ok, %{}}
               end)

      refute_received {:session, "open", _open, _fields}
      assert holder(ctx) == nil
    end

    test "it opens with no turn running, starting the browser when none runs",
         %{ctx: ctx, turn: turn, lineage: lineage} do
      win = lineage["thread_id"]
      set_status(turn, "completed")
      :ok = Programs.end_turn(ctx.athanor_id, turn.id)
      assert holder(ctx) == nil

      _watch = watch!(ctx, win)
      assert_receive {:driver, :opened, session}, 5_000
      assert_receive {:driver, :req, ^session, %{"op" => "cast", "win" => ^win}}, 5_000
      assert [%{by: :browser}] = browser_sessions(ctx)
    end

    test "it goes on after the turn that started the browser ended",
         %{ctx: ctx, driver: driver, turn: turn, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      [%{session: session}] = browser_sessions(ctx)
      set_status(turn, "completed")
      :ok = Programs.end_turn(ctx.athanor_id, turn.id)

      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000
      :ok = Driver.image(driver, cast, 1, jpeg())
      assert_receive {Opus.Browser, _ref, {:image, 1, _image}}, 5_000
      :ok = Opus.Browser.seen(watch, 1)
      assert_receive {:driver, :seen, _s, ^cast, 1}, 5_000
      assert [%{session: ^session}] = browser_sessions(ctx)
    end

    test "a window that does not stand waits, and its cast is asked again once an action opens it",
         %{ctx: ctx, driver: driver, lineage: lineage} = context do
      win = lineage["thread_id"]

      answers(
        context,
        "cast",
        {:error, "no_window", "There is no browser window for this thread; open a page first."}
      )

      _watch = watch!(ctx, win)
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => first}}, 5_000
      assert_receive {Opus.Browser, _ref, :waiting}, 5_000

      answers(context, "cast", {:ok, %{}})
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => again, "win" => ^win}}, 5_000
      assert again != first

      # The driver ended the cast, its window closed: it waits again.
      :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "uncast", "id" => again}))
      assert_receive {Opus.Browser, _ref, :waiting}, 5_000
      :ok = Driver.image(driver, again, 1, jpeg())
      refute_receive {Opus.Browser, _ref, {:image, _n, _image}}, 200
    end

    test "the person's input reaches the window they watch and no other, beside an action of Aqua's that holds it",
         %{ctx: ctx, lineage: lineage} = context do
      {_other_turn, other} = turn!(ctx)
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      assert {:ok, _} = call(ctx, other, "open", %{"url" => "https://example.org/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000

      answers(context, "read", :hold)
      read = Task.async(fn -> call(ctx, lineage, "read") end)
      assert_receive {:driver, :holding, _s, held}, 5_000

      events = [
        %{
          "k" => "mouse",
          "type" => "down",
          "x" => 0.25,
          "y" => 0.5,
          "button" => "left",
          "clicks" => 1,
          "mods" => 0
        },
        %{
          "k" => "key",
          "type" => "down",
          "key" => "a",
          "code" => "KeyA",
          "text" => "a",
          "vk" => 65,
          "mods" => 0
        }
      ]

      assert :ok = Opus.Browser.input(watch, events)
      assert_receive {:driver, :input, _s, ^cast, ^events}, 5_000

      :ok = Driver.release(context.driver, held)
      assert {:ok, _} = Task.await(read, 5_000)
    end

    test "input that does not read is refused, and input from a page with no watch standing is dropped",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000

      move = %{
        "k" => "mouse",
        "type" => "move",
        "x" => 0.5,
        "y" => 0.5,
        "button" => "none",
        "clicks" => 0,
        "mods" => 0
      }

      assert {:error, :bad_input} = Opus.Browser.input(watch, [%{move | "x" => 1.5}])
      assert {:error, :bad_input} = Opus.Browser.input(watch, List.duplicate(move, 65))

      # Another process with the watch's handle is not its viewer.
      Task.await(Task.async(fn -> Opus.Browser.input(watch, [move]) end))
      refute_receive {:driver, :input, _s, _cast, _events}, 200

      :ok = Opus.Browser.unwatch(watch)
      assert_receive {:driver, :uncast, _s, _cast}, 5_000
      :ok = Opus.Browser.input(watch, [move])
      refute_receive {:driver, :input, _s, _cast, _events}, 200
    end

    test "input waiting for the writer when its watch ends is not written",
         %{fake: fake, ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000

      move = %{
        "k" => "mouse",
        "type" => "move",
        "x" => 0.5,
        "y" => 0.5,
        "button" => "none",
        "clicks" => 0,
        "mods" => 0
      }

      Scripted.hold(fake, "input", 30_000)
      first = Task.async(fn -> call(ctx, lineage, "read") end)
      assert_receive {:held, "input", held}, 5_000

      :ok = Opus.Browser.input(watch, [move])
      eventually(fn -> only_watch(ctx).writing end, "the input to wait for the writer")
      :ok = Opus.Browser.unwatch(watch)
      eventually(fn -> :sys.get_state(holder(ctx)).watches == %{} end, "the watch to end")
      send(held, :go)

      assert {:ok, _} = Task.await(first, 10_000)
      assert_receive {:driver, :uncast, _s, _cast}, 5_000
      refute_received {:driver, :input, _s, _cast, _events}
    end

    test "a cast waiting for the writer when its watch ends is not written, and one not answered in time ends its watch",
         %{fake: fake, ctx: ctx, lineage: lineage} = context do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})

      Scripted.hold(fake, "input", 30_000)
      first = Task.async(fn -> call(ctx, lineage, "read") end)
      assert_receive {:held, "input", held}, 5_000

      watch = watch!(ctx, lineage["thread_id"])

      eventually(
        fn -> map_size(:sys.get_state(holder(ctx)).pending) == 2 end,
        "the cast to wait for the writer"
      )

      :ok = Opus.Browser.unwatch(watch)
      eventually(fn -> :sys.get_state(holder(ctx)).watches == %{} end, "the watch to end")
      send(held, :go)

      assert {:ok, _} = Task.await(first, 10_000)
      assert_receive {:driver, :uncast, _s, _cast}, 5_000
      refute_received {:driver, :req, _s, %{"op" => "cast"}}

      answers(context, "cast", :hold)
      _watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :holding, _s, cast}, 5_000
      send(holder(ctx), {:expired, cast})
      assert_receive {Opus.Browser, _ref, {:ended, :unavailable}}, 5_000
      assert_receive {:driver, :uncast, _s, ^cast}, 5_000
    end

    test "a holder that dies with a watch open takes the session with it", %{
      ctx: ctx,
      lineage: lineage
    } do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      _watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000
      holder = holder(ctx)
      [%{session: session}] = browser_sessions(ctx)
      monitor = Process.monitor(holder)

      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 5_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^session, reason: :closed}, 5_000
    end

    test "a watch ends with its page, with a newer watch of its window, and when the setting goes off; a late image goes nowhere",
         %{ctx: ctx, driver: driver, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      win = lineage["thread_id"]

      page = viewer(ctx, win)
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => gone_cast}}, 5_000
      Process.exit(page, :kill)
      assert_receive {:driver, :uncast, _s, ^gone_cast}, 5_000
      :ok = Driver.image(driver, gone_cast, 1, jpeg())

      older = watch!(ctx, win)
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => older_cast}}, 5_000
      newer = viewer(ctx, win)
      assert_receive {Opus.Browser, _ref, {:ended, :replaced}}, 5_000
      assert_receive {:driver, :uncast, _s, ^older_cast}, 5_000
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => newer_cast}}, 5_000
      :ok = Opus.Browser.seen(older, 1)
      refute_receive {:driver, :seen, _s, _cast, _seq}, 200
      :ok = Driver.image(driver, older_cast, 1, jpeg())
      refute_receive {Opus.Browser, _ref, {:image, _n, _late}}, 200

      :ok = Driver.image(driver, newer_cast, 1, jpeg())
      assert_receive {:viewer, ^newer, {:image, 1, _image}}, 5_000

      assert {:ok, %{on: false}} = Provider.handle("browser", ctx, %{"action" => "turn_off"})
      assert_receive {:viewer, ^newer, {:ended, :turned_off}}, 5_000
      eventually(fn -> holder(ctx) == nil end, "the holder to stop")
      refute_received {:viewer, _page, {:image, _n, _late}}
    end

    test "an open watch keeps the browser from its idle stop", %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000
      holder = holder(ctx)
      eventually(fn -> :sys.get_state(holder).pending == %{} end, "the cast to be answered")

      # Nothing waits, and long past the idle time, yet no idle stop is armed,
      # and one that comes finds the watch and stops nothing.
      :sys.replace_state(holder, &%{&1 | last_act: &1.last_act - 86_400_000})
      assert :sys.get_state(holder).idle == nil
      token = make_ref()
      :sys.replace_state(holder, &%{&1 | idle: {make_ref(), token}})
      send(holder, {:idle, token})
      # sleep-ok: 100 ms after the idle message in which the holder must stop nothing
      Process.sleep(100)
      assert [_running] = browser_sessions(ctx)
      assert Process.alive?(holder)

      :ok = Opus.Browser.unwatch(watch)

      eventually(
        fn -> :sys.get_state(holder).idle != nil end,
        "the idle clock to run once it ended"
      )
    end

    test "after a tail an image lost to it is never shown, the response cut by it is asked again, an image whole in it is shown, and the cast goes on anew",
         %{ctx: ctx, driver: driver, lineage: lineage} = context do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      _watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000

      text = :crypto.strong_rand_bytes(150_000) |> Base.encode64()
      answers(context, "read", :hold)

      task =
        Task.async(fn ->
          Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn ->
            {:ok, %{}}
          end)
        end)

      assert_receive {:driver, :holding, _session, id}, 5_000

      # The holder takes nothing while the driver pours out an image, the
      # whole answer and a second image: the last 256 KiB of it arrive as
      # the tail. The answer's frames alone are more than that, so the
      # first image is lost whole and the cut falls inside the answer.
      holder = holder(ctx)
      :sys.suspend(holder)
      :ok = Driver.write(driver, Opus.Browser.Frame.message(%{"t" => "noise"}))
      eventually(fn -> outstanding?(ctx) end, "a delivery outstanding")

      lost = :crypto.strong_rand_bytes(90_000)
      whole = jpeg()
      :ok = Driver.image(driver, cast, 1, lost)
      answers(context, "read", {:ok, %{"text" => text}})
      :ok = Driver.flood(driver)
      :ok = Driver.release(driver, id)
      :ok = Driver.image(driver, cast, 2, whole)

      # The terminal lets some go as soon as the answer passes what it
      # keeps, which may be a read before it has the second image: the
      # holder is let on only once the tail ends with that image, or it
      # would meet it after the cast it belongs to had ended.
      eventually(
        fn -> tail_ends_with?(ctx, Driver.image_frame(cast, 2, whole)) end,
        "the tail to end with the second image"
      )

      :sys.resume(holder)

      assert {:ok, %{"text" => ^text}} = Task.await(task, 20_000)
      assert_receive {:driver, :again, _session, ^id, _seq}, 5_000
      assert_receive {:driver, :uncast, _s, ^cast}, 5_000
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => anew}}, 5_000

      assert_receive {Opus.Browser, _ref, {:image, 1, %Programs.Output{bytes: ^whole}}}, 5_000
      refute_received {Opus.Browser, _ref, {:image, _n, %Programs.Output{bytes: ^lost}}}

      # The old cast's images go nowhere; the new cast's are handed once
      # the last was drawn.
      :ok = Driver.image(driver, cast, 3, jpeg())
      next = jpeg()
      :ok = Opus.Browser.seen(only_watch_handle(ctx), 1)
      :ok = Driver.image(driver, anew, 1, next)
      assert_receive {Opus.Browser, _ref, {:image, 2, %Programs.Output{bytes: ^next}}}, 5_000
      refute_received {Opus.Browser, _ref, {:image, _n, _old}}
    end

    test "an image the viewer is handed and what the person types are in no status or debug log of the holder",
         %{ctx: ctx, driver: driver, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000
      holder = holder(ctx)
      :ok = :sys.log(holder, true)

      shown = "shown-#{System.unique_integer([:positive])}-private"
      typed = "t#{rem(System.unique_integer([:positive]), 1_000_000)}"
      :ok = Driver.image(driver, cast, 1, shown)
      assert_receive {Opus.Browser, _ref, {:image, 1, _image}}, 5_000
      :ok = Driver.image(driver, cast, 2, shown)

      key = %{
        "k" => "key",
        "type" => "down",
        "key" => typed,
        "code" => "",
        "text" => typed,
        "vk" => 0,
        "mods" => 0
      }

      :ok = Opus.Browser.input(watch, [key])
      assert_receive {:driver, :input, _s, ^cast, _events}, 5_000

      status = inspect(:sys.get_status(holder), limit: :infinity, printable_limit: :infinity)
      :ok = :sys.log(holder, false)
      refute status =~ shown
      refute status =~ Base.encode64(shown)
      refute status =~ typed
    end
  end

  describe "the watch's review, round one" do
    # Finding 2: a watch asked of a holder that answers only after its
    # caller stopped waiting is admitted for no one.
    test "a watch whose caller stopped waiting is not admitted, and no cast is asked for it",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      pid = holder(ctx)
      :ok = :sys.suspend(pid)

      result =
        try do
          Opus.Browser.watch(ctx, lineage["thread_id"], %{width: 1280, height: 720}, fn ->
            {:ok, %{}}
          end)
        after
          :sys.resume(pid)
        end

      assert result == {:error, :unavailable}
      refute_receive {:driver, :req, _s, %{"op" => "cast"}}, 500
      assert :sys.get_state(pid).watches == %{}
      refute_received {Opus.Browser, _watch, :watching}
    end

    # Finding 3: input is bounded where it enters: one batch of a watch's
    # on its way to the holder, the next only once the holder took it.
    test "a viewer hands one batch of input at a time; the rest is dropped, never queued",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      watch = watch!(ctx, lineage["thread_id"])
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000
      pid = holder(ctx)

      move = %{
        "k" => "mouse",
        "type" => "move",
        "x" => 0.5,
        "y" => 0.5,
        "button" => "none",
        "clicks" => 0,
        "mods" => 0
      }

      :ok = :sys.suspend(pid)

      {results, waiting} =
        try do
          results = for _ <- 1..500, do: Opus.Browser.input(watch, List.duplicate(move, 64))
          {:messages, messages} = Process.info(pid, :messages)

          waiting =
            Enum.sum(
              for {:"$gen_cast", {:input, _ref, _viewer, events}} <- messages,
                  do: length(events)
            )

          {results, waiting}
        after
          :sys.resume(pid)
        end

      assert waiting <= Opus.Browser.Input.max_events()
      assert Enum.frequencies(results) == %{:ok => 1, {:error, :busy} => 499}

      assert_receive {Opus.Browser, ^watch, :input_taken}, 5_000
      :ok = Opus.Browser.input_taken(watch)
      assert :ok = Opus.Browser.input(watch, [move])
    end
  end

  describe "browser.watch" do
    test "the person watches a workspace thread of their own from the process that asked, starting the browser",
         %{ctx: ctx} do
      work = workspace!(ctx)
      args = %{"action" => "watch", "thread" => work, "width" => 390, "height" => 390}

      assert {:ok, %{watching: ^work}} = Sanctum.Gate.call_external("browser", ctx, args)
      assert_receive {Opus.Browser, _watch, :watching}, 5_000
      assert_receive {:driver, :opened, session}, 5_000

      assert_receive {:driver, :req, ^session,
                      %{
                        "op" => "cast",
                        "win" => ^work,
                        "args" => %{"width" => 390, "height" => 390}
                      }},
                     5_000
    end

    test "a thread that is no workspace thread of the person's is not found, and nothing starts",
         %{ctx: ctx, lineage: lineage} do
      {other, _user} = person!("watch-elsewhere")
      browser_row!(other)
      theirs = workspace!(other)

      for thread <- [lineage["thread_id"], theirs, "thr_none"] do
        assert {:error, {:not_found, "thread", ^thread}} =
                 Provider.handle("browser", ctx, %{
                   "action" => "watch",
                   "thread" => thread,
                   "width" => 640,
                   "height" => 640
                 })
      end

      refute_received {Opus.Browser, _watch, _message}
      assert holder(ctx) == nil
    end

    test "while the setting is off it is refused with the turned-off sentence and starts no browser",
         %{ctx: ctx} do
      work = workspace!(ctx)
      assert {:ok, false} = Aqua.BrowserSetting.put(ctx, false)

      assert refusal(
               Provider.handle("browser", ctx, %{
                 "action" => "watch",
                 "thread" => work,
                 "width" => 640,
                 "height" => 640
               })
             ) == Provider.turned_off()

      refute_received {:session, "open", _open, _fields}
      assert holder(ctx) == nil
    end

    test "a key, a turn or a component reaches no watch, and the console's plane alone offers it",
         %{ctx: ctx, lineage: lineage} do
      work = workspace!(ctx)
      key = %{guest(ctx) | auth_method: :api_key, api_key_id: "key_1"}
      args = %{"action" => "watch", "thread" => work, "width" => 640, "height" => 640}

      for caller <- [key, guest(ctx)] do
        assert refusal(Provider.handle("browser", caller, Map.merge(args, lineage))) ==
                 "Aqua's browser shows only on a page of yours in CYFR."
      end

      [watch] = for %{action: "watch"} = op <- Provider.definition().operations, do: op
      assert watch.planes == [:external] and watch.consent == :interactive and watch.kind == :read
      refute_received {Opus.Browser, _watch, _message}
      assert holder(ctx) == nil
    end
  end

  # Review round two, finding 8: a watch is a page's alone.
  describe "a watch from no page" do
    test "a paired device's call is refused, admits no watch and starts nothing", %{ctx: ctx} do
      work = workspace!(ctx)
      paired = Sanctum.Test.Devices.paired!(ctx.user_id, "127.0.0.1")
      channel = Emissary.Web.DeviceChannel
      peer = %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}
      {:ok, state} = channel.connect(%{connect_info: %{peer_data: peer}})
      {:ok, state} = channel.init(state)

      send_frame = fn state, message ->
        channel.handle_in({Jason.encode!(Prima.Device.encode(message)), [opcode: :text]}, state)
      end

      {:reply, :ok, {:text, json}, state} =
        send_frame.(
          state,
          {:connect, %{client_id: paired.client_id, certificate: paired.certificate}}
        )

      {:ok, {:challenge, %{challenge: challenge}}} =
        Prima.Device.decode(Jason.decode!(json), :home)

      {_public, private} = paired.key
      proof = Prima.DeviceCert.Proof.sign(challenge, private)
      {:push, [_standing], state} = send_frame.(state, {:proof, %{proof: proof}})

      intent =
        {:intent,
         %{
           id: "watch-from-a-device",
           operation: "browser.watch",
           args: %{"thread" => work, "width" => 640, "height" => 640}
         }}

      {:reply, :ok, {:text, answer}, _state} = send_frame.(state, intent)
      answer = Jason.decode!(answer)
      assert %{"type" => "answer", "id" => "watch-from-a-device", "error" => _refused} = answer
      refute Map.has_key?(answer, "result")

      refute_receive {Opus.Browser, _watch, _message}, 200
      refute_received {:driver, :req, _session, %{"op" => "cast"}}
      refute_received {:session, "open", _open, _fields}
      assert holder(ctx) == nil
    end

    test "the command line's call is refused and starts nothing; the page's is admitted",
         %{ctx: ctx} do
      work = workspace!(ctx)
      args = %{"action" => "watch", "thread" => work, "width" => 640, "height" => 640}

      for path <- [:api, :mcp, nil] do
        assert refusal(
                 Sanctum.Gate.call_external("browser", Sanctum.TestContext.via(ctx, path), args)
               ) ==
                 "Aqua's browser shows only on a page of yours in CYFR."
      end

      refute_receive {Opus.Browser, _watch, _message}, 200
      refute_received {:session, "open", _open, _fields}
      assert holder(ctx) == nil

      assert {:ok, %{watching: ^work}} = Sanctum.Gate.call_external("browser", ctx, args)
      assert_receive {Opus.Browser, _watch, :watching}, 5_000
      assert_receive {:driver, :req, _session, %{"op" => "cast", "win" => ^work}}, 5_000
    end
  end

  defp restart_page_calls do
    case Supervisor.restart_child(Aqua.Supervisor, Aqua.PageCalls) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  # A workspace thread of the person's, opened from a post of their day.
  defp workspace!(ctx, apart \\ false) do
    ctx = %{ctx | origin: :interactive}
    actor = Sanctum.Context.actor(ctx)
    {:ok, daily} = Aqua.Day.current(ctx)

    {:ok, %{message: asked}} =
      TurnStorage.accept_message(actor, daily.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "please look it up"}
      })

    {:ok, %{workspace: id}} =
      Aqua.Providers.Workspace.handle("workspace", ctx, %{
        "action" => "open",
        "thread" => daily.id,
        "refs" => [asked.id],
        "title" => "Look it up",
        "ask" => "Look it up",
        "apart" => apart
      })

    id
  end

  defp watch!(ctx, window, size \\ %{width: 1280, height: 720}) do
    assert {:ok, watch} = Opus.Browser.watch(ctx, window, size, fn -> {:ok, %{}} end)
    watch
  end

  # The path of the address a page of `name` is laid out under in the
  # person's athanor.
  defp root(ctx, name) do
    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(ctx.athanor_id)
    Prima.TinctureUrl.path(Sanctum.Tenancy.Athanors.route_slug(athanor), "local", name)
  end

  # A plain page's entry as it is handed over under `nonce`.
  defp plain_handed(document, base, nonce),
    do: Compendium.tincture_head_tags(Compendium.plain_entry(document), base, nonce)

  # The entry at the head of a put's bytes, up to the end of `document`.
  defp handed_entry(bytes, document) do
    [entry, _rest] = :binary.split(bytes, document)
    entry <> document
  end

  defp nonce_of(entry) do
    [_, nonce] = Regex.run(~r/<script nonce="([^"]+)">/, entry)
    nonce
  end

  defp without_nonce(html),
    do: Regex.replace(~r/<script nonce="[^"]+">/, html, ~s(<script nonce="">))

  defp split(_bytes, []), do: []

  defp split(bytes, [size | sizes]) do
    <<part::binary-size(^size), rest::binary>> = bytes
    [part | split(rest, sizes)]
  end

  # A local tincture version laid in the athanor's tree and registered, as
  # publishing it would: its unit and its manifest.
  defp tincture!(ctx, name, tincture, files) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "description" => name,
      "tincture" => tincture
    }

    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, "1.0.0",
        manifest: manifest,
        files: files
      )

    {:ok, _registered} = Compendium.Registry.register_from_arca(ctx, unit)
    {unit, manifest}
  end

  # A page watching `window` in a process of its own, which tells the test
  # each message of its watch as `{:viewer, pid, message}`.
  defp viewer(ctx, window) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _watch} =
          Opus.Browser.watch(ctx, window, %{width: 1280, height: 720}, fn -> {:ok, %{}} end)

        send(test, {:watching, self()})
        forward(test)
      end)

    assert_receive {:watching, ^pid}, 5_000
    pid
  end

  defp forward(test) do
    receive do
      {Opus.Browser, _ref, message} -> send(test, {:viewer, self(), message})
    end

    forward(test)
  end

  defp only_watch(ctx) do
    [watch] = Map.values(:sys.get_state(holder(ctx)).watches)
    watch
  end

  defp only_watch_handle(ctx), do: {holder(ctx), only_watch(ctx).ref}

  defp jpeg, do: <<0xFF, 0xD8>> <> :crypto.strong_rand_bytes(2_000) <> <<0xFF, 0xD9>>

  # Whether the browser's terminal holds a delivery its holder has not
  # taken, and whether it let some of what came meanwhile go.
  defp outstanding?(ctx), do: Enum.any?(subscribers(ctx), &(&1.outstanding != nil))
  defp lost?(ctx), do: Enum.any?(subscribers(ctx), & &1.lost)

  # Whether what the terminal keeps for its holder is a tail, and `frame`
  # the last of it. Read from the terminal's own state: no caller can see
  # what it keeps for a holder that takes nothing.
  defp tail_ends_with?(ctx, frame) do
    Enum.any?(subscribers(ctx), fn subscriber ->
      subscriber.lost and subscriber.pending != nil and
        String.ends_with?(subscriber.pending.bytes, frame)
    end)
  end

  defp subscribers(ctx) do
    case browser_sessions(ctx) do
      [%{session: session}] ->
        [{pid, _}] = Registry.lookup(Opus.Programs.Registry, {:terminal, session})
        Map.values(:sys.get_state(pid).subscribers)

      _none ->
        []
    end
  end

  defp mailbox(pid) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)
    length
  end

  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
