# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.McpServersLiveTest do
  @moduledoc """
  The MCP servers page adds a stdio server through its form, sends its env
  lines as the backend's env, says why a server was not added, and offers
  Restart for a stdio server only.
  """
  use PrismWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, athanor: seated_athanor()}
  end

  defp ctx(athanor),
    do: Sanctum.Context.actor(Sanctum.Context.internal(athanor_id: athanor.id, scope: :athanor))

  test "the stdio form refuses a malformed env line, and a server the catalog refuses",
       %{conn: conn, athanor: athanor} do
    {view, html} = mount_athanor(conn, "/mcp-servers", athanor)
    assert html =~ "Add stdio server"
    refute html =~ "Setup MCP Bridge"

    view |> element("button", "Add stdio server") |> render_click()

    html =
      view
      |> form("form[phx-submit=add_stdio]", %{
        "name" => "github",
        "backend" => "github",
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => "GITHUB_TOKEN vault:gh"
      })
      |> render_submit()

    assert html =~ "Each env line is NAME=value"

    html =
      view
      |> form("form[phx-submit=add_stdio]", %{
        "name" => "github",
        "backend" => "github",
        "command" => "npx -y @modelcontextprotocol/server-github",
        "env" => "GITHUB_TOKEN=vault:gh\n\nNODE_ENV=production"
      })
      |> render_submit()

    assert html =~ "No MCP bridge is configured"
    assert {:error, :not_found} = Arca.McpServerStorage.get(ctx(athanor), "github")
  end

  test "an expanded stdio server offers Restart and an http server does not",
       %{conn: conn, athanor: athanor} do
    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        name: "piped",
        transport: "stdio",
        url: nil,
        enabled: false,
        config_json:
          Jason.encode!(%{
            "backends" => [%{"name" => "fs", "command" => "npx -y fs", "env" => %{}}]
          })
      })

    {:ok, _} =
      Arca.McpServerStorage.insert(ctx(athanor), %{
        name: "webby",
        url: "https://127.0.0.1:9/mcp",
        enabled: false
      })

    {view, html} = mount_athanor(conn, "/mcp-servers", athanor)
    assert html =~ "stdio (MCP bridge)"

    html = view |> element("tr[phx-value-name=piped]") |> render_click()
    assert html =~ ~s(phx-click="restart")

    view |> element("tr[phx-value-name=piped]") |> render_click()
    html = view |> element("tr[phx-value-name=webby]") |> render_click()
    refute html =~ ~s(phx-click="restart")
  end
end
