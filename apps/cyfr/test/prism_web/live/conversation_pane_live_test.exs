# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationPaneLiveTest do
  # The pane on its own: what it says when the session is gone, that a
  # refusal reaches the person as a sentence, that what it pushes names
  # the pane it is for, and that a kept model catalogue is read without a
  # run. Driven with the fake engine on a group's room.
  use PrismWeb.ConnCase, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Arca.Schemas.Message
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "pane_#{:rand.uniform(1_000_000)}")
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
    n = System.unique_integer([:positive])
    {:ok, room} = Athanors.create_group(user.user_id, "Team #{n}")
    conn = log_in_user(conn, user, athanor_id: room.id)
    in_room = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: room.id}

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(in_room, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ""
      })

    {:ok, conv} = Conversations.create(in_room)
    {:ok, _} = Conversations.append(in_room, conv.id, %{author: user.user_id, content: "hello"})
    {:ok, conv} = Conversations.get(in_room, conv.id)

    {:ok, conn: conn, user: user, room: room, in_room: in_room, conv: conv}
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

  defp room_pane(conn, room, conv) do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), conv.id))
    settled_render(view)
    child!(view, "pane-" <> room.id)
  end

  test "a session that no longer establishes renders the signed-out line", %{room: room} do
    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(PrismWeb.SignInResponse.session_key()) => "not-a-session"
      })

    {:ok, pane, _} =
      live_isolated(stale, PrismWeb.ConversationPaneLive, session: %{"athanor_id" => room.id})

    assert render(pane) =~ "Signed out — reload to continue."
    refute has_element?(pane, "form")
  end

  test "a refused standing answer reaches the person as a sentence, not the machine's atom",
       %{conn: conn, room: room, in_room: in_room, conv: conv} do
    {:ok, card} =
      Conversations.append(in_room, conv.id, %{
        author: Message.agent_author(),
        kind: "approval",
        status: "pending",
        content: "Pin the plan",
        payload: %{
          "intent" => %{
            "title" => "Pin the plan",
            "action_kind" => "write",
            "standing" => false,
            "proposal" => %{"tool" => "notes", "action" => "pin", "args" => %{"name" => "plan"}}
          }
        }
      })

    pane = room_pane(conn, room, conv)

    # What the card dispatches for "always".
    send(pane.pid, {:approval_approve, card.id, :always})
    html = render(pane)

    assert html =~ Aqua.ToolGrants.refusal_message({:scope_not_permitted, :never_standing})
    refute html =~ "never_standing"
  end

  test "what the pane pushes names the pane it is for", %{
    conn: conn,
    user: user,
    room: room,
    conv: conv
  } do
    pane = room_pane(conn, room, conv)
    pane_id = "pane-" <> room.id <> "-pane"
    intents = [%{kind: "copy_clipboard", text: "friday"}, %{kind: "navigate", to: "/activities"}]

    send(pane.pid, {:conversation, conv.id, {:intents, intents, user.user_id}})
    render(pane)

    assert_push_event(pane, "aqua:intents", %{pane: ^pane_id, intents: pushed})
    assert [%{kind: "copy_clipboard"}, %{kind: "navigate", to: to}] = pushed
    assert to == PrismWeb.Focus.path(route(room), "/activities")

    # Another member's intents are theirs alone.
    send(pane.pid, {:conversation, conv.id, {:intents, intents, "someone-else"}})
    render(pane)
    refute_push_event(pane, "aqua:intents", %{intents: _})
  end

  test "a kept model catalogue is read on mount without a run", %{
    conn: conn,
    room: room,
    conv: conv,
    in_room: in_room
  } do
    :ok = PrismWeb.ModelCatalog.remember(room.id, %{"models" => %{"kept" => ["kept-model-1"]}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(room.id) end)

    # A hit answers the caller at once — the result is in the mailbox before
    # `load/1` returns, so no run was spawned and no deadline armed — with
    # or without an engine on the box.
    assert :ok = PrismWeb.ModelCatalog.load(in_room)
    assert_received {:list_models_result, {:ok, %{"models" => %{"kept" => ["kept-model-1"]}}}}

    pane = room_pane(conn, room, conv)
    assert has_element?(pane, ~s(select[name="model"] option[value="kept-model-1"]))
  end

  test "the pane's copy: its chrome and the composer's stop", %{
    conn: conn,
    room: room,
    conv: conv
  } do
    html = render(room_pane(conn, room, conv))
    assert html =~ "The soul or role this thread is on"
    refute html =~ "autofocus"
    refute html =~ ~r/\bagent\b/
    refute html =~ "A.Q.U.A."
  end
end
