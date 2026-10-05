# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FilesLiveTest.StalledStore do
  @moduledoc false
  # The Local adapter, with every folder probe under `data/inbox/`
  # answering an error while armed: an acceptance commits and its
  # publication cannot start.
  use Arca.Storage.TestDouble

  @armed {__MODULE__, :armed}

  def arm, do: :persistent_term.put(@armed, true)
  def reset, do: :persistent_term.erase(@armed)

  def last_modified(actor, path), do: Arca.Adapters.Local.last_modified(actor, path)

  def list_typed(actor, ["data", "inbox" | _] = path) do
    if :persistent_term.get(@armed, false), do: {:error, :eio}, else: super(actor, path)
  end

  def list_typed(actor, path), do: super(actor, path)
end

defmodule PrismWeb.FilesLiveTest do
  @moduledoc """
  The Files page: the folders of the tree in their tiers, the server's
  own storage absent, a file uploaded, opened, edited, downloaded and
  deleted in `data/`, and a shaped folder saying what it is. And sending
  a copy: files picked under `data/` offered to someone the person shares
  an athanor with, the Inbox and the sent offers refreshed as each
  transition is heard on the person's own topic, and a transfer that
  failed told to its recipient.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PrismWeb.FilesLiveTest.StalledStore
  alias Sanctum.Tenancy.Members

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    {:ok, conn: conn, ctx: ctx, route: Sanctum.Tenancy.Athanors.route_slug(athanor)}
  end

  test "the root lists the folders in their tiers and nothing of the server's", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/files")

    for folder <- ~w(data aqua components threads notes) do
      assert html =~ "#{folder}/"
    end

    refute html =~ "payloads/"
    refute html =~ "guest/"
    refute html =~ "files-upload"
  end

  test "data/ takes an upload, opens, edits, downloads and deletes a file", %{
    conn: conn,
    ctx: ctx,
    route: route
  } do
    {view, html} = mount_athanor(conn, "/files?p=data")
    assert html =~ "Nothing here yet"
    assert html =~ ~r/>\s*open\s*</

    view
    |> file_input("#files-upload", :files, [
      %{name: "hello.txt", content: "hello there", type: "text/plain"}
    ])
    |> render_upload("hello.txt")

    html = view |> element("#files-upload") |> render_submit()
    assert html =~ "hello.txt"
    assert {:ok, "hello there"} = Arca.get(Sanctum.Context.actor(ctx), ["data", "hello.txt"])

    # Open shows the text; Edit and Save write it back.
    html = view |> element("#files-entries button", "hello.txt") |> render_click()
    assert html =~ "hello there"

    view |> element("#files-open button", "Edit") |> render_click()

    view
    |> form("#files-editor", %{"content" => "hello again"})
    |> render_submit()

    assert {:ok, "hello again"} = Arca.get(Sanctum.Context.actor(ctx), ["data", "hello.txt"])
    assert render(view) =~ "hello again"

    # The download route streams the bytes as a download.
    response = get(conn, "/a/#{route}/files/download/data/hello.txt")
    assert response.status == 200
    assert response.resp_body == "hello again"
    assert get_resp_header(response, "content-type") == ["text/plain"]
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert disposition =~ ~s(attachment; filename="hello.txt")
    settle_session_refresh()

    # Delete takes the file, and its open panel, away.
    view |> element("#files-entries button", "Delete") |> render_click()
    refute has_element?(view, "#files-entries")
    refute has_element?(view, "#files-open")
    refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "hello.txt"])
  end

  test "the download route knows no folder the page does not show", %{conn: conn, route: route} do
    assert get(conn, "/a/#{route}/files/download/payloads/sha256/abc").status == 404
    assert get(conn, "/a/#{route}/files/download/data/missing.txt").status == 404
    assert get(conn, "/a/#{route}/files/download/data").status == 404
    settle_session_refresh()
  end

  # Each authenticated request starts a session-refresh task; a test that
  # ends while one is mid-query leaves the shared sandbox connection busy
  # for the next test.
  defp settle_session_refresh do
    Prima.Test.Wait.wait_until(fn -> Task.Supervisor.children(Prism.TaskSupervisor) == [] end)
  end

  test "a shaped folder says so, and a shipped unit refuses to go in words", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/files?p=components")
    assert html =~ ~r/>\s*shaped\s*</
    assert html =~ "Components page"

    {view, html} = mount_athanor(conn, "/files?p=aqua")
    assert html =~ ~r/>\s*shaped\s*</
    assert html =~ "AQUA page"
    assert html =~ "roles/"
    assert html =~ "aqua.md"

    html =
      view
      |> element("#files-entries button[phx-value-path='aqua/aqua.md']", "Delete")
      |> render_click()

    assert html =~ "ships with the server"
    assert has_element?(view, "#files-entries button", "aqua.md")

    {_view, html} = mount_athanor(conn, "/files?p=notes")
    assert html =~ ~r/>\s*read-only\s*</
    refute html =~ "files-upload"
  end

  # ---------------------------------------------------------------------------
  # Sending a copy
  # ---------------------------------------------------------------------------

  describe "sending a copy" do
    test "an offer reaches the Inbox as it is made, as names, sizes and its sender, never the " <>
           "bytes, and is accepted into the folder shown or declined",
         %{conn: conn, ctx: ctx} do
      {view, html} = mount_athanor(conn, "/files")
      assert html =~ "Nothing is waiting for you"

      sender = sharing_person!(ctx, name: "Sam Sender")
      put!(sender, "q3.csv", "quarterly figures 4471")
      put!(sender, "notes.txt", "notes body 9902")

      {:ok, %{offer_id: offer_id}} =
        call(sender.ctx, "offer", %{
          "paths" => ["data/q3.csv", "data/notes.txt"],
          "to" => ctx.user_id
        })

      html = settled(view)
      assert has_element?(view, "#offer-#{offer_id}", "q3.csv")
      assert has_element?(view, "#offer-#{offer_id}", "notes.txt")
      assert has_element?(view, "#offer-#{offer_id}", "Sam Sender")

      assert has_element?(
               view,
               "#offer-#{offer_id}",
               PrismWeb.DisplayHelpers.format_bytes(byte_size("quarterly figures 4471"))
             )

      # Before acceptance the recipient holds the names and sizes alone.
      for bytes <- ["quarterly figures 4471", "notes body 9902"] do
        refute html =~ bytes
        refute inspect(assigns(view), limit: :infinity, printable_limit: :infinity) =~ bytes
      end

      # The accept form's folder is the one an acceptance without one lands in.
      assert {:ok, %{inbox: [%{folder: folder} | _]}} = call(ctx, "offers")
      assert has_element?(view, ~s(#accept-#{offer_id} input[name="folder"][value="#{folder}"]))

      view |> form("#accept-#{offer_id}") |> render_submit()

      landed = String.split(folder, "/") ++ [offer_id]
      assert {:ok, "quarterly figures 4471"} = Arca.get(actor(ctx), landed ++ ["q3.csv"])
      assert {:ok, "notes body 9902"} = Arca.get(actor(ctx), landed ++ ["notes.txt"])
      settled(view)
      refute has_element?(view, "#offer-#{offer_id}")

      # Another offer, declined from the page.
      {:ok, %{offer_id: second}} =
        call(sender.ctx, "offer", %{"paths" => ["data/notes.txt"], "to" => ctx.user_id})

      settled(view)
      view |> element("#offer-#{second} button", "Decline") |> render_click()
      assert settled(view) =~ "Nothing is waiting for you"
      refute has_element?(view, "#offer-#{second}")

      assert {:ok, %{outbox: outbox}} = call(sender.ctx, "offers")
      assert %{status: "declined"} = Enum.find(outbox, &(&1.offer_id == second))
    end

    test "files picked under data/ are offered to someone picked from the people sharing an " <>
           "athanor, and once accepted the offer shows accepted with no withdraw",
         %{conn: conn, ctx: ctx} do
      recipient = sharing_person!(ctx, name: "Rita Recipient")
      _stranger = test_user(name: "Stan Stranger")
      archived = sharing_person!(ctx, name: "Archie Archived")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(archived.group)

      :ok = Arca.put(actor(ctx), ["data", "a.txt"], "alpha")
      :ok = Arca.put(actor(ctx), ["data", "b.txt"], "beta")

      # Only a file under data/ is picked.
      {view, _html} = mount_athanor(conn, "/files?p=aqua")
      refute has_element?(view, ~s(#files-entries input[type="checkbox"]))

      {view, _html} = mount_athanor(conn, "/files?p=data")
      refute has_element?(view, "#files-send-copy")

      for name <- ~w(a.txt b.txt) do
        view
        |> element(~s(#files-entries input[phx-value-path="data/#{name}"]))
        |> render_click()
      end

      assert has_element?(view, "#files-selection", "2 selected")

      html = view |> element("#files-send-copy") |> render_click()
      assert has_element?(view, "#send-copy-form", "Rita Recipient")
      refute html =~ "Stan Stranger"
      refute html =~ "Archie Archived"

      view |> form("#send-copy-form", %{"to" => recipient.user_id}) |> render_submit()
      refute has_element?(view, "#files-selection")

      assert {:ok, %{outbox: [%{offer_id: offer_id} | _] = outbox}} = call(ctx, "offers")
      assert Enum.sort(Enum.map(outbox, & &1.filename)) == ["a.txt", "b.txt"]
      assert Enum.all?(outbox, &(&1.recipient == recipient.user_id))

      settled(view)
      assert has_element?(view, "#sent-#{offer_id}", "Rita Recipient")
      assert has_element?(view, "#sent-#{offer_id} button", "Withdraw")

      # The recipient accepts, in an athanor of theirs; the sender hears it.
      assert {:ok, %{folder: _}} = call(recipient.ctx, "accept", %{"offer_id" => offer_id})
      settled(view)
      assert has_element?(view, "#sent-#{offer_id}", "accepted")
      refute has_element?(view, "#sent-#{offer_id} button", "Withdraw")
    end

    test "a transfer that could not be delivered is told in the Inbox as it fails",
         %{conn: conn, ctx: ctx} do
      sender = sharing_person!(ctx, name: "Sam Sender")
      put!(sender, "lost.csv", "never landed")

      {:ok, %{offer_id: offer_id}} =
        call(sender.ctx, "offer", %{"paths" => ["data/lost.csv"], "to" => ctx.user_id})

      {view, _html} = mount_athanor(conn, "/files")

      previous = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, StalledStore)
      StalledStore.arm()

      on_exit(fn ->
        StalledStore.reset()

        if previous,
          do: Application.put_env(:arca, :storage_adapter, previous),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      # The acceptance commits; its publication cannot start.
      assert {:ok, %{receipts: [%{status: "received"}]}} =
               call(ctx, "accept", %{"offer_id" => offer_id})

      settled(view)
      assert has_element?(view, ~s([data-receipt="#{offer_id}"]), "lost.csv")
      assert has_element?(view, ~s([data-receipt="#{offer_id}"]), "still landing")

      # Received past `file_receipt_days` with no write ever sent: the sweep
      # fails it, and the page hears so.
      {1, _} =
        Arca.Repo.update_all(
          from(r in Arca.Schemas.FileReceipt, where: r.offer_id == ^offer_id),
          set: [inserted_at: DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)]
        )

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = Arca.Retention.FileReceipts.prune(sweeper(ctx), 7, false)
      end)

      settled(view)
      assert has_element?(view, ~s([data-receipt="#{offer_id}"]), "could not be delivered")
      assert has_element?(view, ~s([data-receipt="#{offer_id}"]), "Sam Sender")
      refute has_element?(view, ~s([data-receipt="#{offer_id}"]), "still landing")
    end

    test "the people a person may send to are those seated with them in an active athanor, " <>
           "and no one else",
         %{ctx: ctx} do
      me = ctx.user_id
      bob = sharing_person!(ctx, name: "Bob")
      carol = test_user(name: "Carol")
      {:ok, _} = Members.ensure(carol.user_id, scope: "athanor", athanor_id: bob.group.id)

      # Bob shares a second group with me: he is listed once.
      {:ok, second} =
        Sanctum.Tenancy.Athanors.create_group(bob.user_id, "Second #{bob.namespace}")

      {:ok, _} = Members.ensure(me, scope: "athanor", athanor_id: second.id)

      # An invitation seats no one.
      {:ok, _} =
        Members.create(%{
          scope: "athanor",
          athanor_id: second.id,
          email: "invited-#{bob.namespace}@example.com",
          status: "invited",
          added_by: me
        })

      # An archived room is no room.
      archie = sharing_person!(ctx, name: "Archie")
      {:ok, _} = Sanctum.Tenancy.Athanors.archive(archie.group)

      # Someone who sits in rooms of their own, never with me.
      stan = test_user(name: "Stan")
      {:ok, _} = Sanctum.Tenancy.Athanors.create_group(stan.user_id, "Alone #{stan.namespace}")

      assert {:ok, people} = Members.people_sharing(me)
      assert Enum.sort(Enum.map(people, & &1.user_id)) == Enum.sort([bob.user_id, carol.user_id])
      assert Enum.all?(people, &(Enum.sort(Map.keys(&1)) == [:display_name, :email, :user_id]))

      assert %{display_name: "Bob", email: bob_email} =
               Enum.find(people, &(&1.user_id == bob.user_id))

      assert bob_email == bob.email

      # Seen from another member, the person is there and the caller is not.
      assert {:ok, seen_by_carol} = Members.people_sharing(carol.user_id)
      assert Enum.sort(Enum.map(seen_by_carol, & &1.user_id)) == Enum.sort([bob.user_id, me])
      assert {:ok, []} = Members.people_sharing(stan.user_id)
    end
  end

  # Someone who shares a group with `ctx`'s person, working in that group
  # in a session of theirs, with the group's tree in place.
  defp sharing_person!(ctx, attrs) do
    person = test_user(attrs)

    {:ok, group} =
      Sanctum.Tenancy.Athanors.create_group(person.user_id, "Shared #{person.namespace}")

    {:ok, _} = Members.ensure(ctx.user_id, scope: "athanor", athanor_id: group.id)

    session =
      Sanctum.Context.build(
        user_id: person.user_id,
        athanor_id: group.id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    :ok = Arca.ensure_roots(Sanctum.Context.actor(session))
    Map.merge(person, %{ctx: session, group: group})
  end

  defp put!(who, name, content),
    do: :ok = Arca.put(Sanctum.Context.actor(who.ctx), ["data", name], content)

  defp call(ctx, action, args \\ %{}),
    do: Grimoire.call_external("file", ctx, Map.put(args, "action", action))

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # The retention sweep's actor for the athanor: the server's own, narrowed.
  defp sweeper(ctx), do: %{Prima.Actor.system() | athanor_id: ctx.athanor_id, scope: :athanor}

  # The page once every message already sent to it has been handled.
  defp settled(view) do
    :sys.get_state(view.pid)
    render(view)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
