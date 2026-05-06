defmodule PrismWeb.WebhooksLiveTest do
  @moduledoc """
  Minimal smoke test — the heavy lifting (storage, MCP tool, signature
  verification, controller) is covered by dedicated tests. Here we just
  verify the route is wired and gated behind authentication.
  """

  use PrismWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /webhooks (unauthenticated)" do
    test "redirects to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/webhooks")
    end
  end
end
