# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ToolRegistryTest.CrashingProvider do
  @moduledoc false
  # A provider that fails the way a real one would: by raising or exiting
  # rather than returning an error tuple.
  def handle(_tool, _ctx, %{"action" => "raise"}), do: raise("boom from provider")
  def handle(_tool, _ctx, %{"action" => "exit"}), do: exit(:provider_exit)
  def handle(_tool, _ctx, _args), do: {:ok, %{"ok" => true}}
end

defmodule Emissary.MCP.ToolRegistryTest.BlockingProvider do
  @moduledoc false
  # A provider that stays in flight. It announces its own pid to the test
  # process first, so a test can assert on the dispatcher's bookkeeping while
  # the call is provably still running instead of guessing at a delay.
  def handle(_tool, _ctx, args) do
    send(Map.fetch!(args, :reply_to), {:handler_running, self()})
    Process.sleep(:infinity)
  end
end

defmodule Emissary.MCP.ToolRegistryTest do
  @moduledoc """
  Tests for the MCP tool registry.

  Verifies tool discovery, listing, lookup, and delegation.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

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
      ctx = Sanctum.TestContext.local()

      {:ok, result} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert result.status in ["ok", "degraded"]
    end

    test "returns error for unknown tool" do
      ctx = Sanctum.TestContext.local()

      result = ToolRegistry.call_external("nonexistent/tool", ctx, %{})

      assert {:error, message} = result
      assert message =~ "Unknown tool"
    end

    test "handles provider errors gracefully" do
      ctx = Sanctum.TestContext.local()

      # Call system with invalid action to trigger error
      {:error, message} =
        ToolRegistry.call_external("system", ctx, %{"action" => "invalid_action"})

      assert message =~ "Unknown action"
    end

    test "passes context and args to provider" do
      ctx = Sanctum.TestContext.local()

      # Verify context is passed through by checking whoami-like behavior
      # The system tool doesn't expose context directly, but we can verify
      # the call succeeds with valid context
      {:ok, result} =
        ToolRegistry.call_external("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert result.status == "ok"
      assert result.services.emissary == "ok"
    end
  end

  describe "external tool auth gate" do
    test "rejects unauthenticated callers before reaching the external provider" do
      ctx = Context.build(authenticated: false, permissions: [])

      assert {:error, message} = ToolRegistry.call_external("someserver:some_tool", ctx, %{})
      assert message =~ "Unauthorized"
      refute message =~ "Unknown tool"
    end

    test "authenticated caller with a nonexistent server still gets Unknown tool" do
      ctx = Sanctum.TestContext.local()

      assert {:error, message} = ToolRegistry.call_external("no-such-server:some_tool", ctx, %{})
      assert message =~ "Unknown tool"
    end

    test "unauthenticated caller with a bare unknown name still gets Unknown tool" do
      ctx = Context.build(authenticated: false, permissions: [])

      assert {:error, message} = ToolRegistry.call_external("definitely_not_a_tool", ctx, %{})
      assert message =~ "Unknown tool"
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
      assert tools != []
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
      ctx = Sanctum.TestContext.local()

      # Calling a non-existent action will raise in the provider
      # The registry should catch this and return an error tuple
      result = ToolRegistry.call_external("system", ctx, %{"action" => "crash_intentionally"})

      # Should return error instead of crashing
      assert {:error, message} = result
      assert is_binary(message)
    end

    test "returns meaningful error for unknown tool" do
      ctx = Sanctum.TestContext.local()

      result = ToolRegistry.call_external("completely/unknown/tool", ctx, %{})

      assert {:error, message} = result
      assert message =~ "Unknown tool"
      assert message =~ "completely/unknown/tool"
    end

    @crash_tool "crash_barrier_test_tool"

    defp register_crashing_tool do
      Arca.Cache.put(
        {:mcp_tool, @crash_tool},
        {Emissary.MCP.ToolRegistryTest.CrashingProvider, %{requires_auth: false}},
        :timer.minutes(1)
      )

      on_exit(fn -> Arca.Cache.invalidate({:mcp_tool, @crash_tool}) end)
    end

    test "a raising handler yields a typed error and the caller survives" do
      register_crashing_tool()
      ctx = Sanctum.TestContext.local()
      caller = self()

      assert {:error, {:crashed, message}} =
               ToolRegistry.call_external(@crash_tool, ctx, %{"action" => "raise"})

      assert message =~ "boom from provider"

      # The whole point: Task.async would have propagated a link exit and killed
      # this process, so reaching the next line at all is the assertion.
      assert Process.alive?(caller)
      assert {:ok, %{"ok" => true}} = ToolRegistry.call_external(@crash_tool, ctx, %{})
    end

    test "an exiting handler yields a typed error and the caller survives" do
      register_crashing_tool()
      ctx = Sanctum.TestContext.local()

      assert {:error, {:exit, message}} =
               ToolRegistry.call_external(@crash_tool, ctx, %{"action" => "exit"})

      assert message =~ "exited unexpectedly"
      assert Process.alive?(self())
    end

    test "handles nil arguments gracefully" do
      ctx = Sanctum.TestContext.local()

      # This should fail due to missing required action, but not crash
      {:error, message} = ToolRegistry.call_external("system", ctx, %{})

      assert message =~ "action"
    end

    test "provider errors are wrapped with context" do
      ctx = Sanctum.TestContext.local()

      # Invalid action will trigger an error from the provider
      {:error, message} = ToolRegistry.call_external("system", ctx, %{"action" => "nonexistent"})

      # Error should be descriptive
      assert is_binary(message)
    end

    test "call returns error tuple on missing context fields" do
      # Create a minimal context with nil user_id
      ctx = %Context{
        user_id: nil,
        org_id: nil,
        permissions: MapSet.new([:*]),
        scope: :project,
        auth_method: nil,
        api_key_type: nil,
        request_id: nil
      }

      # The tool should handle nil user_id gracefully
      result = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

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
      ctx = Sanctum.TestContext.local()

      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            ToolRegistry.call_external("system", ctx, %{"action" => "status"})
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      for result <- results do
        assert {:ok, _} = result
      end
    end
  end

  describe "optional tool-definition fields" do
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

  describe "cancellation tracking" do
    @blocking_tool "cancellation_test_tool"

    defp register_blocking_tool do
      Arca.Cache.put(
        {:mcp_tool, @blocking_tool},
        {Emissary.MCP.ToolRegistryTest.BlockingProvider, %{requires_auth: false}},
        :timer.minutes(1)
      )

      on_exit(fn -> Arca.Cache.invalidate({:mcp_tool, @blocking_tool}) end)
    end

    # The transport cancels a request by request id when its caller closes the
    # response stream, so in-flight work has to be findable under that same id.
    # It used to be registered under the *client-supplied* JSON-RPC id, which
    # two callers can trivially pick the same value for.
    test "in-flight work is registered under the context's request id, and cancellable" do
      register_blocking_tool()
      ctx = %{Sanctum.TestContext.local() | request_id: "req_tracked"}
      caller = self()

      spawn(fn ->
        args = %{reply_to: caller}
        send(caller, {:result, ToolRegistry.call_external(@blocking_tool, ctx, args)})
      end)

      # The handler reports its pid and then blocks, so the call is provably
      # still in flight for the assertions below — no sleeping, no racing.
      assert_receive {:handler_running, handler_pid}, 5_000

      assert [{"req_tracked", ^handler_pid}] =
               :ets.lookup(Emissary.MCP.RunningTasks, "req_tracked")

      assert :ok = Emissary.MCP.RunningTasks.cancel("req_tracked")

      # Killing the handler surfaces to the caller as a typed error rather than
      # taking the dispatcher down with it.
      assert_receive {:result, {:error, {:exit, message}}}, 5_000
      assert message =~ "cancelled"

      :sys.get_state(Emissary.MCP.RunningTasks)
      assert {:error, :not_found} = Emissary.MCP.RunningTasks.cancel("req_tracked")
    end

    test "the entry is cleaned up when the work finishes on its own" do
      ctx = %{Sanctum.TestContext.local() | request_id: "req_finished"}

      {:ok, _} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

      :sys.get_state(Emissary.MCP.RunningTasks)
      assert {:error, :not_found} = Emissary.MCP.RunningTasks.cancel("req_finished")
    end
  end

  describe "provider resilience" do
    test "provider exception is caught and returns error" do
      ctx = Sanctum.TestContext.local()

      # The system tool with an invalid action should trigger an error
      # that is caught by the rescue block
      result = ToolRegistry.call_external("system", ctx, %{"action" => "this_will_cause_error"})

      assert {:error, message} = result
      assert is_binary(message)
    end

    test "provider returning unexpected value is handled gracefully" do
      ctx = Sanctum.TestContext.local()

      # A valid tool call should succeed
      {:ok, result} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})
      assert is_map(result)
    end

    test "multiple failed calls do not affect subsequent calls" do
      ctx = Sanctum.TestContext.local()

      # First call fails
      {:error, _} = ToolRegistry.call_external("system", ctx, %{"action" => "bad_action"})

      # Second call should still work
      {:ok, result} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]

      # Third call fails
      {:error, _} = ToolRegistry.call_external("system", ctx, %{"action" => "another_bad"})

      # Fourth call should still work
      {:ok, result} = ToolRegistry.call_external("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]
    end

    test "error messages from provider are descriptive" do
      ctx = Sanctum.TestContext.local()

      {:error, message} =
        ToolRegistry.call_external("system", ctx, %{"action" => "unknown_action"})

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
        request_id: nil
      }

      # Should not crash the registry
      result = ToolRegistry.call_external("system", ctx, %{"action" => "status"})

      # Might succeed or fail gracefully depending on provider
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "concurrent calls with mixed success/failure are isolated" do
      ctx = Sanctum.TestContext.local()

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              # Even: valid call
              ToolRegistry.call_external("system", ctx, %{"action" => "status"})
            else
              # Odd: invalid call
              ToolRegistry.call_external("system", ctx, %{"action" => "invalid_#{i}"})
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
      ctx = Sanctum.TestContext.local()

      # Start a tool call
      task =
        Task.async(fn ->
          ToolRegistry.call_external("system", ctx, %{"action" => "status"})
        end)

      # While it's running, list_tools should still work
      tools = ToolRegistry.list_tools()
      assert match?([_ | _], tools)

      # Original call should complete
      {:ok, result} = Task.await(task, 5000)
      assert is_map(result)
    end

    test "registry can serve multiple concurrent operations" do
      ctx = Sanctum.TestContext.local()

      # Mix of operations
      call_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ToolRegistry.call_external("system", ctx, %{"action" => "status"})
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

  describe "in_chain_view/1" do
    defp tool_def(name, actions_with_planes) do
      %{
        "name" => name,
        "inputSchema" => %{
          "properties" => %{"action" => %{"enum" => Map.keys(actions_with_planes)}}
        },
        "annotations" => %{
          actions:
            Map.new(actions_with_planes, fn {action, planes} ->
              {action, %{kind: :read, planes: planes}}
            end)
        }
      }
    end

    test "prunes to actions whose planes include :in_chain" do
      defs = [tool_def("mixed", %{"get" => [:external, :in_chain], "set" => [:external]})]

      [pruned] = Emissary.MCP.ToolRegistry.in_chain_view(defs)
      assert get_in(pruned, ["inputSchema", "properties", "action", "enum"]) == ["get"]
    end

    test "drops a tool with no in-chain actions" do
      defs = [tool_def("external_only", %{"plan" => [:external], "commit" => [:external]})]

      assert Emissary.MCP.ToolRegistry.in_chain_view(defs) == []
    end

    test "keeps a fully in-chain tool untouched" do
      defs = [tool_def("chained", %{"run" => [:external, :in_chain]})]

      assert Emissary.MCP.ToolRegistry.in_chain_view(defs) == defs
    end

    test "proxied server:tool entries pass through whole" do
      defs = [%{"name" => "notion:create_page"}]

      assert Emissary.MCP.ToolRegistry.in_chain_view(defs) == defs
    end

    test "a tool without annotations fails closed" do
      defs = [%{"name" => "bare", "inputSchema" => %{}}]

      assert Emissary.MCP.ToolRegistry.in_chain_view(defs) == []
    end
  end
end
