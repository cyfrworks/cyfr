# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLiveTest do
  # The person's own AQUA beside a room: two panes on two athanors on one
  # page, and nothing bleeds — the panel's send lands in You with the room
  # read into the turn, and an answer pastes back onto the room, attributed.
  # The panel itself: what the assistant points at stays in the panel, a
  # halt reaches only its own turn, Escape and Ctrl+J close it, and it
  # keeps its thread, its place, its size and its docking from one page to
  # the next (the pointer and the hand's sheet are the hook's, tested in
  # assets/test/aqua_panel/). Driven against the real loop and a
  # scripted model.
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Runner
  alias Sanctum.Tenancy.Athanors

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "aqua_panel_#{:rand.uniform(1_000_000)}")
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
    other = test_user()
    n = System.unique_integer([:positive])

    mine = Sanctum.Test.People.athanor!(user.user_id)

    {:ok, room} = Athanors.create_group(user.user_id, "Team #{n}")

    # Both athanors are set up: a turn pins the baseline consent, and the
    # composer is held on an athanor that is still being prepared.
    {:ok, mine} = Sanctum.TestContext.mark_provisioned(mine)
    {:ok, _} = Sanctum.TestContext.mark_provisioned(room)

    conn = log_in_user(conn, user, athanor_id: room.id)
    :ok = Sanctum.TestContext.shipped!(mine.id)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(other.user_id, scope: "athanor", athanor_id: room.id)

    me = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}
    in_room = %{me | athanor_id: room.id}
    them = %{in_room | user_id: other.user_id}

    # Both athanors filled, their souls' consents minted; the model is scripted.
    ready_athanor!(mine.id, user.user_id)
    ready_athanor!(room.id, user.user_id)
    script_model!()

    {:ok, thread} = Threads.create(Sanctum.Context.actor(in_room))
    {:ok, _} = Runner.send_message(them, thread.id, "ship friday")
    # The first line names the thread.
    {:ok, thread} = Threads.get(Sanctum.Context.actor(in_room), thread.id)

    {:ok,
     conn: conn,
     user: user,
     mine: mine,
     room: room,
     me: me,
     in_room: in_room,
     them: them,
     thread: thread}
  end

  defp route(athanor), do: Athanors.route_slug(athanor)

  # The thread a pane is turned to, from its own state.
  defp thread_of(pane), do: :sys.get_state(pane.pid).socket.assigns.thread

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

  # The panel's thread of You, once its turn has ended.
  defp settled_you!(me) do
    wait_until(
      fn ->
        match?([_], Threads.list(Sanctum.Context.actor(me))) and
          match?(
            {:ok, []},
            Aqua.Tape.open_turns(me, hd(Threads.list(Sanctum.Context.actor(me))).id)
          )
      end,
      60_000
    )

    [you_thread] = Threads.list(Sanctum.Context.actor(me))
    you_thread
  end

  test "the panel opens onto You beside the room, and a send lands in You with the room read into the turn",
       %{conn: conn, room: room, me: me, in_room: in_room, thread: thread} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)

    {panel, html} = open_panel(view)
    assert has_element?(panel, ~s(#aqua-panel-sheet[aria-label="Your AQUA"] header), "AQUA")
    assert html =~ "Reading #{room.name} · #{thread.title}"

    pane = child!(panel, "aqua-panel-pane")
    assert thread_of(pane) == nil
    assert render(pane) =~ "Read #{room.name}"

    Cyfr.Test.ScriptedWorker.script([model_reply("They mean Friday.")])
    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    # In You, and only there — with the room read into the turn's request
    # beside the task, never into the system prompt.
    you_thread = settled_you!(me)
    [request] = model_requests()
    text = request_text(request)
    assert text =~ "## Read from the room"
    assert text =~ "ship friday"
    assert text =~ "what do they mean?"
    refute request["system"] =~ "ship friday"

    assert Enum.any?(
             Threads.latest_messages(Sanctum.Context.actor(me), you_thread.id, 10),
             &(&1.content == "what do they mean?")
           )

    refute Enum.any?(
             Threads.latest_messages(Sanctum.Context.actor(in_room), thread.id, 10),
             &(&1.content == "what do they mean?")
           )

    # The pane is on the thread its first message created.
    on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "the panel reads what the page shows: open another thread and it says so",
       %{conn: conn, room: room, in_room: in_room, thread: thread} do
    {:ok, second} = Threads.create(Sanctum.Context.actor(in_room))

    {:ok, _} =
      Threads.update(Sanctum.Context.actor(in_room), second.id, %{title: "Second thread"})

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    {panel, html} = open_panel(view)
    assert html =~ "Reading #{room.name} · #{thread.title}"

    render_click(view, "open_thread", %{"route" => route(room), "id" => second.id})
    assert render(panel) =~ "Reading #{room.name} · Second thread"

    Cyfr.Test.Sandbox.end_views()
  end

  test "an answer in the panel pastes onto the room, attributed, and the room's pane shows it",
       %{conn: conn, user: user, room: room, me: me, in_room: in_room, thread: thread} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    pane = child!(panel, "aqua-panel-pane")
    Cyfr.Test.ScriptedWorker.script([model_reply("They mean Friday.")])
    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    you_thread = settled_you!(me)

    answer =
      Enum.find(
        Threads.latest_messages(Sanctum.Context.actor(me), you_thread.id, 10),
        &(&1.content == "They mean Friday.")
      )

    assert answer.author == Arca.Schemas.Message.agent_author()

    on_thread!(pane, you_thread.id)
    assert render(pane) =~ "They mean Friday."

    html =
      pane
      |> element(~s(button[phx-click="paste"][phx-value-id="#{answer.id}"]))
      |> render_click()

    assert html =~ "Pasted onto #{room.name}"

    copy =
      Enum.find(
        Threads.latest_messages(Sanctum.Context.actor(in_room), thread.id, 10),
        &(&1.content == "They mean Friday.")
      )

    assert copy.author == user.user_id
    assert Threads.payload(copy)["shared_agent"] == true

    # The room's own pane on the page heard of it.
    room_pane = child!(view, "pane-" <> room.id)
    assert render(room_pane) =~ "shared from AQUA by You"

    Cyfr.Test.Sandbox.end_views()
  end

  test "on the bench there is no room: the panel reads nothing and sends plainly",
       %{conn: conn, room: room, mine: mine, me: me} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, _html} = open_panel(view)
    assert has_element?(panel, ~s(#aqua-panel-sheet[aria-label="Your AQUA"] header), "AQUA")
    refute has_element?(panel, "#aqua-panel-room")

    pane = child!(panel, "aqua-panel-pane")
    refute render(pane) =~ "with each message"
    Cyfr.Test.ScriptedWorker.script([model_reply("hello you")])
    pane |> form("form", %{"message" => "hello me"}) |> render_submit()

    you_thread = settled_you!(me)
    assert you_thread.athanor_id == mine.id
    [request] = model_requests()
    refute request_text(request) =~ "Read from the room"

    Cyfr.Test.Sandbox.end_views()
  end

  test "the thread's menu carries the model override, the soul or role and the counts, and a model chosen there is the one the next send asks",
       %{conn: conn, room: room, mine: mine, me: me} do
    :ok = PrismWeb.ModelCatalog.remember(mine.id, %{"models" => %{"kept" => ["kept-model-1"]}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(mine.id) end)

    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, _html} = open_panel(view)
    # The header's menu button opens the pane's menu, a popover.
    assert has_element?(panel, ~s(#aqua-panel-more[popovertarget="aqua-panel-pane-menu"]))

    pane = child!(panel, "aqua-panel-pane")
    menu = ~s(#aqua-panel-pane-menu[popover])

    wait_until(
      fn -> has_element?(pane, ~s(#{menu} select[name="model"] option[value="kept-model-1"])) end,
      5_000,
      "the catalogue in the panel's menu"
    )

    assert has_element?(pane, menu, "Soul or role")
    assert has_element?(pane, menu, "0 in · 0 out")

    pane
    |> element(~s(#{menu} select[name="model"]))
    |> render_change(%{"model" => "kept-model-1"})

    assert has_element?(pane, ~s(#{menu} option[value="kept-model-1"][selected]))

    Cyfr.Test.ScriptedWorker.script([model_reply("hello you")])
    pane |> form("form", %{"message" => "hello me"}) |> render_submit()

    _you_thread = settled_you!(me)
    [request] = model_requests()
    assert request["model"] == "kept-model-1"

    Cyfr.Test.Sandbox.end_views()
  end

  # The panel's pane on the thread the first send created, with the turn
  # under way.
  defp panel_thread(panel, me, text) do
    pane = child!(panel, "aqua-panel-pane")
    pane |> form("form", %{"message" => text}) |> render_submit()
    [you_thread] = Threads.list(Sanctum.Context.actor(me))
    {on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id), you_thread}
  end

  defp intents(pane, thread, user, intents) do
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: intents, user_id: user.user_id}
    })

    render(pane)
  end

  test "a navigate from the panel never moves the page: a thread of You opens in the panel, another page is a link",
       %{conn: conn, user: user, mine: mine, room: room, me: me, thread: thread} do
    # The page it points to is dev's, which a person chooses.
    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "dev"})

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    Cyfr.Test.ScriptedWorker.script([model_reply("ok")])
    {pane, you_thread} = panel_thread(panel, me, "where are my activities?")

    # Another page: offered as a link, on You, and nothing pushed.
    html = intents(pane, you_thread, user, [%{kind: "navigate", to: "/activities?id=req_abc"}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert html =~ "AQUA points to"
    assert html =~ PrismWeb.Focus.path(route(mine), "/activities?id=req_abc")

    # Dismissed, it is gone.
    pane |> element(~s(button[phx-click="dismiss_link"])) |> render_click()
    refute render(pane) =~ "AQUA points to"

    # A thread of You: the panel turns to it.
    {:ok, second} = Threads.create(Sanctum.Context.actor(me))
    to = PrismWeb.ChatLive.chat_path(route(mine), second.id)
    intents(pane, you_thread, user, [%{kind: "navigate", to: to}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    on_thread!(child!(panel, "aqua-panel-pane"), second.id)

    # The page is still the room's, and the room's pane is where it was.
    assert child!(view, "pane-" <> room.id)
    assert render(panel) =~ "Reading #{room.name} · #{thread.title}"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a navigate to the chat of You that names no thread is a link, and the panel keeps its thread",
       %{conn: conn, user: user, mine: mine, room: room, me: me, thread: thread} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    Cyfr.Test.ScriptedWorker.script([model_reply("ok")])
    {pane, you_thread} = panel_thread(panel, me, "where were we?")

    # The athanor alone, no `c`: not a thread the panel could turn to.
    to = PrismWeb.ChatLive.chat_path(route(mine))
    html = intents(pane, you_thread, user, [%{kind: "navigate", to: to}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert html =~ "AQUA points to"
    assert html =~ to

    # The open thread was not blanked.
    on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)
    assert has_element?(panel, ~s(#aqua-panel-threads option[value="#{you_thread.id}"][selected]))

    Cyfr.Test.Sandbox.end_views()
  end

  test "⌘. in the panel halts the panel's turn and leaves the room's running",
       %{conn: conn, mine: mine, room: room, me: me, thread: thread} do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    room_id = room.id
    mine_id = mine.id

    # Both models are held mid-answer until each turn is stopped, so both
    # turns run for as long as the case takes: a probe's hold ends after
    # five seconds, and on a loaded host the room's run then went on to the
    # panel's item before the panel was open.
    Cyfr.Test.ScriptedWorker.script([:hang, :hang])

    room_pane = child!(view, "pane-" <> room.id)
    room_pane |> form("form", %{"message" => "@aqua go on"}) |> render_submit()

    wait_until(
      fn -> length(model_requests()) == 1 end,
      30_000,
      "the room's model to be called"
    )

    assert Runner.turn_running?(%{me | athanor_id: room_id}, thread.id)

    {panel, _html} = open_panel(view)
    {pane, you_thread} = panel_thread(panel, me, "and you?")

    wait_until(
      fn -> length(model_requests()) == 2 end,
      30_000,
      "the panel's model to be called"
    )

    assert Runner.turn_running?(%{me | athanor_id: mine_id}, you_thread.id)

    # What the hook pushes for ⌘. — to its own pane.
    render_hook(pane, "stop", %{})

    # The halt cancels the turn's run through its worker service and ends
    # the turn on the tape before the runner stops holding it: bounded as
    # the waits on the models are.
    wait_until(
      fn -> not Runner.turn_running?(%{me | athanor_id: mine_id}, you_thread.id) end,
      30_000,
      "the panel's turn to be halted"
    )

    assert Runner.turn_running?(%{me | athanor_id: room_id}, thread.id)
    assert {:ok, []} = Aqua.Tape.open_turns(me, you_thread.id)

    # The room's turn is stopped too, as its own pane's Stop would, rather
    # than left running under the sweep.
    assert :ok = Runner.stop_turn(%{me | athanor_id: room_id}, thread.id)

    wait_until(
      fn -> not Runner.turn_running?(%{me | athanor_id: room_id}, thread.id) end,
      30_000,
      "the room's turn to be stopped"
    )

    Cyfr.Test.Sandbox.end_views()
  end

  test "a grant the panel's turn needs is asked in the panel's own layer, in the person's own athanor, never the page's",
       %{conn: conn, user: user, mine: mine, room: room, me: me, in_room: in_room, thread: thread} do
    name = "panel-grant-#{System.unique_integer([:positive])}"

    for ctx <- [me, in_room] do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: name,
          version: "0.1.0",
          type: "catalyst",
          description: "A component a turn asks a grant for",
          manifest: Jason.encode!(%{})
        })
    end

    {:ok, you_thread} = Threads.create(Sanctum.Context.actor(me))

    # The page is the room's, with its own layer; the panel is You.
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    {panel, _html} = open_panel(view)
    panel |> element("#aqua-panel-threads") |> render_change(%{"id" => you_thread.id})
    pane = on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)

    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: mine.id,
      thread_id: you_thread.id,
      kind: :consent_required,
      data: %{ref: "catalyst:local.#{name}:0.1.0", user_id: user.user_id}
    })

    render(pane)
    render(panel)
    assert has_element?(panel, ~s(#system-layer-panel-dialog [data-kind="grant"]))
    assert has_element?(panel, "#system-layer-panel-dialog .consent-sheet", "in #{mine.name}")
    refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

    panel |> element(~s(#system-layer-panel-dialog button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk and commits; the panel takes its
    # layer's report, then the pane the one it hands on.
    wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    # Granted in You, not in the room the page shows.
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(me, "catalyst:local.#{name}")
    assert {:ok, []} = Sanctum.Consent.profiles(in_room, "catalyst:local.#{name}")
    assert :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil

    Cyfr.Test.Sandbox.end_views()
  end

  test "the sheet is a dialog over a page that stays live, its close button closes it, and its button names it only while open",
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
    # The panel's own system layer is a dialog of its own, not the sheet,
    # and with no prompt it is closed.
    refute has_element?(panel, "#aqua-panel-sheet[aria-modal]")
    assert html =~ ~s(id="system-layer-panel")
    assert has_element?(panel, ~s(#system-layer-panel[data-open="false"]))
    refute has_element?(panel, "#aqua-panel-sheet[phx-click-away]")
    # Escape is the sheet's own, not the window's: a dialog on the page
    # underneath keeps its Escape. The sheet's hook hears it from inside,
    # the thread's own view included, and sends `close`
    # (assets/test/aqua_panel/hook.test.mjs).
    refute has_element?(panel, "#aqua-panel-sheet[phx-window-keydown]")
    assert has_element?(panel, ~s(#aqua-panel-sheet[phx-hook="AquaPanel"]))
    assert has_element?(panel, ~s(#aqua-panel-button[aria-controls="aqua-panel-sheet"]))

    panel |> element("#aqua-panel-close") |> render_click()
    refute has_element?(panel, "#aqua-panel-sheet")
    refute has_element?(panel, "#aqua-panel-button[aria-controls]")
    assert has_element?(panel, ~s(#aqua-panel-button[aria-expanded="false"]))

    Cyfr.Test.Sandbox.end_views()
  end

  test "the panel keeps its thread from one page to the next, and closed stays closed",
       %{conn: conn, room: room, me: me, thread: thread} do
    {:ok, kept} = Threads.create(Sanctum.Context.actor(me))
    {:ok, _} = Threads.update(Sanctum.Context.actor(me), kept.id, %{title: "Kept"})

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
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
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-sheet")

    Cyfr.Test.Sandbox.end_views()
  end

  # The panel's own attribute, from its rendered markup.
  defp sheet_attr(panel, name) do
    panel
    |> element("#aqua-panel-sheet")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  test "the panel is an overlay its hook places, and Ctrl+J's toggle opens and closes it",
       %{conn: conn, room: room} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    # The keys are heard on the root, which is drawn open or closed.
    assert has_element?(panel, ~s(#aqua-panel-root[phx-hook="AquaPanelKeys"]))
    assert has_element?(panel, ~s(#aqua-panel-button[aria-keyshortcuts="Control+J"]))

    render_hook(panel, "toggle", %{})
    assert has_element?(panel, ~s(#aqua-panel-sheet.aqua-panel[phx-hook="AquaPanel"]))
    # Nothing kept: the hook opens it above its button, at its default size.
    assert sheet_attr(panel, "data-docked") == "false"
    for side <- ~w(data-x data-y data-w data-h), do: assert(sheet_attr(panel, side) == nil)
    # Its edges, the hand's handle and the header's controls.
    for edge <- ~w(n s e w ne nw se sw),
        do: assert(has_element?(panel, ~s(#aqua-panel-sheet [data-aqua-edge="#{edge}"])))

    assert has_element?(
             panel,
             ~s(#aqua-panel-sheet button[data-aqua-handle][aria-label="Change height"])
           )

    assert has_element?(panel, "#aqua-panel-sheet header[data-aqua-grip] #aqua-panel-threads")

    assert has_element?(
             panel,
             ~s(#aqua-panel-dock[aria-pressed="false"][aria-label="Pin to the right edge"])
           )

    assert has_element?(panel, ~s(#aqua-panel-close[aria-label="Close"]))

    render_hook(panel, "toggle", %{})
    refute has_element?(panel, "#aqua-panel-sheet")
    assert has_element?(panel, ~s(#aqua-panel-button[aria-expanded="false"]))

    Cyfr.Test.Sandbox.end_views()
  end

  test "where the panel stands, its size and whether it is docked follow the session from page to page",
       %{conn: conn, room: room, thread: thread} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, _html} = open_panel(view)

    render_hook(panel, "place", %{"x" => 120, "y" => 90, "w" => 420, "h" => 480})
    panel |> element("#aqua-panel-dock") |> render_click()
    assert sheet_attr(panel, "data-docked") == "true"

    assert has_element?(
             panel,
             ~s(#aqua-panel-dock[aria-pressed="true"][aria-label="Float over the page"])
           )

    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(route(room), thread.id))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    assert has_element?(panel, "#aqua-panel-sheet")

    assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-y"), sheet_attr(panel, "data-w"),
            sheet_attr(panel, "data-h"), sheet_attr(panel, "data-docked")} ==
             {"120", "90", "420", "480", "true"}

    # Floated again and closed, the placement waits for the next open.
    panel |> element("#aqua-panel-dock") |> render_click()
    panel |> element("#aqua-panel-close") |> render_click()

    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-sheet")
    {panel, _html} = open_panel(view)
    assert sheet_attr(panel, "data-docked") == "false"
    assert sheet_attr(panel, "data-w") == "420"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a placement under the minimum, off any screen or not in whole pixels is refused, and the kept one stands",
       %{conn: conn, room: room} do
    {:ok, view, _} = live(conn, athanor_path("/members", room))
    settled_render(view)
    {panel, _html} = open_panel(view)
    render_hook(panel, "place", %{"x" => 10, "y" => 60, "w" => 300, "h" => 360})

    for refused <- [
          %{"x" => 10, "y" => 60, "w" => 299, "h" => 400},
          %{"x" => 10, "y" => 60, "w" => 400, "h" => 359},
          %{"x" => -1, "y" => 60, "w" => 400, "h" => 400},
          %{"x" => 10, "y" => 100_001, "w" => 400, "h" => 400},
          %{"x" => 10, "y" => 60, "w" => 400.5, "h" => 400},
          %{"x" => "10", "y" => "60", "w" => "400", "h" => "400"},
          %{"x" => 10, "y" => 60, "w" => 400}
        ] do
      render_hook(panel, "place", refused)

      assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-w"),
              sheet_attr(panel, "data-h")} ==
               {"10", "300", "360"},
             inspect(refused)
    end

    Cyfr.Test.Sandbox.end_views()
  end

  test "the page's first paint carries the button alone; a session that no longer establishes is sent to sign in",
       %{conn: conn, room: room, thread: thread} do
    html = conn |> get(PrismWeb.ChatLive.chat_path(route(room), thread.id)) |> html_response(200)
    assert html =~ ~s(id="aqua-panel-button")
    refute html =~ "aqua-panel-sheet"

    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(CyfrWeb.SignInResponse.session_key()) => "not-a-session"
      })

    assert {:error, {:redirect, %{to: "/login"}}} =
             live_isolated(stale, PrismWeb.AquaPanelLive, session: %{"ui_mode" => "dev"})
  end
end
