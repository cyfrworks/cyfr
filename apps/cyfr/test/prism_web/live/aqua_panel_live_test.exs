# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLiveTest do
  # The person's own AQUA beside a room: two panes on two estates on one
  # page, and nothing bleeds — the panel's send lands in You with the room
  # read into the turn, and an answer pastes back onto the room, attributed.
  # Driven with the fake engine.
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
    conn = log_in_user(conn, user, athanor_id: room.id)

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

    pane = child!(panel, "aqua-panel-pane-new")
    assert render(pane) =~ "Read #{room.name}"

    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    assert_receive {:fake_start, _eid, ctx, input, _profile}, 10_000
    assert ctx.athanor_id == mine.id
    assert input["system"] =~ "## Read from the room"
    assert input["system"] =~ "ship friday"
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

    # The panel followed the thread its first message created.
    assert child!(panel, "aqua-panel-pane-" <> you_conv.id)
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
    pane = child!(panel, "aqua-panel-pane-new")
    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    assert_receive {:fake_start, eid, _ctx, _input, _profile}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000
    [you_conv] = Conversations.list(me)
    ConversationRunner.subscribe(you_conv.id, mine.id)

    emit(runner, "text_delta", %{"content" => "They mean Friday."})
    complete(runner)
    assert_receive {:conversation, _, {:message, %{author: "aqua"} = answer}}, 5_000

    pane = child!(panel, "aqua-panel-pane-" <> you_conv.id)
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
    room_pane = child!(view, "pane-" <> room.id <> "-" <> conv.id)
    assert render(room_pane) =~ "shared from AQUA by You"
  end

  test "on the bench there is no room: the panel reads nothing and sends plainly",
       %{conn: conn, room: room, mine: mine} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, html} = open_panel(view)
    assert html =~ "AQUA · You"
    refute html =~ "Reading "

    pane = child!(panel, "aqua-panel-pane-new")
    refute render(pane) =~ "with each message"
    pane |> form("form", %{"message" => "hello me"}) |> render_submit()

    assert_receive {:fake_start, _eid, ctx, input, _profile}, 10_000
    assert ctx.athanor_id == mine.id
    refute input["system"] =~ "## Read from the room"
  end
end
