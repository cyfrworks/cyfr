# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.TinctureSaveTest do
  @moduledoc """
  Saving a tincture build: the build replaces the unit's `dist/` whole, and
  everything else the unit holds — its source, its manifest and its own
  `data.db` — is kept.
  """
  use ExUnit.Case, async: false

  alias Compendium.Builds
  alias Compendium.ComponentPath
  alias Cyfr.Test.ScriptedBuilder

  @base ComponentPath.version_dir("tincture", "local", "saver", "0.1.0")
  @manifest Jason.encode!(%{
              "name" => "saver",
              "version" => "0.1.0",
              "type" => "tincture",
              "tincture" => %{"entry" => "dist/index.html", "build" => %{"tool" => "vite"}}
            })

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    dir = Path.join(System.tmp_dir!(), "tincture_save_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(dir)
    end)

    # Registered after the restore, so it runs before it: a build's tasks
    # stop while the tree they write is still theirs.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))

    # The unit as an author leaves it: source, the manifest, and the
    # tincture's own data beside them.
    :ok = Arca.put(Sanctum.Context.actor(ctx), @base ++ ["cyfr-manifest.json"], @manifest)
    :ok = Arca.put(Sanctum.Context.actor(ctx), @base ++ ["package.json"], ~s({"name":"saver"}))
    :ok = Arca.put(Sanctum.Context.actor(ctx), @base ++ ["index.html"], "<html>source</html>")

    :ok =
      Arca.put(Sanctum.Context.actor(ctx), @base ++ ["src", "main.tsx"], "console.log('source')")

    :ok = Arca.put(Sanctum.Context.actor(ctx), @base ++ ["data.db"], "rows")

    {:ok, ctx: ctx}
  end

  test "the build lands under dist/, and the source it was built from is kept", %{ctx: ctx} do
    build = %{"index.html" => "<html>built</html>", "assets/app-abc.js" => "console.log(1)"}

    assert :ok = Builds.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", build)

    assert {:ok, "<html>built</html>"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "index.html"])

    assert {:ok, "console.log(1)"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-abc.js"])

    assert {:ok, "<html>source</html>"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["index.html"])

    assert {:ok, ~s({"name":"saver"})} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["package.json"])

    assert {:ok, "console.log('source')"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["src", "main.tsx"])

    assert {:ok, "rows"} = Arca.get(Sanctum.Context.actor(ctx), @base ++ ["data.db"])

    assert {:ok, @manifest} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["cyfr-manifest.json"])
  end

  test "a rebuild replaces dist/ whole: an asset the new build did not produce is gone",
       %{ctx: ctx} do
    assert :ok =
             Builds.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>one</html>",
               "assets/app-one.js" => "one"
             })

    assert :ok =
             Builds.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
               "index.html" => "<html>two</html>",
               "assets/app-two.js" => "two"
             })

    assert {:ok, "<html>two</html>"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "index.html"])

    assert {:ok, "two"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-two.js"])

    assert {:error, :not_found} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-one.js"])

    assert {:ok, "console.log('source')"} =
             Arca.get(Sanctum.Context.actor(ctx), @base ++ ["src", "main.tsx"])

    assert {:ok, "rows"} = Arca.get(Sanctum.Context.actor(ctx), @base ++ ["data.db"])
  end

  test "a build for a version with no manifest saves nothing", %{ctx: ctx} do
    assert {:error, :not_found} =
             Builds.store_tincture_output(ctx, "tincture", "local", "absent", "0.1.0", %{
               "index.html" => "<html>orphan</html>"
             })

    absent = ComponentPath.version_dir("tincture", "local", "absent", "0.1.0")
    refute Arca.exists?(Sanctum.Context.actor(ctx), absent ++ ["dist", "index.html"])
  end

  describe "through the builds service" do
    setup do
      ScriptedBuilder.start!()
      :ok
    end

    defp compile(ctx) do
      Compendium.Builds.Provider.handle("build", ctx, %{
        "action" => "compile",
        "reference" => "tincture:local.saver:0.1.0"
      })
    end

    defp built(files),
      do: %{language: :javascript, target_type: :tincture, outputs: files, diagnostics: []}

    test "the builder is sent the source without dist/ or data.db, and its files replace dist/ whole",
         %{ctx: ctx} do
      first = %{"index.html" => "<html>one</html>", "assets/app-one.js" => "one"}
      second = %{"index.html" => "<html>two</html>", "assets/app-two.js" => "two"}

      ScriptedBuilder.script([
        {:stream, [{:result, built(first)}]},
        {:stream, [{:result, built(second)}]}
      ])

      assert {:ok, result} = compile(ctx)
      assert {result.digest, result.size} == Prima.Digest.file_set(first)
      assert Enum.sort(result.files) == ["assets/app-one.js", "index.html"]
      assert result.language == "javascript" and result.target_type == "tincture"

      assert {:ok, "one"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-one.js"])

      assert {:ok, _} = compile(ctx)

      assert {:ok, "<html>two</html>"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "index.html"])

      assert {:ok, "two"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-two.js"])

      assert {:error, :not_found} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "assets", "app-one.js"])

      assert {:ok, "rows"} = Arca.get(Sanctum.Context.actor(ctx), @base ++ ["data.db"])

      assert {:ok, @manifest} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["cyfr-manifest.json"])

      # The second build's input is the source again: the first build's
      # output and the tincture's data are not build input.
      assert [_first, request] = ScriptedBuilder.requests()
      assert request.language == :javascript and request.target_type == :tincture

      assert Enum.sort(Map.keys(request.sources)) ==
               ["cyfr-manifest.json", "index.html", "package.json", "src/main.tsx"]

      ScriptedBuilder.await_builds()
    end

    test "a result whose path escapes the unit is refused and dist/ is left as it was", %{
      ctx: ctx
    } do
      :ok =
        Builds.store_tincture_output(ctx, "tincture", "local", "saver", "0.1.0", %{
          "index.html" => "<html>kept</html>"
        })

      escaping =
        ScriptedBuilder.fixture()["invalid_lines"]
        |> Enum.find(&(&1["name"] == "result_unsafe_path"))
        |> Map.fetch!("body")

      ScriptedBuilder.script([{:stream, [{:line, escaping}]}])

      ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = compile(ctx) end)

      assert {:ok, "<html>kept</html>"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "index.html"])
    end
  end
end
