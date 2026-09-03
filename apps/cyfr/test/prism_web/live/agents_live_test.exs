# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AgentsLiveTest do
  # The agents page shows two trees — your crew and the estate's — and
  # every write must land in the tree the agent lives in. These drive the
  # LiveView itself: the AgentConfig-level test cannot catch a handler
  # that reads the focused context.
  use PrismWeb.ConnCase, async: false

  setup do
    test_path = Path.join(System.tmp_dir!(), "agents_live_#{:rand.uniform(1_000_000)}")
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

    {view, html} = mount_athanor(conn, "/agents", group)

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

    # Grow MY crew from the estate's page: the child materializes in You,
    # and Acme's tree stays untouched.
    view
    |> element("button[phx-value-parent='#{mine.id}/tom']")
    |> render_click()

    view
    |> form("form[phx-submit=editor_create_sub_agent]", %{"name" => "scout"})
    |> render_submit()

    {:ok, %{files: mine_files_after}} = Arca.usage(mine_ctx, ["aqua"])
    assert mine_files_after > mine_files_before
    assert {:ok, %{files: 0}} = Arca.usage(group_ctx, ["aqua"])

    {:ok, listed} =
      Aqua.AgentConfig.call_aqua(mine_ctx, %{"action" => "list", "type" => "sub-agent"})

    assert Enum.any?(listed["guides"] || [], &(&1["name"] == "scout" and &1["parent"] == "tom"))
  end
end
