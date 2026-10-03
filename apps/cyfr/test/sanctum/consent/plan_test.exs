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

  alias Prima.ConsentPreview
  alias Sanctum.Consent.Plan

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @dep "reagent:local.plan-dep"
  @source "reagent:local.plan-source"
  # The plan binds no commit digest; decoding its rows as a preview needs one.
  @placeholder_digest "sha256:" <> String.duplicate("0", 64)

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
        "commit_digest" => @placeholder_digest
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

    defp oauth_entry!(ctx, scopes, hint \\ "google") do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "mail-#{System.unique_integer([:positive])}",
          kind: "oauth",
          provider_hint: hint,
          oauth: %{"access_token" => "t"},
          oauth_scopes: scopes
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
          fields: %{"KEY" => "k"}
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

      wider = oauth_entry!(ctx, ["gmail.readonly", "gmail.send"], "attenuating-idp")
      {:ok, plan} = Plan.plan(ctx, %{ref: @mail_ref})

      assert %{narrowable: true} = Enum.find(plan.candidates, &(&1.id == wider.id))
      assert mail_warnings(plan) == []
    end
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
