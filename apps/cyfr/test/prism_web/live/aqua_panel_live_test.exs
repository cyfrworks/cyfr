# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaPanelLiveTest do
  # The person's own AQUA on the desktop: beside the shared thread the
  # chat overlay shows, the panel's send lands in You with that thread read
  # into the turn, and an answer pastes back onto it, attributed.
  # The panel itself: what the assistant points at stays in the panel, a
  # halt reaches its own turn, a grant is asked in its own layer, Escape
  # and Ctrl+J close it, it keeps its thread, its place, its size and its
  # docking across a reload (the pointer and the hand's sheet are the
  # hook's, tested in assets/test/aqua_panel/), and it deletes the open
  # thread and tries a failed fill again. Its pane is a window onto the
  # runner: two desktops of the person see one thread, a send is held while
  # the athanor is being prepared, and a file is stored for any device.
  # Driven against the real loop and a scripted model.
  use PrismWeb.ConnCase, async: false

  require Ecto.Query

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

    # The athanor is set up: a turn pins the baseline consent, and the
    # composer is held on an athanor that is still being prepared.
    {:ok, mine} = Sanctum.TestContext.mark_provisioned(mine)

    conn = log_in_user(conn, user)

    me = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}

    # The athanor filled, its soul's consent minted; the model is scripted.
    ready_athanor!(mine.id, user.user_id)
    script_model!()

    # A shared thread the two talk in, which the panel reads beside it.
    {:ok, team} = Sanctum.SharedThreads.create(user.user_id, "Plans #{n}")
    {:ok, :added} = Sanctum.SharedThreads.add(user.user_id, team.id, user_id: other.user_id)
    {:ok, _} = Sanctum.SharedThreads.post(other.user_id, team.id, "ship friday")

    {:ok, conn: conn, user: user, mine: mine, me: me, team: team}
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

  # The person's desktop, under the session `conn` carries: a reload is a
  # second mount of it.
  defp desktop!(conn) do
    {view, _html} = mount_desktop(conn)
    view
  end

  defp open_panel(view) do
    panel = child!(view, "aqua-panel")
    html = panel |> element("#aqua-panel-button") |> render_click()
    {panel, html}
  end

  # The chat overlay on the desktop, opened on the shared thread `thread`.
  defp beside!(view, thread) do
    overlay = child!(view, "chat-overlay")
    overlay |> element("#chat-button") |> render_click()
    overlay |> element("#shared-thread-#{thread.id} button") |> render_click()
    overlay
  end

  # The panel's pane, turned to thread `id`.
  defp select!(panel, id) do
    panel |> element("#aqua-panel-threads") |> render_change(%{"id" => id})
    on_thread!(child!(panel, "aqua-panel-pane"), id)
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

  test "the panel opens onto You beside the shared thread the chat shows, and a send lands in You with that thread read into the turn",
       %{conn: conn, me: me, team: team, user: user} do
    view = desktop!(conn)
    beside!(view, team)

    {panel, html} = open_panel(view)
    assert has_element?(panel, ~s(#aqua-panel-sheet[aria-label="Your AQUA"] header), "AQUA")
    assert html =~ "Reading #{team.title}"

    pane = child!(panel, "aqua-panel-pane")
    assert thread_of(pane) == nil
    assert render(pane) =~ "Read #{team.title}"

    refute has_element?(pane, ~s(label[title*="room"])),
           "the shared-thread read tooltip still says room"

    assert has_element?(pane, ~s(label[title*="thread beside it"]))

    Cyfr.Test.ScriptedWorker.script([model_reply("They mean Friday.")])
    pane |> form("form", %{"message" => "what do they mean?"}) |> render_submit()

    # In You, and only there — with the shared thread read into the turn's
    # request beside the task, never into the system prompt.
    you_thread = settled_you!(me)
    [request] = model_requests()
    text = request_text(request)
    assert text =~ "## Read from a shared thread"
    assert text =~ "ship friday"
    assert text =~ "what do they mean?"
    refute request["system"] =~ "ship friday"

    assert Enum.any?(
             Threads.latest_messages(Sanctum.Context.actor(me), you_thread.id, 10),
             &(&1.content == "what do they mean?")
           )

    {:ok, said} = Sanctum.SharedThreads.messages(user.user_id, team.id)
    refute Enum.any?(said, &(&1.content == "what do they mean?"))

    # The pane is on the thread its first message created.
    on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "the panel reads what the chat shows: another shared thread, and none once the chat closes",
       %{conn: conn, team: team, user: user} do
    {:ok, second} = Sanctum.SharedThreads.create(user.user_id, "Second thread")

    view = desktop!(conn)
    overlay = beside!(view, team)
    {panel, html} = open_panel(view)
    assert html =~ "Reading #{team.title}"

    overlay |> element("#shared-thread-#{second.id} button") |> render_click()
    assert render(panel) =~ "Reading Second thread"

    overlay |> element("#chat-close") |> render_click()
    refute has_element?(panel, "#aqua-panel-room")

    Cyfr.Test.Sandbox.end_views()
  end

  test "an answer in the panel pastes onto the shared thread, attributed, and that thread's pane shows it",
       %{conn: conn, user: user, me: me, team: team} do
    view = desktop!(conn)
    overlay = beside!(view, team)
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

    assert html =~ "Pasted onto #{team.title}"

    {:ok, said} = Sanctum.SharedThreads.messages(user.user_id, team.id)
    copy = Enum.find(said, &(&1.content == "They mean Friday."))
    assert copy.author == user.user_id

    {:ok, stored} = Arca.SharedMessages.get(Prima.Actor.system(), team.id, copy.id)
    assert stored.payload["shared_agent"] == true

    # The shared thread's own pane in the chat heard of it.
    shared_pane = child!(overlay, "chat-thread-" <> team.id)

    wait_until(
      fn -> render(shared_pane) =~ "They mean Friday." end,
      5_000,
      "the pasted answer in the chat's pane"
    )

    Cyfr.Test.Sandbox.end_views()
  end

  test "with no shared thread open beside it the panel reads nothing and sends plainly",
       %{conn: conn, mine: mine, me: me} do
    {panel, _html} = open_panel(desktop!(conn))
    assert has_element?(panel, ~s(#aqua-panel-sheet[aria-label="Your AQUA"] header), "AQUA")
    refute has_element?(panel, "#aqua-panel-room")

    pane = child!(panel, "aqua-panel-pane")
    refute render(pane) =~ "with each message"
    Cyfr.Test.ScriptedWorker.script([model_reply("hello you")])
    pane |> form("form", %{"message" => "hello me"}) |> render_submit()

    you_thread = settled_you!(me)
    assert you_thread.athanor_id == mine.id
    [request] = model_requests()
    refute request_text(request) =~ "Read from a shared thread"

    Cyfr.Test.Sandbox.end_views()
  end

  test "the thread's menu carries the model override, the soul or crew member and the counts, and a model chosen there is the one the next send asks",
       %{conn: conn, mine: mine, me: me} do
    :ok = PrismWeb.ModelCatalog.remember(mine.id, %{"models" => %{"kept" => ["kept-model-1"]}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(mine.id) end)

    {panel, _html} = open_panel(desktop!(conn))
    # The header's toggle opens the pane's menu, an element of the panel
    # that the hook shows; it is drawn hidden.
    assert has_element?(
             panel,
             ~s(#aqua-panel-more[data-aqua-menu-toggle][aria-controls="aqua-panel-pane-menu"][aria-expanded="false"])
           )

    pane = child!(panel, "aqua-panel-pane")
    menu = ~s(#aqua-panel-pane-menu[hidden])

    wait_until(
      fn -> has_element?(pane, ~s(#{menu} select[name="model"] option[value="kept-model-1"])) end,
      5_000,
      "the catalogue in the panel's menu"
    )

    assert has_element?(pane, menu, "Soul or crew member")
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

  test "a navigate from the panel never moves the page: it is a link, nothing is pushed, and the panel keeps its thread",
       %{conn: conn, user: user, mine: mine, me: me, team: team} do
    # The page it points to is dev's, which a person chooses.
    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "dev"})

    view = desktop!(conn)
    overlay = beside!(view, team)
    {panel, _html} = open_panel(view)
    Cyfr.Test.ScriptedWorker.script([model_reply("ok")])
    {pane, you_thread} = panel_thread(panel, me, "where are my activities?")

    html = intents(pane, you_thread, user, [%{kind: "navigate", to: "/activities?id=req_abc"}])
    refute_push_event(pane, "aqua:intents", %{intents: _})
    assert html =~ "AQUA points to"
    assert html =~ PrismWeb.Focus.path(route(mine), "/activities?id=req_abc")

    # The panel is on the thread it was on, and the chat beside it is where
    # it was.
    on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)
    assert has_element?(panel, ~s(#aqua-panel-threads option[value="#{you_thread.id}"][selected]))
    assert find_live_child(overlay, "chat-thread-" <> team.id)

    # Dismissed, it is gone.
    pane |> element(~s(button[phx-click="dismiss_link"])) |> render_click()
    refute render(pane) =~ "AQUA points to"

    Cyfr.Test.Sandbox.end_views()
  end

  test "the panel lists the requests waiting on the crew, and one turns the panel to the thread it was asked in",
       %{conn: conn, me: me} do
    actor = Sanctum.Context.actor(me)
    {:ok, room} = Threads.create(actor)
    {:ok, child} = Threads.crew_thread(actor, room.id, "builder")

    {:ok, %{message: request}} =
      Aqua.Tape.accept(me, room.id, %{
        message: %{
          author: me.user_id,
          sent_by: "person",
          addressee: "builder",
          status: "pending",
          content: "Build the site\nand test it"
        }
      })

    {panel, _html} = open_panel(desktop!(conn))

    waiting = "#aqua-panel-pending-#{request.id}"
    assert has_element?(panel, waiting, "builder")
    assert has_element?(panel, waiting, "from You")
    assert has_element?(panel, waiting, "Build the site")
    refute has_element?(panel, waiting, "and test it")

    # A crew member's thread is reached from its room, never listed.
    assert has_element?(panel, ~s(#aqua-panel-threads option[value="#{room.id}"]))
    refute has_element?(panel, ~s(#aqua-panel-threads option[value="#{child.id}"]))

    panel |> element("#{waiting} button") |> render_click()
    on_thread!(child!(panel, "aqua-panel-pane"), room.id)
    assert has_element?(panel, ~s(#aqua-panel-threads option[value="#{room.id}"][selected]))

    Cyfr.Test.Sandbox.end_views()
  end

  test "⌘. in the panel halts the panel's turn",
       %{conn: conn, mine: mine, me: me} do
    view = desktop!(conn)
    mine_id = mine.id

    # The model is held mid-answer until the turn is stopped, so the turn
    # runs for as long as the case takes.
    Cyfr.Test.ScriptedWorker.script([:hang])

    {panel, _html} = open_panel(view)
    {pane, you_thread} = panel_thread(panel, me, "and you?")

    wait_until(
      fn -> length(model_requests()) == 1 end,
      30_000,
      "the panel's model to be called"
    )

    assert Runner.turn_running?(%{me | athanor_id: mine_id}, you_thread.id)

    # What the hook pushes for ⌘. — to its own pane.
    render_hook(pane, "stop", %{})

    # The halt cancels the turn's run through its worker service and ends
    # the turn on the tape before the runner stops holding it: bounded as
    # the wait on the model is.
    wait_until(
      fn -> not Runner.turn_running?(%{me | athanor_id: mine_id}, you_thread.id) end,
      30_000,
      "the panel's turn to be halted"
    )

    assert {:ok, []} = Aqua.Tape.open_turns(me, you_thread.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "a grant the panel's turn needs is asked in the panel's own layer, in the person's own athanor, never the desktop's",
       %{conn: conn, user: user, mine: mine, me: me, team: team} do
    name = "panel-grant-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compendium.Registry.publish_bytes(me, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A component a turn asks a grant for",
        manifest: Jason.encode!(%{})
      })

    {:ok, you_thread} = Threads.create(Sanctum.Context.actor(me))

    # The desktop has its own layer, beside the shared thread the chat
    # shows; the panel is You.
    view = desktop!(conn)
    beside!(view, team)
    {panel, _html} = open_panel(view)
    pane = select!(panel, you_thread.id)

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
    desktop_dialog = "#" <> PrismWeb.SystemLayer.desktop_layer_id() <> "-dialog"
    refute has_element?(view, ~s(#{desktop_dialog} [data-kind="grant"]))

    panel |> element(~s(#system-layer-panel-dialog button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk and commits; the panel takes its
    # layer's report, then the pane the one it hands on.
    wait_until(
      fn -> :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the pane to hear its grant"
    )

    # Granted in You.
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(me, "catalyst:local.#{name}")
    assert :sys.get_state(pane.pid).socket.assigns.grant_prompt == nil

    Cyfr.Test.Sandbox.end_views()
  end

  test "the sheet is a dialog over a page that stays live, its close button closes it, and its button names it only while open",
       %{conn: conn} do
    view = desktop!(conn)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-button[aria-controls]")

    {panel, html} = open_panel(view)
    assert has_element?(panel, ~s(#aqua-panel-sheet[role="dialog"][aria-label="Your AQUA"]))
    # Not modal: the shared thread under it is what the panel reads and
    # pastes into, so nothing claims a focus trap the page does not have —
    # and a click on the page (to scroll it, to select a line) does not
    # close the panel.
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

  test "the panel keeps its thread across a reload, and closed stays closed",
       %{conn: conn, me: me} do
    {:ok, kept} = Threads.create(Sanctum.Context.actor(me))
    {:ok, _} = Threads.update(Sanctum.Context.actor(me), kept.id, %{title: "Kept"})

    {panel, _html} = open_panel(desktop!(conn))
    select!(panel, kept.id)

    # A reload mounts the desktop and its panel afresh; the same session
    # finds the same panel.
    panel = child!(desktop!(conn), "aqua-panel")
    assert has_element?(panel, "#aqua-panel-sheet")
    on_thread!(child!(panel, "aqua-panel-pane"), kept.id)

    render_click(panel, "close", %{})
    panel = child!(desktop!(conn), "aqua-panel")
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
       %{conn: conn} do
    panel = child!(desktop!(conn), "aqua-panel")
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

  test "where the panel stands, its size and whether it is docked follow the session across a reload",
       %{conn: conn} do
    {panel, _html} = open_panel(desktop!(conn))

    render_hook(panel, "place", %{
      "x" => 120,
      "y" => 90,
      "w" => 420,
      "h" => 480,
      "vw" => 1440,
      "vh" => 900
    })

    panel |> element("#aqua-panel-dock") |> render_click()
    assert sheet_attr(panel, "data-docked") == "true"

    assert has_element?(
             panel,
             ~s(#aqua-panel-dock[aria-pressed="true"][aria-label="Float over the page"])
           )

    panel = child!(desktop!(conn), "aqua-panel")
    assert has_element?(panel, "#aqua-panel-sheet")

    assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-y"), sheet_attr(panel, "data-w"),
            sheet_attr(panel, "data-h"), sheet_attr(panel, "data-docked")} ==
             {"120", "90", "420", "480", "true"}

    # Floated again and closed, the placement waits for the next open.
    panel |> element("#aqua-panel-dock") |> render_click()
    panel |> element("#aqua-panel-close") |> render_click()

    view = desktop!(conn)
    panel = child!(view, "aqua-panel")
    refute has_element?(panel, "#aqua-panel-sheet")
    {panel, _html} = open_panel(view)
    assert sheet_attr(panel, "data-docked") == "false"
    assert sheet_attr(panel, "data-w") == "420"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a placement outside the viewport it was made in, under the minimum or not in whole pixels is refused, and the kept one stands",
       %{conn: conn} do
    {panel, _html} = open_panel(desktop!(conn))
    screen = %{"vw" => 1440, "vh" => 900}

    render_hook(
      panel,
      "place",
      Map.merge(%{"x" => 10, "y" => 60, "w" => 300, "h" => 360}, screen)
    )

    for refused <- [
          # Under the minimum, or left of or above the viewport.
          %{"x" => 10, "y" => 60, "w" => 299, "h" => 400},
          %{"x" => 10, "y" => 60, "w" => 400, "h" => 359},
          %{"x" => -1, "y" => 60, "w" => 400, "h" => 400},
          # Past the viewport's right or bottom edge: Sol's rectangle, and
          # one a pixel over each edge.
          %{"x" => 12_000, "y" => 12_000, "w" => 4000, "h" => 4000},
          %{"x" => 1041, "y" => 60, "w" => 400, "h" => 400},
          %{"x" => 10, "y" => 501, "w" => 400, "h" => 400},
          %{"x" => 10, "y" => 60, "w" => 400.5, "h" => 400},
          %{"x" => "10", "y" => "60", "w" => "400", "h" => "400"}
        ] do
      render_hook(panel, "place", Map.merge(refused, screen))

      assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-w"),
              sheet_attr(panel, "data-h")} ==
               {"10", "300", "360"},
             inspect(refused)
    end

    # A placement with no viewport, or a viewport no screen has, is refused
    # however small it is.
    for viewport <- [
          %{},
          %{"vw" => 1440},
          %{"vw" => 319, "vh" => 900},
          %{"vw" => 1440, "vh" => 16_001},
          %{"vw" => "1440", "vh" => "900"}
        ] do
      render_hook(
        panel,
        "place",
        Map.merge(%{"x" => 20, "y" => 60, "w" => 400, "h" => 400}, viewport)
      )

      assert sheet_attr(panel, "data-x") == "10", inspect(viewport)
    end

    # The viewport is the bound: a placement filling it exactly is kept,
    # and so is one made on a very large screen.
    render_hook(
      panel,
      "place",
      Map.merge(%{"x" => 1040, "y" => 500, "w" => 400, "h" => 400}, screen)
    )

    assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-y")} == {"1040", "500"}

    render_hook(
      panel,
      "place",
      %{"x" => 12_000, "y" => 12_000, "w" => 4000, "h" => 4000, "vw" => 16_000, "vh" => 16_000}
    )

    assert {sheet_attr(panel, "data-x"), sheet_attr(panel, "data-w"), sheet_attr(panel, "data-h")} ==
             {"12000", "4000", "4000"}

    Cyfr.Test.Sandbox.end_views()
  end

  test "the desktop's first paint carries the button alone; a session that no longer establishes is sent to sign in",
       %{conn: conn, mine: mine} do
    html = conn |> get(athanor_path("", mine)) |> html_response(200)
    assert html =~ ~s(id="aqua-panel-button")
    refute html =~ "aqua-panel-sheet"

    stale =
      Plug.Test.init_test_session(build_conn(), %{
        to_string(CyfrWeb.SignInResponse.session_key()) => "not-a-session"
      })

    assert {:error, {:redirect, %{to: "/login"}}} =
             live_isolated(stale, PrismWeb.AquaPanelLive, session: %{"ui_mode" => "dev"})
  end

  # The pane's empty state as a person reads it, its whitespace folded.
  defp empty_state(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id$="-thread"] > div.justify-center))
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp member_ctx(person, athanor) do
    Sanctum.Context.build(
      user_id: person.user_id,
      athanor_id: athanor.id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # A person of their own whose athanor was minted and never filled, signed
  # in on it. Answers the person, the athanor, the conn and their context.
  defp unfilled! do
    person = test_user()
    own = Sanctum.Test.People.athanor!(person.user_id)
    conn = log_in_user(build_conn(), person, athanor_id: own.id)
    ctx = %{Sanctum.TestContext.local() | user_id: person.user_id, athanor_id: own.id}
    {person, own, conn, ctx}
  end

  # The fill's claim held elsewhere, so the athanor stays unfilled and a
  # mount's attempt returns at once instead of running a fill this test
  # never awaits.
  defp hold_fill!(own) do
    {:ok, _held} =
      Arca.ProvisioningClaims.claim(
        %Prima.Actor{athanor_id: own.id},
        "boot_elsewhere/own_held",
        "first_need",
        60_000,
        :none
      )
  end

  test "a reply reaches every desktop of the person on that thread: the runner writes it, not the sender's socket",
       %{conn: conn, user: user, me: me} do
    {panel, _html} = open_panel(desktop!(conn))
    pane = child!(panel, "aqua-panel-pane")

    # The athanor's fill bound a key behind its soul's model, so the empty
    # thread asks for a message and offers no model to connect.
    assert empty_state(render(pane)) == "Ask AQUA anything."
    refute render(pane) =~ "A.Q.U.A."

    Cyfr.Test.ScriptedWorker.script([model_reply("Hi there")])
    pane |> form("form", %{"message" => "@aqua hello from me"}) |> render_submit()
    you_thread = settled_you!(me)

    # The person's other desktop, under a session of its own, opens the same
    # thread and reads the reply the runner wrote.
    {other, _html} = open_panel(desktop!(log_in_user(build_conn(), user)))
    other_pane = select!(other, you_thread.id)
    assert render(other_pane) =~ "hello from me"
    assert render(other_pane) =~ "Hi there"
    refute render(other_pane) =~ "is asking"

    sender = on_thread!(child!(panel, "aqua-panel-pane"), you_thread.id)
    wait_until(fn -> render(sender) =~ "Hi there" end, 5_000, "the reply in the sender's pane")

    agent = Arca.Schemas.Message.agent_author()

    assert [%{author: author}, %{kind: "text", author: ^agent}] =
             Threads.messages(Sanctum.Context.actor(me), you_thread.id)
             |> Enum.filter(&(&1.kind == "text"))

    assert author == user.user_id

    Cyfr.Test.Sandbox.end_views()
  end

  test "an attachment is stored as a blob the person can fetch on any device, and never from outside",
       %{conn: conn, user: user, mine: mine, me: me} do
    Cyfr.Test.ScriptedWorker.script([model_reply("Read them.")])
    again_conn = log_in_user(build_conn(), user)
    carol_conn = log_in_user(build_conn(), test_user())

    {panel, _html} = open_panel(desktop!(conn))
    pane = child!(panel, "aqua-panel-pane")

    for {name, content, type} <- [
          {"note.txt", "hi there", "text/plain"},
          {"plan.md", "second", "text/markdown"}
        ] do
      pane
      |> file_input("form[phx-submit=submit]", :attachments, [
        %{name: name, content: content, type: type}
      ])
      |> render_upload(name)
    end

    pane |> form("form[phx-submit=submit]", %{"message" => "@aqua read these"}) |> render_submit()
    thread = settled_you!(me)

    # The files rode the model request on the task: text files the brain
    # does not take inline (it takes PNG and PDF) as text blocks under
    # their names.
    [request] = model_requests()
    blocks = Enum.flat_map(request["messages"], & &1["content"])

    assert %{"type" => "text", "text" => "The attached file note.txt:\n\nhi there"} in blocks
    assert %{"type" => "text", "text" => "The attached file plan.md:\n\nsecond"} in blocks
    refute Enum.any?(blocks, &(&1["type"] == "document"))

    [msg | _] = Threads.messages(Sanctum.Context.actor(me), thread.id)
    refs = msg |> Aqua.attachment_refs() |> Enum.sort_by(& &1["filename"])
    assert Enum.map(refs, & &1["filename"]) == ["note.txt", "plan.md"]
    assert Enum.map(refs, & &1["size"]) == [8, 6]

    # The bytes are the record: one blob per ref, under the message, the
    # location rebuilt from row identity and never kept in the ref.
    for ref <- refs do
      refute Map.has_key?(ref, "path")

      assert {:ok, ["threads", thread_id, msg_id, _name] = blob} =
               Aqua.attachment_blob_path(thread.id, msg.id, ref)

      assert thread_id == thread.id and msg_id == msg.id
      assert Arca.exists?(Sanctum.Context.actor(me), blob)
    end

    note = Enum.find(refs, &(&1["filename"] == "note.txt"))
    plan = Enum.find(refs, &(&1["filename"] == "plan.md"))

    # The person reads the bytes back on any device, addressed by the
    # stored name so same-named uploads stay distinct; the download still
    # carries the display filename, and the type is served safe.
    path = athanor_path("/attachments/#{msg.id}/#{note["stored_name"]}", mine)
    resp = get(again_conn, path)
    assert resp.status == 200
    assert resp.resp_body == "hi there"
    assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="note.txt")]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    # An undeclared type is served as opaque bytes, never as what the uploader said.
    md = get(again_conn, athanor_path("/attachments/#{msg.id}/#{plan["stored_name"]}", mine))
    assert md.status == 200
    assert get_resp_header(md, "content-type") == ["application/octet-stream"]

    # A person outside the athanor gets nothing; so does an anonymous request.
    assert get(carol_conn, path).status == 404
    assert redirected_to(get(build_conn(), path)) == "/login"
    assert get(again_conn, athanor_path("/attachments/#{msg.id}/nope.txt", mine)).status == 404

    Cyfr.Test.Sandbox.end_views()
  end

  test "a draft offered back after a reload deletes no attachment its pane did not store, a sent one of another desktop's included",
       %{conn: conn, user: user, me: me} do
    Cyfr.Test.ScriptedWorker.script([model_reply("Kept.")])
    again_conn = log_in_user(build_conn(), user)

    {panel, _html} = open_panel(desktop!(conn))
    pane = child!(panel, "aqua-panel-pane")

    pane
    |> file_input("form[phx-submit=submit]", :attachments, [
      %{name: "note.txt", content: "alice's bytes", type: "text/plain"}
    ])
    |> render_upload("note.txt")

    pane |> form("form[phx-submit=submit]", %{"message" => "@aqua keep this"}) |> render_submit()

    thread = settled_you!(me)
    [msg | _] = Threads.messages(Sanctum.Context.actor(me), thread.id)
    [ref] = Aqua.attachment_refs(msg)
    {:ok, blob} = Aqua.attachment_blob_path(thread.id, msg.id, ref)
    assert {:ok, "alice's bytes"} = Arca.get(Sanctum.Context.actor(me), blob)

    # The pane stored the file through the gate: one admitted decision of
    # the person's for `thread/attach`.
    user_id = user.user_id

    assert [%{admission: "admitted"}] =
             Arca.Repo.all(
               Ecto.Query.from(d in Arca.Schemas.DecisionLog,
                 where: d.tool == "thread" and d.action == "attach" and d.user_id == ^user_id
               )
             )

    # The person's other desktop offers back a "held send" naming the
    # message the first sent and its file, with a text the send refuses: the
    # refusal discards nothing this pane did not store itself.
    {other, _html} = open_panel(desktop!(again_conn))
    other_pane = select!(other, thread.id)

    render_hook(other_pane, "restore_draft", %{
      "thread_id" => thread.id,
      "client_id" => Prima.UUID7.generate_id("snd"),
      "message_id" => msg.id,
      "text" => String.duplicate("x", 40_000),
      "attachments" => [ref]
    })

    _ = render(other_pane)
    assert {:ok, "alice's bytes"} = Arca.get(Sanctum.Context.actor(me), blob)

    Cyfr.Test.Sandbox.end_views()
  end

  test "an athanor still being set up says so in the panel, which tries the fill again, and its pane holds the composer until the fill completes" do
    # No bundle to fill it from: the fill fails, and says so.
    Prima.Test.Env.put_app_env(
      :arca,
      :seed_path,
      Path.join(System.tmp_dir!(), "no_seed_#{System.unique_integer([:positive])}")
    )

    {_person, own, conn, _ctx} = unfilled!()

    {panel, html} = open_panel(desktop!(conn))
    assert html =~ "still being set up"

    panel |> element("#aqua-panel-provisioning button[phx-click=provision]") |> render_click()

    rendered = render(panel)
    assert rendered =~ "Still not set up"
    assert rendered =~ "last attempt failed at"
    {:ok, row} = Athanors.get(own.id)
    assert %{step: _} = Athanors.provisioning_failure(row)

    # The pane holds its composer while the athanor is being prepared, and
    # says why instead of blaming a missing model.
    pane = child!(panel, "aqua-panel-pane")
    pane_html = render(pane)
    assert pane_html =~ "still being prepared"
    assert pane_html =~ "Still being prepared"
    refute pane_html =~ "has no model yet"

    # The fill completing reaches the pane without a reload: provisioning
    # broadcasts on the athanor's own topic.
    {:ok, filled} = Sanctum.TestContext.mark_provisioned(row)
    Sanctum.Notify.broadcast(own.id, :athanor_changed, %{name: filled.name})
    refute render(pane) =~ "Still being prepared"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a message sent while the athanor is prepared is held, offered back after a reload, and accepted once" do
    Prima.Test.Env.put_app_env(:sanctum, :provisioning_inline, false)
    {person, own, conn, ctx} = unfilled!()
    hold_fill!(own)

    {panel, _html} = open_panel(desktop!(conn))
    pane = child!(panel, "aqua-panel-pane")
    pane |> form("form", %{"message" => "@aqua hold this"}) |> render_submit()

    # Held, not refused: the pane says so, the browser is given the whole
    # send to keep, and nothing was written.
    assert_push_event(pane, "aqua:held_send", %{
      envelope:
        %{"client_id" => client_id, "message_id" => message_id, "thread_id" => thread_id} =
          envelope
    })

    assert render(pane) =~ "Retry"
    assert [] == Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10)

    # A reload: the panel the send turned to its new thread opens on it
    # again, the hook offers the held send back, and it is held again under
    # the same identity.
    render(panel)

    reloaded =
      on_thread!(child!(child!(desktop!(conn), "aqua-panel"), "aqua-panel-pane"), thread_id)

    render_hook(reloaded, "restore_draft", envelope)
    assert render(reloaded) =~ "Retry"
    assert_push_event(reloaded, "aqua:held_send", %{envelope: %{"message_id" => ^message_id}})
    assert [] == Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10)

    # The fill completes: every pane holding the send retries on its own,
    # the athanor accepts the message once, and the turn runs.
    Cyfr.Test.ScriptedWorker.script([model_reply("Held, then heard")])
    ready_athanor!(own.id, person.user_id)
    {:ok, row} = Athanors.get(own.id)
    {:ok, filled} = Sanctum.TestContext.mark_provisioned(row)
    Sanctum.Notify.broadcast(own.id, :athanor_changed, %{name: filled.name})

    wait_until(
      fn ->
        Enum.any?(
          Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10),
          &(&1.id == message_id)
        ) and match?({:ok, []}, Aqua.Tape.open_turns(ctx, thread_id))
      end,
      60_000
    )

    assert_push_event(reloaded, "aqua:held_send", %{envelope: nil}, 5_000)
    assert_push_event(pane, "aqua:held_send", %{envelope: nil}, 5_000)
    refute render(reloaded) =~ "Retry"

    rows = Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 50)
    assert [%{id: ^message_id}] = Enum.filter(rows, &(&1.author == person.user_id))
    assert Enum.any?(rows, &(&1.content == "Held, then heard"))
    wait_until(fn -> render(reloaded) =~ "Held, then heard" end)

    # The harness offering the same send names the same identity: the
    # console and the wire agree on what was accepted.
    assert {:ok, %{replayed: true, message_id: ^message_id}} =
             Aqua.Providers.Thread.handle("thread", member_ctx(person, own), %{
               "action" => "send",
               "thread" => thread_id,
               "message" => "@aqua hold this",
               "client_id" => client_id
             })

    assert [%{id: ^message_id}] =
             Enum.filter(
               Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 50),
               &(&1.author == person.user_id)
             )

    Cyfr.Test.Sandbox.end_views()
  end

  test "a desktop on an athanor still being filled does not wait for the fill" do
    # The real path: the fill is a task nothing awaits, so a mount cannot be
    # held open by it. The suite otherwise fills inline so its assertions can
    # read rows straight after the call.
    Prima.Test.Env.put_app_env(:sanctum, :provisioning_inline, false)
    {_person, own, conn, _ctx} = unfilled!()
    hold_fill!(own)

    started = System.monotonic_time(:millisecond)
    {panel, html} = open_panel(desktop!(conn))
    _ = render(child!(panel, "aqua-panel-pane"))
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert html =~ "still being set up"

    Cyfr.Test.Sandbox.end_views()
  end

  test "the open thread of You is deleted from the panel's header, which turns to a blank thread; a crew member's thread has no delete",
       %{conn: conn, me: me} do
    actor = Sanctum.Context.actor(me)
    {:ok, doomed} = Threads.create(actor)
    {:ok, room} = Threads.create(actor)
    {:ok, child} = Threads.crew_thread(actor, room.id, "builder")

    {panel, _html} = open_panel(desktop!(conn))
    # The blank thread has nothing to delete.
    refute has_element?(panel, "#aqua-panel-delete")

    pane = select!(panel, doomed.id)
    panel |> element("#aqua-panel-delete") |> render_click()

    assert {:error, :not_found} = Threads.get(actor, doomed.id)
    refute has_element?(panel, ~s(#aqua-panel-threads option[value="#{doomed.id}"]))
    assert has_element?(panel, ~s(#aqua-panel-threads option[value=""][selected]))
    wait_until(fn -> thread_of(pane) == nil end, 5_000, "the pane on a blank thread")

    # A crew member's thread is its room's, reached from it.
    select!(panel, room.id)
    pane |> element(~s([id$="-crew-#{child.id}"])) |> render_click()
    on_thread!(pane, child.id)
    refute has_element?(panel, "#aqua-panel-delete")

    Cyfr.Test.Sandbox.end_views()
  end

  test "a thread chosen in the panel turns its one pane, New thread to a blank one, and a reload finds it blank",
       %{conn: conn, me: me} do
    actor = Sanctum.Context.actor(me)
    {:ok, first} = Threads.create(actor)
    {:ok, second} = Threads.create(actor)

    {panel, _html} = open_panel(desktop!(conn))
    pane = select!(panel, first.id)
    select!(panel, second.id)
    assert child!(panel, "aqua-panel-pane").pid == pane.pid

    panel |> element("#aqua-panel-threads") |> render_change(%{"id" => ""})
    wait_until(fn -> thread_of(pane) == nil end, 5_000, "the pane on a blank thread")
    assert child!(panel, "aqua-panel-pane").pid == pane.pid

    # The blank thread is a place: a reload finds it, not the newest thread.
    panel = child!(desktop!(conn), "aqua-panel")
    assert has_element?(panel, ~s(#aqua-panel-threads option[value=""][selected]))
    assert thread_of(child!(panel, "aqua-panel-pane")) == nil

    Cyfr.Test.Sandbox.end_views()
  end

  describe "an ask from the desktop" do
    test "opens the panel with Prism's sentence after the person's draft, attaching and sending nothing",
         %{conn: conn, me: me, mine: mine} do
      # The catalogue held, so the pane lists its models with no run that
      # could outlive the test.
      :ok = PrismWeb.ModelCatalog.remember(mine.id, %{"models" => %{"kept" => ["kept-model-1"]}})
      on_exit(fn -> PrismWeb.ModelCatalog.forget(mine.id) end)

      shell = desktop!(conn)
      topic = :sys.get_state(shell.pid).socket.assigns.aqua_ask
      panel = child!(shell, "aqua-panel")
      refute has_element?(panel, "#aqua-panel-sheet")

      :ok = Cyfr.Bus.broadcast_page(topic, Cyfr.Bus.AquaAsk.new("About the runs widget: "))
      pane = child!(panel, "aqua-panel-pane")

      wait_until(
        fn -> :sys.get_state(pane.pid).socket.assigns.input == "About the runs widget: " end,
        2_000
      )

      assert has_element?(panel, "#aqua-panel-sheet")

      # A draft the person has is kept, the next sentence after it.
      pane |> element("textarea[name=message]") |> render_change(%{"message" => "my own words"})
      :ok = Cyfr.Bus.broadcast_page(topic, Cyfr.Bus.AquaAsk.new("About the apps widget: "))

      wait_until(
        fn ->
          :sys.get_state(pane.pid).socket.assigns.input ==
            "my own words\n\nAbout the apps widget: "
        end,
        2_000
      )

      # Nothing was sent: no thread of You was made, and nothing is attached.
      assert Threads.list(Sanctum.Context.actor(me)) == []
      assert :sys.get_state(pane.pid).socket.assigns.uploads.attachments.entries == []

      Cyfr.Test.Sandbox.end_views()
    end
  end
end
