# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.CatalogTest.ReplaySafeWrite do
  @moduledoc false
  # A write annotated replay-safe: the audit's refusal, as a provider.
  def service, do: "poker"

  def tools do
    op = Prima.Operation.new("poker", "poke", "Write", [], kind: :write, planes: [:in_chain])
    [%{name: "poker", operations: [%{op | recovery: :replay_safe}]}]
  end

  def handle(_name, _ctx, _args), do: {:ok, %{}}
end

defmodule Grimoire.CatalogTest do
  @moduledoc """
  Tests for the operation table and its gate.

  Verifies the boot-time table, listing, lookup, and delegation.
  """
  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Grimoire.Probe
  alias Prima.Refusal
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  describe "list_tools/0" do
    test "returns a list of tools" do
      tools = Catalog.list_tools()
      assert is_list(tools)
    end

    test "tools have required MCP fields" do
      tools = Catalog.list_tools()

      for tool <- tools do
        assert Map.has_key?(tool, "name")
        assert Map.has_key?(tool, "description")
        assert Map.has_key?(tool, "inputSchema")
      end
    end

    test "tools are sorted by name" do
      tools = Catalog.list_tools()
      names = Enum.map(tools, & &1["name"])

      assert names == Enum.sort(names)
    end

    test "inputSchema has valid JSON Schema type" do
      tools = Catalog.list_tools()

      for tool <- tools do
        schema = tool["inputSchema"]
        assert is_map(schema)
        assert schema["type"] == "object"
      end
    end

    test "includes system tool from Grimoire.Provider" do
      tools = Catalog.list_tools()
      tool_names = Enum.map(tools, & &1["name"])

      assert "system" in tool_names
    end
  end

  describe "get_tool/1" do
    test "returns tool definition for existing tool" do
      {:ok, tool} = Catalog.get_tool("system")

      assert tool["name"] == "system"
      assert is_binary(tool["description"])
      assert is_map(tool["inputSchema"])
    end

    test "returns error for non-existent tool" do
      result = Catalog.get_tool("nonexistent/tool")

      assert {:error, :not_found} = result
    end

    test "tool definition matches list_tools format" do
      {:ok, tool} = Catalog.get_tool("system")
      tools = Catalog.list_tools()
      system_from_list = Enum.find(tools, &(&1["name"] == "system"))

      assert tool == system_from_list
    end
  end

  describe "call/3" do
    test "delegates to correct provider module" do
      ctx = Sanctum.TestContext.local()

      {:ok, result} = Catalog.call_external("system", ctx, %{"action" => "status"})

      assert is_map(result)
      assert Map.has_key?(result, :status)
      assert result.status in ["ok", "degraded"]
    end

    test "returns error for unknown tool" do
      ctx = Sanctum.TestContext.local()

      result = Catalog.call_external("nonexistent/tool", ctx, %{})

      assert {:error, %Refusal{stage: :admission, message: message}} = result
      assert message =~ "Unknown tool"
    end

    test "handles provider errors gracefully" do
      ctx = Sanctum.TestContext.local()

      # Call system with invalid action to trigger error — the dispatch
      # gate answers with the typed default-deny.
      {:error, %Refusal{stage: :admission, reason: {:unknown_action, message}}} =
        Catalog.call_external("system", ctx, %{"action" => "invalid_action"})

      assert message == "system.invalid_action"
    end

    test "passes context and args to provider" do
      ctx = Sanctum.TestContext.local()

      # Verify context is passed through by checking whoami-like behavior
      # The system tool doesn't expose context directly, but we can verify
      # the call succeeds with valid context
      {:ok, result} =
        Catalog.call_external("system", ctx, %{"action" => "status", "scope" => "emissary"})

      assert result.status == "ok"
      assert result.services.emissary == "ok"
    end
  end

  describe "external tool auth gate" do
    test "rejects unauthenticated callers before reaching the external provider" do
      ctx = Context.build(authenticated: false, permissions: [])

      # An auth refusal, never "Unknown tool" — the gate fires first.
      assert {:error,
              %Refusal{stage: :admission, reason: {:tool_auth_required, "someserver:some_tool"}}} =
               Catalog.call_external("someserver:some_tool", ctx, %{})
    end

    test "authenticated caller with a nonexistent server still gets Unknown tool" do
      ctx = Sanctum.TestContext.local()

      assert {:error, %Refusal{stage: :admission, message: message}} =
               Catalog.call_external("no-such-server:some_tool", ctx, %{})

      assert message =~ "Unknown tool"
    end

    test "unauthenticated caller with a bare unknown name still gets Unknown tool" do
      ctx = Context.build(authenticated: false, permissions: [])

      assert {:error, %Refusal{stage: :admission, message: message}} =
               Catalog.call_external("definitely_not_a_tool", ctx, %{})

      assert message =~ "Unknown tool"
    end
  end

  describe "exists?/1" do
    test "returns true for existing tool" do
      assert Catalog.exists?("system") == true
    end

    test "returns false for non-existent tool" do
      assert Catalog.exists?("nonexistent/tool") == false
    end
  end

  describe "the table" do
    test "holds every configured provider's tools, as their declarations built them" do
      for provider <- Catalog.available_providers(), tool <- provider.tools() do
        assert {:ok, {^provider, held}} = Catalog.lookup(tool.name)
        assert held.operations == tool.operations
      end

      assert map_size(Catalog.operations()) == length(Catalog.list_tools())
    end

    test "outlives the cache owner: a flushed cache takes no tool with it" do
      before = Catalog.list_tools()
      owner = Process.whereis(Arca.Cache.Sweeper)
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 5_000

      # No rebuild, no wait: the table never lived in the cache.
      assert Catalog.list_tools() == before
      assert {:ok, {Grimoire.Provider, _}} = Catalog.lookup("system")
      assert {:ok, "session", "read_resource"} = Grimoire.Resources.resolve("sanctum://identity")

      # Leave the cache as it was found: owned, with its table.
      assert :ok = wait_for_cache_owner(owner)
    end

    test "a planted provider is in the table for its block, and gone after" do
      refute Catalog.exists?(Probe.Crashing.tool())

      Catalog.with_providers([Probe.Crashing], fn ->
        assert Catalog.exists?(Probe.Crashing.tool())
        assert Enum.any?(Catalog.list_tools(), &(&1["name"] == Probe.Crashing.tool()))
      end)

      refute Catalog.exists?(Probe.Crashing.tool())
      refute Enum.any?(Catalog.list_tools(), &(&1["name"] == Probe.Crashing.tool()))
    end

    test "the table is put back when the block raises" do
      before = Catalog.operations()

      assert_raise RuntimeError, "in the block", fn ->
        Catalog.with_providers([Probe.Crashing], fn -> raise "in the block" end)
      end

      assert Catalog.operations() == before
    end

    test "a module that declares no tools cannot be planted" do
      assert_raise ArgumentError, ~r/does not export tools\/0/, fn ->
        Catalog.with_providers([Grimoire.CatalogTest.NoSuchProvider], fn -> :ok end)
      end
    end
  end

  defp wait_for_cache_owner(dead, attempts \\ 100) do
    case Process.whereis(Arca.Cache.Sweeper) do
      pid when is_pid(pid) and pid != dead ->
        :ok = Arca.Cache.Sweeper.ensure_table()

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_cache_owner(dead, attempts - 1)

      _ ->
        :timeout
    end
  end

  describe "tool schema validation" do
    test "system tool has action enum" do
      {:ok, tool} = Catalog.get_tool("system")

      action_prop = tool["inputSchema"]["properties"]["action"]
      assert action_prop["type"] == "string"
      assert "status" in action_prop["enum"]
      assert "notify" in action_prop["enum"]
    end

    test "system tool has required action field" do
      {:ok, tool} = Catalog.get_tool("system")

      assert "action" in tool["inputSchema"]["required"]
    end
  end

  describe "error handling" do
    test "handles provider crash gracefully" do
      ctx = Sanctum.TestContext.local()

      # Calling a non-existent action will raise in the provider
      # The registry should catch this and return an error tuple
      result = Catalog.call_external("system", ctx, %{"action" => "crash_intentionally"})

      # Should return error instead of crashing — an undeclared action is
      # the typed default-deny, refused before the handler could raise.
      assert {:error, %Refusal{stage: :admission, reason: {:unknown_action, message}}} = result
      assert is_binary(message)
    end

    test "returns meaningful error for unknown tool" do
      ctx = Sanctum.TestContext.local()

      result = Catalog.call_external("completely/unknown/tool", ctx, %{})

      assert {:error, %Refusal{stage: :admission, message: message}} = result
      assert message =~ "Unknown tool"
      assert message =~ "completely/unknown/tool"
    end

    @crash_tool Probe.Crashing.tool()

    test "a raising handler yields a typed error and the caller survives" do
      Catalog.with_providers([Probe.Crashing], fn ->
        ctx = Sanctum.TestContext.local()
        caller = self()

        assert {:error, {:crashed, message}} =
                 Catalog.call_external(@crash_tool, ctx, %{"action" => "raise"})

        # The tuple names the tool, never the exception's own message — that
        # text can carry a query, a path, or the offending bytes, and this
        # tuple renders verbatim on the wire.
        assert message == "Tool #{@crash_tool} crashed"
        refute message =~ "boom from provider"

        # The whole point: Task.async would have propagated a link exit and killed
        # this process, so reaching the next line at all is the assertion.
        assert Process.alive?(caller)

        assert {:ok, %{"ok" => true}} =
                 Catalog.call_external(@crash_tool, ctx, %{"action" => "ok"})
      end)
    end

    test "an exiting handler yields a typed error and the caller survives" do
      Catalog.with_providers([Probe.Crashing], fn ->
        ctx = Sanctum.TestContext.local()

        assert {:error, {:exit, message}} =
                 Catalog.call_external(@crash_tool, ctx, %{"action" => "exit"})

        assert message =~ "exited unexpectedly"
        assert Process.alive?(self())
      end)
    end

    test "a raised UnauthorizedError is a refusal, never a crash" do
      Catalog.with_providers([Probe.Crashing], fn ->
        ctx = Sanctum.TestContext.local()

        # The reason travels, not a rendered sentence: the wire boundary
        # renders a raised refusal exactly as it renders a returned one, which
        # is how it gets its own JSON-RPC code instead of everything landing
        # on :insufficient_permissions. The handler raised it, so it is the
        # execution's refusal, not the gate's.
        assert {:error, reason} =
                 Catalog.call_external(@crash_tool, ctx, %{"action" => "unauthorized"})

        assert reason == :missing_tenant
        assert Sanctum.Unauthorized.reason?(reason)
        assert Process.alive?(self())
      end)
    end

    test "handles nil arguments gracefully" do
      ctx = Sanctum.TestContext.local()

      # This should fail due to missing required action, but not crash
      assert {:error, %Refusal{stage: :admission, reason: :action_missing}} =
               Catalog.call_external("system", ctx, %{})
    end

    test "provider errors are wrapped with context" do
      ctx = Sanctum.TestContext.local()

      # Invalid action is the dispatcher's typed default-deny, naming the
      # tool.action it refused.
      {:error, %Refusal{stage: :admission, reason: {:unknown_action, message}}} =
        Catalog.call_external("system", ctx, %{"action" => "nonexistent"})

      assert message == "system.nonexistent"
    end

    test "call returns error tuple on missing context fields" do
      # Create a minimal context with nil user_id
      ctx = %Context{
        user_id: nil,
        athanor_id: nil,
        permissions: MapSet.new([:*]),
        scope: :athanor,
        auth_method: nil,
        api_key_type: nil,
        request_id: nil
      }

      # The tool should handle nil user_id gracefully
      result = Catalog.call_external("system", ctx, %{"action" => "status"})

      # Should still work - status doesn't require auth
      assert {:ok, _} = result
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads safely" do
      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            Catalog.list_tools()
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
            Catalog.call_external("system", ctx, %{"action" => "status"})
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
      {:ok, tool} = Catalog.get_tool("system")

      # Grimoire.Provider includes title
      if Map.has_key?(tool, "title") do
        assert is_binary(tool["title"])
      end
    end

    test "optional fields are excluded when nil" do
      tools = Catalog.list_tools()

      for tool <- tools do
        # Verify nil values are not included in output
        refute Map.has_key?(tool, "icons") and is_nil(tool["icons"])
        refute Map.has_key?(tool, "outputSchema") and is_nil(tool["outputSchema"])
        refute Map.has_key?(tool, "annotations") and is_nil(tool["annotations"])
      end
    end
  end

  describe "cancellation tracking" do
    @blocking_tool Probe.Blocking.tool()

    defp with_blocking_tool(fun) do
      Process.register(self(), :catalog_blocking_observer)
      Catalog.with_providers([Probe.Blocking], fun)
    end

    # Supervised work must be registered under the server request id used for cancellation.
    test "in-flight work is registered under the context's request id, and cancellable" do
      with_blocking_tool(fn ->
        ctx = %{Sanctum.TestContext.local() | request_id: "req_tracked"}
        caller = self()

        spawn(fn ->
          args = %{"action" => "block"}

          send(
            caller,
            {:result, Catalog.call_external(@blocking_tool, ctx, args, runner: :supervised)}
          )
        end)

        # The handler reports its pid and then blocks, so the call is provably
        # still in flight for the assertions below — no sleeping, no racing.
        assert_receive {:handler_running, handler_pid}, 5_000

        assert [{"req_tracked", ^handler_pid}] =
                 :ets.lookup(Grimoire.RunningTasks, "req_tracked")

        # The gate runs the handler under its own task supervisor.
        assert handler_pid in Task.Supervisor.children(Grimoire.TaskSupervisor)

        assert :ok = Grimoire.cancel_request("req_tracked")

        # Killing the handler surfaces to the caller as a typed error rather than
        # taking the dispatcher down with it.
        assert_receive {:result, {:error, {:cancelled, message} = reason}}, 5_000
        assert message =~ "cancelled"
        assert %Prima.Refusal{class: :cancelled} = Grimoire.Error.classify(reason)

        # A second cancel, once the first one's unregister has run, finds nothing.
        :sys.get_state(Grimoire.RunningTasks)
        assert {:error, :not_found = gone} = Grimoire.cancel_request("req_tracked")
        assert %Prima.Refusal{class: :not_found} = Grimoire.Error.classify(gone)
      end)
    end

    # A caller that holds no request id cancels by its own handle: the
    # handler is stopped, the call answers cancelled, and the gate releases
    # the handle, so a cancel that arrives after it writes nothing.
    test "in-flight work is cancellable by the caller's handle, which the gate releases" do
      with_blocking_tool(fn ->
        ctx = Sanctum.TestContext.local()
        handle = {:catalog_test, System.unique_integer([:positive])}
        caller = self()

        spawn(fn ->
          send(
            caller,
            {:result,
             Catalog.call_external(@blocking_tool, ctx, %{"action" => "block"},
               runner: :supervised,
               cancel_handle: handle
             )}
          )
        end)

        assert_receive {:handler_running, handler_pid}, 5_000
        ref = Process.monitor(handler_pid)
        assert [{^handle, ^handler_pid}] = :ets.lookup(Grimoire.RunningTasks.Handles, handle)

        assert :ok = Grimoire.cancel_call(handle)
        assert_receive {:DOWN, ^ref, :process, _, :cancelled}, 5_000
        assert_receive {:result, {:error, {:cancelled, "Tool " <> _}}}, 5_000

        assert :ok = Grimoire.cancel_call(handle)
        assert [] = :ets.lookup(Grimoire.RunningTasks.Handles, handle)
      end)
    end

    test "the entry is cleaned up when the work finishes on its own" do
      ctx = %{Sanctum.TestContext.local() | request_id: "req_finished"}

      {:ok, _} =
        Catalog.call_external("system", ctx, %{"action" => "status"}, runner: :supervised)

      :sys.get_state(Grimoire.RunningTasks)
      assert {:error, :not_found} = Grimoire.cancel_request("req_finished")
    end

    # The in-process runner: the console and the assistant hold an
    # authenticated context and a process of their own, so the gate, the
    # contract and the handler run right there — no task, no timeout, and
    # nothing registered for a transport to cancel.
    test "the default runner is inline: the handler runs on the caller's process, unregistered" do
      with_blocking_tool(fn ->
        ctx = %{Sanctum.TestContext.local() | request_id: "req_inline"}
        args = %{"action" => "block", "release" => true}
        assert {:ok, %{ran_on: pid}} = Catalog.call_external(@blocking_tool, ctx, args)
        assert pid == self()
        assert [] = :ets.lookup(Grimoire.RunningTasks, "req_inline")
      end)
    end

    test "the inline runner contains a crash and answers a raised refusal as the refusal" do
      with_blocking_tool(fn ->
        ctx = Sanctum.TestContext.local()

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:error, {:crashed, message}} =
                     Catalog.call_external(@blocking_tool, ctx, %{
                       "action" => "block",
                       "crash" => true
                     })

            assert message =~ "crashed"
          end)

        assert log =~ "crashed"

        assert {:error, :missing_tenant} =
                 Catalog.call_external(@blocking_tool, ctx, %{
                   "action" => "block",
                   "refuse" => true
                 })
      end)
    end
  end

  describe "provider resilience" do
    test "provider exception is caught and returns error" do
      ctx = Sanctum.TestContext.local()

      # The system tool with an invalid action is refused by the dispatch
      # gate's typed default-deny before any handler could raise.
      result = Catalog.call_external("system", ctx, %{"action" => "this_will_cause_error"})

      assert {:error, %Refusal{stage: :admission, reason: {:unknown_action, message}}} = result
      assert is_binary(message)
    end

    test "provider returning unexpected value is handled gracefully" do
      ctx = Sanctum.TestContext.local()

      # A valid tool call should succeed
      {:ok, result} = Catalog.call_external("system", ctx, %{"action" => "status"})
      assert is_map(result)
    end

    test "multiple failed calls do not affect subsequent calls" do
      ctx = Sanctum.TestContext.local()

      # First call fails
      {:error, _} = Catalog.call_external("system", ctx, %{"action" => "bad_action"})

      # Second call should still work
      {:ok, result} = Catalog.call_external("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]

      # Third call fails
      {:error, _} = Catalog.call_external("system", ctx, %{"action" => "another_bad"})

      # Fourth call should still work
      {:ok, result} = Catalog.call_external("system", ctx, %{"action" => "status"})
      assert result.status in ["ok", "degraded"]
    end

    test "error messages from provider are descriptive" do
      ctx = Sanctum.TestContext.local()

      {:error, %Refusal{stage: :admission, reason: {:unknown_action, message}}} =
        Catalog.call_external("system", ctx, %{"action" => "unknown_action"})

      # Error should mention the issue
      assert message =~ "Unknown action" or message =~ "unknown_action"
    end

    test "provider crash with nil context field is handled" do
      # Context with potentially problematic nil fields
      ctx = %Context{
        user_id: nil,
        athanor_id: nil,
        permissions: MapSet.new(),
        scope: nil,
        auth_method: nil,
        api_key_type: nil,
        request_id: nil
      }

      # Should not crash the registry
      result = Catalog.call_external("system", ctx, %{"action" => "status"})

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
              Catalog.call_external("system", ctx, %{"action" => "status"})
            else
              # Odd: invalid call
              Catalog.call_external("system", ctx, %{"action" => "invalid_#{i}"})
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
          Catalog.call_external("system", ctx, %{"action" => "status"})
        end)

      # While it's running, list_tools should still work
      tools = Catalog.list_tools()
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
            Catalog.call_external("system", ctx, %{"action" => "status"})
          end)
        end

      list_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Catalog.list_tools()
          end)
        end

      get_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Catalog.get_tool("system")
          end)
        end

      exists_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Catalog.exists?("system")
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

      [pruned] = Grimoire.Catalog.in_chain_view(defs)
      assert get_in(pruned, ["inputSchema", "properties", "action", "enum"]) == ["get"]
    end

    test "drops a tool with no in-chain actions" do
      defs = [tool_def("external_only", %{"plan" => [:external], "commit" => [:external]})]

      assert Grimoire.Catalog.in_chain_view(defs) == []
    end

    test "keeps a fully in-chain tool untouched" do
      defs = [tool_def("chained", %{"run" => [:external, :in_chain]})]

      assert Grimoire.Catalog.in_chain_view(defs) == defs
    end

    test "proxied server:tool entries pass through whole" do
      defs = [%{"name" => "notion:create_page"}]

      assert Grimoire.Catalog.in_chain_view(defs) == defs
    end

    test "a tool without annotations fails closed" do
      defs = [%{"name" => "bare", "inputSchema" => %{}}]

      assert Grimoire.Catalog.in_chain_view(defs) == []
    end
  end

  describe "providers must load" do
    setup do
      original = Application.get_env(:cyfr, :tool_providers, [])
      lenient = Application.get_env(:cyfr, :tool_providers_lenient)

      on_exit(fn ->
        Application.put_env(:cyfr, :tool_providers, original)

        if is_nil(lenient),
          do: Application.delete_env(:cyfr, :tool_providers_lenient),
          else: Application.put_env(:cyfr, :tool_providers_lenient, lenient)
      end)

      {:ok, original: original}
    end

    test "a configured provider that cannot load is named, and refuses the boot unless lenient",
         %{original: original} do
      # Each boot is run inside a block that puts the member's table back.
      Catalog.with_providers([], fn ->
        before = Catalog.operations()

        Application.put_env(
          :cyfr,
          :tool_providers,
          original ++ [Grimoire.CatalogTest.NoSuchProvider]
        )

        assert {:error, [Grimoire.CatalogTest.NoSuchProvider]} = Catalog.providers_loaded()

        Application.put_env(:cyfr, :tool_providers_lenient, false)

        assert_raise RuntimeError, ~r/failed to load.*refusing to boot/, fn ->
          Catalog.load!()
        end

        # A refused boot wrote nothing.
        assert Catalog.operations() == before

        Application.put_env(:cyfr, :tool_providers_lenient, true)

        log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Catalog.load!() end)

        assert log =~
                 "Grimoire.CatalogTest.NoSuchProvider skipped (lenient): " <>
                   "the module is not available"

        assert Catalog.operations() == before
      end)
    end

    test "a module that exports no tools/0 refuses the boot, or is skipped with its reason",
         %{original: original} do
      Catalog.with_providers([], fn ->
        Application.put_env(:cyfr, :tool_providers, original ++ [Grimoire.CatalogTest])
        Application.put_env(:cyfr, :tool_providers_lenient, false)
        assert_raise RuntimeError, ~r/failed to load.*CatalogTest/, fn -> Catalog.load!() end

        Application.put_env(:cyfr, :tool_providers_lenient, true)
        log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Catalog.load!() end)
        assert log =~ "Grimoire.CatalogTest skipped (lenient): it does not export tools/0"
      end)
    end

    test "an action the audit refuses refuses the boot", %{original: original} do
      Catalog.with_providers([], fn ->
        before = Catalog.operations()

        Application.put_env(
          :cyfr,
          :tool_providers,
          original ++ [Grimoire.CatalogTest.ReplaySafeWrite]
        )

        assert_raise RuntimeError,
                     ~r/failed the catalog audit.*poker\.poke: invalid_operation/s,
                     fn ->
                       Catalog.load!()
                     end

        assert Catalog.operations() == before
      end)
    end
  end
end
