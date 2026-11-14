# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ToolServerDigestTest do
  use ExUnit.Case, async: true

  alias Sanctum.ToolServerDigest

  @base %{
    id: "mcp_row_1",
    transport: "http",
    mark: nil,
    url: "https://mcp.example/sse",
    enabled: true,
    headers: %{"authorization" => "vault:GH_TOKEN", "user-agent" => "cyfr"},
    backends: [],
    tool_patterns: ["*"],
    program: nil
  }

  @program %{
    @base
    | transport: "program",
      mark: "mcp",
      program: %{
        "hosts" => ["api.github.com", "github.com"],
        "home" => "kept",
        "login_entry" => "ent_1",
        "memory_bytes" => 268_435_456,
        "home_max_bytes" => 1_073_741_824,
        "login_command" => "gh auth login"
      },
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
        %{@base | transport: "program", mark: "mcp", url: nil, program: %{}}
      ]

      for variant <- variants do
        {:ok, digest} = ToolServerDigest.compute(variant)
        refute digest == base
      end
    end

    test "every backend axis of an mcp program moves the digest, and its env order does not" do
      {:ok, base} = ToolServerDigest.compute(@program)
      [backend] = @program.backends

      variants = [
        [%{backend | "command" => "npx -y @modelcontextprotocol/server-github@2"}],
        [%{backend | "name" => "gh"}],
        [put_in(backend, ["env", "GITHUB_TOKEN"], "vault:other")],
        [backend, %{"name" => "fs", "command" => "npx -y fs", "env" => %{}}]
      ]

      for backends <- variants do
        {:ok, digest} = ToolServerDigest.compute(%{@program | backends: backends})
        refute digest == base, inspect(backends)
      end

      reordered = %{
        backend
        | "env" => %{"NODE_ENV" => "production", "GITHUB_TOKEN" => "vault:gh"}
      }

      assert {:ok, ^base} = ToolServerDigest.compute(%{@program | backends: [reordered]})
    end

    test "everything that decides what a program is and reaches moves its digest" do
      {:ok, base} = ToolServerDigest.compute(@program)

      for {key, value} <- [
            {"hosts", nil},
            {"hosts", ["api.github.com", "github.com", "evil.example"]},
            {"hosts", ["api.github.com"]},
            {"hosts", []},
            {"home", "scratch"},
            {"login_entry", "ent_2"},
            {"memory_bytes", nil},
            {"home_max_bytes", 2_147_483_648},
            {"login_command", "gh auth login --web"}
          ] do
        {:ok, digest} = ToolServerDigest.compute(put_in(@program, [:program, key], value))
        refute digest == base, "#{key} -> #{inspect(value)} kept the digest"
      end
    end

    test "a program's hosts are a set: one digest in any order, apart from no restriction" do
      {:ok, base} = ToolServerDigest.compute(@program)

      for hosts <- [
            ["github.com", "api.github.com"],
            ["github.com", "api.github.com", "github.com"]
          ] do
        assert {:ok, ^base} =
                 ToolServerDigest.compute(put_in(@program, [:program, "hosts"], hosts))
      end

      {:ok, unrestricted} = ToolServerDigest.compute(put_in(@program, [:program, "hosts"], nil))
      {:ok, empty} = ToolServerDigest.compute(put_in(@program, [:program, "hosts"], []))
      refute unrestricted == empty
      refute empty == base
    end

    test "a stored host list read from the row is the same set, and one that does not read has no digest" do
      row = fn hosts ->
        %{
          id: "mcp_row_1",
          transport: "program",
          mark: "mcp",
          url: nil,
          enabled: true,
          hosts: hosts,
          home: "kept",
          login_entry_id: "ent_1",
          memory_bytes: 268_435_456,
          home_max_bytes: 1_073_741_824,
          login_command: "gh auth login",
          config_json: Jason.encode!(%{"backends" => @program.backends})
        }
      end

      {:ok, a} = ToolServerDigest.from_server(row.(~s(["api.github.com","github.com"])))
      {:ok, b} = ToolServerDigest.from_server(row.(~s(["github.com","api.github.com"])))
      assert a == b
      assert {:ok, ^a} = ToolServerDigest.compute(@program)

      assert {:error, {:invalid_server_config, _}} =
               ToolServerDigest.from_server(row.("not json"))

      assert {:error, {:invalid_server_config, _}} =
               ToolServerDigest.from_server(row.(~s({"a":1})))
    end

    test "only a tool server has a digest: a driven program and an old kind have none" do
      for row <- [
            %{@program | mark: "driven"},
            %{@program | mark: nil},
            %{@base | mark: "mcp"},
            %{@program | transport: "stdio", mark: nil},
            %{@program | transport: "pipe", mark: nil},
            %{@program | program: nil},
            %{@base | program: %{}}
          ] do
        assert {:error, {:invalid_server_config, ^row}} = ToolServerDigest.compute(row)
      end
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
