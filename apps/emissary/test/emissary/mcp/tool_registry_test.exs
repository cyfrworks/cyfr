defmodule Emissary.MCP.ToolRegistryTest do
  @moduledoc """
  Tests for the MCP tool registry.

  Verifies tool discovery, listing, lookup, and delegation.
  """
  use ExUnit.Case, async: true

  alias Emissary.MCP.ToolRegistry
  alias Sanctum.Context

  describe "list_tools/0" do
    test "returns a list of tools" do
      tools = ToolRegistry.list_tools()
      assert is_list(tools)
    end

    test "tools have required MCP fields" do
      tools = ToolRegistry.list_tools()

      for tool <- tools do
        assert Map.has_key?(tool, "name")
        assert Map.has_key?(tool, "description")
        assert Map.has_key?(tool, "inputSchema")
      end
    end

    test "tools are sorted by name" do
      tools = ToolRegistry.list_tools()
      names = Enum.map(tools, & &1["name"])

      assert names == Enum.sort(names)
    end

    test "inputSchema has valid JSON Schema type" do
      tools = ToolRegistry.list_tools()

      for tool <- tools do
        schema = tool["inputSchema"]
        assert is_map(schema)
        assert schema["type"] == "object"
      end
    end

    test "includes system tool from SystemProvider" do
      tools = ToolRegistry.list_tools()
      tool_names = Enum.map(tools, & &1["name"])

      assert "system" in tool_names
    end
  end

  describe "get_tool/1" do
    test "returns tool definition for existing tool" do
      {:ok, tool} = ToolRegistry.get_tool("system")

      assert tool["name"] == "system"
      assert is_binary(tool["description"])
      assert is_map(tool["inputSchema"])
    end

    test "returns error for non-existent tool" do
      result = ToolRegistry.get_tool("nonexistent/tool")

      assert {:error, :not_found} = result
    end

    test "tool definition matches list_tools format" do
      {:ok, tool} = ToolRegistry.get_tool("system")
      tools = ToolRegistry.list_tools()
      system_from_list = Enum.find(tools, &(&1["name"] == "system"))

      assert tool == system_from_list
    end
  end

  describe "call/3" do
    test "delegates to correct provider module" do
      ctx = Context.local()

      {:ok, result} = ToolRegistry.call("system", ctx, %{"action" => "status"})

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert result.status in ["ok", "degraded"]
    end

    test "returns error for unknown tool" do
      ctx = Context.local()

      result = ToolRegistry.call("nonexistent/tool", ctx, %{})

      assert {:error, message} = result
      assert message =~ "Unknown tool"
    end

    test "handles provider errors gracefully" do
      ctx = Context.local()

      # Call system with invalid action to trigger error
      {:error, message} = ToolRegistry.call("system", ctx, %{"action" => "invalid_action"})

      assert message =~ "Unknown action"
    end

    test "passes context and args to provider" do
      ctx = Context.local()

      # Verify context is passed through by checking whoami-like behavior
      # The system tool doesn't expose context directly, but we can verify
      # the call succeeds with valid context
      {:ok, result} = ToolRegistry.call("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert result.status == "ok"
      assert result.services.emissary == "ok"
    end
  end

  describe "exists?/1" do
    test "returns true for existing tool" do
      assert ToolRegistry.exists?("system") == true
    end

    test "returns false for non-existent tool" do
      assert ToolRegistry.exists?("nonexistent/tool") == false
    end
  end

  describe "refresh/0" do
    test "reloads providers and returns tool count" do
      {:ok, count} = ToolRegistry.refresh()

      assert is_integer(count)
      assert count > 0
    end

    test "tools are available after refresh" do
      {:ok, _count} = ToolRegistry.refresh()

      # Verify tools are still accessible
      tools = ToolRegistry.list_tools()
      assert length(tools) > 0
    end
  end

  describe "tool schema validation" do
    test "system tool has action enum" do
      {:ok, tool} = ToolRegistry.get_tool("system")

      action_prop = tool["inputSchema"]["properties"]["action"]
      assert action_prop["type"] == "string"
      assert "status" in action_prop["enum"]
      assert "notify" in action_prop["enum"]
    end

    test "system tool has required action field" do
      {:ok, tool} = ToolRegistry.get_tool("system")

      assert "action" in tool["inputSchema"]["required"]
    end
  end

  describe "error handling" do
    test "handles provider crash gracefully" do
      ctx = Context.local()

      # Calling a non-existent action will raise in the provider
      # The registry should catch this and return an error tuple
      result = ToolRegistry.call("system", ctx, %{"action" => "crash_intentionally"})

      # Should return error instead of crashing
      assert {:error, message} = result
      assert is_binary(message)
    end

    test "returns meaningful error for unknown tool" do
      ctx = Context.local()

      result = ToolRegistry.call("completely/unknown/tool", ctx, %{})

      assert {:error, message} = result
      assert message =~ "Unknown tool"
      assert message =~ "completely/unknown/tool"
    end

    test "handles nil arguments gracefully" do
      ctx = Context.local()

      # This should fail due to missing required action, but not crash
      {:error, message} = ToolRegistry.call("system", ctx, %{})

      assert message =~ "action"
    end

    test "provider errors are wrapped with context" do
      ctx = Context.local()

      # Invalid action will trigger an error from the provider
      {:error, message} = ToolRegistry.call("system", ctx, %{"action" => "nonexistent"})

      # Error should be descriptive
      assert is_binary(message)
    end

    test "call returns error tuple on missing context fields" do
      # Create a minimal context with nil user_id
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :personal,
        auth_method: nil,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      # The tool should handle nil user_id gracefully
      result = ToolRegistry.call("system", ctx, %{"action" => "status"})

      # Should still work - status doesn't require auth
      assert {:ok, _} = result
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads safely" do
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            ToolRegistry.list_tools()
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return the same list
      first_result = hd(results)
      assert Enum.all?(results, &(&1 == first_result))
    end

    test "handles concurrent calls safely" do
      ctx = Context.local()

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            ToolRegistry.call("system", ctx, %{"action" => "status"})
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      for result <- results do
        assert {:ok, _} = result
      end
    end
  end

  describe "optional MCP 2025-11-25 fields" do
    test "tools may include title field" do
      {:ok, tool} = ToolRegistry.get_tool("system")

      # SystemProvider includes title
      if Map.has_key?(tool, "title") do
        assert is_binary(tool["title"])
      end
    end

    test "optional fields are excluded when nil" do
      tools = ToolRegistry.list_tools()

      for tool <- tools do
        # Verify nil values are not included in output
        refute Map.has_key?(tool, "icons") and is_nil(tool["icons"])
        refute Map.has_key?(tool, "outputSchema") and is_nil(tool["outputSchema"])
        refute Map.has_key?(tool, "annotations") and is_nil(tool["annotations"])
      end
    end
  end

  describe "provider resilience" do
    test "provider exception is caught and returns error" do
      ctx = Context.local()

      # The system tool with an invalid action should trigger an error
      # that is caught by the rescue block
      result = ToolRegistry.call("system", ctx, %{"action" => "this_will_cause_error"})

      assert {:error, message} = result
      assert is_binary(message)
    end

    test "provider returning unexpected value is handled gracefully" do
      ctx = Context.local()

      # A valid tool call should succeed
      {:ok, result} = ToolRegistry.call("system", ctx, %{"action" => "status"})
      assert is_map(result)
    end

    test "multiple failed calls do not affect subsequent calls" do
      ctx = Context.local()

      # First call fails
      {:error, _} = ToolRegistry.call("system", ctx, %{"action" => "bad_action"})

      # Second call should still work
      {:ok, result} = ToolRegistry.call("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]

      # Third call fails
      {:error, _} = ToolRegistry.call("system", ctx, %{"action" => "another_bad"})

      # Fourth call should still work
      {:ok, result} = ToolRegistry.call("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]
    end

    test "error messages from provider are descriptive" do
      ctx = Context.local()

      {:error, message} = ToolRegistry.call("system", ctx, %{"action" => "unknown_action"})

      # Error should mention the issue
      assert message =~ "Unknown action" or message =~ "unknown_action"
    end

    test "provider crash with nil context field is handled" do
      # Context with potentially problematic nil fields
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new(),
        scope: nil,
        auth_method: nil,
        api_key_type: nil,
        request_id: nil,
        session_id: nil
      }

      # Should not crash the registry
      result = ToolRegistry.call("system", ctx, %{"action" => "status"})

      # Might succeed or fail gracefully depending on provider
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "concurrent calls with mixed success/failure are isolated" do
      ctx = Context.local()

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Even: valid call
              ToolRegistry.call("system", ctx, %{"action" => "status"})
            else
              # Odd: invalid call
              ToolRegistry.call("system", ctx, %{"action" => "invalid_#{i}"})
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Count successes and failures
      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      # Should have 10 of each
      assert successes == 10
      assert failures == 10
    end
  end

  describe "timeout handling" do
    test "registry remains responsive during tool execution" do
      ctx = Context.local()

      # Start a tool call
      task =
        Task.async(fn ->
          ToolRegistry.call("system", ctx, %{"action" => "status"})
        end)

      # While it's running, list_tools should still work
      tools = ToolRegistry.list_tools()
      assert is_list(tools)
      assert length(tools) > 0

      # Original call should complete
      {:ok, result} = Task.await(task, 5000)
      assert is_map(result)
    end

    test "registry can serve multiple concurrent operations" do
      ctx = Context.local()

      # Mix of operations
      call_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ToolRegistry.call("system", ctx, %{"action" => "status"})
          end)
        end

      list_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ToolRegistry.list_tools()
          end)
        end

      get_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ToolRegistry.get_tool("system")
          end)
        end

      exists_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ToolRegistry.exists?("system")
          end)
        end

      # All should complete successfully
      all_tasks = call_tasks ++ list_tasks ++ get_tasks ++ exists_tasks
      results = Task.await_many(all_tasks, 10_000)

      assert length(results) == 40
    end
  end
end
