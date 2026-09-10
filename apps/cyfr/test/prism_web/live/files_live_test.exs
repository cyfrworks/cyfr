# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FilesLiveTest do
  @moduledoc """
  The Files page: the folders of the tree in their tiers, the server's
  own storage absent, a file uploaded, opened, edited, downloaded and
  deleted in `data/`, and a shaped folder saying what it is.
  """

  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    estate = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: estate.id}
    :ok = Arca.ensure_roots(ctx)
    {:ok, conn: conn, ctx: ctx, route: Sanctum.Tenancy.Athanors.route_slug(estate)}
  end

  test "the root lists the folders in their tiers and nothing of the server's", %{conn: conn} do
    {_view, html} = mount_athanor(conn, "/files")

    for folder <- ~w(data aqua components conversations notes) do
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
    assert {:ok, "hello there"} = Arca.get(ctx, ["guest", "hello.txt"])

    # Open shows the text; Edit and Save write it back.
    html = view |> element("#files-entries button", "hello.txt") |> render_click()
    assert html =~ "hello there"

    view |> element("#files-open button", "Edit") |> render_click()

    view
    |> form("#files-editor", %{"content" => "hello again"})
    |> render_submit()

    assert {:ok, "hello again"} = Arca.get(ctx, ["guest", "hello.txt"])
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
    refute Arca.exists?(ctx, ["guest", "hello.txt"])
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
    Cyfr.Test.Wait.wait_until(fn -> Task.Supervisor.children(Aqua.TaskSupervisor) == [] end)
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
end
