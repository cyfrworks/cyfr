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
  longer holds is refused.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Aqua.Providers.Browser, as: Provider
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedDriver, as: Driver
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)

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

    ctx = %{
      Sanctum.TestContext.local()
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
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
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

  defp call(ctx, lineage, action, args \\ %{}),
    do:
      Provider.handle("browser", guest(ctx), Map.merge(args, Map.put(lineage, "action", action)))

  defp holder(ctx) do
    case Registry.lookup(Opus.Browser.Registry, {ctx.athanor_id, ctx.user_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp browser_sessions(ctx) do
    {:ok, sessions} = Programs.running(ctx)
    Enum.filter(sessions, &(&1.by == :browser))
  end

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for #{what}")

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

  # A turn's `open` of `url`, with the sources its result closes with
  # joined into the turn, as the loop joins them when the step closes.
  defp opened!(ctx, turn, lineage, url) do
    {:ok, answer} = call(ctx, lineage, "open", %{"url" => url})
    {:ok, turn} = Aqua.Tape.turn(ctx, turn.id)
    :ok = Aqua.Tape.join_sources(ctx, turn, Provider.answer_sources(nil, answer))
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

    test "click, type, key, page and close reach the driver with their own arguments",
         %{ctx: ctx, lineage: lineage} do
      win = lineage["thread_id"]
      assert {:ok, _} = call(ctx, lineage, "page", %{"html" => "<p>hello</p>"})

      assert_receive {:driver, :req, _s,
                      %{"op" => "page", "args" => %{"html" => "<p>hello</p>"}}},
                     5_000

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

      # The page was asked for at one address and landed at another.
      answers(
        context,
        "open",
        {:ok, %{"url" => "https://moon.example/landed", "title" => "Moon"}}
      )

      {:ok, png: png}
    end

    test "is the post's own file, carrying the outside source of the page it shows; the draft goes and posts once",
         %{ctx: ctx, turn: turn, lineage: lineage, png: png} do
      opened!(ctx, turn, lineage, "https://moon.example/")
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      thread_id = lineage["thread_id"]

      assert {:ok, %{posted: post_id, thread: ^thread_id, files: 1}} =
               post(ctx, lineage, %{"text" => "The moon", "screenshot" => shot})

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), post_id)

      assert [%{"filename" => "screenshot.png", "media_type" => "image/png"} = ref] =
               Aqua.Attachments.refs_of(row)

      # The landing page's host, never the asked-for address, and the
      # screenshot's own outside source.
      assert Prima.Source.outside("moon.example") in Aqua.Attachments.copied_sources(ref)
      assert Prima.Source.outside("browser") in Aqua.Attachments.copied_sources(ref)

      # Readable from the post alone.
      data = Base.encode64(png)

      assert [%{"data" => ^data}] =
               Aqua.Attachments.load(ctx, thread_id, [%{message_id: post_id, ref: ref}])

      # The draft's bytes went; the post kept its copy.
      assert gone?(ctx, thread_id, shot)
      assert post(ctx, lineage, %{"screenshot" => shot}) |> refusal() == not_a_draft()
      assert [_one] = posts(ctx, thread_id)
    end

    test "of an earlier page keeps an outside source with no name of a host",
         %{ctx: ctx, lineage: lineage} do
      {:ok, %{message_id: shot}} = call(ctx, lineage, "screenshot")
      {:ok, %{posted: post_id}} = post(ctx, lineage, %{"screenshot" => shot})
      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), post_id)
      [ref] = Aqua.Attachments.refs_of(row)
      assert Aqua.Attachments.copied_sources(ref) == [Prima.Source.outside("browser")]
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

    test "a turn turns it off at once; turning it on is a call the person is asked about each time",
         %{ctx: ctx, lineage: lineage} do
      assert {:ok, %{on: false}} = call(ctx, lineage, "turn_off")
      assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)

      # Turning it on is never standing and never `auto`, so the turn's call
      # asks on a card each time; turning it off may run at once.
      assert Sanctum.Catalog.auto_permitted?("browser", "turn_on") == false
      assert Sanctum.Catalog.auto_permitted?("browser", "turn_off") == true

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
                 true
               end)
    end

    test "after a replacement tail it asks again from the first missing chunk, takes the answer whole and runs the action once",
         %{ctx: ctx, lineage: lineage, driver: driver} = context do
      assert {:ok, _} = call(ctx, lineage, "open", %{"url" => "https://example.com/"})
      text = :crypto.strong_rand_bytes(600_000) |> Base.encode64()
      answers(context, "read", :hold)

      task =
        Task.async(fn ->
          Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn -> true end)
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
          Opus.Browser.act(Opus.Browser.caller(guest(ctx), lineage), "read", %{}, fn -> true end)
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
                 true
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

  # Whether the browser's terminal holds a delivery its holder has not
  # taken, and whether it let some of what came meanwhile go.
  defp outstanding?(ctx), do: Enum.any?(subscribers(ctx), &(&1.outstanding != nil))
  defp lost?(ctx), do: Enum.any?(subscribers(ctx), & &1.lost)

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
