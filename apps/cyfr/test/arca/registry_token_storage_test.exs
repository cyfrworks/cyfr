# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RegistryTokenStorageTest do
  use ExUnit.Case, async: false

  alias Arca.RegistryTokenStorage

  @user "storage_user_1"
  @user2 "storage_user_2"
  @reg "registry.test.com"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp put!(user, registry, slug, ct \\ "ciphertext") do
    :ok =
      RegistryTokenStorage.put(%{
        user_id: user,
        registry: registry,
        namespace_slug: slug,
        credential_ciphertext: ct
      })
  end

  test "put/get round-trip stores ciphertext verbatim" do
    put!(@user, @reg, "alice", <<1, 2, 3>>)

    assert {:ok, row} = RegistryTokenStorage.get(@user, @reg, "alice")
    assert row.credential_ciphertext == <<1, 2, 3>>
    assert row.user_id == @user
    assert %DateTime{} = row.issued_at
  end

  test "put upserts on the (user, registry, namespace) triple" do
    put!(@user, @reg, "alice", "first")
    put!(@user, @reg, "alice", "second")

    assert {:ok, row} = RegistryTokenStorage.get(@user, @reg, "alice")
    assert row.credential_ciphertext == "second"

    assert {:ok, rows} = RegistryTokenStorage.list(@user, @reg)
    assert length(rows) == 1
  end

  test "get misses are :not_found" do
    assert {:error, :not_found} = RegistryTokenStorage.get(@user, @reg, "missing")
  end

  test "list is scoped to user and registry, ordered by slug" do
    put!(@user, @reg, "stripe.com")
    put!(@user, @reg, "alice")
    put!(@user, "other.registry", "alice")
    put!(@user2, @reg, "bob")

    assert {:ok, rows} = RegistryTokenStorage.list(@user, @reg)
    assert Enum.map(rows, & &1.namespace_slug) == ["alice", "stripe.com"]
  end

  test "delete removes exactly one slot and is idempotent" do
    put!(@user, @reg, "alice")
    put!(@user, @reg, "stripe.com")

    assert :ok = RegistryTokenStorage.delete(@user, @reg, "alice")
    assert {:error, :not_found} = RegistryTokenStorage.get(@user, @reg, "alice")
    assert {:ok, _} = RegistryTokenStorage.get(@user, @reg, "stripe.com")

    assert :ok = RegistryTokenStorage.delete(@user, @reg, "alice")
  end
end
