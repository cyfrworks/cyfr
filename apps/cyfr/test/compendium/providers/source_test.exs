# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.SourceTest do
  @moduledoc """
  The `source` tool: an agent's `files(path: "components/…")` call routes
  here, host-side, and reads and edits a local component version's own
  source — never its version directory whole, its manifest, or what a
  build writes, at any spelling of their paths — and nothing the layout's
  one grammar (`Compendium.ComponentPath.parse/1`) does not read as a
  local component version. What that grammar refuses, every door refuses
  and the launch rule counts as no component; a pulled component is
  fork-to-modify at every door.
  """
  use ExUnit.Case, async: false

  alias Aqua.Hands
  alias Aqua.Loop.{Binding, Policy}
  alias Compendium.Providers.Source
  alias Crucible.GuestStorage
  alias Prima.Authority.Blob.Edge

  @dir "components/catalysts/local/widget/0.1.0"
  @manifest_segments String.split(@dir, "/") ++ ["cyfr-manifest.json"]
  @actions ["tree", "read", "grep", "write", "edit", "delete"]
  @mutations ["write", "edit", "delete"]
  @guest_mutations [:write, :append, :delete]

  # A pulled component: another publisher's version, which no door edits.
  @pulled "components/catalysts/acme/thing/1.0.0"

  # Files under `components/` the layout's grammar does not read as a
  # component version, each for one reason.
  @off_grammar [
    # no version directory
    "components/catalysts/local/widget/src/lib.rs",
    "components/catalysts/local/notes.txt",
    # a version that is not semver
    "components/catalysts/local/widget/latest/src/lib.rs",
    # a plural no component type has, or no plural at all
    "components/widgets/local/widget/0.1.0/src/lib.rs",
    "components/catalyst/local/widget/0.1.0/src/lib.rs",
    "components/Catalysts/local/widget/0.1.0/src/lib.rs",
    # a publisher or a name the reference grammar refuses
    "components/catalysts/Local/widget/0.1.0/src/lib.rs",
    "components/catalysts/local/Widget/0.1.0/src/lib.rs",
    "components/catalysts/local/wid_get/0.1.0/src/lib.rs"
  ]

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

  # A guest's `op` at `path`, granted every write under `components/`; the
  # hold runs the store call, which a refused write never reaches.
  defp guest(ctx, op, path) do
    scope = %{
      ctx: ctx,
      edge: %Edge{storage: %{paths: ["components/"], actions: ["write", "append", "delete"]}},
      limits: nil,
      quota: nil,
      hold: fn %{io: io} ->
        case io.() do
          :ok -> {:ok, {:confirmed, :ok}}
          {:error, _} = refused -> {:ok, {:failed, refused}}
        end
      end
    }

    GuestStorage.run(scope, op, %{"path" => path, "content" => Base.encode64("{}")})
  end

  # What the launch rule counts a closed `source` call at `path` as having
  # written to.
  defp touched(action, path) do
    Policy.touched_refs([
      %{"tool" => "source", "action" => action, "arguments" => %{"path" => path}}
    ])
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "source_tool_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arca, :base_path, prev),
        else: Application.delete_env(:arca, :base_path)

      File.rm_rf!(base)
    end)

    # The edits a test starts write under the base path: they stop before
    # it moves back.
    Cyfr.Test.Sandbox.stop_work_on_exit()

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
    test "another publisher's component is not yours to read or edit", %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      :ok = Arca.put(actor, String.split(@pulled, "/") ++ ["src", "lib.rs"], "fn theirs() {}")

      calls =
        for(path <- ["#{@pulled}/src/lib.rs", @pulled], action <- @actions, do: {action, path}) ++
          [{"tree", Path.dirname(@pulled)}]

      for {action, path} <- calls do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "'acme' is another publisher's component"
      end

      assert {:ok, "fn theirs() {}"} =
               Arca.get(actor, String.split(@pulled, "/") ++ ["src", "lib.rs"])
    end

    test "a path the layout's grammar does not read as a component version refuses in words",
         %{ctx: ctx} do
      for path <- @off_grammar, action <- @actions do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "'#{path}' is not a component version's own source"
      end

      # Nothing landed in the component the refused spellings resemble.
      assert {:ok, %{files: files}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert Enum.sort(files) == ["cyfr-manifest.json", "src/lib.rs"]
    end

    test "above a version directory, only tree reads a component's name directory",
         %{ctx: ctx} do
      name_dir = Path.dirname(@dir)

      assert {:ok, %{files: files}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => name_dir})

      assert Enum.sort(files) == ["0.1.0/cyfr-manifest.json", "0.1.0/src/lib.rs"]

      for action <- @actions -- ["tree"] do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, name_dir)),
               "#{action} #{name_dir} was not refused"

        assert msg =~ "not a component version's own source"
      end

      for path <- [
            "components",
            "components/catalysts",
            "components/catalysts/local",
            "components/widgets/local/widget",
            "components/catalysts/local/Widget"
          ],
          action <- @actions do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "not a component version's own source"
      end
    end

    test "a call without a path names what it needs", %{ctx: ctx} do
      for args <- [%{"action" => "read"}, %{"action" => "write", "path" => 7}] do
        assert {:error, {:invalid_argument, "source needs a path"}} =
                 Source.handle("source", ctx, args)
      end
    end

    test "the compiled artifact is written by a build, not by hand, at any spelling",
         %{ctx: ctx} do
      for name <- ["catalyst.wasm", "CATALYST.WASM", "Catalyst.Wasm"], action <- @actions do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, "#{@dir}/#{name}")),
               "#{action} #{name} was not refused"

        assert msg =~ "written by a build"
      end
    end

    test "a tincture's dist/ is a build's output, at any spelling", %{ctx: ctx} do
      for dist <- ["dist", "DIST", "Dist"], action <- @actions do
        path = "components/tinctures/local/panel/0.1.0/#{dist}/index.html"

        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "build's output"
      end
    end

    test "the version directory itself is never written, edited or deleted", %{ctx: ctx} do
      for path <- [@dir, @dir <> "/", "/" <> @dir, String.replace(@dir, "/", "//")],
          action <- ["write", "edit", "delete"] do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "created and deleted whole"
      end

      assert {:ok, %{files: [_ | _]}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => @dir})

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
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"

        assert msg =~ "Files page"
      end

      assert {:ok, ~s({"name":"widget"})} =
               Arca.get(Sanctum.Context.actor(ctx), @manifest_segments)

      assert {:ok, %{content: ~s({"name":"widget"})}} =
               Source.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/cyfr-manifest.json"
               })

      assert {:ok, %{files: files}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => @dir})

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
                 Source.handle("source", ctx, mutation(action, path)),
               "#{action} #{path} was not refused"
      end

      assert {:ok, ~s({"name":"widget"})} =
               Arca.get(Sanctum.Context.actor(ctx), @manifest_segments)
    end

    test "a path outside a component version refuses in words", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               Source.handle("source", ctx, %{"action" => "read", "path" => "data/x.txt"})

      assert msg =~ "not a component version's own source"
    end
  end

  describe "actions" do
    test "read, tree and grep answer over the unit's source", %{ctx: ctx} do
      assert {:ok, %{content: "fn one() {}" <> _}} =
               Source.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })

      assert {:ok, %{files: files}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert "src/lib.rs" in files
      assert "cyfr-manifest.json" in files

      assert {:ok, %{matches: [%{file: "src/lib.rs", line: 2}]}} =
               Source.handle("source", ctx, %{
                 "action" => "grep",
                 "path" => @dir,
                 "pattern" => "fn two",
                 "include" => ".rs"
               })
    end

    test "write and edit change the source", %{ctx: ctx} do
      assert {:ok, _} =
               Source.handle("source", ctx, %{
                 "action" => "write",
                 "path" => "#{@dir}/src/new.rs",
                 "content" => "fn added() {}"
               })

      assert {:ok, %{content: "fn added() {}"}} =
               Source.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/new.rs"
               })

      assert {:ok, _} =
               Source.handle("source", ctx, %{
                 "action" => "edit",
                 "path" => "#{@dir}/src/lib.rs",
                 "edits" => [
                   %{"action" => "replace", "start" => 2, "end" => 2, "content" => "fn TWO() {}"}
                 ]
               })

      assert {:ok, %{content: content}} =
               Source.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })

      assert content == "fn one() {}\nfn TWO() {}\nfn three() {}"
    end

    test "an edit past the end of the file says so", %{ctx: ctx} do
      assert {:error, {:invalid_argument, msg}} =
               Source.handle("source", ctx, %{
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
               Source.handle("source", ctx, %{
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

      # An edit is applied to the bytes it read and written only while they
      # are still there, and read again when another edit landed in between
      # (`Arca.Overlay.update/3`, up to five attempts, then a conflict to
      # ask again). Each attempt an editor loses is to another editor's
      # landed write, so two editors started together both land however
      # they interleave. Each attempt's bookkeeping also queues on the
      # sandbox's one shared connection, which drops a checkout that waits
      # past its queue target, so more editors on a loaded machine would be
      # answered unavailable rather than prove anything more.
      editors = 1..2

      editors
      |> Enum.map(fn i ->
        Task.async(fn ->
          Source.handle("source", ctx, %{
            "action" => "edit",
            "path" => "#{@dir}/src/log.txt",
            "edits" => [%{"action" => "insert", "start" => 2, "content" => "line #{i}"}]
          })
        end)
      end)
      |> Enum.each(&assert({:ok, _} = Task.await(&1, 10_000)))

      assert {:ok, %{content: content}} =
               Source.handle("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/log.txt"
               })

      # Every edit is there once, below the line they all inserted under.
      assert ["start" | lines] = String.split(content, "\n")
      assert Enum.sort(lines) == Enum.map(editors, &"line #{&1}")
    end

    test "source is the agent's: the wire does not serve it", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{stage: :admission, reason: {:unknown_action, "source.read"}}} =
               Grimoire.call_external("source", ctx, %{
                 "action" => "read",
                 "path" => "#{@dir}/src/lib.rs"
               })
    end
  end

  # The other doors a component path reaches: the athanor's files, a
  # guest's storage and the launch rule's count of what a turn wrote to.
  describe "one grammar at every door" do
    test "a path the grammar reads as a local version is written at every door and counted",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)

      assert {:ok, _} =
               Source.handle("source", ctx, mutation("write", "#{@dir}/src/by_source.rs"))

      assert {:ok, _} = Arca.Files.write(actor, "#{@dir}/src/by_files.rs", "{}")
      assert {:ok, %{"written" => true}} = guest(ctx, :write, "#{@dir}/src/by_guest.rs")

      for action <- @mutations do
        assert touched(action, "#{@dir}/src/lib.rs") == MapSet.new(["catalyst:local.widget"])
      end
    end

    test "a spelling with empty segments lands in the unit, is counted, and a run of it asks",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      file = String.split(@dir, "/") ++ ["src", "lib.rs"]

      {:ok, launch} =
        Binding.resolve("execution", %{
          "action" => "run",
          "reference" => "catalyst:local.widget:0.1.0"
        })

      policy = %{"execution.run" => "auto"}
      consented = fn ref -> String.starts_with?(ref, "catalyst:local.widget") end

      # Every launch asks, consented and untouched included.
      assert :ask = Policy.decide(launch, policy, consented?: consented, touched: MapSet.new())

      for path <- [
            "components//catalysts/local/widget/0.1.0/src/lib.rs",
            "/components/catalysts/local/widget/0.1.0/src/lib.rs"
          ] do
        content = "fn written_at(#{inspect(path)}) {}"

        assert {:ok, _} =
                 Source.handle("source", ctx, %{
                   "action" => "write",
                   "path" => path,
                   "content" => content
                 })

        assert {:ok, ^content} = Arca.get(actor, file), "#{path} did not land in widget"

        touched = touched("write", path)

        assert touched == MapSet.new(["catalyst:local.widget"]),
               "#{path} named #{inspect(touched)}"

        assert :ask = Policy.decide(launch, policy, consented?: consented, touched: touched)
      end
    end

    test "a path the grammar refuses is refused at every door and names no component",
         %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)

      for path <- @off_grammar do
        for action <- @mutations do
          assert {:error, {:invalid_argument, msg}} =
                   Source.handle("source", ctx, mutation(action, path))

          assert msg =~ "not a component version's own source"
          assert touched(action, path) == MapSet.new(), "#{path} named a component"
        end

        assert {:error, {:invalid_argument, msg}} = Arca.Files.write(actor, path, "{}")
        assert msg =~ "'#{path}' is outside any component"

        for op <- @guest_mutations do
          assert {:error, {:guest_error, "storage_path_denied", msg}} = guest(ctx, op, path),
                 "a guest's #{op} of #{path} was not refused"

          assert msg =~ "must land inside a version directory"
        end
      end

      assert {:ok, %{files: files}} =
               Source.handle("source", ctx, %{"action" => "tree", "path" => @dir})

      assert Enum.sort(files) == ["cyfr-manifest.json", "src/lib.rs"]
    end

    test "a pulled component is fork-to-modify at every door", %{ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      file = "#{@pulled}/src/lib.rs"
      :ok = Arca.put(actor, String.split(file, "/"), "fn theirs() {}")
      fork = Prima.ComponentNamespace.message(:not_local_namespace, "acme")

      for action <- @mutations do
        assert {:error, {:invalid_argument, msg}} =
                 Source.handle("source", ctx, mutation(action, file))

        assert msg =~ "another publisher"
      end

      assert {:error, {:invalid_argument, msg}} = Arca.Files.write(actor, file, "{}")
      assert msg == "'#{file}': " <> fork

      for op <- @guest_mutations do
        assert {:error, {:guest_error, "storage_path_denied", ^fork}} = guest(ctx, op, file)
      end

      assert {:ok, "fn theirs() {}"} = Arca.get(actor, String.split(file, "/"))
    end
  end
end
