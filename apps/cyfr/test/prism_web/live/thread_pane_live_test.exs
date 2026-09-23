# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ThreadPaneLiveTest do
  # The pane on its own: what it says when the session is gone, that a
  # refusal reaches the person as a sentence, that what it pushes names
  # the pane it is for, and that a kept model catalogue is read without a
  # run. On a group's room.
  use PrismWeb.ConnCase, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "pane_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      # A turn the test left finishing may still write under the path; the
      # runners are stopped after this callback, so the removal tolerates it.
      File.rm_rf(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    user = test_user()
    n = System.unique_integer([:positive])
    {:ok, room} = Athanors.create_group(user.user_id, "Team #{n}")
    conn = log_in_user(conn, user, athanor_id: room.id)
    in_room = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: room.id}

    {:ok, thread} = Threads.create(Sanctum.Context.actor(in_room))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(in_room), thread.id, %{
        author: user.user_id,
        content: "hello"
      })

    {:ok, thread} = Threads.get(Sanctum.Context.actor(in_room), thread.id)

    {:ok, conn: conn, user: user, room: room, in_room: in_room, thread: thread}
  end

  defp route(athanor), do: Athanors.route_slug(athanor)

  # A card as the loop opens it: a turn with its root, the model step,
  # the call, and the approval on the tape.
  defp card!(ctx, thread, proposal) do
    alias Aqua.Tape

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua pin it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_pane_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x"
      })

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "#{proposal["tool"]}.#{proposal["action"]}",
            tool: proposal["tool"],
            action: proposal["action"],
            arguments: proposal["args"],
            kind: "write"
          }
        ]
      })

    intent = %{
      "kind" => "request_approval",
      "title" => "Pin the plan",
      "action_kind" => "write",
      "standing" => false,
      "tool_call_id" => "c1",
      "proposal" => proposal
    }

    {:ok, %{card: card}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "Pin the plan", payload: %{"intent" => intent}}
      })

    card
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

  defp room_pane(conn, room, thread) do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    child!(view, "pane-" <> room.id)
  end

  test "a session that no longer establishes is sent to sign in", %{room: room} do
    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(PrismWeb.SignInResponse.session_key()) => "not-a-session"
      })

    assert {:error, {:redirect, %{to: "/login"}}} =
             live_isolated(stale, PrismWeb.ThreadPaneLive, session: %{"athanor_id" => room.id})
  end

  test "a refused standing answer reaches the person as a sentence, not the machine's atom",
       %{conn: conn, room: room, in_room: in_room, thread: thread} do
    card =
      card!(in_room, thread, %{
        "tool" => "notes",
        "action" => "pin",
        "args" => %{"name" => "plan"}
      })

    pane = room_pane(conn, room, thread)

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
    thread: thread
  } do
    pane = room_pane(conn, room, thread)
    pane_id = "pane-" <> room.id <> "-pane"
    intents = [%{kind: "copy_clipboard", text: "friday"}, %{kind: "navigate", to: "/activities"}]

    send(pane.pid, {:thread, thread.id, {:intents, intents, user.user_id}})
    render(pane)

    assert_push_event(pane, "aqua:intents", %{pane: ^pane_id, intents: pushed})
    assert [%{kind: "copy_clipboard"}, %{kind: "navigate", to: to}] = pushed
    assert to == PrismWeb.Focus.path(route(room), "/activities")

    # Another member's intents are theirs alone.
    send(pane.pid, {:thread, thread.id, {:intents, intents, "someone-else"}})
    render(pane)
    refute_push_event(pane, "aqua:intents", %{intents: _})
  end

  test "a navigate is pushed only for a page the console serves", %{
    conn: conn,
    user: user,
    room: room,
    thread: thread
  } do
    pane = room_pane(conn, room, thread)

    intents = [
      %{kind: "navigate", to: "/etc/passwd"},
      # Under a page the nav offers, but no route serves it.
      %{kind: "navigate", to: "/components/not/a/page"},
      %{kind: "navigate", to: "/executions?id=exec_a"}
    ]

    send(pane.pid, {:thread, thread.id, {:intents, intents, user.user_id}})
    render(pane)

    assert_push_event(pane, "aqua:intents", %{intents: pushed})
    assert [%{kind: "navigate", to: to}] = pushed
    assert to == PrismWeb.Focus.path(route(room), "/executions?id=exec_a")
  end

  test "a kept model catalogue is read on mount without a run", %{
    conn: conn,
    room: room,
    thread: thread,
    in_room: in_room
  } do
    :ok = PrismWeb.ModelCatalog.remember(room.id, %{"models" => %{"kept" => ["kept-model-1"]}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(room.id) end)

    # A hit answers the caller at once — the result is in the mailbox before
    # `load/1` returns, so no run was spawned and no deadline armed — with
    # or without an engine on the box.
    assert :ok = PrismWeb.ModelCatalog.load(in_room)

    assert_received {:list_models_result, _tag,
                     {:ok, %{"models" => %{"kept" => ["kept-model-1"]}}}}

    pane = room_pane(conn, room, thread)
    assert has_element?(pane, ~s(select[name="model"] option[value="kept-model-1"]))
  end

  test "the pane's copy: its chrome and the composer's stop", %{
    conn: conn,
    room: room,
    thread: thread
  } do
    html = render(room_pane(conn, room, thread))
    assert html =~ "The soul or role this thread is on"
    refute html =~ "autofocus"
    refute html =~ ~r/\bagent\b/
    refute html =~ "A.Q.U.A."
  end

  test "a turn stopped on an unknown outcome shows so until it goes on", %{
    conn: conn,
    room: room,
    thread: thread,
    user: user
  } do
    pane = room_pane(conn, room, thread)
    send(pane.pid, {:thread, thread.id, {:turn_starting, user.user_id}})
    assert render(pane) =~ "Thinking"

    send(pane.pid, {:thread, thread.id, {:turn_paused, "trn_x", :uncertain}})
    html = render(pane)
    assert html =~ "Stopped: a tool"
    assert html =~ "Your next message continues this turn"
    refute html =~ "Thinking"
    assert has_element?(pane, ~s(button[phx-click="stop"]))

    send(pane.pid, {:thread, thread.id, {:turn_starting, user.user_id}})
    refute render(pane) =~ "Stopped: a tool"

    send(pane.pid, {:thread, thread.id, {:turn_finished}})
    refute has_element?(pane, ~s(button[phx-click="stop"]))
  end
end
