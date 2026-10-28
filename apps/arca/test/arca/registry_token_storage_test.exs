# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RegistryTokenStorageTest do
  use ExUnit.Case, async: false

  alias Arca.RegistryTokenStorage

  @user "storage_user_1"
  @user2 "storage_user_2"
  @reg "registry.test.com"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
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

  test "delete_if_unchanged removes the row only while it holds the ciphertext read" do
    put!(@user, @reg, "alice", "refused")
    put!(@user2, @reg, "alice", "refused")

    # A token stored since the read is kept.
    put!(@user, @reg, "alice", "fresh")
    assert :ok = RegistryTokenStorage.delete_if_unchanged(@user, @reg, "alice", "refused")

    assert {:ok, %{credential_ciphertext: "fresh"}} =
             RegistryTokenStorage.get(@user, @reg, "alice")

    assert :ok = RegistryTokenStorage.delete_if_unchanged(@user, @reg, "alice", "fresh")
    assert {:error, :not_found} = RegistryTokenStorage.get(@user, @reg, "alice")

    # Another person's row of the same namespace is theirs.
    assert {:ok, %{credential_ciphertext: "refused"}} =
             RegistryTokenStorage.get(@user2, @reg, "alice")

    assert :ok = RegistryTokenStorage.delete_if_unchanged(@user, @reg, "alice", "fresh")
  end
end
