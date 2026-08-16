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

    alice_view
    |> form("form[phx-submit=submit]", %{"message" => "hello from alice"})
    |> render_submit()

    assert_receive {:fake_start, eid, start_ctx, _input}, 10_000
    assert start_ctx.user_id == alice.user_id
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
    |> form("form[phx-submit=submit]", %{"message" => "make a webhook"})
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

  test "the Agents page mounts with the athanor's orchestrators", %{conn: conn} do
    conn = log_in_user(conn, test_user())
    {view, _html} = mount_athanor(conn, "/agents")
    assert render(view) =~ "orchestrator"
    assert has_element?(view, "code", "aqua")
  end
end
