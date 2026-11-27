# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/formula_host_helper.exs", __DIR__)

defmodule Cyfr.FormulaCatalogCallsTest do
  @moduledoc """
  What CYFR answers a formula's catalog tool calls.

  Every dispatch is a host call of the formula's attempt (`tool_call`),
  decided by CYFR under the authority it holds for that attempt: a catalog
  tool goes through `Sanctum.Gate.call_in_chain/5`, where the grant is the
  consented edge's tool list — exact `tool.action` entries,
  deny-by-default.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.FormulaHost
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

    ctx = Sanctum.TestContext.local(:api)

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

  # A formula's attempt under `auth`, admitted in `ctx`.
  defp host!(ctx, auth),
    do: FormulaHost.attached!(ctx: ctx, authority: auth, component_ref: "#{@mcp_node}:0.1.0")

  # CYFR's answer to the catalog call `tool.action` with `args` of a
  # formula's attempt admitted in `ctx` under `auth`.
  defp call!(ctx, auth, tool, action, args \\ %{}),
    do: FormulaHost.tool_call(host!(ctx, auth), tool, action, args)

  # ============================================================================
  # Tool grants — the consented edge's tool list
  # ============================================================================

  describe "tool grant enforcement" do
    test "denies a tool the edge does not grant", %{ctx: ctx} do
      # The table's sentence for the rostered denial (`{:invoke_denied,
      # :tool_not_granted}`), which says why in the authority's own words.
      assert {:error, "guest_error",
              %{
                "type" => "dispatch_error",
                "message" => "Denied by chain authority: tool not granted on this node's consent"
              }} =
               call!(ctx, authority(tools: ["storage.read"]), "component", "search", %{
                 "query" => "test"
               })
    end

    test "denies every tool when the edge grants none", %{ctx: ctx} do
      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               call!(ctx, authority(tools: []), "component", "search")

      assert message =~ "Denied by chain authority"
    end

    test "allows a granted tool action", %{ctx: ctx} do
      assert {:ok, _output} =
               call!(ctx, authority(tools: ["component.search"]), "component", "search", %{
                 "query" => "test"
               })
    end
  end

  # ============================================================================
  # Dispatch via the catalog
  # ============================================================================

  describe "dispatch via the catalog" do
    test "webhook.list routes to the provider, whose identity conjunct still refuses", %{
      ctx: ctx
    } do
      # The edge grant clears the authority conjunct, but the dispatch
      # still carries the caller's identity: an identity without
      # :storage_read is refused by the provider itself. Reaching the
      # provider through the registry never bypasses the identity conjunct.
      restricted = %{ctx | permissions: MapSet.new([:execute])}

      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               call!(restricted, authority(tools: ["webhook.list"]), "webhook", "list")

      assert message =~ "storage_read"
    end

    test "routes execution.list through the catalog", %{ctx: ctx} do
      assert {:ok, _output} =
               call!(ctx, authority(tools: ["execution.list"]), "execution", "list")
    end

    test "routes build.toolchains through the catalog", %{ctx: ctx} do
      assert {:ok, %{"toolchains" => toolchains}} =
               call!(ctx, authority(tools: ["build.toolchains"]), "build", "toolchains")

      assert is_map(toolchains)
    end

    test "routes aqua.list through the catalog", %{ctx: ctx} do
      assert {:ok, _output} = call!(ctx, authority(tools: ["aqua.list"]), "aqua", "list")
    end

    test "routes tools.list through the catalog", %{ctx: ctx} do
      assert {:ok, %{"tools" => tools}} =
               call!(ctx, authority(tools: ["tools.list"]), "tools", "list")

      assert is_list(tools)
    end
  end

  # ============================================================================
  # Unknown Tool
  # ============================================================================

  describe "unknown tool dispatch" do
    test "returns dispatch error for unknown tool", %{ctx: ctx} do
      assert {:error, "guest_error", %{"type" => "dispatch_error", "message" => message}} =
               call!(
                 ctx,
                 authority(tools: ["unknown_service.action"]),
                 "unknown_service",
                 "action"
               )

      assert message =~ "Unknown tool"
    end
  end

  # ============================================================================
  # A child's admission
  # ============================================================================

  describe "a child's admission" do
    test "an off-edge child under open_inert gets past the transition decision", %{ctx: ctx} do
      # This fails at the executor level (no such component), but the
      # invoke must get past the transition decision — never a denial.
      assert {:error, "guest_error", %{"type" => type}} =
               FormulaHost.admit_child(
                 host!(ctx, authority()),
                 "reagent:test.nonexistent:0.1.0",
                 "call"
               )

      refute type == "tool_denied"
    end
  end
end
