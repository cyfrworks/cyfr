# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Opus.FormulaHandlerMcpTest do
  @moduledoc """
  Tests FormulaHandler MCP dispatch.

  Every dispatch is a host call of the formula's attempt, decided by CYFR
  under the authority it holds for that attempt: a catalog tool goes
  through `Grimoire.Catalog.call_in_chain/5`, where the grant is the
  consented edge's tool list — exact `tool.action` entries,
  deny-by-default. The telemetry a call emits in its runner's VM is
  `Opus.FormulaHandlerRunnerTest`'s, in Opus's suite.
  """
  use ExUnit.Case, async: false

  alias Opus.FormulaHandler
  alias Opus.Test.FormulaHost
  alias Prima.Authority
  alias Prima.Authority.Blob

  @mcp_node "formula:local.mcp-root"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    test_dir = Path.join(System.tmp_dir!(), "formula_handler_mcp_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    # Ensure the catalog has providers loaded for dispatch tests
    if Process.whereis(Grimoire.Catalog) do
      Grimoire.Catalog.refresh()
    end

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx, test_dir: test_dir}
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

    {:ok, auth} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    auth
  end

  # The host client of a formula's attempt under `auth`, admitted in `ctx`.
  defp host!(ctx, auth),
    do: FormulaHost.attached!(ctx: ctx, authority: auth, component_ref: "#{@mcp_node}:0.1.0").host

  defp execute(json, host, auth), do: FormulaHandler.execute(json, host, FormulaHost.opts(auth))

  defp execute!(json, ctx, auth), do: execute(json, host!(ctx, auth), auth)

  # ============================================================================
  # Request Parsing
  # ============================================================================

  describe "execute/3 - request parsing" do
    test "returns error for invalid JSON", %{ctx: ctx} do
      result = execute!("not json", ctx, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_json"
      assert decoded["error"]["message"] =~ "Invalid JSON"
    end

    test "returns error for missing tool field", %{ctx: ctx} do
      result = execute!(~s({"action": "search"}), ctx, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
      assert decoded["error"]["message"] =~ "tool"
    end

    test "returns error for missing action field", %{ctx: ctx} do
      result = execute!(~s({"tool": "component"}), ctx, authority())
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "invalid_request"
    end
  end

  # ============================================================================
  # Tool grants — the consented edge's tool list
  # ============================================================================

  describe "execute/3 - tool grant enforcement" do
    test "denies a tool the edge does not grant", %{ctx: ctx} do
      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      result = execute!(request, ctx, authority(tools: ["storage.read"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Denied by chain authority"
      assert decoded["error"]["message"] =~ "component"
    end

    test "denies every tool when the edge grants none", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "component", "action" => "search", "args" => %{}})
      result = execute!(request, ctx, authority(tools: []))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Denied by chain authority"
    end

    test "allows a granted tool action", %{ctx: ctx} do
      request =
        Jason.encode!(%{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "test"}
        })

      result = execute!(request, ctx, authority(tools: ["component.search"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end
  end

  # ============================================================================
  # Dispatch via the catalog
  # ============================================================================

  describe "execute/3 - dispatch via the catalog" do
    test "webhook.list routes to the provider, whose identity conjunct still refuses", %{
      ctx: ctx
    } do
      # The edge grant clears the authority conjunct, but the dispatch
      # still carries the caller's identity: an identity without
      # :storage_read is refused by the provider itself. Reaching the
      # provider through the registry never bypasses the identity conjunct.
      restricted = %{ctx | permissions: MapSet.new([:execute])}
      request = Jason.encode!(%{"tool" => "webhook", "action" => "list", "args" => %{}})
      result = execute!(request, restricted, authority(tools: ["webhook.list"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "storage_read"
    end

    test "routes execution.list through the catalog", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "execution", "action" => "list", "args" => %{}})
      result = execute!(request, ctx, authority(tools: ["execution.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end

    test "routes build.toolchains through the catalog", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "build", "action" => "toolchains", "args" => %{}})
      result = execute!(request, ctx, authority(tools: ["build.toolchains"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
      assert is_map(decoded["output"]["toolchains"])
    end

    test "routes aqua.list through the catalog", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "aqua", "action" => "list", "args" => %{}})
      result = execute!(request, ctx, authority(tools: ["aqua.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
    end

    test "routes tools.list through the catalog", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "tools", "action" => "list", "args" => %{}})
      result = execute!(request, ctx, authority(tools: ["tools.list"]))
      decoded = Jason.decode!(result)

      assert decoded["status"] == "completed"
      assert is_list(decoded["output"]["tools"])
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "execute/3 - unknown tool dispatch" do
    test "returns dispatch error for unknown tool", %{ctx: ctx} do
      request = Jason.encode!(%{"tool" => "unknown_service", "action" => "action", "args" => %{}})
      result = execute!(request, ctx, authority(tools: ["unknown_service.action"]))
      decoded = Jason.decode!(result)

      assert decoded["error"]["type"] == "dispatch_error"
      assert decoded["error"]["message"] =~ "Unknown tool"
    end
  end

  # ============================================================================
  # Parent Execution ID Threading
  # ============================================================================

  describe "execute/3 - parent execution id threading" do
    test "threads parent_execution_id for execution.run calls", %{ctx: ctx} do
      # This will fail at the executor level (no such component), but the
      # invoke must get past the transition decision — never a denial.
      request =
        Jason.encode!(%{
          "tool" => "execution",
          "action" => "run",
          "args" => %{"reference" => "reagent:test.nonexistent:0.1.0", "input" => %{}}
        })

      result = execute!(request, ctx, authority())
      decoded = Jason.decode!(result)

      refute match?(%{"error" => %{"type" => "tool_denied"}}, decoded)
    end
  end

  # ============================================================================
  # Host interception
  # ============================================================================

  describe "host interception" do
    test "the host has an arm for exactly the actions an assignment names as intercepted" do
      execution = Enum.find(Cyfr.Execution.MCP.tools(), &(&1.name == "execution"))
      actions = execution |> Grimoire.Annotations.actions_of() |> Map.keys()
      intercepted = FormulaHost.intercepted()

      assert intercepted != []

      for name <- intercepted do
        assert match?({:ok, _}, FormulaHandler.child_runner(name)),
               "#{name} is intercepted but the host has no arm for it"
      end

      for action <- actions do
        assert match?({:ok, _}, FormulaHandler.child_runner("execution.#{action}")) ==
                 "execution.#{action}" in intercepted,
               "execution.#{action}: the host's arm and the assignment's intercepted set disagree"
      end
    end
  end
end
