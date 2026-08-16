# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorsTest do
  use ExUnit.Case, async: false

  alias Sanctum.Tenancy.Athanors

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp slug, do: "grp-#{System.unique_integer([:positive])}"

  defp group!(overrides \\ %{}) do
    {:ok, athanor} =
      Athanors.create(
        Map.merge(%{kind: "group", name: "Group", slug: slug(), created_by: "system"}, overrides)
      )

    athanor
  end

  describe "create/1" do
    test "mints an ath_ id and defaults to active" do
      athanor = group!()
      assert String.starts_with?(athanor.id, "ath_")
      assert athanor.status == "active"
      assert athanor.home == false
      assert athanor.provisioned_at == nil
    end

    test "a person athanor names its owner" do
      assert {:ok, person} =
               Athanors.create(%{
                 kind: "person",
                 name: "Alice",
                 slug: "alice-#{System.unique_integer([:positive])}",
                 owner_user_id: "github|https://github.com|1",
                 created_by: "system"
               })

      assert person.kind == "person"
      assert person.owner_user_id == "github|https://github.com|1"
    end

    test "a person athanor without an owner is rejected" do
      assert {:error, changeset} =
               Athanors.create(%{kind: "person", name: "X", slug: slug(), created_by: "system"})

      assert %{owner_user_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects an unknown kind" do
      assert {:error, changeset} =
               Athanors.create(%{kind: "team", name: "X", slug: slug(), created_by: "system"})

      assert %{kind: [_ | _]} = errors_on(changeset)
    end

    test "slugs are unique per kind" do
      s = slug()
      assert {:ok, _} =
               Athanors.create(%{kind: "group", name: "A", slug: s, created_by: "system"})

      assert {:error, changeset} =
               Athanors.create(%{kind: "group", name: "B", slug: s, created_by: "system"})

      assert %{kind: [_ | _]} = errors_on(changeset)

      # The same slug is free for a person athanor.
      assert {:ok, _} =
               Athanors.create(%{
                 kind: "person",
                 name: "A",
                 slug: s,
                 owner_user_id: "user_#{s}",
                 created_by: "system"
               })
    end

    test "one person, one personal athanor" do
      owner = "github|https://github.com|#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Athanors.create(%{
                 kind: "person",
                 name: "A",
                 slug: slug(),
                 owner_user_id: owner,
                 created_by: "system"
               })

      assert {:error, changeset} =
               Athanors.create(%{
                 kind: "person",
                 name: "A again",
                 slug: slug(),
                 owner_user_id: owner,
                 created_by: "system"
               })

      assert %{owner_user_id: [_ | _]} = errors_on(changeset)
    end

    test "rejects a slug outside the namespace grammar" do
      assert {:error, changeset} =
               Athanors.create(%{
                 kind: "group",
                 name: "X",
                 slug: "Bad Slug",
                 created_by: "system"
               })

      assert %{slug: [_ | _]} = errors_on(changeset)
    end
  end

  describe "home/0 and home!/0" do
    test "finds the seeded Home by its flag" do
      assert {:ok, home} = Athanors.home()
      assert home.home == true
      assert home.slug == "home"
      assert home.kind == "group"
      assert Athanors.home!().id == home.id
    end

    test "there can be only one Home" do
      assert {:error, changeset} =
               Athanors.create(%{
                 kind: "group",
                 name: "Second Home",
                 slug: slug(),
                 home: true,
                 created_by: "system"
               })

      assert %{home: [_ | _]} = errors_on(changeset)
    end
  end

  describe "get/1 and get_by_slug/2" do
    test "finds by id and by (kind, slug)" do
      athanor = group!()
      assert {:ok, ^athanor} = Athanors.get(athanor.id)
      assert {:ok, found} = Athanors.get_by_slug("group", athanor.slug)
      assert found.id == athanor.id
      assert {:error, :not_found} = Athanors.get_by_slug("person", athanor.slug)
      assert {:error, :not_found} = Athanors.get("ath_nope")
    end
  end

  describe "archive/1, unarchive/1, active?/1" do
    test "archiving flips status and stamps archived_at; nothing is deleted" do
      athanor = group!()
      assert Athanors.active?(athanor.id)

      assert {:ok, archived} = Athanors.archive(athanor)
      assert archived.status == "archived"
      assert archived.archived_at != nil
      refute Athanors.active?(athanor.id)
      assert {:ok, _} = Athanors.get(athanor.id)

      assert {:ok, back} = Athanors.unarchive(archived)
      assert back.status == "active"
      assert back.archived_at == nil
      assert Athanors.active?(athanor.id)
    end

    test "active?/1 is false for unknown or empty ids" do
      refute Athanors.active?("ath_nope")
      refute Athanors.active?(nil)
      refute Athanors.active?("")
    end
  end

  describe "settings" do
    test "settings default to an empty map and merge on put" do
      athanor = group!()
      assert Athanors.settings(athanor) == %{}

      {:ok, athanor} = Athanors.put_settings(athanor, %{"aqua" => %{"name" => "Home"}})
      {:ok, athanor} = Athanors.put_settings(athanor, %{"theme" => "dark"})

      assert Athanors.settings(athanor) == %{"aqua" => %{"name" => "Home"}, "theme" => "dark"}
    end
  end

  describe "mark_provisioned/1 and list_by_ids/1" do
    test "records provisioning and lists by ids" do
      a = group!()
      b = group!()

      {:ok, a} = Athanors.mark_provisioned(a)
      assert a.provisioned_at != nil

      ids = Athanors.list_by_ids([a.id, b.id, "ath_missing"]) |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      assert Athanors.list_by_ids([]) == []
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
