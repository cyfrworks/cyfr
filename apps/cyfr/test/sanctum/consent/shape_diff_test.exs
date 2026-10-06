# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDiffTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.ShapeDiff

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "shape_diff_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "diffed",
        version: "1.0.0",
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "diffed",
            "version" => "1.0.0",
            "type" => "reagent"
          })
      })

    {:ok, ctx: ctx}
  end

  @source "reagent:local.diffed"

  defp blob(edge) do
    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        @source => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 100, "window" => "1m"},
            "max_concurrent_tasks" => 1,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => edge}
        }
      }
    })
  end

  # The live side is the latest release's manifest caps: publishing a newer
  # version with the wanted caps is how a test moves the live shape.
  defp publish_live!(ctx, version, caps) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "diffed",
        version: version,
        type: "reagent",
        manifest:
          Jason.encode!(%{
            "name" => "diffed",
            "version" => version,
            "type" => "reagent",
            "caps" => caps
          })
      })

    :ok
  end

  test "a widened capability is named with what appeared", %{ctx: ctx} do
    publish_live!(ctx, "1.0.1", %{"egress" => %{"domains" => ["a.example", "b.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["a.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{capability: "egress.domains", change: :widened, added: ["b.example"], removed: []} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "a narrowed capability is named with what went away", %{ctx: ctx} do
    publish_live!(ctx, "1.0.2", %{"egress" => %{"domains" => ["a.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["a.example", "gone.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :narrowed, added: [], removed: ["gone.example"]} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "both directions at once read as changed", %{ctx: ctx} do
    publish_live!(ctx, "1.0.3", %{"egress" => %{"domains" => ["new.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["old.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :changed, added: ["new.example"], removed: ["old.example"]} =
             Enum.find(diff, &(&1.capability == "egress.domains"))
  end

  test "an unchanged capability produces no entry", %{ctx: ctx} do
    publish_live!(ctx, "1.0.4", %{"egress" => %{"domains" => ["same.example"]}})

    granted = blob(%{"egress" => %{"domains" => ["same.example"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    refute Enum.any?(diff, &(&1.capability == "egress.domains"))
  end

  test "storage and tools are covered too", %{ctx: ctx} do
    publish_live!(ctx, "1.0.5", %{
      "storage" => %{"paths" => ["data/"], "actions" => ["read", "write"]}
    })

    granted = blob(%{"storage" => %{"paths" => ["data/"], "actions" => ["read"]}})
    diff = ShapeDiff.compute(ctx, @source, granted)

    assert %{change: :widened, added: ["write"]} =
             Enum.find(diff, &(&1.capability == "storage.actions"))
  end

  test "a host the ask still covers is never reported as dropped", %{ctx: ctx} do
    # The ask moved to a wildcard: the plain host the person was granted is
    # still inside it, as the egress pin reads a domain grant.
    publish_live!(ctx, "1.0.6", %{"egress" => %{"domains" => ["*.covered.example"]}})

    granted =
      blob(%{
        "egress" => %{"domains" => ["api.covered.example", "gone.elsewhere.example"]}
      })

    diff = ShapeDiff.compute(ctx, @source, granted)
    entry = Enum.find(diff, &(&1.capability == "egress.domains"))

    assert entry.removed == ["gone.elsewhere.example"]
    refute "api.covered.example" in entry.removed
    assert entry.added == ["*.covered.example"]

    # A grant every host of which the ask still covers drops nothing.
    covered =
      ShapeDiff.compute(
        ctx,
        @source,
        blob(%{"egress" => %{"domains" => ["api.covered.example"]}})
      )

    refute Enum.any?(covered, &(&1.capability == "egress.domains" and &1.removed != []))
  end

  describe "provided configuration" do
    @dep "reagent:local.diffed-db"

    defp publish_app!(ctx, version, host, values) do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "diffed-app",
          version: version,
          type: "reagent",
          manifest:
            Jason.encode!(%{
              "name" => "diffed-app",
              "version" => version,
              "type" => "reagent",
              "dependencies" => %{"static" => [%{"ref" => @dep}]},
              "provides" => %{
                @dep => %{
                  "database" => %{"destination" => %{"hosts" => [host]}, "values" => values}
                }
              }
            })
        })

      Arca.Cache.delete_match(:_)
    end

    setup %{ctx: ctx} do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "diffed-db",
          version: "1.0.0",
          type: "reagent",
          manifest:
            Jason.encode!(%{
              "name" => "diffed-db",
              "version" => "1.0.0",
              "type" => "reagent",
              "needs" => %{
                "database" => %{
                  "type" => "api_key:supabase.co",
                  "reason" => "to reach the database",
                  "fields" => ["anon_key"],
                  "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
                }
              }
            })
        })

      :ok
    end

    test "a changed provided address is a new shape, and the diff names the dependency, the " <>
           "need and what moved, never a value",
         %{ctx: ctx} do
      ref = "reagent:local.diffed-app"
      publish_app!(ctx, "1.0.0", "abc.supabase.co", %{"anon_key" => "eyJ-one"})

      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, %{ref: ref})

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: %{ref: ref},
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      publish_app!(ctx, "1.1.0", "xyz.supabase.co", %{"anon_key" => "eyJ-two", "url" => "u"})
      {:ok, moved} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})

      refute moved.shape_digest == plan.shape_digest

      assert [entry] = Enum.filter(moved.shape_diff, &(&1.capability == "provided.#{@dep}"))

      # The app's own configuration, so the app's node.
      assert entry == %{
               node: ref,
               capability: "provided.#{@dep}",
               change: :changed,
               need: "database",
               added: ["destination https://xyz.supabase.co", "value url"],
               removed: ["destination https://abc.supabase.co"],
               new: false,
               dropped: false
             }

      refute inspect(moved.shape_diff) =~ "eyJ"
    end
  end

  describe "every node of the closure" do
    @lib "reagent:local.diffed-lib"
    @user "reagent:local.diffed-user"

    defp publish_reagent!(ctx, name, version, manifest) do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: name,
          version: version,
          type: "reagent",
          manifest:
            Jason.encode!(
              Map.merge(manifest, %{"name" => name, "version" => version, "type" => "reagent"})
            )
        })

      Arca.Cache.delete_match(:_)
    end

    # A dependency a release adds is listed as new: the plan, the diff an
    # admission computes (`compute/3`, resolving the closure itself) and the
    # `consent_required` a run is refused with carry the one list, each
    # entry naming its node and whether it is new or dropped.
    test "a dependency a release adds is listed as new, alike by the plan, by compute/3 and " <>
           "by the consent_required an admission refuses with",
         %{ctx: ctx} do
      caps = %{"egress" => %{"domains" => ["api.user.example"], "methods" => ["GET"]}}

      publish_reagent!(ctx, "diffed-lib", "1.0.0", %{
        "caps" => %{"egress" => %{"domains" => ["api.lib.example"], "methods" => ["GET"]}}
      })

      publish_reagent!(ctx, "diffed-user", "1.0.0", %{"caps" => caps})

      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: @user})
      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, %{ref: @user})

      {:ok, %{profile_id: profile_id}} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: %{ref: @user},
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      publish_reagent!(ctx, "diffed-user", "1.1.0", %{
        "caps" => caps,
        "dependencies" => %{"static" => [%{"ref" => @lib}]}
      })

      {:ok, moved} = Sanctum.Consent.Plan.plan(ctx, %{ref: @user})

      assert moved.shape_diff == [
               %{
                 node: @lib,
                 capability: "egress.domains",
                 change: :widened,
                 added: ["api.lib.example"],
                 removed: [],
                 new: true,
                 dropped: false
               },
               %{
                 node: @lib,
                 capability: "egress.methods",
                 change: :widened,
                 added: ["GET"],
                 removed: [],
                 new: true,
                 dropped: false
               },
               %{
                 node: @lib,
                 capability: "egress.schemes",
                 change: :widened,
                 added: ["https"],
                 removed: [],
                 new: true,
                 dropped: false
               }
             ]

      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      assert ShapeDiff.compute(ctx, @user, head.resolved_policy) == moved.shape_diff

      # A run the head's origins admit, so what refuses it is the moved shape.
      assert {:error, {:consent_required, payload}} =
               Crucible.Admission.authority_for(
                 %{ctx | origin: :interactive},
                 :default,
                 "#{@user}:1.1.0"
               )

      assert payload.profile_id == profile_id
      assert payload.shape_diff == moved.shape_diff
    end
  end

  test "an underivable side yields no diff, never a wrong one", %{ctx: ctx} do
    assert ShapeDiff.compute(ctx, @source, "not a blob") == []
    assert ShapeDiff.compute(ctx, "reagent:local.never-published", blob(%{})) == []
  end
end
