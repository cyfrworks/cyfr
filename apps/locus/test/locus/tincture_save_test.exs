# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.TinctureSaveTest do
  @moduledoc """
  Saving a tincture build: the unit keeps what the build did not produce.

  The builder answers with `dist/`-relative paths, and the unit's completion
  file is its `cyfr-manifest.json`, which no `dist/` holds. Committing the
  build alone resolved no sentinel and saved nothing — and would have wiped
  the source the moment it worked, because a unit commit clears the unit
  before it writes.
  """
  use ExUnit.Case, async: false

  alias Compendium.ComponentPath
  alias Locus.MCP

  @base ComponentPath.version_dir("tincture", "local", "saver", "0.1.0")
  @manifest Jason.encode!(%{
              "name" => "saver",
              "version" => "0.1.0",
              "type" => "tincture",
              "tincture" => %{"entry" => "index.html"}
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
    :ok = Arca.put(ctx, @base ++ ["vite.config.ts"], "export default {}")
    :ok = Arca.put(ctx, @base ++ ["src", "main.tsx"], "console.log('source')")
    :ok = Arca.put(ctx, @base ++ ["data.db"], "rows")

    {:ok, ctx: ctx}
  end

  test "the build lands, and the source it was built from is still there", %{ctx: ctx} do
    build = %{"index.html" => "<html>built</html>", "assets/app-abc.js" => "console.log(1)"}

    assert :ok = MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", build)

    assert {:ok, "<html>built</html>"} = Arca.get(ctx, @base ++ ["index.html"])
    assert {:ok, "console.log(1)"} = Arca.get(ctx, @base ++ ["assets", "app-abc.js"])

    # What the build did not produce survives it — this is the half that
    # would have been silently deleted.
    assert {:ok, ~s({"name":"saver"})} = Arca.get(ctx, @base ++ ["package.json"])
    assert {:ok, "export default {}"} = Arca.get(ctx, @base ++ ["vite.config.ts"])
    assert {:ok, "console.log('source')"} = Arca.get(ctx, @base ++ ["src", "main.tsx"])
    assert {:ok, "rows"} = Arca.get(ctx, @base ++ ["data.db"])
    assert {:ok, @manifest} = Arca.get(ctx, @base ++ ["cyfr-manifest.json"])
  end

  test "a second build replaces the output and still leaves the source", %{ctx: ctx} do
    assert :ok =
             MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>one</html>"
             })

    assert :ok =
             MCP.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>two</html>"
             })

    assert {:ok, "<html>two</html>"} = Arca.get(ctx, @base ++ ["index.html"])
    assert {:ok, "console.log('source')"} = Arca.get(ctx, @base ++ ["src", "main.tsx"])
    assert {:ok, "rows"} = Arca.get(ctx, @base ++ ["data.db"])
  end
end
