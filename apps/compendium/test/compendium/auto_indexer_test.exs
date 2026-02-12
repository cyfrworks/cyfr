defmodule Compendium.AutoIndexerTest do
  use ExUnit.Case, async: false

  alias Compendium.AutoIndexer
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

    test_dir = Path.join(System.tmp_dir!(), "cyfr_autoindexer_test_#{:rand.uniform(100_000)}")
    comp_dir = Path.join(test_dir, "components")
    File.mkdir_p!(comp_dir)

    # Set arca base_path for WASM storage
    arca_dir = Path.join(test_dir, "arca_data")
    File.mkdir_p!(arca_dir)
    Application.put_env(:arca, :base_path, arca_dir)

    ctx = Context.local()

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir, comp_dir: comp_dir, ctx: ctx}
  end

  defp create_component(comp_dir, type, publisher, name, version, opts \\ []) do
    dir = Path.join([comp_dir, "#{type}s", publisher, name, version])
    File.mkdir_p!(dir)

    manifest = %{
      "type" => type,
      "version" => version,
      "description" => Keyword.get(opts, :description, "Test #{name}")
    }

    manifest = if tags = Keyword.get(opts, :tags) do
      Map.put(manifest, "tags", tags)
    else
      manifest
    end

    File.write!(Path.join(dir, "cyfr-manifest.json"), Jason.encode!(manifest))
    File.write!(Path.join(dir, "#{type}.wasm"), @valid_wasm)

    dir
  end

  describe "scan/1" do
    test "discovers and registers local components", %{comp_dir: comp_dir, ctx: ctx} do
      create_component(comp_dir, "catalyst", "local", "openai", "0.1.0")
      create_component(comp_dir, "reagent", "local", "json-tool", "1.0.0")

      result = AutoIndexer.scan([comp_dir])

      assert result.registered == 2
      assert result.errors == 0

      {:ok, search} = Registry.search(ctx, %{query: "openai"})
      assert search.total == 1
      assert hd(search.components).name == "openai"

      {:ok, search2} = Registry.search(ctx, %{query: "json-tool"})
      assert search2.total == 1
    end

    test "registers agent namespace components", %{comp_dir: comp_dir, ctx: ctx} do
      create_component(comp_dir, "reagent", "agent", "ai-generated", "0.1.0")

      result = AutoIndexer.scan([comp_dir])

      assert result.registered == 1

      {:ok, search} = Registry.search(ctx, %{query: "ai-generated"})
      assert search.total == 1
    end

    test "ignores non-local/agent publisher directories", %{comp_dir: comp_dir, ctx: ctx} do
      create_component(comp_dir, "catalyst", "stripe", "payment", "1.0.0")
      create_component(comp_dir, "catalyst", "cyfr", "internal", "1.0.0")

      result = AutoIndexer.scan([comp_dir])

      assert result.registered == 0

      {:ok, search} = Registry.search(ctx, %{query: "payment"})
      assert search.total == 0
    end

    test "skips unchanged components on rescan", %{comp_dir: comp_dir} do
      create_component(comp_dir, "reagent", "local", "stable-tool", "1.0.0")

      result1 = AutoIndexer.scan([comp_dir])
      assert result1.registered == 1

      result2 = AutoIndexer.scan([comp_dir])
      assert result2.unchanged == 1
      assert result2.registered == 0
    end

    test "prunes stale entries", %{comp_dir: comp_dir, ctx: ctx} do
      dir = create_component(comp_dir, "reagent", "local", "temp-tool", "0.1.0")

      result1 = AutoIndexer.scan([comp_dir])
      assert result1.registered == 1

      {:ok, search} = Registry.search(ctx, %{query: "temp-tool"})
      assert search.total == 1

      # Delete the component directory
      File.rm_rf!(dir)

      # Rescan should prune the stale entry
      result2 = AutoIndexer.scan([comp_dir])
      assert result2.pruned == 1

      {:ok, search2} = Registry.search(ctx, %{query: "temp-tool"})
      assert search2.total == 0
    end

    test "handles missing component directories gracefully" do
      result = AutoIndexer.scan(["/nonexistent/path"])

      assert result.registered == 0
      assert result.errors == 0
    end

    test "scans multiple component types", %{comp_dir: comp_dir} do
      create_component(comp_dir, "catalyst", "local", "api-tool", "0.1.0")
      create_component(comp_dir, "reagent", "local", "data-tool", "0.1.0")
      create_component(comp_dir, "formula", "local", "workflow", "0.1.0")

      result = AutoIndexer.scan([comp_dir])

      assert result.registered == 3
      assert result.total == 3
    end
  end
end
