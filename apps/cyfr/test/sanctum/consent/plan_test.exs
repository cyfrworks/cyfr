# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.PlanTest do
  @moduledoc """
  The plan answers the ask as `Prima.ConsentPreview` rows: one per resource
  each node of the closure asks for, its limits, and a tincture's frame,
  streams, cards and system actions, none narrowed, in one order; with the
  origins a decision that names none admits, `interactive` alone.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Prima.ConsentPreview
  alias Sanctum.Consent.Plan
  alias Sanctum.Test.ConsentFixtures

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @dep "reagent:local.plan-dep"
  @source "reagent:local.plan-source"
  # The plan binds no commit digest; decoding its rows as a preview needs one.
  @placeholder_digest "sha256:" <> String.duplicate("0", 64)

  # The installed catalog, answering as it does, that runs `fun` once at the
  # `at`th catalog read the caller of `run/3` makes: state moving at a
  # chosen point inside one call.
  defmodule RacingGrimoire do
    @moduledoc false
    @behaviour Sanctum.Grimoire

    def run(at, fun, call) do
      Process.put(__MODULE__, {0, at, fun})

      try do
        answer = call.()
        {reads, _at, _fun} = Process.get(__MODULE__)
        {answer, reads}
      after
        Process.delete(__MODULE__)
      end
    end

    @impl true
    def tool_actions do
      case Process.get(__MODULE__) do
        {reads, at, fun} ->
          Process.put(__MODULE__, {reads + 1, at, fun})
          if reads + 1 == at, do: fun.()

        nil ->
          :ok
      end

      real().tool_actions()
    end

    @impl true
    def action_declaration(name), do: real().action_declaration(name)

    @impl true
    def providers_loaded, do: real().providers_loaded()

    @impl true
    def tool_server_candidates(ctx), do: real().tool_server_candidates(ctx)

    @impl true
    def tool_server_candidate(ctx, name), do: real().tool_server_candidate(ctx, name)

    defp real, do: :persistent_term.get({__MODULE__, :real})
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_plan_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.isolate!()

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, version, manifest) do
    manifest =
      Map.merge(manifest, %{
        "name" => name,
        "type" => "reagent",
        "version" => version,
        "publisher" => "local"
      })

    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "reagent", "local", name, version,
        manifest: manifest,
        wasm: @wasm
      )

    component
  end

  # A tincture row written as the registry holds one, so a declaration the
  # provider roster does not serve (a stream subject) can still be asked for.
  defp tincture!(ctx, name, version, declaration) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => version,
      "publisher" => "local",
      "tincture" => Map.put(declaration, "entry", "index.html")
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name <> version), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: version,
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    Arca.Cache.delete_match(:_)
    "tincture:local.#{name}"
  end

  defp decode!(rows) do
    {:ok, preview} =
      ConsentPreview.decode(%{
        "v" => ConsentPreview.version(),
        "rows" => rows,
        "origins" => ["interactive"],
        "commit_digest" => @placeholder_digest,
        "removed" => []
      })

    preview.rows
  end

  defp by_kind(rows), do: Enum.group_by(rows, &{&1.kind, &1.node}, & &1.values)

  describe "the ask as rows" do
    setup %{ctx: ctx} do
      publish!(ctx, "plan-dep", "1.0.0", %{
        "caps" => %{
          "egress" => %{"domains" => ["api.dep.example"], "methods" => ["GET"]},
          "storage" => %{"paths" => ["data/dep/"], "actions" => ["read", "list"]}
        }
      })

      publish!(ctx, "plan-source", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => @dep}]},
        "caps" => %{"tools" => ["execution.run"], "limits" => %{"timeout" => "30s"}}
      })

      :ok
    end

    test "every node of the closure, none narrowed, admitting interactive alone", %{ctx: ctx} do
      {:ok, plan} = Plan.plan(ctx, %{ref: @source})

      assert plan.origins == ["interactive"]
      assert Plan.default_origins() == [:interactive]

      rows = decode!(plan.rows)
      grouped = by_kind(rows)

      assert grouped[{:egress, @dep}] == [
               %{
                 "domains" => ["api.dep.example"],
                 "methods" => ["GET"],
                 "schemes" => ["https"],
                 "private_ips" => []
               }
             ]

      assert grouped[{:storage, @dep}] == [
               %{"paths" => ["data/dep/"], "actions" => ["list", "read"]}
             ]

      assert grouped[{:tools, @source}] == [%{"tools" => ["execution.run"]}]
      assert [%{"timeout" => "30s"}] = grouped[{:limits, @source}]
      assert [%{"timeout" => _}] = grouped[{:limits, @dep}]

      # What a node does not ask for has no row; no entry is chosen yet.
      refute Map.has_key?(grouped, {:egress, @source})
      refute Map.has_key?(grouped, {:tools, @dep})
      refute Enum.any?(rows, &(&1.kind in [:credential, :tool_servers]))
      refute Enum.any?(rows, & &1.narrowed)
    end

    test "the rows come in one order: by node, then by kind", %{ctx: ctx} do
      {:ok, plan} = Plan.plan(ctx, %{ref: @source})
      kinds = Enum.map(ConsentPreview.kinds(), &Atom.to_string/1)

      order =
        Enum.map(plan.rows, fn row ->
          {row["node"], Enum.find_index(kinds, &(&1 == row["kind"]))}
        end)

      assert order == Enum.sort(order)

      # And a second plan answers the same rows.
      {:ok, again} = Plan.plan(ctx, %{ref: @source})
      assert again.rows == plan.rows
    end

    test "the rows are the grant the builder would freeze", %{ctx: ctx} do
      {:ok, plan} = Plan.plan(ctx, %{ref: @source})
      [source_limits] = by_kind(decode!(plan.rows))[{:limits, @source}]

      assert source_limits == plan.limits
      assert %{"tools" => tools} = plan.caps
      assert by_kind(decode!(plan.rows))[{:tools, @source}] == [%{"tools" => tools}]
    end
  end

  # `profile.plan` as an MCP client calls it, under a request of its own:
  # the response the client receives (the router's answer encoded as
  # `Emissary.Web.MCPController` encodes it).
  defp plan_over_mcp(ctx, ref) do
    ctx = %{ctx | request_id: Prima.UUID7.request_id()}

    answer =
      Emissary.MCP.Router.dispatch(ctx, %Prima.MCP.Message{
        type: :request,
        id: 1,
        method: "tools/call",
        params: %{"name" => "profile", "arguments" => %{"action" => "plan", "ref" => ref}}
      })

    case answer do
      {:ok, result} -> Prima.MCP.Message.encode_result(1, result)
      {:error, code, message} -> Prima.MCP.Message.encode_error(1, code, message)
    end
  end

  # What the head of `ref`'s profile grants `node`: its resources, as the
  # node's edge in the stored policy grants them, and its limits.
  defp held(ctx, ref, node) do
    {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, ref)
    {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
    %{"nodes" => nodes} = Jason.decode!(head.resolved_policy)

    %{
      resources: Sanctum.Consent.BlobBuilder.node_resources(nodes, ref, node),
      limits: get_in(nodes, [node, "limits"])
    }
  end

  defp commit!(ctx, ref, over) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, over)
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  describe "what the head holds" do
    test "a first grant has no head: no origins of its own and no delta", %{ctx: ctx} do
      publish!(ctx, "plan-first", "1.0.0", %{})
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-first"})
      assert plan.head_origins == nil
      assert plan.shape_diff == []
      assert plan.head_narrowing == %{}
    end

    # What a re-grant keeps (`Plan.head_narrowing/4`): the head's narrowing
    # against the ask as it stands, which the grant sheet opens on.
    test "a re-grant answers the narrowing its head holds, and a method newly asked for " <>
           "falls outside it",
         %{ctx: ctx} do
      ref = "reagent:local.plan-narrowed"

      ask = fn methods ->
        %{"caps" => %{"egress" => %{"domains" => ["api.narrowed.example"], "methods" => methods}}}
      end

      publish!(ctx, "plan-narrowed", "1.0.0", ask.(["GET", "POST"]))
      get_only = %{ref => %{"egress" => %{"methods" => ["GET"]}}}

      # A head no narrowing touched holds none.
      commit!(ctx, ref, %{})
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert plan.head_narrowing == %{}

      commit!(ctx, ref, %{subset: get_only})
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert plan.head_narrowing == get_only

      # The profile tool carries it, to the console and to a client.
      assert {:ok, %{head_narrowing: ^get_only}} =
               Sanctum.Providers.Profile.handle(ctx, %{"action" => "plan", "ref" => ref})

      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               plan_over_mcp(ctx, ref)

      assert %{"head_narrowing" => ^get_only} = Jason.decode!(text)

      # A release asking for PUT too: the head never granted it, so it lies
      # outside the narrowing, which names the methods the head grants.
      publish!(ctx, "plan-narrowed", "1.1.0", ask.(["GET", "POST", "PUT"]))
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert plan.head_narrowing == get_only
    end

    # A stored policy that does not decode leaves the head's narrowing
    # unknown: planned as none, a re-grant would open wider than its head.
    test "a stored policy that cannot be read refuses the plan as the damaged profile it is",
         %{ctx: ctx} do
      ref = "reagent:local.plan-unread-policy"
      publish!(ctx, "plan-unread-policy", "1.0.0", %{})
      commit!(ctx, ref, %{})
      {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, ref)

      :ok = ConsentFixtures.hand_edit_head!(ctx, profile_id, resolved_policy: "not a blob")

      assert Plan.plan(ctx, %{ref: ref}) == {:error, {:corrupt, {:profile, profile_id}}}

      assert Sanctum.Providers.Profile.handle(ctx, %{"action" => "plan", "ref" => ref}) ==
               {:error, {:corrupt, {:profile, profile_id}}}

      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [
                   %{
                     "type" => "text",
                     "text" => "The stored profile is damaged and cannot be used."
                   }
                 ]
               }
             } = plan_over_mcp(ctx, ref)
    end

    # A head is read as every head's bytes are (`Loader.head_blob/1`): bytes
    # that fail their stored digest, though they decode and grant more than
    # was committed, and a policy that does not parse as a blob, whose
    # nodes are no nodes, each leave the narrowing unknown.
    test "a stored policy that fails its digest or does not parse refuses the plan as the " <>
           "damaged profile it is",
         %{ctx: ctx} do
      ref = "reagent:local.plan-damaged-head"

      publish!(ctx, "plan-damaged-head", "1.0.0", %{
        "caps" => %{
          "egress" => %{"domains" => ["api.damaged.example"], "methods" => ~w(GET POST)}
        }
      })

      commit!(ctx, ref, %{subset: %{ref => %{"egress" => %{"methods" => ["GET"]}}}})
      {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)

      widened =
        String.replace(head.resolved_policy, ~s("methods":["GET"]), ~s("methods":["GET","POST"]))

      assert widened != head.resolved_policy
      assert {:ok, _} = Jason.decode(widened)

      not_nodes = [
        Jason.encode!(%{"nodes" => %{ref => "x"}}),
        Jason.encode!(%{
          "nodes" => %{
            ref => %{
              "limits" => "bad",
              "edges" => %{"@ingress" => %{"egress" => %{"methods" => "GET"}}}
            }
          }
        })
      ]

      # The widened bytes under the committed digest; each policy whose
      # nodes are no nodes under the committed digest and under its own,
      # so the parse is what refuses it.
      damaged =
        [[resolved_policy: widened]] ++
          for policy <- not_nodes,
              digest <- [head.blob_digest, Prima.JCS.hash_binary(policy)],
              do: [resolved_policy: policy, blob_digest: digest]

      for changes <- damaged do
        :ok = ConsentFixtures.hand_edit_head!(ctx, profile_id, changes)

        assert Plan.plan(ctx, %{ref: ref}) == {:error, {:corrupt, {:profile, profile_id}}},
               inspect(changes)

        assert Sanctum.Providers.Profile.handle(ctx, %{"action" => "plan", "ref" => ref}) ==
                 {:error, {:corrupt, {:profile, profile_id}}}

        assert %{
                 "result" => %{
                   "isError" => true,
                   "content" => [
                     %{
                       "type" => "text",
                       "text" => "The stored profile is damaged and cannot be used."
                     }
                   ]
                 }
               } = plan_over_mcp(ctx, ref)
      end
    end

    # A rate limit bounds a burst and a rate at once, so the narrower of the
    # head's and the ask's is their overlap, the smaller count over the
    # longer window: never the ask's, which may be faster or burst larger.
    test "a rate limit re-grants as the overlap of the head's and the ask's, no wider than " <>
           "either",
         %{ctx: ctx} do
      ref = "reagent:local.plan-rate"

      ask = fn rate ->
        %{
          "caps" => %{
            "egress" => %{"domains" => ["api.rate.example"], "methods" => ["GET"]},
            "limits" => %{"rate_limit" => rate}
          }
        }
      end

      publish!(ctx, "plan-rate", "1.0.0", ask.(%{"requests" => 100, "window" => "1m"}))

      commit!(ctx, ref, %{
        subset: %{ref => %{"limits" => %{"rate_limit" => %{"requests" => 50}}}}
      })

      assert held(ctx, ref, ref).limits["rate_limit"] == %{"requests" => 50, "window" => "1m"}

      # A release lowering the burst and shortening the window: 40 per ten
      # seconds is 240 a minute, faster than the head's 50.
      publish!(ctx, "plan-rate", "1.1.0", ask.(%{"requests" => 40, "window" => "10s"}))
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert plan.head_narrowing == %{
               ref => %{"limits" => %{"rate_limit" => %{"window" => "1m"}}}
             }

      commit!(ctx, ref, %{subset: plan.head_narrowing})
      assert held(ctx, ref, ref).limits["rate_limit"] == %{"requests" => 40, "window" => "1m"}

      # A head faster than a release's ask (50 per ten seconds against 100
      # a minute) keeps its burst over the ask's window.
      publish!(ctx, "plan-rate", "1.2.0", ask.(%{"requests" => 100, "window" => "10s"}))

      commit!(ctx, ref, %{
        subset: %{ref => %{"limits" => %{"rate_limit" => %{"requests" => 50}}}}
      })

      publish!(ctx, "plan-rate", "1.3.0", ask.(%{"requests" => 100, "window" => "1m"}))
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert plan.head_narrowing == %{
               ref => %{"limits" => %{"rate_limit" => %{"requests" => 50}}}
             }

      commit!(ctx, ref, %{subset: plan.head_narrowing})
      assert held(ctx, ref, ref).limits["rate_limit"] == %{"requests" => 50, "window" => "1m"}
    end

    # A dependency a release adds opens granting none of what it asks and is
    # listed as new; a value newly asked on a dependency the head holds opens
    # off and is listed under it; a dependency a release drops is listed as
    # dropped.
    test "a dependency added, asking more, or dropped opens no wider and is listed under its node",
         %{ctx: ctx} do
      dep = "reagent:local.plan-added-dep"
      ref = "reagent:local.plan-adding"

      dep_ask = fn methods ->
        %{
          "caps" => %{
            "egress" => %{"domains" => ["api.dep.example"], "methods" => methods},
            "storage" => %{"paths" => ["data/dep/"], "actions" => ["read", "write"]},
            "tools" => ["execution.logs"]
          }
        }
      end

      source = %{"egress" => %{"domains" => ["api.source.example"], "methods" => ~w(GET POST)}}
      get_only = %{"egress" => %{"methods" => ["GET"]}}

      publish!(ctx, "plan-added-dep", "1.0.0", dep_ask.(~w(GET DELETE)))
      publish!(ctx, "plan-adding", "1.0.0", %{"caps" => source})
      commit!(ctx, ref, %{subset: %{ref => get_only}})

      publish!(ctx, "plan-adding", "1.1.0", %{
        "caps" => source,
        "dependencies" => %{"static" => [%{"ref" => dep}]}
      })

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      none = %{
        "egress" => %{"domains" => [], "methods" => [], "schemes" => []},
        "storage" => %{"paths" => [], "actions" => []},
        "tools" => []
      }

      assert plan.head_narrowing == %{ref => get_only, dep => none}

      # Listed after the app's own entries, as new, with all it asks.
      assert [%{node: ^ref, new: false, dropped: false} | _] = plan.shape_diff

      assert [%{added: ["POST"], removed: []}] =
               Enum.filter(
                 plan.shape_diff,
                 &(&1.node == ref and &1.capability == "egress.methods")
               )

      listed = Enum.filter(plan.shape_diff, &(&1.node == dep))
      assert Enum.all?(listed, &(&1.new and not &1.dropped and &1.removed == []))

      assert Map.new(listed, &{&1.capability, &1.added}) == %{
               "egress.domains" => ["api.dep.example"],
               "egress.methods" => ["DELETE", "GET"],
               "egress.schemes" => ["https"],
               "storage.paths" => ["data/dep/"],
               "storage.actions" => ["read", "write"],
               "tools" => ["execution.logs"]
             }

      # A client reads each entry's node and whether it is new or dropped.
      assert %{"result" => %{"isError" => false, "content" => [%{"text" => text}]}} =
               plan_over_mcp(ctx, ref)

      wire = Jason.decode!(text)["shape_diff"]
      assert length(wire) == length(plan.shape_diff)

      for entry <- wire do
        assert is_binary(entry["node"]) and is_boolean(entry["new"]) and
                 is_boolean(entry["dropped"]),
               inspect(entry)
      end

      assert %{"node" => ^dep, "new" => true, "dropped" => false, "added" => ["read", "write"]} =
               Enum.find(wire, &(&1["node"] == dep and &1["capability"] == "storage.actions"))

      # Committed as it opens, the dependency is granted nothing.
      commit!(ctx, ref, %{subset: plan.head_narrowing})
      %{resources: granted} = held(ctx, ref, dep)
      assert granted["egress"]["domains"] == [] and granted["egress"]["methods"] == []
      assert granted["storage"] == %{"paths" => [], "actions" => []}
      assert granted["tools"] == []

      # Granted as the person chose: GET on its domain, its files to read.
      commit!(ctx, ref, %{
        subset: %{
          ref => get_only,
          dep => %{"egress" => %{"methods" => ["GET"]}, "storage" => %{"actions" => ["read"]}}
        }
      })

      %{resources: granted} = held(ctx, ref, dep)
      assert granted["egress"]["domains"] == ["api.dep.example"]
      assert granted["egress"]["methods"] == ["GET"]
      assert granted["storage"] == %{"paths" => ["data/dep/"], "actions" => ["read"]}

      # The dependency's release asks for PATCH too: the head never granted
      # it, so it opens off.
      publish!(ctx, "plan-added-dep", "1.1.0", dep_ask.(~w(GET DELETE PATCH)))
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert plan.head_narrowing == %{
               ref => get_only,
               dep => %{
                 "egress" => %{"methods" => ["GET"]},
                 "storage" => %{"actions" => ["read"]}
               }
             }

      # Listed under the dependency, never as the app's own.
      assert [%{added: ["DELETE", "PATCH"], removed: [], new: false, dropped: false}] =
               Enum.filter(
                 plan.shape_diff,
                 &(&1.node == dep and &1.capability == "egress.methods")
               )

      refute Enum.any?(plan.shape_diff, &(&1.node == ref and "PATCH" in &1.added))

      # A release of the app that no longer uses the dependency: what the
      # head granted it is listed as dropped, and nothing of it is asked.
      publish!(ctx, "plan-adding", "1.2.0", %{"caps" => source})
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert plan.head_narrowing == %{ref => get_only}

      listed = Enum.filter(plan.shape_diff, &(&1.node == dep))
      assert Enum.all?(listed, &(&1.dropped and not &1.new and &1.added == []))

      assert Map.new(listed, &{&1.capability, &1.removed}) == %{
               "egress.domains" => ["api.dep.example"],
               "egress.methods" => ["GET"],
               "egress.schemes" => ["https"],
               "storage.paths" => ["data/dep/"],
               "storage.actions" => ["read"],
               "tools" => ["execution.logs"]
             }
    end

    # A plan reads the head once, so a head damaged at any point of a plan is
    # answered as that one read found it: the head as read, or the read's
    # own refusal, never a crash, and never a narrowing of one read with the
    # revision of another.
    test "a head damaged at any point of a plan answers as its one read found it",
         %{ctx: ctx} do
      ref = "reagent:local.plan-racing"

      publish!(ctx, "plan-racing", "1.0.0", %{
        "caps" => %{"egress" => %{"domains" => ["api.racing.example"], "methods" => ~w(GET POST)}}
      })

      get_only = %{ref => %{"egress" => %{"methods" => ["GET"]}}}
      commit!(ctx, ref, %{subset: get_only})
      {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, %{scope: scope}} = Sanctum.Consent.head_consent(ctx, profile_id)

      real = Sanctum.Grimoire.impl!()
      :persistent_term.put({RacingGrimoire, :real}, real)
      Sanctum.Grimoire.install!(RacingGrimoire)

      on_exit(fn ->
        Sanctum.Grimoire.install!(real)
        :persistent_term.erase({RacingGrimoire, :real})
      end)

      damage = fn -> ConsentFixtures.hand_edit_head!(ctx, profile_id, scope: "bogus") end

      restore = fn ->
        ConsentFixtures.hand_edit_head!(ctx, profile_id, scope: to_string(scope))
      end

      # The catalog reads one plan makes, each a point the head can move at.
      {{:ok, whole}, reads} =
        RacingGrimoire.run(0, fn -> :ok end, fn -> Plan.plan(ctx, %{ref: ref}) end)

      assert whole.head_narrowing == get_only
      assert reads > 1

      damage.()
      refused = Plan.plan(ctx, %{ref: ref})
      assert {:error, _} = refused

      answers =
        for at <- 1..reads do
          :ok = restore.()

          {answer, _reads} =
            RacingGrimoire.run(at, damage, fn -> Plan.plan(ctx, %{ref: ref}) end)

          case answer do
            {:ok, plan} ->
              assert plan.head_narrowing == get_only
              assert plan.expected_consent_revision == whole.expected_consent_revision

            refusal ->
              assert refusal == refused
          end

          answer
        end

      # The head moved before the plan read it and after.
      assert refused in answers
      assert Enum.any?(answers, &match?({:ok, _}, &1))
    end

    test "a re-grant names the origins the head admits, and what changed against the head " <>
           "as the person narrowed it",
         %{ctx: ctx} do
      ref = "reagent:local.plan-head"
      ask = fn domains -> %{"caps" => %{"egress" => %{"domains" => domains}}} end
      publish!(ctx, "plan-head", "1.0.0", ask.(["a.example", "b.example"]))

      commit!(ctx, ref, %{
        origins: [:interactive, :webhook],
        subset: %{ref => %{"egress" => %{"domains" => ["a.example"]}}}
      })

      {:ok, unchanged} = Plan.plan(ctx, %{ref: ref})
      assert unchanged.head_origins == ["interactive", "webhook"]
      assert unchanged.shape_diff == []

      publish!(ctx, "plan-head", "1.1.0", ask.(["a.example", "b.example", "c.example"]))
      {:ok, moved} = Plan.plan(ctx, %{ref: ref})

      assert [%{capability: "egress.domains", added: added, removed: []}] =
               Enum.filter(moved.shape_diff, &(&1.capability == "egress.domains"))

      # b is what the person narrowed away, c what the component newly
      # asks for: both are asked for and not granted.
      assert added == ["b.example", "c.example"]
    end

    test "a sub-folder picked inside a folder still asked for is not reported as dropped",
         %{ctx: ctx} do
      ref = "reagent:local.plan-picked"

      ask = fn domains ->
        %{
          "caps" => %{
            "egress" => %{"domains" => domains},
            "storage" => %{"paths" => ["data/notes/"], "actions" => ["read"]}
          }
        }
      end

      publish!(ctx, "plan-picked", "1.0.0", ask.(["a.example"]))

      commit!(ctx, ref, %{
        subset: %{ref => %{"storage" => %{"paths" => ["data/notes/2026/"]}}}
      })

      # The shape moves for another reason; the folder is still asked for.
      publish!(ctx, "plan-picked", "1.1.0", ask.(["a.example", "b.example"]))
      {:ok, moved} = Plan.plan(ctx, %{ref: ref})

      refute moved.shape_diff == []

      for entry <- moved.shape_diff do
        refute "data/notes/2026/" in entry.removed,
               "#{entry.capability} reports the picked sub-folder as no longer asked for"
      end

      # What the ask names and the grant does not give is still said.
      assert [%{added: ["data/notes/"], removed: []}] =
               Enum.filter(moved.shape_diff, &(&1.capability == "storage.paths"))
    end
  end

  # A provider no shipped preset is, shown to attenuate a refresh
  # (`:sanctum, :scripted_oauth_provider`); its token endpoint answers
  # nothing, since a plan asks it nothing.
  defmodule AttenuatingProvider do
    @moduledoc false

    def preset("attenuating-idp"),
      do: %{
        endpoints: %{
          "authorize_url" => "https://idp.attenuating.test/authorize",
          "token_url" => "https://idp.attenuating.test/token"
        },
        attenuates_scope: true
      }

    def preset(_hint), do: nil

    def post(_url, _headers, _body), do: {:error, "a plan asks the provider nothing"}
  end

  describe "OAuth candidates and the needs they meet" do
    @mail_ref "reagent:local.plan-mail"

    setup %{ctx: ctx} do
      publish!(ctx, "plan-mail", "1.0.0", %{
        "needs" => %{
          "mail" => %{
            "type" => "oauth:google",
            "reason" => "to read your mail",
            "required" => true,
            "scopes" => ["gmail.readonly"]
          }
        }
      })

      :ok
    end

    # The mail need declares no attach rule: the component reads its token
    # itself, so the entries that can meet it are disclosed.
    defp oauth_entry!(ctx, scopes, hint \\ "google") do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "mail-#{System.unique_integer([:positive])}",
          kind: "oauth",
          provider_hint: hint,
          oauth: %{"access_token" => "t"},
          oauth_scopes: scopes,
          destination: %{"hosts" => ["gmail.googleapis.com"]},
          disclose: true
        })

      view
    end

    defp mail_warnings(plan), do: Enum.filter(plan.warnings, &(&1 =~ "need 'mail'"))

    test "an OAuth candidate says whether it can be narrowed, and no other kind does",
         %{ctx: ctx} do
      oauth = oauth_entry!(ctx, ["gmail.readonly"])

      {:ok, key} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "key-#{System.unique_integer([:positive])}",
          kind: "api_key",
          fields: %{"KEY" => "k"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      {:ok, plan} = Plan.plan(ctx, %{ref: @mail_ref})

      assert %{narrowable: false} = Enum.find(plan.candidates, &(&1.id == oauth.id))
      refute Map.has_key?(Enum.find(plan.candidates, &(&1.id == key.id)), :narrowable)
    end

    test "a need is met by an OAuth candidate holding exactly its scopes", %{ctx: ctx} do
      oauth_entry!(ctx, ["gmail.readonly"])
      {:ok, plan} = Plan.plan(ctx, %{ref: @mail_ref})

      assert mail_warnings(plan) == []
    end

    test "a need is not met by a wider candidate that cannot be narrowed, nor by one " <>
           "lacking its scopes",
         %{ctx: ctx} do
      {:ok, none} = Plan.plan(ctx, %{ref: @mail_ref})
      assert [_warning] = mail_warnings(none)

      wider = oauth_entry!(ctx, ["gmail.readonly", "gmail.send"])
      oauth_entry!(ctx, ["gmail.send"])
      {:ok, plan} = Plan.plan(ctx, %{ref: @mail_ref})

      assert %{narrowable: false} = Enum.find(plan.candidates, &(&1.id == wider.id))
      assert [warning] = mail_warnings(plan)
      assert warning =~ "gmail.readonly"
    end

    test "a need is met by a wider candidate whose provider attenuates a refresh", %{ctx: ctx} do
      prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)
      Application.put_env(:sanctum, :scripted_oauth_provider, AttenuatingProvider)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
          :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
        end
      end)

      # A need meets entries of its own provider: this one is the
      # attenuating provider's.
      publish!(ctx, "plan-mail-idp", "1.0.0", %{
        "needs" => %{
          "mail" => %{
            "type" => "oauth:attenuating-idp",
            "reason" => "to read your mail",
            "required" => true,
            "scopes" => ["gmail.readonly"]
          }
        }
      })

      wider = oauth_entry!(ctx, ["gmail.readonly", "gmail.send"], "attenuating-idp")
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-mail-idp"})

      assert %{narrowable: true} = Enum.find(plan.candidates, &(&1.id == wider.id))
      assert mail_warnings(plan) == []

      assert [%{entry_id: id, narrowable: true}] =
               Enum.find(plan.needs, &(&1.need == "mail")).candidates

      assert id == wider.id
    end
  end

  describe "each need's choice" do
    @keyed "reagent:local.plan-keyed"
    @attach %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}
    @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

    defp keyed_need(over \\ %{}) do
      Map.merge(
        %{
          "type" => "api_key:openai.com",
          "reason" => "to call the model with a key",
          "fields" => ["OPENAI_API_KEY"],
          "attach" => @attach
        },
        over
      )
    end

    defp own!(ctx, hint, over \\ %{}) do
      {:ok, view} =
        Sanctum.TestContext.create_vault(
          ctx,
          Map.merge(
            %{
              name: "own-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: hint,
              fields: %{"OPENAI_API_KEY" => "sk-own"},
              destination: %{"hosts" => ["api.openai.com"]}
            },
            over
          )
        )

      view
    end

    defp instance!(over \\ %{}) do
      {:ok, entry} =
        Arca.InstanceEntries.put(
          Arca.Test.Actor.platform(),
          Map.merge(
            %{
              name: "instance-#{System.unique_integer([:positive])}",
              kind: "api_key",
              provider_hint: "openai.com",
              field_names: ~s(["OPENAI_API_KEY"]),
              destination: @inference,
              sealed_payload: "sealed",
              binding_digest: "sha256:instance",
              audience: "everyone",
              created_by: "usr_admin"
            },
            over
          )
        )

      entry
    end

    defp need_row!(ctx, ref, name) do
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {plan, Enum.find(plan.needs, &(&1.need == name))}
    end

    test "candidates are the entries of the need's kind and provider, own and offered", %{
      ctx: ctx
    } do
      publish!(ctx, "plan-keyed", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})
      openai = own!(ctx, "openai.com")
      _anthropic = own!(ctx, "anthropic.com")
      offered = instance!()
      _other_provider = instance!(%{provider_hint: "anthropic.com"})
      _bundle = instance!(%{kind: "bundle"})

      {_plan, row} = need_row!(ctx, @keyed, "api_key")

      assert Enum.sort_by(row.candidates, & &1.source) == [
               %{
                 source: "instance",
                 instance_entry_id: offered.id,
                 name: offered.name,
                 kind: "api_key",
                 provider: "openai.com",
                 destination: %{
                   "hosts" => ["api.openai.com"],
                   "methods" => ["POST"],
                   "paths" => ["/v1/"],
                   "scheme" => "https"
                 },
                 disclosed: false
               },
               %{
                 source: "own",
                 entry_id: openai.id,
                 name: openai.name,
                 kind: "api_key",
                 provider: "openai.com",
                 destination: %{"hosts" => ["api.openai.com"], "scheme" => "https"},
                 disclosed: false
               }
             ]

      # The athanor's first entry of the provider is its default, and the
      # default is what the plan suggests.
      assert row.suggested == %{entry_id: openai.id}
      assert row.choice_required == false
      assert row.source == "own"
      assert row.newer_shipped == nil
    end

    test "with no default, several candidates ask the person to choose", %{ctx: ctx} do
      publish!(ctx, "plan-keyed", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})
      own!(ctx, "openai.com")
      instance!()
      :ok = Arca.VaultDefaults.clear(Sanctum.Context.actor(ctx), "openai.com")

      {_plan, row} = need_row!(ctx, @keyed, "api_key")

      assert length(row.candidates) == 2
      assert row.suggested == nil
      assert row.choice_required == true
      assert row.source == nil

      # A default naming no candidate suggests nothing; the next rule
      # answers.
      own = own!(ctx, "anthropic.com")

      {:ok, _} =
        Arca.VaultDefaults.set(Sanctum.Context.actor(ctx), "openai.com", %{
          vault_entry_id: own.id
        })

      {_plan, row} = need_row!(ctx, @keyed, "api_key")
      assert row.suggested == nil and row.choice_required == true
    end

    test "the one offered instance entry is suggested when the athanor holds none of the " <>
           "provider, and a default may name an instance entry",
         %{ctx: ctx} do
      publish!(ctx, "plan-keyed", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})
      offered = instance!()

      {_plan, row} = need_row!(ctx, @keyed, "api_key")
      assert row.suggested == %{instance_entry_id: offered.id}
      assert row.source == "instance"
      refute row.choice_required

      second = instance!()
      {_plan, row} = need_row!(ctx, @keyed, "api_key")
      assert row.suggested == nil and row.choice_required

      {:ok, _} =
        Arca.VaultDefaults.set(Sanctum.Context.actor(ctx), "openai.com", %{
          instance_entry_id: second.id
        })

      {_plan, row} = need_row!(ctx, @keyed, "api_key")
      assert row.suggested == %{instance_entry_id: second.id}
      assert row.source == "instance"
    end

    test "an instance entry under shipped is offered to an unmodified shipped node alone, " <>
           "and under any to every node",
         %{ctx: ctx} do
      publish!(ctx, "plan-keyed", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})

      # A component of the person's own, which the media does not ship.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "plan-custom",
          version: "1.0.0",
          type: "reagent",
          manifest:
            Jason.encode!(%{
              "name" => "plan-custom",
              "version" => "1.0.0",
              "type" => "reagent",
              "needs" => %{"api_key" => keyed_need()}
            })
        })

      shipped = instance!(%{component_policy: "shipped"})
      any = instance!(%{component_policy: "any"})

      {_plan, shipped_row} = need_row!(ctx, @keyed, "api_key")
      {_plan, custom_row} = need_row!(ctx, "reagent:local.plan-custom", "api_key")

      ids = fn row -> row.candidates |> Enum.map(& &1[:instance_entry_id]) |> Enum.sort() end

      assert ids.(shipped_row) == Enum.sort([shipped.id, any.id])
      assert ids.(custom_row) == [any.id]
    end

    test "a disclose-only need is met by disclosed entries alone, and names the newer " <>
           "shipped version",
         %{ctx: ctx} do
      publish!(ctx, "plan-keyed", "1.0.0", %{
        "needs" => %{"api_key" => Map.delete(keyed_need(), "attach")}
      })

      # The release ships a newer version the athanor has not pulled.
      Arca.Test.UnitFixtures.seed_component!("reagent", "local", "plan-keyed", "1.1.0",
        wasm: @wasm
      )

      own!(ctx, "openai.com")
      instance!()

      {plan, row} = need_row!(ctx, @keyed, "api_key")

      assert row.candidates == []
      assert row.newer_shipped == "1.1.0"
      assert [warning] = Enum.filter(plan.warnings, &(&1 =~ "need 'api_key'"))
      assert warning =~ "openai.com"
      assert warning =~ "reads the value itself"
      assert warning =~ "version 1.1.0"

      disclosed = own!(ctx, "openai.com", %{disclose: true})
      {plan, row} = need_row!(ctx, @keyed, "api_key")

      assert [%{entry_id: id, disclosed: true}] = row.candidates
      assert id == disclosed.id
      assert row.suggested == %{entry_id: disclosed.id}
      refute Enum.any?(plan.warnings, &(&1 =~ "need 'api_key'"))
    end

    test "a dependency's need the app provides is answered by the app, and what it cannot " <>
           "provide is said",
         %{ctx: ctx} do
      publish!(ctx, "plan-db", "1.0.0", %{
        "needs" => %{
          "database" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to reach the database",
            "fields" => ["anon_key"],
            "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          },
          "signing" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to sign",
            "fields" => ["secret"]
          }
        }
      })

      provides = fn needs ->
        %{
          "dependencies" => %{"static" => [%{"ref" => "reagent:local.plan-db"}]},
          "provides" => %{"reagent:local.plan-db" => needs}
        }
      end

      entry = %{
        "destination" => %{"hosts" => ["abc.supabase.co"]},
        "values" => %{"anon_key" => "a"}
      }

      publish!(ctx, "plan-app", "1.0.0", provides.(%{"database" => entry}))
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-app"})

      assert [%{dep: "reagent:local.plan-db", needs: needs}] = plan.dependency_needs
      database = Enum.find(needs, &(&1.need == "database"))
      signing = Enum.find(needs, &(&1.need == "signing"))

      assert database.source == "provided"
      assert database.destination == %{"hosts" => ["abc.supabase.co"], "scheme" => "https"}
      assert database.candidates == [] and database.suggested == nil
      refute database.choice_required
      assert signing.source == nil and signing.newer_shipped == nil

      # A need the dependency does not declare, or declares disclose-only,
      # is provided nothing: said, and left to its candidates.
      publish!(ctx, "plan-app", "1.1.0", provides.(%{"signing" => entry, "absent" => entry}))
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-app"})
      [%{needs: needs}] = plan.dependency_needs
      assert Enum.find(needs, &(&1.need == "signing")).source == nil

      assert Enum.any?(
               plan.warnings,
               &(&1 =~ "provides absent" and &1 =~ "declares no such need")
             )

      assert Enum.any?(plan.warnings, &(&1 =~ "provides signing" and &1 =~ "no attach rule"))
    end
  end

  describe "what a surface prefills, the head's bindings and what a lender lends" do
    @prefill_app "reagent:local.plan-prefill-app"
    @prefill_dep "reagent:local.plan-prefill-dep"
    @bearer %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}

    defp prefill_closure!(ctx) do
      publish!(ctx, "plan-prefill-dep", "1.0.0", %{
        "needs" => %{
          "signing" => %{
            "type" => "api_key:openai.com",
            "reason" => "to sign with your key",
            "fields" => ["OPENAI_API_KEY"],
            "attach" => @bearer,
            "hosts" => ["api.openai.com"],
            "paths" => ["/v1/"],
            "disclose" => true
          }
        },
        "caps" => %{"egress" => %{"domains" => ["api.openai.com"]}}
      })

      publish!(ctx, "plan-prefill-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => @prefill_dep}]},
        "needs" => %{
          "model" => %{
            "type" => "api_key:anthropic.com",
            "reason" => "to call the model",
            "fields" => ["ANTHROPIC_API_KEY"],
            "required" => false
          }
        }
      })
    end

    test "each declared need names its kind, provider, disclosure and declared destination, " <>
           "the app's and a dependency's alike; the undeclared slot declares none",
         %{ctx: ctx} do
      prefill_closure!(ctx)
      {:ok, plan} = Plan.plan(ctx, %{ref: @prefill_app})

      assert %{
               kind: "api_key",
               provider: "anthropic.com",
               disclose_only: true,
               disclose: false,
               hosts: nil,
               paths: nil,
               required: false
             } = Enum.find(plan.needs, &(&1.need == "model"))

      assert [%{from: @prefill_app, dep: @prefill_dep, needs: [signing]}] = plan.dependency_needs

      assert %{
               need: "signing",
               kind: "api_key",
               provider: "openai.com",
               disclose_only: false,
               disclose: true,
               hosts: ["api.openai.com"],
               paths: ["/v1/"],
               required: true
             } = signing

      # A manifest declaring no needs has the slot the component reads
      # itself, which names no kind or provider and declares nothing.
      publish!(ctx, "plan-prefill-none", "1.0.0", %{})
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-prefill-none"})
      assert [slot] = plan.needs
      assert %{need: "@ingress", hosts: nil, paths: nil, disclose: false} = slot
      refute Map.has_key?(slot, :kind)
      refute Map.has_key?(slot, :provider)
    end

    test "the head's bindings name each key, what it binds, its lifetime and whether a root " <>
           "consumed its once",
         %{ctx: ctx} do
      ref = "reagent:local.plan-keyed"

      publish!(ctx, "plan-keyed", "1.0.0", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "reason" => "to call the model with a key",
            "fields" => ["OPENAI_API_KEY"],
            "attach" => @bearer
          }
        }
      })

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert plan.head_bindings == []

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "keyed-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          fields: %{"OPENAI_API_KEY" => "sk-keyed"},
          destination: %{"hosts" => ["api.openai.com"]}
        })

      until = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

      commit!(ctx, ref, %{
        bindings: [
          %{need: "api_key", entry_id: entry.id, lifetime: %{kind: "once"}},
          %{
            need: "api_key",
            entry_id: entry.id,
            name: "later",
            lifetime: %{kind: "until", until: DateTime.to_iso8601(until)}
          }
        ]
      })

      {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      [once_key] = for r <- head.vault_refs, r.lifetime_kind == "once", do: r.binding_key
      [until_key] = for r <- head.vault_refs, r.lifetime_kind == "until", do: r.binding_key

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert Enum.sort_by(plan.head_bindings, & &1.binding_key) ==
               Enum.sort_by(
                 [
                   %{
                     binding_key: once_key,
                     entry_id: entry.id,
                     lifetime: %{kind: "once", until: nil},
                     consumed: false
                   },
                   %{
                     binding_key: until_key,
                     entry_id: entry.id,
                     lifetime: %{kind: "until", until: DateTime.to_iso8601(until)},
                     consumed: false
                   }
                 ],
                 & &1.binding_key
               )

      :ok =
        Arca.ConsentStorage.consume_once(
          Sanctum.Context.actor(ctx),
          profile_id,
          head.id,
          once_key,
          "exec_plan_once"
        )

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert %{consumed: true} = Enum.find(plan.head_bindings, &(&1.binding_key == once_key))
      assert %{consumed: false} = Enum.find(plan.head_bindings, &(&1.binding_key == until_key))
    end

    test "a head binding of an instance entry names that entry, and an edge a lending " <>
           "profile fills names the profile's label, never an entry",
         %{ctx: ctx} do
      ref = "reagent:local.plan-head-offered"
      # An instance entry is bound by a person active on this server.
      {person, _user} = Sanctum.TestContext.person!(ctx)
      publish!(person, "plan-head-offered", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})
      offered = instance!()

      commit!(person, ref, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})

      {:ok, plan} = Plan.plan(person, %{ref: ref})

      assert plan.head_bindings == [
               %{
                 binding_key: "#{ref}|@ingress|default",
                 instance_entry_id: offered.id,
                 lifetime: %{kind: "standing", until: nil},
                 consumed: false
               }
             ]

      dep = "reagent:local.plan-head-lend-dep"
      app = "reagent:local.plan-head-lend-app"
      publish!(ctx, "plan-head-lend-dep", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})

      publish!(ctx, "plan-head-lend-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => dep}]}
      })

      key = own!(ctx, "openai.com")
      commit!(ctx, dep, %{bindings: [%{need: "api_key", entry_id: key.id}]})
      commit!(ctx, app, %{selections: [%{dep: dep, label: "default", lifetime: %{kind: "once"}}]})

      {:ok, plan} = Plan.plan(ctx, %{ref: app})

      assert plan.head_bindings == [
               %{
                 binding_key: "#{app}|#{dep}|default",
                 label: "default",
                 lifetime: %{kind: "once", until: nil},
                 consumed: false
               }
             ]
    end

    test "a lender names the fields and the scopes its binding lends", %{ctx: ctx} do
      publish!(ctx, "plan-lend-dep", "1.0.0", %{
        "needs" => %{
          "mail" => %{
            "type" => "oauth:google",
            "reason" => "to read your mail",
            "scopes" => ["gmail.readonly"],
            "attach" => %{"in" => "header", "name" => "Authorization"}
          }
        }
      })

      publish!(ctx, "plan-lend-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.plan-lend-dep"}]}
      })

      mail = oauth_entry!(ctx, ["gmail.readonly"])

      commit!(ctx, "reagent:local.plan-lend-dep", %{
        bindings: [%{need: "mail", entry_id: mail.id}]
      })

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-lend-app"})
      assert [%{candidates: [lender]}] = plan.dependency_needs

      assert %{label: "default", entry_id: id, fields: [], scopes: ["gmail.readonly"]} = lender
      assert id == mail.id

      # A key's lender lends its fields and no scope.
      publish!(ctx, "plan-lend-key", "1.0.0", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "reason" => "to call the model",
            "fields" => ["OPENAI_API_KEY"],
            "attach" => @bearer
          }
        }
      })

      publish!(ctx, "plan-lend-key-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.plan-lend-key"}]}
      })

      {:ok, key} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "lent-key-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "openai.com",
          fields: %{"OPENAI_API_KEY" => "sk-lent"},
          destination: %{"hosts" => ["api.openai.com"]}
        })

      commit!(ctx, "reagent:local.plan-lend-key", %{
        bindings: [%{need: "api_key", entry_id: key.id}]
      })

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-lend-key-app"})
      assert [%{candidates: [key_lender]}] = plan.dependency_needs
      assert %{fields: ["OPENAI_API_KEY"], scopes: []} = key_lender
    end
  end

  describe "a lender that cannot be read" do
    # A lender the store could not answer, or whose profile row or head
    # does not decode, refuses the plan with its reason, which
    # `profile.plan` answers typed and a person reads in
    # `Sanctum.Unauthorized`'s sentence of its class: a plan without that
    # lender would tell the person to set up a key over a profile that
    # lends one. A dependency with no profile, or whose profile has no
    # head, lends nothing.
    @lend_dep "reagent:local.plan-lend-read-dep"
    @lend_app "reagent:local.plan-lend-read-app"
    @unreadable "A profile that lends a key here cannot be read right now — try again."

    defp lending_closure!(ctx) do
      publish!(ctx, "plan-lend-read-dep", "1.0.0", %{"needs" => %{"api_key" => keyed_need()}})

      publish!(ctx, "plan-lend-read-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => @lend_dep}]}
      })
    end

    # The dependency's one owner profile, its head binding a key.
    defp lender!(ctx) do
      key = own!(ctx, "openai.com")
      commit!(ctx, @lend_dep, %{bindings: [%{need: "api_key", entry_id: key.id}]})
      {:ok, [%{id: lender}]} = Sanctum.Consent.profiles(ctx, @lend_dep)

      {:ok, plan} = Plan.plan(ctx, %{ref: @lend_app})
      assert [%{dep: @lend_dep, candidates: [%{profile_id: ^lender}]}] = plan.dependency_needs

      lender
    end

    defp plan_answer(ctx),
      do: Sanctum.Providers.Profile.handle(ctx, %{"action" => "plan", "ref" => @lend_app})

    # `table` stops answering once the app's own profile list is read (the
    # plan's first profile read), so the dependency's is the read refused.
    defp away_after_app_profiles!(table) do
      test = self()
      handler = "plan-lender-away-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == "profiles" and
                 @lend_app in (meta[:params] || []) do
              :telemetry.detach(handler)
              Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    # `table` stops answering once the lender's head is read (its
    # `consent_vault_refs`, the head's last read), so the entry it binds is
    # the read refused; every read before it answers.
    defp away_after_lender_head!(table, head_id) do
      test = self()
      handler = "plan-lent-away-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == "consent_vault_refs" and
                 head_id in (meta[:params] || []) do
              :telemetry.detach(handler)
              Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp head_id!(ctx, profile_id) do
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)
      head.id
    end

    defp lenders(ctx) do
      {:ok, %{dependency_needs: [%{dep: @lend_dep, candidates: candidates}]}} =
        Plan.plan(ctx, %{ref: @lend_app})

      candidates
    end

    test "a dependency with no profile, or a profile with no head, plans with no lenders",
         %{ctx: ctx} do
      lending_closure!(ctx)

      assert {:ok, %{dependency_needs: [%{dep: @lend_dep, candidates: []}]}} =
               Plan.plan(ctx, %{ref: @lend_app})

      :ok =
        ConsentFixtures.seed_profile!(ctx, %{
          id: "prof_plan_lend_headless",
          source_ref: @lend_dep,
          kind: :owner,
          label: "default",
          status: :active
        })

      assert {:ok, %{dependency_needs: [%{dep: @lend_dep, candidates: []}]}} =
               Plan.plan(ctx, %{ref: @lend_app})
    end

    @tag :capture_log
    test "a dependency's profile list the store cannot answer refuses the plan", %{ctx: ctx} do
      lending_closure!(ctx)
      lender!(ctx)

      away_after_app_profiles!("profiles")
      assert {:error, {:lender_unavailable, @lend_dep}} = Plan.plan(ctx, %{ref: @lend_app})

      Arca.Repo.query!("ALTER TABLE profiles_unavailable RENAME TO profiles")
      away_after_app_profiles!("profiles")
      assert_unreadable(plan_answer(ctx))
    end

    @tag :capture_log
    test "a lender's head the store cannot answer refuses the plan", %{ctx: ctx} do
      lending_closure!(ctx)
      lender!(ctx)

      # The app has no profile of its own, so the lender's is the one head
      # the plan reads.
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      assert {:error, {:lender_unavailable, @lend_dep}} = Plan.plan(ctx, %{ref: @lend_app})
      assert_unreadable(plan_answer(ctx))
    end

    test "a lender's profile row that does not decode refuses the plan, naming the profile",
         %{ctx: ctx} do
      lending_closure!(ctx)
      lender = lender!(ctx)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(p in Arca.Schemas.Profile,
            where: p.athanor_id == ^ctx.athanor_id and p.id == ^lender
          ),
          set: [kind: "sideways"]
        )

      assert {:error, {:lender_corrupt, @lend_dep, ^lender}} = Plan.plan(ctx, %{ref: @lend_app})
      assert_damaged(plan_answer(ctx), lender)
    end

    test "a lender's head that does not decode refuses the plan, naming the profile",
         %{ctx: ctx} do
      lending_closure!(ctx)
      lender = lender!(ctx)

      :ok = ConsentFixtures.hand_edit_head!(ctx, lender, scope: "sideways")

      assert {:error, {:lender_corrupt, @lend_dep, ^lender}} = Plan.plan(ctx, %{ref: @lend_app})
      assert_damaged(plan_answer(ctx), lender)
    end

    # Read as a selection reads its lender: a head whose bytes fail their
    # digest is damaged, so no sheet offers it to select.
    test "a lender's head whose bytes fail their digest refuses the plan, naming the profile",
         %{ctx: ctx} do
      lending_closure!(ctx)
      lender = lender!(ctx)

      :ok =
        ConsentFixtures.hand_edit_head!(ctx, lender,
          blob_digest: "sha256:" <> String.duplicate("0", 64)
        )

      assert {:error, {:lender_corrupt, @lend_dep, ^lender}} = Plan.plan(ctx, %{ref: @lend_app})
      assert_damaged(plan_answer(ctx), lender)
    end

    test "a lender's head whose policy does not parse refuses the plan, naming the profile",
         %{ctx: ctx} do
      lending_closure!(ctx)
      lender = lender!(ctx)

      :ok = ConsentFixtures.hand_edit_head!(ctx, lender, resolved_policy: "not a blob")

      assert {:error, {:lender_corrupt, @lend_dep, ^lender}} = Plan.plan(ctx, %{ref: @lend_app})
      assert_damaged(plan_answer(ctx), lender)
    end

    @tag :capture_log
    test "an entry a lender binds that the store cannot answer refuses the plan", %{ctx: ctx} do
      lending_closure!(ctx)
      head = head_id!(ctx, lender!(ctx))

      away_after_lender_head!("vault_entries", head)
      assert {:error, {:lender_unavailable, @lend_dep}} = Plan.plan(ctx, %{ref: @lend_app})

      Arca.Repo.query!("ALTER TABLE vault_entries_unavailable RENAME TO vault_entries")
      away_after_lender_head!("vault_entries", head)
      assert_unreadable(plan_answer(ctx))
    end

    @tag :capture_log
    test "an instance entry a lender binds that the store cannot answer refuses the plan",
         %{ctx: ctx} do
      # An instance entry is bound, and offered, to a person active here.
      {person, _user} = Sanctum.TestContext.person!(ctx)
      lending_closure!(person)
      offered = instance!()
      commit!(person, @lend_dep, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})
      {:ok, [%{id: lender}]} = Sanctum.Consent.profiles(person, @lend_dep)

      assert [%{profile_id: ^lender, source: "instance", entry_id: entry_id}] = lenders(person)
      assert entry_id == offered.id

      head = head_id!(person, lender)
      away_after_lender_head!("instance_entries", head)

      assert {:error, {:lender_unavailable, @lend_dep}} =
               Plan.plan(person, %{ref: @lend_app})

      Arca.Repo.query!("ALTER TABLE instance_entries_unavailable RENAME TO instance_entries")
      away_after_lender_head!("instance_entries", head)
      assert_unreadable(plan_answer(person))
    end

    # The reader's own answers about a lent entry are the entry's state,
    # not a read that failed: each lends nothing. The lender's profile is
    # set active again after each move, so its head is read, not skipped.
    test "a lent entry rebound or revoked lends nothing, its own or an instance entry",
         %{ctx: ctx} do
      lending_closure!(ctx)
      lender = lender!(ctx)
      [%{entry_id: key}] = lenders(ctx)
      reactivate = fn -> :ok = Arca.ProfileStorage.set_status(actor(ctx), lender, "active") end

      {:ok, _} = Sanctum.Vault.rebind(ctx, %{id: key, field_names: ["OPENAI_API_KEY", "REGION"]})
      reactivate.()
      assert lenders(ctx) == []

      {:ok, _} = Sanctum.Vault.revoke(ctx, key)
      reactivate.()
      assert lenders(ctx) == []

      # An instance entry, lent to a person active here.
      {person, _user} = Sanctum.TestContext.person!(ctx)
      offered = instance!()
      commit!(person, @lend_dep, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})
      assert [%{source: "instance"}] = lenders(person)

      {:ok, _} =
        Arca.InstanceEntries.move_binding(
          Arca.Test.Actor.platform(),
          offered.id,
          "sha256:instance",
          %{
            destination:
              ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v2/"],"scheme":"https"}),
            binding_digest: "sha256:moved"
          },
          "needs_consent"
        )

      reactivate.()
      assert lenders(person) == []

      {:ok, _} =
        Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), offered.id, "needs_consent")

      reactivate.()
      assert lenders(person) == []
    end
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  # `profile.plan`'s answer over a lender the store could not answer: the
  # typed reason, read in its class's sentence.
  defp assert_unreadable(answer) do
    assert {:error, {:lender_unavailable, @lend_dep} = reason} = answer

    assert %Prima.Refusal{class: :unavailable, message: @unreadable} =
             Grimoire.Error.classify(reason)
  end

  # `profile.plan`'s answer over a damaged lender, naming the profile to
  # revoke.
  defp assert_damaged(answer, lender) do
    assert {:error, {:lender_corrupt, @lend_dep, ^lender} = reason} = answer

    damaged =
      "A profile that lends a key here is damaged and cannot lend its key — " <>
        "revoke profile #{lender} and grant it again."

    assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)
  end

  describe "a closure that cannot be resolved" do
    test "is unresolved, naming what is missing, with no rows and no selection", %{ctx: ctx} do
      publish!(ctx, "plan-orphan", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.plan-absent"}]},
        "caps" => %{"egress" => %{"domains" => ["api.orphan.example"]}}
      })

      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-orphan"})

      assert plan.unresolved == %{
               reason: "unresolvable_dependency",
               missing: "reagent:local.plan-absent"
             }

      # The source's own rows are not the ask: none is drawn.
      assert plan.rows == []
      assert plan.dependency_needs == []

      # The preview refuses it, naming the same missing ref.
      assert {:error,
              {:activation_unresolvable, {:incomplete, {:unresolvable_dependency, missing}}}} =
               Sanctum.Consent.Commit.preview(ctx, %{ref: "reagent:local.plan-orphan"})

      assert missing == "reagent:local.plan-absent"

      assert {:error, message} =
               Sanctum.Providers.Profile.handle(ctx, %{
                 "action" => "preview",
                 "decisions" => %{"ref" => "reagent:local.plan-orphan"}
               })

      assert message =~ "reagent:local.plan-absent"
    end

    test "a resolved closure is not unresolved", %{ctx: ctx} do
      publish!(ctx, "plan-alone", "1.0.0", %{})
      {:ok, plan} = Plan.plan(ctx, %{ref: "reagent:local.plan-alone"})
      assert plan.unresolved == nil
      assert [_limits] = plan.rows
    end
  end

  describe "a tincture's declarations" do
    @declaration %{
      "frame" => %{"capabilities" => ["pointer_lock"], "placement" => "float"},
      "streams" => [%{"name" => "executions.deltas", "subject" => "run_1"}],
      "cards" => [
        %{"name" => "about", "title" => "About"},
        %{
          "name" => "today",
          "title" => "Today",
          "source" => %{
            "component" => "reagent:local.plan-dep",
            "operation" => "run",
            "args" => %{"city" => "Lisbon"}
          }
        }
      ],
      "actions" => ["execution.list"]
    }

    test "are rows: the frame, each stream, each card and the system actions", %{ctx: ctx} do
      ref = tincture!(ctx, "plan-frame", "1.0.0", @declaration)
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      grouped = by_kind(decode!(plan.rows))

      assert grouped[{:frame, ref}] == [
               %{
                 "capabilities" => ["pointer_lock"],
                 "placement" => "float",
                 "background" => false
               }
             ]

      assert grouped[{:streams, ref}] == [%{"name" => "executions.deltas", "subject" => "run_1"}]

      assert grouped[{:cards, ref}] == [
               %{"name" => "about"},
               %{
                 "name" => "today",
                 "component" => "reagent:local.plan-dep",
                 "operation" => "run",
                 "args" => %{"city" => "Lisbon"}
               }
             ]

      assert grouped[{:system_actions, ref}] == [%{"actions" => ["execution.list"]}]
    end

    test "a version adding background permission and widening a stream's subject changes " <>
           "the shape, and its rows show exactly what was added",
         %{ctx: ctx} do
      ref = tincture!(ctx, "plan-drift", "1.0.0", @declaration)
      {:ok, before} = Plan.plan(ctx, %{ref: ref})

      wider =
        @declaration
        |> put_in(["frame", "background"], true)
        |> Map.put("streams", [%{"name" => "executions.deltas", "subject" => "*"}])

      tincture!(ctx, "plan-drift", "1.1.0", wider)
      {:ok, later} = Plan.plan(ctx, %{ref: ref})

      refute later.shape_digest == before.shape_digest

      assert later.rows -- before.rows == [
               %{
                 "kind" => "frame",
                 "node" => ref,
                 "narrowed" => false,
                 "values" => %{
                   "capabilities" => ["pointer_lock"],
                   "placement" => "float",
                   "background" => true
                 }
               },
               %{
                 "kind" => "streams",
                 "node" => ref,
                 "narrowed" => false,
                 "values" => %{"name" => "executions.deltas", "subject" => "*"}
               }
             ]

      assert length(before.rows -- later.rows) == 2
    end

    test "one stream declared under two subjects is two rows, one per subject", %{ctx: ctx} do
      ref =
        tincture!(ctx, "plan-subjects", "1.0.0", %{
          "streams" => [
            %{"name" => "executions.deltas", "subject" => "run_1"},
            %{"name" => "executions.deltas", "subject" => "*"},
            %{"name" => "executions.deltas"}
          ]
        })

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert by_kind(decode!(plan.rows))[{:streams, ref}] == [
               %{"name" => "executions.deltas"},
               %{"name" => "executions.deltas", "subject" => "*"},
               %{"name" => "executions.deltas", "subject" => "run_1"}
             ]
    end

    test "a tincture that declares nothing has no declaration rows", %{ctx: ctx} do
      ref = tincture!(ctx, "plan-bare", "1.0.0", %{})
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert Enum.map(plan.rows, & &1["kind"]) == ["limits"]
    end
  end
end
