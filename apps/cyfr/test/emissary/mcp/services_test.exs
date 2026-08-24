# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Emissary.MCP.ServicesTest do
  use ExUnit.Case, async: true

  alias Emissary.MCP.Services
  alias Emissary.MCP.ToolRegistry

  test "every configured provider maps to a service the roster lists" do
    names = Services.service_names()

    for module <- ToolRegistry.configured_providers() do
      assert Services.service_name(module) in names
    end

    assert names == names |> Enum.uniq() |> Enum.sort()
  end

  test "the records provider is arca's, everywhere it is named" do
    # routed_to and system.status read the same map, so the same module
    # cannot be one service in the log and another in the report.
    assert Services.service_name(Emissary.MCP.Tools.RecordsProvider) == "arca"
    assert Emissary.MCP.Tools.RecordsProvider in Services.providers_for("arca")
  end

  test "an unlisted module is emissary's" do
    assert Services.service_name(UnknownProvider) == "emissary"
  end
end
