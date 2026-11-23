# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderTest do
  @moduledoc """
  The builder answers a request with output files or with the build wire's
  own refusal, and nothing in between: what a request lacks is `malformed`
  before anything runs, a toolchain this machine lacks is `unavailable`, a
  build that exits non-zero is `failed` with its status, and output past a
  bound is refused as `failed`, never cut to fit. Its files leave it as
  output lines, each read back here through the wire's own rules and kept
  only once its result names them. The executor here is the test
  environment's direct launcher.
  """

  # Replaces PATH for the duration of one test.
  use ExUnit.Case, async: false

  alias Prima.BuilderProtocol
  alias Locus.Builder

  # A build as the service runs one: its place made, the request prepared,
  # then its plan run in the place, which is dropped however the build ends.
  # Its output lines are read as a client reads them, and a result answers
  # the files they carried.
  defp build(request, opts \\ []) do
    {:ok, place} = Builder.place(%{athanor_id: "ath_builder"})
    {:ok, lines} = Agent.start_link(fn -> [] end)
    on_line = fn line -> Agent.update(lines, &[line | &1]) end

    try do
      with {:ok, plan} <- Builder.prepare(request),
           {:ok, result} <- Builder.run(plan, opts ++ [place: place, on_line: on_line]) do
        {:ok, %{result | outputs: received(Agent.get(lines, &Enum.reverse/1), result)}}
      end
    after
      Builder.drop(place)
    end
  end

  defp received(lines, result) do
    outputs =
      Enum.reduce(lines, BuilderProtocol.outputs(), fn line, outputs ->
        assert {:ok, {:output, chunk}} = BuilderProtocol.read_line(line)
        assert {:ok, outputs} = BuilderProtocol.output(outputs, chunk)
        outputs
      end)

    assert {:ok, line} = BuilderProtocol.encode_result(result)
    assert {:ok, {:result, ^result}} = BuilderProtocol.read_line(line)
    assert {:ok, files} = BuilderProtocol.outputs(outputs, result)
    files
  end

  defp rust(sources, fields \\ %{}) do
    Map.merge(%{language: :rust, target_type: :reagent, resolve: false, sources: sources}, fields)
  end

  defp tincture(sources), do: rust(sources, %{language: :javascript, target_type: :tincture})

  # A tincture whose `npm run build` runs `script`, with the lockfile of a
  # package that installs nothing.
  defp scripted(script, scripts \\ %{}) do
    tincture(%{
      "package.json" => package(%{scripts: Map.put(scripts, :build, script)}),
      "package-lock.json" => lockfile(%{})
    })
  end

  defp package(fields),
    do:
      Jason.encode!(Map.merge(%{name: "builder-probe", version: "0.0.1", private: true}, fields))

  # The lockfile npm writes for `builder-probe` with `dependencies` and
  # the `node_modules` entries `installed`.
  defp lockfile(dependencies, installed \\ %{}) do
    root =
      if dependencies == %{},
        do: %{name: "builder-probe", version: "0.0.1"},
        else: %{name: "builder-probe", version: "0.0.1", dependencies: dependencies}

    Jason.encode!(%{
      name: "builder-probe",
      version: "0.0.1",
      lockfileVersion: 3,
      requires: true,
      packages: Map.put(installed, "", root)
    })
  end

  # A package tarball as npm packs one: `package/` and its files, and the
  # integrity a lockfile pins it by.
  defp tarball(files) do
    entries = for {name, bytes} <- files, do: {~c"package/" ++ String.to_charlist(name), bytes}
    path = Path.join(System.tmp_dir!(), "builder-tarball-#{System.unique_integer([:positive])}")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    tgz = File.read!(path)
    File.rm!(path)
    {tgz, "sha512-" <> Base.encode64(:crypto.hash(:sha512, tgz))}
  end

  # Every stage and log line a build reported, oldest first.
  defp collecting do
    {:ok, lines} = Agent.start_link(fn -> [] end)

    {fn stage, message -> Agent.update(lines, &[{stage, message} | &1]) end,
     fn -> Agent.get(lines, &Enum.reverse/1) end}
  end

  describe "toolchains" do
    test "each of the wire's languages reports whether its toolchain is here" do
      toolchains = Builder.available_toolchains()

      assert Map.keys(toolchains) |> Enum.sort() == Enum.sort(BuilderProtocol.languages())
      assert toolchains.rust.command == "cargo-component"
      assert toolchains.javascript.command == "npm"
      assert is_boolean(toolchains.rust.available)
      assert is_boolean(toolchains.javascript.available)

      # What a health answer carries is what the wire reads.
      assert {:ok, line} =
               BuilderProtocol.encode_health(%{release: "0.0.0", toolchains: toolchains})

      assert {:ok, {:health, %{toolchains: ^toolchains}}} = BuilderProtocol.read_line(line)
    end

    test "a language the builder does not speak has no toolchain" do
      refute Builder.toolchain_available?(:python)
      refute Builder.toolchain_available?(:go)
    end
  end

  describe "a request that makes no build is malformed, and nothing runs" do
    test "no sources" do
      assert {:error, {:malformed, "sources name no files"}} = Builder.prepare(rust(%{}))
      assert {:error, {:malformed, _}} = Builder.prepare(tincture(%{}))
    end

    test "a rust build without src/lib.rs, a javascript build without package.json" do
      assert {:error, {:malformed, sentence}} =
               Builder.prepare(rust(%{"src/utils.rs" => "pub fn hello() {}"}))

      assert sentence =~ "src/lib.rs"

      assert {:error, {:malformed, sentence}} =
               Builder.prepare(tincture(%{"src/main.jsx" => "export default function() {}"}))

      assert sentence =~ "package.json"
    end

    test "a javascript build without its lockfile: a tincture builds only from its lockfile" do
      assert {:error, {:malformed, sentence}} =
               Builder.prepare(tincture(%{"package.json" => package(%{})}))

      assert sentence =~ "package-lock.json"
      assert sentence =~ "only from its lockfile"
    end

    test "sources past the wire's bound" do
      big = String.duplicate("x", 600_000)
      max = BuilderProtocol.max_source_bytes()

      assert {:error, {:malformed, sentence}} =
               Builder.prepare(rust(%{"src/lib.rs" => big, "src/utils.rs" => big}))

      assert sentence == "sources total 1200000 bytes; at most #{max} are read"
    end

    test "a source path that leaves the build's directory" do
      sources = %{"src/lib.rs" => "pub fn hello() {}", "../../../../tmp/escape.rs" => "pwned"}

      assert {:error, {:malformed, sentence}} = Builder.prepare(rust(sources))
      assert sentence == "../../../../tmp/escape.rs is not a safe relative path"
    end

    test "a type built from the other language" do
      assert {:error, {:malformed, "a reagent is not built from javascript"}} =
               Builder.prepare(%{
                 language: :javascript,
                 target_type: :reagent,
                 resolve: false,
                 sources: %{"package.json" => "{}"}
               })

      assert {:error, {:malformed, "a tincture is not built from rust"}} =
               Builder.prepare(rust(%{"src/lib.rs" => ""}, %{target_type: :tincture}))
    end
  end

  describe "a toolchain this machine lacks" do
    setup do
      path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")
      on_exit(fn -> System.put_env("PATH", path) end)
    end

    test "is unavailable, in the sentence the wire's vectors carry, and nothing runs" do
      assert {:error, {:unavailable, "the rust toolchain is not installed in this image"}} =
               Builder.prepare(rust(%{"src/lib.rs" => "pub fn hello() {}"}))

      assert {:error, {:unavailable, "the javascript toolchain is not installed in this image"}} =
               build(scripted("true"))
    end
  end

  describe "a configured Cargo seed that is missing" do
    setup do
      Application.put_env(:locus, :cargo_seed, "/nonexistent/cargo-seed")
      on_exit(fn -> Application.delete_env(:locus, :cargo_seed) end)
    end

    @tag :requires_cargo_component
    test "is a broken image: unavailable" do
      assert {:error, {:unavailable, sentence}} =
               Builder.prepare(rust(%{"src/lib.rs" => "pub fn hello() {}"}))

      assert sentence =~ "/nonexistent/cargo-seed/registry"
    end
  end

  describe "a tincture" do
    @describetag :requires_node

    test "builds to the files of its dist, reporting its stages and its log" do
      {on_progress, progress} = collecting()

      script =
        "mkdir -p dist/assets && echo built >&2 && echo hi > dist/index.html && echo js > dist/assets/app.js"

      assert {:ok, built} = build(scripted(script), on_progress: on_progress)

      assert built == %{
               language: :javascript,
               target_type: :tincture,
               outputs: %{"index.html" => "hi\n", "assets/app.js" => "js\n"}
             }

      stages = Enum.map(progress.(), &elem(&1, 0))
      assert Enum.dedup(stages) == [:preparing, :compiling, :output]
      assert Enum.all?(stages, &(&1 in BuilderProtocol.stages()))
      assert {:output, "built"} in progress.()
    end

    test "sends no line for a file of no bytes, which its result names alone, at no bytes" do
      test = self()
      {:ok, place} = Builder.place(%{athanor_id: "ath_builder"})
      script = "mkdir -p dist && : > dist/empty.txt && echo hi > dist/index.html"

      try do
        {:ok, plan} = Builder.prepare(scripted(script))
        assert {:ok, result} = Builder.run(plan, place: place, on_line: &send(test, {:line, &1}))

        assert Enum.sort_by(result.outputs, & &1.path) == [
                 %{path: "empty.txt", size: 0, digest: Prima.Digest.sha256("")},
                 %{path: "index.html", size: 3, digest: Prima.Digest.sha256("hi\n")}
               ]

        assert_received {:line, line}
        assert {:ok, {:output, chunk}} = BuilderProtocol.read_line(line)
        assert %{path: "index.html", seq: 1, bytes: "hi\n"} = chunk
        refute_received {:line, _}

        {:ok, outputs} = BuilderProtocol.output(BuilderProtocol.outputs(), chunk)

        assert BuilderProtocol.outputs(outputs, result) ==
                 {:ok, %{"empty.txt" => "", "index.html" => "hi\n"}}
      after
        Builder.drop(place)
      end
    end

    test "that exits non-zero is failed with its status, its log delivered" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               build(scripted("echo broken >&2; exit 7"), on_progress: on_progress)

      assert is_integer(status) and status != 0
      assert {:output, "broken"} in progress.()
    end

    test "that leaves no dist is failed, and says why" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, 0}}} =
               build(scripted("true"), on_progress: on_progress)

      assert {:compiling, "the build produced no output files in dist/"} in progress.()
    end

    test "whose files pass the wire's count is refused, never cut to fit" do
      {on_progress, progress} = collecting()
      max = BuilderProtocol.max_output_files()

      script =
        "mkdir dist && i=0 && while [ $i -le #{max} ]; do : > dist/f$i; i=$((i+1)); done"

      assert {:error, {:failed, {:status, 0}}} =
               build(scripted(script), on_progress: on_progress)

      assert {:compiling, "the build produced more than #{max} files"} in progress.()
    end

    @tag timeout: 120_000
    test "whose bytes pass the wire's bound is refused, never cut to fit" do
      {on_progress, progress} = collecting()
      max = BuilderProtocol.max_output_bytes()

      script = "mkdir dist && head -c #{max + 1} /dev/zero > dist/big"

      assert {:error, {:failed, {:status, 0}}} =
               build(scripted(script), on_progress: on_progress)

      assert {:validating,
              "the build's outputs total #{max + 1} bytes; at most #{max} are answered"} in progress.()
    end

    @tag timeout: 120_000
    test "whose file is past the bound is refused at its header, before any of its bytes leave" do
      {on_progress, progress} = collecting()
      # Past the wire's bound and within what the executor counts, so the
      # header is what refuses it.
      past = BuilderProtocol.max_output_bytes() + 1_048_576
      test = self()

      script = "mkdir dist && echo small > dist/a && head -c #{past} /dev/zero > dist/big"

      assert {:error, {:failed, {:status, 0}}} =
               build(scripted(script),
                 on_progress: on_progress,
                 on_line: &send(test, {:line, &1})
               )

      assert Enum.any?(progress.(), fn {_stage, message} -> message =~ "outputs total" end)

      # The small file left; nothing of the big one did.
      assert_received {:line, line}
      assert {:ok, {:output, %{path: "a"}}} = BuilderProtocol.read_line(line)
      refute_received {:line, _}
    end

    test "past its budget is a timeout naming the budget" do
      assert {:error, {:timeout, 1_500}} = build(scripted("sleep 60"), timeout_ms: 1_500)
    end

    test "installs from its lockfile alone, and one out of step with its manifest is failed" do
      {tgz, integrity} = tarball(%{"package.json" => ~s({"name":"pinned","version":"1.0.0"})})

      sources = %{
        "package.json" =>
          package(%{
            scripts: %{
              build: "mkdir -p dist && cp node_modules/pinned/package.json dist/pinned.json"
            },
            dependencies: %{pinned: "file:pinned.tgz"}
          }),
        "pinned.tgz" => tgz,
        "package-lock.json" =>
          lockfile(%{pinned: "file:pinned.tgz"}, %{
            "node_modules/pinned" => %{
              version: "1.0.0",
              resolved: "file:pinned.tgz",
              integrity: integrity
            }
          })
      }

      assert {:ok, %{outputs: %{"pinned.json" => pinned}}} = build(tincture(sources))
      assert Jason.decode!(pinned)["version"] == "1.0.0"

      # The manifest asks for a dependency the lockfile does not pin: npm ci
      # refuses rather than resolving it.
      {on_progress, progress} = collecting()

      stale =
        Map.put(
          sources,
          "package.json",
          package(%{
            scripts: %{build: "mkdir -p dist && : > dist/x"},
            dependencies: %{pinned: "file:pinned.tgz", other: "^1.0.0"}
          })
        )

      assert {:error, {:failed, {:status, status}}} =
               build(tincture(stale), on_progress: on_progress)

      assert status != 0

      assert Enum.any?(progress.(), fn {_stage, line} -> line =~ "npm ci" or line =~ "in sync" end)
    end

    test "an install script runs with the build's environment, which holds no credential" do
      System.put_env("LOCUS_BUILDS_KEY", "builder-test-secret-key")
      System.put_env("NPM_TOKEN", "builder-test-npm-token")

      on_exit(fn ->
        System.delete_env("LOCUS_BUILDS_KEY")
        System.delete_env("NPM_TOKEN")
      end)

      build =
        scripted("mkdir -p dist && cp env.txt dist/env.txt", %{postinstall: "env > env.txt"})

      assert {:ok, %{outputs: %{"env.txt" => env}}} = build(build)

      names =
        env |> String.split("\n", trim: true) |> Enum.map(&hd(String.split(&1, "=", parts: 2)))

      # The install script ran, under the build's own home.
      assert "HOME" in names
      refute env =~ "builder-test-secret-key"
      refute env =~ "builder-test-npm-token"
      refute Enum.any?(names, &(&1 =~ ~r/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i))
    end

    test "keeps the notices of the runtime packages it ships" do
      {tgz, integrity} =
        tarball(%{
          "package.json" => ~s({"name":"noticed","version":"2.1.0","license":"MIT"}),
          "LICENSE" => "MIT License, noticed's authors\n",
          "index.js" => "module.exports = 1;\n"
        })

      sources = %{
        "package.json" =>
          package(%{
            scripts: %{build: "mkdir -p dist && echo hi > dist/index.html"},
            dependencies: %{noticed: "file:noticed.tgz"}
          }),
        "noticed.tgz" => tgz,
        "package-lock.json" =>
          lockfile(%{noticed: "file:noticed.tgz"}, %{
            "node_modules/noticed" => %{
              version: "2.1.0",
              resolved: "file:noticed.tgz",
              integrity: integrity,
              license: "MIT"
            }
          })
      }

      assert {:ok, %{outputs: %{"third-party-notices.json" => notices}}} =
               build(tincture(sources))

      assert [
               %{
                 "name" => "noticed",
                 "version" => "2.1.0",
                 "license" => "MIT",
                 "notices" => files
               }
             ] =
               Jason.decode!(notices)

      assert files == [%{"file" => "LICENSE", "text" => "MIT License, noticed's authors\n"}]
    end

    test "that ships no package writes no notices" do
      assert {:ok, %{outputs: outputs}} =
               build(scripted("mkdir -p dist && echo hi > dist/index.html"))

      refute Map.has_key?(outputs, "third-party-notices.json")
    end
  end

  describe "a rust component" do
    @describetag :requires_cargo_component
    @describetag timeout: 900_000

    @lib_rs """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::reagent::compute::Guest;

    struct MyReagent;
    bindings::export!(MyReagent with_types_in bindings);

    impl Guest for MyReagent {
        fn compute(input: String) -> String {
            input
        }
    }
    """

    test "builds to a validated component and the lock it resolved, and builds locked to it" do
      {on_progress, progress} = collecting()

      assert {:ok, %{language: :rust, target_type: :reagent, outputs: outputs}} =
               build(rust(%{"src/lib.rs" => @lib_rs}), on_progress: on_progress)

      wasm = BuilderProtocol.component_wasm()
      lock = BuilderProtocol.component_lockfile()
      assert Map.keys(outputs) |> Enum.sort() == Enum.sort([wasm, lock])
      assert {:ok, _} = Prima.Wasm.validate(outputs[wasm])
      assert outputs[lock] =~ ~s(name = "wit-bindgen-rt")

      assert Enum.dedup(Enum.map(progress.(), &elem(&1, 0))) --
               [:preparing, :compiling, :output, :validating] == []

      assert {:validating, "Validating WASM binary..."} in progress.()

      # A dependency the lock does not cover fails with cargo's own message;
      # `resolve` resolves afresh.
      cargo_toml =
        :reagent
        |> Builder.cargo_toml_for()
        |> String.replace("[dependencies]\n", "[dependencies]\nsmallvec = \"1\"\n")

      sources = %{
        "src/lib.rs" => @lib_rs,
        "Cargo.toml" => cargo_toml,
        "Cargo.lock" => outputs[lock]
      }

      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               build(rust(sources), on_progress: on_progress)

      assert status != 0
      assert Enum.any?(progress.(), fn {_stage, message} -> message =~ "--locked" end)

      assert {:ok, %{outputs: resolved}} = build(rust(sources, %{resolve: true}))
      assert resolved[lock] =~ ~s(name = "smallvec")
    end

    test "that does not compile is failed with cargo's status and its log" do
      {on_progress, progress} = collecting()

      assert {:error, {:failed, {:status, status}}} =
               build(rust(%{"src/lib.rs" => "this is not valid rust code at all!!"}),
                 on_progress: on_progress
               )

      assert status != 0
      assert Enum.any?(progress.(), fn {stage, _message} -> stage == :output end)
    end
  end
end
