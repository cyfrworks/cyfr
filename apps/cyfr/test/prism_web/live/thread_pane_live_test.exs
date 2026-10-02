# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ThreadPaneLiveTest do
  # The pane on its own: what it says when the session is gone, that a
  # refusal reaches the person as a sentence, that what it pushes names
  # the pane it is for, and that a kept model catalogue is read without a
  # run. On a group's room.
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Tenancy.Athanors

  # A text size under the 12 px a 720×720 glass is held to (WCAG 2.2 AA at
  # that viewport, as the join proof measures it).
  @under_12px ~r/text-\[(?:\d|1[01])(?:\.\d+)?px\]/

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
    in_room = %{Sanctum.TestContext.local(:prism) | user_id: user.user_id, athanor_id: room.id}

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
  defp card!(ctx, thread, proposal, intent_over \\ %{}) do
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
          turn_id: turn.id,
          origin: :interactive
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
        consent_id: "consent_x",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
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

    intent =
      Map.merge(
        %{
          "kind" => "request_approval",
          "title" => "Pin the plan",
          "action_kind" => "write",
          "standing" => false,
          "tool_call_id" => "c1",
          "proposal" => proposal
        },
        intent_over
      )

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
        to_string(CyfrWeb.SignInResponse.session_key()) => "not-a-session"
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
    send(pane.pid, {:approval_approve, card.approval_id, %{scope: :always}})
    html = render(pane)

    assert html =~ Aqua.ToolGrants.refusal_message({:scope_not_permitted, :never_standing})
    refute html =~ "never_standing"
  end

  test "a card is decided through approval.resolve by its approval, with the bounds chosen",
       %{conn: conn, room: room, in_room: in_room, thread: thread} do
    card =
      card!(
        in_room,
        thread,
        %{
          "tool" => "files",
          "action" => "write",
          "args" => %{"path" => "data//notes/today.md", "content" => "x"}
        },
        %{"standing" => nil}
      )

    pane = room_pane(conn, room, thread)
    card_dom = ~s([id$="-card-#{card.id}"])

    # Its run was started by no schedule, so no answer can end with one.
    assert has_element?(pane, ~s(#{card_dom} [phx-value-lifecycle="execution"]))
    refute has_element?(pane, ~s(#{card_dom} [phx-value-lifecycle="schedule"]))

    pane |> element(~s(#{card_dom} input[phx-click="approval:toggle_limit"])) |> render_click()
    pane |> element(~s(#{card_dom} button[phx-value-lifecycle="execution"])) |> render_click()
    render(pane)

    [input] =
      Arca.Repo.all(
        from(l in Arca.Schemas.McpLog,
          where: l.tool == "approval" and l.action == "resolve",
          select: l.input
        )
      )

    assert input =~ card.approval_id
    assert input =~ ~s("lifecycle":"execution")
    assert input =~ ~s("scope":"thread")
    assert input =~ ~s("patterns":["data/notes/today.md"])
    assert input =~ ~s("kind":"storage_path")
  end

  @write %{
    "tool" => "files",
    "action" => "write",
    "args" => %{"path" => "data/notes/today.md", "content" => "x"}
  }

  # A card of its own in a thread of its own: deciding a card settles it.
  # A scheduled card's run row names the schedule it was started by.
  defp offer!(conn, room, in_room, scheduled?) do
    {:ok, thread} = Threads.create(Sanctum.Context.actor(in_room))
    card = card!(in_room, thread, @write, %{"standing" => nil})

    if scheduled? do
      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^card.execution_id),
          set: [schedule_id: "sched_offer_#{System.unique_integer([:positive])}"]
        )
    end

    {room_pane(conn, room, thread), card}
  end

  # The grant that reached `approval.resolve` for `card`, as it was asked.
  defp resolved(card) do
    inputs =
      Arca.Repo.all(
        from(l in Arca.Schemas.McpLog,
          where: l.tool == "approval" and l.action == "resolve",
          select: l.input
        )
      )

    assert [input] =
             inputs
             |> Enum.map(&Jason.decode!/1)
             |> Enum.filter(&(&1["approval"] == card.approval_id))

    input
  end

  defp click_offer(pane, card, selector) do
    pane |> element(~s([id$="-card-#{card.id}"] #{selector})) |> render_click()
    render(pane)
  end

  describe "each offer of a card" do
    test "once, for this run and always reach approval.resolve with their scope and lifecycle",
         %{conn: conn, room: room, in_room: in_room} do
      for {selector, scope, lifecycle} <- [
            {~s(button[phx-value-scope="once"]), "once", nil},
            {~s(button[phx-value-lifecycle="execution"]), "thread", "execution"},
            {~s|button[phx-value-scope="always"]:not([phx-value-lifecycle])|, "always", nil}
          ] do
        {pane, card} = offer!(conn, room, in_room, false)
        click_offer(pane, card, selector)
        input = resolved(card)

        assert input["decision"] == "approve"
        assert input["scope"] == scope, selector
        assert input["lifecycle"] == lifecycle, selector
        refute Map.has_key?(input, "until"), selector
        refute Map.has_key?(input, "constraint"), selector
      end
    end

    test "for this thread until ends 1, 8 or 24 hours from the click",
         %{conn: conn, room: room, in_room: in_room} do
      for hours <- [1, 8, 24] do
        {pane, card} = offer!(conn, room, in_room, false)
        before = DateTime.utc_now()
        click_offer(pane, card, ~s(button[phx-value-hours="#{hours}"]))
        later = DateTime.utc_now()
        input = resolved(card)

        assert input["scope"] == "thread"
        refute Map.has_key?(input, "lifecycle")
        assert is_binary(input["until"]), "#{hours}h reached approval.resolve with no until"
        assert {:ok, until, 0} = DateTime.from_iso8601(input["until"])

        assert DateTime.compare(until, DateTime.add(before, hours * 3600 - 1, :second)) != :lt,
               "#{hours}h: #{input["until"]}"

        assert DateTime.compare(until, DateTime.add(later, hours * 3600 + 1, :second)) != :gt,
               "#{hours}h: #{input["until"]}"
      end
    end

    test "for this schedule is offered only for a scheduled run, and ends with its schedule",
         %{conn: conn, room: room, in_room: in_room} do
      {unscheduled, plain} = offer!(conn, room, in_room, false)

      refute has_element?(
               unscheduled,
               ~s([id$="-card-#{plain.id}"] [phx-value-lifecycle="schedule"])
             )

      {pane, card} = offer!(conn, room, in_room, true)
      click_offer(pane, card, ~s(button[phx-value-lifecycle="schedule"]))
      input = resolved(card)

      assert input["scope"] == "always"
      assert input["lifecycle"] == "schedule"
      refute Map.has_key?(input, "until")
    end
  end

  test "the thread's standing answers are listed, bounded ones too, each to withdraw",
       %{conn: conn, room: room, thread: thread} do
    pane = room_pane(conn, room, thread)

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :grants,
      data: MapSet.new([{"aqua", "files", "write"}])
    })

    render(pane)
    assert has_element?(pane, ~s([data-test="standing-answers"]), "standing answers in this chat")

    assert has_element?(
             pane,
             ~s([data-test="standing-answers"] button[phx-click="revoke_grant"][phx-value-tool="files"][phx-value-action="write"])
           )
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

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: user.user_id}
    })

    render(pane)

    assert_push_event(pane, "aqua:intents", %{pane: ^pane_id, intents: pushed})
    assert [%{kind: "copy_clipboard"}, %{kind: "navigate", to: to}] = pushed
    assert to == PrismWeb.Focus.path(route(room), "/activities")

    # Another member's intents are theirs alone.
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: "someone-else"}
    })

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

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: user.user_id}
    })

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

  test "at 720×720 an open thread draws no text under 12 px and no target under 24 px", %{
    conn: conn,
    room: room,
    thread: thread
  } do
    pane = room_pane(conn, room, thread)
    html = render(pane)
    assert html =~ "hello"

    # Every size the pane draws is `text-xs` or larger (WCAG 2.2 AA at the
    # 720×720 glass, as the join proof measures it), and its small targets
    # are held to 24 px (`min-h-6`): the line's author, its say-aloud, the
    # header's controls and the thread's footer.
    refute html =~ @under_12px
    assert has_element?(pane, "span.text-xs", "You")
    assert has_element?(pane, "button.min-h-6.text-xs", "Say aloud")
    assert has_element?(pane, "header a.min-h-6.text-xs", "AQUA")
    assert has_element?(pane, "div.text-xs > span", thread.title || "New thread")
  end

  test "at 720×720 every state the pane draws holds the same sizes", %{
    conn: conn,
    user: user,
    room: room,
    in_room: in_room,
    thread: thread
  } do
    # A state no test here reaches — a DM's header, several approvals
    # pending, a held send, the panel's links and its read-the-room box —
    # is held by the template itself: no text class under 12 px anywhere,
    # and each of those small targets at 24 px.
    source =
      PrismWeb.ThreadPaneLive.module_info(:compile)[:source] |> to_string() |> File.read!()

    refute source =~ @under_12px

    for click <- ~w(approve_all_pending decline_all_pending retry_send discard_send dismiss_link) do
      assert source =~ ~r/phx-click="#{click}"[^>]*class="[^"]*min-h-6/,
             "the #{click} control is under 24 px"
    end

    assert source =~ ~r/phx-click="toggle_read_room"[^>]*class="h-6 w-6/

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(in_room), thread.id, %{
        author: user.user_id,
        content: "two files",
        payload: %{
          "attachments" => [
            %{"filename" => "notes.md", "stored_name" => "abc_notes.md"},
            %{"filename" => "kept-elsewhere.txt"}
          ]
        }
      })

    pane = room_pane(conn, room, thread)

    event = fn kind, data ->
      send(pane.pid, %Cyfr.Bus.ThreadEvent{
        athanor_id: thread.athanor_id,
        thread_id: thread.id,
        kind: kind,
        data: data
      })
    end

    # A turn running for this person with a message queued behind it, its
    # tools at work, two standing answers and the prompt to send again.
    event.(:turn_starting, user.user_id)
    event.(:queued, 2)
    event.(:tool_activity, [%{tool: "files.read", status: :running, preview: "notes.md"}])
    event.(:grants, MapSet.new([{"aqua", "files", "read"}, {"aqua", "notes", "write"}]))
    event.(:restart_prompt, %{text: "two files", user_id: user.user_id})

    # A file on its way up.
    pane
    |> file_input("form[phx-submit=submit]", :attachments, [
      %{name: "draft.txt", content: "x", type: "text/plain"}
    ])
    |> render_upload("draft.txt", 40)

    html = render(pane)

    for drawn <- [
          "is asking",
          "2 queued",
          "+2 this chat",
          "files.read",
          "send it again",
          "draft.txt",
          "kept-elsewhere.txt"
        ],
        do: assert(html =~ drawn, "#{drawn} is not drawn")

    refute html =~ @under_12px

    standing = ~s([data-test="standing-answers"])
    assert has_element?(pane, "#{standing}.text-xs")
    assert has_element?(pane, ~s(#{standing} button.min-h-6.min-w-6[phx-click="revoke_grant"]))
    assert has_element?(pane, ~s(button.min-h-6.min-w-6[phx-click="cancel_upload"]))
    assert has_element?(pane, ~s(button.min-h-6[phx-click="restart_send"]))
    assert has_element?(pane, ~s(button.min-h-6[phx-click="dismiss_restart"]))
    assert has_element?(pane, "a.min-h-6.text-xs[download]", "notes.md")
    assert has_element?(pane, "span.text-xs", "kept-elsewhere.txt")
  end

  test "a turn stopped on an unknown outcome shows so until it goes on", %{
    conn: conn,
    room: room,
    thread: thread,
    user: user
  } do
    pane = room_pane(conn, room, thread)

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_starting,
      data: user.user_id
    })

    assert render(pane) =~ "Thinking"

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_paused,
      data: %{turn_id: "trn_x", reason: :uncertain}
    })

    html = render(pane)
    assert html =~ "Stopped: a tool"
    assert html =~ "Your next message continues this turn"
    refute html =~ "Thinking"
    assert has_element?(pane, ~s(button[phx-click="stop"]))

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_starting,
      data: user.user_id
    })

    refute render(pane) =~ "Stopped: a tool"

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :turn_finished
    })

    refute has_element?(pane, ~s(button[phx-click="stop"]))
  end

  # Minimal valid WASM with a `run` export: enough to publish a row.
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  # A component in `ctx`'s athanor a turn can ask a grant for.
  defp grantable!(ctx) do
    name = "pane-grant-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A component a turn asks a grant for",
        manifest: Jason.encode!(%{})
      })

    {"catalyst:local.#{name}", "catalyst:local.#{name}:0.1.0"}
  end

  defp consent_required(pane, thread, ref, user_id) do
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :consent_required,
      data: %{ref: ref, user_id: user_id}
    })

    render(pane)
  end

  test "a grant the turn needs is asked in the layer of the view that renders the pane, never on the pane",
       %{conn: conn, user: user, room: room, thread: thread, in_room: in_room} do
    {name_ref, ref} = grantable!(in_room)
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    pane = child!(view, "pane-" <> room.id)

    # Another member's turn asks them, not this person.
    consent_required(pane, thread, ref, "someone-else")
    refute render(view) =~ ~s(data-kind="grant")

    consent_required(pane, thread, ref, user.user_id)
    render(view)
    assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
    assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))
    refute has_element?(pane, ".consent-sheet")

    # Said again while it is open: the open prompt already asks it.
    consent_required(pane, thread, ref, user.user_id)
    refute render(view) =~ "waiting."

    # Granted in the page's layer, under the page's context in the pane's
    # athanor; the pane hears it and lets the prompt go.
    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk and commits; the page takes its
    # layer's report, then the pane the one it hands on.
    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    refute render(view) =~ ~s(data-kind="grant")
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(in_room, name_ref)

    Cyfr.Test.Sandbox.end_views()
  end

  test "a pane with no view around it has no layer to ask in, and says so", %{
    conn: conn,
    user: user,
    room: room,
    thread: thread,
    in_room: in_room
  } do
    {_name_ref, ref} = grantable!(in_room)

    {:ok, pane, _} =
      live_isolated(conn, PrismWeb.ThreadPaneLive,
        session: %{"athanor_id" => room.id, "thread_id" => thread.id}
      )

    html = consent_required(pane, thread, ref, user.user_id)
    assert html =~ "Open the thread in the chat to give it."
    refute html =~ ~s(data-kind="grant")
  end
end
