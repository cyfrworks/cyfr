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
  alias Prima.BuilderProtocol
  alias Cyfr.Test.ScriptedBuilder

  @wasm Cyfr.Test.Guests.wasm(:reagent)
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

  # Progress lines of quotes, each escaping to twice its bytes, charged as
  # a builder charges them until they fill the log to its last byte: the
  # steps that stream them, the log a person reads of them, and the bytes
  # streamed.
  defp full_log do
    max_log = BuilderProtocol.max_log_bytes()
    {:ok, empty} = BuilderProtocol.encode_progress(:output, "")
    unit = byte_size(empty) + 1
    long = String.duplicate(~s("), 30_000)
    count = div(max_log, unit + 60_000)
    last = String.duplicate("a", max_log - count * (unit + 60_000) - unit)
    messages = List.duplicate(long, count) ++ [last]

    lines =
      Enum.map(messages, fn message ->
        {:ok, line} = BuilderProtocol.encode_progress(:output, message)
        line
      end)

    streamed = Enum.reduce(lines, 0, &(byte_size(&1) + 1 + &2))
    assert streamed == max_log

    diagnostics = Enum.map(messages, &BuilderProtocol.diagnostic(:output, &1))

    {Enum.map(lines, &{:line, &1}), diagnostics, streamed}
  end

  # `total` bytes over the protocol's most files, each named at the longest
  # path an output may take, of quotes, which escape to two bytes each.
  defp largest_outputs(total) do
    files = BuilderProtocol.max_output_files()
    path_bytes = BuilderProtocol.max_output_path_bytes()
    quotes = String.duplicate(~s("), 240)

    for index <- 0..(files - 1), into: %{} do
      stem = Enum.join([quotes, quotes, quotes, quotes, Integer.to_string(index)], "/")
      path = stem <> String.duplicate(~s("), path_bytes - byte_size(stem))
      size = div(total, files) + if(index < rem(total, files), do: 1, else: 0)
      {path, :binary.copy(<<rem(index, 256)>>, size)}
    end
  end

  describe "the request" do
    test "is signed under the service's key and carries the build as the protocol reads it" do
      ScriptedBuilder.script([{:stream, [{:result, component()}]}])
      deadline = now() + 60_000

      assert {:ok, _built} =
               Client.build(request(%{resolve: true}), deadline: deadline)

      # Verified and read by the builder with `Prima.BuilderProtocol`.
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
      {:ok, real} = Prima.Wasm.validate(@wasm)
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
      assert {built.digest, built.size} == Prima.Digest.file_set(files)
      assert built.exports == []
      assert built.target_type == "tincture"
    end

    test "the vectors' streams are read as the builds they spell, or refused with their error" do
      for %{"name" => name} = vector <- @fixture["lines"]["streams"], vector["lines"] do
        type =
          if Enum.any?(vector["lines"], &(&1 =~ "component.wasm")), do: :reagent, else: :tincture

        ScriptedBuilder.script([{:stream, Enum.map(vector["lines"], &{:line, &1})}])
        answered = build(request(%{target_type: type}))

        case vector do
          %{"outputs" => outputs, "diagnostics" => diagnostics} ->
            assert {:ok, built} = answered, name
            assert built.diagnostics == diagnostics, name
            outputs = Map.new(outputs, fn {path, b64} -> {path, Base.decode64!(b64)} end)

            case type do
              :reagent ->
                assert built.wasm_bytes == outputs["component.wasm"], name
                assert built.lockfile == outputs["Cargo.lock"], name

              :tincture ->
                assert built.output_files == outputs, name
            end

          %{"refusal" => %{"class" => class}} ->
            assert {:error, {:refused, refusal, []}} = answered, name
            assert Atom.to_string(elem(refusal, 0)) == class

          %{"error" => error} ->
            assert {:error, {:malformed, reason}} = answered, name
            assert Atom.to_string(elem(reason, 0)) == error, "#{name} ended as #{inspect(reason)}"
        end
      end
    end

    test "ends the answer: the line after it is not read, and the connection is closed at once" do
      %{"lines" => lines, "outputs" => outputs} =
        Enum.find(@fixture["lines"]["streams"], &(&1["name"] == "output_after_result"))

      ScriptedBuilder.script([
        {:stream, [{:bytes, Enum.map(lines, &[&1, "\n"])}, {:hold, self()}]}
      ])

      # The deadline is a minute away, so a close within seconds is the
      # reader's own.
      assert {:ok, built} = build(request(%{target_type: :tincture}), deadline: now() + 60_000)

      assert built.output_files ==
               Map.new(outputs, fn {path, b64} -> {path, Base.decode64!(b64)} end)

      assert_receive {:scripted_builder, :holding, _handler}, 5_000
      assert_receive {:scripted_builder, :disconnected}, 5_000
    end

    test "a person reads the build's log as its terminal line carried it before: its progress lines, in order" do
      %{"lines" => lines} = Enum.find(@fixture["lines"]["streams"], &(&1["name"] == "component"))
      ScriptedBuilder.script([{:stream, Enum.map(lines, &{:line, &1})}])

      assert {:ok, built} = build()

      assert built.diagnostics == [
               "compiling: Compiling reagent (rust)...",
               "output: Finished `release` profile [optimized] target(s) in 4.20s"
             ]
    end

    test "chunks then a refusal save nothing, and nor does an answer that ends after its chunks" do
      %{"lines" => lines} = Enum.find(@fixture["lines"]["streams"], &(&1["name"] == "tincture"))
      chunks = lines |> Enum.drop(-1) |> Enum.map(&{:line, &1})

      ScriptedBuilder.script([
        {:stream, chunks ++ [{:refusal, {:failed, {:status, 2}}, ["output: tsc: error"]}]},
        {:stream, chunks},
        {:stream, chunks ++ [:drop]}
      ])

      request = request(%{target_type: :tincture})

      assert {:error, {:refused, {:failed, {:status, 2}}, ["output: tsc: error"]}} =
               build(request)

      assert {:error, :disconnected} = build(request)
      assert {:error, :disconnected} = build(request)
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

    test "whose path escapes, is named twice, or names other outputs, or whose outputs pass a bound, is refused" do
      vectors = Map.new(@fixture["invalid_lines"], &{&1["name"], &1})

      for {name, error} <- [
            {"result_unsafe_path", :unsafe_path},
            {"result_duplicate_path", :duplicate_path},
            {"output_unsafe_path", :unsafe_path},
            {"component_with_extra_output", :invalid_field}
          ] do
        ScriptedBuilder.script([{:stream, [{:line, vectors[name]["body"]}]}])
        assert {:error, {:malformed, reason}} = build(request(%{target_type: :tincture}))
        assert elem(reason, 0) == error, "#{name} ended as #{inspect(reason)}"
      end

      # One file more than a result may carry, as output lines.
      too_many =
        for seq <- 1..(BuilderProtocol.max_output_files() + 1) do
          {:ok, line} = BuilderProtocol.encode_output("f#{seq}.txt", seq, "x")
          {:line, line}
        end

      ScriptedBuilder.script([{:stream, too_many}])

      assert {:error, {:malformed, {:too_many, :outputs, _count, _max}}} =
               build(request(%{target_type: :tincture}))
    end
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

        # The log is the progress lines streamed before the refusal.
        streamed = ["compiling: Compiling…" | diagnostics]
        assert {:error, {:refused, ^refusal, ^streamed}} = build()
      end
    end

    test "is read from the vectors' lines at the statuses the protocol names" do
      for vector <- @fixture["lines"]["refusals"], vector["class"] != "protocol_mismatch" do
        status = @fixture["statuses"][vector["class"]]
        ScriptedBuilder.script([{:respond, status, vector["body"]}])

        assert {:error, {:refused, refusal, []}} = build()
        assert Atom.to_string(elem(refusal, 0)) == vector["class"]
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

      progress = %{"version" => 1, "type" => "progress", "stage" => "compiling", "message" => "…"}
      %{"builder" => builder, "client" => client} = refused["reason"]

      ScriptedBuilder.script([
        {:respond, 409, refused["body"]},
        {:stream, [{:line, Jason.encode!(progress)}, {:result, component()}]}
      ])

      assert {:error, {:protocol_mismatch, ^builder, ^client}} = build()
      assert {:error, {:protocol_mismatch, 1, 2}} = build()
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
          "version" => BuilderProtocol.version(),
          "type" => "progress",
          "stage" => "output",
          "message" => message
        })

      ScriptedBuilder.script([{:stream, [{:line, line}, {:result, component()}]}])
      max = BuilderProtocol.max_line_bytes()
      assert {:error, {:malformed, {:too_large, :line, _bytes, ^max}}} = build()
    end

    test "a line past the bound of any line is ended there" do
      mebibyte = :binary.copy("x", 1_048_576)
      times = div(BuilderProtocol.max_line_size(), 1_048_576) + 2
      ScriptedBuilder.script([{:stream, [{:repeat, mebibyte, times}, {:result, component()}]}])

      max = BuilderProtocol.max_line_size()
      assert {:error, {:malformed, {:response_too_large, seen, ^max}}} = build()
      assert seen > max
    end

    test "a log past the bound the builder charges is refused, and one at it is read" do
      {progress, diagnostics, _streamed} = full_log()
      {:ok, one_more} = BuilderProtocol.encode_progress(:output, "a")

      ScriptedBuilder.script([
        {:stream, progress ++ [{:result, component()}]},
        {:stream, progress ++ [{:line, one_more}, {:result, component()}]}
      ])

      assert {:ok, built} = build()
      assert built.diagnostics == diagnostics

      max = BuilderProtocol.max_log_bytes()
      assert {:error, {:malformed, {:too_large, :log, _bytes, ^max}}} = build()
    end

    test "the largest answer the protocol allows is read whole" do
      {progress, diagnostics, _streamed} = full_log()
      outputs = largest_outputs(BuilderProtocol.max_output_bytes())

      result = %{language: :javascript, target_type: :tincture, outputs: outputs}
      ScriptedBuilder.script([{:stream, progress ++ [{:result, result}]}])
      test = self()

      assert {:ok, built} =
               build(request(%{target_type: :tincture, sources: %{"package.json" => "{}"}}),
                 on_progress: fn _stage, _message -> send(test, :progress) end
               )

      assert built.output_files == outputs
      for _line <- progress, do: assert_received(:progress)
      assert built.diagnostics == diagnostics
    end

    test "one byte of output past the bound is refused, bounded and typed" do
      max = BuilderProtocol.max_output_bytes()
      chunk = :binary.copy(<<0>>, BuilderProtocol.max_chunk_bytes())
      chunks = div(max, byte_size(chunk)) + 1

      # No writer of the protocol sends past the bound; the lines are
      # spelled here, each within its own.
      lines =
        for seq <- 1..chunks do
          {:ok, line} = BuilderProtocol.encode_output("big.bin", seq, chunk)
          {:line, line}
        end

      ScriptedBuilder.script([{:stream, lines}])

      assert {:error, {:malformed, {:too_large, :outputs, over, ^max}}} =
               build(request(%{target_type: :tincture, sources: %{"package.json" => "{}"}}))

      assert over > max
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
      Prima.Test.Wait.wait_until(fn -> now() > hd(ScriptedBuilder.requests()).deadline end)
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

      ScriptedBuilder.health({:line, Jason.encode!(%{health | "version" => 1})})
      assert {:error, {:protocol_mismatch, 1, 2}} = Client.toolchains()

      ScriptedBuilder.health({:line, Jason.encode!(Map.delete(health, "toolchains"))})
      assert {:error, {:malformed, {:missing_field, "toolchains"}}} = Client.toolchains()

      ScriptedBuilder.health({:line, @fixture["lines"]["progress"]["body"]})
      assert {:error, {:malformed, :unexpected_line}} = Client.toolchains()
    end
  end
end
