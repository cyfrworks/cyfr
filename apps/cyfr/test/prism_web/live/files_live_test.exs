# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FilesLiveTest.StalledStore do
  @moduledoc false
  # The Local adapter, with every read of a custody copy a publication
  # starts from answering an error while armed: an acceptance commits and
  # its publication cannot start.
  use Arca.Storage.TestDouble

  @armed {__MODULE__, :armed}

  def arm, do: :persistent_term.put(@armed, true)
  def reset, do: :persistent_term.erase(@armed)

  def last_modified(actor, path), do: Arca.Adapters.Local.last_modified(actor, path)

  def get(actor, ["payloads", "receipts" | _] = path) do
    if :persistent_term.get(@armed, false), do: {:error, :eio}, else: super(actor, path)
  end

  def get(actor, path), do: super(actor, path)
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
    refute html =~ "objects/"
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

  # A whole 1x1 PNG: its header, one pixel's compressed data and its end.
  @png Base.decode16!(
         "89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C489" <>
           "0000000D49444154789C636068F8FF1F000482027FE7D85A6C0000000049454E44AE426082"
       )

  test "a picture opens in the panel; other bytes and markup, whatever their name, are not drawn",
       %{
         conn: conn,
         ctx: ctx
       } do
    actor = Sanctum.Context.actor(ctx)
    :ok = Arca.put(actor, ["data", "dot.png"], @png)
    :ok = Arca.put(actor, ["data", "fake.png"], <<0, 1, 2, 3, 255>>)

    {view, _html} = mount_athanor(conn, "/files?p=data")

    view |> element("#files-entries button", "dot.png") |> render_click()

    assert view |> element("#files-picture") |> render() =~
             ~s(src="data:image/png;base64,#{Base.encode64(@png)}")

    refute render(view) =~ "Binary content"

    view |> element("#files-entries button", "fake.png") |> render_click()
    refute has_element?(view, "#files-picture")
    assert render(view) =~ "Binary content — download it to open."

    # Markup named as a picture is text, shown as text and never drawn.
    svg = ~s[<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>]
    html = ~s[<html><body><script>alert(2)</script></body></html>]
    :ok = Arca.put(actor, ["data", "vector.png"], svg)
    :ok = Arca.put(actor, ["data", "page.gif"], html)
    {view, _html} = mount_athanor(conn, "/files?p=data")

    for {name, markup} <- [{"vector.png", svg}, {"page.gif", html}] do
      view |> element("#files-entries button", name) |> render_click()
      refute has_element?(view, "#files-picture")
      refute render(view) =~ "data:image"

      assert view |> element("#files-open pre") |> render() =~
               Phoenix.HTML.html_escape(markup) |> Phoenix.HTML.safe_to_string()
    end
  end

  test "a new folder is held until a file lands there, and Rename and Move relocate a file", %{
    conn: conn,
    ctx: ctx,
    route: route
  } do
    actor = Sanctum.Context.actor(ctx)
    :ok = Arca.put(actor, ["data", "q3.csv"], "a,b\n")

    {view, _html} = mount_athanor(conn, "/files?p=data")

    view |> element("#files-new-folder") |> render_click()
    view |> form("#files-folder-form", %{"name" => "../up"}) |> render_submit()
    assert render(view) =~ "cannot name a folder"

    view |> form("#files-folder-form", %{"name" => "reports"}) |> render_submit()
    assert_patch(view, "/a/#{route}/files?p=data%2Freports")
    assert render(view) =~ "Nothing here yet"

    # Storage holds no empty folder; the page lists the one it holds.
    refute Arca.exists?(actor, ["data", "reports"])
    view |> element("#files-crumbs button", "data") |> render_click()
    assert has_element?(view, "#files-entries button[phx-value-path='data/reports']")

    view
    |> element("#files-entries button[phx-value-path='data/q3.csv']", "Rename")
    |> render_click()

    view |> form("#files-move", %{"name" => "q4.csv"}) |> render_submit()
    assert render(view) =~ "Moved data/q3.csv to data/q4.csv"
    refute Arca.exists?(actor, ["data", "q3.csv"])

    view
    |> element("#files-entries button[phx-value-path='data/q4.csv']", "Move")
    |> render_click()

    view |> form("#files-move", %{"folder" => "data/reports"}) |> render_submit()
    assert render(view) =~ "Moved data/q4.csv to data/reports/q4.csv"
    assert {:ok, "a,b\n"} = Arca.get(actor, ["data", "reports", "q4.csv"])
    refute Arca.exists?(actor, ["data", "q4.csv"])

    # A move onto a name that is taken, or under a file, is refused in words.
    :ok = Arca.put(actor, ["data", "taken.csv"], "t")
    :ok = Arca.put(actor, ["data", "reports", "taken.csv"], "r")
    view |> element("#files-crumbs button", "data") |> render_click()

    view
    |> element("#files-entries button[phx-value-path='data/taken.csv']", "Move")
    |> render_click()

    view |> form("#files-move", %{"folder" => "data/reports"}) |> render_submit()
    assert render(view) =~ "already exists"
    assert {:ok, "t"} = Arca.get(actor, ["data", "taken.csv"])

    # Once a file lands in it, the folder is a stored one: renamed and
    # deleted through storage, leaving nothing of its old name behind.
    view
    |> element("#files-entries button[phx-value-path='data/reports']", "Rename")
    |> render_click()

    view |> form("#files-move", %{"name" => "archive"}) |> render_submit()
    assert render(view) =~ "Moved data/reports to data/archive"
    refute has_element?(view, "#files-entries button[phx-value-path='data/reports']")
    assert {:ok, "r"} = Arca.get(actor, ["data", "archive", "taken.csv"])

    view
    |> element("#files-entries button[phx-value-path='data/archive']", "Delete")
    |> render_click()

    assert render(view) =~ "Deleted data/archive"
    refute has_element?(view, "#files-entries button[phx-value-path='data/archive']")
    refute Arca.exists?(actor, ["data", "archive", "taken.csv"])
    refute Arca.exists?(actor, ["data", "archive", "q4.csv"])

    # A held folder offers Remove alone, which lets it go with the held
    # folders under it.
    view |> element("#files-new-folder") |> render_click()
    view |> form("#files-folder-form", %{"name" => "outer"}) |> render_submit()
    view |> element("#files-new-folder") |> render_click()
    view |> form("#files-folder-form", %{"name" => "inner"}) |> render_submit()
    assert_patch(view, "/a/#{route}/files?p=data%2Fouter%2Finner")

    view |> element("#files-crumbs button", "data") |> render_click()
    outer = "#files-entries button[phx-value-path='data/outer']"
    assert has_element?(view, outer, "Remove")

    for action <- ~w(Rename Move Delete) do
      refute has_element?(view, outer, action)
    end

    view |> element(outer, "Remove") |> render_click()
    assert render(view) =~ "Removed the empty folder data/outer"
    refute has_element?(view, outer)
    view |> element("#files-new-folder") |> render_click()
    view |> form("#files-folder-form", %{"name" => "outer"}) |> render_submit()
    refute has_element?(view, "#files-entries button[phx-value-path='data/outer/inner']")

    # New folder refuses a name already there, stored or held.
    :ok = Arca.put(actor, ["data", "stored", "f.txt"], "f")
    view |> element("#files-crumbs button", "data") |> render_click()

    for name <- ~w(stored outer) do
      unless has_element?(view, "#files-folder-form"),
        do: view |> element("#files-new-folder") |> render_click()

      view |> form("#files-folder-form", %{"name" => name}) |> render_submit()
      assert render(view) =~ "&#39;#{name}&#39; already exists here — choose another name"
      assert has_element?(view, "#files-folder-form")
    end

    assert {:ok, "f"} = Arca.get(actor, ["data", "stored", "f.txt"])
  end

  test "at phone width a row's actions take a line of their own under its name", %{
    conn: conn,
    ctx: ctx
  } do
    :ok = Arca.put(Sanctum.Context.actor(ctx), ["data", "a-long-report-name.csv"], "x")
    {view, _html} = mount_athanor(conn, "/files?p=data")

    page = view |> render() |> LazyHTML.from_document()

    # Below the sm breakpoint the row is a wrapping flex line and the
    # actions cell is a whole line; from sm up both are table parts again.
    assert page |> LazyHTML.query("#files-entries tr") |> LazyHTML.attribute("class") ==
             ["flex flex-wrap items-center hover:bg-gray-800/30 sm:table-row"]

    assert page
           |> LazyHTML.query("#files-entries td[data-row-actions]")
           |> LazyHTML.attribute("class") ==
             [
               "w-full px-3 pb-2 text-left sm:table-cell sm:w-auto sm:pt-2 sm:text-right " <>
                 "sm:whitespace-nowrap"
             ]

    actions = page |> LazyHTML.query("#files-entries td[data-row-actions] :is(a, button)")

    assert actions |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) ==
             ~w(Download Rename Move Delete)
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
    assert html =~ "crew/"
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

      # The accepted offer stays listed with where it landed, and opens there.
      shown = Enum.join(landed, "/") <> "/"
      assert has_element?(view, "#accepted-#{offer_id}", "Sam Sender")
      assert has_element?(view, "#accepted-#{offer_id}", shown)
      assert has_element?(view, "#accepted-#{offer_id}", "q3.csv")
      view |> element("#accepted-#{offer_id} button", "Open") |> render_click()
      assert has_element?(view, "#files-entries button[phx-value-path='#{shown}q3.csv']")

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

    test "files picked under data/ are offered to someone picked from the people sharing a " <>
           "thread, and once accepted the offer shows accepted with no withdraw",
         %{conn: conn, ctx: ctx} do
      recipient = sharing_person!(ctx, name: "Rita Recipient")
      _stranger = test_user(name: "Stan Stranger")
      archived = sharing_person!(ctx, name: "Archie Archived")
      {:ok, _} = Sanctum.SharedThreads.archive(ctx.user_id, archived.thread.id)

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
      stall_publication!()

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

    test "a transfer the sweep lands later leaves the Inbox as it lands", %{conn: conn, ctx: ctx} do
      sender = sharing_person!(ctx, name: "Sam Sender")
      put!(sender, "late.csv", "landed on the sweep")

      {:ok, %{offer_id: offer_id}} =
        call(sender.ctx, "offer", %{"paths" => ["data/late.csv"], "to" => ctx.user_id})

      assert {:ok, %{inbox: [%{folder: folder}]}} = call(ctx, "offers")

      {view, _html} = mount_athanor(conn, "/files")
      stall_publication!()

      # The acceptance commits; its publication cannot start.
      assert {:ok, %{receipts: [%{status: "received"}]}} =
               call(ctx, "accept", %{"offer_id" => offer_id})

      settled(view)
      assert has_element?(view, ~s([data-receipt="#{offer_id}"]), "still landing")

      # Storage answers again, and the receipts sweep finishes the transfer.
      StalledStore.reset()
      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(ctx), 7, false)

      assert {:ok, "landed on the sweep"} =
               Arca.get(actor(ctx), String.split(folder, "/") ++ [offer_id, "late.csv"])

      html = settled(view)
      refute has_element?(view, ~s([data-receipt="#{offer_id}"]))
      refute html =~ "still landing"
      assert html =~ "Nothing is waiting for you"
    end

    test "the picker lists someone who shares only a thread with the person, and a copy reaches them",
         %{conn: conn, ctx: ctx} do
      rita = test_user(name: "Thread Rita")
      {:ok, thread} = Sanctum.SharedThreads.create(ctx.user_id, "Plans")
      {:ok, :added} = Sanctum.SharedThreads.add(ctx.user_id, thread.id, user_id: rita.user_id)
      {:ok, gone} = Sanctum.SharedThreads.create(ctx.user_id, "Gone")
      ola = test_user(name: "Archived Ola")
      {:ok, :added} = Sanctum.SharedThreads.add(ctx.user_id, gone.id, user_id: ola.user_id)
      {:ok, _} = Sanctum.SharedThreads.archive(ctx.user_id, gone.id)
      :ok = Arca.put(actor(ctx), ["data", "a.txt"], "alpha")

      {view, _html} = mount_athanor(conn, "/files?p=data")
      view |> element(~s(#files-entries input[phx-value-path="data/a.txt"])) |> render_click()
      html = view |> element("#files-send-copy") |> render_click()
      assert has_element?(view, "#send-copy-form", "Thread Rita")
      refute html =~ "Archived Ola"

      view |> form("#send-copy-form", %{"to" => rita.user_id}) |> render_submit()
      assert {:ok, %{outbox: [%{recipient: recipient, filename: "a.txt"}]}} = call(ctx, "offers")
      assert recipient == rita.user_id
    end

    test "a refused read of the people sharing a thread is told, never shown as no one",
         %{conn: conn, ctx: ctx} do
      # The page's context stays fresh across the click, so the event
      # reads nothing of the store before the people read it makes.
      original = Application.get_env(:sanctum, :caller_memo_ttl_ms)
      Application.put_env(:sanctum, :caller_memo_ttl_ms, 60_000)

      on_exit(fn ->
        if original,
          do: Application.put_env(:sanctum, :caller_memo_ttl_ms, original),
          else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
      end)

      _rita = sharing_person!(ctx, name: "Rita Recipient")
      :ok = Arca.put(actor(ctx), ["data", "a.txt"], "alpha")

      {view, _html} = mount_athanor(conn, "/files?p=data")
      view |> element(~s(#files-entries input[phx-value-path="data/a.txt"])) |> render_click()

      Arca.Repo.query!("ALTER TABLE shared_thread_members RENAME TO shared_thread_members_gone")

      html =
        try do
          view |> element("#files-send-copy") |> render_click()
        after
          Arca.Repo.query!(
            "ALTER TABLE shared_thread_members_gone RENAME TO shared_thread_members"
          )
        end

      refute html =~ "You share no thread with anyone yet."
      refute has_element?(view, "#send-copy-form")
      assert html =~ "Who you share a thread with could not be read."
    end
  end

  # Someone `ctx`'s person seated with them in a shared thread of theirs,
  # working in their own athanor in a session of theirs, with its tree in
  # place.
  defp sharing_person!(ctx, attrs) do
    person = test_user(attrs)
    own = Sanctum.Test.People.athanor!(person.user_id)

    {:ok, thread} = Sanctum.SharedThreads.create(ctx.user_id, "Shared #{person.namespace}")
    {:ok, :added} = Sanctum.SharedThreads.add(ctx.user_id, thread.id, user_id: person.user_id)

    session =
      Sanctum.Context.build(
        user_id: person.user_id,
        athanor_id: own.id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    :ok = Arca.ensure_roots(Sanctum.Context.actor(session))
    Map.merge(person, %{ctx: session, thread: thread})
  end

  defp put!(who, name, content),
    do: :ok = Arca.put(Sanctum.Context.actor(who.ctx), ["data", name], content)

  defp call(ctx, action, args \\ %{}),
    do: Sanctum.Gate.call_external("file", ctx, Map.put(args, "action", action))

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # The retention sweep's actor for the athanor: the server's own, narrowed.
  defp sweeper(ctx), do: %{Prima.Actor.system() | athanor_id: ctx.athanor_id, scope: :athanor}

  # Storage under `StalledStore` for the rest of the test, its custody
  # reads failing until `StalledStore.reset/0`.
  defp stall_publication! do
    previous = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, StalledStore)
    StalledStore.arm()

    on_exit(fn ->
      StalledStore.reset()

      if previous,
        do: Application.put_env(:arca, :storage_adapter, previous),
        else: Application.delete_env(:arca, :storage_adapter)
    end)
  end

  # The page once every message already sent to it has been handled.
  defp settled(view) do
    :sys.get_state(view.pid)
    render(view)
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
