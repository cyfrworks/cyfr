# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds.ClientTest do
  @moduledoc """
  What this server asks of the builds service and what it accepts back,
  against `Cyfr.Test.ScriptedBuilder`.

  The builder's answer is untrusted input: every way it can end has an
  outcome of its own, a result is verified before it is answered, and its
  digest, size and exports are derived here from the bytes read.
  """
  # The builds service is application configuration and the scripted
  # builder one named process.
  use ExUnit.Case, async: false

  alias Compendium.Builds.Client
  alias Cyfr.BuilderProtocol
  alias Cyfr.Test.ScriptedBuilder

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @fixture ScriptedBuilder.fixture()
  @athanor "ath_01a09fee-045b-770b-b745-a62792bb8798"
  @sources %{"Cargo.toml" => "[package]\n", "src/lib.rs" => "// a reagent\n"}

  setup do
    ScriptedBuilder.start!()
    :ok
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{athanor_id: @athanor, target_type: :reagent, resolve: false, sources: @sources},
      overrides
    )
  end

  defp build(request \\ request(), opts \\ []) do
    Client.build(request, Keyword.put_new(opts, :deadline, now() + 60_000))
  end

  defp now, do: System.system_time(:millisecond)

  defp component(outputs \\ %{}, diagnostics \\ []) do
    %{
      language: :rust,
      target_type: :reagent,
      outputs: Map.merge(%{"component.wasm" => @wasm}, outputs),
      diagnostics: diagnostics
    }
  end

  defp tincture(outputs) do
    %{language: :javascript, target_type: :tincture, outputs: outputs, diagnostics: []}
  end

  describe "the request" do
    test "is signed under the service's key and carries the build as the protocol reads it" do
      ScriptedBuilder.script([{:stream, [{:result, component()}]}])
      deadline = now() + 60_000

      assert {:ok, _built} =
               Client.build(request(%{resolve: true}), deadline: deadline)

      # Verified and read by the builder with `Cyfr.BuilderProtocol`.
      assert [read] = ScriptedBuilder.requests()

      assert read == %{
               athanor_id: @athanor,
               language: :rust,
               target_type: :reagent,
               resolve: true,
               deadline: deadline,
               sources: @sources
             }
    end

    test "of the vectors' fields is the vectors' body, under a header their request key verifies" do
      vector = @fixture["request"]
      fields = vector["fields"]
      sources = Map.new(fields["sources"], fn {path, b64} -> {path, Base.decode64!(b64)} end)
      ScriptedBuilder.script([{:stream, [{:result, component()}]}])

      # The vector's deadline is long past, which the builder here does not
      # hold a build to; the grace keeps the request open for its answer.
      assert {:ok, _built} =
               Client.build(
                 %{
                   athanor_id: fields["athanor_id"],
                   target_type: String.to_existing_atom(fields["target_type"]),
                   resolve: fields["resolve"],
                   sources: sources
                 },
                 deadline: fields["deadline"],
                 grace_ms: 30_000
               )

      # The builder verified the header with the vectors' own request key,
      # which this client can only have derived from the service key.
      assert ScriptedBuilder.bodies() == [vector["body"]]
    end

    test "a tincture is asked for as javascript" do
      ScriptedBuilder.script([{:stream, [{:result, tincture(%{"index.html" => "<p>hi</p>"})}]}])

      assert {:ok, _built} =
               build(request(%{target_type: :tincture, sources: %{"package.json" => "{}"}}))

      assert [%{language: :javascript, target_type: :tincture}] = ScriptedBuilder.requests()
    end

    test "sources past a bound of the protocol, or unsafely named, are refused before anything is sent" do
      oversized = %{"src/lib.rs" => String.duplicate("x", BuilderProtocol.max_source_bytes() + 1)}

      assert {:error, {:sources, {:too_large, :sources, _bytes, _max}}} =
               build(request(%{sources: oversized}))

      assert {:error, {:sources, {:unsafe_path, "../lib.rs"}}} =
               build(request(%{sources: %{"../lib.rs" => "x"}}))

      assert {:error, {:sources, {:invalid_field, "sources"}}} = build(request(%{sources: %{}}))
      assert ScriptedBuilder.requests() == []
    end
  end

  describe "a result" do
    test "has its digest, size and exports derived from the bytes, and keeps the build's lock" do
      {:ok, real} = Compendium.WasmValidator.validate(@wasm)
      lock = "version = 4\n"

      ScriptedBuilder.script([
        {:stream, [{:result, component(%{"Cargo.lock" => lock}, ["output: Finished"])}]}
      ])

      assert {:ok, built} = build()
      assert built.wasm_bytes == @wasm
      assert built.digest == real.digest
      assert built.size == real.size
      assert built.exports == real.exports
      assert built.lockfile == lock
      assert built.language == "rust"
      assert built.target_type == "reagent"
      assert built.diagnostics == ["output: Finished"]
    end

    test "of a component build that left no lock keeps none" do
      ScriptedBuilder.script([{:stream, [{:result, component()}]}])
      assert {:ok, %{lockfile: nil}} = build()
    end

    test "of a tincture is its files, digested as the file set registration digests" do
      files = %{"index.html" => "<p>hi</p>", "assets/app.js" => "console.log(1)"}
      ScriptedBuilder.script([{:stream, [{:result, tincture(files)}]}])

      assert {:ok, built} = build(request(%{target_type: :tincture}))
      assert built.output_files == files
      assert {built.digest, built.size} == Cyfr.Digest.file_set(files)
      assert built.exports == []
      assert built.target_type == "tincture"
    end

    test "the vectors' result lines are read as the builds they spell" do
      for {name, type} <- [{"component_result", :reagent}, {"tincture_result", :tincture}] do
        vector = @fixture["lines"][name]
        ScriptedBuilder.script([{:stream, [{:line, vector["body"]}]}])

        assert {:ok, built} = build(request(%{target_type: type}))
        assert built.diagnostics == vector["diagnostics"]
        outputs = Map.new(vector["outputs"], fn {path, b64} -> {path, Base.decode64!(b64)} end)

        case type do
          :reagent ->
            assert built.wasm_bytes == outputs["component.wasm"]
            assert built.lockfile == outputs["Cargo.lock"]

          :tincture ->
            assert built.output_files == outputs
        end
      end
    end

    test "whose bytes are not a component is refused" do
      ScriptedBuilder.script([
        {:stream, [{:result, component(%{"component.wasm" => "not wasm"})}]}
      ])

      assert {:error, {:malformed, {:invalid_wasm, _reason}}} = build()
    end

    test "whose lock is past what a build's sources may carry is refused" do
      lock = String.duplicate("x", BuilderProtocol.max_source_bytes() + 1)
      ScriptedBuilder.script([{:stream, [{:result, component(%{"Cargo.lock" => lock})}]}])

      assert {:error, {:malformed, {:lockfile_too_large, _size, _max}}} = build()
    end

    test "of another language or type than the one asked for is refused" do
      ScriptedBuilder.script([
        {:stream, [{:result, tincture(%{"index.html" => "<p>hi</p>"})}]},
        {:stream, [{:result, %{component() | target_type: :catalyst}}]}
      ])

      assert {:error, {:malformed, {:another_build, :javascript, :tincture}}} = build()
      assert {:error, {:malformed, {:another_build, :rust, :catalyst}}} = build()
    end

    test "whose digest is not its bytes', whose path escapes or whose outputs pass a bound is refused" do
      vectors = Map.new(@fixture["invalid_lines"], &{&1["name"], &1})

      for {name, error} <- [
            {"result_tampered_bytes", :digest_mismatch},
            {"result_tampered_digest", :digest_mismatch},
            {"result_unsafe_path", :unsafe_path},
            {"result_duplicate_path", :duplicate_path},
            {"component_with_extra_output", :invalid_field}
          ] do
        ScriptedBuilder.script([{:stream, [{:line, vectors[name]["body"]}]}])
        assert {:error, {:malformed, reason}} = build(request(%{target_type: :tincture}))
        assert elem(reason, 0) == error, "#{name} ended as #{inspect(reason)}"
      end

      # One file more than a result may carry, and one byte more.
      too_many = for n <- 1..(BuilderProtocol.max_output_files() + 1), do: {"f#{n}.txt", "x"}
      ScriptedBuilder.script([{:stream, [{:line, result_line(too_many)}]}])

      assert {:error, {:malformed, {:too_many, :outputs, _count, _max}}} =
               build(request(%{target_type: :tincture}))

      too_large = [{"big.bin", :binary.copy("x", BuilderProtocol.max_output_bytes() + 1)}]
      ScriptedBuilder.script([{:stream, [{:line, result_line(too_large)}]}])

      assert {:error, {:malformed, {:too_large, :outputs, _bytes, _max}}} =
               build(request(%{target_type: :tincture}))
    end
  end

  # A tincture result line written without the protocol's own checks, so a
  # line its encoder would refuse can be answered.
  defp result_line(files) do
    Jason.encode!(%{
      "version" => BuilderProtocol.version(),
      "type" => "result",
      "language" => "javascript",
      "target_type" => "tincture",
      "diagnostics" => [],
      "outputs" =>
        for {path, bytes} <- files do
          %{
            "path" => path,
            "base64" => Base.encode64(bytes),
            "digest" => Cyfr.Digest.sha256(bytes)
          }
        end
    })
  end

  describe "a refusal" do
    @refusals [
      {:capacity, 2},
      {:timeout, 270_000},
      {:memory, 1_073_741_824},
      {:unavailable, "the rust toolchain is not installed in this image"},
      {:failed, {:status, 101}},
      {:failed, {:signal, "KILL"}},
      {:malformed, "sources[1].base64 is not of the form this message takes"},
      {:unauthorized, :replayed}
    ]

    test "of each class is its own outcome, before the stream and as the terminal line" do
      diagnostics = ["output: error[E0425]: cannot find value `x` in this scope"]

      for refusal <- @refusals do
        ScriptedBuilder.script([
          {:refuse, refusal, diagnostics},
          {:stream, [{:progress, :compiling, "Compiling…"}, {:refusal, refusal, diagnostics}]}
        ])

        assert {:error, {:refused, ^refusal, ^diagnostics}} = build()
        assert {:error, {:refused, ^refusal, ^diagnostics}} = build()
      end
    end

    test "is read from the vectors' lines at the statuses the protocol names" do
      for vector <- @fixture["lines"]["refusals"], vector["class"] != "protocol_mismatch" do
        status = @fixture["statuses"][vector["class"]]
        ScriptedBuilder.script([{:respond, status, vector["body"]}])

        assert {:error, {:refused, refusal, diagnostics}} = build()
        assert Atom.to_string(elem(refusal, 0)) == vector["class"]
        assert diagnostics == vector["diagnostics"]
        assert BuilderProtocol.describe_refusal(refusal) == vector["sentence"]
      end
    end

    test "memory carries the bound the build was ended at" do
      ScriptedBuilder.script([{:refuse, {:memory, 1_073_741_824}}])
      assert {:error, {:refused, {:memory, 1_073_741_824}, []}} = build()
    end
  end

  describe "the builder's key" do
    test "another key than the service's is refused by the builder as unauthorized" do
      ScriptedBuilder.configure!(ScriptedBuilder.url(), :crypto.strong_rand_bytes(32))
      ScriptedBuilder.script([{:stream, [{:result, component()}]}])

      assert {:error, {:refused, {:unauthorized, :bad_mac}, []}} = build()
      # Refused on its header: the builder read no request.
      assert ScriptedBuilder.requests() == []
    end

    test "without a URL or without a key nothing is asked" do
      for {url, key} <- [
            {nil, ScriptedBuilder.key()},
            {ScriptedBuilder.url(), nil},
            {nil, nil},
            {ScriptedBuilder.url(), "not thirty-two bytes"}
          ] do
        ScriptedBuilder.configure!(url, key)
        assert {:error, :not_configured} = build()
        assert {:error, :not_configured} = Client.toolchains()
      end

      assert ScriptedBuilder.requests() == []
    end
  end

  describe "another version of the protocol" do
    test "is a mismatch naming both ends, by the builder's refusal or by the version of its lines" do
      [refused | _] =
        Enum.filter(@fixture["lines"]["refusals"], &(&1["class"] == "protocol_mismatch"))

      progress = %{"version" => 2, "type" => "progress", "stage" => "compiling", "message" => "…"}

      ScriptedBuilder.script([
        {:respond, 409, refused["body"]},
        {:stream, [{:line, Jason.encode!(progress)}, {:result, component()}]}
      ])

      assert {:error, {:protocol_mismatch, 1, 2}} = build()
      assert {:error, {:protocol_mismatch, 2, 1}} = build()
    end
  end

  describe "an answer that is not the protocol's" do
    test "ending without a terminal line is a disconnect, whether it ends or is cut" do
      ScriptedBuilder.script([
        {:stream, []},
        {:stream, [{:progress, :compiling, "Compiling…"}]},
        {:stream, [{:progress, :compiling, "Compiling…"}, :drop]},
        {:stream, [{:bytes, ~s({"version":1,"type":"resu)}, :drop]}
      ])

      for _ <- 1..4, do: assert({:error, :disconnected} = build())
    end

    test "a terminal line after garbage is not believed" do
      ScriptedBuilder.script([
        {:stream, [{:line, "<html>502 Bad Gateway</html>"}, {:result, component()}]},
        {:stream, [{:line, ~s({"type":"progress"})}, {:result, component()}]},
        {:stream, [{:line, ""}, {:result, component()}]}
      ])

      assert {:error, {:malformed, :not_json}} = build()
      assert {:error, {:malformed, {:version, nil}}} = build()
      assert {:error, {:malformed, :not_json}} = build()
    end

    test "a health line where a build's lines belong is refused" do
      ScriptedBuilder.script([{:stream, [{:line, @fixture["lines"]["health"]["body"]}]}])
      assert {:error, {:malformed, :unexpected_line}} = build()
    end

    test "another server's page is named by its status" do
      ScriptedBuilder.script([
        {:respond, 502, "<html>Bad Gateway</html>"},
        {:respond, 503, ""}
      ])

      assert {:error, {:malformed, {:status, 502}}} = build()
      assert {:error, {:malformed, {:status, 503}}} = build()
    end

    test "a progress line past the line bound is refused" do
      message = String.duplicate("x", BuilderProtocol.max_line_bytes() + 1)

      line =
        Jason.encode!(%{
          "version" => 1,
          "type" => "progress",
          "stage" => "output",
          "message" => message
        })

      ScriptedBuilder.script([{:stream, [{:line, line}, {:result, component()}]}])
      max = BuilderProtocol.max_line_bytes()
      assert {:error, {:malformed, {:too_large, :line, _bytes, ^max}}} = build()
    end

    test "an answer past the response bound is ended there" do
      mebibyte = :binary.copy("x", 1_048_576)
      times = div(BuilderProtocol.max_response_bytes(), 1_048_576) + 2
      ScriptedBuilder.script([{:stream, [{:repeat, mebibyte, times}, {:result, component()}]}])

      max = BuilderProtocol.max_response_bytes()
      assert {:error, {:malformed, {:response_too_large, seen, ^max}}} = build()
      assert seen > max
    end

    test "the response bound holds across lines, not for each" do
      # Progress lines that each read, together past the bound.
      message = String.duplicate("x", BuilderProtocol.max_line_bytes())
      {:ok, line} = BuilderProtocol.encode_progress(:output, message)
      times = div(BuilderProtocol.max_response_bytes(), byte_size(line)) + 2

      ScriptedBuilder.script([
        {:stream, [{:repeat, line <> "\n", times}, {:result, component()}]}
      ])

      assert {:error, {:malformed, {:response_too_large, _seen, _max}}} = build()
    end
  end

  describe "progress" do
    test "reaches the caller's function line by line, in the order the builder wrote it" do
      test = self()

      ScriptedBuilder.script([
        {:stream,
         [
           {:progress, :preparing, "Preparing source files..."},
           {:hold, test},
           {:progress, :compiling, "Compiling reagent (rust)..."},
           {:progress, :output, "   Compiling vector v0.1.0"},
           {:progress, :validating, "Validating WASM binary..."},
           {:result, component()}
         ]}
      ])

      task =
        Task.async(fn ->
          build(request(), on_progress: &send(test, {:progress, &1, &2}))
        end)

      # The first line is delivered while the answer is still open.
      assert_receive {:scripted_builder, :holding, handler}, 5_000
      assert_receive {:progress, :preparing, "Preparing source files..."}, 5_000
      refute_received {:progress, :compiling, _}
      send(handler, :continue)

      assert {:ok, _built} = Task.await(task, 10_000)
      assert_received {:progress, :compiling, "Compiling reagent (rust)..."}
      assert_received {:progress, :output, "   Compiling vector v0.1.0"}
      assert_received {:progress, :validating, "Validating WASM binary..."}
    end
  end

  describe "a deadline" do
    test "passing while the answer is open ends the request, which the builder sees close" do
      ScriptedBuilder.script([{:stream, [{:progress, :compiling, "…"}, {:hold, self()}]}])

      assert {:error, :deadline} = build(request(), deadline: now() + 150, grace_ms: 50)
      assert_receive {:scripted_builder, :holding, _handler}, 5_000
      assert_receive {:scripted_builder, :disconnected}, 5_000
    end

    test "is waited past for the builder's own timeout, which carries the build's log" do
      test = self()
      log = ["output:    Compiling vector v0.1.0"]

      ScriptedBuilder.script([{:stream, [{:hold, test}, {:refusal, {:timeout, 100}, log}]}])
      task = Task.async(fn -> build(request(), deadline: now() + 100, grace_ms: 30_000) end)

      assert_receive {:scripted_builder, :holding, handler}, 5_000
      # The deadline has passed by the time the builder answers.
      Cyfr.Test.Wait.wait_until(fn -> now() > hd(ScriptedBuilder.requests()).deadline end)
      send(handler, :continue)

      assert {:error, {:refused, {:timeout, 100}, ^log}} = Task.await(task, 10_000)
    end
  end

  describe "a caller that goes away" do
    test "killed while the answer is open, takes the request with it and the builder sees it close" do
      test = self()
      ScriptedBuilder.script([{:stream, [{:progress, :compiling, "…"}, {:hold, test}]}])

      caller =
        spawn(fn ->
          send(test, {:answered, build(request(), on_progress: &send(test, {:progress, &1, &2}))})
        end)

      assert_receive {:scripted_builder, :holding, _handler}, 5_000
      assert_receive {:progress, :compiling, "…"}, 5_000
      [request_process] = Task.Supervisor.children(Compendium.Builds.TaskSupervisor)
      ref = Process.monitor(request_process)

      # What a cancelled or timed-out tool call does to its handler.
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^request_process, _reason}, 5_000
      assert_receive {:scripted_builder, :disconnected}, 5_000
      refute_received {:answered, _}
    end
  end

  describe "a builder that cannot be reached" do
    @tag :capture_log
    test "is unreachable: nothing was asked" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      ScriptedBuilder.configure!("http://127.0.0.1:#{port}", ScriptedBuilder.key())

      assert {:error, :unreachable} = build()
      assert {:error, :unreachable} = Client.toolchains()
    end
  end

  describe "toolchains/0" do
    test "answers what the builder's health line reports, by language" do
      assert {:ok, toolchains} = Client.toolchains()
      vector = @fixture["lines"]["health"]["toolchains"]

      for language <- BuilderProtocol.languages() do
        reported = vector[Atom.to_string(language)]

        assert toolchains[language] == %{
                 available: reported["available"],
                 command: reported["command"],
                 description: reported["description"]
               }
      end
    end

    test "a health line of another version is a mismatch; one that does not read is malformed" do
      health = Jason.decode!(@fixture["lines"]["health"]["body"])

      ScriptedBuilder.health({:line, Jason.encode!(%{health | "version" => 2})})
      assert {:error, {:protocol_mismatch, 2, 1}} = Client.toolchains()

      ScriptedBuilder.health({:line, Jason.encode!(Map.delete(health, "toolchains"))})
      assert {:error, {:malformed, {:missing_field, "toolchains"}}} = Client.toolchains()

      ScriptedBuilder.health({:line, @fixture["lines"]["progress"]["body"]})
      assert {:error, {:malformed, :unexpected_line}} = Client.toolchains()
    end
  end
end
