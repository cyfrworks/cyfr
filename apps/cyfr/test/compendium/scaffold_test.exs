defmodule Compendium.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Compendium.Scaffold
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_scaffold_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx, test_dir: test_dir}
  end

  # ============================================================================
  # Validation
  # ============================================================================

  describe "name validation" do
    test "rejects invalid names", %{ctx: ctx} do
      assert {:error, msg} = Scaffold.create(ctx, "My-Api", "catalyst", "0.1.0")
      assert msg =~ "Invalid component name"

      assert {:error, msg} = Scaffold.create(ctx, "-bad", "catalyst", "0.1.0")
      assert msg =~ "Invalid component name"

      assert {:error, msg} = Scaffold.create(ctx, "bad-", "catalyst", "0.1.0")
      assert msg =~ "Invalid component name"

      assert {:error, msg} = Scaffold.create(ctx, "has space", "catalyst", "0.1.0")
      assert msg =~ "Invalid component name"

      assert {:error, msg} = Scaffold.create(ctx, nil, "catalyst", "0.1.0")
      assert msg =~ "name"
    end

    test "accepts valid names", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "my-api", "catalyst", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "a", "reagent", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "my-api-v2", "formula", "0.1.0")
    end
  end

  describe "type validation" do
    test "rejects invalid types", %{ctx: ctx} do
      assert {:error, msg} = Scaffold.create(ctx, "test", "plugin", "0.1.0")
      assert msg =~ "Invalid component type"

      assert {:error, msg} = Scaffold.create(ctx, "test", nil, "0.1.0")
      assert msg =~ "type"
    end

    test "accepts valid types", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "test-r", "reagent", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "test-c", "catalyst", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "test-f", "formula", "0.1.0")
    end
  end

  describe "version validation" do
    test "rejects invalid versions", %{ctx: ctx} do
      assert {:error, msg} = Scaffold.create(ctx, "test", "reagent", "not-a-version")
      assert msg =~ "Invalid version"

      assert {:error, msg} = Scaffold.create(ctx, "test", "reagent", nil)
      assert msg =~ "version"
    end

    test "accepts valid semver", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "test", "reagent", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "test2", "reagent", "1.2.3")
    end
  end

  # ============================================================================
  # Duplicate Prevention
  # ============================================================================

  describe "duplicate prevention" do
    test "rejects scaffold when component already exists", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "existing", "catalyst", "0.1.0")
      assert {:error, msg} = Scaffold.create(ctx, "existing", "catalyst", "0.1.0")
      assert msg =~ "already exists"
    end

    test "allows same name with different version", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "my-comp", "catalyst", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "my-comp", "catalyst", "0.2.0")
    end

    test "allows same name with different type", %{ctx: ctx} do
      assert {:ok, _} = Scaffold.create(ctx, "my-comp2", "catalyst", "0.1.0")
      assert {:ok, _} = Scaffold.create(ctx, "my-comp2", "reagent", "0.1.0")
    end
  end

  # ============================================================================
  # Scaffold Output
  # ============================================================================

  describe "scaffold for catalyst" do
    test "creates all expected files", %{ctx: ctx, test_dir: test_dir} do
      assert {:ok, result} = Scaffold.create(ctx, "weather-api", "catalyst", "0.1.0")
      assert result.status == "created"
      assert result.reference == "catalyst:local.weather-api:0.1.0"
      assert is_list(result.files)
      assert is_list(result.next_steps)

      base = Path.join([test_dir, "components", "catalysts", "local", "weather-api", "0.1.0"])
      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join([base, "src", "Cargo.toml"]))
      assert File.exists?(Path.join([base, "src", "src", "lib.rs"]))
      assert File.exists?(Path.join([base, "src", "wit", "world.wit"]))

      # Verify manifest content
      {:ok, manifest_json} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["name"] == "weather-api"
      assert manifest["type"] == "catalyst"
      assert manifest["version"] == "0.1.0"
      assert manifest["publisher"] == "local"
      assert is_map(manifest["setup"]["policy"])

      # Verify lib.rs contains catalyst pattern
      {:ok, lib_rs} = File.read(Path.join([base, "src", "src", "lib.rs"]))
      assert lib_rs =~ "cyfr::catalyst::run::Guest"
      assert lib_rs =~ "fn run"

      # Verify Cargo.toml is for catalyst
      {:ok, cargo} = File.read(Path.join([base, "src", "Cargo.toml"]))
      assert cargo =~ "cyfr:catalyst"
    end
  end

  describe "scaffold for formula" do
    test "creates all expected files", %{ctx: ctx, test_dir: test_dir} do
      assert {:ok, result} = Scaffold.create(ctx, "my-workflow", "formula", "0.1.0")
      assert result.reference == "formula:local.my-workflow:0.1.0"

      base = Path.join([test_dir, "components", "formulas", "local", "my-workflow", "0.1.0"])
      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join([base, "src", "src", "lib.rs"]))

      # Verify manifest has formula-specific fields
      {:ok, manifest_json} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["type"] == "formula"
      assert is_list(manifest["setup"]["policy"]["allowed_tools"])
      assert is_map(manifest["dependencies"])

      # Verify lib.rs contains formula pattern
      {:ok, lib_rs} = File.read(Path.join([base, "src", "src", "lib.rs"]))
      assert lib_rs =~ "cyfr::formula::run::Guest"
      assert lib_rs =~ "invoke"
    end
  end

  describe "scaffold for reagent" do
    test "creates all expected files", %{ctx: ctx, test_dir: test_dir} do
      assert {:ok, result} = Scaffold.create(ctx, "my-transform", "reagent", "0.1.0")
      assert result.reference == "reagent:local.my-transform:0.1.0"

      base = Path.join([test_dir, "components", "reagents", "local", "my-transform", "0.1.0"])
      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join([base, "src", "src", "lib.rs"]))

      # Verify manifest is minimal for reagent
      {:ok, manifest_json} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["type"] == "reagent"
      refute Map.has_key?(manifest, "setup")

      # Verify lib.rs contains reagent pattern
      {:ok, lib_rs} = File.read(Path.join([base, "src", "src", "lib.rs"]))
      assert lib_rs =~ "cyfr::reagent::compute::Guest"
      assert lib_rs =~ "fn compute"
    end
  end
end
