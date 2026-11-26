# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WorkspaceLiveTest do
  # A workspace thread as its own layer over the desktop: its title and
  # state, who is at work there, its steps as Aqua words them, what it
  # made with its pictures, files and links, and its posts in the thread
  # pane, whose sends go to that thread alone; two tabs in the hand. Only
  # the person's own workspace thread opens; anything else reads as not
  # here and shows nothing of it. The state follows the thread: a move
  # its list announces, a crew member's work ending under it, its
  # deletion; Stop ends its work.
  # A crew member's thread under it opens in the same pane, which leads
  # back. Driven against the real loop and a scripted model; the crew's
  # delivery consumer is off in the suite, so an opening starts no turn.
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Aqua.Providers.Workspace
  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Cyfr.Test.ScriptedDriver, as: Driver
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "workspace_live_#{:rand.uniform(1_000_000)}")
    # Removed after the setting is restored: a turn the test left finishing
    # may still write under the path, so the removal tolerates it.
    on_exit(fn -> File.rm_rf(test_path) end)
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)

    user = test_user()
    mine = Sanctum.Test.People.athanor!(user.user_id)
    {:ok, mine} = Sanctum.TestContext.mark_provisioned(mine)
    conn = log_in_user(conn, user)

    me = %{
      Sanctum.TestContext.local(:prism)
      | user_id: user.user_id,
        athanor_id: mine.id,
        origin: :interactive
    }

    ready_athanor!(mine.id, user.user_id)
    script_model!()

    {:ok, daily} = Aqua.Day.current(me)
    {:ok, conn: conn, user: user, mine: mine, me: me, daily: daily}
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)
  defp route(athanor), do: Athanors.route_slug(athanor)
  defp layer_path(athanor, id), do: PrismWeb.WorkspaceLive.address(route(athanor), id)

  # The person opens a workspace thread from a post of the daily thread.
  defp open!(me, daily, title) do
    {:ok, %{message: asked}} =
      TurnStorage.accept_message(actor(me), daily.id, %{
        message: %{author: me.user_id, sent_by: "person", content: "please #{title}"}
      })

    {:ok, %{workspace: id}} =
      Workspace.handle("workspace", me, %{
        "action" => "open",
        "thread" => daily.id,
        "refs" => [asked.id],
        "title" => title,
        "ask" => title
      })

    {:ok, workspace} = Threads.get(actor(me), id)
    workspace
  end

  # The turn its opening opens, as its delivery opens it: accepted, and
  # never run here.
  defp work!(me, workspace) do
    [opening | _] =
      Enum.filter(
        Threads.messages(actor(me), workspace.id),
        &(&1.kind == "opening" and is_nil(&1.turn_id))
      )

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor(me), workspace.id, %{
        message: %{author: me.user_id, sent_by: "person", content: opening.content},
        opening_id: opening.id,
        turn: %{agent: "aqua", requested_by: me.user_id, origin: :interactive}
      })

    turn
  end

  # Steps as a turn's loop leaves them.
  defp steps!(me, turn, specs) do
    rows =
      specs
      |> Enum.with_index(1)
      |> Enum.map(fn {spec, seq} ->
        Map.merge(
          %{
            id: Prima.UUID7.generate_id("stp"),
            athanor_id: me.athanor_id,
            turn_id: turn.id,
            seq: seq,
            kind: "tool",
            purpose: "chat",
            dispatch_state: "dispatched",
            generation: 0,
            started_at: DateTime.utc_now(),
            tool: nil,
            action: nil,
            outcome: "ok"
          },
          spec
        )
      end)

    {_, _} = Arca.Repo.insert_all(Arca.Schemas.TurnStep, rows)
    Enum.map(rows, & &1.id)
  end

  # A workspace thread whose turn wrote a file, read a page and posted a
  # picture and a link, and reported it done; the turn ended, so nothing
  # runs when a view opens it.
  defp charted!(me, daily) do
    workspace = open!(me, daily, "Moon chart")
    turn = work!(me, workspace)
    steps!(me, turn, [%{tool: "files", action: "write"}, %{tool: "http", action: "read"}])

    chart = Prima.UUID7.generate_id("msg")
    png = %{"filename" => "chart.png", "media_type" => "image/png", "bytes" => "PNG-chart"}
    {:ok, [ref]} = Aqua.Attachments.copy(me, workspace.id, chart, [png])

    {:ok, _} =
      Tape.post(me, turn, %{
        id: chart,
        content: "The chart",
        payload: %{
          "post" => true,
          "attachments" => [ref],
          "links" => [%{"url" => "https://example.com/moon", "title" => "The moon tonight"}]
        }
      })

    {:ok, _} = Tape.report_workspace(me, turn, "done", %{summary: "Charted."})
    {:ok, current} = Tape.turn(me, turn.id)
    {:ok, _} = Tape.finish(me, current, "cancelled", %{error: "stopped"})
    {:ok, workspace} = Threads.get(actor(me), workspace.id)
    {workspace, chart, ref}
  end

  # A nested view mounts after its host renders; look again until it has.
  defp child!(parent, id, tries \\ 50) do
    render(parent)

    case find_live_child(parent, id) do
      nil when tries > 0 ->
        # sleep-ok: poll interval of child!'s bounded wait (50 tries) for the nested view to mount
        Process.sleep(20)
        child!(parent, id, tries - 1)

      nil ->
        flunk("no child #{id} under #{parent.id}")

      child ->
        child
    end
  end

  defp pane_thread(pane), do: :sys.get_state(pane.pid).socket.assigns.thread

  defp on_thread!(pane, id) do
    wait_until(fn -> match?(%{id: ^id}, pane_thread(pane)) end, 2_000, "the pane on #{id}")
    pane
  end

  # The JS commands an element's binding carries, as LiveView's client reads
  # them.
  defp commands(view, selector, binding) do
    [encoded] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(binding)

    Jason.decode!(encoded)
  end

  # A state the store's rule wrote, as the writers S5 holds to it do, then
  # announced as they announce it: the view reads it again.
  defp move!(workspace, state) do
    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Thread, where: t.id == ^workspace.id),
        set: [workspace_state: state]
      )
  end

  test "a workspace thread opens as a full layer: its title and state, its steps as Aqua words them, what it made, and its posts in the pane on it",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, chart, ref} = charted!(me, daily)

    {:ok, view, html} = live(conn, layer_path(mine, workspace.id))

    # Drawn full over the desktop, with its own close back to it and no
    # page list.
    assert html =~ "settings-overlay-full"
    refute has_element?(view, "#settings-close")
    assert has_element?(view, ~s(#workspace-close[href="/a/#{route(mine)}"]))

    assert has_element?(view, "#workspace-title", "Moon chart")
    assert has_element?(view, ~s(#workspace-state[data-state="done"]), "Finished")

    # The steps, newest first, in Aqua's words; no step carries what the
    # model wrote.
    steps = view |> element("#workspace-steps") |> render()
    assert [_, read, wrote] = Regex.split(~r/<li /, steps) |> Enum.take(3)
    assert read =~ "Read a page on the web"
    assert wrote =~ "Wrote a file"

    # What it made: its picture in place, at the attachment address of the
    # post that holds it, and its link.
    pane = child!(view, "workspace-pane")
    on_thread!(pane, workspace.id)

    src = PrismWeb.ThreadPaneLive.attachment_path(route(mine), chart, ref["stored_name"])

    wait_until(fn -> has_element?(view, ~s(#workspace-results img[src="#{src}"])) end)
    # The pane holds the whole thread: the results claim no window.
    refute has_element?(view, "#workspace-results-window")

    assert has_element?(
             view,
             ~s(#workspace-results a[href="https://example.com/moon"]),
             "The moon tonight"
           )

    # Its posts are the pane on the workspace thread itself.
    assert pane_thread(pane).id == workspace.id
    assert has_element?(pane, "#workspace-pane-thread[data-thread='#{workspace.id}']")

    Cyfr.Test.Sandbox.end_views()
  end

  test "what a workspace thread made stays in its results behind 500 of a turn's own rows",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, chart, ref} = charted!(me, daily)

    for n <- 1..500 do
      {:ok, _} =
        Threads.append(actor(me), workspace.id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "tool_call",
          content: "call #{n}"
        })
    end

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    on_thread!(child!(view, "workspace-pane"), workspace.id)
    src = PrismWeb.ThreadPaneLive.attachment_path(route(mine), chart, ref["stored_name"])

    wait_until(fn -> has_element?(view, ~s(#workspace-results img[src="#{src}"])) end)
    assert has_element?(view, ~s(#workspace-results a[href="https://example.com/moon"]))
    refute has_element?(view, "#workspace-results-window")

    Cyfr.Test.Sandbox.end_views()
  end

  test "a thread longer than the pane reads says its results are what the latest posts hold, and lists no earlier one",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    workspace = open!(me, daily, "Long one")
    turn = work!(me, workspace)

    {:ok, _} =
      Tape.post(me, turn, %{
        id: Prima.UUID7.generate_id("msg"),
        content: "An early result",
        payload: %{"post" => true, "links" => [%{"url" => "https://example.com/early"}]}
      })

    {:ok, current} = Tape.turn(me, turn.id)
    {:ok, _} = Tape.finish(me, current, "cancelled", %{error: "stopped"})

    for n <- 1..500 do
      {:ok, _} =
        Threads.append(actor(me), workspace.id, %{
          author: me.user_id,
          sent_by: "person",
          content: "note #{n}"
        })
    end

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    _pane = on_thread!(child!(view, "workspace-pane"), workspace.id)

    wait_until(fn -> has_element?(view, "#workspace-results-window") end)
    assert has_element?(view, "#workspace-results-window", "latest 500 posts")
    assert has_element?(view, "#workspace-no-results", "Nothing in them.")
    refute render(view) =~ "https://example.com/early"

    Cyfr.Test.Sandbox.end_views()
  end

  test "in the hand the thread is the screen and the steps and results are a second tab",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))

    assert has_element?(view, ~s(#workspace-tab-posts[aria-selected="true"]))
    assert has_element?(view, "#workspace-work.max-md\\:hidden")
    refute has_element?(view, "#workspace-posts.max-md\\:hidden")

    view |> element("#workspace-tab-work") |> render_click()

    assert has_element?(view, ~s(#workspace-tab-work[aria-selected="true"]))
    assert has_element?(view, "#workspace-posts.max-md\\:hidden")
    refute has_element?(view, "#workspace-work.max-md\\:hidden")

    # The pane stays mounted behind its tab: the thread is kept.
    assert find_live_child(view, "workspace-pane")

    Cyfr.Test.Sandbox.end_views()
  end

  test "words typed in the layer go to that workspace thread's own soul, and nowhere else",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    daily_before = Threads.messages(actor(me), daily.id)

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    pane = on_thread!(child!(view, "workspace-pane"), workspace.id)

    Cyfr.Test.ScriptedWorker.script([model_reply("On it.")])
    pane |> form("form", %{"message" => "make it blue"}) |> render_submit()

    wait_until(
      fn ->
        rows = Threads.messages(actor(me), workspace.id)

        Enum.any?(rows, &(&1.content == "make it blue")) and
          Enum.any?(rows, &(&1.content == "On it."))
      end,
      60_000
    )

    # The turn ran in the workspace thread, and the daily thread holds
    # nothing it said.
    [request] = model_requests()
    assert request_text(request) =~ "make it blue"
    after_rows = Threads.messages(actor(me), daily.id)
    refute Enum.any?(after_rows, &(&1.content in ["make it blue", "On it."]))
    assert length(after_rows) >= length(daily_before)

    # New work opened it again.
    wait_until(fn -> has_element?(view, ~s(#workspace-state[data-state="open"])) end)

    # Once a turn has run there, the composer still names the soul as a
    # person reads it, never by its handle.
    assert has_element?(pane, ~s(textarea[placeholder^="Ask Aqua…"]))
    refute render(pane) =~ "Ask aqua…"

    Cyfr.Test.Sandbox.end_views()
  end

  test "only the person's own workspace thread opens: another athanor's, a daily or crew thread and an id of none read as not here, with nothing of them",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    workspace = open!(me, daily, "Mine")
    {:ok, crew} = Threads.crew_thread(actor(me), workspace.id, "builder")

    other = test_user()
    theirs = Sanctum.Test.People.athanor!(other.user_id)
    them = %{me | user_id: other.user_id, athanor_id: theirs.id}
    {:ok, their_daily} = Aqua.Day.current(them)
    foreign = open!(them, their_daily, "Theirs")

    for id <- [foreign.id, daily.id, crew.id, "thr_none"] do
      {:ok, view, html} = live(conn, layer_path(mine, id))
      assert has_element?(view, "#workspace-missing", "This workspace thread is not here.")
      refute find_live_child(view, "workspace-pane")
      refute html =~ "Theirs"
      refute has_element?(view, "form")
    end

    # A stranger asking for the person's own workspace thread at the
    # person's own athanor is not let in; the athanor is not theirs.
    stranger = log_in_user(Phoenix.ConnTest.build_conn(), other)

    assert {:error, {:redirect, %{to: "/"}}} = live(stranger, layer_path(mine, workspace.id))

    # An anonymous browser is sent to sign in.
    assert {:error, {:redirect, %{to: "/login"}}} =
             live(Phoenix.ConnTest.build_conn(), layer_path(mine, workspace.id))

    Cyfr.Test.Sandbox.end_views()
  end

  test "the state follows the thread: a move its list announces, and its deletion",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    assert has_element?(view, ~s(#workspace-state[data-state="done"]))

    # A move the person's list announces.
    move!(workspace, "needs_you")
    Aqua.ThreadList.changed(me, workspace.id)

    wait_until(fn ->
      has_element?(view, ~s(#workspace-state[data-state="needs_you"]), "Needs you")
    end)

    # Deleted while open: nothing of it is left, its posts included.
    {:ok, _} = Tape.delete_thread(me, workspace.id)
    wait_until(fn -> has_element?(view, "#workspace-missing") end)
    refute find_live_child(view, "workspace-pane")
    refute render(view) =~ "Moon chart"

    Cyfr.Test.Sandbox.end_views()
  end

  test "the layer's toggle opens the thread's menu by JS commands; a press away and Escape " <>
         "close it, Escape giving focus back to the toggle; its Delete leaves for the desktop",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    pane = on_thread!(child!(view, "workspace-pane"), workspace.id)

    toggle = "#workspace-menu-toggle"

    assert has_element?(
             view,
             ~s(#{toggle}[aria-controls="workspace-pane-menu"][aria-expanded="false"]) <>
               ~s([aria-label="This thread's menu"])
           )

    assert commands(view, toggle, "phx-click") == [
             ["remove_attr", %{"attr" => "hidden", "to" => "#workspace-pane-menu"}],
             ["set_attr", %{"attr" => ["aria-expanded", "true"]}],
             ["set_attr", %{"attr" => ["inert", ""]}],
             ["focus_first", %{"to" => "#workspace-pane-menu"}]
           ]

    menu = "#workspace-pane-menu"
    assert has_element?(pane, ~s(#{menu}[hidden][phx-key="Escape"]))

    closed = [
      ["remove_attr", %{"attr" => "inert", "to" => toggle}],
      ["set_attr", %{"attr" => ["aria-expanded", "false"], "to" => toggle}],
      ["set_attr", %{"attr" => ["hidden", ""], "to" => menu}]
    ]

    assert commands(pane, menu, "phx-click-away") == closed

    assert commands(pane, menu, "phx-window-keydown") ==
             [
               ["remove_attr", %{"attr" => "inert", "to" => toggle}],
               ["focus", %{"to" => toggle <> ~s([aria-expanded="true"])}]
               | tl(closed)
             ]

    pane |> element("#workspace-pane-delete") |> render_click()
    assert_redirect(view, PrismWeb.DesktopLive.path(route(mine)))
    assert {:error, :not_found} = Threads.get(actor(me), workspace.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "with nothing attached or linked, a finished thread's last answer is its result, and " <>
         "an unfinished one has nothing made yet",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    workspace = open!(me, daily, "Plain answer")
    turn = work!(me, workspace)
    answer = Prima.UUID7.generate_id("msg")

    for {id, words} <- [
          {Prima.UUID7.generate_id("msg"), "A first thought"},
          {answer, "The answer is 42."}
        ] do
      {:ok, _} = Tape.post(me, turn, %{id: id, content: words, payload: %{"post" => true}})
    end

    {:ok, _} = Tape.report_workspace(me, turn, "done", %{summary: "Answered."})
    {:ok, current} = Tape.turn(me, turn.id)
    {:ok, _} = Tape.finish(me, current, "cancelled", %{error: "stopped"})

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    on_thread!(child!(view, "workspace-pane"), workspace.id)
    assert has_element?(view, ~s(#workspace-state[data-state="done"]))

    # A post's words are drawn by the browser from the text it carries.
    wait_until(fn ->
      has_element?(
        view,
        ~s(#workspace-results #workspace-result-#{answer}[data-raw-content="The answer is 42."])
      )
    end)

    refute has_element?(view, ~s(#workspace-results [data-raw-content="A first thought"]))
    refute has_element?(view, "#workspace-no-results")

    move!(workspace, "open")
    Aqua.ThreadList.changed(me, workspace.id)

    wait_until(fn -> has_element?(view, "#workspace-no-results", "Nothing made yet.") end)
    refute has_element?(view, "#workspace-results")

    Cyfr.Test.Sandbox.end_views()
  end

  test "each state reads as a person reads it, and Stop is offered only while it works or needs them",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))

    for {state, label, stop?} <- [
          {"open", "Working", true},
          {"needs_you", "Needs you", true},
          {"done", "Finished", false},
          {"stopped", "Stopped", false},
          {"error", "Error", false}
        ] do
      move!(workspace, state)
      Aqua.ThreadList.changed(me, workspace.id)

      wait_until(fn ->
        has_element?(view, ~s(#workspace-state[data-state="#{state}"]), label)
      end)

      assert has_element?(view, "#workspace-stop") == stop?
    end

    Cyfr.Test.Sandbox.end_views()
  end

  test "who is at work stands above the steps, one row an agent; a crew member's turn ending under it moves the layer's state",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    workspace = open!(me, daily, "Crew work")
    aqua = work!(me, workspace)
    {:ok, crew} = Threads.crew_thread(actor(me), workspace.id, "planner")

    {:ok, %{turn: planner}} =
      TurnStorage.accept_message(actor(me), crew.id, %{
        message: %{author: me.user_id, sent_by: "person", content: "plan it"},
        turn: %{agent: "planner", requested_by: me.user_id, origin: :interactive}
      })

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^planner.id),
        set: [status: "running"]
      )

    steps!(me, planner, [%{tool: "http", action: "read", outcome: nil}])

    # Aqua's work done while the planner's runs: the thread is at work.
    {:ok, _} = Tape.report_workspace(me, aqua, "done", %{summary: "Done."})
    {:ok, current} = Tape.turn(me, aqua.id)
    {:ok, _} = Tape.finish(me, current, "cancelled", %{error: "stopped"})

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))

    assert has_element?(view, ~s(#workspace-state[data-state="open"]), "Working")
    assert has_element?(view, ~s(#workspace-at-work-planner[data-status="running"]), "planner")
    assert has_element?(view, "#workspace-at-work-planner", "Read a page on the web")
    assert has_element?(view, "#workspace-at-work-planner", "just now")
    refute has_element?(view, "#workspace-at-work-aqua")

    # The planner's turn ends in its own thread: the list announces its
    # room, and the layer reads the thread finished, with nobody at work.
    {:ok, current} = Tape.turn(me, planner.id)
    {:ok, _} = Tape.finish(me, current, "cancelled", %{error: "stopped"})

    wait_until(fn ->
      has_element?(view, ~s(#workspace-state[data-state="done"]), "Finished")
    end)

    refute has_element?(view, "#workspace-at-work")
    refute has_element?(view, "#workspace-stop")

    Cyfr.Test.Sandbox.end_views()
  end

  test "Stop ends the thread's work: its running turn is cancelled, and the thread reads Stopped",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    pane = on_thread!(child!(view, "workspace-pane"), workspace.id)
    refute has_element?(view, "#workspace-stop")

    # The turn's model call is with the scripted model, which never answers.
    Cyfr.Test.ScriptedWorker.script([{:probe, self()}, :hang])
    pane |> form("form", %{"message" => "look around"}) |> render_submit()
    assert_receive {:scripted_probe, player, _execution}, 60_000
    send(player, :continue)

    wait_until(fn -> has_element?(view, ~s(#workspace-state[data-state="open"])) end)

    # Aqua stands at work there, thinking; the soul reads as Aqua. The rows
    # are read again every few seconds.
    wait_until(
      fn -> has_element?(view, ~s(#workspace-at-work-aqua[data-status="running"])) end,
      15_000
    )

    assert has_element?(view, "#workspace-at-work-aqua", "Aqua")
    assert has_element?(view, "#workspace-at-work-aqua", "Thinking")

    [turn] =
      Arca.Repo.all(
        from(t in Arca.Schemas.Turn,
          where: t.thread_id == ^workspace.id and t.status in ^Prima.TurnState.open_statuses()
        )
      )

    view |> element("#workspace-stop") |> render_click()

    wait_until(fn ->
      has_element?(view, ~s(#workspace-state[data-state="stopped"]), "Stopped")
    end)

    refute has_element?(view, "#workspace-stop")
    assert {:ok, %{status: "cancelled"}} = Tape.turn(me, turn.id)
    wait_until(fn -> not has_element?(view, "#workspace-at-work") end)

    Cyfr.Test.Sandbox.end_views()
  end

  test "a crew member's thread under it opens in the layer's pane, which leads back",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    member = Cyfr.Test.SeedBundle.seat_member()
    {:ok, crew} = Threads.crew_thread(actor(me), workspace.id, member)

    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))
    pane = on_thread!(child!(view, "workspace-pane"), workspace.id)

    wait_until(fn ->
      render(pane)
      has_element?(pane, "#workspace-pane-crew-#{crew.id}")
    end)

    pane |> element("#workspace-pane-crew-#{crew.id}") |> render_click()
    on_thread!(pane, crew.id)

    # The layer stays the workspace thread's.
    assert has_element?(view, "#workspace-title", "Moon chart")

    pane
    |> element("#workspace-pane-crew-thread button[phx-click='open_thread']")
    |> render_click()

    on_thread!(pane, workspace.id)

    Cyfr.Test.Sandbox.end_views()
  end

  describe "Aqua's browser in the layer" do
    setup %{me: me} do
      root = :crypto.strong_rand_bytes(32)
      fake = Scripted.start(self(), root)
      _controller = Scripted.supervise_controller(url: fake.url, root: root, tick_ms: 3_600_000)
      assert_receive {:control, "reconcile", _message, _fields}, 2_000

      answers = :ets.new(:answers, [:public])
      driver = Driver.start(self(), answer: &browser_answer(answers, &1))
      Scripted.set(fake, :terminal, driver)

      {:ok, _row} =
        Arca.McpServerStorage.insert(actor(me), %{
          cap: 0,
          name: Opus.Programs.Definition.browser_name(),
          transport: "program",
          mark: "driven",
          url: nil,
          home: "kept",
          config_json: Jason.encode!(%{"command" => "cyfr-browser", "env" => %{}})
        })

      {:ok, driver: driver, answers: answers}
    end

    test "a thread whose work uses the browser offers its window, and nothing streams before it is asked",
         %{conn: conn, mine: mine, me: me, daily: daily} do
      bare = open!(me, daily, "Nothing browsed")
      {:ok, view, _html} = live(conn, layer_path(mine, bare.id))
      browser = child!(view, "workspace-browser-view")
      refute has_element?(browser, "#workspace-browser-watch")

      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      assert has_element?(browser, "#workspace-browser-watch", "Show Aqua's browser")
      refute_received {:driver, :req, _session, %{"op" => "cast"}}
    end

    test "asked, the window shows in the middle, each image drawn before the next, the person's input goes to it, and closing ends it",
         %{conn: conn, mine: mine, me: me, daily: daily, driver: driver} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      work_id = work.id

      render_hook(browser, "browser_watch", %{"width" => 780, "height" => 780})

      assert_receive {:driver, :req, _s,
                      %{"op" => "cast", "id" => cast, "win" => ^work_id, "args" => args}},
                     5_000

      assert args == %{"width" => 780, "height" => 780}

      jpeg = <<0xFF, 0xD8, "first", 0xFF, 0xD9>>
      :ok = Driver.image(driver, cast, 1, jpeg)
      encoded = Base.encode64(jpeg)
      assert_push_event(browser, "browser_image", %{watch: watch, n: 1, jpeg: ^encoded}, 5_000)
      assert has_element?(browser, "#workspace-browser[data-stream=showing]")
      refute_received {:driver, :seen, _s, ^cast, _seq}

      render_hook(browser, "browser_drawn", %{"watch" => watch, "n" => 1})
      assert_receive {:driver, :seen, _s, ^cast, 1}, 5_000

      press = %{
        "k" => "mouse",
        "type" => "down",
        "x" => 0.5,
        "y" => 0.25,
        "button" => "left",
        "clicks" => 1,
        "mods" => 0
      }

      assert watch == watch_of(browser)
      render_hook(browser, "browser_input", %{"watch" => watch, "browser_input" => [press]})
      assert_receive {:driver, :input, _s, ^cast, [^press]}, 5_000
      assert_push_event(browser, "browser_input_taken", %{watch: ^watch}, 5_000)

      # What does not read as events is dropped, and the hook may go on.
      render_hook(browser, "browser_input", %{
        "watch" => watch,
        "browser_input" => [%{press | "x" => 7}]
      })

      refute_receive {:driver, :input, _s, ^cast, _events}, 200
      assert_push_event(browser, "browser_input_taken", %{watch: ^watch}, 5_000)

      browser |> element("#workspace-browser-close") |> render_click()
      assert_receive {:driver, :uncast, _s, ^cast}, 5_000
      assert has_element?(browser, "#workspace-browser-watch")
    end

    test "a window Aqua has no page open in says so in words, and shows once Aqua opens one",
         %{conn: conn, mine: mine, me: me, daily: daily, answers: answers} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)

      :ets.insert(
        answers,
        {"cast",
         {:error, "no_window", "There is no browser window for this thread; open a page first."}}
      )

      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})

      wait_until(
        fn -> has_element?(browser, "#workspace-browser-waiting") end,
        2_000,
        "the waiting words"
      )

      assert render(browser) =~ "Aqua has no page open in this thread yet."
    end

    test "while the setting is off the stream is refused in the provider's words; turned off while it runs, it ends in them",
         %{conn: conn, mine: mine, me: me, daily: daily} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast"}}, 5_000

      assert {:ok, %{on: false}} =
               Aqua.Providers.Browser.handle("browser", me, %{"action" => "turn_off"})

      wait_until(
        fn -> render(browser) =~ Aqua.Providers.Browser.turned_off() end,
        2_000,
        "the stream to end in the turned-off sentence"
      )

      # The browser stopped: no window stands to offer.
      refute has_element?(browser, "#workspace-browser-watch")

      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})

      assert has_element?(
               browser,
               "#workspace-browser-refused",
               Aqua.Providers.Browser.turned_off()
             )

      refute_receive {:driver, :req, _s, %{"op" => "cast"}}, 200
    end

    test "another page of the person's takes the window; this one says so and offers to take it back",
         %{conn: conn, mine: mine, me: me, daily: daily, user: user} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => first}}, 5_000

      other = log_in_user(Phoenix.ConnTest.build_conn(), user)
      {:ok, second, _html} = live(other, layer_path(mine, work.id))
      elsewhere = child!(second, "workspace-browser-view")
      render_hook(elsewhere, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :uncast, _s, ^first}, 5_000

      wait_until(
        fn -> has_element?(browser, "#workspace-browser-taken") end,
        2_000,
        "the first page to say the window went elsewhere"
      )

      assert render(browser) =~ "showing on another page of yours now"
      assert has_element?(browser, "#workspace-browser-taken button", "Show it here instead")
    end

    # Review round two, finding 6: what is meant for a watch ends with it.
    test "a reopened stream takes no input meant for the watch before it",
         %{conn: conn, mine: mine, me: me, daily: daily} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => old}}, 5_000
      before = watch_of(browser)

      browser |> element("#workspace-browser-close") |> render_click()
      assert_receive {:driver, :uncast, _s, ^old}, 5_000
      assert watch_of(browser) == nil

      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => new}}, 5_000
      now = watch_of(browser)
      assert is_binary(now) and now != before

      key = %{
        "k" => "key",
        "type" => "down",
        "key" => "x",
        "code" => "KeyX",
        "text" => "x",
        "vk" => 88,
        "mods" => 0
      }

      render_hook(browser, "browser_input", %{"watch" => before, "browser_input" => [key]})
      refute_receive {:driver, :input, _s, ^new, _events}, 200

      render_hook(browser, "browser_input", %{"watch" => now, "browser_input" => [key]})
      assert_receive {:driver, :input, _s, ^new, [^key]}, 5_000
    end

    # Review round two, finding 7: an image's acknowledgement names its watch.
    test "an old image's acknowledgement does not acknowledge the image of the watch after it",
         %{conn: conn, mine: mine, me: me, daily: daily, driver: driver} do
      work = open!(me, daily, "Replaced image")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => old}}, 5_000
      :ok = Driver.image(driver, old, 1, <<0xFF, 0xD8, "old", 0xFF, 0xD9>>)
      assert_push_event(browser, "browser_image", %{watch: before, n: 1}, 5_000)

      browser |> element("#workspace-browser-close") |> render_click()
      assert_receive {:driver, :uncast, _s, ^old}, 5_000
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => new}}, 5_000
      :ok = Driver.image(driver, new, 1, <<0xFF, 0xD8, "new", 0xFF, 0xD9>>)
      assert_push_event(browser, "browser_image", %{watch: now, n: 1}, 5_000)
      assert now != before

      # The first watch's image finishes drawing only now.
      render_hook(browser, "browser_drawn", %{"watch" => before, "n" => 1})
      refute_receive {:driver, :seen, _s, ^new, 1}, 500

      render_hook(browser, "browser_drawn", %{"watch" => now, "n" => 1})
      assert_receive {:driver, :seen, _s, ^new, 1}, 5_000
    end

    # Review round two, a note: a closed watch's monitor of its holder goes.
    test "closing the stream leaves no monitor of the browser behind",
         %{conn: conn, mine: mine, me: me, daily: daily} do
      work = open!(me, daily, "Stop monitoring")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      {:monitors, before} = Process.info(browser.pid, :monitors)

      for _ <- 1..3 do
        render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
        assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000
        browser |> element("#workspace-browser-close") |> render_click()
        assert_receive {:driver, :uncast, _s, ^cast}, 5_000
      end

      assert {:monitors, ^before} = Process.info(browser.pid, :monitors)
    end

    # Review round two, finding 9: what the person types travels as a
    # parameter the event log filters, as a program's terminal's does.
    test "LiveView's line for the person's input carries nothing they typed",
         %{conn: conn, mine: mine, me: me, daily: daily} do
      work = open!(me, daily, "Private input")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000
      watch = watch_of(browser)
      typed = "typed-canary-7"

      key = %{
        "k" => "key",
        "type" => "down",
        "key" => "x",
        "code" => "KeyX",
        "text" => typed,
        "vk" => 88,
        "mods" => 0
      }

      Prima.Test.Env.configure_logger(level: :debug)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          render_hook(browser, "browser_input", %{"watch" => watch, "browser_input" => [key]})
          assert_receive {:driver, :input, _s, ^cast, [%{"text" => ^typed}]}, 5_000
        end)

      assert log =~ ~s(HANDLE EVENT "browser_input")
      assert log =~ ~s("browser_input" => "[FILTERED]")
      refute log =~ typed
    end

    test "leaving the page ends its stream", %{conn: conn, mine: mine, me: me, daily: daily} do
      work = open!(me, daily, "Look it up")
      browse!(me, work)
      {:ok, view, _html} = live(conn, layer_path(mine, work.id))
      browser = child!(view, "workspace-browser-view")
      render_hook(browser, "browser_watch", %{"width" => 640, "height" => 640})
      assert_receive {:driver, :req, _s, %{"op" => "cast", "id" => cast}}, 5_000

      GenServer.stop(view.pid)
      assert_receive {:driver, :uncast, _s, ^cast}, 5_000
    end
  end

  # The watch the view names on the page, as the hook reads it, or nil.
  defp watch_of(browser) do
    browser
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#workspace-browser")
    |> LazyHTML.attribute("data-watch")
    |> List.first()
  end

  defp browser_answer(answers, %{"op" => op}) do
    case :ets.lookup(answers, op) do
      [{^op, answer}] -> answer
      [] -> {:ok, %{"url" => "https://example.com/", "title" => "Example"}}
    end
  end

  # A turn of the workspace thread opens a page in Aqua's browser, so the
  # person's browser holds a window for it.
  defp browse!(me, workspace) do
    turn = work!(me, workspace)
    root = "exe_turn_root_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, status: "running"]
      )

    lineage = %{
      "thread_id" => workspace.id,
      "root_execution_id" => root,
      "parent_execution_id" => root
    }

    assert {:ok, _} =
             Aqua.Providers.Browser.handle(
               "browser",
               Sanctum.Context.enter_guest(me),
               Map.merge(lineage, %{"action" => "open", "url" => "https://example.com/"})
             )

    assert_receive {:driver, :req, _session, %{"op" => "open"}}, 5_000
  end
end
