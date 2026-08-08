# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.FormulaHandlerMcpTest do
  @moduledoc """
  Tests for FormulaHandler's MCP dispatch functionality.
  (Previously McpHandler tests — now absorbed by FormulaHandler)

  Every dispatch runs under a chain authority: non-execution tools go
  through `ToolRegistry.call_in_chain/5`, where the grant is the consented
  edge's tool list — exact `tool.action` entries, deny-by-default.
  """
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Context

  @mcp_node "formula:local.mcp-root"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()

    test_dir = Path.join(System.tmp_dir!(), "formula_handler_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    # Ensure ToolRegistry has providers loaded for dispatch tests
    if Process.whereis(Emissary.MCP.ToolRegistry) do
      Emissary.MCP.ToolRegistry.refresh()
    end

    ctx = Sanctum.TestContext.local()
    execution_id = "exec_test_#{:rand.uniform(100_000)}"

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, execution_id: execution_id, test_dir: test_dir}
  end

  defp authority(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    blob_map = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @mcp_node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 100, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "5m"
          },
          "edges" => %{"@ingress" => %{"tools" => tools}}
        }
      }
    }

    {:ok, blob} = Blob.parse(blob_map)

    profile = %{
      profile_id: "prof-mcp",
      consent_id: "consent-mcp",
      source_ref: @mcp_node,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@mcp_node => "sha256:act-mcp"}
    }

    {:ok, auth} = Authority.root(profile, blob)
    auth
  end

  defp execute(json, ctx, eid, auth) do
    FormulaHandler.execute(json, Context.enter_guest(ctx),
      parent_execution_id: eid,
      authority: auth
    )
  end

  # ============================================================================
  # Request Parsing
  # ============================================================================

  describe "execute/3 - request parsing" do
    test "returns error for invalid JSON", %{ctx: ctx, execution_id: eid} do
      result = execute("not json", ctx, eid, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for missing tool field", %{ctx: ctx, execution_id: eid} do
      result = execute(~s({"action": "search"}), ctx, eid, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "tool"
    end

    test "returns error for missing action field", %{ctx: ctx, execution_id: eid} do
      result = execute(~s({"tool": "component"}), ctx, eid, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end
  end

  # ============================================================================
  # Tool grants — the consented edge's tool list
  # ============================================================================

  describe "execute/3 - tool grant enforcement" do
    test "denies a tool the edge does not grant", %{ctx: ctx, execution_id: eid} do
      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      result = execute(request, ctx, eid, authority(tools: ["storage.read"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Denied by chain authority"
      assert decoded["error"]["message"] =~ "component"
    end

    test "denies every tool when the edge grants none", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: []))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Denied by chain authority"
    end

    test "allows a granted tool action", %{ctx: ctx, execution_id: eid} do
      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      result = execute(request, ctx, eid, authority(tools: ["component.search"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  describe "execute/3 - telemetry" do
    test "emits telemetry event on tool call", %{ctx: ctx, execution_id: eid} do
      # Attach a telemetry handler to capture the event
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-mcp-tool-#{inspect(ref)}",
        [:cyfr, :opus, :mcp_tool, :call],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      _result = execute(request, ctx, eid, authority(tools: ["component.search"]))

      assert_receive {:telemetry_event, [:cyfr, :opus, :mcp_tool, :call], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.execution_id == eid
      assert metadata.tool_action == "component.search"
      assert metadata.status in [:ok, :error]

      :telemetry.detach("test-mcp-tool-#{inspect(ref)}")
    end

    test "emits telemetry with error status for denied tool", %{ctx: ctx, execution_id: eid} do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-mcp-denied-#{inspect(ref)}",
        [:cyfr, :opus, :mcp_tool, :call],
        fn _event_name, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_status, metadata.status})
        end,
        nil
      )

      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      _result = execute(request, ctx, eid, authority(tools: []))

      assert_receive {:telemetry_status, :error}

      :telemetry.detach("test-mcp-denied-#{inspect(ref)}")
    end
  end

  # ============================================================================
  # Dispatch via ToolRegistry
  # ============================================================================

  describe "execute/3 - dispatch via ToolRegistry" do
    test "webhook.list routes to the provider, whose identity conjunct still refuses", %{
      ctx: ctx,
      execution_id: eid
    } do
      # The edge grant clears the authority conjunct, but the dispatch
      # still carries the caller's identity: an identity without
      # :storage_read is refused by the provider itself. Reaching the
      # provider through the registry never bypasses the identity conjunct.
      restricted = %{ctx | permissions: MapSet.new([:execute])}
      request = Jason.encode!(%{"tool" => "webhook", "action" => "list", "args" => %{}})
      result = execute(request, restricted, eid, authority(tools: ["webhook.list"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "storage_read"
    end

    test "routes execution.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "execution", "action" => "list", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: ["execution.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end

    test "routes build.toolchains through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "build", "action" => "toolchains", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: ["build.toolchains"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
      assert is_map(decoded["output"]["toolchains"])
    end

    test "routes aqua.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "aqua", "action" => "list", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: ["aqua.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end

    test "routes tools.list through ToolRegistry", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "tools", "action" => "list", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: ["tools.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
      assert is_list(decoded["output"]["tools"])
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "execute/3 - unknown tool dispatch" do
    test "returns dispatch error for unknown tool", %{ctx: ctx, execution_id: eid} do
      request = Jason.encode!(%{"tool" => "unknown_service", "action" => "action", "args" => %{}})
      result = execute(request, ctx, eid, authority(tools: ["unknown_service.action"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Parent Execution ID Threading
  # ============================================================================

  describe "execute/3 - parent execution id threading" do
    test "threads parent_execution_id for execution.run calls", %{ctx: ctx, execution_id: eid} do
      # This will fail at the executor level (no such component), but the
      # invoke must get past the transition decision — never a denial.
      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run",
          "args" => %{"reference" => "reagent:test.nonexistent:0.1.0", "input" => %{}}
        })

      result = execute(request, ctx, eid, authority())
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end
  end
end
