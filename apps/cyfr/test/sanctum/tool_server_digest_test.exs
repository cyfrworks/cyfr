# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigestTest do
  use ExUnit.Case, async: true

  alias Sanctum.ToolServerDigest

  @base %{
    id: "mcp_row_1",
    transport: "http",
    url: "https://mcp.example/sse",
    enabled: true,
    headers: %{"authorization" => "vault:GH_TOKEN", "user-agent" => "cyfr"},
    backends: [],
    tool_patterns: ["*"]
  }

  @stdio %{
    @base
    | transport: "stdio",
      url: nil,
      headers: %{},
      backends: [
        %{
          "name" => "github",
          "command" => "npx -y @modelcontextprotocol/server-github",
          "env" => %{"GITHUB_TOKEN" => "vault:gh", "NODE_ENV" => "production"}
        }
      ]
  }

  describe "compute/1" do
    test "is stable across header ordering" do
      {:ok, a} = ToolServerDigest.compute(@base)

      {:ok, b} =
        ToolServerDigest.compute(%{
          @base
          | headers: %{"user-agent" => "cyfr", "authorization" => "vault:GH_TOKEN"}
        })

      assert a == b
    end

    test "every config axis moves the digest" do
      {:ok, base} = ToolServerDigest.compute(@base)

      variants = [
        %{@base | id: "mcp_row_2"},
        %{@base | url: "https://evil.example/sse"},
        %{@base | enabled: false},
        %{@base | headers: %{"authorization" => "vault:OTHER_TOKEN"}},
        %{@base | tool_patterns: ["issues.*"]},
        %{@base | transport: "stdio", url: nil}
      ]

      for variant <- variants do
        {:ok, digest} = ToolServerDigest.compute(variant)
        refute digest == base
      end
    end

    test "every backend axis of a stdio server moves the digest, and its env order does not" do
      {:ok, base} = ToolServerDigest.compute(@stdio)
      [backend] = @stdio.backends

      variants = [
        [%{backend | "command" => "npx -y @modelcontextprotocol/server-github@2"}],
        [%{backend | "name" => "gh"}],
        [put_in(backend, ["env", "GITHUB_TOKEN"], "vault:other")],
        [backend, %{"name" => "fs", "command" => "npx -y fs", "env" => %{}}]
      ]

      for backends <- variants do
        {:ok, digest} = ToolServerDigest.compute(%{@stdio | backends: backends})
        refute digest == base, inspect(backends)
      end

      reordered = %{
        backend
        | "env" => %{"NODE_ENV" => "production", "GITHUB_TOKEN" => "vault:gh"}
      }

      assert {:ok, ^base} = ToolServerDigest.compute(%{@stdio | backends: [reordered]})
    end

    test "distinct servers never share a digest" do
      {:ok, a} = ToolServerDigest.compute(@base)
      {:ok, b} = ToolServerDigest.compute(%{@base | url: "https://other.example/sse"})
      refute a == b
    end
  end

  describe "from_server/1 + tool_patterns/1" do
    test "derives from a stored row shape" do
      server = %{
        id: "mcp_row_1",
        transport: "http",
        url: "https://mcp.example/sse",
        enabled: true,
        config_json:
          Jason.encode!(%{
            "headers" => %{"authorization" => "vault:GH_TOKEN", "user-agent" => "cyfr"},
            "timeout_ms" => 30_000,
            "tool_patterns" => ["*"]
          })
      }

      assert {:ok, digest} = ToolServerDigest.from_server(server)
      assert {:ok, ^digest} = ToolServerDigest.compute(@base)
    end

    test "timeout_ms is process identity, not consent identity" do
      row = fn timeout ->
        %{
          id: "mcp_row_1",
          transport: "http",
          url: "https://mcp.example/sse",
          enabled: true,
          config_json: Jason.encode!(%{"headers" => %{}, "timeout_ms" => timeout})
        }
      end

      {:ok, a} = ToolServerDigest.from_server(row.(30_000))
      {:ok, b} = ToolServerDigest.from_server(row.(60_000))
      assert a == b
    end

    test "absent patterns expose everything; a present list is an allowlist" do
      absent = %{url: "https://x", enabled: true, config_json: Jason.encode!(%{})}
      assert ToolServerDigest.tool_patterns(absent) == ["*"]

      narrowed = %{
        url: "https://x",
        enabled: true,
        config_json: Jason.encode!(%{"tool_patterns" => ["issues.*", "repo_get"]})
      }

      assert ToolServerDigest.tool_patterns(narrowed) == ["issues.*", "repo_get"]

      # Invalid entries drop; an all-invalid list exposes NOTHING rather
      # than widening back to *.
      corrupt = %{
        url: "https://x",
        enabled: true,
        config_json: Jason.encode!(%{"tool_patterns" => ["read*", "a*b"]})
      }

      assert ToolServerDigest.tool_patterns(corrupt) == []
    end
  end
end
