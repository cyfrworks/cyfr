defmodule Sanctum.Policy.RestrictedToolsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Policy.RestrictedTools

  describe "restricted_for/1" do
    test "returns non-empty list for :formula" do
      list = RestrictedTools.restricted_for(:formula)
      assert is_list(list)
      assert length(list) > 0
    end

    test "includes key security patterns" do
      list = RestrictedTools.restricted_for(:formula)
      assert "session.*" in list
      assert "key.*" in list
      assert "permission.*" in list
      assert "policy.set" in list
      assert "secret.set" in list
      assert "policy_store.*" in list
    end
  end

  describe "check/2" do
    test "allows safe tools" do
      assert :allowed = RestrictedTools.check(:formula, "execution.run")
      assert :allowed = RestrictedTools.check(:formula, "component.search")
      assert :allowed = RestrictedTools.check(:formula, "component.inspect")
      assert :allowed = RestrictedTools.check(:formula, "guide.get")
      assert :allowed = RestrictedTools.check(:formula, "tools.list")
      assert :allowed = RestrictedTools.check(:formula, "policy.get")
      assert :allowed = RestrictedTools.check(:formula, "secret.get")
    end

    test "blocks exact restricted matches" do
      assert {:restricted, "policy.set"} = RestrictedTools.check(:formula, "policy.set")
      assert {:restricted, "policy.delete"} = RestrictedTools.check(:formula, "policy.delete")
      assert {:restricted, "secret.set"} = RestrictedTools.check(:formula, "secret.set")
      assert {:restricted, "secret.delete"} = RestrictedTools.check(:formula, "secret.delete")
      assert {:restricted, "component.publish"} = RestrictedTools.check(:formula, "component.publish")
      assert {:restricted, "component.remove"} = RestrictedTools.check(:formula, "component.remove")
      assert {:restricted, "execution.force_release"} = RestrictedTools.check(:formula, "execution.force_release")
      assert {:restricted, "system.notify"} = RestrictedTools.check(:formula, "system.notify")
    end

    test "blocks wildcard restricted matches" do
      assert {:restricted, "session.*"} = RestrictedTools.check(:formula, "session.login")
      assert {:restricted, "session.*"} = RestrictedTools.check(:formula, "session.logout")
      assert {:restricted, "key.*"} = RestrictedTools.check(:formula, "key.create")
      assert {:restricted, "key.*"} = RestrictedTools.check(:formula, "key.revoke")
      assert {:restricted, "permission.*"} = RestrictedTools.check(:formula, "permission.grant")
      assert {:restricted, "policy_store.*"} = RestrictedTools.check(:formula, "policy_store.get")
      assert {:restricted, "secret_store.*"} = RestrictedTools.check(:formula, "secret_store.put")
      assert {:restricted, "mcp_log.*"} = RestrictedTools.check(:formula, "mcp_log.query")
    end
  end

  describe "validate_allowed_tools/2" do
    test "returns :ok for safe tool lists" do
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["execution.run", "component.search"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["tools.*", "guide.*"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["tools.list", "guide.get"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, [])
    end

    test "returns :ok for '*' wildcard (allowed at save-time)" do
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["*"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["*", "execution.run"])
    end

    test "catches exact restricted tool violations" do
      assert {:error, violations} = RestrictedTools.validate_allowed_tools(:formula, ["policy.set"])
      assert {"policy.set", "policy.set"} in violations
    end

    test "catches wildcard overlap violations" do
      assert {:error, violations} = RestrictedTools.validate_allowed_tools(:formula, ["session.*"])
      assert {"session.*", "session.*"} in violations
    end

    test "catches when allowed tool falls within restricted wildcard" do
      assert {:error, violations} = RestrictedTools.validate_allowed_tools(:formula, ["session.login"])
      assert {"session.login", "session.*"} in violations
    end

    test "catches multiple violations" do
      assert {:error, violations} = RestrictedTools.validate_allowed_tools(:formula, [
        "execution.run",
        "session.login",
        "policy.set",
        "component.search"
      ])

      violating_tools = Enum.map(violations, &elem(&1, 0)) |> Enum.uniq()
      assert "session.login" in violating_tools
      assert "policy.set" in violating_tools
      refute "execution.run" in violating_tools
      refute "component.search" in violating_tools
    end
  end

  describe "filter_tool_list/3" do
    test "removes entirely restricted tool namespaces" do
      tool_defs = [
        %{
          "name" => "session",
          "description" => "Session management",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["login", "logout", "whoami"]}
            }
          }
        },
        %{
          "name" => "execution",
          "description" => "Component execution",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["run", "list", "force_release"]}
            }
          }
        }
      ]

      result = RestrictedTools.filter_tool_list(:formula, tool_defs, nil)

      names = Enum.map(result, & &1["name"])
      refute "session" in names
      assert "execution" in names
    end

    test "strips restricted actions from action enum" do
      tool_defs = [
        %{
          "name" => "execution",
          "description" => "Component execution",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["run", "list", "status", "force_release", "ping"]}
            }
          }
        }
      ]

      [exec] = RestrictedTools.filter_tool_list(:formula, tool_defs, nil)
      actions = get_in(exec, ["inputSchema", "properties", "action", "enum"])

      assert "run" in actions
      assert "list" in actions
      refute "force_release" in actions
    end

    test "applies policy allowed_tools filter" do
      policy = %Sanctum.Policy{allowed_tools: ["execution.run", "guide.*"]}

      tool_defs = [
        %{
          "name" => "execution",
          "description" => "Execution",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["run", "list", "status"]}
            }
          }
        },
        %{
          "name" => "guide",
          "description" => "Guides",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["list", "get"]}
            }
          }
        },
        %{
          "name" => "component",
          "description" => "Components",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["search", "inspect"]}
            }
          }
        }
      ]

      result = RestrictedTools.filter_tool_list(:formula, tool_defs, policy)
      names = Enum.map(result, & &1["name"])

      assert "execution" in names
      assert "guide" in names
      refute "component" in names

      exec = Enum.find(result, &(&1["name"] == "execution"))
      actions = get_in(exec, ["inputSchema", "properties", "action", "enum"])
      assert actions == ["run"]
    end

    test "removes tool entirely when all actions are filtered out" do
      policy = %Sanctum.Policy{allowed_tools: ["guide.get"]}

      tool_defs = [
        %{
          "name" => "execution",
          "description" => "Execution",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["run", "list"]}
            }
          }
        },
        %{
          "name" => "guide",
          "description" => "Guides",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["list", "get"]}
            }
          }
        }
      ]

      result = RestrictedTools.filter_tool_list(:formula, tool_defs, policy)
      names = Enum.map(result, & &1["name"])

      refute "execution" in names
      assert "guide" in names
    end

    test "nil policy shows all non-restricted tools" do
      tool_defs = [
        %{
          "name" => "guide",
          "description" => "Guides",
          "inputSchema" => %{
            "properties" => %{
              "action" => %{"enum" => ["list", "get"]}
            }
          }
        }
      ]

      result = RestrictedTools.filter_tool_list(:formula, tool_defs, nil)
      assert length(result) == 1
      actions = get_in(hd(result), ["inputSchema", "properties", "action", "enum"])
      assert actions == ["list", "get"]
    end
  end

  describe "patterns_overlap?/2" do
    test "exact patterns match only when identical" do
      assert RestrictedTools.patterns_overlap?("policy.set", "policy.set")
      refute RestrictedTools.patterns_overlap?("policy.set", "policy.get")
      refute RestrictedTools.patterns_overlap?("component.search", "component.publish")
    end

    test "wildcard covers exact in same namespace" do
      assert RestrictedTools.patterns_overlap?("session.*", "session.login")
      assert RestrictedTools.patterns_overlap?("session.login", "session.*")
      refute RestrictedTools.patterns_overlap?("session.*", "policy.set")
    end

    test "wildcards in same namespace overlap" do
      assert RestrictedTools.patterns_overlap?("session.*", "session.*")
      refute RestrictedTools.patterns_overlap?("session.*", "policy.*")
    end
  end
end
