# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SharedThreadLiveTest do
  # A shared thread's pane, opened from the chat at `?s=<thread>`: what its
  # people said, the composer, and the header's controls, each through the
  # gate's `shared_thread` tool under the person's own seat.
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Cyfr.Bus.SharedThreadChanged
  alias Sanctum.SharedThreads
  alias Sanctum.Test.RegistryStub

  setup do
    base =
      Path.join(System.tmp_dir!(), "shared_thread_live_#{System.unique_integer([:positive])}")

    # The restore is registered before the change, so a test killed at its
    # timeout leaves the setting as it found it.
    Prima.Test.Env.put_app_env(:arca, :base_path, base)
    on_exit(fn -> File.rm_rf(base) end)

    alice = test_user()
    bob = test_user()
    {:ok, thread} = SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = SharedThreads.add(alice.user_id, thread.id, user_id: bob.user_id)

    {:ok, alice: alice, bob: bob, thread: thread}
  end

  defp open!(conn, user, thread_id) do
    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, PrismWeb.ChatLive.shared_path(thread_id))
    pane = find_live_child(view, "shared-pane-" <> thread_id)
    assert pane, "the chat opened no pane for #{thread_id}"
    {view, pane}
  end

  # What a person is told of their threads, heard by the test as the page
  # and the pane hear it.
  defp listen!(user), do: :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(user.user_id))

  defp identifier, do: "per_" <> Prima.Digest.sha256_hex("stl-#{System.unique_integer()}")

  test "the pane shows what was said, by whom, with its files, and a post reaches another person's open pane",
       %{conn: conn, alice: alice, bob: bob, thread: thread} do
    {:ok, said} =
      SharedThreads.post(bob.user_id, thread.id, "hello from bob", [
        %{filename: "a.txt", media_type: "text/plain", bytes: "abc"}
      ])

    {_alice_view, alice_pane} = open!(conn, alice, thread.id)
    {_bob_view, bob_pane} = open!(build_conn(), bob, thread.id)

    html = render(alice_pane)
    assert html =~ "hello from bob"
    assert html =~ Sanctum.Tenancy.Users.display_name(bob.user_id)

    assert has_element?(
             alice_pane,
             ~s(a[href="/shared/#{thread.id}/attachments/#{said.id}/0-a.txt"]),
             "a.txt"
           )

    listen!(bob)
    bob_id = bob.user_id
    thread_id = thread.id
    alice_pane |> form("#shared-composer", %{"content" => "hi bob"}) |> render_submit()

    assert_receive %SharedThreadChanged{kind: :posted, user_id: ^bob_id, thread_id: ^thread_id},
                   5_000

    wait_until(fn -> render(bob_pane) =~ "hi bob" end, 5_000, "the post in bob's pane")
    {:ok, messages} = SharedThreads.messages(bob.user_id, thread.id)
    assert %{author: author, content: "hi bob"} = List.last(messages)
    assert author == alice.user_id

    Cyfr.Test.Sandbox.end_views()
  end

  test "files attached in the composer are posted with the words, as bytes in the thread",
       %{conn: conn, alice: alice, bob: bob, thread: thread} do
    {_view, pane} = open!(conn, alice, thread.id)

    pane
    |> file_input("#shared-composer", :files, [
      %{name: "notes.txt", content: "file bytes", type: "text/plain"}
    ])
    |> render_upload("notes.txt")

    pane |> form("#shared-composer", %{"content" => "see attached"}) |> render_submit()

    {:ok, [message]} = SharedThreads.messages(bob.user_id, thread.id)
    assert message.content == "see attached"
    assert [%{"filename" => "notes.txt", "stored_name" => stored}] = message.attachments

    assert {:ok, %{bytes: "file bytes"}} =
             SharedThreads.attachment(bob.user_id, thread.id, message.id, stored)

    assert has_element?(pane, "a", "notes.txt")

    Cyfr.Test.Sandbox.end_views()
  end

  test "the header lists the people and invitations, and any of them adds by name, removes, withdraws, renames and makes an invitation link",
       %{conn: conn, alice: alice, bob: bob, thread: thread} do
    carol = test_user()
    %{identifier: carol_identifier} = RegistryStub.enroll!(carol.user_id)
    record_namespace!(carol)
    RegistryStub.handles!(%{carol.namespace => carol_identifier})
    waiting = identifier()
    {:ok, :added} = SharedThreads.add(alice.user_id, thread.id, identifier: waiting)

    {view, pane} = open!(conn, alice, thread.id)
    assert has_element?(pane, "#shared-people", Sanctum.Tenancy.Users.display_name(bob.user_id))
    assert has_element?(pane, "#shared-people", waiting)

    pane |> form("#shared-add", %{"person" => "@#{carol.namespace}"}) |> render_submit()
    assert seated(alice, thread) == Enum.sort([alice.user_id, bob.user_id, carol.user_id])

    pane
    |> element(~s(#shared-people button[phx-click=remove][phx-value-user-id="#{bob.user_id}"]))
    |> render_click()

    assert seated(alice, thread) == Enum.sort([alice.user_id, carol.user_id])

    pane
    |> element(~s(#shared-people button[phx-click=withdraw][phx-value-identifier="#{waiting}"]))
    |> render_click()

    refute has_element?(pane, "#shared-people", waiting)
    {:ok, people} = SharedThreads.people(alice.user_id, thread.id)
    refute Enum.any?(people, &(&1[:identifier] == waiting))

    pane |> element("#shared-rename") |> render_click()
    pane |> form("#shared-rename-form", %{"title" => "Renamed"}) |> render_submit()
    assert has_element?(pane, "#shared-title", "Renamed")
    assert {:ok, %{title: "Renamed"}} = SharedThreads.get(carol.user_id, thread.id)

    wait_until(
      fn -> has_element?(view, "#shared-thread-#{thread.id}", "Renamed") end,
      5_000,
      "the renamed thread in the rail"
    )

    pane |> element("#shared-invite") |> render_click()
    assert render(pane) =~ "/invite#"

    {:ok, %{invitations: invitations}} =
      PrismWeb.Ops.call_tool(alice_ctx(alice), "invitation/list", %{})

    assert Enum.any?(invitations, &(&1[:thread_id] == thread.id))

    Cyfr.Test.Sandbox.end_views()
  end

  test "a pair offers leave alone, and leaving ends it", %{conn: conn, alice: alice, bob: bob} do
    {:ok, pair} = SharedThreads.pair(alice.user_id, bob.user_id)
    {view, pane} = open!(conn, alice, pair.id)

    assert has_element?(pane, "#shared-title", Sanctum.Tenancy.Users.display_name(bob.user_id))
    assert has_element?(pane, "#shared-leave")

    for control <- ~w(#shared-rename #shared-invite #shared-archive #shared-add),
        do: refute(has_element?(pane, control), "a pair shows #{control}")

    refute has_element?(pane, "#shared-people button")

    listen!(alice)
    alice_id = alice.user_id
    pair_id = pair.id
    pane |> element("#shared-leave") |> render_click()

    assert {:error, {:not_found, "Thread", _}} = SharedThreads.get(alice.user_id, pair.id)
    assert {:ok, %{status: "archived"}} = SharedThreads.get(bob.user_id, pair.id)

    assert_receive %SharedThreadChanged{kind: :changed, user_id: ^alice_id, thread_id: ^pair_id},
                   5_000

    assert_patch(view, "/chat", 5_000)
    assert render(view) =~ "You are no longer in that thread."

    Cyfr.Test.Sandbox.end_views()
  end

  test "archiving a thread closes it for everyone in it", %{
    conn: conn,
    alice: alice,
    bob: bob,
    thread: thread
  } do
    {_alice_view, alice_pane} = open!(conn, alice, thread.id)
    {bob_view, _bob_pane} = open!(build_conn(), bob, thread.id)
    listen!(bob)
    bob_id = bob.user_id
    thread_id = thread.id

    alice_pane |> element("#shared-archive") |> render_click()

    assert {:ok, %{status: "archived"}} = SharedThreads.get(bob.user_id, thread.id)

    assert_receive %SharedThreadChanged{kind: :changed, user_id: ^bob_id, thread_id: ^thread_id},
                   5_000

    assert_patch(bob_view, "/chat", 5_000)
    assert render(bob_view) =~ "This thread has been archived."
    refute has_element?(bob_view, "#shared-thread-" <> thread.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "nothing runs in a shared thread: no agent, approval, grant or follow among its controls",
       %{conn: conn, alice: alice, bob: bob, thread: thread} do
    {:ok, _} = SharedThreads.post(bob.user_id, thread.id, "hello")
    {:ok, :added} = SharedThreads.add(alice.user_id, thread.id, identifier: identifier())
    {_view, pane} = open!(conn, alice, thread.id)
    pane |> element("#shared-rename") |> render_click()
    html = render(pane)

    events =
      ~r/phx-(?:click|submit|change)="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    allowed =
      MapSet.new(~w(toggle_rail toggle_rename invite_link archive leave withdraw remove
                    cancel_upload post validate update_input add rename))

    assert MapSet.subset?(events, allowed),
           "unexpected controls: #{inspect(MapSet.difference(events, allowed) |> MapSet.to_list())}"

    refute html =~ ~r/approv|@aqua|follow/i
    refute html =~ ~r/\b(workspace|group|room)s?\b/i

    Cyfr.Test.Sandbox.end_views()
  end

  test "a person taken out of the thread while its pane is open is told so, and reads nothing more",
       %{conn: conn, alice: alice, bob: bob, thread: thread} do
    {_view, pane} = open!(build_conn() |> Map.merge(conn), bob, thread.id)
    listen!(bob)
    bob_id = bob.user_id
    thread_id = thread.id

    :ok = SharedThreads.remove(alice.user_id, thread.id, user_id: bob.user_id)

    assert_receive %SharedThreadChanged{kind: :changed, user_id: ^bob_id, thread_id: ^thread_id},
                   5_000

    {:ok, _} = SharedThreads.post(alice.user_id, thread.id, "after you left")

    wait_until(
      fn -> render(pane) =~ "You are no longer in this thread." end,
      5_000,
      "the pane saying bob is out"
    )

    html = render(pane)
    refute html =~ "after you left"
    refute has_element?(pane, "#shared-composer")
  end

  defp seated(user, thread) do
    {:ok, people} = SharedThreads.people(user.user_id, thread.id)

    people
    |> Enum.flat_map(fn p -> if p.status == "active", do: [p.user_id], else: [] end)
    |> Enum.sort()
  end

  defp alice_ctx(alice) do
    Sanctum.Context.build(
      user_id: alice.user_id,
      athanor_id: Sanctum.Test.People.athanor!(alice.user_id).id,
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      authenticated: true
    )
  end
end
