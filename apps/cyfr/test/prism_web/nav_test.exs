# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.NavTest do
  use ExUnit.Case, async: true

  alias PrismWeb.Nav

  test "lite is chat and a drawer: the everyday pages, flat, apps first-named" do
    keys = Enum.map(Nav.items("lite"), & &1.key)

    assert keys ==
             ~w(chat agents tinctures members connections schedules webhooks mcp_servers settings legal)

    refute "executions" in keys
    refute "api_keys" in keys
    assert [{nil, items}] = Nav.sections("lite")
    assert length(items) == length(keys)
    assert Enum.find(items, &(&1.key == "tinctures")).label == "Apps"
  end

  test "dev is every page, sectioned, webhooks and enforcements included" do
    keys = Enum.map(Nav.items("dev"), & &1.key)

    for key <-
          ~w(chat executions enforcements components builds registry api_keys webhooks reports) do
      assert key in keys, "dev lacks #{key}"
    end

    titles = Nav.sections("dev") |> Enum.map(&elem(&1, 0))
    assert titles == [nil, "Observability", "Components", "Configuration", "Other"]
    assert Enum.find(Nav.items("dev"), &(&1.key == "tinctures")).label == "Tinctures"
  end

  test "an unknown mode is dev, and ids keep the sidebar's spelling" do
    assert Nav.items(nil) == Nav.items("dev")
    assert Nav.dom_id("nav", "api_keys") == "nav-api-keys"
    assert Nav.dom_id("drawer-nav", "mcp_servers") == "drawer-nav-mcp-servers"
  end
end
