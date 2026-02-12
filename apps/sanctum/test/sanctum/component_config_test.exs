defmodule Sanctum.ComponentConfigTest do
  use ExUnit.Case, async: false

  alias Sanctum.ComponentConfig
  alias Sanctum.Context

  # Helper to register a component in SQLite so ComponentConfig can resolve dirs
  defp register_component(name, version \\ "1.0.0", type \\ "reagent") do
    now = DateTime.utc_now()
    Arca.ComponentStorage.put_component(%{
      id: "comp_test_#{name}_#{version}",
      name: name,
      version: version,
      component_type: type,
      description: "test component",
      tags: "[]",
      category: nil,
      license: nil,
      digest: "sha256:test",
      size: 100,
      exports: "[]",
      publisher: "local",
      publisher_id: "test",
      org_id: nil,
      inserted_at: now,
      updated_at: now
    })

    # Return the storage path segments for this component
    ["components", "#{type}s", "local", name, version]
  end

  # Use component_ref format: "name:version"
  defp component_ref(name, version \\ "1.0.0"), do: "#{name}:#{version}"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    test_dir = Path.join(System.tmp_dir!(), "cyfr_config_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:arca, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: Context.local()}
  end

  describe "get/3 and set/4" do
    test "sets and retrieves a config value", %{ctx: ctx} do
      name = "config-test-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      assert :ok = ComponentConfig.set(ctx, ref, "api_version", "2023-10-16")
      assert {:ok, "2023-10-16"} = ComponentConfig.get(ctx, ref, "api_version")
    end

    test "returns not_found for missing key", %{ctx: ctx} do
      name = "nf-test-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      assert {:error, :not_found} = ComponentConfig.get(ctx, ref, "nonexistent")
    end

    test "overwrites existing value", %{ctx: ctx} do
      name = "overwrite-test-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "key", "old")
      :ok = ComponentConfig.set(ctx, ref, "key", "new")

      assert {:ok, "new"} = ComponentConfig.get(ctx, ref, "key")
    end

    test "supports various value types", %{ctx: ctx} do
      name = "typed-comp-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "string", "hello")
      :ok = ComponentConfig.set(ctx, ref, "integer", 42)
      :ok = ComponentConfig.set(ctx, ref, "boolean_true", true)
      :ok = ComponentConfig.set(ctx, ref, "boolean_false", false)
      :ok = ComponentConfig.set(ctx, ref, "list", ["a", "b", "c"])

      assert {:ok, "hello"} = ComponentConfig.get(ctx, ref, "string")
      assert {:ok, 42} = ComponentConfig.get(ctx, ref, "integer")
      assert {:ok, true} = ComponentConfig.get(ctx, ref, "boolean_true")
      assert {:ok, false} = ComponentConfig.get(ctx, ref, "boolean_false")
      assert {:ok, ["a", "b", "c"]} = ComponentConfig.get(ctx, ref, "list")
    end

    test "set writes to SQLite, not filesystem", %{ctx: ctx, test_dir: test_dir} do
      name = "sqlite-verify-#{:rand.uniform(100_000)}"
      prefix = register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "api_version", "v2")

      # Verify no user.json was created on filesystem
      user_json_path = Path.join([test_dir | prefix] ++ ["user.json"])
      refute File.exists?(user_json_path)

      # Verify the value is in SQLite
      {:ok, config} = Arca.ComponentConfigStorage.get_all_config(ref)
      assert config["api_version"] == "v2"
    end
  end

  describe "get_all/2" do
    test "returns empty map for unregistered component", %{ctx: ctx} do
      assert {:ok, %{}} = ComponentConfig.get_all(ctx, "nonexistent:1.0.0")
    end

    test "returns all config for a component", %{ctx: ctx} do
      name = "multi-config-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "key1", "value1")
      :ok = ComponentConfig.set(ctx, ref, "key2", "value2")
      :ok = ComponentConfig.set(ctx, ref, "key3", 123)

      {:ok, config} = ComponentConfig.get_all(ctx, ref)

      assert config["key1"] == "value1"
      assert config["key2"] == "value2"
      assert config["key3"] == 123
    end
  end

  describe "set_all/3" do
    test "sets multiple values at once", %{ctx: ctx} do
      name = "batch-comp-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      values = %{
        "api_version" => "2023-10-16",
        "webhook_secret" => "whsec_test",
        "max_retries" => 3
      }

      assert :ok = ComponentConfig.set_all(ctx, ref, values)

      {:ok, config} = ComponentConfig.get_all(ctx, ref)
      assert config["api_version"] == "2023-10-16"
      assert config["webhook_secret"] == "whsec_test"
      assert config["max_retries"] == 3
    end

    test "merges with existing config", %{ctx: ctx} do
      name = "merge-comp-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "existing", "value")
      :ok = ComponentConfig.set_all(ctx, ref, %{"new" => "added"})

      {:ok, config} = ComponentConfig.get_all(ctx, ref)
      assert config["existing"] == "value"
      assert config["new"] == "added"
    end
  end

  describe "delete/3" do
    test "deletes a specific key", %{ctx: ctx} do
      name = "delete-test-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "keep", "value1")
      :ok = ComponentConfig.set(ctx, ref, "remove", "value2")

      assert :ok = ComponentConfig.delete(ctx, ref, "remove")

      assert {:ok, "value1"} = ComponentConfig.get(ctx, ref, "keep")
      assert {:error, :not_found} = ComponentConfig.get(ctx, ref, "remove")
    end

    test "succeeds even if key doesn't exist", %{ctx: ctx} do
      name = "del-nf-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      assert :ok = ComponentConfig.delete(ctx, ref, "nonexistent")
    end
  end

  describe "delete_all/2" do
    test "removes all user config for a component", %{ctx: ctx} do
      name = "del-all-#{:rand.uniform(100_000)}"
      register_component(name)
      ref = component_ref(name)

      :ok = ComponentConfig.set(ctx, ref, "key1", "value1")
      :ok = ComponentConfig.set(ctx, ref, "key2", "value2")

      assert :ok = ComponentConfig.delete_all(ctx, ref)
      assert {:ok, %{}} = ComponentConfig.get_all(ctx, ref)
    end

    test "succeeds for component without config", %{ctx: ctx} do
      assert :ok = ComponentConfig.delete_all(ctx, "no-config:1.0.0")
    end
  end

  describe "config.json defaults merge with SQLite overrides" do
    test "SQLite overrides take precedence over config.json defaults", %{ctx: ctx} do
      name = "merge-json-#{:rand.uniform(100_000)}"
      prefix = register_component(name)
      ref = component_ref(name)

      # Write config.json (developer defaults) via Arca storage
      defaults = %{"api_version" => "2023-01-01", "debug" => false}
      {:ok, _} = Arca.MCP.handle("storage", ctx, %{
        "action" => "write",
        "path" => prefix ++ ["config.json"],
        "content" => Base.encode64(Jason.encode!(defaults))
      })

      # Set user override via SQLite
      :ok = ComponentConfig.set(ctx, ref, "api_version", "2023-10-16")

      {:ok, config} = ComponentConfig.get_all(ctx, ref)
      # User override takes precedence
      assert config["api_version"] == "2023-10-16"
      # Developer default preserved
      assert config["debug"] == false
    end
  end

  describe "list_components/1" do
    test "returns a list of component names", %{ctx: ctx} do
      {:ok, refs} = ComponentConfig.list_components(ctx)
      assert is_list(refs)
    end

    test "returns list of component names", %{ctx: ctx} do
      names = for i <- 1..3 do
        name = "list-comp-#{i}-#{:rand.uniform(100_000)}"
        register_component(name)
        name
      end

      {:ok, refs} = ComponentConfig.list_components(ctx)

      for name <- names do
        assert name in refs
      end
    end
  end
end
