# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.Tools.SystemProviderTest do
  @moduledoc """
  Unit tests for the SystemProvider MCP tool.

  Tests the system tool with its status and notify actions.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.Tools.SystemProvider

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "tools/0" do
    test "returns a list with the system, tools and resource tools" do
      tools = SystemProvider.tools()

      assert is_list(tools)
      assert length(tools) == 3
      names = Enum.map(tools, & &1.name)
      assert "system" in names
      assert "tools" in names
      assert "resource" in names
    end

    test "system tool has correct name" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      assert tool.name == "system"
    end

    test "system tool has title" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      assert tool.title == "System"
    end

    test "system tool has description" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      assert is_binary(tool.description)
      assert tool.description =~ "health"
    end

    test "input_schema has action enum with status and notify" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      action_prop = tool.input_schema["properties"]["action"]
      assert action_prop["type"] == "string"
      assert action_prop["enum"] == ["status", "notify"]
    end

    test "input_schema has scope property for status" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      scope_prop = action_schema(tool, "status")["properties"]["scope"]
      assert scope_prop["type"] == "string"
      assert "all" in scope_prop["enum"]
      assert "emissary" in scope_prop["enum"]
      assert "sanctum" in scope_prop["enum"]
      assert "arca" in scope_prop["enum"]
      assert "opus" in scope_prop["enum"]
      assert "compendium" in scope_prop["enum"]
    end

    test "input_schema has notify parameters" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      props = action_schema(tool, "notify")["properties"]
      assert props["event"]["type"] == "string"
      assert props["target"]["type"] == "string"
      assert props["payload"]["type"] == "object"
      assert Enum.sort(action_schema(tool, "notify")["required"]) == ["action", "event", "target"]
    end

    test "action is required" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      assert tool.input_schema["required"] == ["action"]
    end

    test "tools tool has list action" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "tools"))

      assert tool.title == "Tools"
      action_prop = tool.input_schema["properties"]["action"]
      assert action_prop["enum"] == ["list"]
    end
  end

  describe "registry health" do
    # The probe is off in the suite (it is a DNS and TLS round trip); these
    # turn it on against the closed loopback port the suite configures as
    # the registry, so the answer is immediate and never leaves this machine.
    setup do
      previous = Application.get_env(:cyfr, :registry_health_probe)
      key = {:registry_health, Compendium.RegistryHost.canonical_host()}
      Arca.Cache.invalidate(key)

      on_exit(fn ->
        Application.put_env(:cyfr, :registry_health_probe, previous)
        Arca.Cache.invalidate(key)
      end)

      :ok
    end

    test "a configured registry that does not answer is unreachable, within the probe's timeout" do
      Application.put_env(:cyfr, :registry_health_probe, true)
      started = System.monotonic_time(:millisecond)

      {:ok, result} =
        SystemProvider.handle("system", Sanctum.TestContext.local(), %{"action" => "status"})

      assert result.services.registry == "unreachable"
      assert System.monotonic_time(:millisecond) - started < 5_000
    end

    test "what configuration decides is answered afresh, never from a cached probe" do
      Application.put_env(:cyfr, :registry_health_probe, true)
      ctx = Sanctum.TestContext.local()

      {:ok, probed} = SystemProvider.handle("system", ctx, %{"action" => "status"})
      assert probed.services.registry == "unreachable"

      Application.put_env(:cyfr, :registry_health_probe, false)
      {:ok, unprobed} = SystemProvider.handle("system", ctx, %{"action" => "status"})
      assert unprobed.services.registry == "unknown"
    end

    test "with the probe off the answer is unknown, never a guess" do
      Application.put_env(:cyfr, :registry_health_probe, false)

      {:ok, result} =
        SystemProvider.handle("system", Sanctum.TestContext.local(), %{"action" => "status"})

      assert result.services.registry == "unknown"
    end
  end

  describe "handle/3 - status action with scope 'all'" do
    test "returns ok or degraded status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert result.status in ["ok", "degraded"]
    end

    test "includes version" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_binary(result.version)
    end

    test "includes uptime_seconds" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_integer(result.uptime_seconds)
      assert result.uptime_seconds >= 0
    end

    test "includes services map" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_map(result.services)
      assert Map.has_key?(result.services, :emissary)
      assert Map.has_key?(result.services, :sanctum)
      assert Map.has_key?(result.services, :arca)
      assert Map.has_key?(result.services, :opus)
      assert Map.has_key?(result.services, :compendium)
    end

    test "emissary service is always ok" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert result.services.emissary == "ok"
    end

    test "includes mcp metadata" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_map(result.mcp)
      assert is_binary(result.mcp.protocol_version)
      assert is_integer(result.mcp.tools_count)
      assert is_integer(result.mcp.resources_count)
    end
  end

  describe "handle/3 - status action with specific scopes" do
    test "scope emissary returns only emissary status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert result.status == "ok"
      assert Map.keys(result.services) == [:emissary]
      assert result.services.emissary == "ok"
    end

    test "scope sanctum returns only sanctum status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "sanctum"})

      assert result.status == "ok"
      assert Map.keys(result.services) == [:sanctum]
    end

    test "scope arca returns only arca status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "arca"})

      assert Map.keys(result.services) == [:arca]
    end

    test "scope opus returns only opus status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "opus"})

      assert Map.keys(result.services) == [:opus]
      assert result.services.opus == "ok"
    end

    test "scope compendium returns only compendium status" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "compendium"})

      assert Map.keys(result.services) == [:compendium]
    end

    test "scoped status includes version and uptime" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert is_binary(result.version)
      assert is_integer(result.uptime_seconds)
    end

    test "scope locus is a valid scope and reports its provider" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "locus"})

      assert Map.keys(result.services) == [:locus]
    end

    test "the scope enum is the derived roster" do
      tool = Enum.find(SystemProvider.tools(), &(&1.name == "system"))

      assert action_schema(tool, "status")["properties"]["scope"]["enum"] ==
               ["all"] ++ Cyfr.Ops.Services.service_names() ++ ["registry"]
    end

    test "invalid scope returns error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "invalid"})

      assert message =~ "Invalid scope"
      assert message =~ "all"
    end
  end

  describe "handle/3 - notify action success" do
    test "an SSRF-blocked target is a tool error naming the target" do
      ctx = Sanctum.TestContext.local()

      # localhost is blocked by SSRF validation
      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://localhost:9999/unreachable",
          "payload" => %{"key" => "value"}
        })

      assert message =~ "http://localhost:9999/unreachable"
      assert message =~ "validation failed"
    end
  end

  describe "handle/3 - notify action with unreachable target" do
    test "returns a tool error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://unreachable.invalid/webhook"
        })

      # Failed or blocked delivery must return a failed tool call.
      assert is_binary(message)
    end
  end

  describe "handle/3 - notify SSRF protection" do
    test "blocks cloud metadata endpoint (169.254.169.254)" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://169.254.169.254/latest/meta-data/"
        })

      # Failed or blocked delivery must return a failed tool call.
      assert is_binary(message)
    end

    test "blocks private IP (10.0.0.1)" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://10.0.0.1/internal"
        })

      # Failed or blocked delivery must return a failed tool call.
      assert is_binary(message)
    end

    test "blocks loopback (127.0.0.1)" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://127.0.0.1/admin"
        })

      # Failed or blocked delivery must return a failed tool call.
      assert is_binary(message)
    end

    test "blocks file:// scheme" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "file:///etc/passwd"
        })

      # Failed or blocked delivery must return a failed tool call.
      assert is_binary(message)
    end
  end

  describe "handle/3 - notify action errors" do
    test "missing target returns error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event"
        })

      assert message =~ "Missing required parameter: target"
    end

    test "missing event returns error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "target" => "http://example.com/webhook"
        })

      assert message =~ "Missing required parameter: event"
    end

    test "nil payload uses empty map" do
      ctx = Sanctum.TestContext.local()

      # Should not crash with nil payload; the unreachable target is a
      # clean tool error, not a raise.
      {:error, message} =
        SystemProvider.handle("system", ctx, %{
          "action" => "notify",
          "event" => "test.event",
          "target" => "http://unreachable.invalid/test"
        })

      assert is_binary(message)
    end
  end

  describe "handle/3 - invalid action" do
    test "unknown action returns error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{"action" => "invalid_action"})

      assert message =~ "Unknown action"
    end
  end

  describe "handle/3 - missing required params" do
    test "missing action returns error" do
      ctx = Sanctum.TestContext.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{})

      assert message =~ "Missing required parameter: action"
    end
  end

  describe "handle/3 - unknown tool" do
    test "returns error for unknown tool name" do
      ctx = Sanctum.TestContext.local()

      {:error, message} = SystemProvider.handle("unknown", ctx, %{})

      assert message =~ "Unknown tool"
    end
  end

  # One action's own declaration, as `Cyfr.Ops.Operation.cast/2` applies it;
  # the tool's discovery schema merges every action into one flat object.
  defp action_schema(tool, action) do
    case Enum.find(tool.operations, &(&1.action == action)) do
      nil ->
        flunk("missing schema for #{tool.name}.#{action}")

      operation ->
        operation.args
        |> Cyfr.Ops.Arg.schema()
        |> put_in(["properties", "action"], %{"type" => "string", "const" => action})
        |> Map.update!("required", &["action" | &1])
    end
  end
end
