# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AutoIndexerTest do
  use ExUnit.Case, async: false

  alias Compendium.AutoIndexer
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

    test_dir = Path.join(System.tmp_dir!(), "cyfr_autoindexer_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, ctx: ctx}
  end

  defp create_component(type, publisher, name, version, opts \\ []) do
    athanor = Keyword.get(opts, :athanor, Sanctum.TestContext.athanor_id())
    fixture_ctx = Sanctum.Context.build(user_id: "fixture", athanor_id: athanor, authenticated: true)

    dir =
      Arca.Adapters.Local.build_path(
        fixture_ctx,
        ["components", "#{type}s", publisher, name, version]
      )

    File.mkdir_p!(dir)

    manifest = %{
      "type" => type,
      "version" => version,
      "description" => Keyword.get(opts, :description, "Test #{name}")
    }

    manifest =
      if tags = Keyword.get(opts, :tags) do
        Map.put(manifest, "tags", tags)
      else
        manifest
      end

    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "#{type}.wasm"), @valid_wasm)

    dir
  end

  describe "scan/1" do
    test "discovers and registers local components", %{ctx: ctx} do
      create_component("catalyst", "local", "openai", "0.1.0")
      create_component("reagent", "local", "json-tool", "1.0.0")

      result = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 2
      assert result.errors == 0

      {:ok, search} = Registry.search(ctx, %{query: "openai"})
      assert search.total == 1
      assert hd(search.components).name == "openai"

      {:ok, search2} = Registry.search(ctx, %{query: "json-tool"})
      assert search2.total == 1
    end

    test "ignores non-local publisher directories", %{ctx: ctx} do
      create_component("catalyst", "stripe", "payment", "1.0.0")
      create_component("catalyst", "cyfr", "internal", "1.0.0")

      result = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 0

      {:ok, search} = Registry.search(ctx, %{query: "payment"})
      assert search.total == 0
    end

    test "skips unchanged components on rescan", %{ctx: ctx} do
      create_component("reagent", "local", "stable-tool", "1.0.0")

      result1 = AutoIndexer.scan(ctx: ctx)
      assert result1.registered == 1

      result2 = AutoIndexer.scan(ctx: ctx)
      assert result2.unchanged == 1
      assert result2.registered == 0
    end

    test "prunes stale entries", %{ctx: ctx} do
      dir = create_component("reagent", "local", "temp-tool", "0.1.0")

      result1 = AutoIndexer.scan(ctx: ctx)
      assert result1.registered == 1

      {:ok, search} = Registry.search(ctx, %{query: "temp-tool"})
      assert search.total == 1

      # Delete the component directory
      File.rm_rf!(dir)

      # Rescan should prune the stale entry
      result2 = AutoIndexer.scan(ctx: ctx)
      assert result2.pruned == 1

      {:ok, search2} = Registry.search(ctx, %{query: "temp-tool"})
      assert search2.total == 0
    end

    test "handles missing component directories gracefully", %{ctx: ctx} do
      # Point the storage root at a directory that doesn't exist.
      Application.put_env(:cyfr, :base_path, "/nonexistent/scan/path")

      result = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 0
      assert result.errors == 0
      assert [%{via: "Arca.list_recursive"}] = result.scanned_dirs
    end

    test "includes scanned_dirs in result", %{ctx: ctx} do
      create_component("catalyst", "local", "test-tool", "0.1.0")

      result = AutoIndexer.scan(ctx: ctx)

      # scanned_dirs records the athanor's Arca prefix, not raw filesystem paths.
      expected_path = "components/#{ctx.athanor_id}/"
      assert [%{path: ^expected_path, via: "Arca.list_recursive"}] = result.scanned_dirs
    end

    test "scans multiple component types", %{ctx: ctx} do
      create_component("catalyst", "local", "api-tool", "0.1.0")
      create_component("reagent", "local", "data-tool", "0.1.0")
      create_component("formula", "local", "workflow", "0.1.0")

      result = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 3
      assert result.total == 3
    end

    test "discovers the components of the context's own athanor", %{ctx: ctx} do
      ctx_other = %{ctx | athanor_id: "ath_other"}
      create_component("catalyst", "local", "other-tool", "0.1.0", athanor: "ath_other")

      result = AutoIndexer.scan(ctx: ctx_other)

      assert result.registered == 1
      assert result.total == 1
    end

    test "never sees another athanor's tree", %{ctx: ctx} do
      create_component("catalyst", "local", "other-only", "0.1.0", athanor: "ath_other")

      result = AutoIndexer.scan(ctx: ctx)
      assert result.registered == 0
      assert result.total == 0
    end

    test "never indexes the seed bundle", %{ctx: ctx, test_dir: test_dir} do
      # A seed fixture of this test's own — never the suite-shared seed tree.
      prev_seed = Application.get_env(:cyfr, :seed_path)
      Application.put_env(:cyfr, :seed_path, Path.join(test_dir, "seed_fixture"))
      on_exit(fn -> Application.put_env(:cyfr, :seed_path, prev_seed) end)

      create_component("catalyst", "local", "bundled", "0.1.0", athanor: "_bundle")

      result = AutoIndexer.scan(ctx: ctx)
      assert result.registered == 0
      assert result.total == 0
    end
  end
end
