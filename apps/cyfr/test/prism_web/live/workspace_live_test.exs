# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.WorkspaceLiveTest do
  # A workspace thread as its own layer over the desktop: its title and
  # state, its steps as Aqua words them, what it made with its pictures,
  # files and links, and its conversation in the thread pane, whose sends
  # go to that thread alone; two tabs in the hand. Only the person's own
  # workspace thread opens; anything else reads as not here and shows
  # nothing of it. The state follows the thread: a move its list
  # announces, a card in a crew member's thread under it, its deletion.
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
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "workspace_live_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

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
            outcome: "ok",
            approval_id: nil
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

  # A state the store's rule wrote, as the writers S5 holds to it do, then
  # announced as they announce it: the view reads it again.
  defp move!(workspace, state) do
    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Thread, where: t.id == ^workspace.id),
        set: [workspace_state: state]
      )
  end

  test "a workspace thread opens as a full layer: its title and state, its steps as Aqua words them, what it made, and its conversation in the pane on it",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, chart, ref} = charted!(me, daily)

    {:ok, view, html} = live(conn, layer_path(mine, workspace.id))

    # Drawn full over the desktop, with its own close back to it and no
    # page list.
    assert html =~ "settings-overlay-full"
    refute has_element?(view, "#settings-close")
    assert has_element?(view, ~s(#workspace-close[href="/a/#{route(mine)}"]))

    assert has_element?(view, "#workspace-title", "Moon chart")
    assert has_element?(view, ~s(#workspace-state[data-state="done"]), "Done")

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

    # Its conversation is the pane on the workspace thread itself.
    assert pane_thread(pane).id == workspace.id
    assert has_element?(pane, "#workspace-pane-thread[data-thread='#{workspace.id}']")

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

  test "in the hand the conversation is the screen and the steps and results are a second tab",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, view, _html} = live(conn, layer_path(mine, workspace.id))

    assert has_element?(view, ~s(#workspace-tab-conversation[aria-selected="true"]))
    assert has_element?(view, "#workspace-work.max-md\\:hidden")
    refute has_element?(view, "#workspace-conversation.max-md\\:hidden")

    view |> element("#workspace-tab-work") |> render_click()

    assert has_element?(view, ~s(#workspace-tab-work[aria-selected="true"]))
    assert has_element?(view, "#workspace-conversation.max-md\\:hidden")
    refute has_element?(view, "#workspace-work.max-md\\:hidden")

    # The pane stays mounted behind its tab: the conversation is kept.
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

    # A card the next turn opens there names it so too, and the thread
    # waits on the person.
    Cyfr.Test.ScriptedWorker.script([
      model_call("c1", "files", %{"action" => "delete", "path" => "notes.md"})
    ])

    pane |> form("form", %{"message" => "delete my notes"}) |> render_submit()

    wait_until(fn -> has_element?(pane, ~s([id^="workspace-pane-card-"]), "wants to") end, 60_000)
    assert has_element?(pane, ~s([id^="workspace-pane-card-"]), "Aqua wants to")
    refute render(pane) =~ "aqua wants to"
    wait_until(fn -> has_element?(view, ~s(#workspace-state[data-state="needs_you"])) end)

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

  test "the state follows the thread: a move its list announces, a card under it, and its deletion",
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

    # A card decided in a crew member's thread under it announces no move
    # of the workspace thread's own; the athanor's notice is enough.
    move!(workspace, "open")
    Sanctum.Notify.broadcast(me.athanor_id, :approval_resolved, %{thread_id: "thr_crew"})

    wait_until(fn ->
      has_element?(view, ~s(#workspace-state[data-state="open"]), "Working on it")
    end)

    # Deleted while open: nothing of it is left, the conversation included.
    {:ok, _} = Tape.delete_thread(me, workspace.id)
    wait_until(fn -> has_element?(view, "#workspace-missing") end)
    refute find_live_child(view, "workspace-pane")
    refute render(view) =~ "Moon chart"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a crew member's thread under it opens in the layer's pane, which leads back",
       %{conn: conn, mine: mine, me: me, daily: daily} do
    {workspace, _chart, _ref} = charted!(me, daily)
    {:ok, crew} = Threads.crew_thread(actor(me), workspace.id, "builder")

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
end
