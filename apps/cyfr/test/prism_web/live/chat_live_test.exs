# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatLiveTest do
  # The chat page is a window onto the runner: two members of the same
  # athanor see one thread, and a turn keeps going when the sender's tab is
  # closed. Driven against the real loop and a scripted model.
  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.Wait

  alias Arca.ConversationStorage, as: Conversations

  setup do
    test_path = Path.join(System.tmp_dir!(), "conv_live_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      # A turn the test left finishing may still write under the path; the
      # runners are stopped after this callback, so the removal tolerates it.
      File.rm_rf(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    # The estate most of these tests chat in. A group, because no estate is
    # shared server-wide and several of them seat two people together.
    {:ok, estate} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "group",
        name: "Chat",
        slug: "chat-#{System.unique_integer([:positive])}",
        created_by: "system"
      })

    # Set up, like an estate people actually chat in: a turn pins the
    # baseline consent, and sending is held while one is being prepared.
    {:ok, estate} = Sanctum.Tenancy.Athanors.mark_provisioned(estate)
    Process.put(:chat_estate, estate)

    # Filled like an estate people actually chat in, with its soul's
    # consent minted; the model it names is scripted.
    ready_estate!(estate.id, Sanctum.TestContext.local().user_id)
    script_model!()

    :ok
  end

  defp member_ctx(user, athanor) do
    Sanctum.Context.build(
      user_id: user.user_id,
      athanor_id: athanor.id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end

  # The one thread the estate holds, once its turn has ended.
  defp settled_thread!(ctx) do
    wait_until(
      fn ->
        match?([_], Conversations.list(ctx)) and
          match?({:ok, []}, Aqua.Tape.open_turns(ctx, hd(Conversations.list(ctx)).id))
      end,
      60_000
    )

    [conv] = Conversations.list(ctx)
    conv
  end

  # The chat's address for an estate (the shared one by default) and a thread.
  defp chat_path(athanor, conv_id \\ nil) do
    athanor = athanor || estate()
    PrismWeb.ChatLive.chat_path(Sanctum.Tenancy.Athanors.route_slug(athanor), conv_id)
  end

  defp mount_chat(conn, athanor \\ nil, conv_id \\ nil) do
    {:ok, view, _mount_html} = live(conn, chat_path(athanor, conv_id))
    {view, settled_render(view)}
  end

  # The open thread is a nested LiveView of its own: events reach it by
  # name, a different thread is a different child, and what the tape shows
  # is read by rendering the pane — a render of the page does not wait for
  # the pane's process to apply a broadcast.
  defp pane(view), do: Enum.find(live_children(view), &String.starts_with?(&1.id, "pane-"))

  # The thread the estate's one pane is turned to, from its own state.
  defp pane_thread(view), do: :sys.get_state(pane(view).pid).socket.assigns.conversation

  test "the rail lists every estate you belong to, and opening one moves the tape, not the bench",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Rail #{alice.namespace}")
    :ok = Sanctum.TestContext.shipped!(group.id)

    {view, html} = mount_chat(conn)
    assert html =~ "Rail #{alice.namespace}"
    assert has_element?(view, "#estate-" <> group.id)
    # The tape is the shared estate's, and the open estate says so to a
    # screen reader.
    assert render(pane(view)) =~ "in Chat"
    assert has_element?(view, "#estate-#{estate().id} button[aria-current=true]", "Chat")

    view
    |> element("#estate-#{group.id} button[phx-click=open_estate]")
    |> render_click()

    assert_patch(view, chat_path(group))
    # The tape moved to the group…
    assert render(pane(view)) =~ "in Rail #{alice.namespace}"
    assert has_element?(view, "#estate-#{group.id} button[aria-current=true]")
    refute has_element?(view, "#estate-#{estate().id} button[aria-current=true]")

    # …and the bar followed what the page has in view: the switcher names
    # the group, and the tray now reads the shared estate as "elsewhere" — a page that
    # moves by patch cannot leave the bar on the estate it mounted with.
    bar = find_live_child(view, "topbar")
    assert has_element?(bar, "#viewing-name", "Rail #{alice.namespace}")
    Sanctum.Notify.broadcast(group.id, :execution_failed, %{})
    Sanctum.Notify.broadcast(estate().id, :execution_failed, %{})
    :sys.get_state(bar.pid)
    render_click(bar, "toggle_popover", %{"name" => "athanors"})
    assert render(bar) =~ ~r/bg-blue-500\/80[^>]*>\s*\d+\s*</

    # The session's default athanor did not move: the root still lands there.
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
    assert to == chat_path(nil)
  end

  defp estate, do: Process.get(:chat_estate)

  test "a thread named in the address opens under its estate, whatever the session's default is",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Cold #{alice.namespace}")

    ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, conv} = Conversations.create(ctx)
    {:ok, _} = Conversations.append(ctx, conv.id, %{author: alice.user_id, content: "cold open"})

    # A cold mount — no rail click, the session defaulting to the shared estate.
    {view, html} = mount_chat(conn, group, conv.id)
    assert html =~ "cold open"
    assert :sys.get_state(view.pid).socket.assigns.athanor.id == group.id
    assert has_element?(view, "#conv-#{conv.id} button[aria-current=true]")
  end

  test "the rail lists only the estates you hold a seat in", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    carol = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    {:ok, theirs} = Sanctum.Tenancy.Athanors.create_group(bob.user_id, "Theirs #{bob.namespace}")
    # Carol shares nothing with Alice: her only seat is in Bob's group.
    _carol_conn = log_in_user(build_conn(), carol, athanor_id: theirs.id)

    {view, html} = mount_chat(conn)
    %{estates: estates, people: people} = :sys.get_state(view.pid).socket.assigns

    refute theirs.id in Enum.map(estates, & &1.athanor.id)
    refute html =~ "Theirs #{bob.namespace}"
    refute carol.user_id in Enum.map(people, & &1.user_id)
  end

  test "a thread the estate does not hold is refused by name, and the estate's own opens",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)

    # A patch pushed from the first handle_params is applied inside the
    # join, so it is the outcome that is checked: the flash, and the estate's own.
    {view, html} = mount_chat(conn, nil, "conv_not_here")
    assert html =~ "That conversation isn"
    assert render(pane(view)) =~ "in Chat"
    assert :sys.get_state(view.pid).socket.assigns.athanor.id == estate().id
  end

  test "a DM opens from the rail, in place", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Pals #{alice.namespace}")
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    _bob_conn = log_in_user(build_conn(), bob, athanor_id: group.id)

    {view, html} = mount_chat(alice_conn, group)
    # Bob, whom Alice shares an estate with, is a person she can message.
    assert html =~ "People"
    assert has_element?(view, "button[phx-click=open_dm][phx-value-user-id='#{bob.user_id}']")

    view
    |> element("button[phx-click=open_dm][phx-value-user-id='#{bob.user_id}']")
    |> render_click()

    [pair] =
      Enum.filter(Sanctum.Tenancy.Athanors.list_for_user(alice.user_id), &(&1.roster == "frozen"))

    assert_patch(view, chat_path(pair))
    assert render(pane(view)) =~ "DM"
    # The bar names the DM by the other person, never the pair's own "A & B"…
    bar = find_live_child(view, "topbar")
    assert has_element?(bar, "#viewing-name", bob.email)
    refute has_element?(bar, "#viewing-name", alice.email)
    # …and the session's default athanor did not move.
    assert {:error, {:live_redirect, %{to: to}}} = live(alice_conn, "/")
    assert to == chat_path(group)
  end

  test "the chat opens on the estate its address names, and a sent message becomes everyone's thread",
       %{
         conn: conn
       } do
    alice = test_user()
    bob = test_user()
    alice_conn = log_in_user(conn, alice, athanor_id: estate().id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: estate().id)

    {alice_view, html} = mount_chat(alice_conn)
    assert html =~ "AQUA"
    refute html =~ "A.Q.U.A."
    # The chat says which furnace it is, and whether that furnace can think:
    # a test athanor has an orchestrator but no key behind its model.
    assert html =~ "in Chat"
    assert html =~ "has no model yet"
    assert html =~ "Connect a model"

    # With multiple human members, the estate requires an explicit agent mention.
    assert html =~ "Talk to the group"

    Cyfr.Test.ScriptedExecution.script([model_reply("Hi Alice, hi Bob")])

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua hello from alice"})
    |> render_submit()

    start_ctx = member_ctx(alice, estate())
    conv = settled_thread!(start_ctx)

    # The row exists in the athanor; Bob opens the same conversation and
    # reads the reply the runner — not the sender's socket — wrote.
    {bob_view, bob_html} = mount_chat(bob_conn, nil, conv.id)
    assert bob_html =~ "hello from alice"
    assert render(pane(bob_view)) =~ "Hi Alice, hi Bob"
    assert render(pane(alice_view)) =~ "Hi Alice, hi Bob"
    refute render(pane(bob_view)) =~ "is asking"

    agent = Arca.Schemas.Message.agent_author()

    assert [%{author: a}, %{kind: "text", author: ^agent}] =
             Conversations.messages(start_ctx, conv.id) |> Enum.filter(&(&1.kind == "text"))

    assert a == alice.user_id
  end

  test "an approval card decided by one member resolves for the other", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    alice_conn = log_in_user(conn, alice, athanor_id: estate().id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: estate().id)

    {alice_view, _} = mount_chat(alice_conn)

    Cyfr.Test.ScriptedExecution.script([
      model_call("c1", "notes", %{"action" => "keep", "name" => "plan", "content" => "ship it"})
    ])

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua keep the plan"})
    |> render_submit()

    start_ctx = member_ctx(alice, estate())

    wait_until(
      fn ->
        match?(
          [_],
          Conversations.pending_approvals(start_ctx, hd(Conversations.list(start_ctx)).id)
        )
      end,
      60_000
    )

    [conv] = Conversations.list(start_ctx)
    {bob_view, _} = mount_chat(bob_conn, nil, conv.id)

    assert render(pane(alice_view)) =~ "notes.keep"
    assert render(pane(bob_view)) =~ "notes.keep"
    [apr] = Conversations.pending_approvals(start_ctx, conv.id)

    # Bob approves from his tab; the turn continues and answers.
    Cyfr.Test.ScriptedExecution.script([model_reply("Kept.")])

    pane(bob_view)
    |> element("#" <> pane(bob_view).id <> "-card-" <> apr.id <> " button[phx-value-scope=once]")
    |> render_click()

    settled_thread!(start_ctx)
    assert render(pane(bob_view)) =~ "Kept."
    assert render(pane(alice_view)) =~ "Kept."
    {:ok, done} = Conversations.get_message(start_ctx, apr.id)
    assert done.status == "approved"
    assert done.resolved_by == bob.user_id

    assert {:ok, %{status: "approved", decided_by: decided_by}} =
             Aqua.Tape.approval_by_message(start_ctx, apr.id)

    assert decided_by == bob.user_id
  end

  test "a thread opens only in its own estate, and only for a member", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    alice_conn = log_in_user(conn, alice, athanor_id: estate().id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: estate().id)

    {:ok, group} =
      Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Private #{alice.namespace}")

    ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, conv} = Conversations.create(ctx)

    {:ok, _} =
      Conversations.append(ctx, conv.id, %{author: alice.user_id, content: "secret plan"})

    # The focused estate, asked for the group's conversation id, opens
    # nothing of it: the id is not one of its threads, so the page says so
    # and opens one of its own. (The rail may name the group's topic — Alice
    # is its member — but the tape stays the focused estate's.)
    {view, html} = mount_chat(alice_conn, nil, conv.id)
    assert html =~ "That conversation isn"
    refute render(pane(view)) =~ "secret plan"
    %{athanor: athanor, conversation: open} = :sys.get_state(view.pid).socket.assigns
    assert athanor.id == estate().id
    refute open && open.id == conv.id

    # A person outside the group cannot address it at all: the chat leaves
    # for the default estate.
    assert {:error, {:live_redirect, %{to: "/chat"}}} = live(bob_conn, chat_path(group, conv.id))
  end

  test "in a group, people talk to each other without AQUA answering; a removed member is shown out",
       %{conn: conn} do
    alice = test_user()
    bob = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Two #{alice.namespace}")
    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(group)
    ready_estate!(group.id, alice.user_id)
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: group.id)

    {alice_view, _} = mount_chat(alice_conn, group)

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "lunch at noon?"})
    |> render_submit()

    ctx = member_ctx(alice, group)
    [conv] = Conversations.list(ctx)
    assert {:ok, []} = Aqua.Tape.open_turns(ctx, conv.id)
    {bob_view, bob_html} = mount_chat(bob_conn, group, conv.id)
    assert bob_html =~ "lunch at noon?"
    # Two people are here, so the composer says a mention is needed rather
    # than offering to ask the agent directly. Derived from the roster, not
    # a per-group setting.
    assert bob_html =~ "Talk to the group"

    pane(bob_view)
    |> form("form[phx-submit=submit]", %{"message" => "sure"})
    |> render_submit()

    Process.sleep(50)
    assert render(pane(alice_view)) =~ "sure"
    assert {:ok, []} = Aqua.Tape.open_turns(ctx, conv.id)

    # Bob is removed: his tab is sent away, and a fresh open is refused.
    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)
    assert_redirect(bob_view, "/")

    {:ok, _view, redirected_html} =
      case live(bob_conn, chat_path(group, conv.id)) do
        {:error, {:live_redirect, %{to: to}}} -> {:ok, nil, to}
        {:error, {:redirect, %{to: to}}} -> {:ok, nil, to}
        {:ok, view, html} -> {:ok, view, html}
      end

    refute redirected_html =~ "lunch at noon?"

    Cyfr.Test.ScriptedExecution.script([model_reply("Booked.")])

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua book it"})
    |> render_submit()

    settled_thread!(ctx)
    # the whole exchange reaches the agent, each line attributed
    [request] = model_requests()
    text = request_text(request)
    assert text =~ ~r/: lunch at noon\?/
    assert text =~ ~r/: sure/
    assert text =~ ~r/: @aqua book it/
  end

  test "an attachment is stored as a blob any member can fetch, and never from outside", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    carol = test_user()

    {:ok, group} =
      Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Files #{alice.namespace}")

    {:ok, _} = Sanctum.Tenancy.Athanors.mark_provisioned(group)
    ready_estate!(group.id, alice.user_id)
    Cyfr.Test.ScriptedExecution.script([model_reply("Read them.")])
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: group.id)
    carol_conn = log_in_user(build_conn(), carol, athanor_id: estate().id)

    {alice_view, _} = mount_chat(alice_conn, group)

    for {name, content, type} <- [
          {"note.txt", "hi there", "text/plain"},
          {"plan.md", "second", "text/markdown"}
        ] do
      pane(alice_view)
      |> file_input("form[phx-submit=submit]", :attachments, [
        %{name: name, content: content, type: type}
      ])
      |> render_upload(name)
    end

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua read these"})
    |> render_submit()

    ctx = member_ctx(alice, group)
    conv = settled_thread!(ctx)

    # The files rode the model request as typed blocks on the task.
    [request] = model_requests()

    attached =
      request["messages"]
      |> Enum.flat_map(& &1["content"])
      |> Enum.filter(&(&1["type"] == "document"))
      |> Enum.sort_by(& &1["filename"])

    assert [%{"filename" => "note.txt", "data" => data}, %{"filename" => "plan.md"}] = attached
    assert Base.decode64!(data) == "hi there"

    [msg | _] = Conversations.messages(ctx, conv.id)
    refs = msg |> Aqua.Attachments.refs_of() |> Enum.sort_by(& &1["filename"])
    assert Enum.map(refs, & &1["filename"]) == ["note.txt", "plan.md"]
    assert Enum.map(refs, & &1["size"]) == [8, 6]
    # the bytes are the record: one blob per ref, under the message — the
    # location rebuilt from row identity, never persisted in the ref.
    for ref <- refs do
      refute Map.has_key?(ref, "path")

      assert {:ok, ["conversations", conv_id, msg_id, _name] = blob} =
               Aqua.Attachments.blob_path(conv.id, msg.id, ref)

      assert conv_id == conv.id and msg_id == msg.id
      assert Arca.exists?(ctx, blob)
    end

    note = Enum.find(refs, &(&1["filename"] == "note.txt"))
    plan = Enum.find(refs, &(&1["filename"] == "plan.md"))

    # A member reads the bytes back on any device — addressed by the
    # STORED name, so same-named uploads stay distinct; the download still
    # carries the display filename. The type is served safe.
    path = athanor_path("/attachments/#{msg.id}/#{note["stored_name"]}", group)
    resp = get(bob_conn, path)
    assert resp.status == 200
    assert resp.resp_body == "hi there"
    assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="note.txt")]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    # An undeclared type is served as opaque bytes, never as what the uploader said.
    md = get(bob_conn, athanor_path("/attachments/#{msg.id}/#{plan["stored_name"]}", group))
    assert md.status == 200
    assert get_resp_header(md, "content-type") == ["application/octet-stream"]

    # A person outside the group gets nothing; so does an anonymous request.
    assert get(carol_conn, path).status == 404
    assert redirected_to(get(build_conn(), path)) == "/login"
    assert get(bob_conn, athanor_path("/attachments/#{msg.id}/nope.txt", group)).status == 404
  end

  test "an athanor still being set up says so, and any member can retry from the chat", %{
    conn: conn
  } do
    alice = test_user()
    # a bare group row: created, never provisioned — and no bundle to fill
    # it from, so the fill fails and says so
    Application.put_env(
      :cyfr,
      :seed_path,
      Path.join(System.tmp_dir!(), "no_seed_#{alice.namespace}")
    )

    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Bare #{alice.namespace}")
    conn = log_in_user(conn, alice, athanor_id: group.id)

    {view, html} = mount_chat(conn, group)
    assert html =~ "still being set up"

    view |> element("button[phx-click=provision]") |> render_click()

    rendered = render(view)
    assert rendered =~ "Still not set up"
    assert rendered =~ "last attempt failed at"
    {:ok, row} = Sanctum.Tenancy.Athanors.get(group.id)
    assert Sanctum.Tenancy.Athanors.settings(row)["provisioning_error"]["step"]

    # The pane holds its composer while the estate is being prepared, and
    # says why instead of blaming a missing model.
    pane_html = render(pane(view))
    assert pane_html =~ "still being prepared"
    assert pane_html =~ "Still being prepared"
    refute pane_html =~ "has no model yet"

    # The fill completing reaches both the page and its pane without a
    # reload: provisioning broadcasts on the estate's own topic.
    {:ok, filled} = Sanctum.Tenancy.Athanors.mark_provisioned(row)
    Sanctum.Notify.broadcast(group.id, :athanor_changed, %{name: filled.name})

    refute render(view) =~ "still being set up"
    refute render(pane(view)) =~ "Still being prepared"
  end

  test "a message sent while the estate is prepared is held, offered back after a reload, and accepted once",
       %{conn: conn} do
    Application.put_env(:cyfr, :provisioning_inline, false)
    on_exit(fn -> Application.put_env(:cyfr, :provisioning_inline, true) end)

    alice = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Held #{alice.namespace}")
    conn = log_in_user(conn, alice, athanor_id: group.id)
    ctx = member_ctx(alice, group)

    # The fill's claim is held: the estate stays unfilled while the pane sends.
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, group.id, :filling)
        send(parent, :claimed)
        receive do: (:release -> :ok)
      end)

    assert_receive :claimed
    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)

    {view, _html} = mount_chat(conn, group)

    pane(view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua hold this"})
    |> render_submit()

    # Held, not refused: the pane says so, the browser is given the whole
    # send to keep, and nothing was written.
    assert_push_event(pane(view), "aqua:held_send", %{
      envelope:
        %{"client_id" => client_id, "message_id" => message_id, "conversation_id" => conv_id} =
          envelope
    })

    assert render(pane(view)) =~ "Retry"
    assert [] == Conversations.latest_messages(ctx, conv_id, 10)

    # A reload: the hook offers the held send back, and it is held again
    # under the same identity.
    {reloaded, _} = mount_chat(conn, group, conv_id)
    render_hook(pane(reloaded), "restore_draft", envelope)
    assert render(pane(reloaded)) =~ "Retry"

    assert_push_event(pane(reloaded), "aqua:held_send", %{
      envelope: %{"message_id" => ^message_id}
    })

    assert [] == Conversations.latest_messages(ctx, conv_id, 10)

    # The fill completes: every pane holding the send retries on its own,
    # the estate accepts the message once, and the turn runs.
    Cyfr.Test.ScriptedExecution.script([model_reply("Held, then heard")])
    ready_estate!(group.id, alice.user_id)
    {:ok, row} = Sanctum.Tenancy.Athanors.get(group.id)
    {:ok, filled} = Sanctum.Tenancy.Athanors.mark_provisioned(row)
    Sanctum.Notify.broadcast(group.id, :athanor_changed, %{name: filled.name})

    # Both panes offer the send; the turn it opens ends with the reply.
    wait_until(
      fn ->
        Enum.any?(Conversations.latest_messages(ctx, conv_id, 10), &(&1.id == message_id)) and
          match?({:ok, []}, Aqua.Tape.open_turns(ctx, conv_id))
      end,
      60_000
    )

    assert_push_event(pane(reloaded), "aqua:held_send", %{envelope: nil}, 5_000)
    assert_push_event(view, "aqua:held_send", %{envelope: nil}, 5_000)
    refute render(pane(reloaded)) =~ "Retry"

    rows = Conversations.latest_messages(ctx, conv_id, 50)
    assert [%{id: ^message_id}] = Enum.filter(rows, &(&1.author == alice.user_id))
    assert Enum.any?(rows, &(&1.content == "Held, then heard"))
    wait_until(fn -> render(pane(reloaded)) =~ "Held, then heard" end)

    # The harness offering the same send names the same identity: the
    # console and the wire agree on what was accepted.
    assert {:ok, %{replayed: true, message_id: ^message_id}} =
             Emissary.MCP.ConversationTool.handle("conversation", ctx, %{
               "action" => "send",
               "conversation" => conv_id,
               "message" => "@aqua hold this",
               "client_id" => client_id
             })

    assert [%{id: ^message_id}] =
             Enum.filter(
               Conversations.latest_messages(ctx, conv_id, 50),
               &(&1.author == alice.user_id)
             )
  end

  test "a mount on an estate still being filled does not wait for the fill", %{conn: conn} do
    # The real path: the fill is a task nothing awaits, so a mount cannot be
    # held open by it. The suite otherwise fills inline so its assertions can
    # read rows straight after the call.
    Application.put_env(:cyfr, :provisioning_inline, false)
    on_exit(fn -> Application.put_env(:cyfr, :provisioning_inline, true) end)

    alice = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Slow #{alice.namespace}")
    conn = log_in_user(conn, alice, athanor_id: group.id)

    # Hold the estate's claim so the mount's attempt returns at once instead
    # of running a fill this test never awaits — one that would reach the
    # database without the sandbox connection the test owns.
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Sanctum.ProvisioningRegistry, group.id, :filling)
        send(parent, :claimed)
        receive do: (:release -> :ok)
      end)

    assert_receive :claimed
    on_exit(fn -> if Process.alive?(holder), do: send(holder, :release) end)

    started = System.monotonic_time(:millisecond)
    {_view, html} = mount_chat(conn, group)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert html =~ "still being set up"
  end

  test "archiving the athanor sends every open chat away", %{conn: conn} do
    alice = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Gone #{alice.namespace}")
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    {view, _} = mount_chat(alice_conn, group)

    {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
    assert_redirect(view, "/chat")

    # A fresh open is refused too — the root, or the login page when the
    # archived group was the only athanor the session had.
    assert {:error, {_, %{to: to}}} = live(alice_conn, chat_path(group))
    assert to in ["/chat", "/login?error=no_athanor"]
  end

  test "the AQUA page mounts with the athanor's soul and roles, and opens the grant sheet for a model",
       %{conn: conn} do
    conn = log_in_user(conn, test_user(), athanor_id: estate().id)
    {view, _html} = mount_athanor(conn, "/aqua")
    assert render(view) =~ "soul"
    assert has_element?(view, "code", "aqua")

    # "Connect a model" is the lite path to a key: the consent sheet for the
    # orchestrator's catalyst, from this page.
    render_click(view, "open_consent", %{"ref" => "catalyst:local.http:1.1.0"})
    assert has_element?(view, ".consent-sheet")
    send(view.pid, {:consent_sheet_closed, "catalyst:local.http:1.1.0"})
    refute has_element?(view, ".consent-sheet")
  end

  test "on a phone the drawer opens from the pane's Chats button and closes from its own ×",
       %{conn: conn} do
    conn = log_in_user(conn, test_user(), athanor_id: estate().id)
    {view, html} = mount_chat(conn)
    hidden = ~r/id="conversation-list"[^>]*max-md:hidden/

    # At rest: a column at a desk, off-screen on a phone.
    assert html =~ hidden

    # The button is the pane's; the drawer is the page's, and one owner
    # holds it — the pane asks, the page opens.
    pane(view) |> element("button[phx-click=toggle_rail]") |> render_click()
    refute render(view) =~ hidden

    view |> element("#conversation-list button[phx-click=close_rail]") |> render_click()
    assert render(view) =~ hidden
  end

  test "a seat gained while the page is open joins the rail, and a fold the person closed stays closed",
       %{conn: conn} do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)

    # The focused estate holds a thread Alice does not follow, so its
    # "Other topics" has something to fold.
    home_ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: estate().id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, conv} = Conversations.create(home_ctx)
    :ok = Arca.TopicSubscriptionStorage.unfollow(home_ctx, conv.id, alice.user_id)

    {view, _html} = mount_chat(conn)
    fold = "#estate-#{estate().id} button[phx-click=toggle_other]"
    assert has_element?(view, fold <> "[aria-expanded=true]")
    view |> element(fold) |> render_click()
    assert has_element?(view, fold <> "[aria-expanded=false]")

    # Bob makes a group and adds Alice from his side: her rail hears of it
    # without a reload…
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(bob.user_id, "Late #{bob.namespace}")
    refute has_element?(view, "#estate-" <> group.id)
    {:ok, :added} = Sanctum.Tenancy.Members.add(group, [user_id: alice.user_id], bob.user_id)
    assert has_element?(view, "#estate-" <> group.id)
    assert render(view) =~ "Late #{bob.namespace}"

    # …and the rebuild did not undo what she folded.
    assert has_element?(view, fold <> "[aria-expanded=false]")

    # Bob takes the seat back: the row goes, and the page — on the focused
    # estate — stays.
    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: alice.user_id)
    refute has_element?(view, "#estate-" <> group.id)
    assert has_element?(view, "#estate-#{estate().id} button[aria-current=true]", "Chat")
  end

  test "following names only the open estate's own threads: a foreign id writes no row",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Else #{alice.namespace}")

    group_ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, foreign} = Conversations.create(group_ctx)
    :ok = Arca.TopicSubscriptionStorage.unfollow(group_ctx, foreign.id, alice.user_id)

    # The focused estate is open; the id belongs to the group.
    {view, _html} = mount_chat(conn)
    assert render_click(view, "follow_topic", %{"id" => foreign.id}) =~ "That conversation isn"
    refute Arca.TopicSubscriptionStorage.follows?(estate().id, foreign.id, alice.user_id)
    refute Arca.TopicSubscriptionStorage.follows?(group.id, foreign.id, alice.user_id)

    assert render_click(view, "unfollow_topic", %{"id" => foreign.id}) =~
             "That conversation isn"
  end

  test "+ New opens a blank pane, whatever the estate already holds", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    home = estate()
    ctx = %{Sanctum.TestContext.local() | user_id: alice.user_id, athanor_id: home.id}
    {:ok, existing} = Conversations.create(ctx)

    {view, _html} = mount_chat(conn, home, existing.id)
    assert pane(view).id == "pane-#{home.id}"
    assert pane_thread(view).id == existing.id
    pid = pane(view).pid

    render_click(view, "new_conversation")
    assert_patch(view, chat_path(home, PrismWeb.ChatLive.blank()))
    settled_render(view)
    # The pane is the estate's one: turned to the blank slate, not remounted.
    assert pane(view).pid == pid
    assert pane_thread(view) == nil

    # And the address is a place: a refresh of it is the same blank pane,
    # not the newest thread.
    {view2, _} = mount_chat(conn, home, PrismWeb.ChatLive.blank())
    assert pane(view2).id == "pane-#{home.id}"
    assert pane_thread(view2) == nil
  end

  test "a thread switch turns the estate's pane rather than mounting another", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice, athanor_id: estate().id)
    home = estate()
    ctx = %{Sanctum.TestContext.local() | user_id: alice.user_id, athanor_id: home.id}
    {:ok, first} = Conversations.create(ctx)
    {:ok, second} = Conversations.create(ctx)

    {view, _html} = mount_chat(conn, home, first.id)
    pid = pane(view).pid
    assert pane_thread(view).id == first.id

    render_click(view, "open_conversation", %{
      "route" => Sanctum.Tenancy.Athanors.route_slug(home),
      "id" => second.id
    })

    assert_patch(view, chat_path(home, second.id))
    settled_render(view)

    assert pane(view).pid == pid
    assert pane_thread(view).id == second.id
  end
end
