# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.TinctureSaveTest do
  @moduledoc """
  Saving a tincture build: the build replaces the unit's `dist/` whole, and
  everything else the unit holds — its source, its manifest and its other
  files — is kept.
  """
  use ExUnit.Case, async: false

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

    # The unit as an author leaves it: source, the manifest, and a file of
    # its own beside them, one commit.
    Arca.Test.UnitFixtures.lay_unit!(ctx, @base, [
      {"cyfr-manifest.json", @manifest},
      {"package.json", ~s({"name":"saver"})},
      {"package-lock.json", ~s({"name":"saver"})},
      {"index.html", "<html>source</html>"},
      {"src/main.tsx", "console.log('source')"},
      {"notes.md", "rows"}
    ])

    {:ok, ctx: ctx}
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

    test "the builder is sent the unit without dist/, and its files replace dist/ whole",
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

      assert {:ok, "rows"} = Arca.get(Sanctum.Context.actor(ctx), @base ++ ["notes.md"])

      assert {:ok, "<html>source</html>"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["index.html"])

      assert {:ok, "console.log('source')"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["src", "main.tsx"])

      assert {:ok, @manifest} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["cyfr-manifest.json"])

      # The second build's input is the unit again: the first build's
      # output is not build input.
      assert [_first, request] = ScriptedBuilder.requests()
      assert request.language == :javascript and request.target_type == :tincture

      assert Enum.sort(Map.keys(request.sources)) ==
               [
                 "cyfr-manifest.json",
                 "index.html",
                 "notes.md",
                 "package-lock.json",
                 "package.json",
                 "src/main.tsx"
               ]

      ScriptedBuilder.await_builds()
    end

    test "a result whose path escapes the unit is refused and dist/ is left as it was", %{
      ctx: ctx
    } do
      escaping =
        ScriptedBuilder.fixture()["invalid_lines"]
        |> Enum.find(&(&1["name"] == "result_unsafe_path"))
        |> Map.fetch!("body")

      ScriptedBuilder.script([
        {:stream, [{:result, built(%{"index.html" => "<html>kept</html>"})}]},
        {:stream, [{:line, escaping}]}
      ])

      assert {:ok, _} = compile(ctx)
      ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = compile(ctx) end)

      assert {:ok, "<html>kept</html>"} =
               Arca.get(Sanctum.Context.actor(ctx), @base ++ ["dist", "index.html"])
    end
  end
end
