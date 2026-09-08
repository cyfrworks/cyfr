# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RolePolicyTest do
  # A role's clone definition carries its EFFECTIVE policy — its authored
  # one with the standing decisions made for that role and the kind
  # ceiling applied — exactly as the soul's is composed. A "never"
  # answered for the Builder holds when the soul clones into it.
  use ExUnit.Case, async: true

  alias Aqua.AgentConfig

  @roster [
    %{"name" => "aqua", "type" => "soul", "tool_policy" => %{"aqua_builder.*" => "auto"}},
    %{
      "name" => "aqua_builder",
      "type" => "role",
      "content" => "build",
      "tool_policy" => %{
        "files.write" => "auto",
        "files.delete" => "auto",
        "component.*" => "auto"
      }
    },
    %{
      "name" => "aqua_web",
      "type" => "role",
      "content" => "fetch",
      "tool_policy" => %{"http.get" => "auto"}
    }
  ]

  test "a standing deny for a role holds in its clone definition, and the ceiling applies" do
    grants = %{"aqua_builder" => [%{effect: "deny", tool: "files", action: "write"}]}

    [builder, web] = AgentConfig.role_definitions(@roster, [], "cat", "m", grants)

    assert builder["name"] == "aqua_builder"
    assert builder["tool_policy"]["files.write"] == "deny"
    # A hand-written destructive auto reaches the guest as ask.
    assert builder["tool_policy"]["files.delete"] == "ask"
    # A catalogued glob is expanded to exact keys.
    refute Map.has_key?(builder["tool_policy"], "component.*")
    assert builder["tool_policy"]["component.search"] == "auto"

    assert web["tool_policy"] == %{"http.get" => "auto"}
  end

  test "no grants still composes — never the file as written" do
    [builder, _web] = AgentConfig.role_definitions(@roster, [], "cat", "m")
    assert builder["tool_policy"]["files.delete"] == "ask"
  end
end
