# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConsentSheetComponentTest do
  @moduledoc """
  The consent sheet drives the plan → preview → commit walk through
  `PrismWeb.MCPHelpers.call_tool/3`, whose dialect is `tool/action` — a
  dot-spelled name silently misses the registry and every call fails with
  "Unknown tool". These tests render the component against the real
  registry so a dialect drift (or a retired verb) fails here instead of
  in the operator's browser.
  """

  use PrismWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Sanctum.Context

  defp oidc_ctx do
    Context.build(
      user_id: "consent_sheet_test_user",
      namespace: "consent_sheet_test_user",
      org_id: "local",
      project_id: "default",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      authenticated: true
    )
  end

  test "the sheet's plan call reaches the profile tool through the registry" do
    html =
      render_component(PrismWeb.ConsentSheetComponent,
        id: "consent-sheet",
        ref: "publisher/does-not-exist@0.0.1",
        context: oidc_ctx()
      )

    # The plan fails on the nonexistent ref — that's expected. What must
    # never appear is a registry miss: that means the component and the
    # helper disagree on the tool-name dialect again.
    refute html =~ "Unknown tool"
  end

  test "every verb the sheet speaks is a registered profile action" do
    {:ok, tool} = Emissary.MCP.ToolRegistry.get_tool("profile")

    enum = get_in(tool, ["inputSchema", "properties", "action", "enum"]) || []

    for action <- ~w(plan preview commit) do
      assert action in enum,
             "consent sheet drives profile.#{action}, which the profile tool no longer registers"
    end
  end
end
