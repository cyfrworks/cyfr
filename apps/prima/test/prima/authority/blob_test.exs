# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Prima.Authority.BlobTest do
  use ExUnit.Case, async: true

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Prima.Destination
  alias Prima.Limits
  alias Prima.Test.AuthorityFixtures, as: Fixtures

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

  # Authority graph fixture with full limits.
  defp golden do
    %{
      "canonical" => "jcs-1",
      "nodes" => %{
        @formula => %{
          "limits" => limits_map(),
          "edges" => %{
            "@ingress" => %{},
            "#{@catalyst}|source" => %{
              "vault" =>
                Fixtures.bound_vault(@formula, "#{@catalyst}|source", "vault-1", "sha256:aaa",
                  attach: Fixtures.attach_map(),
                  projection: %{"fields" => ["url", "anon_key"]}
                ),
              "egress" => %{
                "domains" => ["prod.supabase.co"],
                "methods" => ["GET", "POST"],
                "schemes" => ["https"],
                "private_ips" => []
              },
              "storage" => %{"paths" => [], "actions" => []},
              "tools" => ["storage.read"],
              "tool_servers" => [
                %{
                  "server_digest" => "sha256:srv",
                  "server_name" => "github",
                  "tool_patterns" => ["github.*"]
                }
              ]
            },
            "#{@catalyst}|dest" => %{
              "vault" =>
                Fixtures.bound_vault(@formula, "#{@catalyst}|dest", "vault-2", "sha256:bbb",
                  projection: %{"fields" => ["url", "service_key"]}
                )
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
                 scope: "athanor",
                 binding_key:
                   "formula:local.daily-report|catalyst:supabase.com.database|source|default",
                 destination: %Destination{hosts: ["prod.supabase.co"], scheme: "https"},
                 attach: %{in: "header", name: "Authorization", template: "Bearer {value}"},
                 projection: %{fields: ["url", "anon_key"], scopes: []}
               },
               egress: %{domains: ["prod.supabase.co"], methods: ["GET", "POST"]},
               storage: %{paths: [], actions: []},
               tools: ["storage.read"],
               tool_servers: [
                 %{
                   server_digest: "sha256:srv",
                   server_name: "github",
                   tool_patterns: ["github.*"],
                   descriptions_digest: nil
                 }
               ]
             } = source

      {:ok, dest} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      assert dest.vault.entry_id == "vault-2"
      # A disclose-only need's binding attaches nothing.
      assert dest.vault.attach == nil
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

  describe "entry_digest_conflicts/1" do
    test "the same entry with two binding digests is listed" do
      blob = parse!(golden())
      assert Blob.entry_digest_conflicts(blob) == []

      conflicted =
        golden()
        |> put_in(
          ["nodes", @formula, "edges", "#{@catalyst}|dest", "vault"],
          Fixtures.bound_vault(@formula, "#{@catalyst}|dest", "vault-1", "sha256:other",
            projection: %{"fields" => ["url"]}
          )
        )
        |> parse!()

      assert Blob.entry_digest_conflicts(conflicted) == ["vault-1"]
    end

    test "a named binding's entry counts as the default's does" do
      named =
        Fixtures.bound_vault(@formula, "#{@catalyst}|dest", "vault-1", "sha256:other",
          name: "Second"
        )

      conflicted =
        golden()
        |> put_in(["nodes", @formula, "edges", "#{@catalyst}|dest", "vault", "named"], %{
          "Second" => named
        })
        |> parse!()

      assert Blob.entry_digest_conflicts(conflicted) == ["vault-1"]
    end
  end

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

  describe "an edge's allowed lists" do
    test "name what the edge grants" do
      {:ok, source} = Blob.lookup_edge(parse!(golden()), @formula, @catalyst, "source")

      assert Edge.domains(source) == ["prod.supabase.co"]
      assert Edge.paths(source) == []
      assert Edge.actions(source) == []
      assert Edge.tools(source) == ["storage.read"]
    end

    test "are empty for a nil edge and for an absent resource group" do
      {:ok, dest} = Blob.lookup_edge(parse!(golden()), @formula, @catalyst, "dest")

      for edge <- [nil, dest] do
        assert Edge.domains(edge) == []
        assert Edge.paths(edge) == []
        assert Edge.actions(edge) == []
        assert Edge.tools(edge) == []
      end
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

    test "a key that is no string is unknown, at the top and on a node" do
      assert {:error, {:unknown_field, _}} = golden() |> Map.put(nil, 1) |> Blob.parse()

      assert {:error, {:unknown_field, "nodes[" <> _}} =
               golden() |> put_in(["nodes", @catalyst, nil], 1) |> Blob.parse()
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

  # ============================================================================
  # Bindings: scope, destination, attach, named, selected, provided
  # ============================================================================

  @golden_path Path.expand(
                 "../../support/fixtures/authority/resolved_policy_golden.json",
                 __DIR__
               )

  @dest_key "#{@catalyst}|dest"

  defp vault_path(edge_key), do: ["nodes", @formula, "edges", edge_key, "vault"]

  defp with_vault(edge_key, vault), do: put_in(golden(), vault_path(edge_key), vault)

  defp named(name, entry_id \\ "vault-named", opts \\ []) do
    Fixtures.bound_vault(@formula, @dest_key, entry_id, "sha256:named", [name: name] ++ opts)
  end

  defp dest_vault(opts \\ []),
    do: Fixtures.bound_vault(@formula, @dest_key, "vault-2", "sha256:bbb", opts)

  defp refused?(map), do: match?({:error, {:invalid_resource, _, _, :vault, _}}, Blob.parse(map))

  describe "bindings" do
    test "a vault key that is no string is refused" do
      refute refused?(with_vault(@dest_key, dest_vault()))
      assert refused?(with_vault(@dest_key, Map.put(dest_vault(), nil, 1)))
    end

    test "the golden blob holds a bound, a named, a resolved and a provided edge, and round-trips" do
      blob = @golden_path |> File.read!() |> Blob.parse() |> elem(1)

      {:ok, source} = Blob.lookup_edge(blob, @formula, @catalyst, "source")
      assert source.vault.scope == "athanor"
      assert source.vault.attach == %{in: "header", name: "apikey", template: "{value}"}
      assert source.vault.destination.paths == ["/rest/v1"]

      {:ok, dest} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      assert dest.vault.attach == nil

      assert %{"Archive" => %{scope: "instance", entry_id: "vault-entry-archive"}} =
               dest.vault.named

      {:ok, lent} = Blob.lookup_edge(blob, @formula, @catalyst, "lent")

      assert lent.vault.lender == %{
               profile_id: "prof-supabase",
               consent_id: "consent-supabase-3",
               binding_key: "#{@catalyst}|@ingress|default"
             }

      assert lent.vault.binding_key == "#{@formula}|#{@catalyst}|lent|default"

      {:ok, public} = Blob.lookup_edge(blob, @formula, @catalyst, "public")

      assert %{provided: %{values: %{"anon_key" => "public-anon-key"}, attach: %{}}} =
               public.vault

      assert Blob.bound_vault?(public.vault)

      assert Blob.parse(Blob.to_map(blob)) == {:ok, blob}

      # Both identities of the resolved selection cross the wire and back.
      {:ok, root} =
        Authority.root(
          %{
            profile_id: "prof-daily-report",
            consent_id: "consent-rev-2",
            source_ref: @formula,
            kind: :owner,
            invoke_mode: :open_inert,
            activation: %{}
          },
          blob,
          ceiling: Fixtures.ceiling()
        )

      child = Authority.bound_child(root, @catalyst, lent)

      assert {:ok, back} =
               child
               |> Authority.to_wire()
               |> Jason.encode!()
               |> Jason.decode!()
               |> Authority.from_wire()

      assert back.resources.vault == lent.vault
      assert back.policy == root.policy
    end

    test "a disclose-only binding writes no rule and reads an absent or a null one as none" do
      blob = parse!(golden())
      {:ok, dest} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      refute Map.has_key?(Blob.vault_to_map(dest.vault), "attach")
      assert {:ok, _canonical} = Prima.JCS.encode(Blob.to_map(blob))

      nulled = with_vault(@dest_key, Map.put(dest_vault(), "attach", nil))
      assert {:ok, blob} = Blob.parse(nulled)
      assert {:ok, %{vault: %{attach: nil}}} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
    end

    test "a bound vault names its scope, destination and binding key" do
      for field <- ["scope", "binding_key", "destination"] do
        assert refused?(with_vault(@dest_key, Map.delete(dest_vault(), field))), field
      end

      assert refused?(with_vault(@dest_key, dest_vault(scope: "athanors")))
      assert refused?(with_vault(@dest_key, dest_vault(destination: %{"hosts" => ["*"]})))
      assert refused?(with_vault(@dest_key, dest_vault(destination: %{"hosts" => []})))

      assert refused?(
               with_vault(
                 @dest_key,
                 dest_vault(attach: %{"in" => "body", "name" => "k", "template" => "{value}"})
               )
             )

      assert refused?(
               with_vault(
                 @dest_key,
                 dest_vault(attach: %{"in" => "header", "name" => "k", "template" => "none"})
               )
             )
    end

    test "a binding key names the node and edge it sits on and its own slot" do
      elsewhere = %{
        dest_vault()
        | "binding_key" => Blob.binding_key(@formula, "#{@catalyst}|source", nil)
      }

      assert refused?(with_vault(@dest_key, elsewhere))

      other_node = %{dest_vault() | "binding_key" => Blob.binding_key(@catalyst, @dest_key, nil)}
      assert refused?(with_vault(@dest_key, other_node))

      # `name:` on the unnamed binding, and `default` on a named one.
      assert refused?(with_vault(@dest_key, dest_vault(name: "Archive")))

      default_slot = %{
        named("Archive")
        | "binding_key" => Blob.binding_key(@formula, @dest_key, nil)
      }

      assert refused?(with_vault(@dest_key, dest_vault(named: %{"Archive" => default_slot})))

      other_name = %{
        named("Archive")
        | "binding_key" => Blob.binding_key(@formula, @dest_key, "Other")
      }

      assert refused?(with_vault(@dest_key, dest_vault(named: %{"Archive" => other_name})))

      # An account named "default" is a named slot, never the unnamed one.
      assert {:ok, blob} =
               Blob.parse(
                 with_vault(@dest_key, dest_vault(named: %{"default" => named("default")}))
               )

      {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      assert edge.vault.named["default"].binding_key == "#{@formula}|#{@dest_key}|name:default"
      assert edge.vault.binding_key == "#{@formula}|#{@dest_key}|default"
    end

    test "named bindings: none on a selection, no empty, repeated or reserved name, no nesting" do
      via = %{"via" => %{"label" => "default"}, "named" => %{"A" => named("A")}}
      assert refused?(with_vault(@dest_key, via))

      assert refused?(with_vault(@dest_key, dest_vault(named: %{})))
      assert refused?(with_vault(@dest_key, dest_vault(named: %{"" => named("")})))
      assert refused?(with_vault(@dest_key, dest_vault(named: %{"a|b" => named("a|b")})))

      # Two names a person reads as one are one name repeated.
      repeated = %{
        "Supabase" => named("Supabase"),
        "supabase" => named("supabase", "vault-other")
      }

      assert refused?(with_vault(@dest_key, dest_vault(named: repeated)))

      nested = Map.put(named("A"), "named", %{"B" => named("B")})
      assert refused?(with_vault(@dest_key, dest_vault(named: %{"A" => nested})))

      lent =
        Map.put(named("A"), "lender", %{
          "profile_id" => "p",
          "consent_id" => "c",
          "binding_key" => "#{@catalyst}|@ingress|default"
        })

      assert refused?(with_vault(@dest_key, dest_vault(named: %{"A" => lent})))
    end

    test "a lender names its profile, consent and binding key" do
      lender = %{
        "profile_id" => "p",
        "consent_id" => "c",
        "binding_key" => "#{@catalyst}|@ingress|default"
      }

      assert {:ok, _blob} = Blob.parse(with_vault(@dest_key, dest_vault(lender: lender)))

      for field <- Map.keys(lender) do
        assert refused?(with_vault(@dest_key, dest_vault(lender: Map.delete(lender, field)))),
               field
      end

      assert refused?(
               with_vault(@dest_key, dest_vault(lender: %{lender | "binding_key" => "not a key"}))
             )
    end

    test "provided configuration names its destination, values and attach rule" do
      provided = %{
        "destination" => Fixtures.destination_map(),
        "values" => %{"anon_key" => "public"},
        "attach" => Fixtures.attach_map()
      }

      assert {:ok, blob} = Blob.parse(with_vault(@dest_key, %{"provided" => provided}))
      {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      assert %{provided: %{values: %{"anon_key" => "public"}}} = edge.vault
      assert Blob.edge_to_map(edge)["vault"] == %{"provided" => provided}

      assert refused?(with_vault(@dest_key, %{"provided" => Map.delete(provided, "attach")}))
      assert refused?(with_vault(@dest_key, %{"provided" => Map.put(provided, "attach", nil)}))
      assert refused?(with_vault(@dest_key, %{"provided" => Map.delete(provided, "values")}))

      too_large = %{provided | "values" => %{"k" => String.duplicate("v", 4096)}}
      assert refused?(with_vault(@dest_key, %{"provided" => too_large}))

      assert refused?(
               with_vault(@dest_key, %{"provided" => provided, "named" => %{"A" => named("A")}})
             )
    end

    test "bound_vault? is true for an entry and for provided configuration" do
      blob = @golden_path |> File.read!() |> Blob.parse() |> elem(1)

      for need <- ["source", "dest", "lent", "public"] do
        {:ok, edge} = Blob.lookup_edge(blob, @formula, @catalyst, need)
        assert Blob.bound_vault?(edge.vault), need
      end

      refute Blob.bound_vault?(%{via: %{label: "x", binding_digest: nil}, projection: nil})
      refute Blob.bound_vault?(nil)
    end
  end

  describe "vault_for/2" do
    setup do
      blob = @golden_path |> File.read!() |> Blob.parse() |> elem(1)
      {:ok, dest} = Blob.lookup_edge(blob, @formula, @catalyst, "dest")
      {:ok, public} = Blob.lookup_edge(blob, @formula, @catalyst, "public")
      %{dest: dest, public: public}
    end

    test "picks the default without its named bindings, or the named account", %{dest: dest} do
      assert {:ok, default} = Blob.vault_for(dest, nil)
      assert default == Map.delete(dest.vault, :named)
      assert default.entry_id == "vault-entry-warehouse"

      assert {:ok, archive} = Blob.vault_for(dest, "Archive")
      assert archive == dest.vault.named["Archive"]
    end

    test "a name the edge does not bind is connection_not_granted", %{dest: dest, public: public} do
      assert Blob.vault_for(dest, "archive") == {:error, :connection_not_granted}
      assert Blob.vault_for(dest, "default") == {:error, :connection_not_granted}
      assert Blob.vault_for(public, "Archive") == {:error, :connection_not_granted}
      assert Blob.vault_for(%Edge{}, "Archive") == {:error, :connection_not_granted}
      assert Blob.vault_for(nil, "Archive") == {:error, :connection_not_granted}
      assert Blob.vault_for(nil, nil) == {:ok, nil}
      assert Blob.vault_for(%Edge{}, nil) == {:ok, nil}
    end
  end

  describe "binding keys" do
    test "spell the node, the edge key and the slot, and parse back" do
      for {node, edge, slot} <- [
            {@formula, "@ingress", nil},
            {@formula, @catalyst, nil},
            {@formula, @dest_key, "Supabase 1"},
            {@formula, @dest_key, "default"}
          ] do
        key = Blob.binding_key(node, edge, slot)
        assert Blob.parse_binding_key(key) == {:ok, {node, edge, slot}}, key
      end

      assert Blob.binding_key(@formula, "@ingress", nil) == "#{@formula}|@ingress|default"
    end

    test "outside the grammar are refused" do
      for bad <- [
            "",
            @formula,
            "#{@formula}|@ingress",
            "#{@formula}|@ingress|",
            "#{@formula}|@ingress|named",
            "#{@formula}|@ingress|name:",
            "#{@formula}|@bogus|default",
            "#{@formula}||default",
            "#{@formula}:1.0.0|@ingress|default",
            "not a ref|@ingress|default",
            nil
          ] do
        assert Blob.parse_binding_key(bad) == :error, inspect(bad)
      end
    end

    test "an edge read alone holds its key to the grammar, not to a place" do
      picked = Map.put(named("Archive"), "attach", Fixtures.attach_map())
      assert {:ok, %Edge{vault: %{binding_key: key}}} = Blob.parse_edge(%{"vault" => picked})
      assert key == "#{@formula}|#{@dest_key}|name:Archive"

      assert {:error, {:invalid_resource, _, _, :vault, _}} =
               Blob.parse_edge(%{"vault" => %{picked | "binding_key" => "nonsense"}})
    end
  end

  defp node_stub do
    %{"limits" => limits_map(), "edges" => %{}}
  end
end
