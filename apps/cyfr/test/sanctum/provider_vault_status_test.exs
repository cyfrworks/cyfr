# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ProviderVaultStatusTest do
  @moduledoc """
  `vault.status`: each living entry's name, kind, status, created and
  updated times and whether a consent's head revision binds it — for every
  kind of entry the vault holds, and never a value or a field. It is a
  read on the external plane under no consent class, so a tincture frame
  reaches it where `vault.list` refuses it; a guest has no enumeration of
  the vault.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Vault

  @secret "s3cret-value-never-shown"
  @field "SECRET_FIELD_NAME"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  defp status(ctx), do: Sanctum.Provider.handle("vault", ctx, %{"action" => "status"})

  defp entries!(ctx) do
    assert {:ok, %{entries: entries}} = status(ctx)
    entries
  end

  # One entry of each kind, every one holding the secret somewhere.
  defp one_of_each!(ctx) do
    for {kind, params} <- [
          {"api_key", %{fields: %{@field => @secret}}},
          {"bundle", %{fields: %{@field => @secret, "OTHER" => @secret <> "-2"}}},
          {"oauth",
           %{
             oauth: %{"access_token" => @secret, "refresh_token" => @secret <> "-r"},
             oauth_scopes: ["scope-#{@secret}"],
             oauth_endpoints: %{"token_url" => "https://idp.example/#{@secret}"}
           }}
        ] do
      name = "#{kind}-#{System.unique_integer([:positive])}"

      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, Map.merge(%{name: name, kind: kind}, params))

      {kind, view}
    end
  end

  test "answers each entry's standing for every kind, and never a value or a field", %{ctx: ctx} do
    created = one_of_each!(ctx)
    entries = entries!(ctx)

    for {kind, view} <- created do
      entry = Enum.find(entries, &(&1.id == view.id))
      assert entry, "#{kind} is not answered"

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(bound created_at id kind name status updated_at)a

      assert %{name: name, kind: ^kind, status: "active", bound: false} = entry
      assert name == view.name
      assert {:ok, _at, 0} = DateTime.from_iso8601(entry.created_at)
      assert {:ok, _at, 0} = DateTime.from_iso8601(entry.updated_at)
    end

    wire = Jason.encode!(%{entries: entries})
    refute wire =~ @secret
    refute wire =~ @field
    refute wire =~ "OTHER"
    refute wire =~ "idp.example"
  end

  test "names an entry a head consent binds as bound, and leaves out a deleted one", %{ctx: ctx} do
    [{_, bound_view}, {_, deleted_view}, _oauth] = one_of_each!(ctx)
    {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), bound_view.id)
    {:ok, digest} = Sanctum.VaultReader.binding_digest(entry)

    {:ok, profile} =
      Arca.ProfileStorage.put(%{
        athanor_id: ctx.athanor_id,
        source_ref: "formula:local.status-consumer",
        kind: "owner",
        label: "default",
        status: "active"
      })

    {:ok, _consent} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: ctx.athanor_id,
          profile_id: profile.id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary("{}"),
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "test",
          granted_via: "bootstrap"
        },
        [%{vault_entry_id: bound_view.id, binding_digest: digest}],
        nil
      )

    :ok = Vault.delete(ctx, deleted_view.id)
    entries = entries!(ctx)

    assert %{bound: true} = Enum.find(entries, &(&1.id == bound_view.id))
    refute Enum.any?(entries, &(&1.id == deleted_view.id))
  end

  test "is a read on the external plane under no consent class; a guest reaches neither" do
    assert {:ok, {Sanctum.Provider, meta}} = Grimoire.lookup("vault")

    tincture = %{Sanctum.TestContext.local() | auth_method: :tincture}
    args = fn action -> %{"action" => action} end

    assert :ok =
             Grimoire.Catalog.authorize_annotated_action("vault", meta, tincture, args.("status"))

    assert {:error, {:consent_class_required, _}} =
             Grimoire.Catalog.authorize_annotated_action("vault", meta, tincture, args.("list"))

    # No running chain reaches either: a guest has no enumeration of the
    # vault.
    refute Grimoire.Catalog.in_chain_reachable?("vault", "status")
    refute Grimoire.Catalog.in_chain_reachable?("vault", "list")
  end
end
