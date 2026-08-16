# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorageTest do
  use ExUnit.Case, async: false

  alias Arca.VaultStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, athanor: ctx.athanor_id}
  end

  defp put!(athanor, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          athanor_id: athanor,
          name: "entry-#{System.unique_integer([:positive])}",
          kind: "api_key",
          sealed_payload: "sealed-bytes"
        },
        over
      )

    {:ok, entry} = VaultStorage.put(attrs)
    entry
  end

  describe "list/2" do
    test "excludes tombstoned rows unless widened", %{athanor: athanor} do
      live = put!(athanor)
      dead = put!(athanor)
      :ok = VaultStorage.tombstone(athanor, dead.id)

      {:ok, rows} = VaultStorage.list(athanor)
      ids = Enum.map(rows, & &1.id)
      assert live.id in ids
      refute dead.id in ids

      {:ok, all} = VaultStorage.list(athanor, include_tombstoned: true)
      assert dead.id in Enum.map(all, & &1.id)
    end
  end

  describe "update_meta/4" do
    test "renames; unknown rows are not_found", %{athanor: athanor} do
      entry = put!(athanor)

      assert :ok = VaultStorage.update_meta(athanor, entry.id, %{name: "renamed"})
      {:ok, row} = VaultStorage.get(athanor, entry.id)
      assert row.name == "renamed"

      assert {:error, :not_found} = VaultStorage.update_meta(athanor, "vlt_missing", %{name: "x"})
    end
  end

  describe "tombstone/3" do
    test "flips status and erases the sealed payload in one update", %{athanor: athanor} do
      entry = put!(athanor)

      assert :ok = VaultStorage.tombstone(athanor, entry.id)

      {:ok, row} = VaultStorage.get(athanor, entry.id)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil
    end

    test "frees the living-name slot", %{athanor: athanor} do
      entry = put!(athanor, %{name: "unique-name"})
      :ok = VaultStorage.tombstone(athanor, entry.id)

      assert {:ok, _} =
               VaultStorage.put(%{
                 athanor_id: athanor,
                 name: "unique-name",
                 kind: "api_key"
               })

      assert {:error, :not_found} = VaultStorage.get_by_name(athanor, "missing")
    end
  end

  describe "update_binding/4" do
    test "updates binding columns and the cached digest", %{athanor: athanor} do
      entry = put!(athanor)

      assert :ok =
               VaultStorage.update_binding(athanor, entry.id, %{
                 oauth_endpoints: ~s({"token_url":"https://x/t"}),
                 oauth_scopes: ~s(["a"]),
                 binding_digest: "sha256:new"
               })

      {:ok, row} = VaultStorage.get(athanor, entry.id)
      assert row.oauth_endpoints == ~s({"token_url":"https://x/t"})
      assert row.oauth_scopes == ~s(["a"])
      assert row.binding_digest == "sha256:new"
      # provider_hint is not an accepted key — it lives in the AAD.
      assert row.provider_hint == ""
    end
  end

  describe "tenant isolation" do
    test "get and mutations are athanor-scoped", %{athanor: athanor} do
      entry = put!(athanor)

      assert {:error, :not_found} = VaultStorage.get("ath_other", entry.id)

      assert {:error, :not_found} =
               VaultStorage.update_meta("ath_other", entry.id, %{name: "x"})

      assert {:error, :not_found} = VaultStorage.set_status("ath_other", entry.id, "revoked")
      assert {:error, :not_found} = VaultStorage.tombstone("ath_other", entry.id)

      assert {:error, :payload_conflict} =
               VaultStorage.rotate_payload("ath_other", entry.id, 0, "sealed-x")

      assert {:ok, _} = VaultStorage.get(athanor, entry.id)
    end
  end
end
