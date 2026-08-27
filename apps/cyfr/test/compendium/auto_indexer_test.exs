# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AutoIndexerTest.OutageAdapter do
  @moduledoc false
  # Every listing fails — a storage outage. Everything else delegates.
  @behaviour Arca.Storage

  defdelegate get(ctx, path), to: Arca.Adapters.Local
  defdelegate put(ctx, path, content), to: Arca.Adapters.Local
  defdelegate append(ctx, path, content), to: Arca.Adapters.Local
  defdelegate delete(ctx, path), to: Arca.Adapters.Local
  defdelegate list_typed(ctx, path), to: Arca.Adapters.Local
  defdelegate exists?(ctx, path), to: Arca.Adapters.Local
  defdelegate delete_tree(ctx, path), to: Arca.Adapters.Local
  defdelegate usage(ctx, path), to: Arca.Adapters.Local
  defdelegate serve_to_conn(conn, ctx, path, opts), to: Arca.Adapters.Local

  def list_recursive(_ctx, _path), do: {:error, :injected_outage}
end

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

    fixture_ctx =
      Sanctum.Context.build(user_id: "fixture", athanor_id: athanor, authenticated: true)

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

  describe "discover/1" do
    test "answers manifest-bearing local version dirs only — the build plane's roster", %{
      ctx: ctx
    } do
      create_component("reagent", "local", "with-manifest", "1.0.0")
      create_component("reagent", "acme", "foreign", "1.0.0")

      # A version dir without a manifest was never buildable — a scaffold
      # always writes one — so it is not on the roster.
      bare =
        Arca.Adapters.Local.build_path(
          ctx,
          ["components", "reagents", "local", "manifest-less", "1.0.0"]
        )

      File.mkdir_p!(bare)
      File.write!(Path.join(bare, "reagent.wasm"), @valid_wasm)

      {:ok, discovered} = Compendium.AutoIndexer.discover(ctx)

      assert ["components", "reagents", "local", "with-manifest", "1.0.0"] in discovered
      refute Enum.any?(discovered, fn segs -> "foreign" in segs end)
      refute Enum.any?(discovered, fn segs -> "manifest-less" in segs end)
    end
  end

  describe "scan/1" do
    test "discovers and registers local components", %{ctx: ctx} do
      create_component("catalyst", "local", "openai", "0.1.0")
      create_component("reagent", "local", "json-tool", "1.0.0")

      {:ok, result} = AutoIndexer.scan(ctx: ctx)

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

      {:ok, result} = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 0

      {:ok, search} = Registry.search(ctx, %{query: "payment"})
      assert search.total == 0
    end

    test "skips unchanged components on rescan", %{ctx: ctx} do
      create_component("reagent", "local", "stable-tool", "1.0.0")

      {:ok, result1} = AutoIndexer.scan(ctx: ctx)
      assert result1.registered == 1

      {:ok, result2} = AutoIndexer.scan(ctx: ctx)
      assert result2.unchanged == 1
      assert result2.registered == 0
    end

    test "prunes stale entries", %{ctx: ctx} do
      dir = create_component("reagent", "local", "temp-tool", "0.1.0")

      {:ok, result1} = AutoIndexer.scan(ctx: ctx)
      assert result1.registered == 1

      {:ok, search} = Registry.search(ctx, %{query: "temp-tool"})
      assert search.total == 1

      # Delete the component directory
      File.rm_rf!(dir)

      # Rescan should prune the stale entry
      {:ok, result2} = AutoIndexer.scan(ctx: ctx)
      assert result2.pruned == 1

      {:ok, search2} = Registry.search(ctx, %{query: "temp-tool"})
      assert search2.total == 0
    end

    test "handles missing component directories gracefully", %{ctx: ctx} do
      # Point the storage root at a directory that doesn't exist.
      Application.put_env(:cyfr, :base_path, "/nonexistent/scan/path")

      {:ok, result} = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 0
      assert result.errors == 0
      assert [%{via: "Arca.list_recursive"}] = result.scanned_dirs
    end

    test "includes scanned_dirs in result", %{ctx: ctx} do
      create_component("catalyst", "local", "test-tool", "0.1.0")

      {:ok, result} = AutoIndexer.scan(ctx: ctx)

      # scanned_dirs speaks the logical vocabulary: tenant-relative, no
      # athanor in the path (the context carries it).
      assert [%{path: "components/", via: "Arca.list_recursive"}] = result.scanned_dirs
    end

    test "scans multiple component types", %{ctx: ctx} do
      create_component("catalyst", "local", "api-tool", "0.1.0")
      create_component("reagent", "local", "data-tool", "0.1.0")
      create_component("formula", "local", "workflow", "0.1.0")

      {:ok, result} = AutoIndexer.scan(ctx: ctx)

      assert result.registered == 3
      assert result.total == 3
    end

    test "discovers the components of the context's own athanor", %{ctx: ctx} do
      ctx_other = %{ctx | athanor_id: "ath_other"}
      create_component("catalyst", "local", "other-tool", "0.1.0", athanor: "ath_other")

      {:ok, result} = AutoIndexer.scan(ctx: ctx_other)

      assert result.registered == 1
      assert result.total == 1
    end

    test "never sees another athanor's tree", %{ctx: ctx} do
      create_component("catalyst", "local", "other-only", "0.1.0", athanor: "ath_other")

      {:ok, result} = AutoIndexer.scan(ctx: ctx)
      assert result.registered == 0
      assert result.total == 0
    end

    test "indexes the seed bundle through the overlay union, and prune keeps its rows", %{
      ctx: ctx,
      test_dir: test_dir
    } do
      # A seed fixture of this test's own — never the suite-shared seed tree.
      prev_seed = Application.get_env(:cyfr, :seed_path)
      seed_dir = Path.join(test_dir, "seed_fixture")
      Application.put_env(:cyfr, :seed_path, seed_dir)
      on_exit(fn -> Application.put_env(:cyfr, :seed_path, prev_seed) end)

      bundle_dir = Path.join([seed_dir, "components", "catalysts", "local", "bundled", "0.1.0"])
      File.mkdir_p!(bundle_dir)

      File.write!(
        Path.join(bundle_dir, "cyfr-manifest.json"),
        Jason.encode!(%{"type" => "catalyst", "version" => "0.1.0", "description" => "Bundled"})
      )

      File.write!(Path.join(bundle_dir, "catalyst.wasm"), @valid_wasm)

      # No bytes in the athanor's tree — the walk sees the bundle through
      # the union and mints its row anyway.
      {:ok, result} = AutoIndexer.scan(ctx: ctx)
      assert result.registered == 1

      assert {:ok, %{name: "bundled"}} =
               Arca.ComponentStorage.get_component(ctx, "bundled", "0.1.0")

      refute File.exists?(
               Arca.Adapters.Local.build_path(
                 ctx,
                 ["components", "catalysts", "local", "bundled", "0.1.0", "catalyst.wasm"]
               )
             )

      # The rescan rediscovers it the same way — prune must keep the row,
      # not sweep it as stale.
      {:ok, rescan} = AutoIndexer.scan(ctx: ctx)
      assert rescan.pruned == 0

      assert {:ok, %{name: "bundled"}} =
               Arca.ComponentStorage.get_component(ctx, "bundled", "0.1.0")
    end
  end

  describe "dep-broken re-scan" do
    test "a re-scan of a manifest gone dep-broken keeps the existing row", %{ctx: ctx} do
      dir = create_component("catalyst", "local", "dep-regress", "1.0.0")
      {:ok, %{registered: 1}} = AutoIndexer.scan(ctx: ctx)
      {:ok, row} = Arca.ComponentStorage.get_component(ctx, "dep-regress", "1.0.0")

      # The manifest goes dep-broken on disk; the next scan must not
      # replace the standing row with a failure (refs validate before
      # any row moves).
      File.write!(
        Path.join(dir, "cyfr-manifest.json"),
        Jason.encode!(%{
          "type" => "catalyst",
          "version" => "1.0.0",
          "dependencies" => %{"static" => [%{"ref" => "not a valid ref !!"}]}
        })
      )

      {:ok, %{errors: 1}} = AutoIndexer.scan(ctx: ctx)

      assert {:ok, kept} = Arca.ComponentStorage.get_component(ctx, "dep-regress", "1.0.0")
      assert kept.manifest == row.manifest
    end
  end

  describe "discovery outage" do
    test "a listing outage registers nothing and prunes nothing", %{ctx: ctx} do
      create_component("catalyst", "local", "outage-survivor", "1.0.0")
      assert {:ok, %{registered: 1}} = AutoIndexer.scan(ctx: ctx)

      prev = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Compendium.AutoIndexerTest.OutageAdapter)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :storage_adapter, prev),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      # An unreadable tree is an outage, never an empty roster — the scan
      # that used to read it as empty pruned every filesystem row.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:discovery_failed, :injected_outage}} = AutoIndexer.scan(ctx: ctx)
        end)

      assert log =~ "Discovery failed"

      if prev,
        do: Application.put_env(:cyfr, :storage_adapter, prev),
        else: Application.delete_env(:cyfr, :storage_adapter)

      assert {:ok, %{name: "outage-survivor"}} =
               Arca.ComponentStorage.get_component(ctx, "outage-survivor", "1.0.0")
    end
  end
end
