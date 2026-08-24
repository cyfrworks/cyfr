# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ScaffoldTest do
  use ExUnit.Case, async: false

  alias Compendium.Scaffold

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_scaffold_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx}
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
    test "creates all expected files", %{ctx: ctx} do
      assert {:ok, result} = Scaffold.create(ctx, "weather-api", "catalyst", "0.1.0")
      assert result.status == "created"
      assert result.reference == "catalyst:local.weather-api:0.1.0"
      assert is_list(result.files)
      assert is_list(result.next_steps)

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "catalysts", "local", "weather-api", "0.1.0"]
        )

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
      assert is_map(manifest["caps"]["egress"])
      refute Map.has_key?(manifest, "setup")
      refute Map.has_key?(manifest, "wasi")

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
    test "creates all expected files", %{ctx: ctx} do
      assert {:ok, result} = Scaffold.create(ctx, "my-workflow", "formula", "0.1.0")
      assert result.reference == "formula:local.my-workflow:0.1.0"

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "formulas", "local", "my-workflow", "0.1.0"]
        )

      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join([base, "src", "src", "lib.rs"]))

      # Verify manifest has formula-specific fields
      {:ok, manifest_json} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["type"] == "formula"
      assert is_list(manifest["caps"]["tools"])
      assert is_map(manifest["dependencies"])

      # Verify lib.rs contains formula pattern
      {:ok, lib_rs} = File.read(Path.join([base, "src", "src", "lib.rs"]))
      assert lib_rs =~ "cyfr::formula::run::Guest"
      assert lib_rs =~ "invoke"
    end
  end

  describe "scaffold for reagent" do
    test "creates all expected files", %{ctx: ctx} do
      assert {:ok, result} = Scaffold.create(ctx, "my-transform", "reagent", "0.1.0")
      assert result.reference == "reagent:local.my-transform:0.1.0"

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "reagents", "local", "my-transform", "0.1.0"]
        )

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

  # ============================================================================
  # React Tincture Scaffold
  # ============================================================================

  describe "scaffold for tincture with react template" do
    test "creates React project files", %{ctx: ctx} do
      assert {:ok, result} =
               Scaffold.create(ctx, "test-dash", "tincture", "0.1.0", template: "react")

      assert result.status == "created"
      assert result.reference == "tincture:local.test-dash:0.1.0"

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "tinctures", "local", "test-dash", "0.1.0"]
        )

      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join(base, "package.json"))
      assert File.exists?(Path.join(base, "tsconfig.json"))
      assert File.exists?(Path.join(base, "vite.config.ts"))
      assert File.exists?(Path.join(base, "index.html"))
      assert File.exists?(Path.join([base, "src", "main.tsx"]))
      assert File.exists?(Path.join([base, "src", "App.tsx"]))
      assert File.exists?(Path.join([base, "src", "index.css"]))

      # No vanilla files
      refute File.exists?(Path.join(base, "app.js"))
      refute File.exists?(Path.join(base, "style.css"))
    end

    test "react manifest includes build field", %{ctx: ctx} do
      assert {:ok, _} =
               Scaffold.create(ctx, "build-dash", "tincture", "0.1.0", template: "react")

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "tinctures", "local", "build-dash", "0.1.0"]
        )

      {:ok, raw} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(raw)

      assert manifest["type"] == "tincture"
      assert get_in(manifest, ["tincture", "build", "tool"]) == "vite"
      assert get_in(manifest, ["tincture", "entry"]) == "index.html"
    end

    test "package.json has correct dependencies", %{ctx: ctx} do
      assert {:ok, _} =
               Scaffold.create(ctx, "pkg-dash", "tincture", "0.1.0", template: "react")

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "tinctures", "local", "pkg-dash", "0.1.0"]
        )

      {:ok, raw} = File.read(Path.join(base, "package.json"))
      {:ok, pkg} = Jason.decode(raw)

      assert Map.has_key?(pkg["dependencies"], "react")
      assert Map.has_key?(pkg["dependencies"], "react-dom")
      assert Map.has_key?(pkg["devDependencies"], "vite")
      assert Map.has_key?(pkg["devDependencies"], "typescript")
      assert pkg["scripts"]["build"] =~ "tsc"
    end

    test "vite config uses relative base path", %{ctx: ctx} do
      assert {:ok, _} =
               Scaffold.create(ctx, "vite-dash", "tincture", "0.1.0", template: "react")

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "tinctures", "local", "vite-dash", "0.1.0"]
        )

      {:ok, config} = File.read(Path.join(base, "vite.config.ts"))
      assert config =~ ~s(base: "./")
    end

    test "next steps reference build.compile", %{ctx: ctx} do
      assert {:ok, result} =
               Scaffold.create(ctx, "steps-dash", "tincture", "0.1.0", template: "react")

      assert Enum.any?(result.next_steps, &(&1 =~ "build.compile"))
      assert Enum.any?(result.next_steps, &(&1 =~ "src/App.tsx"))
    end
  end

  describe "scaffold for vanilla tincture (no template)" do
    test "unchanged - creates vanilla files", %{ctx: ctx} do
      assert {:ok, result} = Scaffold.create(ctx, "vanilla", "tincture", "0.1.0")
      assert result.status == "created"

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_test", "tinctures", "local", "vanilla", "0.1.0"]
        )

      assert File.exists?(Path.join(base, "app.js"))
      assert File.exists?(Path.join(base, "style.css"))
      assert File.exists?(Path.join(base, "index.html"))

      # No React files
      refute File.exists?(Path.join(base, "package.json"))
      refute File.exists?(Path.join(base, "tsconfig.json"))
      refute File.exists?(Path.join(base, "vite.config.ts"))

      # Manifest has no build field
      {:ok, raw} = File.read(Path.join(base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(raw)
      refute Map.has_key?(manifest["tincture"] || %{}, "build")
    end
  end

  describe "athanor-scoped scaffold" do
    test "creates scaffold under the context's athanor", %{ctx: ctx} do
      ctx_other = %{ctx | athanor_id: "ath_scaffold"}

      assert {:ok, result} = Scaffold.create(ctx_other, "other-tool", "catalyst", "0.1.0")
      assert result.status == "created"

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "ath_scaffold", "catalysts", "local", "other-tool", "0.1.0"]
        )

      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
      assert File.exists?(Path.join([base, "src", "Cargo.toml"]))
    end

    test "the test context scaffolds under its own athanor", %{ctx: ctx} do
      assert ctx.athanor_id == Sanctum.TestContext.athanor_id()

      assert {:ok, _} = Scaffold.create(ctx, "flat-tool", "reagent", "0.1.0")

      base =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", ctx.athanor_id, "reagents", "local", "flat-tool", "0.1.0"]
        )

      assert File.exists?(Path.join(base, "cyfr-manifest.json"))
    end

    test "detects duplicate within an athanor", %{ctx: ctx} do
      ctx_other = %{ctx | athanor_id: "ath_dup"}

      assert {:ok, _} = Scaffold.create(ctx_other, "dup-check", "catalyst", "0.1.0")
      assert {:error, msg} = Scaffold.create(ctx_other, "dup-check", "catalyst", "0.1.0")
      assert msg =~ "already exists"
    end
  end

  describe "cargo_toml_for/2 (canonical template, delegated to by Locus.Builder)" do
    test "reagent/formula templates are identical regardless of the oauth option" do
      for type <- [:reagent, :formula] do
        assert Scaffold.cargo_toml_for(type) ==
                 Scaffold.cargo_toml_for(type, include_oauth_wit: false)
      end
    end

    test "catalyst variants differ ONLY by the cyfr:oauth WIT dep line" do
      oauth_line = ~s("cyfr:oauth" = { path = "wit/deps/cyfr-oauth" }\n)

      with_oauth = Scaffold.cargo_toml_for(:catalyst)
      without_oauth = Scaffold.cargo_toml_for(:catalyst, include_oauth_wit: false)

      assert with_oauth =~ oauth_line
      refute without_oauth =~ "cyfr:oauth"
      assert String.replace(with_oauth, oauth_line, "") == without_oauth
    end
  end
end
