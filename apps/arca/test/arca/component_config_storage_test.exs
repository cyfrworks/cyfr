defmodule Arca.ComponentConfigStorageTest do
  use ExUnit.Case, async: false

  alias Arca.ComponentConfigStorage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    :ok
  end

  defp unique_ref, do: "local.test-component-#{:rand.uniform(100_000)}:1.0.0"

  describe "put_config/3 and get_all_config/1" do
    test "stores and retrieves a single config value" do
      ref = unique_ref()

      assert :ok = ComponentConfigStorage.put_config(ref, "api_version", "v2")
      assert {:ok, %{"api_version" => "v2"}} = ComponentConfigStorage.get_all_config(ref)
    end

    test "stores multiple keys for the same component" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "key1", "value1")
      :ok = ComponentConfigStorage.put_config(ref, "key2", 42)
      :ok = ComponentConfigStorage.put_config(ref, "key3", true)

      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      assert config["key1"] == "value1"
      assert config["key2"] == 42
      assert config["key3"] == true
    end

    test "upserts existing key" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "key", "old")
      :ok = ComponentConfigStorage.put_config(ref, "key", "new")

      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      assert config["key"] == "new"
    end

    test "supports various JSON value types" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "string", "hello")
      :ok = ComponentConfigStorage.put_config(ref, "integer", 42)
      :ok = ComponentConfigStorage.put_config(ref, "float", 3.14)
      :ok = ComponentConfigStorage.put_config(ref, "boolean", false)
      :ok = ComponentConfigStorage.put_config(ref, "list", ["a", "b"])
      :ok = ComponentConfigStorage.put_config(ref, "map", %{"nested" => true})
      :ok = ComponentConfigStorage.put_config(ref, "null_val", nil)

      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      assert config["string"] == "hello"
      assert config["integer"] == 42
      assert config["float"] == 3.14
      assert config["boolean"] == false
      assert config["list"] == ["a", "b"]
      assert config["map"] == %{"nested" => true}
      assert config["null_val"] == nil
    end

    test "returns empty map for unknown component" do
      assert {:ok, %{}} = ComponentConfigStorage.get_all_config("nonexistent:0.0.0")
    end

    test "isolates config between components" do
      ref1 = unique_ref()
      ref2 = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref1, "key", "value1")
      :ok = ComponentConfigStorage.put_config(ref2, "key", "value2")

      {:ok, config1} = ComponentConfigStorage.get_all_config(ref1)
      {:ok, config2} = ComponentConfigStorage.get_all_config(ref2)

      assert config1["key"] == "value1"
      assert config2["key"] == "value2"
    end
  end

  describe "delete_config/2" do
    test "deletes a specific key" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "keep", "yes")
      :ok = ComponentConfigStorage.put_config(ref, "remove", "bye")

      assert :ok = ComponentConfigStorage.delete_config(ref, "remove")

      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      assert config["keep"] == "yes"
      refute Map.has_key?(config, "remove")
    end

    test "succeeds for nonexistent key" do
      ref = unique_ref()
      assert :ok = ComponentConfigStorage.delete_config(ref, "nope")
    end
  end

  describe "delete_all_config/1" do
    test "removes all keys for a component" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "k1", "v1")
      :ok = ComponentConfigStorage.put_config(ref, "k2", "v2")

      assert :ok = ComponentConfigStorage.delete_all_config(ref)
      assert {:ok, %{}} = ComponentConfigStorage.get_all_config(ref)
    end

    test "does not affect other components" do
      ref1 = unique_ref()
      ref2 = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref1, "key", "v1")
      :ok = ComponentConfigStorage.put_config(ref2, "key", "v2")

      :ok = ComponentConfigStorage.delete_all_config(ref1)

      assert {:ok, %{}} = ComponentConfigStorage.get_all_config(ref1)
      assert {:ok, %{"key" => "v2"}} = ComponentConfigStorage.get_all_config(ref2)
    end

    test "succeeds for component with no config" do
      assert :ok = ComponentConfigStorage.delete_all_config("empty:1.0.0")
    end
  end

  describe "list_component_refs/0" do
    test "returns empty list when no configs exist" do
      assert [] = ComponentConfigStorage.list_component_refs()
    end

    test "returns distinct component refs" do
      ref1 = "local.list-test-a-#{:rand.uniform(100_000)}:1.0.0"
      ref2 = "local.list-test-b-#{:rand.uniform(100_000)}:1.0.0"

      :ok = ComponentConfigStorage.put_config(ref1, "k1", "v1")
      :ok = ComponentConfigStorage.put_config(ref1, "k2", "v2")
      :ok = ComponentConfigStorage.put_config(ref2, "k1", "v1")

      refs = ComponentConfigStorage.list_component_refs()
      assert ref1 in refs
      assert ref2 in refs
    end
  end

  describe "caching" do
    test "invalidates cache on put" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "key", "v1")
      {:ok, %{"key" => "v1"}} = ComponentConfigStorage.get_all_config(ref)

      # Second put should invalidate cache
      :ok = ComponentConfigStorage.put_config(ref, "key", "v2")
      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      assert config["key"] == "v2"
    end

    test "invalidates cache on delete" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "key", "v1")
      {:ok, %{"key" => "v1"}} = ComponentConfigStorage.get_all_config(ref)

      :ok = ComponentConfigStorage.delete_config(ref, "key")
      {:ok, config} = ComponentConfigStorage.get_all_config(ref)
      refute Map.has_key?(config, "key")
    end

    test "invalidates cache on delete_all" do
      ref = unique_ref()

      :ok = ComponentConfigStorage.put_config(ref, "key", "v1")
      {:ok, %{"key" => "v1"}} = ComponentConfigStorage.get_all_config(ref)

      :ok = ComponentConfigStorage.delete_all_config(ref)
      assert {:ok, %{}} = ComponentConfigStorage.get_all_config(ref)
    end
  end
end
