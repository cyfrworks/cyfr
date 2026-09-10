# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLiveTest do
  # The person's own AQUA beside a room: two panes on two estates on one
  # page, and nothing bleeds — the panel's send lands in You with the room
  # read into the turn, and an answer pastes back onto the room, attributed.
  # The panel itself: what the assistant points at stays in the panel, a
  # halt reaches only its own turn, Escape closes it, and it keeps its
  # thread from one page to the next. Driven with the fake engine.
  use PrismWeb.ConnCase, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "aqua_panel_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :aqua_turn, Aqua.FakeTurn)
    Aqua.FakeTurn.listen()

    on_exit(fn ->
      Application.delete_env(:cyfr, :aqua_turn)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    user = test_user()
    other = test_user()
    n = System.unique_integer([:positive])

    {:ok, mine} =
      Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me-panel#{n}",
        owner_user_id: user.user_id,
        created_by: user.user_id
      })

    {:ok, room} = Athanors.create_group(user.user_id, "Team #{n}")

    # Both estates are set up: a turn pins the baseline consent, and the
    # composer is held on an estate that is still being prepared.
    {:ok, mine} = Athanors.mark_provisioned(mine)
    {:ok, _} = Athanors.mark_provisioned(room)

    conn = log_in_user(conn, user, athanor_id: room.id)
    :ok = Sanctum.TestContext.shipped!(mine.id)

    {:ok, u} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)
    {:ok, _} = Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: mine.id)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(other.user_id, scope: "athanor", athanor_id: room.id)

    me = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}
    in_room = %{me | athanor_id: room.id}
    them = %{in_room | user_id: other.user_id}

    # The seed soul names a catalyst these sandboxes do not hold; the fake
    # engine needs none.
    for ctx <- [me, in_room] do
      {:ok, _} =
        Aqua.AgentConfig.call_aqua(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "catalyst_ref" => ""
        })
    end

    {:ok, conv} = Conversations.create(in_room)
    :ok = ConversationRunner.send_message(them, conv.id, "ship friday")
    # The first line names the thread.
    {:ok, conv} = Conversations.get(in_room, conv.id)

    {:ok,
     conn: conn,
     user: user,
     mine: mine,
     room: room,
     me: me,
     in_room: in_room,
     them: them,
     conv: conv}
  end

  defp route(athanor), do: Athanors.route_slug(athanor)

  # The thread a pane is turned to, from its own state.
  defp thread_of(pane), do: :sys.get_state(pane.pid).socket.assigns.conversation

  # A pane turns to a thread by message; look again until it has.
  defp on_thread!(pane, id, tries \\ 50) do
    case thread_of(pane) do
      %{id: ^id} ->
        pane

      _ when tries > 0 ->
        Process.sleep(20)
        on_thread!(pane, id, tries - 1)

      other ->
        flunk("the pane is on #{inspect(other && other.id)}, not #{id}")
    end
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

  defp open_panel(view) do
    panel = child!(view, "aqua-panel")
    html = panel |> element("#aqua-panel-button") |> render_click()
    {panel, html}
  end

  defp emit(runner, kind, data) do
    %{execution_id: eid} = :sys.get_state(runner)

    send(
      runner,
      {:execution_event, %{execution_id: eid, type: "emit", data: Map.put(data, "kind", kind)}}
    )
  end

  defp complete(runner) do
    %{execution_id: eid} = :sys.get_state(runner)
    send(runner, {:execution_event, %{execution_id: eid, type: "complete", data: %{}}})
  end

  test "the panel opens onto You beside the room, and a send lands in You with the room read into the turn",
       %{conn: conn, mine: mine, room: room, me: me, in_room: in_room, conv: conv} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)

    {panel, html} = open_panel(view)
    assert html =~ "AQUA · You"
    assert html =~ "Reading #{room.name} · #{conv.title}"

    pane = child!(panel, "aqua-panel-pane")
    assert thread_of(pane) == nil
    assert render(pane) =~ "Read #{room.name}"

    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    assert_receive {:fake_start, _eid, ctx, input, _profile}, 10_000
    assert ctx.athanor_id == mine.id
    assert input["transient"] =~ "## Read from the room"
    assert input["transient"] =~ "ship friday"
    refute input["system"] =~ "ship friday"
    assert input["task"] == "what do they mean?"

    # In You, and only there.
    assert [you_conv] = Conversations.list(me)

    assert Enum.any?(
             Conversations.latest_messages(me, you_conv.id, 10),
             &(&1.content == "what do they mean?")
           )

    refute Enum.any?(
             Conversations.latest_messages(in_room, conv.id, 10),
             &(&1.content == "what do they mean?")
           )

    # The pane is on the thread its first message created.
    on_thread!(child!(panel, "aqua-panel-pane"), you_conv.id)
  end

  test "the panel reads what the page shows: open another thread and it says so",
       %{conn: conn, room: room, in_room: in_room, conv: conv} do
    {:ok, second} = Conversations.create(in_room)
    {:ok, _} = Conversations.update(in_room, second.id, %{title: "Second thread"})

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    {panel, html} = open_panel(view)
    assert html =~ "Reading #{room.name} · #{conv.title}"

    render_click(view, "open_conversation", %{"route" => route(room), "id" => second.id})
    assert render(panel) =~ "Reading #{room.name} · Second thread"
  end

  test "an answer in the panel pastes onto the room, attributed, and the room's pane shows it",
       %{conn: conn, user: user, mine: mine, room: room, me: me, in_room: in_room, conv: conv} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    pane = child!(panel, "aqua-panel-pane")
    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    assert_receive {:fake_start, eid, _ctx, _input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000
    [you_conv] = Conversations.list(me)
    ConversationRunner.subscribe(you_conv.id, mine.id)

    emit(runner, "text_delta", %{"content" => "They mean Friday."})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{author: "aqua"} = answer}}, 5_000

    on_thread!(pane, you_conv.id)
    assert render(pane) =~ "They mean Friday."

    html =
      pane
      |> element(~s(button[phx-click="paste"][phx-value-id="#{answer.id}"]))
      |> render_click()

    assert html =~ "Pasted onto #{room.name}"

    copy =
      Enum.find(
        Conversations.latest_messages(in_room, conv.id, 10),
        &(&1.content == "They mean Friday.")
      )

    assert copy.author == user.user_id
    assert Conversations.payload(copy)["shared_agent"] == true

    # The room's own pane on the page heard of it.
    room_pane = child!(view, "pane-" <> room.id)
    assert render(room_pane) =~ "shared from AQUA by You"
  end

  test "on the bench there is no room: the panel reads nothing and sends plainly",
       %{conn: conn, room: room, mine: mine} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, html} = open_panel(view)
    assert html =~ "AQUA · You"
    refute html =~ "Reading "

    pane = child!(panel, "aqua-panel-pane")
    refute render(pane) =~ "with each message"
    pane |> form("form", %{"message" => "hello me"}) |> render_submit()

    assert_receive {:fake_start, _eid, ctx, input, _profile}, 10_000
    assert ctx.athanor_id == mine.id
    refute Map.has_key?(input, "transient")
  end

  # The panel's pane on the thread the first send created, with the turn
  # under way.
  defp panel_thread(panel, me, text) do
    pane = child!(panel, "aqua-panel-pane")
    pane |> form("form", %{"message" => text}) |> render_submit()
    [you_conv] = Conversations.list(me)
    {on_thread!(child!(panel, "aqua-panel-pane"), you_conv.id), you_conv}
  end

  defp intents(pane, conv, user, intents) do
    send(pane.pid, {:conversation, conv.id, {:intents, intents, user.user_id}})
    render(pane)
  end

  test "a navigate from the panel never moves the page: a thread of You opens in the panel, another page is a link",
       %{conn: conn, user: user, mine: mine, room: room, me: me, conv: conv} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    {pane, you_conv} = panel_thread(panel, me, "where are my activities?")
    assert_receive {:fake_start, _eid, _ctx, _input, _profile}, 10_000

    # Another page: offered as a link, on You, and nothing pushed.
    html = intents(pane, you_conv, user, [%{kind: "navigate", to: "/activities?id=req_abc"}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert html =~ "AQUA points to"
    assert html =~ PrismWeb.Focus.path(route(mine), "/activities?id=req_abc")

    # Dismissed, it is gone.
    pane |> element(~s(button[phx-click="dismiss_link"])) |> render_click()
    refute render(pane) =~ "AQUA points to"

    # A thread of You: the panel turns to it.
    {:ok, second} = Conversations.create(me)
    to = PrismWeb.ChatLive.chat_path(route(mine), second.id)
    intents(pane, you_conv, user, [%{kind: "navigate", to: to}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    on_thread!(child!(panel, "aqua-panel-pane"), second.id)

    # The page is still the room's, and the room's pane is where it was.
    assert child!(view, "pane-" <> room.id)
    assert render(panel) =~ "Reading #{room.name} · #{conv.title}"
  end

  test "a navigate to the chat of You that names no thread is a link, and the panel keeps its thread",
       %{conn: conn, user: user, mine: mine, room: room, me: me, conv: conv} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    {pane, you_conv} = panel_thread(panel, me, "where were we?")
    assert_receive {:fake_start, _eid, _ctx, _input, _profile}, 10_000

    # The estate alone, no `c`: not a thread the panel could turn to.
    to = PrismWeb.ChatLive.chat_path(route(mine))
    html = intents(pane, you_conv, user, [%{kind: "navigate", to: to}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert html =~ "AQUA points to"
    assert html =~ to

    # The open thread was not blanked.
    on_thread!(child!(panel, "aqua-panel-pane"), you_conv.id)
    assert has_element?(panel, ~s(#aqua-panel-threads option[value="#{you_conv.id}"][selected]))
  end

  test "⌘. in the panel halts the panel's turn and leaves the room's running",
       %{conn: conn, mine: mine, room: room, me: me, conv: conv} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    room_id = room.id
    mine_id = mine.id

    room_pane = child!(view, "pane-" <> room.id)
    room_pane |> form("form", %{"message" => "@aqua go on"}) |> render_submit()
    assert_receive {:fake_start, room_eid, %{athanor_id: ^room_id}, _input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^room_eid, _runner}, 5_000

    {panel, _html} = open_panel(view)
    {pane, _you_conv} = panel_thread(panel, me, "and you?")
    assert_receive {:fake_start, panel_eid, %{athanor_id: ^mine_id}, _input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^panel_eid, _runner}, 5_000

    # What the hook pushes for ⌘. — to its own pane.
    render_hook(pane, "stop", %{})
    assert_receive {:fake_cancel, ^panel_eid}, 5_000
    refute_receive {:fake_cancel, ^room_eid}, 300
  end

  test "the sheet is a dialog over a page that stays live, Escape closes it, and its button names it only while open",
       %{conn: conn, room: room} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-button[aria-controls]")

    {panel, html} = open_panel(view)
    assert has_element?(panel, ~s(#aqua-panel-sheet[role="dialog"][aria-label="Your AQUA"]))
    # Not modal: the room under it is what the panel reads and pastes into,
    # so nothing claims a focus trap the page does not have — and a click
    # on the room (to scroll it, to select a line) does not close the panel.
    refute html =~ "aria-modal"
    refute has_element?(panel, "#aqua-panel-sheet[phx-click-away]")
    # Escape is the sheet's own, not the window's: a dialog on the page
    # underneath keeps its Escape.
    refute has_element?(panel, "#aqua-panel-sheet[phx-window-keydown]")
    assert has_element?(panel, "#aqua-panel-sheet[phx-keydown]")
    assert has_element?(panel, ~s(#aqua-panel-button[aria-controls="aqua-panel-sheet"]))

    panel |> element("#aqua-panel-sheet") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(panel, "#aqua-panel-sheet")
    refute has_element?(panel, "#aqua-panel-button[aria-controls]")
    assert has_element?(panel, ~s(#aqua-panel-button[aria-expanded="false"]))
  end

  test "the panel keeps its thread from one page to the next, and closed stays closed",
       %{conn: conn, room: room, me: me, conv: conv} do
    {:ok, kept} = Conversations.create(me)
    {:ok, _} = Conversations.update(me, kept.id, %{title: "Kept"})

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    panel |> element("#aqua-panel-threads") |> render_change(%{"id" => kept.id})
    on_thread!(child!(panel, "aqua-panel-pane"), kept.id)

    # The next page mounts the layout's panel afresh, as a live navigation
    # does; the same session finds the same panel.
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    assert has_element?(panel, "#aqua-panel-sheet")
    on_thread!(child!(panel, "aqua-panel-pane"), kept.id)

    render_click(panel, "close", %{})
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-sheet")
  end

  test "the page's first paint carries the button alone; a session that no longer establishes says so",
       %{conn: conn, room: room, conv: conv} do
    html = conn |> get(PrismWeb.ChatLive.chat_path(route(room), conv.id)) |> html_response(200)
    assert html =~ ~s(id="aqua-panel-button")
    refute html =~ "aqua-panel-sheet"

    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(PrismWeb.SignInResponse.session_key()) => "not-a-session"
      })

    {:ok, panel, _} = live_isolated(stale, PrismWeb.AquaPanelLive, session: %{"ui_mode" => "dev"})
    assert render(panel) =~ "Signed out — reload to continue"
    refute has_element?(panel, "#aqua-panel-button")
  end
end
