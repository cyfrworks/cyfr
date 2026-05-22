# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.OrgsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Orgs

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    :ok
  end

  defp valid_org_attrs(overrides \\ %{}) do
    Map.merge(
      %{name: "Test Org", slug: "test-org"},
      overrides
    )
  end

  describe "create/1" do
    test "creates an org with valid attrs" do
      assert {:ok, org} = Orgs.create(valid_org_attrs())
      assert org.name == "Test Org"
      assert org.slug == "test-org"
      assert String.starts_with?(org.id, "org_")
    end

    test "rejects invalid slug format" do
      assert {:error, changeset} = Orgs.create(valid_org_attrs(%{slug: "BAD SLUG"}))
      assert %{slug: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate slug" do
      assert {:ok, _} = Orgs.create(valid_org_attrs())
      assert {:error, changeset} = Orgs.create(valid_org_attrs(%{name: "Another"}))
      assert %{slug: [_ | _]} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns org by id" do
      {:ok, org} = Orgs.create(valid_org_attrs())
      assert {:ok, found} = Orgs.get(org.id)
      assert found.id == org.id
    end

    test "returns not_found for missing id" do
      assert {:error, :not_found} = Orgs.get("org_nonexistent")
    end
  end

  describe "get_by_slug/1" do
    test "returns org by slug" do
      {:ok, org} = Orgs.create(valid_org_attrs())
      assert {:ok, found} = Orgs.get_by_slug("test-org")
      assert found.id == org.id
    end

    test "returns not_found for missing slug" do
      assert {:error, :not_found} = Orgs.get_by_slug("nonexistent")
    end
  end

  describe "update/2" do
    test "updates org attributes" do
      {:ok, org} = Orgs.create(valid_org_attrs())
      assert {:ok, updated} = Orgs.update(org, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end
  end

  describe "delete/1" do
    test "deletes an org" do
      {:ok, org} = Orgs.create(valid_org_attrs())
      assert {:ok, _} = Orgs.delete(org)
      assert {:error, :not_found} = Orgs.get(org.id)
    end
  end

  describe "list/1" do
    test "lists orgs" do
      {:ok, _} = Orgs.create(valid_org_attrs(%{slug: "org-01"}))
      {:ok, _} = Orgs.create(valid_org_attrs(%{slug: "org-02"}))
      orgs = Orgs.list()
      assert length(orgs) >= 2
    end
  end

  defp errors_on(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
