# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ComponentStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ComponentStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()

    {:ok, ctx: ctx}
  end

  defp component_attrs(name, version, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        name: name,
        version: version,
        component_type: "catalyst",
        description: "Test component #{name}",
        tags: "[]",
        category: "test",
        license: "MIT",
        digest:
          "sha256:#{:crypto.hash(:sha256, "#{name}:#{version}") |> Base.encode16(case: :lower)}",
        size: 1024,
        exports: "[]",
        manifest: "{}",
        publisher: "local",
        publisher_id: nil,
        source: "test",
        signature_verified: false,
        signer_identity: nil,
        signer_issuer: nil,
        inserted_at: now,
        updated_at: now
      },
      overrides
    )
  end

  describe "put_component/2 and get_component/3" do
    test "stores and retrieves a component", %{ctx: ctx} do
      attrs = component_attrs("my-comp", "1.0.0")
      assert {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      assert {:ok, comp} = ComponentStorage.get_component(ctx, "my-comp", "1.0.0")
      assert comp.name == "my-comp"
      assert comp.version == "1.0.0"
      assert comp.component_type == "catalyst"
    end

    test "returns not_found for missing component", %{ctx: ctx} do
      assert {:error, :not_found} = ComponentStorage.get_component(ctx, "missing", "1.0.0")
    end

    test "upserts on conflict", %{ctx: ctx} do
      attrs = component_attrs("upsert-comp", "1.0.0", %{description: "original"})
      assert {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      updated = %{attrs | description: "updated", id: attrs.id}
      assert {:ok, _} = ComponentStorage.put_component(ctx, updated)

      assert {:ok, comp} = ComponentStorage.get_component(ctx, "upsert-comp", "1.0.0")
      assert comp.description == "updated"
    end

    # Component-identity validation moved to Compendium.Registry (the component
    # domain); ComponentStorage persists already-validated attributes. Validation
    # coverage now lives in Compendium.ComponentValidationTest.
  end

  describe "get_component/5 with publisher and type filters" do
    test "filters by publisher", %{ctx: ctx} do
      attrs = component_attrs("pub-comp", "1.0.0", %{publisher: "acme"})
      {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      assert {:ok, _} = ComponentStorage.get_component(ctx, "pub-comp", "1.0.0", "acme")

      assert {:error, :not_found} =
               ComponentStorage.get_component(ctx, "pub-comp", "1.0.0", "other")
    end

    test "filters by component_type", %{ctx: ctx} do
      attrs = component_attrs("typed-comp", "1.0.0", %{component_type: "reagent"})
      {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      assert {:ok, _} = ComponentStorage.get_component(ctx, "typed-comp", "1.0.0", nil, "reagent")

      assert {:error, :not_found} =
               ComponentStorage.get_component(ctx, "typed-comp", "1.0.0", nil, "catalyst")
    end
  end

  describe "get_by_digest/2" do
    test "retrieves component by digest", %{ctx: ctx} do
      digest = "sha256:abc123unique"
      attrs = component_attrs("digest-comp", "1.0.0", %{digest: digest})
      {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      assert {:ok, comp} = ComponentStorage.get_by_digest(ctx, digest)
      assert comp.name == "digest-comp"
    end

    test "returns not_found for unknown digest", %{ctx: ctx} do
      assert {:error, :not_found} = ComponentStorage.get_by_digest(ctx, "sha256:nonexistent")
    end
  end

  describe "delete_component/3" do
    test "deletes a component", %{ctx: ctx} do
      attrs = component_attrs("del-comp", "1.0.0")
      {:ok, _} = ComponentStorage.put_component(ctx, attrs)

      assert :ok = ComponentStorage.delete_component(ctx, "del-comp", "1.0.0")
      assert {:error, :not_found} = ComponentStorage.get_component(ctx, "del-comp", "1.0.0")
    end

    test "delete of missing component returns ok", %{ctx: ctx} do
      assert :ok = ComponentStorage.delete_component(ctx, "nonexistent", "1.0.0")
    end
  end

  describe "list_components/2" do
    test "lists all components", %{ctx: ctx} do
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("list-a", "1.0.0"))
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("list-b", "2.0.0"))

      assert {:ok, comps} = ComponentStorage.list_components(ctx)
      names = Enum.map(comps, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "filters by name", %{ctx: ctx} do
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("filter-name", "1.0.0"))
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("other", "1.0.0"))

      assert {:ok, comps} = ComponentStorage.list_components(ctx, name: "filter-name")
      assert length(comps) == 1
      assert hd(comps).name == "filter-name"
    end

    test "filters by component_type", %{ctx: ctx} do
      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("cat", "1.0.0", %{component_type: "catalyst"})
        )

      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("rea", "1.0.0", %{component_type: "reagent"})
        )

      assert {:ok, comps} = ComponentStorage.list_components(ctx, component_type: "reagent")
      assert Enum.all?(comps, &(&1.component_type == "reagent"))
    end

    test "text search in name/description", %{ctx: ctx} do
      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("search-target", "1.0.0", %{description: "findme widget"})
        )

      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("other-comp", "1.0.0", %{description: "nothing here"})
        )

      assert {:ok, comps} = ComponentStorage.list_components(ctx, query: "findme")
      assert length(comps) == 1
      assert hd(comps).name == "search-target"
    end

    test "returns empty list when no components match", %{ctx: ctx} do
      assert {:ok, []} = ComponentStorage.list_components(ctx, name: "nonexistent")
    end

    test "respects limit option", %{ctx: ctx} do
      for i <- 1..5 do
        {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("lim-#{i}", "1.0.0"))
      end

      assert {:ok, comps} = ComponentStorage.list_components(ctx, limit: 2)
      assert length(comps) == 2
    end

    test "limit: :none returns every row past the default page", %{ctx: ctx} do
      for i <- 1..105 do
        {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("all-#{i}", "1.0.0"))
      end

      assert {:ok, paged} = ComponentStorage.list_components(ctx)
      assert length(paged) == 100

      assert {:ok, comps} = ComponentStorage.list_components(ctx, limit: :none)
      assert length(comps) == 105
    end
  end

  describe "timestamp parsing" do
    test "get_component returns DateTime structs for timestamps", %{ctx: ctx} do
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("ts-comp", "1.0.0"))

      assert {:ok, comp} = ComponentStorage.get_component(ctx, "ts-comp", "1.0.0")
      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end

    test "list_components returns DateTime structs for timestamps", %{ctx: ctx} do
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("ts-list", "1.0.0"))

      assert {:ok, [comp | _]} = ComponentStorage.list_components(ctx, name: "ts-list")
      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end

    test "get_by_digest returns DateTime structs for timestamps", %{ctx: ctx} do
      digest = "sha256:ts_digest_test"

      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("ts-digest", "1.0.0", %{digest: digest})
        )

      assert {:ok, comp} = ComponentStorage.get_by_digest(ctx, digest)
      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end
  end

  describe "exists?/3" do
    test "returns true for existing component", %{ctx: ctx} do
      {:ok, _} = ComponentStorage.put_component(ctx, component_attrs("exists-comp", "1.0.0"))

      assert ComponentStorage.exists?(ctx, "exists-comp", "1.0.0")
    end

    test "returns false for missing component", %{ctx: ctx} do
      refute ComponentStorage.exists?(ctx, "missing", "1.0.0")
    end
  end

  describe "an athanor-less context" do
    test "fails loud with a message on writes, matching the module's siblings", %{ctx: ctx} do
      anon = %{ctx | athanor_id: nil}

      assert_raise ArgumentError, ~r/resolved athanor_id is required/, fn ->
        ComponentStorage.put_component(anon, component_attrs("x", "1.0.0"))
      end

      assert_raise ArgumentError, ~r/resolved athanor_id is required/, fn ->
        ComponentStorage.insert_component(anon, component_attrs("x", "1.0.0"))
      end
    end
  end
end
