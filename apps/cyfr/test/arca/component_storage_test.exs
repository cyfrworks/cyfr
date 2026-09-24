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

  describe "replace_projection/3" do
    alias Arca.{StorageProjectionChanges, StorageProjectionRoots, StorageUnits}

    @root "components"

    setup do
      athanor = "ath_projection_#{System.unique_integer([:positive])}"
      {:ok, projector: %Cyfr.Actor{athanor_id: athanor, user_id: "usr_projection"}}
    end

    # A unit published and served: its change ready and pending.
    defp published!(actor, key) do
      token = StorageUnits.new_writer_token()
      {:ok, draft} = StorageUnits.register_draft(actor, @root, key, token)

      {:committed, generation} =
        StorageUnits.stamped_commit(actor, draft, nil, token, %{
          new_revision: "rev_#{generation_tag()}",
          content_identity: "sha256:#{key}",
          commit_identity: "usr_projection"
        })

      {:ok, %{units: units}} = StorageProjectionChanges.snapshot(actor, @root, units: [key])
      %{source_revision: revision} = Enum.find(units, &(&1.unit_key == key))
      :ok = StorageProjectionChanges.mark_ready(actor, @root, key, generation, revision)
      generation
    end

    defp generation_tag, do: System.unique_integer([:positive])

    defp token(actor) do
      {:ok, token} = StorageProjectionChanges.snapshot(actor, @root)
      token
    end

    defp standing(actor) do
      {:ok, standing} = StorageProjectionRoots.epoch(actor, @root)
      standing
    end

    defp names(actor) do
      {:ok, rows} = ComponentStorage.list_components(actor, limit: :none)
      rows |> Enum.map(&{&1.name, &1.component_type, &1.source}) |> Enum.sort()
    end

    test "writes the rows and acknowledges the snapshot in one transaction", %{projector: actor} do
      generation = published!(actor, "catalysts/local/proj/1.0.0")
      assert %{epoch: ^generation, acknowledged_epoch: 0} = standing(actor)

      assert {:ok, %{put: [_], deleted: []}} =
               ComponentStorage.replace_projection(actor, token(actor), %{
                 put: [component_attrs("proj", "1.0.0")],
                 delete: []
               })

      assert names(actor) == [{"proj", "catalyst", "filesystem"}]
      assert %{epoch: ^generation, acknowledged_epoch: ^generation} = standing(actor)
    end

    test "a removal names publisher, name and version, narrowed by type and source", %{
      projector: actor
    } do
      {:ok, _} = ComponentStorage.put_component(actor, component_attrs("twin", "1.0.0"))

      {:ok, _} =
        ComponentStorage.put_component(
          actor,
          component_attrs("twin", "1.0.0", %{
            id: Ecto.UUID.generate(),
            component_type: "reagent",
            source: Compendium.Source.published()
          })
        )

      published!(actor, "catalysts/local/twin/1.0.0")

      assert {:ok, %{deleted: [%{name: "twin", component_type: "catalyst"}]}} =
               ComponentStorage.replace_projection(actor, token(actor), %{
                 put: [],
                 delete: [
                   %{
                     publisher: "local",
                     name: "twin",
                     version: "1.0.0",
                     source: Compendium.Source.filesystem()
                   }
                 ]
               })

      assert names(actor) == [{"twin", "reagent", "published"}]
    end

    @tag :capture_log
    test "the rows and the acknowledgment roll back together", %{projector: actor} do
      {:ok, _} = ComponentStorage.put_component(actor, component_attrs("kept", "1.0.0"))
      generation = published!(actor, "catalysts/local/kept/1.0.0")

      # `digest` is NOT NULL: the put fails after the removal ran, inside
      # the transaction that would have acknowledged the change.
      assert {:error, :database_error} =
               ComponentStorage.replace_projection(actor, token(actor), %{
                 put: [component_attrs("kept", "2.0.0", %{digest: nil})],
                 delete: [%{publisher: "local", name: "kept", version: "1.0.0"}]
               })

      assert names(actor) == [{"kept", "catalyst", "filesystem"}]
      assert %{epoch: ^generation, acknowledged_epoch: 0} = standing(actor)
    end

    test "a change the snapshot did not see writes nothing", %{projector: actor} do
      published!(actor, "catalysts/local/early/1.0.0")
      stale = token(actor)
      latest = published!(actor, "catalysts/local/late/1.0.0")

      assert {:error, :generation_conflict} =
               ComponentStorage.replace_projection(actor, stale, %{
                 put: [component_attrs("early", "1.0.0")],
                 delete: []
               })

      assert names(actor) == []
      assert %{epoch: ^latest, acknowledged_epoch: 0} = standing(actor)
    end

    test "an actor without an athanor, and another athanor's token, are refused", %{
      projector: actor
    } do
      published!(actor, "catalysts/local/mine/1.0.0")
      token = token(actor)
      rows = %{put: [component_attrs("mine", "1.0.0")], delete: []}

      for nobody <- [%Cyfr.Actor{athanor_id: nil}, %Cyfr.Actor{athanor_id: ""}] do
        assert {:error, :no_athanor} = ComponentStorage.replace_projection(nobody, token, rows)
      end

      other = %{actor | athanor_id: actor.athanor_id <> "_other"}
      assert {:error, :cross_tenant} = ComponentStorage.replace_projection(other, token, rows)
      assert names(other) == []
      assert names(actor) == []
      assert %{acknowledged_epoch: 0} = standing(actor)
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
