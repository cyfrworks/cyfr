defmodule Compendium.ForkTest do
  use ExUnit.Case, async: false

  alias Compendium.Fork
  alias Sanctum.{ComponentRef, Context}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_fork_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :components_path, Path.join(test_dir, "components"))

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, ctx: ctx, test_dir: test_dir}
  end

  # ============================================================================
  # Helpers — create a fake "published" component at a non-local namespace
  # ============================================================================

  defp create_source_component(test_dir, type, publisher, name, version, opts \\ []) do
    base = Path.join([test_dir, "components", "#{type}s", publisher, name, version])

    manifest = %{
      "name" => name,
      "type" => type,
      "version" => version,
      "publisher" => publisher,
      "description" => "A test component"
    }

    File.mkdir_p!(base)
    File.write!(Path.join(base, "cyfr-manifest.json"), Jason.encode!(manifest, pretty: true))

    if Keyword.get(opts, :with_source, true) do
      src_dir = Path.join(base, "src")
      File.mkdir_p!(Path.join(src_dir, "src"))
      File.write!(Path.join([src_dir, "Cargo.toml"]), "[package]\nname = \"test\"")
      File.write!(Path.join([src_dir, "src", "lib.rs"]), "fn main() {}")
    end

    if Keyword.get(opts, :with_wasm, false) do
      File.write!(Path.join(base, "#{type}.wasm"), "fake-wasm-binary")
    end

    if Keyword.get(opts, :with_readme, false) do
      File.write!(Path.join(base, "README.md"), "# Test Component")
    end

    base
  end

  defp create_tincture_component(test_dir, publisher, name, version, opts \\ []) do
    base = Path.join([test_dir, "components", "tinctures", publisher, name, version])

    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => version,
      "publisher" => publisher,
      "description" => "A test tincture",
      "tincture" => %{"entry" => "index.html"}
    }

    File.mkdir_p!(base)
    File.write!(Path.join(base, "cyfr-manifest.json"), Jason.encode!(manifest, pretty: true))
    File.write!(Path.join(base, "index.html"), "<html><body>Hello</body></html>")
    File.write!(Path.join(base, "app.js"), "console.log('hello')")
    File.write!(Path.join(base, "style.css"), "body { color: red; }")

    if Keyword.get(opts, :with_source, true) do
      src_dir = Path.join(base, "src")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "main.js"), "export default function() {}")
    end

    if Keyword.get(opts, :with_data_db, false) do
      File.write!(Path.join(base, "data.db"), "fake-sqlite-db")
    end

    base
  end

  defp parse_ref!(ref_str) do
    {:ok, cref} = ComponentRef.parse(ref_str)
    cref
  end

  # ============================================================================
  # Happy Path
  # ============================================================================

  describe "fork happy path (WASM)" do
    test "forks a catalyst to local namespace", %{ctx: ctx, test_dir: test_dir} do
      create_source_component(test_dir, "catalyst", "acme", "my-tool", "1.0.0",
        with_wasm: true,
        with_readme: true
      )

      source_ref = parse_ref!("c:acme.my-tool:1.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref)

      assert result.status == "forked"
      assert result.reference == "catalyst:local.my-tool:1.0.0"
      assert result.forked_from == "catalyst:acme.my-tool:1.0.0"
      assert is_list(result.files)
      assert is_list(result.next_steps)

      # Verify files at target path
      target_base = Path.join([test_dir, "components", "catalysts", "local", "my-tool", "1.0.0"])
      assert File.exists?(Path.join(target_base, "cyfr-manifest.json"))
      assert File.exists?(Path.join(target_base, "catalyst.wasm"))
      assert File.exists?(Path.join(target_base, "README.md"))
      assert File.exists?(Path.join([target_base, "src", "Cargo.toml"]))
      assert File.exists?(Path.join([target_base, "src", "src", "lib.rs"]))

      # Verify manifest was rewritten
      {:ok, manifest_json} = File.read(Path.join(target_base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["publisher"] == "local"
      assert manifest["name"] == "my-tool"
      assert manifest["version"] == "1.0.0"
      assert manifest["forked_from"] == "catalyst:acme.my-tool:1.0.0"
    end
  end

  describe "fork happy path (tincture)" do
    test "forks a tincture to local namespace", %{ctx: ctx, test_dir: test_dir} do
      create_tincture_component(test_dir, "acme", "my-dash", "1.0.0")

      source_ref = parse_ref!("t:acme.my-dash:1.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref)

      assert result.status == "forked"
      assert result.reference == "tincture:local.my-dash:1.0.0"

      target_base = Path.join([test_dir, "components", "tinctures", "local", "my-dash", "1.0.0"])
      assert File.exists?(Path.join(target_base, "index.html"))
      assert File.exists?(Path.join(target_base, "app.js"))
      assert File.exists?(Path.join(target_base, "style.css"))
      assert File.exists?(Path.join([target_base, "src", "main.js"]))
    end
  end

  # ============================================================================
  # Error Cases
  # ============================================================================

  describe "no source error" do
    test "errors when component has no src/ directory", %{ctx: ctx, test_dir: test_dir} do
      create_source_component(test_dir, "catalyst", "acme", "no-src", "1.0.0", with_source: false)

      source_ref = parse_ref!("c:acme.no-src:1.0.0")
      assert {:error, msg} = Fork.fork(ctx, source_ref)
      assert msg =~ "No source code available"
      assert msg =~ "acme.no-src"
    end
  end

  describe "component not found" do
    test "errors when component is not pulled locally", %{ctx: ctx} do
      source_ref = parse_ref!("c:acme.nonexistent:1.0.0")
      assert {:error, msg} = Fork.fork(ctx, source_ref)
      assert msg =~ "not found locally"
      assert msg =~ "Pull it first"
    end
  end

  describe "target already exists" do
    test "errors when target component already exists", %{ctx: ctx, test_dir: test_dir} do
      create_source_component(test_dir, "catalyst", "acme", "my-tool", "1.0.0")
      # Create the target too
      create_source_component(test_dir, "catalyst", "local", "my-tool", "1.0.0")

      source_ref = parse_ref!("c:acme.my-tool:1.0.0")
      assert {:error, msg} = Fork.fork(ctx, source_ref)
      assert msg =~ "already exists"
    end
  end

  # ============================================================================
  # Custom Name / Version
  # ============================================================================

  describe "custom name" do
    test "forks with a different name", %{ctx: ctx, test_dir: test_dir} do
      create_source_component(test_dir, "reagent", "acme", "original", "1.0.0")

      source_ref = parse_ref!("r:acme.original:1.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref, name: "my-fork")

      assert result.reference == "reagent:local.my-fork:1.0.0"
      assert result.forked_from == "reagent:acme.original:1.0.0"

      target_base = Path.join([test_dir, "components", "reagents", "local", "my-fork", "1.0.0"])
      {:ok, manifest_json} = File.read(Path.join(target_base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["name"] == "my-fork"
      assert manifest["publisher"] == "local"
    end
  end

  describe "custom version" do
    test "forks with a different version", %{ctx: ctx, test_dir: test_dir} do
      create_source_component(test_dir, "formula", "acme", "my-flow", "2.0.0")

      source_ref = parse_ref!("f:acme.my-flow:2.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref, version: "0.1.0")

      assert result.reference == "formula:local.my-flow:0.1.0"

      target_base = Path.join([test_dir, "components", "formulas", "local", "my-flow", "0.1.0"])
      {:ok, manifest_json} = File.read(Path.join(target_base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["version"] == "0.1.0"
    end
  end

  # ============================================================================
  # data.db included (cyfr no longer manages tincture state — data.db is a
  # regular shipped asset, copied alongside index.html and the manifest)
  # ============================================================================

  describe "data.db included" do
    test "copies data.db when forking a tincture", %{ctx: ctx, test_dir: test_dir} do
      create_tincture_component(test_dir, "acme", "db-dash", "1.0.0", with_data_db: true)

      source_base = Path.join([test_dir, "components", "tinctures", "acme", "db-dash", "1.0.0"])
      assert File.exists?(Path.join(source_base, "data.db"))

      source_ref = parse_ref!("t:acme.db-dash:1.0.0")
      assert {:ok, _result} = Fork.fork(ctx, source_ref)

      target_base = Path.join([test_dir, "components", "tinctures", "local", "db-dash", "1.0.0"])
      assert File.exists?(Path.join(target_base, "data.db"))
      assert File.exists?(Path.join(target_base, "index.html"))
      assert File.exists?(Path.join(target_base, "cyfr-manifest.json"))
    end
  end

  # ============================================================================
  # MCP Handler Guards (tested via Fork module directly since they're in MCP)
  # These test the ComponentRef.parse guards that the MCP handler applies
  # ============================================================================

  describe "version required (guard at Fork level)" do
    test "fork validates version is present" do
      # ComponentRef with nil version would be caught by MCP handler,
      # but Fork.fork also validates via ComponentRef.validate_version
      cref = %ComponentRef{type: "catalyst", namespace: "acme", name: "tool", version: nil}
      ctx = Sanctum.TestContext.local()
      assert {:error, msg} = Fork.fork(ctx, cref)
      assert msg =~ "version"
    end
  end
end
