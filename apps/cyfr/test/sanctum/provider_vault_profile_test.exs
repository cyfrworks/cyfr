# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderVaultProfileTest do
  use ExUnit.Case, async: false

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "mcp_vault_profile_#{:rand.uniform(1_000_000)}")
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

  test "the whole walk works over the wire shape — string keys end to end", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-walk",
        version: "1.0.0",
        type: "reagent"
      })

    # vault.create over wire args
    {:ok, %{entry: entry}} =
      Sanctum.Provider.handle("vault", ctx, %{
        "action" => "create",
        "name" => "wire-conn",
        "kind" => "api_key",
        "fields" => %{"url" => "https://db.example", "anon_key" => "anon"}
      })

    {:ok, %{entries: entries}} = Sanctum.Provider.handle("vault", ctx, %{"action" => "list"})
    assert Enum.any?(entries, &(&1.id == entry.id))

    # profile.plan
    {:ok, plan} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-walk"
      })

    assert plan.expected_consent_revision == 0

    decisions = %{
      "ref" => "reagent:local.mcp-walk",
      "bindings" => [
        %{"need" => "@ingress", "entry_id" => entry.id, "fields" => ["url", "anon_key"]}
      ]
    }

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    {:ok, committed} =
      Sanctum.Provider.handle("profile", ctx, %{
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
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "list",
        "ref" => "reagent:local.mcp-walk"
      })

    assert profile.head_revision == 1

    # profile.revoke closes it out
    {:ok, %{status: "revoked"}} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "revoke",
        "profile_id" => committed.profile_id
      })

    {:ok, reloaded} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), committed.profile_id)
    assert reloaded.status == "revoked"
  end

  test "conflicts cross the boundary as a typed consent signal", %{ctx: ctx} do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "mcp-conflict",
        version: "1.0.0",
        type: "reagent"
      })

    decisions = %{"ref" => "reagent:local.mcp-conflict"}

    {:ok, plan} =
      Sanctum.Provider.handle("profile", ctx, %{
        "action" => "plan",
        "ref" => "reagent:local.mcp-conflict"
      })

    {:ok, preview} =
      Sanctum.Provider.handle("profile", ctx, %{"action" => "preview", "decisions" => decisions})

    # Typed to the boundary: the wire router promotes this to a protocol
    # error (-33503 + error.data via Emissary.MCP.ConsentSignal).
    assert {:error, {:consent_conflict, payload}} =
             Sanctum.Provider.handle("profile", ctx, %{
               "action" => "commit",
               "decisions" => decisions,
               "plan_token" => plan.plan_token,
               "proof" => preview.proof,
               "commit_digest" => preview.commit_digest,
               "expected_consent_revision" => 7
             })

    assert %{cause: :stale_plan, actual_revision: 0} = payload
    assert Emissary.MCP.ConsentSignal.signal?({:consent_conflict, payload})
  end

  test "the tincture session surface is named in the refusal", %{ctx: ctx} do
    session_ctx = %{ctx | auth_method: :session}

    assert {:error, "consent_class_required:" <> _} =
             Sanctum.Provider.handle("vault", session_ctx, %{"action" => "list"})
  end

  test "a limits decision is refused rather than signed and ignored", %{ctx: ctx} do
    # It rode the commit digest and stopped there: the blob is built from the
    # manifest's caps, so the operator's number was proofed and recorded while
    # the runtime kept the manifest's. Refusing keeps the digest a promise
    # about what actually runs.
    for action <- ["preview", "commit"] do
      assert {:error, "limits are not a consent decision" <> _} =
               Sanctum.Provider.handle("profile", ctx, %{
                 "action" => action,
                 "decisions" => %{
                   "ref" => "reagent:local.mcp-walk",
                   "limits" => %{"timeout" => "1s"}
                 }
               })
    end
  end
end
