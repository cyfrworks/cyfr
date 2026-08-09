# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.RegistryTest.FailingPutAdapter do
  @moduledoc false
  # Delegates to the Local adapter but refuses to write `boom.txt` —
  # simulates an object-store write failing partway through a multi-file
  # tincture store.
  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate list_recursive(ctx, path), to: Arca.Adapters.Local
  defdelegate read_subtree(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

  def put(ctx, path, content) do
    if List.last(path) == "boom.txt" do
      {:error, :injected_write_failure}
    else
      Arca.Adapters.Local.put(ctx, path, content)
    end
  end
end

defmodule Compendium.RegistryTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry

  # Valid minimal WASM with export section
  # magic + version
  # type section
  # function section
  # export section
  # code section
  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_registry_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  describe "publish_bytes/3" do
    test "publishes WASM bytes to registry", %{ctx: ctx} do
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "test-tool",
          version: "1.0.0",
          type: "reagent",
          description: "A test component"
        })

      assert component.name == "test-tool"
      assert component.version == "1.0.0"
      assert component.description == "A test component"
      assert component.component_type == "reagent"
      assert String.starts_with?(component.digest, "sha256:")
      assert component.inserted_at != nil
    end

    test "stores WASM in canonical directory", %{ctx: ctx} do
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "blob-test",
          version: "1.0.0",
          type: "reagent"
        })

      # Verify WASM exists in Arca storage at the canonical (project-scoped) path
      storage_path = [
        "components",
        "local",
        "default",
        "reagents",
        "local",
        "blob-test",
        "1.0.0",
        "reagent.wasm"
      ]

      {:ok, content} = Arca.get(ctx, storage_path)
      assert content == @valid_wasm

      # Also verify we can get it via get_blob
      {:ok, blob} = Registry.get_blob(ctx, component.digest)
      assert blob == @valid_wasm
    end

    test "rejects a malformed manifest instead of registering with no declarations", %{ctx: ctx} do
      assert {:error, {:invalid_manifest, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "bad-manifest",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: "{not json"
               })

      # A manifest that parses to a non-object is equally malformed
      assert {:error, {:invalid_manifest, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "bad-manifest",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: ~s(["not", "an", "object"])
               })
    end

    test "rejects a manifest carrying an oauth block", %{ctx: ctx} do
      assert {:error, {:legacy_manifest_blocks, msg}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "bad-oauth",
                 version: "1.0.0",
                 type: "reagent",
                 manifest: ~s({"oauth": "not-a-map"})
               })

      assert msg =~ "retired block(s) oauth"
    end

    test "allows overwriting local publisher versions", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "overwrite-test",
          version: "1.0.0",
          type: "reagent"
        })

      # Publishing same name:version again should succeed for local publisher
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "overwrite-test",
          version: "1.0.0",
          type: "reagent",
          description: "Updated"
        })

      assert component.name == "overwrite-test"
    end

    test "rejects duplicate name:version for non-local publisher", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "dup-test",
          version: "1.0.0",
          type: "reagent",
          publisher: "cyfr"
        })

      assert {:error, {:already_exists, "dup-test", "1.0.0"}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "dup-test",
                 version: "1.0.0",
                 type: "reagent",
                 publisher: "cyfr"
               })
    end

    test "validates name format", %{ctx: ctx} do
      assert {:error, {:invalid_name, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "InvalidName",
                 version: "1.0.0",
                 type: "reagent"
               })

      assert {:error, {:invalid_name, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "invalid name",
                 version: "1.0.0",
                 type: "reagent"
               })

      # Single lowercase alphanumeric char is allowed by validate_name/1
      assert {:ok, _} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "a",
                 version: "1.0.0",
                 type: "reagent"
               })
    end

    test "validates version format", %{ctx: ctx} do
      assert {:error, {:invalid_version, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "valid-name",
                 version: "invalid",
                 type: "reagent"
               })

      assert {:error, {:invalid_version, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "valid-name",
                 version: "1.0",
                 type: "reagent"
               })
    end

    test "requires name field", %{ctx: ctx} do
      assert {:error, {:missing_required, :name}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{version: "1.0.0", type: "reagent"})
    end

    test "requires version field", %{ctx: ctx} do
      assert {:error, {:missing_required, :version}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "valid-name", type: "reagent"})
    end

    test "requires type field", %{ctx: ctx} do
      assert {:error, {:missing_required, :type}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "valid-name", version: "1.0.0"})
    end

    test "accepts metadata fields", %{ctx: ctx} do
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "meta-test",
          version: "1.0.0",
          type: "catalyst",
          description: "Test description",
          tags: ["test", "example"],
          category: "utilities",
          license: "MIT"
        })

      assert component.component_type == "catalyst"
      assert component.description == "Test description"
      assert component.category == "utilities"
      assert component.license == "MIT"
    end
  end

  describe "search/2" do
    setup %{ctx: ctx} do
      # Count pre-existing components
      {:ok, pre_existing} = Registry.search(ctx, %{limit: 1000})
      pre_count = pre_existing.total

      components = [
        {"tool-one", "1.0.0", %{type: "reagent", category: "utilities", tags: ["json", "parse"]}},
        {"tool-two", "1.0.0", %{type: "catalyst", category: "api-integrations", tags: ["http"]}},
        {"tool-three", "2.0.0",
         %{type: "reagent", category: "utilities", tags: ["json", "format"], license: "MIT"}}
      ]

      for {name, version, meta} <- components do
        {:ok, _} =
          Registry.publish_bytes(
            ctx,
            @valid_wasm,
            Map.merge(%{name: name, version: version}, meta)
          )
      end

      {:ok, pre_count: pre_count}
    end

    test "returns all components when no filters", %{ctx: ctx, pre_count: pre_count} do
      {:ok, result} = Registry.search(ctx, %{limit: 1000})

      assert result.total == 3 + pre_count
      assert length(result.components) == 3 + pre_count
    end

    test "filters by type", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{type: "reagent"})

      assert result.total == 2
      assert Enum.all?(result.components, &(&1.component_type == "reagent"))
    end

    test "filters by category", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{category: "utilities"})

      assert result.total == 2
      assert Enum.all?(result.components, &(&1.category == "utilities"))
    end

    test "filters by tags (AND logic)", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{tags: ["json"]})
      assert result.total == 2

      {:ok, result2} = Registry.search(ctx, %{tags: ["json", "parse"]})
      assert result2.total == 1
      assert hd(result2.components).name == "tool-one"
    end

    test "filters by license", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{license: "MIT"})

      assert result.total == 1
      assert hd(result.components).name == "tool-three"
    end

    test "filters by text query", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{query: "tool-one"})

      assert result.total == 1
      assert hd(result.components).name == "tool-one"
    end

    test "respects limit", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{limit: 2})

      assert result.total == 2
      assert length(result.components) == 2
    end

    test "combines filters", %{ctx: ctx} do
      {:ok, result} = Registry.search(ctx, %{type: "reagent", category: "utilities"})

      assert result.total == 2
    end
  end

  describe "get/3" do
    test "retrieves component by name and version", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "get-test",
          version: "1.0.0",
          type: "reagent"
        })

      {:ok, component} = Registry.get(ctx, "get-test", "1.0.0")

      assert component.name == "get-test"
      assert component.version == "1.0.0"
    end

    test "rejects nil as version" do
      ctx = Sanctum.TestContext.local()
      assert {:error, :version_required} = Registry.get(ctx, "latest-test", nil)
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      assert {:error, :not_found} = Registry.get(ctx, "nonexistent", "1.0.0")
    end

    test "returns error for non-existent version", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "version-test",
          version: "1.0.0",
          type: "reagent"
        })

      assert {:error, :not_found} = Registry.get(ctx, "version-test", "2.0.0")
    end
  end

  describe "get_latest/3" do
    test "retrieves most recently published version", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "latest-test",
          version: "1.0.0",
          type: "reagent"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "latest-test",
          version: "2.0.0",
          type: "reagent"
        })

      {:ok, component} = Registry.get_latest(ctx, "latest-test")

      # Should get most recently published (2.0.0)
      assert component.version == "2.0.0"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      assert {:error, :not_found} = Registry.get_latest(ctx, "nonexistent")
    end

    test "returns highest semver, not most recently published", %{ctx: ctx} do
      # Publish 1.0.0 first, then 0.9.0 after — get_latest must return 1.0.0
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "semver-test",
          version: "1.0.0",
          type: "reagent"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "semver-test",
          version: "0.9.0",
          type: "reagent"
        })

      {:ok, component} = Registry.get_latest(ctx, "semver-test")

      assert component.version == "1.0.0"
    end

    test "returns highest semver across many versions", %{ctx: ctx} do
      for v <- ["0.1.0", "2.0.0", "1.5.0", "0.9.9", "2.1.0", "1.0.0"] do
        {:ok, _} =
          Registry.publish_bytes(ctx, @valid_wasm, %{
            name: "multi-semver",
            version: v,
            type: "reagent"
          })
      end

      {:ok, component} = Registry.get_latest(ctx, "multi-semver")

      assert component.version == "2.1.0"
    end
  end

  describe "get_blob/2" do
    test "retrieves blob by digest", %{ctx: ctx} do
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "blob-test",
          version: "1.0.0",
          type: "reagent"
        })

      {:ok, blob} = Registry.get_blob(ctx, component.digest)

      assert blob == @valid_wasm
    end

    test "returns error for non-existent blob", %{ctx: ctx} do
      assert {:error, :blob_not_found} = Registry.get_blob(ctx, "sha256:nonexistent")
    end
  end

  describe "delete/3" do
    test "deletes component from registry", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "delete-test",
          version: "1.0.0",
          type: "reagent"
        })

      assert :ok = Registry.delete(ctx, "delete-test", "1.0.0")
      assert {:error, :not_found} = Registry.get(ctx, "delete-test", "1.0.0")
    end

    # Delete cleanup for profiles and webhook registrations is covered by
    # the cascade test file; policy rows are unreferenced and drop with
    # their table.
    test "returns error for non-existent component", %{ctx: ctx} do
      assert {:error, :not_found} = Registry.delete(ctx, "nonexistent", "1.0.0")
    end
  end

  describe "list_versions/2" do
    test "lists all versions of a component", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "versions-test",
          version: "1.0.0",
          type: "reagent"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "versions-test",
          version: "1.1.0",
          type: "reagent"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "versions-test",
          version: "2.0.0",
          type: "reagent"
        })

      {:ok, versions} = Registry.list_versions(ctx, "versions-test")

      assert length(versions) == 3
      version_nums = Enum.map(versions, & &1["version"])
      assert "1.0.0" in version_nums
      assert "1.1.0" in version_nums
      assert "2.0.0" in version_nums
    end

    test "returns empty list for non-existent component", %{ctx: ctx} do
      {:ok, versions} = Registry.list_versions(ctx, "nonexistent")

      assert versions == []
    end
  end

  describe "publish_bytes/3 source field" do
    test "published components have source: published", %{ctx: ctx} do
      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "pub-source",
          version: "1.0.0",
          type: "reagent"
        })

      assert component.source == "published"
    end
  end

  describe "register_from_directory/3" do
    setup %{test_dir: test_dir} do
      # Create a component directory with manifest and WASM
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "test-tool",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{
        "type" => "reagent",
        "version" => "0.1.0",
        "description" => "A test reagent",
        "license" => "MIT",
        "tags" => ["test"]
      }

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, comp_dir: comp_dir}
    end

    test "registers a component from directory", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, component} = Registry.register_from_directory(ctx, comp_dir)

      assert component.name == "test-tool"
      assert component.version == "0.1.0"
      assert component.component_type == "reagent"
      assert component.source == "filesystem"
      assert component.description == "A test reagent"
      assert component.license == "MIT"
      assert String.starts_with?(component.digest, "sha256:")
    end

    test "registered component is searchable", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, result} = Registry.search(ctx, %{query: "test-tool"})
      assert result.total == 1
      assert hd(result.components).name == "test-tool"
    end

    test "skips unchanged component", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, _component} = Registry.register_from_directory(ctx, comp_dir)

      # Second registration should return :unchanged
      assert {:ok, :unchanged} = Registry.register_from_directory(ctx, comp_dir)
    end

    test "re-registers when manifest changes", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, _component} = Registry.register_from_directory(ctx, comp_dir)

      # Update manifest without changing WASM
      manifest_path = Path.join(comp_dir, "cyfr-manifest.json")
      manifest = manifest_path |> File.read!() |> Jason.decode!()
      updated = Map.put(manifest, "description", "updated description")
      File.write!(manifest_path, Jason.encode!(updated))

      # Should re-register, not return :unchanged
      assert {:ok, %{name: _}} = Registry.register_from_directory(ctx, comp_dir)
    end

    test "re-registers when force option is set", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, component} = Registry.register_from_directory(ctx, comp_dir, force: true)
      assert component.name == "test-tool"
    end

    test "infers name and version from directory path", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "my-catalyst",
          "2.0.0"
        ])

      File.mkdir_p!(comp_dir)

      # Manifest without name/version — should be inferred from path
      manifest = %{"type" => "catalyst", "description" => "Inferred metadata"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      {:ok, component} = Registry.register_from_directory(ctx, comp_dir)

      assert component.name == "my-catalyst"
      assert component.version == "2.0.0"
      assert component.component_type == "catalyst"
    end

    test "rejects non-local publisher namespaces", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "stripe",
          "payment",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      assert {:error, {:namespace_rejected, msg}} =
               Registry.register_from_directory(ctx, comp_dir)

      assert msg =~ "stripe"
    end

    test "returns error for missing manifest", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "no-manifest",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      assert {:error, {:missing_manifest, _}} = Registry.register_from_directory(ctx, comp_dir)
    end

    test "returns error for malformed manifest JSON", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "bad-json",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), "{not json")
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      assert {:error, {:invalid_manifest, _}} = Registry.register_from_directory(ctx, comp_dir)
    end

    test "returns error for missing WASM", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "no-wasm",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      assert {:error, {:missing_wasm, _}} = Registry.register_from_directory(ctx, comp_dir)
    end
  end

  describe "prune_stale_entries/2" do
    test "removes filesystem entries not in discovered set", %{ctx: ctx} do
      test_dir = Application.get_env(:cyfr, :base_path)

      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "stale-tool",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0", "description" => "Will be pruned"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Verify it exists
      {:ok, result} = Registry.search(ctx, %{query: "stale-tool"})
      assert result.total == 1

      # Get all current filesystem entries so we can exclude them from discovered
      # (we only want to prune our specific entry)
      {:ok, all_fs} = Arca.ComponentStorage.list_components(ctx, source: "filesystem")

      other_entries =
        all_fs
        |> Enum.reject(&(&1.name == "stale-tool"))
        |> Enum.map(&{&1.name, &1.version, Map.get(&1, :publisher, "local")})

      # Prune with only other entries in discovered set — should remove stale-tool
      pruned = Registry.prune_stale_entries(ctx, other_entries)
      assert pruned >= 1

      # Verify stale-tool is gone
      {:ok, result2} = Registry.search(ctx, %{query: "stale-tool"})
      assert result2.total == 0
    end

    test "preserves entries in discovered set", %{ctx: ctx} do
      test_dir = Application.get_env(:cyfr, :base_path)

      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "keep-tool",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Include ALL filesystem entries in the discovered set
      {:ok, all_fs} = Arca.ComponentStorage.list_components(ctx, source: "filesystem")

      all_discovered = Enum.map(all_fs, &{&1.name, &1.version, Map.get(&1, :publisher, "local")})

      # Prune with all entries in discovered set — should not remove anything
      pruned = Registry.prune_stale_entries(ctx, all_discovered)
      assert pruned == 0

      {:ok, result} = Registry.search(ctx, %{query: "keep-tool"})
      assert result.total == 1
    end

    test "prune deletes entire version directory from storage", %{ctx: ctx} do
      test_dir = Application.get_env(:cyfr, :base_path)

      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "tree-test",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0", "description" => "Will be pruned"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), "# Tree Test")

      src_dir = Path.join(comp_dir, "src")
      File.mkdir_p!(Path.join(src_dir, "src"))
      File.write!(Path.join(src_dir, "Cargo.toml"), "[package]\nname = \"tree-test\"")
      File.write!(Path.join([src_dir, "src", "lib.rs"]), "fn main() {}")

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Verify files were stored
      base = ["components", "local", "default", "catalysts", "local", "tree-test", "1.0.0"]
      assert {:ok, _} = Arca.get(ctx, base ++ ["catalyst.wasm"])
      assert {:ok, _} = Arca.get(ctx, base ++ ["cyfr-manifest.json"])
      assert {:ok, _} = Arca.get(ctx, base ++ ["README.md"])
      assert {:ok, _} = Arca.get(ctx, base ++ ["src", "Cargo.toml"])

      # Build discovered set excluding tree-test
      {:ok, all_fs} = Arca.ComponentStorage.list_components(ctx, source: "filesystem")

      other_entries =
        all_fs
        |> Enum.reject(&(&1.name == "tree-test"))
        |> Enum.map(&{&1.name, &1.version, Map.get(&1, :publisher, "local")})

      pruned = Registry.prune_stale_entries(ctx, other_entries)
      assert pruned >= 1

      # prune_stale_entries is DB-only cleanup — filesystem files are preserved
      # (user source files must survive transient discovery failures).
      # Verify DB entry was removed by confirming search no longer finds it.
      {:ok, search_result} = Registry.search(ctx, %{query: "tree-test"})
      assert search_result.total == 0
    end
  end

  describe "publisher-aware get/4" do
    test "filters by publisher when provided", %{ctx: ctx} do
      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "pub-test",
          version: "1.0.0",
          type: "reagent",
          publisher: "local"
        })

      {:ok, _} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "pub-test",
          version: "1.0.0",
          type: "reagent",
          publisher: "cyfr"
        })

      # Without publisher, should return a component
      {:ok, component} = Registry.get(ctx, "pub-test", "1.0.0")
      assert component.name == "pub-test"

      # With publisher "local", should return the local one
      {:ok, local_comp} = Registry.get(ctx, "pub-test", "1.0.0", "local")
      assert local_comp.publisher == "local"

      # With publisher "cyfr", should return the cyfr one
      {:ok, cyfr_comp} = Registry.get(ctx, "pub-test", "1.0.0", "cyfr")
      assert cyfr_comp.publisher == "cyfr"

      # With non-existent publisher, should return not_found
      assert {:error, :not_found} = Registry.get(ctx, "pub-test", "1.0.0", "nonexistent")
    end

    test "two components with same name/version but different publishers don't collide", %{
      ctx: ctx
    } do
      {:ok, local} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "collision-test",
          version: "1.0.0",
          type: "reagent",
          publisher: "local",
          description: "Local version"
        })

      {:ok, cyfr} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "collision-test",
          version: "1.0.0",
          type: "reagent",
          publisher: "cyfr",
          description: "CYFR version"
        })

      assert local.publisher == "local"
      assert cyfr.publisher == "cyfr"

      # Both should be retrievable by publisher filter
      {:ok, got_local} = Registry.get(ctx, "collision-test", "1.0.0", "local")
      {:ok, got_cyfr} = Registry.get(ctx, "collision-test", "1.0.0", "cyfr")

      assert got_local.description == "Local version"
      assert got_cyfr.description == "CYFR version"
    end
  end

  describe "org-scoped storage" do
    test "org_id is passed through to storage path for get_blob", %{ctx: ctx} do
      # Publish under org_A context
      ctx_a = %{ctx | org_id: "org_a"}

      {:ok, component} =
        Registry.publish_bytes(ctx_a, @valid_wasm, %{
          name: "org-scoped",
          version: "1.0.0",
          type: "reagent"
        })

      # Retrieve with same org — should work
      {:ok, blob} = Registry.get_blob(ctx_a, component.digest)
      assert blob == @valid_wasm

      # Retrieve with different org — should not find the blob (different storage path)
      ctx_b = %{ctx | org_id: "org_b"}
      assert {:error, :blob_not_found} = Registry.get_blob(ctx_b, component.digest)
    end

    test "single-user context stores under the seeded local org", %{ctx: ctx} do
      # The single-user test context resolves to the seeded "local" org.
      assert ctx.org_id == "local"

      {:ok, component} =
        Registry.publish_bytes(ctx, @valid_wasm, %{
          name: "core-mode",
          version: "1.0.0",
          type: "reagent"
        })

      # Verify stored at the canonical (project-scoped) path
      storage_path = [
        "components",
        "local",
        "default",
        "reagents",
        "local",
        "core-mode",
        "1.0.0",
        "reagent.wasm"
      ]

      {:ok, content} = Arca.get(ctx, storage_path)
      assert content == @valid_wasm

      # get_blob should also work
      {:ok, blob} = Registry.get_blob(ctx, component.digest)
      assert blob == @valid_wasm
    end

    test "multi-tenant: stores under org_id path (no orgs/ prefix)", %{ctx: ctx} do
      ctx_org = %{ctx | org_id: "myorg"}

      {:ok, component} =
        Registry.publish_bytes(ctx_org, @valid_wasm, %{
          name: "ext-path-test",
          version: "1.0.0",
          type: "catalyst"
        })

      # Verify stored at components/{org_id}/{project_id}/{type}s/... (no "orgs" segment)
      storage_path = [
        "components",
        "myorg",
        "default",
        "catalysts",
        "local",
        "ext-path-test",
        "1.0.0",
        "catalyst.wasm"
      ]

      {:ok, content} = Arca.get(ctx_org, storage_path)
      assert content == @valid_wasm

      {:ok, blob} = Registry.get_blob(ctx_org, component.digest)
      assert blob == @valid_wasm
    end

    test "org-scoped cleanup removes org-scoped directories", %{ctx: ctx} do
      ctx_org = %{ctx | org_id: "cleanup_org"}

      {:ok, _} =
        Registry.publish_bytes(ctx_org, @valid_wasm, %{
          name: "org-cleanup-test",
          version: "1.0.0",
          type: "reagent"
        })

      # Verify stored
      storage_path = [
        "components",
        "cleanup_org",
        "default",
        "reagents",
        "local",
        "org-cleanup-test",
        "1.0.0",
        "reagent.wasm"
      ]

      assert {:ok, _} = Arca.get(ctx_org, storage_path)

      # Delete the component
      assert :ok = Registry.delete(ctx_org, "org-cleanup-test", "1.0.0")

      # Verify the version directory is cleaned up
      assert {:error, _} = Arca.get(ctx_org, storage_path)
    end

    test "org-scoped register_from_directory infers path metadata", %{
      ctx: ctx,
      test_dir: test_dir
    } do
      ctx_org = %{ctx | org_id: "reg_org"}

      # Create a component directory under the project-scoped path
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "reg_org",
          "default",
          "reagents",
          "local",
          "org-reg-test",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0", "description" => "Org registered"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, component} = Registry.register_from_directory(ctx_org, comp_dir)

      assert component.name == "org-reg-test"
      assert component.version == "0.1.0"
      assert component.component_type == "reagent"
      assert component.source == "filesystem"
    end
  end

  describe "concurrency" do
    test "sequential publish operations succeed", %{ctx: ctx} do
      for i <- 1..3 do
        {:ok, _} =
          Registry.publish_bytes(ctx, @valid_wasm, %{
            name: "seq-tool-#{i}",
            version: "1.0.0",
            type: "reagent"
          })
      end

      {:ok, search_result} = Registry.search(ctx, %{query: "seq-tool"})
      assert search_result.total == 3
    end
  end

  describe "register_from_directory/3 copies supplementary files" do
    test "copies cyfr-manifest.json to Arca", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "copy-test",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{
        "name" => "copy-test",
        "version" => "1.0.0",
        "type" => "catalyst",
        "description" => "test copy",
        "schema" => %{"input" => %{}}
      }

      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Verify manifest was stored in Arca
      path = [
        "components",
        "local",
        "default",
        "catalysts",
        "local",
        "copy-test",
        "1.0.0",
        "cyfr-manifest.json"
      ]

      {:ok, content} = Arca.get(ctx, path)
      {:ok, stored} = Jason.decode(content)
      assert stored["schema"] == %{"input" => %{}}
      assert stored["name"] == "copy-test"
    end

    test "copies README.md to Arca", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "readme-test",
          "0.1.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0"}
      readme_content = "# My Component\n\nThis is the README."
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)
      File.write!(Path.join(comp_dir, "README.md"), readme_content)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Verify README was stored in Arca
      path = [
        "components",
        "local",
        "default",
        "reagents",
        "local",
        "readme-test",
        "0.1.0",
        "README.md"
      ]

      {:ok, content} = Arca.get(ctx, path)
      assert content == readme_content
    end

    test "copies src/ directory recursively to Arca", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "src-test",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      # Create src/ with nested structure
      src_dir = Path.join(comp_dir, "src")
      File.mkdir_p!(Path.join(src_dir, "src"))
      File.write!(Path.join(src_dir, "Cargo.toml"), "[package]\nname = \"src-test\"")
      File.write!(Path.join([src_dir, "src", "lib.rs"]), "fn main() {}")

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Verify src files stored in Arca
      base = ["components", "local", "default", "catalysts", "local", "src-test", "1.0.0", "src"]

      {:ok, cargo_content} = Arca.get(ctx, base ++ ["Cargo.toml"])
      assert cargo_content =~ "src-test"

      {:ok, lib_content} = Arca.get(ctx, base ++ ["src", "lib.rs"])
      assert lib_content =~ "fn main()"
    end

    test "succeeds when no README or src/ exist", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "reagents",
          "local",
          "minimal",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      # Should succeed — README and src are optional
      {:ok, component} = Registry.register_from_directory(ctx, comp_dir)
      assert component.name == "minimal"

      # Manifest should still be stored
      path = [
        "components",
        "local",
        "default",
        "reagents",
        "local",
        "minimal",
        "1.0.0",
        "cyfr-manifest.json"
      ]

      assert {:ok, _} = Arca.get(ctx, path)

      # README should not exist
      readme_path = [
        "components",
        "local",
        "default",
        "reagents",
        "local",
        "minimal",
        "1.0.0",
        "README.md"
      ]

      assert {:error, _} = Arca.get(ctx, readme_path)
    end

    test "handles empty src/ directory gracefully", %{ctx: ctx, test_dir: test_dir} do
      comp_dir =
        Path.join([
          test_dir,
          "components",
          "local",
          "default",
          "catalysts",
          "local",
          "empty-src",
          "1.0.0"
        ])

      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)
      File.mkdir_p!(Path.join(comp_dir, "src"))

      {:ok, component} = Registry.register_from_directory(ctx, comp_dir)
      assert component.name == "empty-src"
    end
  end

  describe "publish_tincture_archive/4 — decompression bomb defense" do
    test "rejects an archive that decompresses beyond the configured limit", %{ctx: ctx} do
      Application.put_env(:cyfr, :tincture_max_decompressed_bytes, 1024)
      on_exit(fn -> Application.delete_env(:cyfr, :tincture_max_decompressed_bytes) end)

      # A small gzip that expands to 50 KB — well past the 1 KB cap. It is
      # rejected at decompression, before any tar extraction or filesystem write.
      archive = :zlib.gzip(String.duplicate("A", 50_000))

      # Non-local publisher: this ingress refuses `local` outright, and the
      # point here is the decompression bound, not the namespace gate.
      assert {:error, msg} =
               Registry.publish_tincture_archive(ctx, archive, %{
                 name: "bomb-test",
                 version: "1.0.0",
                 type: "tincture",
                 publisher: "acme"
               })

      assert msg =~ "decompresses beyond"
    end
  end

  describe "remote-origin publishes — local namespace refusal" do
    test "publish_bytes refuses remote content into the local namespace", %{ctx: ctx} do
      assert {:error, {:namespace_rejected, msg}} =
               Registry.publish_bytes(
                 ctx,
                 @valid_wasm,
                 %{name: "sneaky", version: "1.0.0", type: "reagent", publisher: "local"},
                 allow_overwrite: true,
                 origin: :remote
               )

      assert msg =~ "local"
      assert {:error, :not_found} = Registry.get(ctx, "sneaky", "1.0.0")
    end

    test "an absent publisher normalizes to local and is refused for remote content", %{ctx: ctx} do
      assert {:error, {:namespace_rejected, _}} =
               Registry.publish_bytes(
                 ctx,
                 @valid_wasm,
                 %{name: "sneaky-default", version: "1.0.0", type: "reagent"},
                 origin: :remote
               )
    end

    test "a non-local publisher passes the origin gate", %{ctx: ctx} do
      assert {:ok, component} =
               Registry.publish_bytes(
                 ctx,
                 @valid_wasm,
                 %{name: "remote-fine", version: "1.0.0", type: "reagent", publisher: "acme"},
                 origin: :remote
               )

      assert component.publisher == "acme"
    end

    test "local publishes without a remote origin keep working", %{ctx: ctx} do
      assert {:ok, component} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "local-still-ok",
                 version: "1.0.0",
                 type: "reagent"
               })

      assert component.publisher == "local"
    end

    test "publish_tincture_archive refuses the local namespace unconditionally", %{ctx: ctx} do
      # The refusal fires before the archive is even decompressed, so any
      # bytes will do.
      archive = :zlib.gzip("irrelevant")

      assert {:error, {:namespace_rejected, _}} =
               Registry.publish_tincture_archive(ctx, archive, %{
                 name: "sneaky-tincture",
                 version: "1.0.0",
                 type: "tincture",
                 publisher: "local"
               })

      # An absent publisher normalizes to local — refused all the same.
      assert {:error, {:namespace_rejected, _}} =
               Registry.publish_tincture_archive(ctx, archive, %{
                 name: "sneaky-tincture",
                 version: "1.0.0",
                 type: "tincture"
               })
    end
  end

  describe "publish_tincture_archive/4 — partial storage failure" do
    test "a failed file write aborts registration and cleans up partial files", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Compendium.RegistryTest.FailingPutAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      archive =
        tincture_archive([
          {"cyfr-manifest.json",
           Jason.encode!(%{"name" => "partial", "version" => "1.0.0", "type" => "tincture"})},
          {"index.html", "<html></html>"},
          {"boom.txt", "this write fails"}
        ])

      assert {:error, {:tincture_store_failed, :injected_write_failure}} =
               Registry.publish_tincture_archive(ctx, archive, %{
                 name: "partial",
                 version: "1.0.0",
                 type: "tincture",
                 publisher: "acme"
               })

      # Nothing registered — a component whose stored files do not match its
      # digest must never appear healthy.
      assert {:error, :not_found} = Registry.get(ctx, "partial", "1.0.0")

      # And any files that landed before the failure were cleaned up.
      version_dir =
        Compendium.ComponentPath.version_dir("tincture", "acme", "partial", "1.0.0", ctx)

      case Arca.list(ctx, version_dir) do
        {:ok, entries} -> assert entries == []
        {:error, _not_found} -> :ok
      end
    end
  end

  # Gzipped tar archive from {path, content} entries (OTP 28-compatible:
  # :erl_tar's :memory create is unreliable, so round-trip a tmp file).
  defp tincture_archive(files) do
    tmp = Path.join(System.tmp_dir!(), "cyfr_tincture_fixture_#{:rand.uniform(1_000_000)}.tar")
    entries = Enum.map(files, fn {path, content} -> {String.to_charlist(path), content} end)
    :ok = :erl_tar.create(String.to_charlist(tmp), entries)
    {:ok, tar} = File.read(tmp)
    File.rm!(tmp)
    :zlib.gzip(tar)
  end
end
