# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.TipsLiveTest do
  @moduledoc """
  Tips is one of the athanor's pages in both UI modes, and each tip's
  "Show me" opens a page the console serves.
  """
  use PrismWeb.ConnCase, async: false

  alias PrismWeb.{Nav, TipsLive}

  test "both modes' menus list Tips" do
    for mode <- ~w(lite dev) do
      assert %{path: "/tips", label: "Tips"} = Enum.find(Nav.items(mode), &(&1.key == "tips"))
    end
  end

  test "the page shows every tip with a Show me, in words a person reads", %{conn: conn} do
    {view, html} = conn |> log_in_user(test_user()) |> mount_athanor("/tips")

    assert Enum.map(TipsLive.show_me(), &elem(&1, 0)) ==
             ~w(desktop modes people keys failures)

    for {id, _path} <- TipsLive.show_me() do
      assert has_element?(view, "#tip-#{id} h3")
      assert has_element?(view, "#tip-#{id}-show", "Show me")
    end

    assert html |> LazyHTML.from_fragment() |> LazyHTML.query("[id$='-show']") |> Enum.count() ==
             length(TipsLive.show_me())

    PrismWeb.Vocabulary.refute_vocabulary(html)
  end

  # Pressed as a person in lite, who sees no dev menu, and as the
  # administrator, who starts in dev: each lands on the page it names.
  for {who, admin?} <- [{"a person in lite", false}, {"the administrator in dev", true}] do
    test "every Show me opens a page that exists, for #{who}", %{conn: conn} do
      user = test_user()

      if unquote(admin?),
        do: {:ok, _} = Sanctum.TestContext.ensure_platform(user.user_id)

      conn = log_in_user(conn, user)

      for {id, path} <- TipsLive.show_me() do
        {view, _html} = mount_athanor(conn, "/tips")
        to = athanor_path(path)

        assert {:error, {:live_redirect, %{to: ^to}}} =
                 view |> element("#tip-#{id}-show") |> render_click()

        assert Nav.page?(to)
        assert {:ok, _page, _html} = live(conn, to)
      end
    end
  end
end
