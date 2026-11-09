# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.VaultStreamTest do
  @moduledoc """
  `vault.changes`, the vault as a canvas reads it: every standing entry
  first, by name, credential kind and standing, and then each entry a
  committed write left, `removed` by name once a delete, a revoke or a
  rename takes the name away. Every refresh item and live payload is
  read as a canvas reads it: projected, passed through JSON and held to
  the declared shape, and none carries a value, a field name, a
  destination or a last use.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Bus.VaultEntry
  alias Prima.Canvas.Shape
  alias Sanctum.{Context, Vault}

  @secret "s3cret-never-on-the-stream"
  @field "SECRET_FIELD_NAME"
  @host "api.private-host.example"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    ctx = Sanctum.TestContext.local(:prism)
    actor = Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.vault_entries(actor))
    {:ok, ctx: ctx}
  end

  defp create!(ctx, name, kind \\ "api_key") do
    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: name,
        kind: kind,
        fields: %{@field => @secret},
        destination: %{"hosts" => [@host]}
      })

    view
  end

  test "is declared by the vault's provider, shaped, subjectless and refreshed" do
    assert {:ok, {Sanctum.Provider, stream}} = Sanctum.Catalog.lookup_stream("vault.changes")

    assert {stream.topic, stream.subject, stream.bind, stream.filter, stream.refresh} ==
             {:vault_entries, nil, nil, nil, {Sanctum.Providers.Vault, :standing}}

    assert stream.projection == ~w(kind name type status revision at)

    assert {stream.key, stream.removal, stream.reread, stream.stale_after} ==
             {"name", "removed", [], 900}

    assert stream.shape["fields"]["kind"]["values"] == ["changed", "removed"]
    assert stream.shape["fields"]["status"]["values"] == ["fine", "needs_reauthorisation"]
    assert stream.shape["fields"]["type"]["values"] == Prima.CredentialKinds.all()

    {:ok, %{streams: listed}} = Compendium.Canvas.catalog(Sanctum.TestContext.local())
    assert %{shape: shape, refresh: true} = Enum.find(listed, &(&1.name == "vault.changes"))
    assert shape == stream.shape
  end

  test "the refresh is every standing entry by name, kind and standing, and nothing else",
       %{ctx: ctx} do
    key = create!(ctx, "github")
    revoked = create!(ctx, "old-key")
    {:ok, _} = Vault.revoke(ctx, revoked.id)
    drain()

    assert {:ok, items} = Sanctum.Providers.Vault.standing(ctx, nil)
    read = Enum.map(items, &read_as/1)

    assert %{"kind" => "changed", "name" => "github", "type" => "api_key", "status" => "fine"} in Enum.map(
             read,
             &Map.drop(&1, ~w(revision at))
           )

    refute Enum.any?(read, &(&1["name"] == "old-key"))
    refute_secret(read)
    assert key.status == "active"

    assert {:error, :no_athanor} = Sanctum.Providers.Vault.standing(%{ctx | athanor_id: nil}, nil)
  end

  test "a create, a rename, a revoke and a delete each reach the stream after their commit",
       %{ctx: ctx} do
    view = create!(ctx, "first")

    assert %{"kind" => "changed", "name" => "first", "type" => "api_key", "status" => "fine"} =
             heard()

    assert :ok = Vault.rename(ctx, view.id, "second")
    assert %{"kind" => "removed", "name" => "first", "type" => nil, "status" => nil} = heard()
    assert %{"kind" => "changed", "name" => "second", "status" => "fine"} = heard()

    assert {:ok, _} = Vault.revoke(ctx, view.id)
    assert %{"kind" => "removed", "name" => "second"} = heard()

    assert :ok = Vault.delete(ctx, view.id)
    assert %{"kind" => "removed", "name" => "second"} = heard()
    refute_received %VaultEntry{}
  end

  test "a login entry waiting for its sign-in reads as needing reauthorisation", %{ctx: ctx} do
    {:ok, _view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "claude-login",
        kind: "login",
        program: "claude"
      })

    assert %{"name" => "claude-login", "type" => "login", "status" => "needs_reauthorisation"} =
             heard()
  end

  test "another athanor's refresh never lists this athanor's entries", %{ctx: ctx} do
    _ = create!(ctx, "ours")
    assert {:ok, items} = Sanctum.Providers.Vault.standing(%{ctx | athanor_id: "ath_other"}, nil)
    refute Enum.any?(items, &(&1.name == "ours"))
  end

  defp heard do
    assert_receive %VaultEntry{} = payload
    data = read_as(payload)
    refute_secret([data])
    data
  end

  defp drain do
    receive do
      %VaultEntry{} -> drain()
    after
      50 -> :ok
    end
  end

  defp refute_secret(read) do
    text = Jason.encode!(read)
    refute text =~ @secret
    refute text =~ @field
    refute text =~ @host
    refute text =~ "last_used"
  end

  # A refresh item or a live payload as a canvas reads it.
  defp read_as(payload) do
    {:ok, {_provider, stream}} = Sanctum.Catalog.lookup_stream("vault.changes")

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: nil,
      deadline: DateTime.utc_now(),
      grant_id: "sgr_vault"
    }

    payload = if is_struct(payload), do: Map.from_struct(payload), else: payload
    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    data
  end
end
