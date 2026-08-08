# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Policy.RestrictedToolsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Policy.RestrictedTools

  describe "restricted_for/1" do
    test "returns non-empty list for :formula" do
      list = RestrictedTools.restricted_for(:formula)
      assert match?([_ | _], list)
    end

    test "includes key security patterns" do
      list = RestrictedTools.restricted_for(:formula)
      assert "session.*" in list
      assert "key.*" in list
      assert "permission.*" in list
      assert "vault.create" in list
      assert "webhook.create" in list
      assert "schedule.create" in list
      assert "tincture_visibility.set" in list
    end

    test "every restricted pattern names a live tool action" do
      live =
        Application.get_env(:cyfr, :tool_providers, [])
        |> Enum.filter(&Code.ensure_loaded?/1)
        |> Enum.flat_map(& &1.tools())
        |> Map.new(fn tool ->
          actions =
            case tool.input_schema do
              %{"properties" => %{"action" => %{"enum" => actions}}} -> actions
              _ -> []
            end

          {tool.name, actions}
        end)

      # Tools owned by sibling umbrella apps aren't on the code path when
      # this suite runs standalone; the root suite and CI cover them.
      sibling_app_tools = ~w(execution schedule build)

      for pattern <- RestrictedTools.restricted_for(:formula) do
        [tool, action] = String.split(pattern, ".", parts: 2)

        case Map.fetch(live, tool) do
          {:ok, actions} ->
            if action != "*" do
              assert action in actions,
                     "restricted pattern #{pattern} names an action that does not exist " <>
                       "(live actions for #{tool}: #{inspect(actions)})"
            end

          :error ->
            assert tool in sibling_app_tools,
                   "restricted pattern #{pattern} names a tool no provider registers"
        end
      end
    end
  end

  describe "check/2" do
    test "allows safe tools" do
      assert :allowed = RestrictedTools.check(:formula, "execution.run")
      assert :allowed = RestrictedTools.check(:formula, "component.search")
      assert :allowed = RestrictedTools.check(:formula, "component.inspect")
      assert :allowed = RestrictedTools.check(:formula, "aqua.get")
      assert :allowed = RestrictedTools.check(:formula, "tools.list")
    end

    test "blocks exact restricted matches" do
      assert {:restricted, "vault.create"} = RestrictedTools.check(:formula, "vault.create")
      assert {:restricted, "webhook.create"} = RestrictedTools.check(:formula, "webhook.create")
      assert {:restricted, "profile.commit"} = RestrictedTools.check(:formula, "profile.commit")

      assert {:restricted, "component.push"} =
               RestrictedTools.check(:formula, "component.push")

      assert {:restricted, "component.delete"} =
               RestrictedTools.check(:formula, "component.delete")

      assert {:restricted, "execution.force_release"} =
               RestrictedTools.check(:formula, "execution.force_release")

      assert {:restricted, "system.notify"} = RestrictedTools.check(:formula, "system.notify")
    end

    test "blocks standing-ingress and exposure mutations, keeps reads callable" do
      for action <- ~w(create update revoke rotate) do
        assert {:restricted, _} = RestrictedTools.check(:formula, "webhook.#{action}")
      end

      for action <- ~w(create update delete pause resume re_resolve) do
        assert {:restricted, _} = RestrictedTools.check(:formula, "schedule.#{action}")
      end

      for action <- ~w(create delete enable disable test refresh) do
        assert {:restricted, _} = RestrictedTools.check(:formula, "mcp_servers.#{action}")
      end

      assert {:restricted, "tincture_visibility.set"} =
               RestrictedTools.check(:formula, "tincture_visibility.set")

      assert :allowed = RestrictedTools.check(:formula, "webhook.list")
      assert :allowed = RestrictedTools.check(:formula, "webhook.get")
      assert :allowed = RestrictedTools.check(:formula, "schedule.list")
      assert :allowed = RestrictedTools.check(:formula, "schedule.get")
      assert :allowed = RestrictedTools.check(:formula, "mcp_servers.list")
      assert :allowed = RestrictedTools.check(:formula, "mcp_servers.get")
      assert :allowed = RestrictedTools.check(:formula, "tincture_visibility.get")
    end

    test "blocks wildcard restricted matches" do
      assert {:restricted, "session.*"} = RestrictedTools.check(:formula, "session.login")
      assert {:restricted, "session.*"} = RestrictedTools.check(:formula, "session.logout")
      assert {:restricted, "key.*"} = RestrictedTools.check(:formula, "key.create")
      assert {:restricted, "key.*"} = RestrictedTools.check(:formula, "key.revoke")
      assert {:restricted, "permission.*"} = RestrictedTools.check(:formula, "permission.grant")
      assert {:restricted, "record.*"} = RestrictedTools.check(:formula, "record.get")
      assert {:restricted, "retention.*"} = RestrictedTools.check(:formula, "retention.cleanup")
      assert {:restricted, "mcp_log.*"} = RestrictedTools.check(:formula, "mcp_log.query")
    end
  end

  describe "validate_allowed_tools/2" do
    test "returns :ok for safe tool lists" do
      assert :ok =
               RestrictedTools.validate_allowed_tools(:formula, [
                 "execution.run",
                 "component.search"
               ])

      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["tools.*", "guide.*"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["tools.list", "aqua.get"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, [])
    end

    test "returns :ok for '*' wildcard (allowed at save-time)" do
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["*"])
      assert :ok = RestrictedTools.validate_allowed_tools(:formula, ["*", "execution.run"])
    end

    test "catches exact restricted tool violations" do
      assert {:error, violations} =
               RestrictedTools.validate_allowed_tools(:formula, ["vault.create"])

      assert {"vault.create", "vault.create"} in violations
    end

    test "catches wildcard overlap violations" do
      assert {:error, violations} =
               RestrictedTools.validate_allowed_tools(:formula, ["session.*"])

      assert {"session.*", "session.*"} in violations
    end

    test "catches when allowed tool falls within restricted wildcard" do
      assert {:error, violations} =
               RestrictedTools.validate_allowed_tools(:formula, ["session.login"])

      assert {"session.login", "session.*"} in violations
    end

    test "catches multiple violations" do
      assert {:error, violations} =
               RestrictedTools.validate_allowed_tools(:formula, [
                 "execution.run",
                 "session.login",
                 "vault.create",
                 "component.search"
               ])

      violating_tools = Enum.map(violations, &elem(&1, 0)) |> Enum.uniq()
      assert "session.login" in violating_tools
      assert "vault.create" in violating_tools
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
      policy = %Sanctum.Policy{allowed_tools: ["execution.run", "aqua.*"]}

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
          "name" => "aqua",
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
      assert "aqua" in names
      refute "component" in names

      exec = Enum.find(result, &(&1["name"] == "execution"))
      actions = get_in(exec, ["inputSchema", "properties", "action", "enum"])
      assert actions == ["run"]
    end

    test "removes tool entirely when all actions are filtered out" do
      policy = %Sanctum.Policy{allowed_tools: ["aqua.get"]}

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
          "name" => "aqua",
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
      assert "aqua" in names
    end

    test "nil policy shows all non-restricted tools" do
      tool_defs = [
        %{
          "name" => "aqua",
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
      refute RestrictedTools.patterns_overlap?("component.search", "component.push")
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
