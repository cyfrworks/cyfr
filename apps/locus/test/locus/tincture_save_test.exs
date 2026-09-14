# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.TinctureSaveTest do
  @moduledoc """
  Saving a tincture build: the build replaces the unit's `dist/` whole, and
  everything else the unit holds — its source, its manifest and its own
  `data.db` — is kept.
  """
  use ExUnit.Case, async: false

  alias Compendium.ComponentPath
  alias Locus.MCP

  @base ComponentPath.version_dir("tincture", "local", "saver", "0.1.0")
  @manifest Jason.encode!(%{
              "name" => "saver",
              "version" => "0.1.0",
              "type" => "tincture",
              "tincture" => %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}
            })

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    dir = Path.join(System.tmp_dir!(), "tincture_save_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:cyfr, :base_path, prev)
      File.rm_rf!(dir)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(ctx)

    # The unit as an author leaves it: source, the manifest, and the
    # tincture's own data beside them.
    :ok = Arca.put(ctx, @base ++ ["cyfr-manifest.json"], @manifest)
    :ok = Arca.put(ctx, @base ++ ["package.json"], ~s({"name":"saver"}))
    :ok = Arca.put(ctx, @base ++ ["index.html"], "<html>source</html>")
    :ok = Arca.put(ctx, @base ++ ["src", "main.tsx"], "console.log('source')")
    :ok = Arca.put(ctx, @base ++ ["data.db"], "rows")

    {:ok, ctx: ctx}
  end

  test "the build lands under dist/, and the source it was built from is kept", %{ctx: ctx} do
    build = %{"index.html" => "<html>built</html>", "assets/app-abc.js" => "console.log(1)"}

    assert :ok = MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", build)

    assert {:ok, "<html>built</html>"} = Arca.get(ctx, @base ++ ["dist", "index.html"])
    assert {:ok, "console.log(1)"} = Arca.get(ctx, @base ++ ["dist", "assets", "app-abc.js"])

    assert {:ok, "<html>source</html>"} = Arca.get(ctx, @base ++ ["index.html"])
    assert {:ok, ~s({"name":"saver"})} = Arca.get(ctx, @base ++ ["package.json"])
    assert {:ok, "console.log('source')"} = Arca.get(ctx, @base ++ ["src", "main.tsx"])
    assert {:ok, "rows"} = Arca.get(ctx, @base ++ ["data.db"])
    assert {:ok, @manifest} = Arca.get(ctx, @base ++ ["cyfr-manifest.json"])
  end

  test "a rebuild replaces dist/ whole: an asset the new build did not produce is gone",
       %{ctx: ctx} do
    assert :ok =
             MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>one</html>",
               "assets/app-one.js" => "one"
             })

    assert :ok =
             MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>two</html>",
               "assets/app-two.js" => "two"
             })

    assert {:ok, "<html>two</html>"} = Arca.get(ctx, @base ++ ["dist", "index.html"])
    assert {:ok, "two"} = Arca.get(ctx, @base ++ ["dist", "assets", "app-two.js"])
    assert {:error, :not_found} = Arca.get(ctx, @base ++ ["dist", "assets", "app-one.js"])

    assert {:ok, "console.log('source')"} = Arca.get(ctx, @base ++ ["src", "main.tsx"])
    assert {:ok, "rows"} = Arca.get(ctx, @base ++ ["data.db"])
  end

  test "a build for a version with no manifest saves nothing", %{ctx: ctx} do
    assert {:error, :not_found} =
             MCP.store_tincture_output(ctx, "tincture", "local", "absent", "0.1.0", %{
               "index.html" => "<html>orphan</html>"
             })

    absent = ComponentPath.version_dir("tincture", "local", "absent", "0.1.0")
    refute Arca.exists?(ctx, absent ++ ["dist", "index.html"])
  end
end
