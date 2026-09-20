# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ComponentStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ComponentStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    actor = Sanctum.Context.actor(Sanctum.TestContext.local())

    {:ok, actor: actor}
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
        source: Compendium.Source.filesystem(),
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
    test "refuses a source outside the closed roster — forged rows cannot land", %{actor: actor} do
      attrs = component_attrs("forged", "1.0.0", %{source: "local"})

      assert_raise ArgumentError, ~r/unknown component source/, fn ->
        ComponentStorage.put_component(actor, attrs)
      end

      assert_raise ArgumentError, ~r/unknown component source/, fn ->
        ComponentStorage.insert_component(actor, attrs)
      end
    end

    test "stores and retrieves a component", %{actor: actor} do
      attrs = component_attrs("my-comp", "1.0.0")
      assert {:ok, _} = ComponentStorage.put_component(actor, attrs)

      assert {:ok, comp} =
               ComponentStorage.get_component(actor, "my-comp", "1.0.0")

      assert comp.name == "my-comp"
      assert comp.version == "1.0.0"
      assert comp.component_type == "catalyst"
    end

    test "returns not_found for missing component", %{actor: actor} do
      assert {:error, :not_found} =
               ComponentStorage.get_component(actor, "missing", "1.0.0")
    end

    test "upserts on conflict", %{actor: actor} do
      attrs = component_attrs("upsert-comp", "1.0.0", %{description: "original"})
      assert {:ok, _} = ComponentStorage.put_component(actor, attrs)

      updated = %{attrs | description: "updated", id: attrs.id}
      assert {:ok, _} = ComponentStorage.put_component(actor, updated)

      assert {:ok, comp} =
               ComponentStorage.get_component(actor, "upsert-comp", "1.0.0")

      assert comp.description == "updated"
    end

    # Component-identity validation moved to Compendium.Registry (the component
    # domain); ComponentStorage persists already-validated attributes. Validation
    # coverage now lives in Compendium.ComponentValidationTest.
  end

  describe "get_component/5 with publisher and type filters" do
    test "filters by publisher", %{actor: actor} do
      attrs = component_attrs("pub-comp", "1.0.0", %{publisher: "acme"})
      {:ok, _} = ComponentStorage.put_component(actor, attrs)

      assert {:ok, _} =
               ComponentStorage.get_component(
                 actor,
                 "pub-comp",
                 "1.0.0",
                 "acme"
               )

      assert {:error, :not_found} =
               ComponentStorage.get_component(
                 actor,
                 "pub-comp",
                 "1.0.0",
                 "other"
               )
    end

    test "filters by component_type", %{actor: actor} do
      attrs = component_attrs("typed-comp", "1.0.0", %{component_type: "reagent"})
      {:ok, _} = ComponentStorage.put_component(actor, attrs)

      assert {:ok, _} =
               ComponentStorage.get_component(
                 actor,
                 "typed-comp",
                 "1.0.0",
                 nil,
                 "reagent"
               )

      assert {:error, :not_found} =
               ComponentStorage.get_component(
                 actor,
                 "typed-comp",
                 "1.0.0",
                 nil,
                 "catalyst"
               )
    end
  end

  describe "get_by_digest/2" do
    test "retrieves component by digest", %{actor: actor} do
      digest = "sha256:abc123unique"
      attrs = component_attrs("digest-comp", "1.0.0", %{digest: digest})
      {:ok, _} = ComponentStorage.put_component(actor, attrs)

      assert {:ok, comp} = ComponentStorage.get_by_digest(actor, digest)
      assert comp.name == "digest-comp"
    end

    test "returns not_found for unknown digest", %{actor: actor} do
      assert {:error, :not_found} =
               ComponentStorage.get_by_digest(actor, "sha256:nonexistent")
    end
  end

  describe "delete_component/3" do
    test "deletes a component", %{actor: actor} do
      attrs = component_attrs("del-comp", "1.0.0")
      {:ok, _} = ComponentStorage.put_component(actor, attrs)

      assert :ok =
               ComponentStorage.delete_component(actor, "del-comp", "1.0.0")

      assert {:error, :not_found} =
               ComponentStorage.get_component(actor, "del-comp", "1.0.0")
    end

    test "delete of missing component returns ok", %{actor: actor} do
      assert :ok =
               ComponentStorage.delete_component(
                 actor,
                 "nonexistent",
                 "1.0.0"
               )
    end
  end

  describe "list_components/2" do
    test "lists all components", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("list-a", "1.0.0")
        )

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("list-b", "2.0.0")
        )

      assert {:ok, comps} = ComponentStorage.list_components(actor)
      names = Enum.map(comps, & &1.name)
      assert "list-a" in names
      assert "list-b" in names
    end

    test "filters by name", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("filter-name", "1.0.0")
        )

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("other", "1.0.0")
        )

      assert {:ok, comps} =
               ComponentStorage.list_components(actor, name: "filter-name")

      assert length(comps) == 1
      assert hd(comps).name == "filter-name"
    end

    test "filters by component_type", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("cat", "1.0.0", %{component_type: "catalyst"})
        )

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("rea", "1.0.0", %{component_type: "reagent"})
        )

      assert {:ok, comps} =
               ComponentStorage.list_components(actor,
                 component_type: "reagent"
               )

      assert Enum.all?(comps, &(&1.component_type == "reagent"))
    end

    test "text search in name/description", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("search-target", "1.0.0", %{description: "findme widget"})
        )

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("other-comp", "1.0.0", %{description: "nothing here"})
        )

      assert {:ok, comps} =
               ComponentStorage.list_components(actor, query: "findme")

      assert length(comps) == 1
      assert hd(comps).name == "search-target"
    end

    test "returns empty list when no components match", %{actor: actor} do
      assert {:ok, []} =
               ComponentStorage.list_components(actor, name: "nonexistent")
    end

    test "respects limit option", %{actor: actor} do
      for i <- 1..5 do
        {:ok, _} =
          ComponentStorage.put_component(
            actor,
            component_attrs("lim-#{i}", "1.0.0")
          )
      end

      assert {:ok, comps} = ComponentStorage.list_components(actor, limit: 2)
      assert length(comps) == 2
    end

    test "limit: :none returns every row past the default page", %{actor: actor} do
      for i <- 1..105 do
        {:ok, _} =
          ComponentStorage.put_component(
            actor,
            component_attrs("all-#{i}", "1.0.0")
          )
      end

      assert {:ok, paged} = ComponentStorage.list_components(actor)
      assert length(paged) == 100

      assert {:ok, comps} =
               ComponentStorage.list_components(actor, limit: :none)

      assert length(comps) == 105
    end
  end

  describe "timestamp parsing" do
    test "get_component returns DateTime structs for timestamps", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("ts-comp", "1.0.0")
        )

      assert {:ok, comp} =
               ComponentStorage.get_component(actor, "ts-comp", "1.0.0")

      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end

    test "list_components returns DateTime structs for timestamps", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("ts-list", "1.0.0")
        )

      assert {:ok, [comp | _]} =
               ComponentStorage.list_components(actor, name: "ts-list")

      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end

    test "get_by_digest returns DateTime structs for timestamps", %{actor: actor} do
      digest = "sha256:ts_digest_test"

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("ts-digest", "1.0.0", %{digest: digest})
        )

      assert {:ok, comp} = ComponentStorage.get_by_digest(actor, digest)
      assert %DateTime{} = comp.inserted_at
      assert %DateTime{} = comp.updated_at
    end
  end

  describe "exists?/3" do
    test "returns true for existing component", %{actor: actor} do
      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("exists-comp", "1.0.0")
        )

      assert ComponentStorage.exists?(actor, "exists-comp", "1.0.0")
    end

    test "returns false for missing component", %{actor: actor} do
      refute ComponentStorage.exists?(actor, "missing", "1.0.0")
    end
  end

  describe "an athanor-less actor" do
    test "is refused before any query, nil and empty alike", %{actor: actor} do
      for anon <- [%{actor | athanor_id: nil}, %{actor | athanor_id: ""}] do
        assert {:error, :no_athanor} =
                 ComponentStorage.put_component(anon, component_attrs("x", "1.0.0"))

        assert {:error, :no_athanor} =
                 ComponentStorage.insert_component(anon, component_attrs("x", "1.0.0"))

        assert {:error, :no_athanor} = ComponentStorage.get_component(anon, "x", "1.0.0")
        assert {:error, :no_athanor} = ComponentStorage.list_components(anon)
      end
    end

    test "a context is not an actor: no head matches it" do
      context = Sanctum.TestContext.local()

      assert_raise FunctionClauseError, fn ->
        ComponentStorage.list_components(context)
      end

      assert_raise FunctionClauseError, fn ->
        ComponentStorage.put_component(
          context,
          component_attrs("x", "1.0.0")
        )
      end
    end
  end
end
