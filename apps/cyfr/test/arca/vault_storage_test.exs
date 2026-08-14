# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorageTest do
  use ExUnit.Case, async: false

  alias Arca.VaultStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, org: ctx.org_id, proj: ctx.project_id}
  end

  defp put!(org, proj, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          project_id: proj,
          name: "entry-#{System.unique_integer([:positive])}",
          kind: "api_key",
          sealed_payload: "sealed-bytes"
        },
        over
      )

    {:ok, entry} = VaultStorage.put(attrs)
    entry
  end

  describe "list/3" do
    test "excludes tombstoned rows unless widened", %{org: org, proj: proj} do
      live = put!(org, proj)
      dead = put!(org, proj)
      :ok = VaultStorage.tombstone(org, proj, dead.id)

      {:ok, rows} = VaultStorage.list(org, proj)
      ids = Enum.map(rows, & &1.id)
      assert live.id in ids
      refute dead.id in ids

      {:ok, all} = VaultStorage.list(org, proj, include_tombstoned: true)
      assert dead.id in Enum.map(all, & &1.id)
    end
  end

  describe "update_meta/4" do
    test "renames; unknown rows are not_found", %{org: org, proj: proj} do
      entry = put!(org, proj)

      assert :ok = VaultStorage.update_meta(org, proj, entry.id, %{name: "renamed"})
      {:ok, row} = VaultStorage.get(org, proj, entry.id)
      assert row.name == "renamed"

      assert {:error, :not_found} = VaultStorage.update_meta(org, proj, "vlt_missing", %{name: "x"})
    end
  end

  describe "tombstone/3" do
    test "flips status and erases the sealed payload in one update", %{org: org, proj: proj} do
      entry = put!(org, proj)

      assert :ok = VaultStorage.tombstone(org, proj, entry.id)

      {:ok, row} = VaultStorage.get(org, proj, entry.id)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil
    end

    test "frees the living-name slot", %{org: org, proj: proj} do
      entry = put!(org, proj, %{name: "unique-name"})
      :ok = VaultStorage.tombstone(org, proj, entry.id)

      assert {:ok, _} =
               VaultStorage.put(%{
                 org_id: org,
                 project_id: proj,
                 name: "unique-name",
                 kind: "api_key"
               })

      assert {:error, :not_found} = VaultStorage.get_by_name(org, proj, "missing")
    end
  end

  describe "update_binding/4" do
    test "updates binding columns and the cached digest", %{org: org, proj: proj} do
      entry = put!(org, proj)

      assert :ok =
               VaultStorage.update_binding(org, proj, entry.id, %{
                 oauth_endpoints: ~s({"token_url":"https://x/t"}),
                 oauth_scopes: ~s(["a"]),
                 binding_digest: "sha256:new"
               })

      {:ok, row} = VaultStorage.get(org, proj, entry.id)
      assert row.oauth_endpoints == ~s({"token_url":"https://x/t"})
      assert row.oauth_scopes == ~s(["a"])
      assert row.binding_digest == "sha256:new"
      # provider_hint is not an accepted key — it lives in the AAD.
      assert row.provider_hint == ""
    end
  end

  describe "tenant isolation" do
    test "get and mutations are org-scoped", %{org: org, proj: proj} do
      entry = put!(org, proj)

      assert {:error, :not_found} = VaultStorage.get("other_org", proj, entry.id)

      assert {:error, :not_found} =
               VaultStorage.update_meta("other_org", proj, entry.id, %{name: "x"})

      assert {:error, :not_found} = VaultStorage.tombstone("other_org", proj, entry.id)
    end

    test "get and mutations are project-scoped — an id from another project does not resolve",
         %{org: org, proj: proj} do
      entry = put!(org, "project-b")

      assert {:error, :not_found} = VaultStorage.get(org, proj, entry.id)
      assert {:error, :not_found} = VaultStorage.update_meta(org, proj, entry.id, %{name: "x"})
      assert {:error, :not_found} = VaultStorage.set_status(org, proj, entry.id, "revoked")
      assert {:error, :not_found} = VaultStorage.tombstone(org, proj, entry.id)

      assert {:error, :payload_conflict} =
               VaultStorage.rotate_payload(org, proj, entry.id, 0, "sealed-x")

      assert {:ok, _} = VaultStorage.get(org, "project-b", entry.id)
    end
  end
end
