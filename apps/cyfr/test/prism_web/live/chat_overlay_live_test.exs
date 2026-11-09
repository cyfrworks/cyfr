# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ChatOverlayLiveTest do
  @moduledoc """
  The chat as CYFR's own overlay on the desktop (`PrismWeb.ChatOverlayLive`):
  its control on the shelf with the count of threads holding unread
  messages, the person's pairs and shared threads opened in place under
  their seat, the sharing acts in CYFR's own code, the read mark moved while
  a thread is shown, the thread in view told to AQUA's panel, and no frame.
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  setup %{conn: conn} do
    alice = test_user()
    {:ok, conn: log_in_user(conn, alice), alice: alice}
  end

  defp mount_chat(conn, feed \\ PrismWeb.RoomFeed.topic("desk-#{System.unique_integer([:positive])}")) do
    {:ok, view, _html} =
      live_isolated(conn, PrismWeb.ChatOverlayLive, session: %{"room_feed" => feed})

    {view, feed}
  end

  defp open!(view) do
    view |> element("#chat-button") |> render_click()
    assert has_element?(view, "#chat-sheet")
  end

  test "the overlay lists your pairs by the other's name and your shared threads by title, and opens one in place under your seat",
       %{conn: conn, alice: alice} do
    bob = test_user()
    carol = test_user()
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)
    {:ok, pair} = Sanctum.SharedThreads.pair(alice.user_id, bob.user_id)
    {:ok, old} = Sanctum.SharedThreads.create(alice.user_id, "Old #{alice.namespace}")
    {:ok, _} = Sanctum.SharedThreads.archive(alice.user_id, old.id)
    {:ok, theirs} = Sanctum.SharedThreads.create(carol.user_id, "Theirs #{carol.namespace}")

    {view, _feed} = mount_chat(conn)
    # Closed, the overlay is its control alone.
    assert has_element?(view, ~s(#chat-button[aria-expanded="false"]), "Chat")
    refute has_element?(view, "#chat-sheet")

    open!(view)
    assert has_element?(view, "#shared-thread-#{plans.id}", "Plans #{alice.namespace}")

    assert has_element?(
             view,
             "#shared-thread-#{pair.id}",
             Sanctum.Tenancy.Users.display_name(bob.user_id)
           )

    refute has_element?(view, "#shared-thread-" <> old.id)
    refute has_element?(view, "#shared-thread-" <> theirs.id)
    refute render(view) =~ "Theirs #{carol.namespace}"

    view |> element("#shared-thread-#{plans.id} button") |> render_click()
    shared = find_live_child(view, "chat-thread-" <> plans.id)
    assert render(shared) =~ "Plans #{alice.namespace}"

    # A thread Alice does not sit in opens nothing, as a missing one.
    html = render_click(view, "open_shared", %{"id" => theirs.id})
    assert html =~ "That thread cannot be opened"
    refute html =~ "Theirs #{carol.namespace}"
    refute find_live_child(view, "chat-thread-" <> theirs.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "New thread with people makes a thread with its title and the people named, and says who could not be added",
       %{conn: conn, alice: alice} do
    carol = test_user()

    %{account: %{identifier: identifier}, dir: dir} =
      Sanctum.Test.DirectoryServer.member!(carol.user_id)

    record_namespace!(carol)
    Sanctum.Test.RegistryStub.handles!(%{carol.namespace => identifier}, dir.url)

    {view, _feed} = mount_chat(conn)
    open!(view)
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
    assert find_live_child(view, "chat-thread-" <> garden.id)
    assert render(view) =~ "Not added: nobody-here"

    {:ok, people} = Sanctum.SharedThreads.people(alice.user_id, garden.id)

    assert Enum.sort(for %{status: "active", user_id: id} <- people, do: id) ==
             Enum.sort([alice.user_id, carol.user_id])

    Cyfr.Test.Sandbox.end_views()
  end

  test "a pair opens in place with someone you share a thread with", %{conn: conn, alice: alice} do
    bob = test_user()
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)

    {view, _feed} = mount_chat(conn)
    open!(view)

    view
    |> element(~s(#chat-people button[phx-value-user-id="#{bob.user_id}"]))
    |> render_click()

    {:ok, threads} = Sanctum.SharedThreads.list(alice.user_id)
    assert [pair] = for %{kind: "pair"} = thread <- threads, do: thread
    assert find_live_child(view, "chat-thread-" <> pair.id)
    assert has_element?(view, "#shared-thread-" <> pair.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "the overlay reads the threads again on each change, and a thread you were taken out of closes",
       %{conn: conn, alice: alice} do
    bob = test_user()
    {view, _feed} = mount_chat(conn)
    open!(view)
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.shared_threads(alice.user_id))
    alice_id = alice.user_id

    {:ok, late} = Sanctum.SharedThreads.create(bob.user_id, "Late #{bob.namespace}")
    late_id = late.id
    refute has_element?(view, "#shared-thread-" <> late.id)
    {:ok, :added} = Sanctum.SharedThreads.add(bob.user_id, late.id, user_id: alice.user_id)

    assert_receive %Cyfr.Bus.SharedThreadChanged{user_id: ^alice_id, thread_id: ^late_id}, 5_000

    wait_until(
      fn -> has_element?(view, "#shared-thread-#{late.id}", "Late #{bob.namespace}") end,
      5_000,
      "the added thread in the list"
    )

    {:ok, _} = Sanctum.SharedThreads.rename(bob.user_id, late.id, "Later #{bob.namespace}")

    wait_until(
      fn -> has_element?(view, "#shared-thread-#{late.id}", "Later #{bob.namespace}") end,
      5_000,
      "the renamed thread in the list"
    )

    view |> element("#shared-thread-#{late.id} button") |> render_click()
    assert find_live_child(view, "chat-thread-" <> late.id)

    :ok = Sanctum.SharedThreads.remove(bob.user_id, late.id, user_id: alice.user_id)

    wait_until(
      fn -> render(view) =~ "You are no longer in that thread." end,
      5_000,
      "the thread Alice left closed"
    )

    refute has_element?(view, "#shared-thread-" <> late.id)
    refute find_live_child(view, "chat-thread-" <> late.id)

    Cyfr.Test.Sandbox.end_views()
  end

  test "another person's message counts on the shelf until the overlay shows its thread, which moves the read mark",
       %{conn: conn, alice: alice} do
    bob = test_user()
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)

    {view, _feed} = mount_chat(conn)
    refute has_element?(view, "#chat-unread")

    {:ok, _said} = Sanctum.SharedThreads.post(bob.user_id, plans.id, "Hello Alice")

    wait_until(
      fn -> has_element?(view, "#chat-unread", "1") end,
      5_000,
      "the shelf's count of threads with unread messages"
    )

    # Alice's own post is never unread to her.
    {:ok, _said} = Sanctum.SharedThreads.post(alice.user_id, plans.id, "Hi Bob")
    assert {:ok, [%{id: id, unread: 1}]} = listed(alice)
    assert id == plans.id

    open!(view)
    assert has_element?(view, ~s(#shared-thread-#{plans.id} [data-unread="1"]))
    view |> element("#shared-thread-#{plans.id} button") |> render_click()

    wait_until(fn -> not has_element?(view, "#chat-unread") end, 5_000, "the count fallen")
    assert {:ok, [%{unread: 0}]} = listed(alice)
    refute has_element?(view, ~s(#shared-thread-#{plans.id} [data-unread]))

    # A message posted while the thread is shown is read as it lands.
    {:ok, _said} = Sanctum.SharedThreads.post(bob.user_id, plans.id, "Still here")

    wait_until(
      fn -> render(find_live_child(view, "chat-thread-" <> plans.id)) =~ "Still here" end,
      5_000,
      "the new message in the open thread"
    )

    wait_until(fn -> match?({:ok, [%{unread: 0}]}, listed(alice)) end, 5_000, "read as it landed")
    refute has_element?(view, "#chat-unread")

    # Closed, the overlay shows nothing, and a new message counts again.
    view |> element("#chat-close") |> render_click()
    {:ok, _said} = Sanctum.SharedThreads.post(bob.user_id, plans.id, "Are you there?")
    wait_until(fn -> has_element?(view, "#chat-unread", "1") end, 5_000, "counted again")

    Cyfr.Test.Sandbox.end_views()
  end

  test "the thread the overlay shows is told to AQUA by its id and title, and nothing once it closes",
       %{conn: conn, alice: alice} do
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {view, feed} = mount_chat(conn)
    :ok = PrismWeb.RoomFeed.subscribe(feed)

    open!(view)
    assert_receive %Cyfr.Bus.RoomInView{room: nil}, 5_000
    view |> element("#shared-thread-#{plans.id} button") |> render_click()
    title = "Plans #{alice.namespace}"

    assert_receive %Cyfr.Bus.RoomInView{room: %{"shared_thread_id" => id, "title" => ^title} = room},
                   5_000

    assert id == plans.id
    assert Map.keys(room) |> Enum.sort() == ["shared_thread_id", "title"]

    view |> element("#chat-close") |> render_click()
    assert_receive %Cyfr.Bus.RoomInView{room: nil}, 5_000

    Cyfr.Test.Sandbox.end_views()
  end

  test "the overlay is CYFR's own: no frame, and every sharing act a plain click in its thread view",
       %{conn: conn, alice: alice} do
    bob = test_user()
    {:ok, plans} = Sanctum.SharedThreads.create(alice.user_id, "Plans #{alice.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(alice.user_id, plans.id, user_id: bob.user_id)
    {:ok, _said} = Sanctum.SharedThreads.post(bob.user_id, plans.id, "A body of words")

    {view, _feed} = mount_chat(conn)
    open!(view)
    view |> element("#shared-thread-#{plans.id} button") |> render_click()
    shared = find_live_child(view, "chat-thread-" <> plans.id)
    html = render(view) <> render(shared)

    refute html =~ "<iframe"
    refute html =~ "phx-hook=\"IframeBridge\""
    assert html =~ "A body of words"

    for click <- ~w(invite_link archive leave),
        do: assert(has_element?(shared, ~s([phx-click="#{click}"])), click)

    Cyfr.Test.Sandbox.end_views()
  end

  defp listed(person), do: Sanctum.SharedThreads.listed(person.user_id)
end
