# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLiveTest do
  # The AQUA page shows two closets — yours and the estate's — and
  # every write must land in the tree the agent lives in. These drive the
  # LiveView itself: the AgentConfig-level test cannot catch a handler
  # that reads the focused context.
  use PrismWeb.ConnCase, async: false

  setup do
    test_path = Path.join(System.tmp_dir!(), "aqua_live_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    :ok
  end

  test "a personal agent is edited and grown in its own tree, wherever the page is focused",
       %{conn: conn} do
    user = test_user()
    n = System.unique_integer([:positive])

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me-al#{n}",
        owner_user_id: user.user_id,
        created_by: user.user_id
      })

    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Acme #{n}")
    conn = log_in_user(conn, user, athanor_id: group.id)

    {:ok, u} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: mine.id)

    mine_ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}
    group_ctx = %{mine_ctx | athanor_id: group.id}

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(mine_ctx, %{
        "action" => "create",
        "name" => "tom",
        "title" => "Tom",
        "content" => "# Tom"
      })

    {:ok, %{files: mine_files_before}} = Arca.usage(mine_ctx, ["aqua"])
    assert {:ok, %{files: 0}} = Arca.usage(group_ctx, ["aqua"])

    {view, html} = mount_athanor(conn, "/aqua", group)

    # Both trees render, and the personal one says so.
    assert html =~ "tom"
    assert html =~ "yours"

    # Rename MY tom while focused on Acme: the write follows the agent.
    render_change(view, "editor_update_field", %{
      "name" => "tom",
      "owner" => mine.id,
      "field" => "title",
      "value" => "My Tom"
    })

    {:ok, detail} = Aqua.AgentConfig.call_aqua(mine_ctx, %{"action" => "get", "name" => "tom"})
    assert detail["title"] == "My Tom"

    # Add a role to MY closet from the estate's page: the file materializes
    # in You, and Acme's tree stays untouched.
    view
    |> form("form[phx-submit=editor_create_role]", %{"name" => "scout", "owner" => mine.id})
    |> render_submit()

    {:ok, %{files: mine_files_after}} = Arca.usage(mine_ctx, ["aqua"])
    assert mine_files_after > mine_files_before
    assert {:ok, %{files: 0}} = Arca.usage(group_ctx, ["aqua"])

    {:ok, listed} = Aqua.AgentConfig.call_aqua(mine_ctx, %{"action" => "list"})
    assert Enum.any?(listed["guides"] || [], &(&1["name"] == "scout" and &1["type"] == "role"))
  end

  # The page beside the closet: the pinned page, the notes and the scrolls,
  # every write through the same tool an agent's card goes through.
  describe "the estate's page" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      home = Sanctum.Tenancy.Athanors.home!()
      ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: home.id}
      {:ok, conn: conn, ctx: ctx}
    end

    test "About us is pinned from the page and is what the soul reads", %{conn: conn, ctx: ctx} do
      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "About us"
      assert html =~ "Nothing pinned yet."

      render_click(view, "about_edit")

      view
      |> form("#aqua-about form", %{"content" => "We ship on Fridays."})
      |> render_submit()

      assert render(view) =~ "We ship on Fridays."
      assert {:ok, %{name: "about-us", content: "We ship on Fridays."}} = Aqua.Notes.pinned(ctx)

      # The pinned page is not a note in the drawer.
      refute render(view) =~ "about-us"
    end

    test "the notes drawer lists what was kept here, opens one, and forgets on request",
         %{conn: conn, ctx: ctx} do
      {:ok, _} = Aqua.Notes.keep(ctx, "plan", "Ship Friday.\nThen rest.")

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "plan"
      refute html =~ "Ship Friday."

      assert render_click(view, "note_open", %{"name" => "plan"}) =~ "Ship Friday."

      render_click(view, "note_forget", %{"name" => "plan"})
      refute render(view) =~ "Ship Friday."
      assert {:ok, notes} = Aqua.Notes.list(ctx)
      refute Enum.any?(notes, &(&1.name == "plan"))
    end

    test "the scrolls disclosure lists the estate's scrolls and opens one", %{
      conn: conn,
      ctx: ctx
    } do
      {:ok, _} =
        Aqua.AgentConfig.call_aqua(ctx, %{
          "action" => "skill_create",
          "name" => "pdf-forms",
          "description" => "Fill PDF forms",
          "content" => "# PDF forms\nUse pdftk."
        })

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "pdf-forms"
      assert html =~ "Fill PDF forms"
      refute html =~ "Use pdftk."

      assert render_click(view, "skill_open", %{"name" => "pdf-forms"}) =~ "Use pdftk."
    end
  end
end
