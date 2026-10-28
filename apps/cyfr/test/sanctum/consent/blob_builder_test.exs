# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.BlobBuilderTest do
  @moduledoc """
  A narrowing grants the ask intersected with the subset a decision names,
  for each kind whose enforcement point can check a subset: egress domains,
  methods, schemes and private ranges, storage paths and actions, tool
  actions, the limits under the ceiling, and the flows to each exit. A
  value outside the ask is refused as a superset, a kind no enforcement
  point can narrow is refused rather than shown narrowed, and what is
  granted is what runs. Each edge keeps the flows whose exit it binds.
  """

  use ExUnit.Case, async: false

  require Phoenix.LiveViewTest

  alias Prima.Authority.Blob
  alias Prima.ConsentPreview
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan

  @wasm Cyfr.Test.Guests.wasm(:reagent)
  @ref "reagent:local.narrow-source"
  @dep "reagent:local.narrow-dep"

  @ask %{
    "egress" => %{
      "domains" => ["api.one.example", "*.two.example"],
      "methods" => ["GET", "POST"],
      "schemes" => ["http", "https"],
      "private_ips" => ["10.0.0.0/8", "192.168.1.5"]
    },
    "storage" => %{"paths" => ["data/"], "actions" => ["list", "read", "write"]},
    "tools" => ["execution.logs", "execution.run"],
    "limits" => %{
      "timeout" => "45m",
      "max_memory_bytes" => 33_554_432,
      "rate_limit" => %{"requests" => 60, "window" => "1m"}
    }
  }

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_narrow_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    original_ceiling = Application.get_env(:sanctum, :platform_ceiling)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)

      if original_ceiling,
        do: Application.put_env(:sanctum, :platform_ceiling, original_ceiling),
        else: Application.delete_env(:sanctum, :platform_ceiling)
    end)

    ctx = Sanctum.TestContext.local(:prism)
    publish!(ctx, "narrow-source", %{"caps" => @ask})
    {:ok, ctx: ctx}
  end

  defp publish!(ctx, name, manifest) do
    manifest = Map.merge(manifest, %{"name" => name, "version" => "1.0.0", "type" => "reagent"})

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    component
  end

  defp preview(ctx, subset, ref \\ @ref), do: Commit.preview(ctx, %{ref: ref, subset: subset})

  defp walk!(ctx, subset, ref \\ @ref) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, subset: subset}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    committed
  end

  defp rows(preview) do
    {:ok, decoded} =
      ConsentPreview.decode(%{
        "v" => preview.v,
        "rows" => preview.rows,
        "origins" => preview.origins,
        "commit_digest" => preview.commit_digest,
        "removed" => preview.removed
      })

    Map.new(decoded.rows, &{{&1.kind, &1.node}, &1})
  end

  describe "each kind narrows to the part of the ask it names" do
    @narrowing %{
      @ref => %{
        "egress" => %{
          # One domain the ask names, and one host its pattern admits.
          "domains" => ["api.one.example", "api.b.two.example"],
          "methods" => ["GET"],
          "schemes" => ["https"],
          # A narrower range inside one of the ask's, and one of its addresses.
          "private_ips" => ["10.1.2.0/24", "192.168.1.5"]
        },
        # A folder below the ask's prefix, as a picker selects it.
        "storage" => %{"paths" => ["data/reports/"], "actions" => ["read"]},
        "tools" => ["execution.run"],
        "limits" => %{
          "timeout" => "10m",
          "max_memory_bytes" => 16_777_216,
          "max_concurrent_tasks" => 0,
          "rate_limit" => %{"requests" => 30}
        }
      }
    }

    test "the preview shows each narrowed kind, narrowed, with what it grants", %{ctx: ctx} do
      {:ok, preview} = preview(ctx, @narrowing)
      rows = rows(preview)

      assert %{narrowed: true, values: egress} = rows[{:egress, @ref}]

      assert egress == %{
               "domains" => ["api.b.two.example", "api.one.example"],
               "methods" => ["GET"],
               "schemes" => ["https"],
               "private_ips" => ["10.1.2.0/24", "192.168.1.5"]
             }

      assert %{narrowed: true, values: %{"paths" => ["data/reports/"], "actions" => ["read"]}} =
               rows[{:storage, @ref}]

      assert %{narrowed: true, values: %{"tools" => ["execution.run"]}} = rows[{:tools, @ref}]

      assert %{narrowed: true, values: limits} = rows[{:limits, @ref}]
      assert limits["timeout"] == "10m"
      assert limits["max_memory_bytes"] == 16_777_216
      assert limits["max_concurrent_tasks"] == 0
      assert limits["rate_limit"] == %{"requests" => 30, "window" => "1m"}
      # A limit the narrowing leaves out keeps its ask.
      assert limits["max_request_size"] == Prima.Limits.default_max_request_size()
    end

    test "what is granted is what runs: the loaded edge refuses what was dropped", %{ctx: ctx} do
      walk!(ctx, @narrowing)
      {:ok, authority} = Opus.authority_for(ctx, :default, @ref)
      edge = authority.resources

      assert Prima.Network.domain_allowed?("api.b.two.example", edge.egress.domains)
      refute Prima.Network.domain_allowed?("api.c.two.example", edge.egress.domains)
      assert edge.egress.methods == ["GET"]
      assert edge.storage == %{paths: ["data/reports/"], actions: ["read"]}
      assert edge.tools == ["execution.run"]

      limits = Prima.Authority.limits(authority)
      assert limits.timeout == "10m"
      assert limits.max_concurrent_tasks == 0
      assert limits.rate_limit == %{requests: 30, window: "1m"}
    end

    test "a field left out keeps its ask, and an empty set grants none", %{ctx: ctx} do
      {:ok, preview} = preview(ctx, %{@ref => %{"egress" => %{"domains" => []}}})
      rows = rows(preview)

      assert %{narrowed: true, values: egress} = rows[{:egress, @ref}]
      assert egress["domains"] == []
      assert egress["methods"] == ["GET", "POST"]

      assert %{narrowed: false, values: %{"actions" => ["list", "read", "write"]}} =
               rows[{:storage, @ref}]

      walk!(ctx, %{@ref => %{"egress" => %{"domains" => []}}})
      {:ok, authority} = Opus.authority_for(ctx, :default, @ref)
      refute Prima.Network.domain_allowed?("api.one.example", authority.resources.egress.domains)
    end

    test "a path is inside the ask when the ask admits it, as the storage door reads the ask",
         %{ctx: ctx} do
      # The bare folder a prefix names is a path that prefix admits (a
      # listing names it without its slash), so it narrows the ask, as a
      # path or a prefix below the ask's prefix does.
      for paths <- [["data"], ["data/reports"], ["data/reports/"]] do
        assert {:ok, preview} = preview(ctx, %{@ref => %{"storage" => %{"paths" => paths}}}),
               inspect(paths)

        assert %{narrowed: true, values: %{"paths" => ^paths}} = rows(preview)[{:storage, @ref}]
      end

      walk!(ctx, %{@ref => %{"storage" => %{"paths" => ["data"]}}})
      {:ok, authority} = Opus.authority_for(ctx, :default, @ref)
      granted = Blob.Edge.paths(authority.resources)

      assert Prima.ComponentPath.path_granted?("data", granted)
      refute Prima.ComponentPath.path_granted?("data/reports/a.md", granted)
    end

    test "a narrowing that leaves the ask as it is is not shown as narrowed", %{ctx: ctx} do
      {:ok, preview} =
        preview(ctx, %{@ref => %{"storage" => %{"actions" => ["write", "read", "list"]}}})

      assert %{narrowed: false} = rows(preview)[{:storage, @ref}]
    end
  end

  describe "a superset is refused" do
    test "a value outside the ask, in each narrowable field", %{ctx: ctx} do
      for {subset, fragment} <- [
            {%{"egress" => %{"domains" => ["api.three.example"]}}, "egress domain api.three"},
            {%{"egress" => %{"domains" => ["*.example"]}}, "egress domain *.example"},
            {%{"egress" => %{"methods" => ["DELETE"]}}, "egress method DELETE"},
            {%{"egress" => %{"schemes" => ["ftp"]}}, "egress scheme ftp"},
            {%{"egress" => %{"private_ips" => ["172.16.0.0/12"]}}, "private range 172.16"},
            {%{"egress" => %{"private_ips" => ["10.0.0.0/7"]}}, "private range 10.0.0.0/7"},
            {%{"storage" => %{"paths" => ["cache/"]}}, "storage path cache/"},
            {%{"storage" => %{"paths" => ["data/../system/"]}}, "storage path data/../"},
            {%{"storage" => %{"actions" => ["delete"]}}, "storage action delete"},
            {%{"tools" => ["execution.cancel"]}, "tool action execution.cancel"},
            {%{"limits" => %{"timeout" => "50m"}}, "limits.timeout to 50m, above the 45m"},
            {%{"limits" => %{"max_memory_bytes" => 67_108_864}}, "limits.max_memory_bytes"},
            {%{"limits" => %{"rate_limit" => %{"requests" => 61}}}, "61 requests, above"},
            {%{"limits" => %{"rate_limit" => %{"window" => "30s"}}}, "a faster rate"}
          ] do
        assert {:error, {:invalid_argument, why}} = preview(ctx, %{@ref => subset}),
               "#{inspect(subset)} was accepted"

        assert why =~ fragment, "#{inspect(subset)}: #{why}"
        assert why =~ @ref
      end
    end

    test "a path spelled other than the storage door reaches it is refused", %{ctx: ctx} do
      for path <- ["data//reports/", "data/./reports/", "data/reports//"] do
        assert {:error, {:invalid_argument, why}} =
                 preview(ctx, %{@ref => %{"storage" => %{"paths" => [path]}}}),
               "#{path} was accepted"

        assert why =~ "storage path #{path}", why
      end
    end

    test "the commit refuses it as the preview does", %{ctx: ctx} do
      {:ok, plan} = Plan.plan(ctx, %{ref: @ref})
      {:ok, preview} = Commit.preview(ctx, %{ref: @ref})
      wider = %{@ref => %{"egress" => %{"domains" => ["api.three.example"]}}}

      assert {:error, {:invalid_argument, _why}} =
               Commit.commit(ctx, %{
                 decisions: %{ref: @ref, subset: wider},
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: 0
               })

      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @ref)
    end

    test "a limit lies under the ceiling as well as the ask", %{ctx: ctx} do
      # The ask's 45m is above the compiled ceiling's 30m, so 40m is inside
      # the ask and still refused.
      assert {:error, {:invalid_argument, why}} =
               preview(ctx, %{@ref => %{"limits" => %{"timeout" => "40m"}}})

      assert why =~ "limits.timeout above the platform ceiling"

      assert {:ok, _} = preview(ctx, %{@ref => %{"limits" => %{"timeout" => "30m"}}})

      # An operator's lowered ceiling bounds a narrowing too.
      Application.put_env(:sanctum, :platform_ceiling, %{max_concurrent_tasks: 4})

      assert {:error, {:invalid_argument, why}} =
               preview(ctx, %{@ref => %{"limits" => %{"max_concurrent_tasks" => 8}}})

      assert why =~ "max_concurrent_tasks above the platform ceiling"
      assert {:ok, _} = preview(ctx, %{@ref => %{"limits" => %{"max_concurrent_tasks" => 4}}})
    end

    test "zero is refused where it bounds nothing, and kept where it means none",
         %{ctx: ctx} do
      for limits <- [
            %{"max_memory_bytes" => 0},
            %{"max_request_size" => 0},
            %{"max_response_size" => 0},
            %{"timeout" => "0s"},
            %{"batch_timeout" => "0ms"},
            %{"rate_limit" => %{"window" => "0s"}}
          ] do
        assert {:error, {:invalid_argument, why}} = preview(ctx, %{@ref => %{"limits" => limits}}),
               "#{inspect(limits)} was accepted"

        assert why =~ "zero"
      end

      # No task spawned, and no request admitted: each a bound its
      # enforcement point reads.
      assert {:ok, _} = preview(ctx, %{@ref => %{"limits" => %{"max_concurrent_tasks" => 0}}})

      assert {:ok, _} =
               preview(ctx, %{@ref => %{"limits" => %{"rate_limit" => %{"requests" => 0}}}})
    end
  end

  describe "a node whose stored manifest does not decode" do
    test "refuses its ask as that damage, never asking for nothing" do
      ref = "reagent:local.ask-damaged"
      rows = %{ref => %{manifest: ~s({"name": "ask-damaged",)}}

      assert {:error, {:corrupt, {:manifest, ^ref}}} = BlobBuilder.ask_rows(rows)
    end
  end

  describe "an ask that names every tool" do
    setup %{ctx: ctx} do
      publish!(ctx, "narrow-every", %{"caps" => %{"tools" => ["*"]}})
      {:ok, ref: "reagent:local.narrow-every"}
    end

    test "is one wildcard row as the grant states it, in the plan and the preview",
         %{ctx: ctx, ref: ref} do
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert [%{"values" => %{"tools" => ["*"]}, "narrowed" => false}] =
               Enum.filter(plan.rows, &(&1["kind"] == "tools"))

      # The ask still grants the whole catalog it expands to.
      assert length(plan.caps["tools"]) > 1

      {:ok, preview} = preview(ctx, %{}, ref)
      assert %{narrowed: false, values: %{"tools" => ["*"]}} = rows(preview)[{:tools, ref}]
    end

    test "narrowed, it is the tools the grant holds, never the wildcard", %{ctx: ctx, ref: ref} do
      {:ok, none} = preview(ctx, %{ref => %{"tools" => []}}, ref)
      assert %{narrowed: true, values: %{"tools" => []}} = rows(none)[{:tools, ref}]

      {:ok, one} = preview(ctx, %{ref => %{"tools" => ["execution.run"]}}, ref)
      assert %{narrowed: true, values: %{"tools" => ["execution.run"]}} = rows(one)[{:tools, ref}]
    end
  end

  describe "a kind its enforcement point cannot narrow" do
    test "is refused, never granted as narrowed", %{ctx: ctx} do
      for kind <- ~w(credential tool_servers frame streams system_actions) do
        assert {:error, {:invalid_argument, why}} = preview(ctx, %{@ref => %{kind => %{}}})
        assert why =~ "#{kind} cannot be narrowed; it is granted whole or not at all"
      end
    end

    test "and a node outside the consent graph is refused", %{ctx: ctx} do
      assert {:error, {:invalid_argument, why}} =
               preview(ctx, %{"reagent:local.elsewhere" => %{"tools" => []}})

      assert why =~ "not a component of this grant's consent graph"
    end
  end

  describe "a dependency's narrowing" do
    test "every edge into the narrowed node carries it", %{ctx: ctx} do
      publish!(ctx, "narrow-dep", %{
        "caps" => %{"egress" => %{"domains" => ["a.dep.example", "b.dep.example"]}}
      })

      publish!(ctx, "narrow-root", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      root = "reagent:local.narrow-root"
      subset = %{@dep => %{"egress" => %{"domains" => ["a.dep.example"]}}}

      {:ok, preview} = preview(ctx, subset, root)

      assert %{narrowed: true, values: %{"domains" => ["a.dep.example"]}} =
               rows(preview)[{:egress, @dep}]

      walk!(ctx, subset, root)
      {:ok, authority} = Opus.authority_for(ctx, :default, root)
      {:ok, edge} = Blob.lookup_edge(authority.policy, root, @dep, "")
      assert edge.egress.domains == ["a.dep.example"]
    end
  end

  describe "a public profile's narrowing" do
    test "narrows what the owner's grant gives, never beyond it", %{ctx: ctx} do
      walk!(ctx, %{@ref => %{"egress" => %{"domains" => ["api.one.example"]}}})
      {:ok, [owner]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @ref)
      {:ok, staged} = Commit.stage_publish(ctx, %{profile_id: owner.id})

      # The owner's grant, not the component's ask, is what a public twin
      # may narrow.
      wider = %{@ref => %{"egress" => %{"domains" => ["api.b.two.example"]}}}

      assert {:error, {:invalid_argument, _why}} =
               Commit.preview(ctx, Map.put(staged.decisions, :subset, wider))

      narrower = %{@ref => %{"storage" => %{"actions" => ["list"]}}}
      decisions = Map.put(staged.decisions, :subset, narrower)
      {:ok, preview} = Commit.preview(ctx, decisions)

      assert %{narrowed: true, values: %{"actions" => ["list"]}} = rows(preview)[{:storage, @ref}]

      assert {:ok, %{profile_id: public_id}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: staged.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: staged.expected_consent_revision
               })

      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), public_id)
      ingress = Jason.decode!(head.resolved_policy)["nodes"][@ref]["edges"]["@ingress"]
      assert ingress["storage"]["actions"] == ["list"]
      assert ingress["egress"]["domains"] == ["api.one.example"]
    end
  end

  describe "a binding's key" do
    test "is the place a bound vault sits; a selection carries none until it resolves",
         %{ctx: ctx} do
      publish!(ctx, "narrow-dep", %{})
      publish!(ctx, "narrow-root", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      root = "reagent:local.narrow-root"

      bound = %{
        "entry_id" => "vlt_1",
        "binding_digest" => "sha256:b",
        "scope" => "athanor",
        "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"}
      }

      build = fn edge_vault ->
        {:ok, nodes} =
          BlobBuilder.build(
            ctx,
            graph!(ctx, root),
            root,
            fn node, _row, _manifest -> if node == root, do: bound end,
            edge_vault_fn: fn _from, _dep, _row, _manifest, _provided -> edge_vault end
          )

        {:ok, json} = BlobBuilder.encode(nodes)
        {:ok, blob} = Blob.parse(json)
        blob
      end

      blob = build.(bound)
      {:ok, ingress} = Blob.ingress(blob, root)
      assert ingress.vault.binding_key == "#{root}|@ingress|default"
      {:ok, edge} = Blob.lookup_edge(blob, root, @dep, "")
      assert edge.vault.binding_key == "#{root}|#{@dep}|default"

      blob = build.(%{"via" => %{"label" => "default"}})
      {:ok, edge} = Blob.lookup_edge(blob, root, @dep, "")
      assert edge.vault == %{via: %{label: "default", binding_digest: nil}}
    end

    test "keys one row per binding: an entry's names the entry, a selection's its label and pin",
         %{ctx: ctx} do
      publish!(ctx, "narrow-dep", %{})
      publish!(ctx, "narrow-root", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      root = "reagent:local.narrow-root"

      bound = %{
        "entry_id" => "vlt_1",
        "binding_digest" => "sha256:b",
        "scope" => "athanor",
        "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"}
      }

      refs = fn edge_vault ->
        {:ok, nodes} =
          BlobBuilder.build(
            ctx,
            graph!(ctx, root),
            root,
            fn node, _row, _manifest -> if node == root, do: bound end,
            edge_vault_fn: fn _from, _dep, _row, _manifest, _provided -> edge_vault end
          )

        BlobBuilder.vault_refs(nodes)
      end

      # A resource that records no decision stands until revoked.
      ingress = %{
        binding_key: "#{root}|@ingress|default",
        scope: "athanor",
        vault_entry_id: "vlt_1",
        binding_digest: "sha256:b",
        lifetime_kind: "standing",
        expires_at: nil,
        renew: false
      }

      edge_key = "#{root}|#{@dep}|default"

      # One entry bound on two edges is two rows, one per place.
      assert refs.(bound) == [ingress, %{ingress | binding_key: edge_key}]

      # A selection is the borrower's own binding: its row names the label
      # it borrows and the digest it pinned, or none, and never an entry.
      for {via, pin} <- [
            {%{"label" => "work", "binding_digest" => "sha256:lent"}, "sha256:lent"},
            {%{"label" => "work"}, nil}
          ] do
        assert refs.(%{"via" => via}) == [
                 ingress,
                 %{
                   binding_key: edge_key,
                   scope: "athanor",
                   via_label: "work",
                   binding_digest: pin,
                   lifetime_kind: "standing",
                   expires_at: nil,
                   renew: false
                 }
               ]
      end

      # An edge holding no vault is no row.
      assert refs.(nil) == [ingress]
    end

    test "named accounts are rows of their own, each with its decision's lifetime and renew, " <>
           "an instance entry's row names it, and provided configuration is no row",
         %{ctx: ctx} do
      publish!(ctx, "narrow-dep", %{})
      publish!(ctx, "narrow-root", %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      root = "reagent:local.narrow-root"
      until = ~U[2026-10-05 10:00:00Z]

      binding = fn entry_id, over ->
        Map.merge(
          %{
            entry_id: entry_id,
            binding_digest: "sha256:" <> entry_id,
            scope: "athanor",
            destination: %{"hosts" => ["api.example.com"], "scheme" => "https"},
            attach: %{"in" => "header", "name" => "x-api-key", "template" => "{value}"},
            fields: %{"KEY" => "KEY"},
            scopes: []
          },
          over
        )
      end

      source =
        BlobBuilder.vault_resource(
          binding.("vlt_default", %{
            named: [
              binding.("vlt_one", %{name: "Supabase 1", lifetime: %{kind: "until", until: until}}),
              binding.("ine_two", %{
                name: "Supabase 2",
                scope: "instance",
                lifetime: %{kind: "once", until: nil},
                renew: true
              })
            ]
          })
        )

      provided =
        BlobBuilder.vault_resource(%{
          provided: %{
            destination: %{"hosts" => ["abc.supabase.co"], "scheme" => "https"},
            values: %{"anon_key" => "eyJ-public"},
            attach: %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          }
        })

      {:ok, nodes} =
        BlobBuilder.build(
          ctx,
          graph!(ctx, root),
          root,
          fn node, _row, _manifest -> if node == root, do: source end,
          edge_vault_fn: fn _from, _dep, _row, _manifest, _provided -> provided end
        )

      key = fn slot -> "#{root}|@ingress|#{slot}" end

      assert BlobBuilder.vault_refs(nodes) == [
               %{
                 binding_key: key.("default"),
                 scope: "athanor",
                 vault_entry_id: "vlt_default",
                 binding_digest: "sha256:vlt_default",
                 lifetime_kind: "standing",
                 expires_at: nil,
                 renew: false
               },
               %{
                 binding_key: key.("name:Supabase 1"),
                 scope: "athanor",
                 vault_entry_id: "vlt_one",
                 binding_digest: "sha256:vlt_one",
                 lifetime_kind: "until",
                 expires_at: until,
                 renew: false
               },
               %{
                 binding_key: key.("name:Supabase 2"),
                 scope: "instance",
                 instance_entry_id: "ine_two",
                 binding_digest: "sha256:ine_two",
                 lifetime_kind: "once",
                 expires_at: nil,
                 renew: true
               }
             ]

      # The blob names each binding's place and none of its lifetime; the
      # provided configuration rides the dependency's edge as it is.
      {:ok, json} = BlobBuilder.encode(nodes)
      refute json =~ "__decision__"
      refute json =~ "until"
      {:ok, blob} = Blob.parse(json)
      {:ok, ingress} = Blob.ingress(blob, root)

      assert %{"Supabase 1" => %{binding_key: one}, "Supabase 2" => %{scope: "instance"}} =
               ingress.vault.named

      assert one == key.("name:Supabase 1")
      {:ok, edge} = Blob.lookup_edge(blob, root, @dep, "")
      assert %{provided: %{values: %{"anon_key" => "eyJ-public"}}} = edge.vault
    end
  end

  describe "provided/3" do
    @dep_needs %{
      "needs" => %{
        "database" => %{
          "type" => "api_key:supabase.co",
          "hosts" => ["abc.supabase.co"],
          "reason" => "to reach the database",
          "fields" => ["anon_key"],
          "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
        },
        "signing" => %{
          "type" => "api_key:supabase.co",
          "hosts" => ["abc.supabase.co"],
          "reason" => "to sign",
          "fields" => ["secret"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["abc.supabase.co"]}}
    }

    test "covers a need the dependency declares with an attach rule, and nothing else" do
      entry = %{"destination" => %{"hosts" => ["abc.supabase.co"]}, "values" => %{"k" => "v"}}

      app = %{
        "dependencies" => %{"static" => ["reagent:local.db:1.0.0"]},
        "provides" => %{
          "reagent:local.db:1.0.0" => %{
            "database" => entry,
            "signing" => entry,
            "absent" => entry
          }
        }
      }

      assert %{covered: [{"database", resource}], unprovidable: unprovidable} =
               BlobBuilder.provided(app, "reagent:local.db", @dep_needs)

      assert unprovidable == [{"absent", :undeclared}, {"signing", :no_attach}]

      # Beside the resource rides the need it fills, which `encode/1` reads
      # for the edge's flows and writes into no blob.
      assert Map.delete(resource, "__decision__") == %{
               "provided" => %{
                 "destination" => %{"hosts" => ["abc.supabase.co"], "scheme" => "https"},
                 "values" => %{"k" => "v"},
                 "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
               }
             }

      # Another dependency's block covers nothing here.
      assert %{covered: [], unprovidable: []} =
               BlobBuilder.provided(app, "reagent:local.other", @dep_needs)
    end
  end

  describe "narrow/5" do
    test "answers the ask unchanged, and nothing narrowed, for no narrowing" do
      resources = %{"tools" => ["execution.run"]}
      limits = %{"timeout" => "1m"}

      assert {:ok, ^resources, ^limits, []} =
               BlobBuilder.narrow(@ref, resources, limits, nil, %{})
    end

    test "an empty narrowing of a kind the ask does not carry leaves it absent" do
      assert {:ok, %{"tools" => []}, nil, []} =
               BlobBuilder.narrow(
                 @ref,
                 %{"tools" => []},
                 nil,
                 %{"egress" => %{"domains" => []}, "storage" => %{"paths" => []}},
                 %{}
               )
    end
  end

  describe "flows" do
    @flow_ref "reagent:local.flow-source"
    @flow_caps %{
      "egress" => %{"domains" => ["api.one.example", "*.two.example"], "methods" => ["GET"]},
      "flows" => [
        %{"from" => "pinned", "to" => "api.one.example"},
        %{"from" => "filed", "to" => "api.one.example"},
        %{"from" => "outside", "to" => "*.two.example"},
        %{"from" => "vault_disclosed", "to" => "server:forecasts"}
      ]
    }

    setup %{ctx: ctx} do
      publish!(ctx, "flow-source", %{"caps" => @flow_caps})
      :ok
    end

    defp flow(from, to), do: %{"from" => from, "to" => to}

    # The preview's exits rows of the source, by exit: the classes and
    # whether the narrowing narrowed them.
    defp exits(rows) do
      for %{"kind" => "exits", "node" => @flow_ref, "values" => values} = row <- rows,
          into: %{},
          do: {values["exit"], {values["flows"], row["narrowed"]}}
    end

    defp head_flows!(ctx, profile_id) do
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)
      {:ok, blob} = Blob.parse(head.resolved_policy)
      {:ok, ingress} = Blob.ingress(blob, @flow_ref)
      Blob.Edge.flows(ingress)
    end

    test "a host narrowed under a declared pattern shows the pattern's flows it inherits, as the committed grant lets them reach it",
         %{ctx: ctx} do
      host = "api.b.two.example"
      subset = %{@flow_ref => %{"egress" => %{"domains" => [host]}}}
      {:ok, plan} = Plan.plan(ctx, %{ref: @flow_ref})
      {:ok, preview} = preview(ctx, subset, @flow_ref)
      %{profile_id: profile_id} = walk!(ctx, subset, @flow_ref)

      committed = head_flows!(ctx, profile_id)

      assert Prima.Flow.uncovered([Prima.Source.outside(nil)], {:domain, host}, flows: committed) ==
               []

      row = Enum.find(preview.rows, &(get_in(&1, ["values", "exit"]) == host))
      assert row["values"]["flows"] == ["outside"]

      html =
        Phoenix.LiveViewTest.render_component(PrismWeb.ConsentSheetComponent,
          id: "narrowed-exit",
          ref: @flow_ref,
          walk: %{
            ref: @flow_ref,
            plan: plan,
            preview: preview,
            decisions: %{"ref" => @flow_ref, "subset" => subset}
          },
          context: ctx
        )

      text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-row="exits"][data-exit="#{host}"]))
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")

      assert text =~ "outside"
      refute text =~ "nothing it reads"
    end

    test "the plan asks every flow declared; the grant keeps those its edge binds, and runs them",
         %{ctx: ctx} do
      {:ok, plan} = Plan.plan(ctx, %{ref: @flow_ref})

      assert exits(plan.rows) == %{
               "*.two.example" => {["outside"], false},
               "api.one.example" => {["pinned", "filed"], false},
               "server:forecasts" => {["vault_disclosed"], false}
             }

      # The grant binds no tool server, so the flow to one is not kept,
      # and the exit is not drawn.
      {:ok, preview} = preview(ctx, %{}, @flow_ref)

      assert exits(preview.rows) == %{
               "*.two.example" => {["outside"], false},
               "api.one.example" => {["pinned", "filed"], false}
             }

      %{profile_id: profile_id} = walk!(ctx, %{}, @flow_ref)

      assert head_flows!(ctx, profile_id) == [
               %{from: :pinned, to: "api.one.example"},
               %{from: :filed, to: "api.one.example"},
               %{from: :outside, to: "*.two.example"}
             ]

      {:ok, authority} = Opus.authority_for(ctx, :default, @flow_ref)
      assert Blob.Edge.flows(authority.resources) == head_flows!(ctx, profile_id)
      # A flow grants no exit: the egress is the ask's, no wider.
      assert authority.resources.egress.domains == ["*.two.example", "api.one.example"]
    end

    test "a narrowing keeps the flows it names; none named keeps all, an empty one keeps none",
         %{ctx: ctx} do
      kept = %{@flow_ref => %{"exits" => [flow("pinned", "api.one.example")]}}
      {:ok, preview} = preview(ctx, kept, @flow_ref)

      assert exits(preview.rows) == %{
               "*.two.example" => {[], true},
               "api.one.example" => {["pinned"], true}
             }

      %{profile_id: profile_id} = walk!(ctx, kept, @flow_ref)
      assert head_flows!(ctx, profile_id) == [%{from: :pinned, to: "api.one.example"}]

      {:ok, none} = preview(ctx, %{@flow_ref => %{"exits" => []}}, @flow_ref)

      assert exits(none.rows) == %{
               "*.two.example" => {[], true},
               "api.one.example" => {[], true}
             }

      %{profile_id: none_id} = walk!(ctx, %{@flow_ref => %{"exits" => []}}, @flow_ref)
      assert head_flows!(ctx, none_id) == []
    end

    test "a flow nobody asked for is refused, never granted", %{ctx: ctx} do
      for flows <- [
            [flow("vault_disclosed", "api.one.example")],
            [flow("pinned", "other.example")],
            [flow("pinned", "api.b.two.example")],
            [flow("pinned", "api.one.example"), flow("outside", "need:api_key")]
          ] do
        assert {:error, {:invalid_argument, why}} =
                 preview(ctx, %{@flow_ref => %{"exits" => flows}}, @flow_ref),
               inspect(flows)

        assert why =~ "does not ask for"
      end

      for malformed <- [[flow("unsettled", "api.one.example")], [%{"from" => "pinned"}], "all"] do
        assert {:error, {:invalid_argument, why}} =
                 preview(ctx, %{@flow_ref => %{"exits" => malformed}}, @flow_ref),
               inspect(malformed)

        assert why =~ "exits"
      end
    end

    test "a domain the egress narrowing drops takes its flows; a host under a pattern keeps " <>
           "the pattern's",
         %{ctx: ctx} do
      subset = %{@flow_ref => %{"egress" => %{"domains" => ["api.b.two.example"]}}}
      {:ok, preview} = preview(ctx, subset, @flow_ref)

      assert exits(preview.rows) == %{
               "*.two.example" => {["outside"], false},
               "api.b.two.example" => {["outside"], false}
             }

      %{profile_id: profile_id} = walk!(ctx, subset, @flow_ref)
      assert head_flows!(ctx, profile_id) == [%{from: :outside, to: "*.two.example"}]
    end

    test "equal narrowings are one digest, a changed flow another, and an old proof commits " <>
           "no changed flow",
         %{ctx: ctx} do
      one = flow("pinned", "api.one.example")
      two = flow("outside", "*.two.example")

      {:ok, plain} = preview(ctx, %{}, @flow_ref)
      {:ok, both} = preview(ctx, %{@flow_ref => %{"exits" => [one, two]}}, @flow_ref)
      {:ok, again} = preview(ctx, %{@flow_ref => %{"exits" => [two, one, two]}}, @flow_ref)
      {:ok, fewer} = preview(ctx, %{@flow_ref => %{"exits" => [one]}}, @flow_ref)
      {:ok, other} = preview(ctx, %{@flow_ref => %{"exits" => [two]}}, @flow_ref)

      # Ordering and repetition are one decision; each other set of flows,
      # and the whole ask, is its own.
      assert both.commit_digest == again.commit_digest
      digests = Enum.map([plain, both, fewer, other], & &1.commit_digest)
      assert length(Enum.uniq(digests)) == 4

      # A decision previewed with two flows does not commit one.
      {:ok, plan} = Plan.plan(ctx, %{ref: @flow_ref})

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: %{ref: @flow_ref, subset: %{@flow_ref => %{"exits" => [one]}}},
                 plan_token: plan.plan_token,
                 proof: both.proof,
                 commit_digest: both.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })
    end
  end

  describe "a public profile's flows" do
    setup %{ctx: ctx} do
      publish!(ctx, "flow-source", %{"caps" => @flow_caps})
      :ok
    end

    test "are the owner's, narrowed only within them", %{ctx: ctx} do
      owner_kept = [flow("pinned", "api.one.example"), flow("outside", "*.two.example")]
      walk!(ctx, %{@flow_ref => %{"exits" => owner_kept}}, @flow_ref)
      {:ok, [owner]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), @flow_ref)
      {:ok, staged} = Commit.stage_publish(ctx, %{profile_id: owner.id})

      # A flow the manifest asks but the owner's grant does not hold is no
      # narrowing of the twin.
      wider = %{@flow_ref => %{"exits" => [flow("filed", "api.one.example")]}}

      assert {:error, {:invalid_argument, why}} =
               Commit.preview(ctx, Map.put(staged.decisions, :subset, wider))

      assert why =~ "does not ask for"

      narrower = %{@flow_ref => %{"exits" => [flow("outside", "*.two.example")]}}
      decisions = Map.put(staged.decisions, :subset, narrower)
      {:ok, preview} = Commit.preview(ctx, decisions)

      assert exits(preview.rows) == %{
               "*.two.example" => {["outside"], false},
               "api.one.example" => {[], true}
             }

      assert {:ok, %{profile_id: public_id}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: staged.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: staged.expected_consent_revision
               })

      assert head_flows!(ctx, public_id) == [%{from: :outside, to: "*.two.example"}]
    end
  end

  describe "an edge's flows, as encode/1 writes them" do
    @dep_ref "reagent:local.flow-dep"

    defp json(flows), do: Prima.Flow.to_json(flows)

    defp flows(edge), do: elem(Prima.Flow.parse(edge["flows"], :any), 1)

    defp bound(need) do
      BlobBuilder.vault_resource(%{
        entry_id: "ent_1",
        binding_digest: "sha256:" <> String.duplicate("a", 64),
        scope: "athanor",
        destination: %{"hosts" => ["api.one.example"], "scheme" => "https"},
        attach: nil,
        fields: %{"api_key" => "api_key"},
        scopes: [],
        need: need
      })
    end

    test "keep a need flow where the edge fills that need and a server flow where it grants " <>
           "that server" do
      asked = [
        %{from: :pinned, to: "api.one.example"},
        %{from: :vault_disclosed, to: "need:api_key"},
        %{from: :vault_disclosed, to: "need:other"},
        %{from: :outside, to: "server:github"},
        %{from: :outside, to: "server:elsewhere"}
      ]

      server = %{
        "server_digest" => "sha256:srv",
        "server_name" => "github",
        "tool_patterns" => []
      }

      limits = Prima.Limits.to_map(Prima.Limits.defaults(:reagent))

      nodes = %{
        @ref => %{
          limits: limits,
          resources: %{"flows" => json(asked), "__vault__" => bound("api_key")},
          edges: %{
            "@ingress" => %{
              "flows" => json(asked),
              "tool_servers" => [server],
              "__vault__" => bound("api_key")
            },
            @dep_ref => %{"__dep__" => @dep_ref, "__vault__" => nil}
          }
        },
        @dep_ref => %{
          limits: limits,
          resources: %{"flows" => json(asked), "__vault__" => nil},
          edges: %{}
        }
      }

      {:ok, encoded} = BlobBuilder.encode(nodes)
      edges = Jason.decode!(encoded)["nodes"][@ref]["edges"]

      assert flows(edges["@ingress"]) == [
               %{from: :pinned, to: "api.one.example"},
               %{from: :vault_disclosed, to: "need:api_key"},
               %{from: :outside, to: "server:github"}
             ]

      # The dependency's edge fills no need and grants no server.
      assert flows(edges[@dep_ref]) == [%{from: :pinned, to: "api.one.example"}]

      # The blob parses, and no edge writes an empty flow list.
      assert {:ok, _blob} = Blob.parse(encoded)

      {:ok, no_flows} =
        BlobBuilder.encode(%{
          @ref => %{
            limits: %{},
            resources: %{},
            edges: %{"@ingress" => %{"flows" => json([%{from: :pinned, to: "need:x"}])}}
          }
        })

      refute Map.has_key?(Jason.decode!(no_flows)["nodes"][@ref]["edges"]["@ingress"], "flows")
    end

    test "a provided configuration fills its need, and keeps that need's flows" do
      app = %{
        "dependencies" => %{"static" => ["reagent:local.db:1.0.0"]},
        "provides" => %{
          "reagent:local.db:1.0.0" => %{
            "database" => %{
              "destination" => %{"hosts" => ["abc.supabase.co"]},
              "values" => %{"k" => "v"}
            }
          }
        }
      }

      %{covered: [{"database", resource}]} =
        BlobBuilder.provided(app, "reagent:local.db", @dep_needs)

      asked = [%{from: :filed, to: "need:database"}, %{from: :filed, to: "need:signing"}]

      {:ok, encoded} =
        BlobBuilder.encode(%{
          @ref => %{
            limits: %{},
            resources: %{},
            edges: %{"@ingress" => %{"flows" => json(asked), "__vault__" => resource}}
          }
        })

      ingress = Jason.decode!(encoded)["nodes"][@ref]["edges"]["@ingress"]
      assert flows(ingress) == [%{from: :filed, to: "need:database"}]
      assert ingress["vault"]["provided"]["values"] == %{"k" => "v"}
    end
  end

  # The closure the activation resolves for `root`, at the release digests
  # it records: the builder reads every node at the release the closure
  # resolved.
  defp graph!(ctx, root) do
    {:ok, ref} = Prima.ComponentRef.parse(root)
    {:ok, row} = Sanctum.Consent.Components.get_latest(ctx, ref.name, ref.namespace, ref.type)
    {:ok, %{graph: graph}} = Sanctum.Consent.Components.resolve(ctx, row)
    graph
  end
end
