# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCPVaultProfileTest do
  use ExUnit.Case, async: false

  alias Sanctum.Consent.Source

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "mcp_vault_profile_#{:rand.uniform(1_000_000)}")
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

  test "the whole walk works over the wire shape — string keys end to end", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-walk",
        version: "1.0.0",
        type: "reagent"
      })

    # vault.create over wire args
    {:ok, %{entry: entry}} =
      Sanctum.MCP.handle("vault", ctx, %{
        "action" => "create",
        "name" => "wire-conn",
        "kind" => "api_key",
        "fields" => %{"url" => "https://db.example", "anon_key" => "anon"}
      })

    {:ok, %{entries: entries}} = Sanctum.MCP.handle("vault", ctx, %{"action" => "list"})
    assert Enum.any?(entries, &(&1.id == entry.id))

    # profile.plan
    {:ok, plan} =
      Sanctum.MCP.handle("profile", ctx, %{"action" => "plan", "ref" => "reagent:local.mcp-walk"})

    assert plan.expected_consent_revision == 0

    decisions = %{
      "ref" => "reagent:local.mcp-walk",
      "bindings" => [
        %{"need" => "@ingress", "entry_id" => entry.id, "fields" => ["url", "anon_key"]}
      ]
    }

    {:ok, preview} =
      Sanctum.MCP.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    {:ok, committed} =
      Sanctum.MCP.handle("profile", ctx, %{
        "action" => "commit",
        "decisions" => decisions,
        "plan_token" => plan.plan_token,
        "proof" => preview.proof,
        "commit_digest" => preview.commit_digest,
        "expected_consent_revision" => 0
      })

    assert committed.status == "committed"
    assert committed.revision == 1

    # profile.list shows the head revision
    {:ok, %{profiles: [profile]}} =
      Sanctum.MCP.handle("profile", ctx, %{"action" => "list", "ref" => "reagent:local.mcp-walk"})

    assert profile.head_revision == 1

    # profile.revoke closes it out
    {:ok, %{status: "revoked"}} =
      Sanctum.MCP.handle("profile", ctx, %{
        "action" => "revoke",
        "profile_id" => committed.profile_id
      })

    {:ok, reloaded} = Arca.ProfileStorage.get(ctx.org_id, committed.profile_id)
    assert reloaded.status == "revoked"
  end

  test "conflicts cross the boundary in the tag: json convention", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-conflict",
        version: "1.0.0",
        type: "reagent"
      })

    decisions = %{"ref" => "reagent:local.mcp-conflict"}

    {:ok, plan} =
      Sanctum.MCP.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-conflict"
      })

    {:ok, preview} =
      Sanctum.MCP.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    assert {:error, "consent_conflict: " <> json} =
             Sanctum.MCP.handle("profile", ctx, %{
               "action" => "commit",
               "decisions" => decisions,
               "plan_token" => plan.plan_token,
               "proof" => preview.proof,
               "commit_digest" => preview.commit_digest,
               "expected_consent_revision" => 7
             })

    assert %{"cause" => "stale_plan", "actual_revision" => 0} = Jason.decode!(json)
  end

  test "the tincture session surface is named in the refusal", %{ctx: ctx} do
    session_ctx = %{ctx | auth_method: :session}

    assert {:error, "consent_class_required:" <> _} =
             Sanctum.MCP.handle("vault", session_ctx, %{"action" => "list"})
  end
end
