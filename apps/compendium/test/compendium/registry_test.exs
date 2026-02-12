defmodule Compendium.RegistryTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry
  alias Sanctum.Context

  # Valid minimal WASM with export section
  @valid_wasm (
    <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>  # magic + version
    <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>               # type section
    <<0x03, 0x02, 0x01, 0x00>> <>                           # function section
    <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>        # export section
    <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>                  # code section
  )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_registry_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  describe "publish_bytes/3" do
    test "publishes WASM bytes to registry", %{ctx: ctx} do
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "test-tool",
        version: "1.0.0",
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
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "blob-test",
        version: "1.0.0"
      })

      # Verify WASM exists in Arca storage at canonical path
      storage_path = ["components", "reagents", "local", "blob-test", "1.0.0", "reagent.wasm"]
      {:ok, %{content: b64_content}} = Arca.MCP.handle("storage", ctx, %{"action" => "read", "path" => storage_path})
      assert Base.decode64!(b64_content) == @valid_wasm

      # Also verify we can get it via get_blob
      {:ok, blob} = Registry.get_blob(ctx, component.digest)
      assert blob == @valid_wasm
    end

    test "allows overwriting local publisher versions", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "overwrite-test",
        version: "1.0.0"
      })

      # Publishing same name:version again should succeed for local publisher
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "overwrite-test",
        version: "1.0.0",
        description: "Updated"
      })

      assert component.name == "overwrite-test"
    end

    test "rejects duplicate name:version for non-local publisher", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "dup-test",
        version: "1.0.0",
        publisher: "cyfr"
      })

      assert {:error, {:already_exists, "dup-test", "1.0.0"}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{
                 name: "dup-test",
                 version: "1.0.0",
                 publisher: "cyfr"
               })
    end

    test "validates name format", %{ctx: ctx} do
      assert {:error, {:invalid_name, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "InvalidName", version: "1.0.0"})

      assert {:error, {:invalid_name, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "invalid name", version: "1.0.0"})

      assert {:error, {:invalid_name, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "a", version: "1.0.0"})
    end

    test "validates version format", %{ctx: ctx} do
      assert {:error, {:invalid_version, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "valid-name", version: "invalid"})

      assert {:error, {:invalid_version, _}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "valid-name", version: "1.0"})
    end

    test "requires name field", %{ctx: ctx} do
      assert {:error, {:missing_required, :name}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{version: "1.0.0"})
    end

    test "requires version field", %{ctx: ctx} do
      assert {:error, {:missing_required, :version}} =
               Registry.publish_bytes(ctx, @valid_wasm, %{name: "valid-name"})
    end

    test "accepts metadata fields", %{ctx: ctx} do
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{
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
        {"tool-three", "2.0.0", %{type: "reagent", category: "utilities", tags: ["json", "format"], license: "MIT"}}
      ]

      for {name, version, meta} <- components do
        {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, Map.merge(%{name: name, version: version}, meta))
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
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "get-test", version: "1.0.0"})

      {:ok, component} = Registry.get(ctx, "get-test", "1.0.0")

      assert component.name == "get-test"
      assert component.version == "1.0.0"
    end

    test "retrieves latest version", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "latest-test", version: "1.0.0"})
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "latest-test", version: "2.0.0"})

      {:ok, component} = Registry.get(ctx, "latest-test", "latest")

      # Should get most recently published (2.0.0)
      assert component.version == "2.0.0"
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      assert {:error, :not_found} = Registry.get(ctx, "nonexistent", "1.0.0")
    end

    test "returns error for non-existent version", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "version-test", version: "1.0.0"})

      assert {:error, :not_found} = Registry.get(ctx, "version-test", "2.0.0")
    end
  end

  describe "get_blob/2" do
    test "retrieves blob by digest", %{ctx: ctx} do
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "blob-test", version: "1.0.0"})

      {:ok, blob} = Registry.get_blob(ctx, component.digest)

      assert blob == @valid_wasm
    end

    test "returns error for non-existent blob", %{ctx: ctx} do
      assert {:error, :blob_not_found} = Registry.get_blob(ctx, "sha256:nonexistent")
    end
  end

  describe "delete/3" do
    test "deletes component from registry", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "delete-test", version: "1.0.0"})

      assert :ok = Registry.delete(ctx, "delete-test", "1.0.0")
      assert {:error, :not_found} = Registry.get(ctx, "delete-test", "1.0.0")
    end

    test "returns error for non-existent component", %{ctx: ctx} do
      assert {:error, :not_found} = Registry.delete(ctx, "nonexistent", "1.0.0")
    end
  end

  describe "list_versions/2" do
    test "lists all versions of a component", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "versions-test", version: "1.0.0"})
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "versions-test", version: "1.1.0"})
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "versions-test", version: "2.0.0"})

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
      {:ok, component} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "pub-source",
        version: "1.0.0"
      })

      assert component.source == "published"
    end
  end

  describe "register_from_directory/3" do
    setup %{test_dir: test_dir} do
      # Create a component directory with manifest and WASM
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "test-tool", "0.1.0"])
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

    test "re-registers when force option is set", %{ctx: ctx, comp_dir: comp_dir} do
      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      {:ok, component} = Registry.register_from_directory(ctx, comp_dir, force: true)
      assert component.name == "test-tool"
    end

    test "infers name and version from directory path", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = Path.join([test_dir, "components", "catalysts", "local", "my-catalyst", "2.0.0"])
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

    test "rejects non-local/agent publisher namespaces", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = Path.join([test_dir, "components", "catalysts", "stripe", "payment", "1.0.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "catalyst", "version" => "1.0.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "catalyst.wasm"), @valid_wasm)

      assert {:error, {:namespace_rejected, msg}} = Registry.register_from_directory(ctx, comp_dir)
      assert msg =~ "stripe"
    end

    test "allows agent namespace", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = Path.join([test_dir, "components", "reagents", "agent", "ai-tool", "0.1.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0", "description" => "Agent tool"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, component} = Registry.register_from_directory(ctx, comp_dir)
      assert component.name == "ai-tool"
      assert component.source == "filesystem"
    end

    test "returns error for missing manifest", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "no-manifest", "0.1.0"])
      File.mkdir_p!(comp_dir)
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      assert {:error, {:missing_manifest, _}} = Registry.register_from_directory(ctx, comp_dir)
    end

    test "returns error for missing WASM", %{ctx: ctx, test_dir: test_dir} do
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "no-wasm", "0.1.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))

      assert {:error, {:missing_wasm, _}} = Registry.register_from_directory(ctx, comp_dir)
    end
  end

  describe "prune_stale_entries/2" do
    test "removes filesystem entries not in discovered set", %{ctx: ctx} do
      test_dir = Application.get_env(:arca, :base_path)
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "stale-tool", "0.1.0"])
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
      {:ok, %{components: all_fs}} = Arca.MCP.handle("component_store", ctx,
        %{"action" => "list", "source" => "filesystem", "limit" => 10_000})

      other_entries =
        all_fs
        |> Enum.reject(&(&1.name == "stale-tool"))
        |> Enum.map(&{&1.name, &1.version})

      # Prune with only other entries in discovered set — should remove stale-tool
      pruned = Registry.prune_stale_entries(ctx, other_entries)
      assert pruned >= 1

      # Verify stale-tool is gone
      {:ok, result2} = Registry.search(ctx, %{query: "stale-tool"})
      assert result2.total == 0
    end

    test "preserves entries in discovered set", %{ctx: ctx} do
      test_dir = Application.get_env(:arca, :base_path)
      comp_dir = Path.join([test_dir, "components", "reagents", "local", "keep-tool", "0.1.0"])
      File.mkdir_p!(comp_dir)

      manifest = %{"type" => "reagent", "version" => "0.1.0"}
      File.write!(Path.join(comp_dir, "cyfr-manifest.json"), Jason.encode!(manifest))
      File.write!(Path.join(comp_dir, "reagent.wasm"), @valid_wasm)

      {:ok, _} = Registry.register_from_directory(ctx, comp_dir)

      # Include ALL filesystem entries in the discovered set
      {:ok, %{components: all_fs}} = Arca.MCP.handle("component_store", ctx,
        %{"action" => "list", "source" => "filesystem", "limit" => 10_000})

      all_discovered = Enum.map(all_fs, &{&1.name, &1.version})

      # Prune with all entries in discovered set — should not remove anything
      pruned = Registry.prune_stale_entries(ctx, all_discovered)
      assert pruned == 0

      {:ok, result} = Registry.search(ctx, %{query: "keep-tool"})
      assert result.total == 1
    end
  end

  describe "publisher-aware get/4" do
    test "filters by publisher when provided", %{ctx: ctx} do
      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "pub-test",
        version: "1.0.0",
        publisher: "local"
      })

      {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "pub-test",
        version: "1.0.0",
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

    test "two components with same name/version but different publishers don't collide", %{ctx: ctx} do
      {:ok, local} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "collision-test",
        version: "1.0.0",
        publisher: "local",
        description: "Local version"
      })

      {:ok, cyfr} = Registry.publish_bytes(ctx, @valid_wasm, %{
        name: "collision-test",
        version: "1.0.0",
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

  describe "concurrency" do
    test "sequential publish operations succeed", %{ctx: ctx} do
      for i <- 1..3 do
        {:ok, _} = Registry.publish_bytes(ctx, @valid_wasm, %{name: "seq-tool-#{i}", version: "1.0.0"})
      end

      {:ok, search_result} = Registry.search(ctx, %{query: "seq-tool"})
      assert search_result.total == 3
    end
  end
end
