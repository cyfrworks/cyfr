# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConversationLiveTest do
  # The chat page is a window onto the runner: two members of the same
  # athanor see one thread, and a turn keeps going when the sender's tab is
  # closed. Driven with the fake engine.
  use PrismWeb.ConnCase, async: false

  alias Arca.ConversationStorage, as: Conversations

  setup do
    test_path = Path.join(System.tmp_dir!(), "conv_live_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :aqua_turn, Prism.FakeAquaTurn)
    Prism.FakeAquaTurn.listen()

    on_exit(fn ->
      Application.delete_env(:cyfr, :aqua_turn)
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    :ok
  end

  defp emit(runner, kind, data) do
    send(runner, {:execution_event, %{type: "emit", data: Map.put(data, "kind", kind)}})
  end

  defp complete(runner), do: send(runner, {:execution_event, %{type: "complete", data: %{}}})

  test "the athanor's root is the chat, and a sent message becomes everyone's thread", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    alice_conn = log_in_user(conn, alice)
    bob_conn = log_in_user(build_conn(), bob)

    {alice_view, html} = mount_athanor(alice_conn, "")
    assert html =~ "A.Q.U.A."
    assert html =~ "Ask anything"

    # Home is a group: AQUA answers when @-mentioned (the composer says so).
    assert html =~ "@aqua to ask AQUA"

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "@aqua hello from alice"})
    |> render_submit()

    assert_receive {:fake_start, eid, start_ctx, input}, 10_000
    assert start_ctx.user_id == alice.user_id
    assert input["task"] =~ ~r/: hello from alice$/
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000

    # The row exists in the athanor; Bob opens the same conversation.
    [conv] = Conversations.list(start_ctx)
    {bob_view, bob_html} = mount_athanor(bob_conn, "?c=" <> conv.id)
    assert bob_html =~ "hello from alice"
    assert bob_html =~ "is asking"

    # The stream reaches Bob's tab as it reaches Alice's — the runner, not
    # the sender's socket, owns the turn.
    emit(runner, "text_delta", %{"content" => "Hi Alice, hi Bob"})
    :sys.get_state(runner)
    assert render(bob_view) =~ "Hi Alice, hi Bob"

    complete(runner)
    :sys.get_state(runner)
    Process.sleep(50)

    rendered = render(bob_view)
    assert rendered =~ "Hi Alice, hi Bob"
    refute rendered =~ "is asking"
    assert render(alice_view) =~ "Hi Alice, hi Bob"

    assert [%{author: a}, %{author: "aqua"}] = Conversations.messages(start_ctx, conv.id)
    assert a == alice.user_id
  end

  test "an approval card decided by one member resolves for the other", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    alice_conn = log_in_user(conn, alice)
    bob_conn = log_in_user(build_conn(), bob)

    {alice_view, _} = mount_athanor(alice_conn, "")

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "@aqua make a webhook"})
    |> render_submit()

    assert_receive {:fake_start, eid, start_ctx, _}, 10_000
    assert_receive {:fake_subscribe, ^eid, runner}, 5_000
    [conv] = Conversations.list(start_ctx)
    {bob_view, _} = mount_athanor(bob_conn, "?c=" <> conv.id)

    block = """
    ```aqua-actions
    [{"kind":"ui.request_approval","title":"Create webhook","summary":"Creates hook X","action_description":"webhook.create","risk":"low","proposal":{"tool":"webhook","action":"create","args":{"name":"x"}}}]
    ```
    """

    emit(runner, "text_delta", %{"content" => block})
    complete(runner)
    :sys.get_state(runner)
    Process.sleep(50)

    assert render(alice_view) =~ "Create webhook"
    assert render(bob_view) =~ "Create webhook"
    [apr] = Conversations.pending_approvals(start_ctx, conv.id)

    # Bob approves from his tab.
    bob_view
    |> element("#" <> apr.id <> " button[phx-value-scope=once]")
    |> render_click()

    assert_receive {:fake_run_approved, %{tool: "webhook", action: "create"}, run_ctx}, 5_000
    assert run_ctx.user_id == bob.user_id
    Process.sleep(100)

    assert render(bob_view) =~ "Approved"
    assert render(alice_view) =~ "Approved"
    {:ok, done} = Conversations.get_message(start_ctx, apr.id)
    assert done.status == "approved"
    assert done.resolved_by == bob.user_id
  end

  test "a member of another athanor cannot open the conversation", %{conn: conn} do
    alice = test_user()
    alice_conn = log_in_user(conn, alice)

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

    # Home's chat page, asked for the group's conversation id, shows nothing of it.
    {_view, html} = mount_athanor(alice_conn, "?c=" <> conv.id)
    refute html =~ "secret plan"
  end

  test "in a group, people talk to each other without AQUA answering; a removed member is shown out",
       %{conn: conn} do
    alice = test_user()
    bob = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Two #{alice.namespace}")
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: group.id)

    {alice_view, _} = mount_athanor(alice_conn, "", group)

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "lunch at noon?"})
    |> render_submit()

    refute_receive {:fake_start, _, _, _}, 300

    ctx =
      Sanctum.Context.build(
        user_id: alice.user_id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    [conv] = Conversations.list(ctx)
    {bob_view, bob_html} = mount_athanor(bob_conn, "?c=" <> conv.id, group)
    assert bob_html =~ "lunch at noon?"
    # the answer-mode control is a group's
    assert has_element?(bob_view, "select[name=answer_mode]")

    bob_view
    |> form("form[phx-submit=submit]", %{"message" => "sure"})
    |> render_submit()

    Process.sleep(50)
    assert render(alice_view) =~ "sure"
    refute_receive {:fake_start, _, _, _}, 200

    # Bob is removed: his tab is sent away, and a fresh open is refused.
    :ok = Sanctum.Tenancy.Members.remove_member(group, user_id: bob.user_id)
    assert_redirect(bob_view, "/")

    {:ok, _view, redirected_html} =
      case live(bob_conn, athanor_path("?c=" <> conv.id, group)) do
        {:error, {:live_redirect, %{to: to}}} -> {:ok, nil, to}
        {:error, {:redirect, %{to: to}}} -> {:ok, nil, to}
        {:ok, view, html} -> {:ok, view, html}
      end

    refute redirected_html =~ "lunch at noon?"

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "@aqua book it"})
    |> render_submit()

    assert_receive {:fake_start, _eid, _ctx, input}, 10_000
    # the whole exchange reaches the agent, each line attributed
    assert input["task"] =~ ~r/: lunch at noon\?/
    assert input["task"] =~ ~r/: sure/
    assert input["task"] =~ ~r/: book it$/
  end

  test "an attachment is stored as a blob any member can fetch, and never from outside", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    carol = test_user()

    {:ok, group} =
      Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Files #{alice.namespace}")

    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    bob_conn = log_in_user(build_conn(), bob, athanor_id: group.id)
    carol_conn = log_in_user(build_conn(), carol)

    {alice_view, _} = mount_athanor(alice_conn, "", group)

    for {name, content, type} <- [
          {"note.txt", "hi there", "text/plain"},
          {"plan.md", "second", "text/markdown"}
        ] do
      alice_view
      |> file_input("form[phx-submit=submit]", :attachments, [
        %{name: name, content: content, type: type}
      ])
      |> render_upload(name)
    end

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "@aqua read these"})
    |> render_submit()

    assert_receive {:fake_start, _eid, ctx, input}, 10_000
    attached = Enum.sort_by(input["attachments"], & &1["filename"])
    assert [%{"filename" => "note.txt", "data" => data}, %{"filename" => "plan.md"}] = attached
    assert Base.decode64!(data) == "hi there"

    [conv] = Conversations.list(ctx)
    [msg | _] = Conversations.messages(ctx, conv.id)
    refs = msg |> Prism.Attachments.refs_of() |> Enum.sort_by(& &1["filename"])
    assert Enum.map(refs, & &1["filename"]) == ["note.txt", "plan.md"]
    assert Enum.map(refs, & &1["size"]) == [8, 6]
    # the bytes are the record: one blob per ref, under the message
    for ref <- refs do
      assert ["conversations", conv_id, msg_id, _name] = ref["path"]
      assert conv_id == conv.id and msg_id == msg.id
      assert Arca.exists?(ctx, ref["path"])
    end

    # A member reads the bytes back on any device; the type is served safe.
    path = athanor_path("/attachments/#{msg.id}/note.txt", group)
    resp = get(bob_conn, path)
    assert resp.status == 200
    assert resp.resp_body == "hi there"
    assert get_resp_header(resp, "content-disposition") == [~s(attachment; filename="note.txt")]
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]

    # An undeclared type is served as opaque bytes, never as what the uploader said.
    md = get(bob_conn, athanor_path("/attachments/#{msg.id}/plan.md", group))
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
    # a bare group row: created, never provisioned (no bundle in this suite)
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Bare #{alice.namespace}")
    conn = log_in_user(conn, alice, athanor_id: group.id)

    {view, html} = mount_athanor(conn, "", group)
    assert html =~ "still being set up"

    view |> element("button[phx-click=provision]") |> render_click()

    rendered = render(view)
    assert rendered =~ "Still not set up"
    assert rendered =~ "last attempt failed at"
    {:ok, row} = Sanctum.Tenancy.Athanors.get(group.id)
    assert Sanctum.Tenancy.Athanors.settings(row)["provisioning_error"]["step"]
  end

  test "archiving the athanor sends every open chat away", %{conn: conn} do
    alice = test_user()
    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(alice.user_id, "Gone #{alice.namespace}")
    alice_conn = log_in_user(conn, alice, athanor_id: group.id)
    {view, _} = mount_athanor(alice_conn, "", group)

    {:ok, _} = Sanctum.Tenancy.Athanors.archive(group)
    assert_redirect(view, "/")

    # A fresh open is refused too — the root, or the login page when the
    # archived group was the only athanor the session had.
    assert {:error, {_, %{to: to}}} = live(alice_conn, athanor_path("", group))
    assert to in ["/", "/login?error=no_athanor"]
  end

  test "the Agents page mounts with the athanor's orchestrators", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/agents")
    assert render(view) =~ "orchestrator"
    assert has_element?(view, "code", "aqua")
  end
end
