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
    command: nil,
    env: nil,
    program: nil
  }

  @program %{
    @base
    | transport: "program",
      mark: "mcp",
      program: %{
        "hosts" => ["api.github.com", "github.com"],
        "home" => "kept",
        "memory_bytes" => 268_435_456,
        "home_max_bytes" => 1_073_741_824
      },
      url: nil,
      headers: %{},
      command: "npx -y @modelcontextprotocol/server-github",
      env: %{"GITHUB_TOKEN" => "vault:gh", "NODE_ENV" => "production"}
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

    test "what decides where a tool server's calls go and which entries ride along moves the digest" do
      {:ok, base} = ToolServerDigest.compute(@base)

      variants = [
        %{@base | id: "mcp_row_2"},
        %{@base | url: "http://mcp.example/sse"},
        %{@base | url: "https://evil.example/sse"},
        %{@base | url: "https://mcp.example:8443/sse"},
        %{@base | url: "https://mcp.example/other"},
        %{@base | enabled: false},
        %{@base | headers: %{"authorization" => "vault:OTHER_TOKEN", "user-agent" => "cyfr"}},
        %{@base | headers: %{"user-agent" => "cyfr"}},
        %{@base | headers: Map.put(@base.headers, "x-extra", "Bearer vault:EXTRA")},
        %{
          @base
          | transport: "program",
            mark: "mcp",
            url: nil,
            command: "npx server",
            env: %{},
            program: %{"home" => "scratch"}
        }
      ]

      for variant <- variants do
        {:ok, digest} = ToolServerDigest.compute(variant)
        refute digest == base, inspect(variant)
      end
    end

    test "every header moves the digest, a literal by its value; tool patterns keep it" do
      {:ok, base} = ToolServerDigest.compute(@base)

      for headers <- [
            %{"authorization" => "vault:GH_TOKEN", "user-agent" => "cyfr/2"},
            %{"authorization" => "vault:GH_TOKEN"},
            %{
              "authorization" => "vault:GH_TOKEN",
              "user-agent" => "cyfr",
              "host" => "other.example"
            }
          ] do
        {:ok, digest} = ToolServerDigest.compute(%{@base | headers: headers})
        refute digest == base, inspect(headers)
      end

      row = fn patterns ->
        %{
          id: "mcp_row_1",
          transport: "http",
          url: "https://mcp.example/sse",
          enabled: true,
          config_json: Jason.encode!(%{"headers" => @base.headers, "tool_patterns" => patterns})
        }
      end

      assert {:ok, ^base} = ToolServerDigest.from_server(row.(["*"]))
      assert {:ok, ^base} = ToolServerDigest.from_server(row.(["issues.*"]))
    end

    test "an mcp program's command and every env name and template move the digest, a " <>
           "literal by its value, and its env order does not" do
      {:ok, base} = ToolServerDigest.compute(@program)

      variants = [
        %{@program | command: "npx -y @modelcontextprotocol/server-github@2"},
        put_in(@program, [:env, "GITHUB_TOKEN"], "vault:other"),
        put_in(@program, [:env, "GITHUB_TOKEN"], "Bearer vault:gh"),
        put_in(@program, [:env, "NODE_ENV"], "development"),
        put_in(@program, [:env, "GH_HOST"], "vault:gh"),
        %{@program | env: Map.delete(@program.env, "NODE_ENV")}
      ]

      for variant <- variants do
        {:ok, digest} = ToolServerDigest.compute(variant)
        refute digest == base, inspect({variant.command, variant.env})
      end

      reordered = %{"NODE_ENV" => "production", "GITHUB_TOKEN" => "vault:gh"}
      assert {:ok, ^base} = ToolServerDigest.compute(%{@program | env: reordered})
    end

    test "everything that decides what a program is and reaches moves its digest and its record" do
      {:ok, base} = ToolServerDigest.compute(@program)
      {:ok, record, _} = record_and_digest(@program)

      for {key, value} <- [
            {"hosts", nil},
            {"hosts", ["api.github.com", "github.com", "evil.example"]},
            {"hosts", ["api.github.com"]},
            {"hosts", []},
            {"home", "scratch"},
            {"memory_bytes", nil},
            {"memory_bytes", 536_870_912},
            {"home_max_bytes", 2_147_483_648}
          ] do
        variant = put_in(@program, [:program, key], value)
        {:ok, digest} = ToolServerDigest.compute(variant)
        refute digest == base, "#{key} -> #{inspect(value)} kept the digest"

        {:ok, moved, ^digest} = record_and_digest(variant)
        refute moved == record, "#{key} -> #{inspect(value)} kept the record"
      end
    end

    # Nothing the digest covers is outside the record but a literal's value
    # and the row's identity: a program whose record and literals are the
    # same has the same digest, whatever else its map holds.
    test "a program's digest is its record and its literals' values" do
      {:ok, record, digest} = record_and_digest(@program)

      assert record == %{
               "address" => "npx -y @modelcontextprotocol/server-github",
               "env" => [
                 %{"name" => "GITHUB_TOKEN", "entry" => "gh"},
                 %{"name" => "NODE_ENV", "literal" => true}
               ],
               "folder" => "kept",
               "hosts" => ["api.github.com", "github.com"],
               "memory_bytes" => 268_435_456,
               "home_max_bytes" => 1_073_741_824
             }

      assert {:ok, ^digest} =
               Prima.JCS.hash(%{
                 "id" => "mcp_row_1",
                 "transport" => "program",
                 "enabled" => true,
                 "mark" => "mcp",
                 "record" => record,
                 "literals" => %{"NODE_ENV" => "production"}
               })

      # Hosts and a literal both moved: the record tells the hosts alone,
      # and the digest moves for both.
      hosts_only = put_in(@program, [:program, "hosts"], ["api.github.com"])
      both = put_in(hosts_only, [:env, "NODE_ENV"], "development")
      {:ok, hosts_record, hosts_digest} = record_and_digest(hosts_only)
      assert {:ok, ^hosts_record, both_digest} = record_and_digest(both)
      refute both_digest == hosts_digest
    end

    test "a program setting that does not read leaves it without a record or a digest" do
      for {key, value} <- [
            {"home", nil},
            {"home", "shared"},
            {"hosts", "github.com"},
            {"hosts", [""]},
            {"memory_bytes", 0},
            {"home_max_bytes", "1 GiB"}
          ] do
        row = put_in(@program, [:program, key], value)
        assert {:error, {:invalid_server_config, ^row}} = ToolServerDigest.compute(row)
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
          memory_bytes: 268_435_456,
          home_max_bytes: 1_073_741_824,
          config_json: Jason.encode!(%{"command" => @program.command, "env" => @program.env})
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

    # Every row's definition has a digest, a driven program's too, which
    # its login grants are bound at; only a tool server's is pinned by a
    # grant of its tools.
    test "a driven program's definition has a digest, which it is no tool server's" do
      driven = %{@program | mark: "driven"}
      {:ok, mcp} = ToolServerDigest.compute(@program)
      assert {:ok, digest} = ToolServerDigest.compute(driven)
      refute digest == mcp

      {:ok, moved} = ToolServerDigest.compute(%{driven | env: %{"NODE_ENV" => "development"}})
      refute moved == digest

      row = fn mark ->
        %{
          id: "srv_driven",
          transport: "program",
          mark: mark,
          url: nil,
          enabled: true,
          home: "kept",
          config_json: ~s({"command":"claude","env":{}})
        }
      end

      assert {:ok, _} = ToolServerDigest.definition(row.("driven"))
      assert {:error, {:invalid_server_config, _}} = ToolServerDigest.from_server(row.("driven"))
      assert ToolServerDigest.from_server(row.("mcp")) == ToolServerDigest.definition(row.("mcp"))
    end

    test "an old kind or a broken row has no digest" do
      for row <- [
            %{@program | mark: nil},
            %{@base | mark: "mcp"},
            %{@program | transport: "stdio", mark: nil},
            %{@program | transport: "pipe", mark: nil},
            %{@program | program: nil},
            %{@program | command: nil},
            %{@program | env: nil},
            %{@base | program: %{}},
            %{@base | command: "npx server", env: %{}}
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

  # The record and digest of a server as `compute/1` reads it: the record
  # through a stored row of the same definition.
  defp record_and_digest(server) do
    row = %{
      id: server.id,
      transport: server.transport,
      mark: server.mark,
      url: server.url,
      enabled: server.enabled,
      hosts: server.program["hosts"] && Jason.encode!(server.program["hosts"]),
      home: server.program["home"],
      memory_bytes: server.program["memory_bytes"],
      home_max_bytes: server.program["home_max_bytes"],
      config_json: Jason.encode!(%{"command" => server.command, "env" => server.env})
    }

    with {:ok, record} <- ToolServerDigest.recorded(row),
         {:ok, digest} <- ToolServerDigest.from_server(row) do
      {:ok, ^digest} = ToolServerDigest.compute(server)
      {:ok, record, digest}
    end
  end

  describe "recorded/1" do
    # A stored row as the row store holds one, its config JSON beside its
    # program columns.
    defp stored(over) do
      Map.merge(
        %{
          id: "mcp_row_1",
          transport: "http",
          mark: nil,
          url: "https://mcp.example/sse",
          enabled: true,
          hosts: nil,
          home: "scratch",
          memory_bytes: nil,
          home_max_bytes: nil,
          config_json:
            Jason.encode!(%{
              "headers" => %{
                "authorization" => "Bearer vault:GH_TOKEN",
                "x-api-key" => "vault:other",
                "user-agent" => "cyfr-literal-secret"
              }
            })
        },
        over
      )
    end

    test "an http row records its url and each header by name with the entry it names" do
      assert ToolServerDigest.recorded(stored(%{})) ==
               {:ok,
                %{
                  "address" => "https://mcp.example/sse",
                  "headers" => [
                    %{"name" => "authorization", "entry" => "GH_TOKEN", "scheme" => "Bearer"},
                    %{"name" => "user-agent", "literal" => true},
                    %{"name" => "x-api-key", "entry" => "other"}
                  ]
                }}
    end

    test "a program records its command, each environment variable, a literal by name " <>
           "alone, and its settings, each unset one absent" do
      row =
        stored(%{
          transport: "program",
          mark: "mcp",
          url: nil,
          config_json: Jason.encode!(%{"command" => @program.command, "env" => @program.env})
        })

      assert ToolServerDigest.recorded(row) ==
               {:ok,
                %{
                  "address" => "npx -y @modelcontextprotocol/server-github",
                  "env" => [
                    %{"name" => "GITHUB_TOKEN", "entry" => "gh"},
                    %{"name" => "NODE_ENV", "literal" => true}
                  ],
                  "folder" => "scratch"
                }}

      # A stored host list is a set; an empty one is a list of its own.
      assert {:ok, %{"hosts" => ["api.github.com", "github.com"]}} =
               ToolServerDigest.recorded(%{
                 row
                 | hosts: ~s(["github.com","api.github.com","github.com"])
               })

      assert {:ok, %{"hosts" => []}} = ToolServerDigest.recorded(%{row | hosts: "[]"})

      # A driven program offers no tools and has no digest, but is recorded
      # as a program of either mark is: its install confirmation shows it.
      assert ToolServerDigest.recorded(%{row | mark: "driven"}) == ToolServerDigest.recorded(row)

      assert {:error, {:invalid_server_config, _}} =
               ToolServerDigest.from_server(%{row | mark: "driven"})
    end

    test "never carries a literal's value, which the digest still covers" do
      {:ok, record} = ToolServerDigest.recorded(stored(%{}))
      refute inspect(record) =~ "cyfr-literal-secret"

      moved =
        stored(%{
          config_json:
            Jason.encode!(%{
              "headers" => %{
                "authorization" => "Bearer vault:GH_TOKEN",
                "x-api-key" => "vault:other",
                "user-agent" => "another-literal"
              }
            })
        })

      assert ToolServerDigest.recorded(moved) == {:ok, record}
      refute ToolServerDigest.from_server(moved) == ToolServerDigest.from_server(stored(%{}))
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
