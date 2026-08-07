# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultTest do
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Vault
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp create!(ctx, over \\ %{}) do
    params =
      Map.merge(
        %{
          name: "supabase-#{System.unique_integer([:positive])}",
          kind: "api_key",
          fields: %{"url" => "https://db.example", "anon_key" => "anon"}
        },
        over
      )

    {:ok, view} = Vault.create(ctx, params)
    view
  end

  defp resource_for(ctx, id) do
    {:ok, entry} = Arca.VaultStorage.get(ctx.org_id, id)
    {:ok, digest} = VaultReader.binding_digest(entry)
    %{entry_id: id, binding_digest: digest}
  end

  defp mint_profile_with_ref(ctx, entry_id, binding_digest) do
    {:ok, profile} =
      Arca.ProfileStorage.put(%{
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        source_ref: "formula:local.consumer",
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _consent} =
      Arca.ConsentStorage.insert_revision(
        %{
          org_id: ctx.org_id,
          profile_id: profile.id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "test",
          granted_via: "bootstrap"
        },
        [%{vault_entry_id: entry_id, binding_digest: binding_digest}],
        nil
      )

    profile
  end

  describe "authorization class" do
    test "no vault mutation is reachable from an api_key surface", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, {:surface_not_permitted, :api_key}} =
               Vault.create(key_ctx, %{name: "x", kind: "api_key"})

      assert {:error, {:surface_not_permitted, :api_key}} = Vault.rename(key_ctx, "vlt_x", "y")

      assert {:error, {:surface_not_permitted, :api_key}} =
               Vault.rotate(key_ctx, %{id: "vlt_x", fields: %{}, expected_payload_rev: 0})

      assert {:error, {:surface_not_permitted, :api_key}} = Vault.rebind(key_ctx, %{id: "vlt_x"})
      assert {:error, {:surface_not_permitted, :api_key}} = Vault.revoke(key_ctx, "vlt_x")
      assert {:error, {:surface_not_permitted, :api_key}} = Vault.delete(key_ctx, "vlt_x")
    end

    test "a guest-planed context is refused before anything else", %{ctx: ctx} do
      guest = Sanctum.Context.enter_guest(ctx)

      assert {:error, :guest_plane} = Vault.create(guest, %{name: "x", kind: "api_key"})
      assert {:error, :guest_plane} = Vault.revoke(guest, "vlt_x")
    end
  end

  describe "create + list" do
    test "creates sealed material and lists metadata only", %{ctx: ctx} do
      view = create!(ctx, %{name: "my-supabase"})

      assert view.name == "my-supabase"
      assert view.status == "active"
      assert view.field_names == ["anon_key", "url"]
      assert view.payload_rev == 0
      refute Map.has_key?(view, :sealed_payload)

      {:ok, listed} = Vault.list(ctx)
      assert Enum.any?(listed, &(&1.id == view.id))

      # The material actually resolves through the reader.
      assert {:ok, %{"url" => "https://db.example", "anon_key" => "anon"}} =
               VaultReader.fetch(ctx, resource_for(ctx, view.id))
    end

    test "a living name cannot be reused", %{ctx: ctx} do
      create!(ctx, %{name: "taken"})

      assert {:error, :name_taken} = Vault.create(ctx, %{name: "taken", kind: "api_key"})
    end

    test "unknown kinds are refused", %{ctx: ctx} do
      assert {:error, {:invalid_kind, _}} = Vault.create(ctx, %{name: "x", kind: "wand"})
    end
  end

  describe "rotate — material only, no re-consent (D3)" do
    test "replaces material under CAS; the binding digest does not move", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "old-material"}})
      resource = resource_for(ctx, view.id)

      assert {:ok, 1} =
               Vault.rotate(ctx, %{
                 id: view.id,
                 fields: %{"key" => "new-material"},
                 expected_payload_rev: 0
               })

      # The consent's copy of the binding digest still verifies — rotation
      # never forces a re-consent.
      assert {:ok, %{"key" => "new-material"}} = VaultReader.fetch(ctx, resource)
      assert resource_for(ctx, view.id).binding_digest == resource.binding_digest
    end

    test "a stale expected_payload_rev loses the race", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})

      assert {:error, :payload_conflict} =
               Vault.rotate(ctx, %{id: view.id, fields: %{"key" => "x"}, expected_payload_rev: 7})
    end

    test "a schema change is not a rotation", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})

      assert {:error, :schema_change_requires_rebind} =
               Vault.rotate(ctx, %{
                 id: view.id,
                 fields: %{"other" => "v"},
                 expected_payload_rev: 0
               })
    end

    test "rotating a needs_reauth entry reactivates it", %{ctx: ctx} do
      view = create!(ctx, %{fields: %{"key" => "v"}})
      :ok = Arca.VaultStorage.set_status(ctx.org_id, view.id, "needs_reauth")

      assert {:ok, 1} =
               Vault.rotate(ctx, %{id: view.id, fields: %{"key" => "v2"}, expected_payload_rev: 0})

      {:ok, entry} = Arca.VaultStorage.get(ctx.org_id, view.id)
      assert entry.status == "active"
    end

    test "a secrets-only legacy pointer converts to material in place", %{ctx: ctx} do
      id = Emissary.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, "legacy")
      pointer = ~s({"v":1,"legacy":{"secrets":[{"name":"PTR_KEY","scope":"project"}]}})
      {:ok, sealed} = Sanctum.Cipher.encrypt(pointer, aad)

      {:ok, _} =
        Arca.VaultStorage.put(%{
          id: id,
          org_id: ctx.org_id,
          project_id: ctx.project_id,
          name: "legacy:conv",
          provider_hint: "legacy",
          kind: "bundle",
          field_names: Jason.encode!(["PTR_KEY"]),
          sealed_payload: sealed
        })

      resource = resource_for(ctx, id)

      assert {:ok, 1} =
               Vault.rotate(ctx, %{
                 id: id,
                 fields: %{"PTR_KEY" => "typed-fresh"},
                 expected_payload_rev: 0
               })

      # Resolves as material now — no legacy store row exists to point at.
      assert {:ok, %{"PTR_KEY" => "typed-fresh"}} = VaultReader.fetch(ctx, resource)
    end

    test "an OAuth-bearing pointer refuses conversion — re-auth is the converter",
         %{ctx: ctx} do
      id = Emissary.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, "legacy")

      pointer =
        ~s({"v":1,"legacy":{"oauth":[{"component_ref":"catalyst:local.gmail","provider":"google"}]}})

      {:ok, sealed} = Sanctum.Cipher.encrypt(pointer, aad)

      {:ok, _} =
        Arca.VaultStorage.put(%{
          id: id,
          org_id: ctx.org_id,
          project_id: ctx.project_id,
          name: "legacy:oauth",
          provider_hint: "legacy",
          kind: "bundle",
          field_names: "[]",
          sealed_payload: sealed
        })

      assert {:error, :oauth_pointer_requires_reauth} =
               Vault.rotate(ctx, %{id: id, fields: %{}, expected_payload_rev: 0})
    end
  end

  describe "rebind — always a re-consent (D3)" do
    test "moves the derived digest and blocks affected head profiles", %{ctx: ctx} do
      view = create!(ctx)
      old_resource = resource_for(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, old_resource.binding_digest)

      assert {:ok, %{binding_digest: new_digest, affected: affected}} =
               Vault.rebind(ctx, %{
                 id: view.id,
                 oauth_endpoints: %{"token_url" => "https://other.example/token"}
               })

      assert new_digest != old_resource.binding_digest
      assert affected == [profile.id]

      # The old consent's digest no longer verifies.
      assert {:error, :binding_mismatch} = VaultReader.fetch(ctx, old_resource)

      {:ok, reloaded} = Arca.ProfileStorage.get(ctx.org_id, profile.id)
      assert reloaded.status == "needs_consent"
    end

    test "a rebind with no binding fields is refused", %{ctx: ctx} do
      view = create!(ctx)

      assert {:error, :no_binding_changes} = Vault.rebind(ctx, %{id: view.id})
    end
  end

  describe "revoke + delete" do
    test "revoke reports affected head profiles; the reader refuses next retrieval",
         %{ctx: ctx} do
      view = create!(ctx)
      resource = resource_for(ctx, view.id)
      profile = mint_profile_with_ref(ctx, view.id, resource.binding_digest)

      assert {:ok, %{affected: [profile_id]}} = Vault.revoke(ctx, view.id)
      assert profile_id == profile.id

      assert {:error, {:entry_unavailable, "revoked"}} = VaultReader.fetch(ctx, resource)
    end

    test "delete tombstones, erases material, and frees the name", %{ctx: ctx} do
      view = create!(ctx, %{name: "reusable"})

      assert :ok = Vault.delete(ctx, view.id)

      {:ok, row} = Arca.VaultStorage.get(ctx.org_id, view.id)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil

      # The living-name unique index ignores tombstones.
      assert {:ok, _} = Vault.create(ctx, %{name: "reusable", kind: "api_key"})
    end
  end

  describe "broadcasts" do
    test "every mutation announces itself on the tenant vault topic", %{ctx: ctx} do
      Phoenix.PubSub.subscribe(Emissary.PubSub, Sanctum.PubSub.topic("vault:changed", ctx))

      view = create!(ctx)
      assert_receive {:vault_entry_changed, _, :create}

      {:ok, _} =
        Vault.rotate(ctx, %{id: view.id, fields: view_fields(ctx, view), expected_payload_rev: 0})

      assert_receive {:vault_entry_changed, _, :rotate}

      {:ok, _} = Vault.revoke(ctx, view.id)
      assert_receive {:vault_entry_changed, _, :revoke}
    end

    defp view_fields(_ctx, view) do
      Map.new(view.field_names, fn name -> {name, "rotated"} end)
    end
  end
end
