# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryRemoveCascadeTest do
  # Removal revokes profiles and disables registrations while retaining consents and vault entries.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "remove_cascade_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(:api)}
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
          blob_digest: Prima.Digest.sha256("{}"),
          resolved_policy: "{}",
          activation: "{}",
          admitted_origins: [:interactive],
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
      Sanctum.TestContext.create_vault(ctx, %{
        name: "survivor",
        kind: "api_key",
        fields: %{"k" => "v"},
        destination: %{"hosts" => ["api.example.com"]}
      })

    {:ok, _} = Compendium.Registry.delete(ctx, "cascade-target", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id)
    assert profile.status == "revoked"

    # Consents are insert-only history — the revoked status is the gate.
    assert Arca.Repo.get(Arca.Schemas.Consent, consent.id)

    # Vault entries are the operator's and outlive the component.
    assert {:ok, %{status: "active"}} =
             Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
  end

  test "a webhook pointed at the removed component is disabled", %{ctx: ctx} do
    publish!(ctx, "cascade-hooked", "1.0.0")

    profile =
      Sanctum.Test.ConsentFixtures.bindable_profile(ctx, "reagent:local.cascade-hooked:1.0.0")

    {:ok, _} =
      Sanctum.TestContext.create_webhook(ctx, %{
        name: "cascade-hook",
        replay_protection: "none",
        target_ref: "reagent:local.cascade-hooked:1.0.0",
        profile_id: profile
      })

    {:ok, _} = Compendium.Registry.delete(ctx, "cascade-hooked", "1.0.0", "local")

    {:ok, live} = Arca.WebhookStorage.list_webhooks(Sanctum.Context.actor(ctx))

    refute Enum.any?(live, &(&1.name == "cascade-hook"))
  end

  test "removing one of several versions cascades nothing", %{ctx: ctx} do
    publish!(ctx, "cascade-multi", "1.0.0")
    publish!(ctx, "cascade-multi", "1.0.1")
    {profile_id, _} = seed_profile!(ctx, "reagent:local.cascade-multi")

    {:ok, _} = Compendium.Registry.delete(ctx, "cascade-multi", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id)
    assert profile.status == "active"
  end

  describe "a feed of the removed component" do
    @keys [
      {Arca.ControlPlane, :standing},
      {Arca.ControlPlane, :generation},
      {Arca.ControlPlane, :slot}
    ]

    test "is removed with it", %{ctx: ctx} do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "cascade-feed",
          version: "1.0.0",
          type: "catalyst"
        })

      feed = feed!(ctx, "cascade-feed")
      {:ok, _} = Compendium.Registry.delete(ctx, "cascade-feed", "1.0.0", "local")

      assert {:error, :not_found} =
               Arca.CronSchedule.get_feed(Sanctum.Context.actor(ctx), feed.id)
    end

    test "whose removal is refused is logged by its id and reason, and the uninstall completes",
         %{ctx: ctx} do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "cascade-fenced",
          version: "1.0.0",
          type: "catalyst"
        })

      slot = claimant!()
      feed = feed!(ctx, "cascade-fenced")

      # A successor takes the slot over once the version's bytes are
      # removed, under the live slot as every unit removal is, and as its
      # row goes: this member still believes it holds the slot, so only
      # the feed row's own fenced write refuses.
      take_over_at_row_delete!(slot)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Compendium.Registry.delete(ctx, "cascade-fenced", "1.0.0", "local")
        end)

      assert log =~ "registration #{feed.id} was not removed: not_owner"
      refute log =~ "cascade-secret-arg"
      refute log =~ "Cascade feed label"

      # The component is gone; the feed outlives it, and is said.
      assert {:error, _} = Compendium.Registry.get(ctx, "cascade-fenced", "1.0.0", "local")

      assert {:ok, %{status: "active"}} =
               Arca.CronSchedule.get_feed(Sanctum.Context.actor(ctx), feed.id)
    end
  end

  defp feed!(ctx, name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Cascade feed label",
        "reference" => "catalyst:local.#{name}",
        "operation" => "quote",
        "args" => %{"key" => "cascade-secret-arg"},
        "interval_minutes" => 60,
        "result_shape" => %{"type" => "json"},
        "actions" => []
      })

    {:ok, feed} =
      Arca.CronSchedule.create_feed(Sanctum.Context.actor(ctx), %{
        binding: binding,
        resolved_reference: "catalyst:local.#{name}:1.0.0",
        profile_id: "prof_cascade",
        cap: 1_000
      })

    feed
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none, which would leave a
  # write's live check nothing to check. Restored when the case ends.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-cascade-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # The slot taken over the moment the component's row is deleted, in the
  # deleting process: after the version's bytes are removed, before the
  # removal reaches the component's registrations.
  defp take_over_at_row_delete!(slot) do
    test = self()
    handler = "cascade-takeover-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach(
      handler,
      [:arca, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test and meta[:source] == "components" and is_binary(meta[:query]) and
             String.starts_with?(meta[:query], "DELETE") do
          :telemetry.detach(handler)
          take_over!(slot)
        end
      end,
      nil
    )
  end

  defp take_over!(%{node: node, generation: generation}) do
    {1, _} =
      Arca.Repo.update_all(
        from(l in Arca.Schemas.CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1]
      )

    :ok
  end

  test "an unrelated component's profile is untouched", %{ctx: ctx} do
    publish!(ctx, "cascade-a", "1.0.0")
    publish!(ctx, "cascade-b", "1.0.0")
    {other_id, _} = seed_profile!(ctx, "reagent:local.cascade-b")

    {:ok, _} = Compendium.Registry.delete(ctx, "cascade-a", "1.0.0", "local")

    {:ok, profile} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), other_id)
    assert profile.status == "active"
  end
end
