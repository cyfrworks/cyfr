# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlanTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Vault

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_setup_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent"
      })

    component
  end

  @dep "reagent:local.plan-dep"

  @limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 100, "window" => "1m"},
    "max_concurrent_tasks" => 5,
    "batch_timeout" => "1m"
  }

  defp publish_manifest!(ctx, name, manifest_extra) do
    manifest =
      Map.merge(%{"name" => name, "version" => "1.0.0", "type" => "reagent"}, manifest_extra)

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    component
  end

  # The consent walk a person makes: plan, preview, commit.
  defp walk!(ctx, decisions) do
    {:ok, plan} = Plan.plan(ctx, Map.take(decisions, [:ref, :label]))
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

  # `ref`'s owner head, written as it is stored: a revision whose source
  # node holds `edges` beside its ingress, and `refs` as its rows.
  defp seed!(ctx, ref, edges, refs) do
    nodes = %{ref => %{"limits" => @limits, "edges" => Map.put(edges, "@ingress", %{})}}

    nodes =
      if edges == %{},
        do: nodes,
        else: Map.put(nodes, @dep, %{"limits" => @limits, "edges" => %{}})

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{id: "prof_#{ref}", source_ref: ref, kind: :owner, status: :active},
        %{
          id: "cons_#{ref}",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: Jason.encode!(%{"canonical" => "jcs-1", "nodes" => nodes}),
          activation: %{ref => "sha256:act"},
          admitted_origins: [:interactive],
          vault_refs: refs
        }
      )
  end

  # A head whose edge into the dependency selects its profile through
  # `via`, with the borrower's own row for it, pinning what `via` pins.
  defp seed_selection!(ctx, ref, via) do
    seed!(ctx, ref, %{@dep => %{"vault" => %{"via" => via}}}, [
      %{
        binding_key: Prima.Authority.Blob.binding_key(ref, @dep, nil),
        scope: "athanor",
        via_label: via["label"],
        binding_digest: via["binding_digest"]
      }
    ])
  end

  defp grant!(ctx, ref, bindings) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: bindings}
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

  @tag :capture_log
  test "a consent store that cannot answer is not ready, never 'no profile'", %{ctx: ctx} do
    publish!(ctx, "plan-outage")
    Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-outage")

    assert %{profile_status: :unavailable, ready: false} = plan.consent
    assert plan.ready == false
  end

  test "an owner profile that cannot be decoded is reported, not skipped", %{ctx: ctx} do
    publish!(ctx, "plan-damaged")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "plan-damaged-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    grant!(ctx, "reagent:local.plan-damaged", [%{need: "@ingress", entry_id: entry.id}])

    {:ok, [%{id: profile_id}]} =
      Sanctum.Consent.profiles(ctx, "reagent:local.plan-damaged")

    Arca.Repo.update_all(
      Ecto.Query.from(p in Arca.Schemas.Profile,
        where: p.athanor_id == ^ctx.athanor_id and p.id == ^profile_id
      ),
      set: [kind: "sideways"]
    )

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-damaged")

    assert %{profile_id: ^profile_id, profile_status: :corrupt, ready: false} = plan.consent
    assert plan.ready == false
  end

  test "a component with no profile and no needs is ready", %{ctx: ctx} do
    publish!(ctx, "plan-no-profile")

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-no-profile")

    assert plan.consent == nil
    assert plan.needs == []
    assert plan.ready == true
  end

  test "a granted profile reports ready from its consent", %{ctx: ctx} do
    publish!(ctx, "plan-granted")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "plan-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    grant!(ctx, "reagent:local.plan-granted", [%{need: "@ingress", entry_id: entry.id}])

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-granted")

    assert plan.consent.revision == 1
    assert plan.consent.profile_kind == :owner
    assert [%{satisfied: true, detail: detail}] = plan.consent.needs
    assert detail =~ "plan-conn"
    assert plan.ready
  end

  test "a rebound connection makes the plan not-ready with an actionable detail",
       %{ctx: ctx} do
    publish!(ctx, "plan-rebound")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "rebound-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    grant!(ctx, "reagent:local.plan-rebound", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.rebind(ctx, %{id: entry.id, field_names: ["k", "region"]})

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-rebound")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "rebound"
    refute plan.ready
  end

  test "a revoked connection makes the plan not-ready", %{ctx: ctx} do
    publish!(ctx, "plan-revoked")

    {:ok, entry} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "revoked-conn",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    grant!(ctx, "reagent:local.plan-revoked", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.revoke(ctx, entry.id)

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-revoked")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "revoked"
    refute plan.ready
  end

  describe "a borrowed key" do
    # The dependency declares one key and its own profile binds an entry;
    # each source depends on it and selects that profile. A selection
    # resolves under the origin a run carries: here the console's
    # `interactive`, which the lender's grant admits.
    setup %{ctx: ctx} do
      ctx = Sanctum.TestContext.via(ctx, :prism)

      publish_manifest!(ctx, "plan-dep", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:example.com",
            "reason" => "to call the example API",
            "required" => true,
            "fields" => ["KEY"]
          }
        }
      })

      for name <- ~w(plan-borrower plan-loose) do
        publish_manifest!(ctx, name, %{"dependencies" => %{"static" => [%{"ref" => @dep}]}})
      end

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "lent-conn",
          kind: "api_key",
          fields: %{"KEY" => "k"},
          destination: %{"hosts" => ["api.example.com"]}
        })

      walk!(ctx, %{ref: @dep, bindings: [%{need: "api_key", entry_id: entry.id}]})
      {:ok, ctx: ctx, entry: entry}
    end

    test "pinned by the walk, reads ready from the lender's entry, and not ready once it moves",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-borrower"
      walk!(ctx, %{ref: ref, selections: [%{dep: @dep, label: "default"}]})

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      entry_id = entry.id
      assert [%{entry_id: ^entry_id, satisfied: true, detail: detail}] = plan.consent.needs
      assert detail =~ "lent-conn"
      assert plan.ready

      # The lender's entry is rebound: the lender waits on a new consent,
      # so the selection resolves to nothing, which is said, not raised.
      {:ok, _} = Vault.rebind(ctx, %{id: entry.id, field_names: ["KEY", "ORG"]})

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{entry_id: nil, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "default"
      refute plan.ready
    end

    test "unpinned, resolves as a run resolves it, and a label no profile has is not ready",
         %{ctx: ctx, entry: entry} do
      ref = "reagent:local.plan-loose"

      seed_selection!(ctx, ref, %{"label" => "default"})
      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      entry_id = entry.id
      assert [%{entry_id: ^entry_id, satisfied: true, detail: detail}] = plan.consent.needs
      assert detail =~ "lent-conn"
      assert plan.ready

      seed_selection!(ctx, ref, %{"label" => "work"})
      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{entry_id: nil, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "work"
      refute plan.ready
    end

    test "a row naming an instance entry is not ready, and nothing reads it as the athanor's",
         %{ctx: ctx} do
      ref = "reagent:local.plan-loose"

      {:ok, instance} =
        Arca.InstanceEntries.put(Arca.Test.Actor.platform(), %{
          name: "instance-#{System.unique_integer([:positive])}",
          kind: "api_key",
          provider_hint: "example.com",
          field_names: ~s(["KEY"]),
          destination:
            ~s({"hosts":["api.example.com"],"methods":["GET"],"paths":["/v1/"],"scheme":"https"}),
          sealed_payload: "sealed",
          binding_digest: "sha256:instance",
          audience: "everyone",
          created_by: "usr_admin"
        })

      seed!(ctx, ref, %{}, [
        %{
          binding_key: Prima.Authority.Blob.binding_key(ref, "@ingress", nil),
          scope: "instance",
          instance_entry_id: instance.id,
          binding_digest: "sha256:instance"
        }
      ])

      {:ok, plan} = Compendium.Component.setup_plan(ctx, ref)

      assert [%{entry_id: nil, satisfied: false, detail: detail}] = plan.consent.needs
      assert detail =~ "instance"
      refute plan.ready
    end
  end

  test "a consent binding nothing is ready — an egress-only grant is complete",
       %{ctx: ctx} do
    publish!(ctx, "plan-bare")
    grant!(ctx, "reagent:local.plan-bare", [])

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-bare")

    assert plan.consent.needs == []
    assert plan.ready
  end
end
