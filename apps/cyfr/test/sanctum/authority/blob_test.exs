# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.BlobTest do
  use ExUnit.Case, async: true

  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Blob.Edge
  alias Sanctum.Limits

  @formula "formula:local.daily-report"
  @catalyst "catalyst:supabase.com.database"

  defp limits_map(overrides \\ %{}) do
    Map.merge(
      %{
        "timeout" => "15m",
        "max_memory_bytes" => 67_108_864,
        "max_request_size" => 1_048_576,
        "max_response_size" => 5_242_880,
        "rate_limit" => %{"requests" => 100, "window" => "1m"},
        "max_concurrent_tasks" => 30,
        "batch_timeout" => "5m"
      },
      overrides
    )
  end

  # The model §3.3 example, completed with full limits.
  defp golden do
    %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @formula => %{
          "limits" => limits_map(),
          "edges" => %{
            "@ingress" => %{},
            "#{@catalyst}|source" => %{
              "vault" => %{
                "entry_id" => "vault-1",
                "binding_digest" => "sha256:aaa",
                "projection" => %{"fields" => ["url", "anon_key"]}
              },
              "egress" => %{
                "domains" => ["prod.supabase.co"],
                "methods" => ["GET", "POST"],
                "schemes" => ["https"],
                "private_ips" => []
              },
              "storage" => %{"paths" => [], "actions" => []},
              "tools" => ["storage.read"],
              "tool_servers" => [
                %{"server_digest" => "sha256:srv", "tool_patterns" => ["github.*"]}
              ]
            },
            "#{@catalyst}|dest" => %{
              "vault" => %{
                "entry_id" => "vault-2",
                "binding_digest" => "sha256:bbb",
                "projection" => %{"fields" => ["url", "service_key"]}
              }
            }
          }
        },
        @catalyst => %{
          "limits" => limits_map(%{"timeout" => "30s"}),
          "edges" => %{}
        }
      }
    }
  end

  defp parse!(map) do
    {:ok, blob} = Blob.parse(map)
    blob
  end

  # ============================================================================
  # Golden parse
  # ============================================================================

  describe "parse/1 golden" do
    test "parses the JSON string form" do
      {:ok, blob} = golden() |> Jason.encode!() |> Blob.parse()

      assert blob.canonical == "jcs-1"
      assert Map.keys(blob.nodes) |> Enum.sort() == [@catalyst, @formula]

      {:ok, limits} = Blob.node_limits(blob, @formula)
      assert %Limits{timeout: "15m", max_concurrent_tasks: 30} = limits

      {:ok, callee_limits} = Blob.node_limits(blob, @catalyst)
      assert callee_limits.timeout == "30s"
    end

    test "edges carry exactly their declared resources, atom-keyed" do
      blob = parse!(golden())

      {:ok, source} = Blob.lookup_edge(blob, @formula, @catalyst, "source")

      assert %Edge{
               vault: %{
                 entry_id: "vault-1",
                 binding_digest: "sha256:aaa",
                 projection: %{fields: ["url", "anon_key"], scopes: []}
               },
               egress: %{domains: ["prod.supabase.co"], methods: ["GET", "POST"]},
               storage: %{paths: [], actions: []},
               tools: ["storage.read"],
               tool_servers: [%{server_digest: "sha256:srv", tool_patterns: ["github.*"]}]
             } = source

      {:ok, dest} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      assert dest.vault.entry_id == "vault-2"
      assert dest.egress == nil
      assert dest.tools == []
    end

    test "the ingress edge is an ordinary empty Edge" do
      blob = parse!(golden())

      assert {:ok, %Edge{vault: nil, egress: nil, storage: nil, tools: [], tool_servers: []}} =
               Blob.ingress(blob, @formula)
    end
  end

  # ============================================================================
  # Lookup
  # ============================================================================

  describe "lookup" do
    test "edge_key/2 canonical spelling" do
      assert Blob.edge_key(@catalyst, "") == @catalyst
      assert Blob.edge_key(@catalyst, "source") == "#{@catalyst}|source"
    end

    test "lookup misses fail closed" do
      blob = parse!(golden())

      assert {:error, :no_edge} = Blob.lookup_edge(blob, @formula, @catalyst, "")
      assert {:error, :no_edge} = Blob.lookup_edge(blob, @formula, @catalyst, "backup")
      assert {:error, :no_edge} = Blob.lookup_edge(blob, @catalyst, @formula, "")

      assert {:error, :no_edge} =
               Blob.lookup_edge(blob, "formula:local.ghost", @catalyst, "source")

      assert {:error, :missing_ingress} = Blob.ingress(blob, @catalyst)
      assert {:error, :unknown_node} = Blob.node(blob, "formula:local.ghost")
    end
  end

  # ============================================================================
  # Clamp
  # ============================================================================

  describe "clamp/2" do
    test "clamps every node's limits" do
      blob = parse!(golden())
      clamped = Blob.clamp(blob, %{timeout: "1m", max_concurrent_tasks: 5})

      {:ok, formula_limits} = Blob.node_limits(clamped, @formula)
      assert formula_limits.timeout == "1m"
      assert formula_limits.max_concurrent_tasks == 5

      {:ok, catalyst_limits} = Blob.node_limits(clamped, @catalyst)
      assert catalyst_limits.timeout == "30s"
      assert catalyst_limits.max_concurrent_tasks == 5
    end
  end

  # ============================================================================
  # Error taxonomy — one mutation, one specific error
  # ============================================================================

  describe "parse/1 errors" do
    test "invalid JSON" do
      assert {:error, {:invalid_json, _}} = Blob.parse("{not json")
      assert {:error, {:invalid_json, nil}} = Blob.parse(nil)
      assert {:error, {:invalid_structure, "", _}} = Blob.parse("[1,2]")
    end

    test "unsupported canonical" do
      assert {:error, {:unsupported_canonical, "jcs-2"}} =
               golden() |> Map.put("canonical", "jcs-2") |> Blob.parse()

      assert {:error, {:unsupported_canonical, nil}} =
               golden() |> Map.delete("canonical") |> Blob.parse()
    end

    test "unknown fields at every level" do
      assert {:error, {:unknown_field, "signature"}} =
               golden() |> Map.put("signature", "x") |> Blob.parse()

      assert {:error, {:unknown_field, "nodes[" <> _}} =
               golden()
               |> put_in(["nodes", @catalyst, "policy"], %{})
               |> Blob.parse()
    end

    test "nodes must be an object" do
      assert {:error, {:invalid_structure, "nodes", _}} =
               golden() |> Map.put("nodes", []) |> Blob.parse()

      assert {:error, {:invalid_structure, "nodes", _}} =
               golden() |> Map.delete("nodes") |> Blob.parse()

      assert {:error, {:invalid_structure, "nodes[formula:local.x]", _}} =
               golden() |> put_in(["nodes", "formula:local.x"], "oops") |> Blob.parse()
    end

    test "node refs must parse and be name-level" do
      assert {:error, {:invalid_node_ref, "garbage"}} =
               golden() |> put_in(["nodes", "garbage"], node_stub()) |> Blob.parse()

      pinned = "formula:local.daily-report:1.0.0"

      assert {:error, {:invalid_node_ref, ^pinned}} =
               golden() |> put_in(["nodes", pinned], node_stub()) |> Blob.parse()
    end

    test "limits are required and validated" do
      assert {:error, {:invalid_structure, path, _}} =
               golden()
               |> update_in(["nodes", @catalyst], &Map.delete(&1, "limits"))
               |> Blob.parse()

      assert path =~ "limits"

      assert {:error, {:invalid_limits, @catalyst, {:invalid_limit, :timeout, _}}} =
               golden()
               |> put_in(["nodes", @catalyst, "limits", "timeout"], "forever")
               |> Blob.parse()
    end

    test "edge keys reject reserved, pinned, and ambiguous spellings" do
      for bad <- [
            "@bogus",
            "#{@catalyst}|",
            "#{@catalyst}|a|b",
            "#{@catalyst}:0.3.3|source",
            "not a ref"
          ] do
        assert {:error, {:invalid_edge_key, @formula, ^bad}} =
                 golden()
                 |> put_in(["nodes", @formula, "edges", bad], %{})
                 |> Blob.parse(),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "edge targets must have node entries" do
      dangling = "catalyst:local.ghost"

      assert {:error, {:dangling_edge, @formula, ^dangling}} =
               golden()
               |> put_in(["nodes", @formula, "edges", dangling], %{})
               |> Blob.parse()
    end

    test "resource shapes are validated per kind" do
      assert {:error, {:invalid_resource, @formula, _, :vault, _}} =
               golden()
               |> update_in(
                 ["nodes", @formula, "edges", "#{@catalyst}|source", "vault"],
                 &Map.delete(&1, "entry_id")
               )
               |> Blob.parse()

      assert {:error, {:invalid_resource, @formula, _, :vault, _}} =
               golden()
               |> put_in(
                 ["nodes", @formula, "edges", "#{@catalyst}|source", "vault", "projection"],
                 %{"fields" => ["url"], "rows" => ["*"]}
               )
               |> Blob.parse()

      assert {:error, {:invalid_resource, @formula, _, :egress, _}} =
               golden()
               |> put_in(
                 ["nodes", @formula, "edges", "#{@catalyst}|source", "egress"],
                 %{"domains" => ["x.com"], "ports" => [443]}
               )
               |> Blob.parse()

      assert {:error, {:invalid_resource, @formula, _, :tools, _}} =
               golden()
               |> put_in(["nodes", @formula, "edges", "#{@catalyst}|source", "tools"], [
                 "storage.read",
                 ""
               ])
               |> Blob.parse()

      assert {:error, {:invalid_resource, @formula, _, :tool_servers, _}} =
               golden()
               |> put_in(["nodes", @formula, "edges", "#{@catalyst}|source", "tool_servers"], [
                 %{"tool_patterns" => ["a.*"]}
               ])
               |> Blob.parse()
    end
  end

  defp node_stub do
    %{"limits" => limits_map(), "edges" => %{}}
  end
end
