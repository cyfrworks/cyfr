# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlanTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source
  alias Sanctum.Vault

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_setup_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
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
      Vault.create(ctx, %{name: "plan-conn", kind: "api_key", fields: %{"k" => "v"}})

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
      Vault.create(ctx, %{name: "rebound-conn", kind: "api_key", fields: %{"k" => "v"}})

    grant!(ctx, "reagent:local.plan-rebound", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.rebind(ctx, %{id: entry.id, oauth_scopes: ["new.scope"]})

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-rebound")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "rebound"
    refute plan.ready
  end

  test "a revoked connection makes the plan not-ready", %{ctx: ctx} do
    publish!(ctx, "plan-revoked")

    {:ok, entry} =
      Vault.create(ctx, %{name: "revoked-conn", kind: "api_key", fields: %{"k" => "v"}})

    grant!(ctx, "reagent:local.plan-revoked", [%{need: "@ingress", entry_id: entry.id}])
    {:ok, _} = Vault.revoke(ctx, entry.id)

    {:ok, plan} = Compendium.Component.setup_plan(ctx, "reagent:local.plan-revoked")

    assert [%{satisfied: false, detail: detail}] = plan.consent.needs
    assert detail =~ "revoked"
    refute plan.ready
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
