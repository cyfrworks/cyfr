# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultReaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.CipherAAD
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp actor(ctx), do: Sanctum.Context.actor(ctx)

  defp mint_material_entry(ctx, fields, over \\ %{}) do
    id = Prima.UUID7.generate_id("vlt")
    hint = Map.get(over, :provider_hint, "")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, hint)

    {:ok, json} = Payload.encode_material(fields, Map.get(over, :oauth))
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    attrs = %{
      id: id,
      name: Map.get(over, :name, "entry-#{id}"),
      provider_hint: hint,
      kind: Map.get(over, :kind, "api_key"),
      field_names: Jason.encode!(Map.keys(fields) |> Enum.sort()),
      oauth_endpoints: Map.get(over, :oauth_endpoints),
      oauth_scopes: Map.get(over, :oauth_scopes),
      status: Map.get(over, :status, "active"),
      sealed_payload: sealed
    }

    {:ok, entry} = Arca.VaultStorage.put(actor(ctx), attrs)
    {:ok, digest} = VaultReader.binding_digest(entry)

    # The edge a consent writes: its projection names the fields it reads
    # and, for an OAuth grant, the scopes the entry was authorized for.
    scopes = if json = Map.get(over, :oauth_scopes), do: Jason.decode!(json), else: []
    projection = %{fields: fields |> Map.keys() |> Enum.sort(), scopes: Enum.sort(scopes)}
    {entry, %{entry_id: entry.id, binding_digest: digest, projection: projection}}
  end

  defp last_used_at(ctx, entry) do
    {:ok, row} = Arca.VaultStorage.get(actor(ctx), entry.id)
    row.last_used_at
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

    test "an edge whose projection names no fields is corrupt and dispenses nothing",
         %{ctx: ctx} do
      {entry, resource} = mint_material_entry(ctx, %{"a" => "sealed-a", "b" => "sealed-b"})
      before = last_used_at(ctx, entry)

      # An edge stored before projections named their fields carries no
      # projection at all; the rest are the same defect spelled otherwise.
      unnamed = [
        Map.delete(resource, :projection),
        %{resource | projection: nil},
        %{resource | projection: %{scopes: []}},
        %{resource | projection: %{fields: [], scopes: []}},
        %{resource | projection: %{fields: "a", scopes: []}},
        %{resource | projection: %{fields: ["a", nil], scopes: []}},
        %{resource | projection: %{fields: ["a", ""], scopes: []}}
      ]

      for edge <- unnamed do
        log =
          capture_log(fn ->
            assert {:error, :corrupt} = VaultReader.fetch(ctx, edge)
          end)

        assert log =~ "re-consent to the component's current version"
        refute log =~ "sealed-"
      end

      # Refused before the entry is read: no use is recorded.
      assert last_used_at(ctx, entry) == before
    end

    test "a projected field the entry lacks refuses the whole resolution", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"url" => "https://db.example"})
      resource = %{resource | projection: %{fields: ["url", "anon_key"], scopes: []}}

      # Never the partial map with `url` alone, and never a silent skip.
      assert {:error, {:missing_field, "anon_key"}} = VaultReader.fetch(ctx, resource)
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

    test "a reader in another athanor gets nothing, and not a different nothing", %{ctx: ctx} do
      {_entry, resource} = mint_material_entry(ctx, %{"k" => "v"}, %{name: "a-only"})
      foreign = %{ctx | athanor_id: "ath_other"}

      # The entry's own athanor column says the row belongs to the test
      # tenant; what decides the read is the caller's actor, and the answer
      # is byte-identical to one for an id that exists nowhere — a
      # different refusal would confirm the entry exists somewhere else.
      assert {:error, :not_found} = VaultReader.fetch(foreign, resource)

      assert VaultReader.fetch(foreign, resource) ==
               VaultReader.fetch(foreign, %{resource | entry_id: "vlt_nonexistent"})

      assert {:error, :not_found} = VaultReader.unseal_by_name("ath_other", "a-only")

      assert {:error, :not_found} =
               VaultReader.usable("ath_other", resource.entry_id, resource.binding_digest)

      # The same reads inside the owning athanor still answer.
      assert {:ok, %{"k" => "v"}} = VaultReader.fetch(ctx, resource)
      assert {:ok, %{"k" => "v"}} = VaultReader.unseal_by_name(ctx.athanor_id, "a-only")
    end

    test "a payload with unknown keys is refused at decode", %{ctx: ctx} do
      id = Prima.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(ctx.athanor_id, id, "")
      {:ok, sealed} = Sanctum.Cipher.encrypt(~s({"v":2,"fields":{},"extra":1}), aad)

      {:ok, entry} =
        Arca.VaultStorage.put(actor(ctx), %{
          id: id,
          name: "tampered",
          provider_hint: "",
          kind: "api_key",
          sealed_payload: sealed
        })

      {:ok, digest} = VaultReader.binding_digest(entry)
      resource = %{entry_id: id, binding_digest: digest, projection: %{fields: ["k"], scopes: []}}

      assert {:error, {:invalid_payload, {:unknown_keys, ["extra"]}}} =
               VaultReader.fetch(ctx, resource)
    end
  end

  describe "oauth_token/3 — v2 material" do
    @valid_oauth %{"access_token" => "tok-live", "token_type" => "bearer"}
    @readonly Jason.encode!(["gmail.readonly"])

    test "dispenses a valid token without touching any provider", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:ok, "tok-live"} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "a consent for one provider never dispenses another's token", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

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
        mint_material_entry(ctx, %{"k" => "v"}, %{
          provider_hint: "google",
          oauth_scopes: @readonly
        })

      assert {:error, :no_oauth_material} = VaultReader.oauth_token(ctx, resource, "google")
    end

    test "an OAuth edge that names no scopes is corrupt and dispenses nothing", %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      before = last_used_at(ctx, entry)

      for edge <- [
            Map.delete(resource, :projection),
            %{resource | projection: nil},
            %{resource | projection: %{fields: [], scopes: []}},
            %{resource | projection: %{fields: [], scopes: [""]}}
          ] do
        log =
          capture_log(fn ->
            assert {:error, :corrupt} = VaultReader.oauth_token(ctx, edge, "google")
          end)

        assert log =~ "re-consent to the component's current version"
        refute log =~ "tok-live"
      end

      assert last_used_at(ctx, entry) == before
    end

    test "a key edge carries no OAuth grant, whatever its entry holds", %{ctx: ctx} do
      {entry, resource} =
        mint_material_entry(ctx, %{"k" => "v"}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      key_edge = %{resource | projection: %{fields: ["k"], scopes: []}}
      before = last_used_at(ctx, entry)

      assert {:error, :no_oauth_material} = VaultReader.oauth_token(ctx, key_edge, "google")
      assert last_used_at(ctx, entry) == before
    end

    test "anonymous callers are refused before any load", %{ctx: ctx} do
      {_entry, resource} =
        mint_material_entry(ctx, %{}, %{
          provider_hint: "google",
          oauth: @valid_oauth,
          oauth_scopes: @readonly
        })

      assert {:error, :anonymous_denied} =
               VaultReader.oauth_token(%{ctx | anonymous: true}, resource, "google")
    end
  end
end
