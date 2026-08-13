# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCPTest do
  @moduledoc """
  Tests for the internal MCP API (direct Elixir calls).

  These tests verify that MCP functionality works without HTTP transport,
  enabling internal usage from Prism/LiveView components.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()
    :ok
  end

  describe "handle_message/2 - request processing" do
    setup do
      ctx = Sanctum.TestContext.local()
      {:ok, ctx: ctx}
    end

    test "handles tools/list request", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      }

      {:ok, result, 1} = MCP.handle_message(ctx, params)

      assert is_list(result["tools"])
      tool_names = Enum.map(result["tools"], & &1["name"])
      assert "system" in tool_names
    end

    test "handles tools/call request", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      {:ok, result, 2} = MCP.handle_message(ctx, params)

      assert result["content"]
      [content] = result["content"]
      assert content["type"] == "text"

      decoded = Jason.decode!(content["text"])
      # Status may be "ok" or "degraded" depending on which services are available
      assert decoded["status"] in ["ok", "degraded"]
    end

    # `ping` was removed in 2026-07-28. It is not merely unimplemented — a server
    # that still answers it tells a client the wrong thing about which revision
    # it speaks, so the rejection is the correct behaviour and worth pinning.
    test "ping is gone", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "ping"
      }

      assert {:error, :method_not_found, message, 3} = MCP.handle_message(ctx, params)
      assert message =~ "ping"
    end

    test "handles resources/list request", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "resources/list"
      }

      {:ok, result, 4} = MCP.handle_message(ctx, params)
      assert is_list(result["resources"])
    end

    test "returns error for unknown method", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "unknown/method"
      }

      {:error, :method_not_found, message, 5} = MCP.handle_message(ctx, params)
      assert message =~ "Unknown method"
    end

    test "returns error for invalid JSON-RPC", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "1.0",
        "id" => 6,
        "method" => "tools/list"
      }

      {:error, :invalid_request, message} = MCP.handle_message(ctx, params)
      assert message =~ "jsonrpc version"
    end
  end

  describe "handle_message/2 - notification processing" do
    setup do
      ctx = Sanctum.TestContext.local()
      {:ok, ctx: ctx}
    end

    test "handles notifications/cancelled", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 123}
      }

      result = MCP.handle_message(ctx, params)
      assert result == :ok
    end

    test "unknown notifications return :ok", %{ctx: ctx} do
      params = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/unknown"
      }

      result = MCP.handle_message(ctx, params)
      assert result == :ok
    end
  end
end
