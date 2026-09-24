# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.SourceToolTest do
  @moduledoc """
  The `source` tool: an agent's `files(path: "components/…")` call routes
  here, host-side, and reads and edits a local component version's own
  source — never its version directory whole, its manifest, or what a
  build writes, at any spelling of their paths.
  """
  use ExUnit.Case, async: false

  alias Aqua.Hands
  alias Compendium.MCP.SourceTool

  @dir "components/catalysts/local/widget/0.1.0"
  @manifest_segments String.split(@dir, "/") ++ ["cyfr-manifest.json"]
  @actions ["tree", "read", "grep", "write", "edit", "delete"]

  # One call of `action` at `path`, carrying what every action needs.
  defp mutation(action, path) do
    %{
      "action" => action,
      "path" => path,
      "content" => "{}",
      "pattern" => "x",
      "edits" => [%{"action" => "replace", "start" => 1, "end" => 1, "content" => "{}"}]
    }
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "source_tool_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      if prev, do: Application.put_env(:arca, :base_path, prev)
      File.rm_rf!(base)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Arca.ensure_roots(Sanctum.Context.actor(ctx))
    segs = String.split(@dir, "/")

    :ok =
      Arca.put(Sanctum.Context.actor(ctx), segs ++ ["cyfr-manifest.json"], ~s({"name":"widget"}))

    :ok =
      Arca.put(
        Sanctum.Context.actor(ctx),
        segs ++ ["src", "lib.rs"],
        "fn one() {}\nfn two() {}\nfn three() {}"
      )

    {:ok, ctx: ctx}
  end

  describe "routing" do
    test "a files call on a component path is canonicalised to the host-side source tool" do
      assert {:ok, %{tool: "source", action: "read"}} =
               Hands.canonical_files("read", %{"path" => "#{@dir}/src/lib.rs"})

      assert {:ok, %{tool: "source", action: "write"}} =
               Hands.canonical_files("write", %{"path" => "#{@dir}/src/lib.rs"})
    end

    test "a files call on data/ is still the files catalyst" do
      assert {:ok, %{tool: "files"}} =
               Hands.canonical_files("read", %{"path" => "data/notes.txt"})
    end

    test "data/storage/ still goes to the storage hand" do
      assert {:ok, %{tool: "storage"}} =
               Hands.canonical_files("read", %{"path" => "data/storage/thing.json"})
    end
  end

  describe "scope" do
    test "another publisher's component is not yours to edit", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "components/catalysts/acme/thing/1.0.0/src/lib.rs"
               })

      assert msg =~ "another publisher"
    end

    test "the compiled artifact is written by a build, not by hand, at any spelling",
         %{ctx: ctx} do
      for name <- ["catalyst.wasm", "CATALYST.WASM", "Catalyst.Wasm"], action <- @actions do
        assert {:error, {:invalid_argument, msg}} =
                 SourceTool.handle("source", ctx, mutation(action, "#{@dir}/#{name}")),
               "#{action} #{name} was not refused"

        assert msg =~ "written by a build"
      end
    end

    test "a tincture's dist/ is a build's output, at any spelling", %{ctx: ctx} do
      for dist <- ["dist", "DIST", "Dist"], action <- @actions do
        path = "components/tinctures/local/panel/0.1.0/#{dist}/index.html"

        assert {:error, {:invalid_argument, msg}} =
                 SourceTool.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "build's output"
      end
    end

    test "the version directory itself is never written, edited or deleted", %{ctx: ctx} do
      for path <- [@dir, @dir <> "/", "/" <> @dir, String.replace(@dir, "/", "//")],
          action <- ["write", "edit", "delete"] do
        assert {:error, {:invalid_argument, msg}} =
                 SourceTool.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "created and deleted whole"
      end

      assert {:ok, %{files: [_ | _]}} =
               SourceTool.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert {:ok, _} = Arca.get(Sanctum.Context.actor(ctx), @manifest_segments)
    end

    test "the manifest is read here and never written, edited or deleted, at any spelling",
         %{ctx: ctx} do
      spellings = [
        "#{@dir}/cyfr-manifest.json",
        "#{@dir}/CYFR-MANIFEST.JSON",
        "#{@dir}/Cyfr-Manifest.Json",
        # Fullwidth letters: the same name after compatibility normalisation.
        "#{@dir}/ｃｙｆｒ-ｍａｎｉｆｅｓｔ.ｊｓｏｎ",
        "/#{@dir}/cyfr-manifest.json",
        "#{String.replace(@dir, "/", "//")}//cyfr-manifest.json"
      ]

      for path <- spellings, action <- ["write", "edit", "delete"] do
        assert {:error, {:invalid_argument, msg}} =
                 SourceTool.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "Files page"
      end

      assert {:ok, ~s({"name":"widget"})} =
               Arca.get(Sanctum.Context.actor(ctx), @manifest_segments)

      assert {:ok, %{content: ~s({"name":"widget"})}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/cyfr-manifest.json"
               })

      assert {:ok, %{files: files}} =
               SourceTool.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert "cyfr-manifest.json" in files
    end

    test "a dot or encoded segment refuses before any name is compared", %{ctx: ctx} do
      for path <- [
            "#{@dir}/./cyfr-manifest.json",
            "#{@dir}/src/../cyfr-manifest.json",
            "#{@dir}/src/%2e%2e/cyfr-manifest.json",
            "#{@dir}/.",
            "#{@dir}/src\\..\\cyfr-manifest.json"
          ],
          action <- @actions do
        assert {:error, {:invalid_argument, _msg}} =
                 SourceTool.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"
      end

      assert {:ok, ~s({"name":"widget"})} =
               Arca.get(Sanctum.Context.actor(ctx), @manifest_segments)
    end

    test "a path outside a component version refuses in words", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               SourceTool.handle("source", ctx, %{"action" => "read", "path" => "data/x.txt"})

      assert msg =~ "not a component version's own source"
    end
  end

  describe "actions" do
    test "read, tree and grep answer over the unit's source", %{ctx: ctx} do
      assert {:ok, %{content: "fn one() {}" <> _}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })

      assert {:ok, %{files: files}} =
               SourceTool.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert "src/lib.rs" in files
      assert "cyfr-manifest.json" in files

      assert {:ok, %{matches: [%{file: "src/lib.rs", line: 2}]}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "grep",
                 "path" => @dir,
                 "pattern" => "fn two",
                 "include" => ".rs"
               })
    end

    test "write and edit change the source", %{ctx: ctx} do
      assert {:ok, _} =
               SourceTool.handle("source", ctx, %{
                 "action" => "write",
                 "path" => "#{@dir}/src/new.rs",
                 "content" => "fn added() {}"
               })

      assert {:ok, %{content: "fn added() {}"}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/new.rs"
               })

      assert {:ok, _} =
               SourceTool.handle("source", ctx, %{
                 "action" => "edit",
                 "path" => "#{@dir}/src/lib.rs",
                 "edits" => [
                   %{"action" => "replace", "start" => 2, "end" => 2, "content" => "fn TWO() {}"}
                 ]
               })

      assert {:ok, %{content: content}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })

      assert content == "fn one() {}\nfn TWO() {}\nfn three() {}"
    end

    test "an edit past the end of the file says so", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "edit",
                 "path" => "#{@dir}/src/lib.rs",
                 "edits" => [%{"action" => "delete", "start" => 9, "end" => 12}]
               })

      assert msg =~ "past the end"
    end

    test "edit works on text; a binary file is written whole", %{ctx: ctx} do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          String.split(@dir, "/") ++ ["media", "icon.png"],
          <<137, 0, 1, 2>>
        )

      assert {:error, {:invalid_argument, msg}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "edit",
                 "path" => "#{@dir}/media/icon.png",
                 "edits" => [%{"action" => "delete", "start" => 1, "end" => 1}]
               })

      assert msg =~ "not text"
    end

    test "edits of one file serialize: none is lost to a concurrent one", %{ctx: ctx} do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          String.split(@dir, "/") ++ ["src", "log.txt"],
          "start"
        )

      parent = self()

      1..8
      |> Enum.map(fn i ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, parent, self())

          SourceTool.handle("source", ctx, %{
            "action" => "edit",
            "path" => "#{@dir}/src/log.txt",
            "edits" => [%{"action" => "insert", "start" => 2, "content" => "line #{i}"}]
          })
        end)
      end)
      |> Enum.each(&assert({:ok, _} = Task.await(&1, 10_000)))

      assert {:ok, %{content: content}} =
               SourceTool.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/log.txt"
               })

      assert length(String.split(content, "\n")) == 9
    end

    test "source is the agent's: the wire does not serve it", %{ctx: ctx} do
      assert {:error, {:unknown_action, "source.read"}} =
               Grimoire.Catalog.call_external("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })
    end
  end
end
