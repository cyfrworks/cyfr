# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatLiveTest do
  # The chat page is a window onto the runner: two tabs of the person see
  # one thread of their athanor, and a turn keeps going when the sender's
  # tab is closed. Driven against the real loop and a scripted model.
  use PrismWeb.ConnCase, async: false

  require Ecto.Query

  import Prima.Test.Wait

  alias Arca.ThreadStorage, as: Threads

  setup do
    test_path = Path.join(System.tmp_dir!(), "thread_live_#{:rand.uniform(1_000_000)}")
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

    # The person most of these tests chat as, and their own athanor.
    person = test_user()

    # Set up, like an athanor people actually chat in: a turn pins the
    # baseline consent, and sending is held while one is being prepared.
    {:ok, athanor} =
      Sanctum.TestContext.mark_provisioned(Sanctum.Test.People.athanor!(person.user_id))

    Process.put(:chat_athanor, athanor)
    Process.put(:chat_person, person)

    # Filled like an athanor people actually chat in, with its soul's
    # consent minted; the model it names is scripted.
    ready_athanor!(athanor.id, person.user_id)
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

  # The one thread the athanor holds, once its turn has ended.
  defp settled_thread!(ctx) do
    wait_until(
      fn ->
        match?([_], Threads.list(Sanctum.Context.actor(ctx))) and
          match?(
            {:ok, []},
            Aqua.Tape.open_turns(ctx, hd(Threads.list(Sanctum.Context.actor(ctx))).id)
          )
      end,
      60_000
    )

    [thread] = Threads.list(Sanctum.Context.actor(ctx))
    thread
  end

  # The chat's address for an athanor (the person's own by default) and a thread.
  defp chat_path(athanor, thread_id \\ nil) do
    athanor = athanor || athanor()
    PrismWeb.ChatLive.chat_path(Sanctum.Tenancy.Athanors.route_slug(athanor), thread_id)
  end

  defp mount_chat(conn, athanor \\ nil, thread_id \\ nil) do
    {:ok, view, _mount_html} = live(conn, chat_path(athanor, thread_id))
    {view, settled_render(view)}
  end

  # The open thread is a nested LiveView of its own: events reach it by
  # name, a different thread is a different child, and what the tape shows
  # is read by rendering the pane — a render of the page does not wait for
  # the pane's process to apply a broadcast.
  defp pane(view), do: Enum.find(live_children(view), &String.starts_with?(&1.id, "pane-"))

  # The thread the athanor's one pane is turned to, from its own state.
  defp pane_thread(view), do: :sys.get_state(pane(view).pid).socket.assigns.thread

  defp athanor, do: Process.get(:chat_athanor)
  defp person, do: Process.get(:chat_person)

  # `user`'s own athanor filled as the setup fills the chat's athanor
  # (`ready_athanor!/2`) but with no key bound to the model its soul names:
  # one of the states whose empty chat offers to connect a model. It is the
  # one the setup's own steps reach by leaving out the key, with nothing
  # removed. The setup's fill points the seed path at the shipped tree for
  # the whole test.
  defp keyless_athanor!(user) do
    {:ok, athanor} =
      Sanctum.TestContext.mark_provisioned(Sanctum.Test.People.athanor!(user.user_id))

    ctx = %{Sanctum.TestContext.local(:prism) | user_id: user.user_id, athanor_id: athanor.id}
    :ok = Sanctum.TestContext.shipped!(athanor.id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
    {:ok, _} = Opus.authority_for(ctx, :default, Prima.AgentRef.soul_ref())
    athanor
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

  test "a grant the pane's turn needs is asked in the page's layer",
       %{conn: conn} do
    alice = person()
    conn = log_in_user(conn, alice)

    here = %{Sanctum.TestContext.local() | user_id: alice.user_id, athanor_id: athanor().id}
    name = "chat-grant-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compendium.Registry.publish_bytes(here, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A component a turn asks a grant for",
        manifest: Jason.encode!(%{})
      })

    {:ok, thread} = Threads.create(Sanctum.Context.actor(here))
    {view, _html} = mount_chat(conn, nil, thread.id)

    send(pane(view).pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: athanor().id,
      thread_id: thread.id,
      kind: :consent_required,
      data: %{ref: "catalyst:local.#{name}:0.1.0", user_id: alice.user_id}
    })

    # The pane asks the page, and the page places the prompt in its layer,
    # each by a message of its own.
    render(pane(view))
    render(view)
    assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
    assert has_element?(view, "#system-layer-dialog .consent-sheet", "in #{athanor().name}")

    Cyfr.Test.Sandbox.end_views()
  end

  test "the rail lists only the athanors you hold a seat in", %{conn: conn} do
    alice = person()
    carol = test_user()
    conn = log_in_user(conn, alice)
    theirs = Sanctum.Test.People.athanor!(test_user().user_id)
    # Carol shares nothing with Alice: her only seat is in her own athanor.
    _carol_conn = log_in_user(build_conn(), carol)

    {view, _html} = mount_chat(conn)
    %{athanors: athanors, people: people} = :sys.get_state(view.pid).socket.assigns

    refute theirs.id in Enum.map(athanors, & &1.athanor.id)
    refute has_element?(view, "#athanor-" <> theirs.id)
    refute carol.user_id in Enum.map(people, & &1.user_id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "a seat the store cannot read says try again shortly, never no athanor or not a member",
       %{conn: conn} do
    # The context the page holds stays fresh for the whole test, so the
    # guard lets each action through to the focus it asks for: what is
    # checked is the page's own answer to an outage, not the guard's.
    ttl = Application.get_env(:sanctum, :caller_memo_ttl_ms)
    Application.put_env(:sanctum, :caller_memo_ttl_ms, 600_000)

    on_exit(fn ->
      if ttl,
        do: Application.put_env(:sanctum, :caller_memo_ttl_ms, ttl),
        else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
    end)

    alice = person()
    conn = log_in_user(conn, alice)
    {view, _html} = mount_chat(conn)

    # The seat read fails; the athanor listing, which selects no membership
    # column, still answers.
    Arca.Repo.query!("ALTER TABLE memberships DROP COLUMN added_by")

    # No athanor named: the default's seat cannot be read.
    html = render_patch(view, PrismWeb.ChatLive.chat_path(nil))
    assert html =~ "That athanor cannot be opened just now. Try again shortly."
    refute html =~ "Your session could not be checked"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a thread the athanor does not hold is refused by name, and the athanor's own opens",
       %{conn: conn} do
    alice = person()
    conn = log_in_user(conn, alice)

    # A patch pushed from the first handle_params is applied inside the
    # join, so it is the outcome that is checked: the flash, and the athanor's own.
    {view, html} = mount_chat(conn, nil, "thread_not_here")
    assert html =~ "That thread isn"
    assert render(pane(view)) =~ "in your AQUA"
    assert :sys.get_state(view.pid).socket.assigns.athanor.id == athanor().id

    Cyfr.Test.Sandbox.end_views()
  end

  test "a pair opens from the rail with someone you share a thread with, found or made, in place",
       %{conn: conn} do
    alice = person()
    bob = test_user()
    conn = log_in_user(conn, alice)
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)

    {view, html} = mount_chat(conn)
    # Bob, whom Alice shares a thread with, is a person she can message.
    assert html =~ "People"
    person = "button[phx-click=open_dm][phx-value-user-id='#{bob.user_id}']"
    assert has_element?(view, person)

    view |> element(person) |> render_click()

    {:ok, threads} = Sanctum.SharedThreads.list(alice.user_id)
    [pair] = for %{kind: "pair"} = thread <- threads, do: thread
    assert_patch(view, PrismWeb.ChatLive.shared_path(pair.id))

    # The rail names the pair by the other person, and its pane is the
    # shared thread's, no athanor's.
    bob_name = Sanctum.Tenancy.Users.display_name(bob.user_id)
    assert has_element?(view, "#shared-thread-#{pair.id} button[aria-current=true]", bob_name)
    assert find_live_child(view, "shared-pane-" <> pair.id)
    refute pane(view)

    # A second click finds the same pair.
    view |> element(person) |> render_click()
    assert_patch(view, PrismWeb.ChatLive.shared_path(pair.id))
    {:ok, threads} = Sanctum.SharedThreads.list(alice.user_id)
    assert [_one] = for(%{kind: "pair"} = thread <- threads, do: thread)

    # The session's default athanor did not move.
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/")
    assert to == chat_path(athanor())

    Cyfr.Test.Sandbox.end_views()
  end

  test "the chat opens on the person's own athanor, and a sent message's reply reaches each of their tabs",
       %{
         conn: conn
       } do
    alice = person()
    alice_conn = log_in_user(conn, alice)
    again_conn = log_in_user(build_conn(), alice)

    {alice_view, html} = mount_chat(alice_conn)
    assert html =~ "AQUA"
    refute html =~ "A.Q.U.A."
    # The chat says which furnace it is, and whether that furnace can think:
    # this athanor's fill bound a key behind its soul's model, so its empty
    # chat asks for a message and offers no model to connect.
    assert html =~ "in your AQUA"
    assert empty_state(html) == "Ask AQUA anything."

    Cyfr.Test.ScriptedWorker.script([model_reply("Hi Alice")])

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua hello from alice"})
    |> render_submit()

    start_ctx = member_ctx(alice, athanor())
    thread = settled_thread!(start_ctx)

    # The row exists in the athanor; Alice's other tab opens the same
    # thread and reads the reply the runner — not the sender's socket — wrote.
    {again_view, again_html} = mount_chat(again_conn, nil, thread.id)
    assert again_html =~ "hello from alice"
    assert render(pane(again_view)) =~ "Hi Alice"
    assert render(pane(alice_view)) =~ "Hi Alice"
    refute render(pane(again_view)) =~ "is asking"

    agent = Arca.Schemas.Message.agent_author()

    assert [%{author: a}, %{kind: "text", author: ^agent}] =
             Threads.messages(Sanctum.Context.actor(start_ctx), thread.id)
             |> Enum.filter(&(&1.kind == "text"))

    assert a == alice.user_id

    Cyfr.Test.Sandbox.end_views()
  end

  test "a thread opens only in its own athanor, and only for a person seated there",
       %{conn: conn} do
    alice = person()
    bob = test_user()
    alice_conn = log_in_user(conn, alice)
    theirs = Sanctum.Test.People.athanor!(bob.user_id)

    ctx =
      Sanctum.Context.build(
        user_id: bob.user_id,
        athanor_id: theirs.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    {:ok, _} =
      Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
        author: bob.user_id,
        content: "secret plan"
      })

    # The focused athanor, asked for Bob's thread id, opens nothing of it:
    # the id is not one of its threads, so the page says so and opens one
    # of its own.
    {view, html} = mount_chat(alice_conn, nil, thread.id)
    assert html =~ "That thread isn"
    refute render(pane(view)) =~ "secret plan"
    %{athanor: athanor, thread: open} = :sys.get_state(view.pid).socket.assigns
    assert athanor.id == athanor().id
    refute open && open.id == thread.id

    # A person with no seat in Bob's athanor cannot address it at all: the
    # chat leaves for the default athanor.
    assert {:error, {:live_redirect, %{to: "/chat"}}} =
             live(alice_conn, chat_path(theirs, thread.id))

    Cyfr.Test.Sandbox.end_views()
  end

  test "an attachment is stored as a blob the person can fetch on any device, and never from outside",
       %{conn: conn} do
    alice = person()
    carol = test_user()
    home = athanor()
    Cyfr.Test.ScriptedWorker.script([model_reply("Read them.")])
    alice_conn = log_in_user(conn, alice)
    again_conn = log_in_user(build_conn(), alice)
    carol_conn = log_in_user(build_conn(), carol)

    {alice_view, _} = mount_chat(alice_conn, home)

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

    ctx = member_ctx(alice, home)
    thread = settled_thread!(ctx)

    # The files rode the model request as typed blocks on the task.
    [request] = model_requests()

    attached =
      request["messages"]
      |> Enum.flat_map(& &1["content"])
      |> Enum.filter(&(&1["type"] == "document"))
      |> Enum.sort_by(& &1["filename"])

    assert [%{"filename" => "note.txt", "data" => data}, %{"filename" => "plan.md"}] = attached
    assert Base.decode64!(data) == "hi there"

    [msg | _] = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
    refs = msg |> Aqua.attachment_refs() |> Enum.sort_by(& &1["filename"])
    assert Enum.map(refs, & &1["filename"]) == ["note.txt", "plan.md"]
    assert Enum.map(refs, & &1["size"]) == [8, 6]
    # the bytes are the record: one blob per ref, under the message — the
    # location rebuilt from row identity, never persisted in the ref.
    for ref <- refs do
      refute Map.has_key?(ref, "path")

      assert {:ok, ["threads", thread_id, msg_id, _name] = blob} =
               Aqua.attachment_blob_path(thread.id, msg.id, ref)

      assert thread_id == thread.id and msg_id == msg.id
      assert Arca.exists?(Sanctum.Context.actor(ctx), blob)
    end

    note = Enum.find(refs, &(&1["filename"] == "note.txt"))
    plan = Enum.find(refs, &(&1["filename"] == "plan.md"))

    # The person reads the bytes back on any device — addressed by the
    # STORED name, so same-named uploads stay distinct; the download still
    # carries the display filename. The type is served safe.
    path = athanor_path("/attachments/#{msg.id}/#{note["stored_name"]}", home)
    resp = get(again_conn, path)
    assert resp.status == 200
    assert resp.resp_body == "hi there"
    assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="note.txt")]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    # An undeclared type is served as opaque bytes, never as what the uploader said.
    md = get(again_conn, athanor_path("/attachments/#{msg.id}/#{plan["stored_name"]}", home))
    assert md.status == 200
    assert get_resp_header(md, "content-type") == ["application/octet-stream"]

    # A person outside the athanor gets nothing; so does an anonymous request.
    assert get(carol_conn, path).status == 404
    assert redirected_to(get(build_conn(), path)) == "/login"
    assert get(again_conn, athanor_path("/attachments/#{msg.id}/nope.txt", home)).status == 404

    Cyfr.Test.Sandbox.end_views()
  end

  test "a draft offered back after a reload deletes no attachment its pane did not store, a sent one of another tab's included",
       %{conn: conn} do
    alice = person()
    home = athanor()
    Cyfr.Test.ScriptedWorker.script([model_reply("Kept.")])
    alice_conn = log_in_user(conn, alice)
    again_conn = log_in_user(build_conn(), alice)

    {alice_view, _} = mount_chat(alice_conn, home)

    pane(alice_view)
    |> file_input("form[phx-submit=submit]", :attachments, [
      %{name: "note.txt", content: "alice's bytes", type: "text/plain"}
    ])
    |> render_upload("note.txt")

    pane(alice_view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua keep this"})
    |> render_submit()

    ctx = member_ctx(alice, home)
    thread = settled_thread!(ctx)
    [msg | _] = Threads.messages(Sanctum.Context.actor(ctx), thread.id)
    [ref] = Aqua.attachment_refs(msg)
    {:ok, blob} = Aqua.attachment_blob_path(thread.id, msg.id, ref)
    assert {:ok, "alice's bytes"} = Arca.get(Sanctum.Context.actor(ctx), blob)

    # The pane stored the file through the gate: one admitted decision of
    # Alice's for `thread/attach`.
    assert [%{admission: "admitted"}] =
             Arca.Repo.all(
               Ecto.Query.from(d in Arca.Schemas.DecisionLog,
                 where:
                   d.tool == "thread" and d.action == "attach" and d.user_id == ^alice.user_id
               )
             )

    # Alice's other browser offers back a "held send" naming the message
    # the first sent and its file, with a text the send refuses: the
    # refusal discards nothing this pane did not store itself.
    {again_view, _} = mount_chat(again_conn, home, thread.id)

    render_hook(pane(again_view), "restore_draft", %{
      "thread_id" => thread.id,
      "client_id" => Prima.UUID7.generate_id("snd"),
      "message_id" => msg.id,
      "text" => String.duplicate("x", 40_000),
      "attachments" => [ref]
    })

    _ = render(pane(again_view))
    assert {:ok, "alice's bytes"} = Arca.get(Sanctum.Context.actor(ctx), blob)

    Cyfr.Test.Sandbox.end_views()
  end

  test "an athanor still being set up says so, and its person can retry from the chat", %{
    conn: conn
  } do
    alice = test_user()
    # the person's own athanor as their admission minted it, never
    # provisioned — and no bundle to fill it from, so the fill fails and
    # says so
    Application.put_env(
      :arca,
      :seed_path,
      Path.join(System.tmp_dir!(), "no_seed_#{alice.namespace}")
    )

    own = Sanctum.Test.People.athanor!(alice.user_id)
    conn = log_in_user(conn, alice, athanor_id: own.id)

    {view, html} = mount_chat(conn, own)
    assert html =~ "still being set up"

    view |> element("button[phx-click=provision]") |> render_click()

    rendered = render(view)
    assert rendered =~ "Still not set up"
    assert rendered =~ "last attempt failed at"
    {:ok, row} = Sanctum.Tenancy.Athanors.get(own.id)
    assert %{step: _} = Sanctum.Tenancy.Athanors.provisioning_failure(row)

    # The pane holds its composer while the athanor is being prepared, and
    # says why instead of blaming a missing model.
    pane_html = render(pane(view))
    assert pane_html =~ "still being prepared"
    assert pane_html =~ "Still being prepared"
    refute pane_html =~ "has no model yet"

    # The fill completing reaches both the page and its pane without a
    # reload: provisioning broadcasts on the athanor's own topic.
    {:ok, filled} = Sanctum.TestContext.mark_provisioned(row)
    Sanctum.Notify.broadcast(own.id, :athanor_changed, %{name: filled.name})

    refute render(view) =~ "still being set up"
    refute render(pane(view)) =~ "Still being prepared"

    Cyfr.Test.Sandbox.end_views()
  end

  test "a message sent while the athanor is prepared is held, offered back after a reload, and accepted once",
       %{conn: conn} do
    Application.put_env(:sanctum, :provisioning_inline, false)
    on_exit(fn -> Application.put_env(:sanctum, :provisioning_inline, true) end)

    alice = test_user()
    own = Sanctum.Test.People.athanor!(alice.user_id)
    conn = log_in_user(conn, alice, athanor_id: own.id)
    ctx = member_ctx(alice, own)

    # The fill's claim is held: the athanor stays unfilled while the pane sends.
    {:ok, _held} =
      Arca.ProvisioningClaims.claim(
        %Prima.Actor{athanor_id: own.id},
        "boot_elsewhere/own_held",
        "first_need",
        60_000,
        :none
      )

    {view, _html} = mount_chat(conn, own)

    pane(view)
    |> form("form[phx-submit=submit]", %{"message" => "@aqua hold this"})
    |> render_submit()

    # Held, not refused: the pane says so, the browser is given the whole
    # send to keep, and nothing was written.
    assert_push_event(pane(view), "aqua:held_send", %{
      envelope:
        %{"client_id" => client_id, "message_id" => message_id, "thread_id" => thread_id} =
          envelope
    })

    assert render(pane(view)) =~ "Retry"
    assert [] == Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10)

    # A reload: the hook offers the held send back, and it is held again
    # under the same identity.
    {reloaded, _} = mount_chat(conn, own, thread_id)
    render_hook(pane(reloaded), "restore_draft", envelope)
    assert render(pane(reloaded)) =~ "Retry"

    assert_push_event(pane(reloaded), "aqua:held_send", %{
      envelope: %{"message_id" => ^message_id}
    })

    assert [] == Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10)

    # The fill completes: every pane holding the send retries on its own,
    # the athanor accepts the message once, and the turn runs.
    Cyfr.Test.ScriptedWorker.script([model_reply("Held, then heard")])
    ready_athanor!(own.id, alice.user_id)
    {:ok, row} = Sanctum.Tenancy.Athanors.get(own.id)
    {:ok, filled} = Sanctum.TestContext.mark_provisioned(row)
    Sanctum.Notify.broadcast(own.id, :athanor_changed, %{name: filled.name})

    # Both panes offer the send; the turn it opens ends with the reply.
    wait_until(
      fn ->
        Enum.any?(
          Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 10),
          &(&1.id == message_id)
        ) and
          match?({:ok, []}, Aqua.Tape.open_turns(ctx, thread_id))
      end,
      60_000
    )

    assert_push_event(pane(reloaded), "aqua:held_send", %{envelope: nil}, 5_000)
    assert_push_event(view, "aqua:held_send", %{envelope: nil}, 5_000)
    refute render(pane(reloaded)) =~ "Retry"

    rows = Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 50)
    assert [%{id: ^message_id}] = Enum.filter(rows, &(&1.author == alice.user_id))
    assert Enum.any?(rows, &(&1.content == "Held, then heard"))
    wait_until(fn -> render(pane(reloaded)) =~ "Held, then heard" end)

    # The harness offering the same send names the same identity: the
    # console and the wire agree on what was accepted.
    assert {:ok, %{replayed: true, message_id: ^message_id}} =
             Aqua.Providers.Thread.handle("thread", ctx, %{
               "action" => "send",
               "thread" => thread_id,
               "message" => "@aqua hold this",
               "client_id" => client_id
             })

    assert [%{id: ^message_id}] =
             Enum.filter(
               Threads.latest_messages(Sanctum.Context.actor(ctx), thread_id, 50),
               &(&1.author == alice.user_id)
             )

    Cyfr.Test.Sandbox.end_views()
  end

  test "a mount on an athanor still being filled does not wait for the fill", %{conn: conn} do
    # The real path: the fill is a task nothing awaits, so a mount cannot be
    # held open by it. The suite otherwise fills inline so its assertions can
    # read rows straight after the call.
    Application.put_env(:sanctum, :provisioning_inline, false)
    on_exit(fn -> Application.put_env(:sanctum, :provisioning_inline, true) end)

    alice = test_user()
    own = Sanctum.Test.People.athanor!(alice.user_id)
    conn = log_in_user(conn, alice, athanor_id: own.id)

    # Hold the athanor's claim so the mount's attempt returns at once instead
    # of running a fill this test never awaits — one that would reach the
    # database without the sandbox connection the test owns.
    {:ok, _held} =
      Arca.ProvisioningClaims.claim(
        %Prima.Actor{athanor_id: own.id},
        "boot_elsewhere/own_held",
        "first_need",
        60_000,
        :none
      )

    started = System.monotonic_time(:millisecond)
    {_view, html} = mount_chat(conn, own)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert html =~ "still being set up"

    Cyfr.Test.Sandbox.end_views()
  end

  test "archiving the athanor sends every open chat away", %{conn: conn} do
    alice = person()
    alice_conn = log_in_user(conn, alice)
    {view, _} = mount_chat(alice_conn)

    # The guard refuses the archived focus before the page's own notify
    # handler runs; the root lands in the chat.
    Sanctum.TestContext.archive!(athanor().id)
    assert_redirect(view, "/")

    # A fresh open is refused too — the root, or the login page when the
    # archived athanor was the only one the session had.
    assert {:error, {_, %{to: to}}} = live(alice_conn, chat_path(athanor()))
    assert to in ["/chat", "/login?error=no_athanor"]

    Cyfr.Test.Sandbox.end_views()
  end

  test "the AQUA page mounts with the athanor's soul and roles, and opens the grant sheet for a model",
       %{conn: conn} do
    conn = log_in_user(conn, person())
    {view, _html} = mount_athanor(conn, "/aqua")
    assert render(view) =~ "soul"
    assert has_element?(view, "code", "aqua")

    # "Connect a model" is the lite path to a key: the grant for the
    # agent's catalyst, from this page, asked in its system layer.
    render_click(view, "open_consent", %{"ref" => "catalyst:local.http:1.1.3"})
    assert has_element?(view, "#system-layer-dialog .consent-sheet")
    view |> element(~s(#system-layer-dialog button[phx-click="dismiss"])) |> render_click()
    refute has_element?(view, ".consent-sheet")

    Cyfr.Test.Sandbox.end_views()
  end

  # A text size under the 12 px a 720×720 glass is held to (WCAG 2.2 AA at
  # that viewport, as the join proof measures it).
  @under_12px ~r/text-\[(?:\d|1[01])(?:\.\d+)?px\]/

  test "at 720×720 the page and its drawer draw no text under 12 px and no target under 24 px",
       %{conn: conn} do
    user = test_user()
    keyless = keyless_athanor!(user)
    conn = log_in_user(conn, user, athanor_id: keyless.id)
    {view, _html} = mount_chat(conn, keyless)

    # The pane at rest, its model with no key yet: the phone's Chats
    # button, the workbench link and the way to a model are each at least
    # 24 px high (`min-h-6`), and nothing it draws is smaller than
    # `text-xs`.
    assert empty_state(render(pane(view))) == "your AQUA has no model yet. Connect a model"
    refute render(pane(view)) =~ @under_12px
    assert has_element?(pane(view), "button.min-h-6.text-xs[phx-click=toggle_rail]", "Chats")
    assert has_element?(pane(view), "header a.min-h-6.text-xs", "AQUA")
    assert has_element?(pane(view), "a.min-h-6", "Connect a model")

    # The drawer the Chats button opens.
    pane(view) |> element("button[phx-click=toggle_rail]") |> render_click()
    refute view |> element("#thread-list") |> render() =~ @under_12px
    assert has_element?(view, "#thread-list button.min-h-6.text-xs[phx-click=new_thread]")

    row = "#athanor-#{keyless.id}"
    assert has_element?(view, "#{row} button.min-h-6.w-6[phx-click=toggle_athanor]")
    assert has_element?(view, "#{row} button.min-h-6[phx-click=open_athanor]")

    Cyfr.Test.Sandbox.end_views()
  end

  test "on a phone the drawer opens from the pane's Chats button and closes from its own ×",
       %{conn: conn} do
    conn = log_in_user(conn, person())
    {view, html} = mount_chat(conn)
    hidden = ~r/id="thread-list"[^>]*max-md:hidden/

    # At rest: a column at a desk, off-screen on a phone.
    assert html =~ hidden

    # The button is the pane's; the drawer is the page's, and one owner
    # holds it — the pane asks, the page opens.
    pane(view) |> element("button[phx-click=toggle_rail]") |> render_click()
    refute render(view) =~ hidden

    view |> element("#thread-list button[phx-click=close_rail]") |> render_click()
    assert render(view) =~ hidden

    Cyfr.Test.Sandbox.end_views()
  end

  test "+ New opens a blank pane, whatever the athanor already holds", %{conn: conn} do
    alice = person()
    conn = log_in_user(conn, alice)
    home = athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: alice.user_id, athanor_id: home.id}
    {:ok, existing} = Threads.create(Sanctum.Context.actor(ctx))

    {view, _html} = mount_chat(conn, home, existing.id)
    assert pane(view).id == "pane-#{home.id}"
    assert pane_thread(view).id == existing.id
    pid = pane(view).pid

    render_click(view, "new_thread")
    assert_patch(view, chat_path(home, PrismWeb.ChatLive.blank()))
    settled_render(view)
    # The pane is the athanor's one: turned to the blank slate, not remounted.
    assert pane(view).pid == pid
    assert pane_thread(view) == nil

    # And the address is a place: a refresh of it is the same blank pane,
    # not the newest thread.
    {view2, _} = mount_chat(conn, home, PrismWeb.ChatLive.blank())
    assert pane(view2).id == "pane-#{home.id}"
    assert pane_thread(view2) == nil

    Cyfr.Test.Sandbox.end_views()
  end

  test "a thread switch turns the athanor's pane rather than mounting another", %{conn: conn} do
    alice = person()
    conn = log_in_user(conn, alice)
    home = athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: alice.user_id, athanor_id: home.id}
    {:ok, first} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, second} = Threads.create(Sanctum.Context.actor(ctx))

    {view, _html} = mount_chat(conn, home, first.id)
    pid = pane(view).pid
    assert pane_thread(view).id == first.id

    render_click(view, "open_thread", %{
      "route" => Sanctum.Tenancy.Athanors.route_slug(home),
      "id" => second.id
    })

    assert_patch(view, chat_path(home, second.id))
    settled_render(view)

    assert pane(view).pid == pid
    assert pane_thread(view).id == second.id

    Cyfr.Test.Sandbox.end_views()
  end

  describe "threads with people" do
    test "the rail lists your athanors' threads, your pairs by the other's name and your shared threads by title, and ?s= opens one under your seat",
         %{conn: conn} do
      alice = person()
      bob = test_user()
      carol = test_user()
      conn = log_in_user(conn, alice)
      {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
      {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)
      {:ok, pair} = Sanctum.SharedThreads.pair(alice.user_id, bob.user_id)
      {:ok, old} = Sanctum.SharedThreads.create(alice.user_id, "Old #{alice.namespace}")
      {:ok, _} = Sanctum.SharedThreads.archive(alice.user_id, old.id)
      {:ok, theirs} = Sanctum.SharedThreads.create(carol.user_id, "Theirs #{carol.namespace}")

      {view, html} = mount_chat(conn)
      assert has_element?(view, "#athanor-" <> athanor().id)
      assert has_element?(view, "#shared-thread-#{plans.id}", "Plans #{alice.namespace}")

      assert has_element?(
               view,
               "#shared-thread-#{pair.id}",
               Sanctum.Tenancy.Users.display_name(bob.user_id)
             )

      refute has_element?(view, "#shared-thread-" <> old.id)
      refute has_element?(view, "#shared-thread-" <> theirs.id)
      refute html =~ "Theirs #{carol.namespace}"
      shared_rows = view |> element("#shared-threads") |> render()
      refute shared_rows =~ ~r/\b(workspace|group|room)s?\b/i

      view |> element("#shared-thread-#{plans.id} button") |> render_click()
      assert_patch(view, PrismWeb.ChatLive.shared_path(plans.id))
      shared = find_live_child(view, "shared-pane-" <> plans.id)
      assert render(shared) =~ "Plans #{alice.namespace}"

      # A thread Alice does not sit in opens nothing, as a missing one.
      html = render_patch(view, PrismWeb.ChatLive.shared_path(theirs.id))
      assert html =~ "That thread cannot be opened"
      refute html =~ "Theirs #{carol.namespace}"
      refute find_live_child(view, "shared-pane-" <> theirs.id)

      Cyfr.Test.Sandbox.end_views()
    end

    test "New thread with people makes a thread with its title and the people named, and says who could not be added",
         %{conn: conn} do
      alice = person()
      carol = test_user()
      %{identifier: identifier} = Sanctum.Test.RegistryStub.enroll!(carol.user_id)
      record_namespace!(carol)
      Sanctum.Test.RegistryStub.handles!(%{carol.namespace => identifier})
      conn = log_in_user(conn, alice)

      {view, _html} = mount_chat(conn)
      view |> element("#new-with-people") |> render_click()

      # A name that is no name makes nothing.
      html =
        view
        |> form("#new-shared-thread", %{"title" => "Nope", "people" => "Not A Name"})
        |> render_submit()

      assert html =~ "is not a name"
      assert {:ok, []} = Sanctum.SharedThreads.list(alice.user_id)

      view
      |> form("#new-shared-thread", %{
        "title" => "Garden",
        "people" => "@#{carol.namespace}, nobody-here"
      })
      |> render_submit()

      {:ok, [garden]} = Sanctum.SharedThreads.list(alice.user_id)
      assert garden.title == "Garden"
      assert_patch(view, PrismWeb.ChatLive.shared_path(garden.id))
      assert render(view) =~ "Not added: nobody-here"

      {:ok, people} = Sanctum.SharedThreads.people(alice.user_id, garden.id)

      assert Enum.sort(for %{status: "active", user_id: id} <- people, do: id) ==
               Enum.sort([alice.user_id, carol.user_id])

      Cyfr.Test.Sandbox.end_views()
    end

    test "the rail reads the shared threads again on each change, and a thread you were taken out of closes",
         %{conn: conn} do
      alice = person()
      bob = test_user()
      conn = log_in_user(conn, alice)
      {view, _html} = mount_chat(conn)
      # The page acts on what Alice is told; the test hears the same.
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(alice.user_id))
      alice_id = alice.user_id

      {:ok, late} = Sanctum.SharedThreads.create(bob.user_id, "Late #{bob.namespace}")
      late_id = late.id
      refute has_element?(view, "#shared-thread-" <> late.id)
      {:ok, :added} = Sanctum.SharedThreads.add(bob.user_id, late.id, user_id: alice.user_id)

      assert_receive %Cyfr.Bus.SharedThreadChanged{user_id: ^alice_id, thread_id: ^late_id},
                     5_000

      wait_until(
        fn -> has_element?(view, "#shared-thread-#{late.id}", "Late #{bob.namespace}") end,
        5_000,
        "the added thread in the rail"
      )

      {:ok, _} = Sanctum.SharedThreads.rename(bob.user_id, late.id, "Later #{bob.namespace}")

      assert_receive %Cyfr.Bus.SharedThreadChanged{user_id: ^alice_id, thread_id: ^late_id},
                     5_000

      wait_until(
        fn -> has_element?(view, "#shared-thread-#{late.id}", "Later #{bob.namespace}") end,
        5_000,
        "the renamed thread in the rail"
      )

      view |> element("#shared-thread-#{late.id} button") |> render_click()
      assert_patch(view, PrismWeb.ChatLive.shared_path(late.id))

      :ok = Sanctum.SharedThreads.remove(bob.user_id, late.id, user_id: alice.user_id)

      assert_receive %Cyfr.Bus.SharedThreadChanged{user_id: ^alice_id, thread_id: ^late_id},
                     5_000

      assert_patch(view, "/chat", 5_000)
      html = render(view)
      assert html =~ "You are no longer in that thread."
      refute has_element?(view, "#shared-thread-" <> late.id)
      refute find_live_child(view, "shared-pane-" <> late.id)

      Cyfr.Test.Sandbox.end_views()
    end

    test "the shared thread in view is told to your own AQUA by its id and title, and an athanor's thread is not",
         %{conn: conn} do
      alice = person()
      conn = log_in_user(conn, alice)
      {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
      {:ok, own} = Threads.create(Sanctum.Context.actor(member_ctx(alice, athanor())))

      {view, _html} = mount_chat(conn, athanor(), own.id)
      :ok = PrismWeb.RoomFeed.subscribe(PrismWeb.RoomFeed.topic(view.id))

      render_patch(view, PrismWeb.ChatLive.shared_path(plans.id))
      title = "Plans #{alice.namespace}"

      assert_receive %Cyfr.Bus.RoomInView{
                       room: %{"shared_thread_id" => id, "title" => ^title} = room
                     },
                     5_000

      assert id == plans.id
      assert Map.keys(room) |> Enum.sort() == ["shared_thread_id", "title"]

      render_patch(view, chat_path(athanor(), own.id))
      assert_receive %Cyfr.Bus.RoomInView{room: nil}, 5_000

      Cyfr.Test.Sandbox.end_views()
    end

    test "a line said aloud from the picker lands in the shared thread chosen, attributed to you",
         %{conn: conn} do
      alice = person()
      bob = test_user()
      conn = log_in_user(conn, alice)
      {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
      {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)
      actor = Sanctum.Context.actor(member_ctx(alice, athanor()))
      {:ok, own} = Threads.create(actor)
      {:ok, line} = Threads.append(actor, own.id, %{author: alice.user_id, content: "Say this"})

      {view, _html} = mount_chat(conn, athanor(), own.id)
      html = render_click(view, "aloud_open", %{"id" => line.id})
      assert html =~ "Plans #{alice.namespace}"

      view
      |> element("button[phx-click=aloud_post][phx-value-thread='#{plans.id}']")
      |> render_click()

      assert render(view) =~ "Said aloud"
      assert {:ok, [said]} = Sanctum.SharedThreads.messages(bob.user_id, plans.id)
      assert %{author: author, content: "Say this"} = said
      assert author == alice.user_id

      Cyfr.Test.Sandbox.end_views()
    end
  end
end
