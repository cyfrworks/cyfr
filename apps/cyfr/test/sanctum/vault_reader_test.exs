# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultReaderTest do
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp mint_material_entry(ctx, fields, over \\ %{}) do
    id = Emissary.UUID7.generate_id("vlt")
    hint = Map.get(over, :provider_hint, "")
    aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, hint)

    {:ok, json} = Payload.encode_material(fields, Map.get(over, :oauth))
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    attrs = %{
      id: id,
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      name: Map.get(over, :name, "entry-#{id}"),
      provider_hint: hint,
      kind: Map.get(over, :kind, "api_key"),
      field_names: Jason.encode!(Map.keys(fields) |> Enum.sort()),
      oauth_endpoints: Map.get(over, :oauth_endpoints),
      oauth_scopes: Map.get(over, :oauth_scopes),
      status: Map.get(over, :status, "active"),
      sealed_payload: sealed
    }

    {:ok, entry} = Arca.VaultStorage.put(attrs)
    {:ok, digest} = VaultReader.binding_digest(entry)
    {entry, %{entry_id: entry.id, binding_digest: digest}}
  end

  describe "fetch/2 — v2 material" do
    test "projects the sealed fields; nothing outside the projection leaves", %{ctx: ctx} do
      fields = %{"url" => "https://db.example", "anon_key" => "anon", "service_key" => "SECRET"}
      {_entry, resource} = mint_material_entry(ctx, fields)
      resource = Map.put(resource, :projection, %{fields: ["url", "anon_key"], scopes: []})

      assert {:ok, resolved} = VaultReader.fetch(ctx, resource)
      assert resolved == %{"url" => "https://db.example", "anon_key" => "anon"}
      refute Map.has_key?(resolved, "service_key")
    end

    test "no projection resolves every field", %{ctx: ctx} do
      fields = %{"a" => "1", "b" => "2"}
      {_entry, resource} = mint_material_entry(ctx, fields)

      assert {:ok, ^fields} = VaultReader.fetch(ctx, resource)
    end

    test "anonymous callers are refused before any load", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      assert {:error, :anonymous_denied} =
               VaultReader.fetch(%{ctx | anonymous: true}, resource)
    end

    test "a non-active entry is unavailable", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{status: "needs_reauth"})

      assert {:error, {:entry_unavailable, "needs_reauth"}} = VaultReader.fetch(ctx, resource)
    end

    test "a rebound entry fails at the derived binding digest", %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"k" => "v"})

      import Ecto.Query

      Arca.Repo.update_all(
        from(v in Arca.Schemas.VaultEntry, where: v.id == ^entry.id),
        set: [oauth_endpoints: ~s({"token_url":"https://evil.example/token"})]
      )

      assert {:error, :binding_mismatch} = VaultReader.fetch(ctx, resource)
    end

    test "a payload with unknown keys is refused at decode", %{ctx: ctx} do
      id = Emissary.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, "")
      {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":2,"fields":{},"extra":1}), aad)

      {:ok, entry} =
        Arca.VaultStorage.put(%{
          id: id,
          org_id: ctx.org_id,
          project_id: ctx.project_id,
          name: "tampered",
          provider_hint: "",
          kind: "api_key",
          sealed_payload: sealed
        })

      {:ok, digest} = VaultReader.binding_digest(entry)

      assert {:error, {:invalid_payload, {:unknown_keys, ["extra"]}}} =
               VaultReader.fetch(ctx, %{entry_id: id, binding_digest: digest})
    end
  end

  describe "oauth_token/3 — v2 material" do
    @valid_oauth %{"access_token" => "tok-live", "token_type" => "bearer"}

    test "dispenses a valid token without touching any provider", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{provider_hint: "google", oauth: @valid_oauth})

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a consent for one provider never dispenses another's token", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{provider_hint: "google", oauth: @valid_oauth})

      assert {:error, {:provider_mismatch, "github"}} =
               VaultReader.oauth_token(ctx, resource, "github")
    end

    test "a scope projection outside the entry's authorized scopes is unsatisfiable",
         %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: Jason.encode!(["gmail.readonly"])
        })

      resource =
        Map.put(resource, :projection, %{fields: [], scopes: ["gmail.readonly", "gmail.send"]})

      assert {:error, {:scope_projection_unsatisfiable, ["gmail.send"]}} =
               VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a subset scope projection dispenses", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: Jason.encode!(["gmail.readonly", "gmail.send"])
        })

      resource = Map.put(resource, :projection, %{fields: [], scopes: ["gmail.readonly"]})

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a material entry without an oauth bundle has no token to dispense", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{provider_hint: "google"})

      assert {:error, :no_oauth_material} = VaultReader.oauth_token(ctx, resource, "google")
    end
  end

  describe "v1 legacy pointers" do
    test "a pointer fails closed as retired — nothing dispenses", %{ctx: ctx} do
      id = Emissary.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, id, "legacy")

      pointer = ~s({"v":1,"legacy":{"secrets":[{"name":"PTR_KEY","scope":"project"}]}})
      {:ok, sealed} = Sanctum.Cipher.encrypt(pointer, aad)

      {:ok, entry} =
        Arca.VaultStorage.put(%{
          id: id,
          org_id: ctx.org_id,
          project_id: ctx.project_id,
          name: "legacy:ptr",
          provider_hint: "legacy",
          kind: "bundle",
          sealed_payload: sealed
        })

      {:ok, digest} = VaultReader.binding_digest(entry)

      assert {:error, :legacy_pointer_retired} =
               VaultReader.fetch(ctx, %{entry_id: id, binding_digest: digest})
    end
  end
end
