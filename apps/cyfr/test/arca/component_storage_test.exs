defmodule Arca.ComponentStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ComponentStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.Context.local()

    {:ok, ctx: ctx}
  end

  defp component_attrs(name, version, overrides \\ %{}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

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

    test "validates required fields", %{ctx: ctx} do
      assert {:error, {:missing_required, :name}} =
               ComponentStorage.put_component(ctx, %{
                 version: "1.0.0",
                 component_type: "catalyst",
                 publisher: "local"
               })
    end
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

  describe "delete_by_source/2" do
    test "deletes components by source", %{ctx: ctx} do
      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("src-a", "1.0.0", %{source: "filesystem"})
        )

      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("src-b", "1.0.0", %{source: "filesystem"})
        )

      {:ok, _} =
        ComponentStorage.put_component(ctx, component_attrs("src-c", "1.0.0", %{source: "oci"}))

      ComponentStorage.delete_by_source(ctx, "filesystem")

      assert {:error, :not_found} = ComponentStorage.get_component(ctx, "src-a", "1.0.0")
      assert {:error, :not_found} = ComponentStorage.get_component(ctx, "src-b", "1.0.0")
      assert {:ok, _} = ComponentStorage.get_component(ctx, "src-c", "1.0.0")
    end
  end

  describe "search_components/3" do
    test "delegates to list_components with query", %{ctx: ctx} do
      {:ok, _} =
        ComponentStorage.put_component(
          ctx,
          component_attrs("searchable", "1.0.0", %{description: "unique_marker"})
        )

      assert {:ok, comps} = ComponentStorage.search_components(ctx, "unique_marker")
      assert length(comps) == 1
      assert hd(comps).name == "searchable"
    end
  end

  describe "validate_attrs/1" do
    test "returns ok for valid attrs" do
      attrs = %{name: "valid", version: "1.0.0", component_type: "catalyst", publisher: "local"}
      assert :ok = ComponentStorage.validate_attrs(attrs)
    end

    test "rejects missing name" do
      assert {:error, {:missing_required, :name}} =
               ComponentStorage.validate_attrs(%{
                 version: "1.0.0",
                 component_type: "catalyst",
                 publisher: "local"
               })
    end

    test "rejects empty version" do
      assert {:error, {:missing_required, :version}} =
               ComponentStorage.validate_attrs(%{
                 name: "x",
                 version: "",
                 component_type: "catalyst",
                 publisher: "local"
               })
    end
  end
end
