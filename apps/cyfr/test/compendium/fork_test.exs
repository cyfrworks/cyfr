# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ForkTest do
  use ExUnit.Case, async: false

  alias Compendium.Fork
  alias Sanctum.ComponentRef

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_fork_test_#{:rand.uniform(100_000)}")
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
  # Helpers — create a fake "published" component at a non-local namespace
  # ============================================================================

  defp create_source_component(type, publisher, name, version, opts \\ []) do
    files =
      if(Keyword.get(opts, :with_source, true),
        do: [
          {"src/Cargo.toml", "[package]\nname = \"test\""},
          {"src/src/lib.rs", "fn main() {}"}
        ],
        else: []
      ) ++
        if(Keyword.get(opts, :with_readme, false),
          do: [{"README.md", "# Test Component"}],
          else: []
        )

    Arca.Test.UnitFixtures.tenant_component!(
      Sanctum.TestContext.local(),
      type,
      publisher,
      name,
      version,
      manifest: %{
        "name" => name,
        "type" => type,
        "version" => version,
        "publisher" => publisher,
        "description" => "A test component"
      },
      wasm: if(Keyword.get(opts, :with_wasm, false), do: "fake-wasm-binary", else: false),
      files: files
    )
  end

  defp create_tincture_component(publisher, name, version, opts \\ []) do
    files =
      [
        {"index.html", "<html><body>Hello</body></html>"},
        {"app.js", "console.log('hello')"},
        {"style.css", "body { color: red; }"}
      ] ++
        if(Keyword.get(opts, :with_source, true),
          do: [{"src/main.js", "export default function() {}"}],
          else: []
        )

    base =
      Arca.Test.UnitFixtures.tenant_component!(
        Sanctum.TestContext.local(),
        "tincture",
        publisher,
        name,
        version,
        manifest: %{
          "name" => name,
          "type" => "tincture",
          "version" => version,
          "publisher" => publisher,
          "description" => "A test tincture",
          "tincture" => %{"entry" => "index.html"}
        },
        files: files
      )

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
    test "forks a catalyst to local namespace", %{ctx: ctx} do
      create_source_component("catalyst", "acme", "my-tool", "1.0.0",
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
      target_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "catalysts",
            "local",
            "my-tool",
            "1.0.0"
          ]
        )

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

    test "the stamped lineage is queryable end to end", %{ctx: ctx} do
      # The "written but never read" gap, closed: fork → register → the
      # row's manifest carries the stamp and the provenance surface
      # reports the upstream line.
      valid_wasm =
        <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

      # Pulled components carry rows; upstream_status reads what this
      # install KNOWS, so the upstream line must be registered. The
      # publish commits the unit wholesale, so the fixture's src/ tree is
      # laid AFTER it — as a pull's unit files would ride the commit.
      for version <- ["1.0.0", "1.1.0"] do
        {:ok, _} =
          Compendium.Registry.publish_bytes(ctx, valid_wasm, %{
            name: "lineage-tool",
            version: version,
            type: "reagent",
            publisher: "acme"
          })
      end

      create_source_component("reagent", "acme", "lineage-tool", "1.0.0", with_wasm: true)
      create_source_component("reagent", "acme", "lineage-tool", "1.1.0", with_wasm: true)

      source_ref = parse_ref!("r:acme.lineage-tool:1.0.0")
      assert {:ok, _} = Fork.fork(ctx, source_ref, name: "my-lineage")

      # The member rebuilds the fork; the fixture's source wasm is fake.
      target_dir = ["components", "reagents", "local", "my-lineage", "1.0.0"]
      :ok = Arca.put(ctx, target_dir ++ ["reagent.wasm"], valid_wasm)
      {:ok, row} = Compendium.Registry.register_from_arca(ctx, target_dir)

      assert %{
               forked_from: "reagent:acme.lineage-tool:1.0.0",
               upstream_superseded: true
             } = Compendium.Provenance.upstream_status(ctx, row)

      {:ok, [entry]} = Compendium.Provenance.annotate(ctx, [row])
      assert entry.provenance == :user
      assert entry.forked_from == "reagent:acme.lineage-tool:1.0.0"
      assert entry.upstream_superseded
    end
  end

  describe "fork happy path (tincture)" do
    test "forks a tincture to local namespace", %{ctx: ctx} do
      create_tincture_component("acme", "my-dash", "1.0.0")

      source_ref = parse_ref!("t:acme.my-dash:1.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref)

      assert result.status == "forked"
      assert result.reference == "tincture:local.my-dash:1.0.0"

      target_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "tinctures",
            "local",
            "my-dash",
            "1.0.0"
          ]
        )

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
    test "errors when component has no src/ directory", %{ctx: ctx} do
      create_source_component("catalyst", "acme", "no-src", "1.0.0", with_source: false)

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
    test "errors when target component already exists", %{ctx: ctx} do
      create_source_component("catalyst", "acme", "my-tool", "1.0.0")
      # Create the target too
      create_source_component("catalyst", "local", "my-tool", "1.0.0")

      source_ref = parse_ref!("c:acme.my-tool:1.0.0")
      assert {:error, msg} = Fork.fork(ctx, source_ref)
      assert msg =~ "already exists"
    end
  end

  # ============================================================================
  # Custom Name / Version
  # ============================================================================

  describe "custom name" do
    test "forks with a different name", %{ctx: ctx} do
      create_source_component("reagent", "acme", "original", "1.0.0")

      source_ref = parse_ref!("r:acme.original:1.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref, name: "my-fork")

      assert result.reference == "reagent:local.my-fork:1.0.0"
      assert result.forked_from == "reagent:acme.original:1.0.0"

      target_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "reagents",
            "local",
            "my-fork",
            "1.0.0"
          ]
        )

      {:ok, manifest_json} = File.read(Path.join(target_base, "cyfr-manifest.json"))
      {:ok, manifest} = Jason.decode(manifest_json)
      assert manifest["name"] == "my-fork"
      assert manifest["publisher"] == "local"
    end
  end

  describe "custom version" do
    test "forks with a different version", %{ctx: ctx} do
      create_source_component("formula", "acme", "my-flow", "2.0.0")

      source_ref = parse_ref!("f:acme.my-flow:2.0.0")
      assert {:ok, result} = Fork.fork(ctx, source_ref, version: "0.1.0")

      assert result.reference == "formula:local.my-flow:0.1.0"

      target_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "formulas",
            "local",
            "my-flow",
            "0.1.0"
          ]
        )

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
    test "copies data.db when forking a tincture", %{ctx: ctx} do
      create_tincture_component("acme", "db-dash", "1.0.0", with_data_db: true)

      source_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "tinctures",
            "acme",
            "db-dash",
            "1.0.0"
          ]
        )

      assert File.exists?(Path.join(source_base, "data.db"))

      source_ref = parse_ref!("t:acme.db-dash:1.0.0")
      assert {:ok, _result} = Fork.fork(ctx, source_ref)

      target_base =
        Arca.Adapters.Local.build_path(
          Sanctum.TestContext.local(),
          [
            "components",
            "tinctures",
            "local",
            "db-dash",
            "1.0.0"
          ]
        )

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
