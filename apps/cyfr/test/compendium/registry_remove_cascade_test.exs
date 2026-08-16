# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryRemoveCascadeTest do
  # §3.10: removing a component revokes its profiles and takes its
  # registrations with it. Consents stay as history; vault entries stay
  # because they are the operator's, not the component's.
  use ExUnit.Case, async: false

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "remove_cascade_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp publish!(ctx, name, version) do
    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: version,
        type: "reagent"
      })

    component
  end

  defp seed_profile!(ctx, name_ref) do
    profile_id = "prof-cascade-#{System.unique_integer([:positive])}"

    {:ok, consent} =
      Arca.ConsentStorage.mint_profile_with_revision(
        %{
          id: profile_id,
          athanor_id: ctx.athanor_id,
          source_ref: name_ref,
          kind: "owner",
          label: "default",
          status: "active"
        },
        %{
          athanor_id: ctx.athanor_id,
          profile_id: profile_id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:s",
          commit_digest: "sha256:c",
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "test",
          granted_via: "bootstrap"
        },
        []
      )

    {profile_id, consent}
  end

  test "removing the last version revokes profiles and keeps consent history",
       %{ctx: ctx} do
    publish!(ctx, "cascade-target", "1.0.0")
    name_ref = "reagent:local.cascade-target"
    {profile_id, consent} = seed_profile!(ctx, name_ref)

    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{name: "survivor", kind: "api_key", fields: %{"k" => "v"}})

    :ok = Compendium.Registry.delete(ctx, "cascade-target", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(ctx.athanor_id, profile_id)
    assert profile.status == "revoked"

    # Consents are insert-only history — the revoked status is the gate.
    assert Arca.Repo.get(Arca.Schemas.Consent, consent.id)

    # Vault entries are the operator's and outlive the component.
    assert {:ok, %{status: "active"}} = Arca.VaultStorage.get(ctx.athanor_id, entry.id)
  end

  test "a webhook pointed at the removed component is disabled", %{ctx: ctx} do
    publish!(ctx, "cascade-hooked", "1.0.0")

    Sanctum.Test.ConsentFixtures.start_source!()

    profile =
      Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.cascade-hooked:1.0.0")

    {:ok, _} =
      Sanctum.Webhook.create(ctx, %{
        name: "cascade-hook",
        target_ref: "reagent:local.cascade-hooked:1.0.0",
        profile_id: profile
      })

    :ok = Compendium.Registry.delete(ctx, "cascade-hooked", "1.0.0", "local")

    {:ok, live} = Arca.WebhookStorage.list_webhooks(ctx.athanor_id)

    refute Enum.any?(live, &(&1.name == "cascade-hook"))
  end

  test "removing one of several versions cascades nothing", %{ctx: ctx} do
    publish!(ctx, "cascade-multi", "1.0.0")
    publish!(ctx, "cascade-multi", "1.0.1")
    {profile_id, _} = seed_profile!(ctx, "reagent:local.cascade-multi")

    :ok = Compendium.Registry.delete(ctx, "cascade-multi", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(ctx.athanor_id, profile_id)
    assert profile.status == "active"
  end

  test "an unrelated component's profile is untouched", %{ctx: ctx} do
    publish!(ctx, "cascade-a", "1.0.0")
    publish!(ctx, "cascade-b", "1.0.0")
    {other_id, _} = seed_profile!(ctx, "reagent:local.cascade-b")

    :ok = Compendium.Registry.delete(ctx, "cascade-a", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(ctx.athanor_id, other_id)
    assert profile.status == "active"
  end
end
