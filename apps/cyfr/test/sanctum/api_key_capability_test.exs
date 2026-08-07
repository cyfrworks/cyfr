# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ApiKeyCapabilityTest do
  use ExUnit.Case, async: false

  alias Sanctum.ApiKey
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))
  @digest "sha256:" <> String.duplicate("ab", 32)

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "key_capability_#{:rand.uniform(1_000_000)}")
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

  defp future, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  describe "minting a capability-bearing key" do
    test "requires the interactive class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, {:surface_not_permitted, :api_key}} =
               ApiKey.create(key_ctx, %{
                 name: "cap-key-denied",
                 consent_capability: %{commit_digest: @digest, expires_at: future()}
               })

      assert {:ok, _} =
               ApiKey.create(ctx, %{
                 name: "cap-key-ok",
                 consent_capability: %{commit_digest: @digest, expires_at: future()}
               })
    end

    test "refuses malformed digests and past expiries", %{ctx: ctx} do
      assert {:error, :invalid_consent_capability} =
               ApiKey.create(ctx, %{
                 name: "cap-bad-digest",
                 consent_capability: %{commit_digest: "not-a-digest", expires_at: future()}
               })

      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:error, :capability_already_expired} =
               ApiKey.create(ctx, %{
                 name: "cap-expired",
                 consent_capability: %{commit_digest: @digest, expires_at: past}
               })
    end

    test "an ordinary key stores no capability and reads back nil", %{ctx: ctx} do
      {:ok, _} = ApiKey.create(ctx, %{name: "plain-key"})
      {:ok, row} = Arca.ApiKeyStorage.get_key("plain-key", "project", ctx.org_id, ctx.project_id)

      assert row.capability == nil
      assert {:ok, nil} = ApiKey.consent_capability(ctx, row.id)
    end

    test "consent_capability round-trips the envelope", %{ctx: ctx} do
      expires = future()

      {:ok, _} =
        ApiKey.create(ctx, %{
          name: "cap-roundtrip",
          consent_capability: %{commit_digest: @digest, expires_at: expires}
        })

      {:ok, row} =
        Arca.ApiKeyStorage.get_key("cap-roundtrip", "project", ctx.org_id, ctx.project_id)

      {:ok, capability} = ApiKey.consent_capability(ctx, row.id)
      assert capability.commit_digest == @digest
      assert DateTime.diff(capability.expires_at, expires) == 0
    end
  end

  describe "the scoped-automation walk" do
    defp publish!(ctx, name) do
      {:ok, component} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: name,
          version: "1.0.0",
          type: "reagent"
        })

      component
    end

    test "a caveated key commits exactly its pinned digest", %{ctx: ctx} do
      publish!(ctx, "cap-walk")
      key_ctx = %{ctx | auth_method: :api_key}

      # Stage as the automation would: plan + preview are open to keys.
      {:ok, plan} = Plan.plan(key_ctx, %{ref: "reagent:local.cap-walk"})
      decisions = %{ref: "reagent:local.cap-walk"}
      {:ok, preview} = Commit.preview(key_ctx, decisions)

      # The interactive operator mints the capability for THIS digest.
      {:ok, _} =
        ApiKey.create(ctx, %{
          name: "cap-walk-key",
          consent_capability: %{commit_digest: preview.commit_digest, expires_at: future()}
        })

      {:ok, row} =
        Arca.ApiKeyStorage.get_key("cap-walk-key", "project", ctx.org_id, ctx.project_id)

      {:ok, capability} = ApiKey.consent_capability(ctx, row.id)

      assert {:ok, committed} =
               Commit.commit(
                 key_ctx,
                 %{
                   decisions: decisions,
                   plan_token: plan.plan_token,
                   proof: preview.proof,
                   commit_digest: preview.commit_digest,
                   expected_consent_revision: 0
                 },
                 key_capability: capability
               )

      {:ok, head, _refs} = Arca.ConsentStorage.get_head(ctx.org_id, committed.profile_id)
      assert head.granted_via == "scoped_key"
    end

    test "a capability for a different digest is refused", %{ctx: ctx} do
      publish!(ctx, "cap-wrong")
      key_ctx = %{ctx | auth_method: :api_key}

      {:ok, plan} = Plan.plan(key_ctx, %{ref: "reagent:local.cap-wrong"})
      decisions = %{ref: "reagent:local.cap-wrong"}
      {:ok, preview} = Commit.preview(key_ctx, decisions)

      assert {:error, :capability_digest_mismatch} =
               Commit.commit(
                 key_ctx,
                 %{
                   decisions: decisions,
                   plan_token: plan.plan_token,
                   proof: preview.proof,
                   commit_digest: preview.commit_digest,
                   expected_consent_revision: 0
                 },
                 key_capability: %{commit_digest: @digest, expires_at: future()}
               )
    end

    test "overrides are refused from any key, capability or not", %{ctx: ctx} do
      publish!(ctx, "cap-override")
      key_ctx = %{ctx | auth_method: :api_key}

      {:ok, plan} = Plan.plan(key_ctx, %{ref: "reagent:local.cap-override"})
      decisions = %{ref: "reagent:local.cap-override", override: true}
      {:ok, preview} = Commit.preview(key_ctx, decisions)

      assert {:error, :override_requires_interactive} =
               Commit.commit(
                 key_ctx,
                 %{
                   decisions: decisions,
                   plan_token: plan.plan_token,
                   proof: preview.proof,
                   commit_digest: preview.commit_digest,
                   expected_consent_revision: 0
                 },
                 key_capability: %{commit_digest: preview.commit_digest, expires_at: future()}
               )
    end
  end
end
