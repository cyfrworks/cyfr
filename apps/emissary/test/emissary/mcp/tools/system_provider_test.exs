defmodule Emissary.MCP.Tools.SystemProviderTest do
  @moduledoc """
  Unit tests for the SystemProvider MCP tool.

  Tests the system tool with its status and notify actions.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.Tools.SystemProvider
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  describe "tools/0" do
    test "returns a list with system tool" do
      tools = SystemProvider.tools()

      assert is_list(tools)
      assert length(tools) == 1
    end

    test "system tool has correct name" do
      [tool] = SystemProvider.tools()

      assert tool.name == "system"
    end

    test "system tool has title" do
      [tool] = SystemProvider.tools()

      assert tool.title == "System"
    end

    test "system tool has description" do
      [tool] = SystemProvider.tools()

      assert is_binary(tool.description)
      assert tool.description =~ "health"
    end

    test "input_schema has action enum with status and notify" do
      [tool] = SystemProvider.tools()

      action_prop = tool.input_schema["properties"]["action"]
      assert action_prop["type"] == "string"
      assert action_prop["enum"] == ["status", "notify"]
    end

    test "input_schema has scope property for status" do
      [tool] = SystemProvider.tools()

      scope_prop = tool.input_schema["properties"]["scope"]
      assert scope_prop["type"] == "string"
      assert "all" in scope_prop["enum"]
      assert "emissary" in scope_prop["enum"]
      assert "sanctum" in scope_prop["enum"]
      assert "arca" in scope_prop["enum"]
      assert "opus" in scope_prop["enum"]
      assert "compendium" in scope_prop["enum"]
    end

    test "input_schema has notify parameters" do
      [tool] = SystemProvider.tools()

      props = tool.input_schema["properties"]
      assert props["event"]["type"] == "string"
      assert props["target"]["type"] == "string"
      assert props["payload"]["type"] == "object"
    end

    test "action is required" do
      [tool] = SystemProvider.tools()

      assert tool.input_schema["required"] == ["action"]
    end
  end

  describe "handle/3 - status action with scope 'all'" do
    test "returns ok or degraded status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert result.status in ["ok", "degraded"]
    end

    test "includes version" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_binary(result.version)
    end

    test "includes uptime_seconds" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_integer(result.uptime_seconds)
      assert result.uptime_seconds >= 0
    end

    test "includes services map" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_map(result.services)
      assert Map.has_key?(result.services, :emissary)
      assert Map.has_key?(result.services, :sanctum)
      assert Map.has_key?(result.services, :arca)
      assert Map.has_key?(result.services, :opus)
      assert Map.has_key?(result.services, :compendium)
    end

    test "emissary service is always ok" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert result.services.emissary == "ok"
    end

    test "includes mcp metadata" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status"})

      assert is_map(result.mcp)
      assert is_binary(result.mcp.protocol_version)
      assert is_integer(result.mcp.tools_count)
      assert is_integer(result.mcp.resources_count)
    end
  end

  describe "handle/3 - status action with specific scopes" do
    test "scope emissary returns only emissary status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert result.status == "ok"
      assert Map.keys(result.services) == [:emissary]
      assert result.services.emissary == "ok"
    end

    test "scope sanctum returns only sanctum status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "sanctum"})

      assert result.status == "ok"
      assert Map.keys(result.services) == [:sanctum]
    end

    test "scope arca returns only arca status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "arca"})

      assert Map.keys(result.services) == [:arca]
    end

    test "scope opus returns only opus status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "opus"})

      assert Map.keys(result.services) == [:opus]
      assert result.services.opus == "ok"
    end

    test "scope compendium returns only compendium status" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "compendium"})

      assert Map.keys(result.services) == [:compendium]
    end

    test "scoped status includes version and uptime" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert is_binary(result.version)
      assert is_integer(result.uptime_seconds)
    end

    test "invalid scope returns error" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{"action" => "status", "scope" => "invalid"})

      assert message =~ "Invalid scope"
      assert message =~ "all"
    end
  end

  describe "handle/3 - notify action success" do
    test "returns notification details on success" do
      ctx = Context.local()

      # Use unreachable endpoint to verify error handling
      {:ok, result} = SystemProvider.handle("system", ctx, %{
        "action" => "notify",
        "event" => "test.event",
        "target" => "http://localhost:9999/unreachable",
        "payload" => %{"key" => "value"}
      })

      # Will fail to connect but should not crash
      assert result.delivered == false
      assert result.target == "http://localhost:9999/unreachable"
      assert result.event == "test.event"
      assert is_binary(result.error)
    end
  end

  describe "handle/3 - notify action with unreachable target" do
    test "returns delivered: false with error" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{
        "action" => "notify",
        "event" => "test.event",
        "target" => "http://unreachable.invalid/webhook"
      })

      assert result.delivered == false
      assert is_binary(result.error)
    end
  end

  describe "handle/3 - notify action errors" do
    test "missing target returns error" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{
        "action" => "notify",
        "event" => "test.event"
      })

      assert message =~ "Missing required parameter: target"
    end

    test "missing event returns error" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{
        "action" => "notify",
        "target" => "http://example.com/webhook"
      })

      assert message =~ "Missing required parameter: event"
    end

    test "nil payload uses empty map" do
      ctx = Context.local()

      {:ok, result} = SystemProvider.handle("system", ctx, %{
        "action" => "notify",
        "event" => "test.event",
        "target" => "http://localhost:9999/test"
      })

      # Should not crash with nil payload
      assert is_map(result)
    end
  end

  describe "handle/3 - invalid action" do
    test "unknown action returns error" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{"action" => "invalid_action"})

      assert message =~ "Unknown action"
    end
  end

  describe "handle/3 - missing required params" do
    test "missing action returns error" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("system", ctx, %{})

      assert message =~ "Missing required parameter: action"
    end
  end

  describe "handle/3 - unknown tool" do
    test "returns error for unknown tool name" do
      ctx = Context.local()

      {:error, message} = SystemProvider.handle("unknown", ctx, %{})

      assert message =~ "Unknown tool"
    end
  end
end
