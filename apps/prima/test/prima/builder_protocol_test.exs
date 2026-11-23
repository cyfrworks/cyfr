# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BuilderProtocolTest do
  @moduledoc """
  The build wire reproduces every shared vector
  (`tests/fixtures/locus_builds.json`): the protocol's data, the request
  key derived over the service label, the request's canonical string, MAC
  and header, every line and refusal read to its fields and written back
  to its body, every invalid body refused with its error, and every
  rejected header refused with its reason, and every stream of lines read
  to the files and diagnostics a reader keeps, or refused with its error.
  Beyond the vectors: a request is bounded on its declared size before any
  MAC work and on its encoded sources before any decoding; every refusal
  class round-trips; a header for another Locus service, or under its key,
  never verifies as builds; and header-first verification refuses exactly
  what the one-step verifier refuses; an output's path is bounded on its
  own bytes; a running digest is the whole file's; and the lines' bounds
  are the vectors' numbers, derived term by term from the other bounds.
  """
  use ExUnit.Case, async: true

  alias Prima.{BuilderProtocol, MacEnvelope}

  @vectors Path.expand("../../../../tests/fixtures/locus_builds.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @athanor "ath_01a09fee-045b-770b-b745-a62792bb8798"
  @now 1_789_305_249_602

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp unhex(text), do: Base.decode16!(text, case: :lower)
  defp files(map), do: Map.new(map, fn {path, b64} -> {path, Base.decode64!(b64)} end)
  defp tag(error) when is_tuple(error), do: elem(error, 0)
  defp tag(error) when is_atom(error), do: error
  defp key, do: unhex(@vectors["key_hex"])
  defp request_key, do: unhex(@vectors["request_key_hex"])

  defp request do
    f = @vectors["request"]["fields"]

    %{
      athanor_id: f["athanor_id"],
      language: String.to_existing_atom(f["language"]),
      target_type: String.to_existing_atom(f["target_type"]),
      resolve: f["resolve"],
      deadline: f["deadline"],
      sources: files(f["sources"])
    }
  end

  defp result(name) do
    v = @vectors["lines"][name]

    %{
      language: String.to_existing_atom(v["language"]),
      target_type: String.to_existing_atom(v["target_type"]),
      outputs:
        Enum.map(v["outputs"], &%{path: &1["path"], size: &1["size"], digest: &1["digest"]})
    }
  end

  defp auth, do: %{ts: @vectors["request"]["ts"], nonce: @vectors["request"]["nonce"]}

  # A wire body built from the valid request with other sources.
  defp request_wire(sources) do
    @vectors["request"]["body"]
    |> Jason.decode!()
    |> Map.put(
      "sources",
      Enum.map(sources, fn {path, b64} -> %{"path" => path, "base64" => b64} end)
    )
    |> Jason.encode!()
  end

  defp zero_files(count, bytes) do
    b64 = Base.encode64(:binary.copy(<<0>>, bytes))
    for index <- 1..count, do: {"f/#{index}.bin", b64}
  end

  defp synthesized(%{"files" => count, "bytes" => bytes}, :request),
    do: request_wire(zero_files(count, bytes))

  defp synthesized(%{"files" => count} = synthesize, :line) do
    size = Map.get(synthesize, "size", 0)

    @vectors["lines"]["tincture_result"]["body"]
    |> Jason.decode!()
    |> Map.put(
      "outputs",
      for index <- 1..count do
        %{"path" => "f/#{index}.bin", "size" => size, "digest" => Prima.Digest.sha256("")}
      end
    )
    |> Jason.encode!()
  end

  defp synthesized(%{"chunk_bytes" => bytes}, :line) do
    @vectors["lines"]["output"]["body"]
    |> Jason.decode!()
    |> Map.put("bytes", Base.encode64(:binary.copy(<<0>>, bytes)))
    |> Jason.encode!()
  end

  defp synthesized(%{"message_bytes" => bytes}, :line) do
    @vectors["lines"]["progress"]["body"]
    |> Jason.decode!()
    |> Map.put("message", String.duplicate("a", bytes))
    |> Jason.encode!()
  end

  describe "the shared vectors" do
    test "the protocol's data is what the vectors say" do
      v = @vectors

      assert BuilderProtocol.version() == v["version"]
      assert BuilderProtocol.domain() == v["domain"]
      assert BuilderProtocol.service() == v["service"]
      assert v["label"] == v["domain"] <> "/" <> v["service"]
      assert BuilderProtocol.auth_header() == v["auth_header"]
      assert BuilderProtocol.window_ms() == v["window_ms"]

      assert BuilderProtocol.routes() == %{
               build: v["routes"]["build"],
               health: v["routes"]["health"]
             }

      assert Map.new(BuilderProtocol.classes(), &{Atom.to_string(&1), BuilderProtocol.status(&1)}) ==
               v["statuses"]

      for {name, bound} <- v["bounds"] do
        assert apply(BuilderProtocol, String.to_existing_atom(name), []) == bound, name
      end

      assert Enum.map(BuilderProtocol.languages(), &Atom.to_string/1) == v["languages"]

      for {type, language} <- v["language_for"] do
        assert BuilderProtocol.language_for(String.to_existing_atom(type)) ==
                 String.to_existing_atom(language)
      end

      assert Enum.map(BuilderProtocol.stages(), &Atom.to_string/1) == v["stages"]
      assert BuilderProtocol.component_wasm() == v["component_wasm"]
      assert BuilderProtocol.component_lockfile() == v["component_lockfile"]
    end

    test "the request key derives from the service key over the label, and the key text decodes" do
      v = @vectors

      assert hex(BuilderProtocol.request_key(key())) == v["request_key_hex"]
      assert BuilderProtocol.request_key(key()) == MacEnvelope.derive(key(), v["label"])

      assert hex(MacEnvelope.derive(unhex(v["backends_key_hex"]), "cyfr-locus/v1/backends")) ==
               v["backends_request_key_hex"]

      for text <- v["key_text"]["valid"] do
        assert {:ok, decoded} = MacEnvelope.decode_root(text)
        assert decoded == key()
      end

      for text <- v["key_text"]["invalid"],
          do: assert(:error = MacEnvelope.decode_root(text), inspect(text))

      assert :error = MacEnvelope.decode_root(nil)
    end

    test "the request reads to its fields, writes back to its body, and signs as the vectors say" do
      v = @vectors["request"]
      request = request()

      assert {:ok, ^request} = BuilderProtocol.read_request(v["body"])
      assert {:ok, v["body"]} == BuilderProtocol.encode_request(request)
      assert {:ok, v["canonical"]} == BuilderProtocol.canonical(auth(), v["body"])

      assert {:ok, v["header"]} ==
               BuilderProtocol.request_header(request_key(), auth(), v["body"])

      [_signed, mac] = String.split(v["header"], " mac=")
      assert mac == v["mac"]

      assert Base.url_encode64(:crypto.mac(:hmac, :sha256, request_key(), v["canonical"]),
               padding: false
             ) == mac

      assert v["canonical"] |> String.split("\n") |> List.first() ==
               @vectors["label"] <> "/request"

      assert v["canonical"] |> String.split("\n") |> List.last() ==
               Prima.Digest.sha256_hex(v["body"])

      assert v["header"] =~ " body=#{Prima.Digest.sha256_hex(v["body"])} mac="
    end

    test "the request verifies under the request key, one-step and header-first" do
      v = @vectors["request"]
      auth = auth()
      hash = Prima.Digest.sha256_hex(v["body"])

      assert {:ok, ^auth} =
               BuilderProtocol.verify_request(request_key(), v["header"], v["body"], v["ts"])

      assert {:ok, ^auth, ^hash} =
               BuilderProtocol.verify_request_header(request_key(), v["header"], v["ts"])

      assert :ok = BuilderProtocol.verify_body(hash, v["body"])
      assert {:error, :bad_mac} = BuilderProtocol.verify_body(hash, v["body"] <> " ")

      other = String.replace_prefix(v["header"], "v1 ", "v2 ")

      assert {:error, :unknown_version} =
               BuilderProtocol.verify_request(request_key(), other, v["body"], v["ts"])

      assert {:error, :unknown_version} =
               BuilderProtocol.verify_request_header(request_key(), other, v["ts"])
    end

    test "every rejected header is refused with its reason, one-step and header-first" do
      for %{
            "name" => name,
            "header" => header,
            "body" => body,
            "now" => now,
            "refusal" => refusal
          } <-
            @vectors["auth_rejected"] do
        expected = String.to_existing_atom(refusal)

        assert {:error, ^expected} =
                 BuilderProtocol.verify_request(request_key(), header, body, now),
               name

        # Header-first: a body tampered after signing is caught by verify_body,
        # every other refusal by the header alone.
        case BuilderProtocol.verify_request_header(request_key(), header, now) do
          {:ok, _auth, hash} ->
            assert name == "tampered_body"
            assert {:error, :bad_mac} = BuilderProtocol.verify_body(hash, body)

          {:error, why} ->
            assert why == expected, name
        end
      end
    end

    test "the health request is its body" do
      body = @vectors["health_request"]["body"]

      assert BuilderProtocol.encode_health_request() == body
      assert :ok = BuilderProtocol.read_health_request(body)
      assert {:error, {:version, nil}} = BuilderProtocol.read_health_request("{}")

      assert {:error, {:unknown_field, "op"}} =
               BuilderProtocol.read_health_request(
                 ~s({"version":#{BuilderProtocol.version()},"op":"health"})
               )
    end

    test "every line reads to its fields and writes back to its body" do
      lines = @vectors["lines"]

      p = lines["progress"]
      stage = String.to_existing_atom(p["stage"])
      assert {:ok, {:progress, ^stage, message}} = BuilderProtocol.read_line(p["body"])
      assert message == p["message"]
      assert {:ok, p["body"]} == BuilderProtocol.encode_progress(stage, message)

      o = lines["output"]
      bytes = Base.decode64!(o["bytes"])
      chunk = %{path: o["path"], seq: o["seq"], bytes: bytes}
      assert {:ok, {:output, ^chunk}} = BuilderProtocol.read_line(o["body"])
      assert {:ok, o["body"]} == BuilderProtocol.encode_output(o["path"], o["seq"], bytes)
      assert bytes == <<0, "asm", 0x0D, 0, 1, 0>>

      for name <- ["component_result", "tincture_result"] do
        result = result(name)
        assert {:ok, {:result, ^result}} = BuilderProtocol.read_line(lines[name]["body"])
        assert {:ok, lines[name]["body"]} == BuilderProtocol.encode_result(result)
      end

      component = result("component_result")
      assert Enum.map(component.outputs, & &1.path) == ["component.wasm", "Cargo.lock"]

      h = lines["health"]

      health = %{
        release: h["release"],
        toolchains:
          Map.new(h["toolchains"], fn {language, t} ->
            {String.to_existing_atom(language),
             %{available: t["available"], command: t["command"], description: t["description"]}}
          end)
      }

      assert {:ok, {:health, ^health}} = BuilderProtocol.read_line(h["body"])
      assert {:ok, h["body"]} == BuilderProtocol.encode_health(health)
    end

    test "every refusal reads to its class and reason, writes back, and is described" do
      for %{"class" => class, "reason" => reason, "body" => body} = v <-
            @vectors["lines"]["refusals"] do
        assert {:ok, {:refusal, refusal}} = BuilderProtocol.read_line(body), class
        assert Atom.to_string(elem(refusal, 0)) == class
        assert Jason.decode!(body)["reason"] == reason
        refute Map.has_key?(Jason.decode!(body), "diagnostics")
        assert {:ok, ^body} = BuilderProtocol.encode_refusal(refusal)
        assert BuilderProtocol.describe_refusal(refusal) == v["sentence"]
        assert BuilderProtocol.status(refusal) == @vectors["statuses"][class]
      end
    end

    test "every invalid request is refused with its error, on read and on write" do
      for %{"name" => name, "error" => error} = v <- @vectors["invalid_requests"] do
        expected = String.to_existing_atom(error)

        cond do
          body = v["body"] ->
            assert {:error, err} = BuilderProtocol.read_request(body), name
            assert tag(err) == expected, "#{name}: #{inspect(err)}"

          synthesize = v["synthesize"] ->
            assert {:error, err} = BuilderProtocol.read_request(synthesized(synthesize, :request)),
                   name

            assert tag(err) == expected, "#{name}: #{inspect(err)}"

            zeros = :binary.copy(<<0>>, synthesize["bytes"])
            sources = Map.new(1..synthesize["files"], &{"f/#{&1}.bin", zeros})

            assert {:error, err} = BuilderProtocol.encode_request(%{request() | sources: sources}),
                   name

            assert tag(err) == expected, "#{name} on write: #{inspect(err)}"

          declared = v["declared_bytes"] ->
            assert {:error, {:too_large, :request, ^declared, max}} =
                     BuilderProtocol.admit_request_bytes(declared)

            assert max == BuilderProtocol.max_request_bytes()
        end
      end
    end

    test "every invalid line is refused with its error" do
      for %{"name" => name, "error" => error} = v <- @vectors["invalid_lines"] do
        expected = String.to_existing_atom(error)
        body = v["body"] || synthesized(v["synthesize"], :line)

        assert {:error, err} = BuilderProtocol.read_line(body), name
        assert tag(err) == expected, "#{name}: #{inspect(err)}"
      end
    end

    test "every stream reads to the files and log a reader keeps, or is refused with its error" do
      for %{"name" => name} = v <- @vectors["lines"]["streams"] do
        lines = v["lines"] || synthesized_stream(v["synthesize"])

        case {read_stream(lines), v} do
          {{:ok, files, log}, %{"outputs" => outputs, "diagnostics" => diagnostics}} ->
            assert files == files(outputs), name
            assert log == diagnostics, name

          {{:refused, refusal, kept}, %{"refusal" => expected}} ->
            assert Atom.to_string(elem(refusal, 0)) == expected["class"], name
            assert Jason.decode!(List.last(lines))["reason"] == expected["reason"], name
            assert kept == %{}, "#{name}: a refused stream keeps nothing"

          {{:error, err}, %{"error" => error}} ->
            assert tag(err) == String.to_existing_atom(error), "#{name}: #{inspect(err)}"

          {read, _v} ->
            flunk("#{name} read as #{inspect(read)}")
        end
      end
    end
  end

  # A reader of an answer's lines, as the client reads them: the progress
  # lines are its log, the output lines its files once a result names them.
  defp read_stream(lines) do
    Enum.reduce_while(lines, {BuilderProtocol.outputs(), []}, fn line, {outputs, log} ->
      case BuilderProtocol.read_line(line) do
        {:ok, {:progress, stage, message}} ->
          {:cont, {outputs, [BuilderProtocol.diagnostic(stage, message) | log]}}

        {:ok, {:output, chunk}} ->
          case BuilderProtocol.output(outputs, chunk) do
            {:ok, outputs} -> {:cont, {outputs, log}}
            {:error, _} = error -> {:halt, error}
          end

        {:ok, {:result, result}} ->
          case BuilderProtocol.outputs(outputs, result) do
            {:ok, files} -> {:halt, {:ok, files, Enum.reverse(log)}}
            {:error, _} = error -> {:halt, error}
          end

        {:ok, {:refusal, refusal}} ->
          {:halt, {:refused, refusal, %{}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp synthesized_stream(%{"files" => count}) do
    for seq <- 1..count do
      {:ok, line} = BuilderProtocol.encode_output("f/#{seq}.bin", seq, "")
      line
    end
  end

  defp synthesized_stream(%{"bytes" => bytes}) do
    max = BuilderProtocol.max_chunk_bytes()
    full = :binary.copy(<<0>>, max)

    Stream.unfold({bytes, 1}, fn
      {0, _seq} ->
        nil

      {left, seq} ->
        chunk = if left >= max, do: full, else: :binary.copy(<<0>>, left)
        {:ok, line} = BuilderProtocol.encode_output("big.bin", seq, chunk)
        {line, {left - byte_size(chunk), seq + 1}}
    end)
    |> Enum.to_list()
  end

  describe "bounds" do
    test "a request over the declared size is refused before any MAC work or parsing" do
      max = BuilderProtocol.max_request_bytes()

      assert :ok = BuilderProtocol.admit_request_bytes(max)

      assert {:error, {:too_large, :request, _, ^max}} =
               BuilderProtocol.admit_request_bytes(max + 1)

      # Not JSON, and over the bound: the bound answers, so nothing of the
      # body was looked at — and no key was involved.
      oversized = String.duplicate("!", max + 1)
      assert {:error, {:too_large, :request, _, ^max}} = BuilderProtocol.read_request(oversized)
      assert {:error, :not_json} = BuilderProtocol.read_request("!")
    end

    test "sources over the byte bound are refused on their encoded size, before any is decoded" do
      max = BuilderProtocol.max_source_bytes()
      # Not base64 at all: a decode would refuse the field, the bound refuses the size.
      undecodable =
        String.duplicate("!", div(max * 4, 3) + 4 * BuilderProtocol.max_source_files() + 1)

      assert {:error, {:too_large, :sources, _, ^max}} =
               BuilderProtocol.read_request(request_wire([{"big.bin", undecodable}]))

      assert {:error, {:invalid_field, "sources[0].base64"}} =
               BuilderProtocol.read_request(request_wire([{"big.bin", "!!!!"}]))
    end

    test "a line, a chunk and a sentence are bounded" do
      max_line = BuilderProtocol.max_line_bytes()
      max_chunk = BuilderProtocol.max_chunk_bytes()
      long = String.duplicate("a", max_line + 1)

      assert {:error, {:too_large, :line, _, ^max_line}} =
               BuilderProtocol.encode_progress(:output, long)

      assert {:ok, _} = BuilderProtocol.encode_progress(:output, String.duplicate("a", max_line))

      assert {:error, {:too_large, :chunk, _, ^max_chunk}} =
               BuilderProtocol.encode_output("a.bin", 1, :binary.copy(<<0>>, max_chunk + 1))

      # A chunk at its bound, under the longest path and the largest seq,
      # is a line within its bound, read back whole.
      # Segments of quotes, each escaping to two bytes, to the path's bound.
      stem = Enum.map_join(1..4, "/", fn _ -> String.duplicate(~s("), 240) end) <> "/"

      path =
        stem <> String.duplicate(~s("), BuilderProtocol.max_output_path_bytes() - byte_size(stem))

      assert byte_size(path) == BuilderProtocol.max_output_path_bytes()
      seq = BuilderProtocol.max_output_bytes() + BuilderProtocol.max_output_files()
      chunk = :binary.copy(<<0xFF>>, max_chunk)
      assert {:ok, line} = BuilderProtocol.encode_output(path, seq, chunk)
      assert byte_size(line) + 1 <= BuilderProtocol.max_output_line_bytes()

      assert {:ok, {:output, %{path: ^path, seq: ^seq, bytes: ^chunk}}} =
               BuilderProtocol.read_line(line)

      assert {:error, {:invalid_field, "seq"}} =
               BuilderProtocol.encode_output("a.bin", seq + 1, "")

      assert {:error, {:invalid_field, "seq"}} = BuilderProtocol.encode_output("a.bin", 0, "")

      # A line past the largest any type may be is refused before it is parsed.
      over = String.duplicate(" ", BuilderProtocol.max_line_size())
      max_size = BuilderProtocol.max_line_size()
      assert {:error, {:too_large, :line, _, ^max_size}} = BuilderProtocol.read_line(over)

      assert {:error, {:invalid_field, "reason"}} =
               BuilderProtocol.encode_refusal({:unavailable, long})

      assert {:error, {:invalid_field, "reason"}} =
               BuilderProtocol.encode_refusal({:malformed, ""})
    end

    test "the lines' bounds are derived, term by term, from the vectors' other bounds" do
      b = @vectors["bounds"]
      escaped_path = 2 * b["max_output_path_bytes"]

      # An output line with an empty path and no bytes at the largest seq,
      # its newline and its path escaped at most twice over; the chunk is
      # what base64 fits in the rest.
      seq = b["max_output_bytes"] + b["max_output_files"]

      output_envelope =
        @vectors["lines"]["output"]["body"]
        |> Jason.decode!()
        |> Map.merge(%{"path" => "", "seq" => seq, "bytes" => ""})
        |> Jason.encode!()
        |> byte_size()
        |> Kernel.+(1 + escaped_path)

      assert 3 * div(b["max_output_line_bytes"] - output_envelope, 4) == b["max_chunk_bytes"]

      # A result with no output at its longest pairing and newline, then
      # each entry with its path escaped, the largest size, the digest and
      # a comma.
      template = Jason.decode!(@vectors["lines"]["tincture_result"]["body"])

      envelope =
        @vectors["language_for"]
        |> Enum.map(fn {type, language} ->
          template
          |> Map.merge(%{"language" => language, "target_type" => type, "outputs" => []})
          |> Jason.encode!()
          |> byte_size()
          |> Kernel.+(1)
        end)
        |> Enum.max()

      [first | _] = template["outputs"]
      empty = %{first | "path" => "", "size" => b["max_output_bytes"]}
      entry = byte_size(Jason.encode!(empty)) + 1 + escaped_path
      assert byte_size(first["digest"]) == byte_size("sha256:") + 64

      assert envelope + b["max_output_files"] * entry == b["max_result_line_bytes"]
      assert max(b["max_output_line_bytes"], b["max_result_line_bytes"]) == b["max_line_size"]

      # A progress line's message and a refusal's sentence escape six times
      # over at most, and stay within any line's bound.
      {:ok, progress} = BuilderProtocol.encode_progress(:output, "")
      assert byte_size(progress) + 6 * b["max_line_bytes"] + 1 < b["max_line_size"]
    end

    test "an output's path is bounded on its own bytes, and holds no control character" do
      max = BuilderProtocol.max_output_path_bytes()
      base = result("tincture_result")

      named = fn path ->
        %{base | outputs: [%{path: path, size: 1, digest: Prima.Digest.sha256("x")}]}
      end

      # PathSafety counts no empty segment; the wire's bound counts every byte.
      at_bound = "a" <> String.duplicate("/", max - 2) <> "b"
      assert :ok = Prima.PathSafety.validate_relative_path(at_bound <> "/")
      assert {:ok, _} = BuilderProtocol.encode_result(named.(at_bound))
      assert {:ok, _} = BuilderProtocol.encode_output(at_bound, 1, "x")

      assert {:error, {:invalid_field, "outputs[0].path"}} =
               BuilderProtocol.encode_result(named.(at_bound <> "/"))

      assert {:error, {:invalid_field, "path"}} =
               BuilderProtocol.encode_output(at_bound <> "/", 1, "x")

      for byte <- Enum.concat(0x01..0x1F, [0x7F]) do
        path = <<"dist/a", byte, "b.js">>

        assert {:error, {:invalid_field, "outputs[0].path"}} =
                 BuilderProtocol.encode_result(named.(path)),
               "byte #{byte}"

        assert {:error, {:invalid_field, "path"}} = BuilderProtocol.encode_output(path, 1, "x"),
               "byte #{byte}"
      end

      # What is left escapes to at most two bytes a byte: a quote, since
      # PathSafety refuses a backslash.
      escaped = Enum.map_join(1..4, "/", fn _ -> String.duplicate(~s("), 240) end)

      assert {:ok, line} = BuilderProtocol.encode_result(named.(escaped))
      assert {:ok, {:result, %{outputs: [%{path: ^escaped}]}}} = BuilderProtocol.read_line(line)
      assert byte_size(Jason.encode!(escaped)) - 2 <= 2 * max
    end

    test "a running digest is the whole file's, as a result names it" do
      bytes = :crypto.strong_rand_bytes(100_000)

      hash =
        for <<chunk::binary-size(1_000) <- bytes>>, reduce: BuilderProtocol.digest_init() do
          hash -> BuilderProtocol.digest_update(hash, chunk)
        end

      assert BuilderProtocol.digest_final(hash) == Prima.Digest.sha256(bytes)

      assert BuilderProtocol.digest_final(BuilderProtocol.digest_init()) ==
               Prima.Digest.sha256("")
    end

    test "a log is its progress lines as a person reads them, in their order" do
      assert BuilderProtocol.diagnostic(:compiling, "Compiling reagent (rust)...") ==
               "compiling: Compiling reagent (rust)..."

      %{"diagnostics" => diagnostics, "lines" => lines} =
        Enum.find(@vectors["lines"]["streams"], &(&1["name"] == "component"))

      progress =
        for line <- lines,
            {:ok, {:progress, stage, message}} <- [BuilderProtocol.read_line(line)],
            do: BuilderProtocol.diagnostic(stage, message)

      assert progress == diagnostics
    end

    test "text fields must be UTF-8" do
      assert {:error, {:invalid_field, "message"}} =
               BuilderProtocol.encode_progress(:output, <<0xFF>>)

      assert {:error, {:invalid_field, "athanor_id"}} =
               BuilderProtocol.encode_request(%{request() | athanor_id: <<0xFF>>})
    end

    test "a request's athanor_id is of the grammar every Locus wire gives an athanor's id" do
      read = fn athanor_id ->
        wire = Map.put(Jason.decode!(@vectors["request"]["body"]), "athanor_id", athanor_id)

        {BuilderProtocol.encode_request(%{request() | athanor_id: athanor_id}),
         BuilderProtocol.read_request(Jason.encode!(wire))}
      end

      for athanor_id <- ["family@example", String.duplicate("a", 256)] do
        assert {{:ok, _body}, {:ok, %{athanor_id: ^athanor_id}}} = read.(athanor_id)
        assert Regex.match?(Prima.RunnerControl.athanor_id_pattern(), athanor_id)
      end

      for athanor_id <- ["family of mine", "famille-é", String.duplicate("a", 257)] do
        assert read.(athanor_id) ==
                 {{:error, {:invalid_field, "athanor_id"}},
                  {:error, {:invalid_field, "athanor_id"}}}

        refute Regex.match?(Prima.RunnerControl.athanor_id_pattern(), athanor_id)
      end
    end
  end

  describe "refusals" do
    test "every class round-trips with its typed reason" do
      refusals = [
        {:malformed, "sources is required"},
        {:unauthorized, :unknown_version},
        {:unauthorized, :malformed},
        {:unauthorized, :outside_window},
        {:unauthorized, :bad_mac},
        {:unauthorized, :replayed},
        {:capacity, 16},
        {:timeout, 0},
        {:memory, 1},
        {:memory, 1_073_741_824},
        {:memory, :machine},
        {:memory, :either},
        {:unavailable, "keeper"},
        {:failed, {:status, 0}},
        {:failed, {:status, -1}},
        {:failed, {:signal, "TERM"}},
        {:protocol_mismatch, 1, 3},
        {:protocol_mismatch, 2, nil}
      ]

      for refusal <- refusals do
        assert {:ok, line} = BuilderProtocol.encode_refusal(refusal)
        assert {:ok, {:refusal, ^refusal}} = BuilderProtocol.read_line(line)
        assert is_binary(BuilderProtocol.describe_refusal(refusal))
        assert BuilderProtocol.status(refusal) in 400..599
      end

      assert Enum.sort(Enum.uniq(Enum.map(refusals, &elem(&1, 0)))) ==
               Enum.sort(BuilderProtocol.classes())
    end

    test "a build ended at its memory bound is a class of its own, never failed or timeout" do
      vector = Enum.find(@vectors["lines"]["refusals"], &(&1["class"] == "memory"))
      limit = vector["reason"]["limit_bytes"]

      assert {:ok, {:refusal, {:memory, ^limit}}} = BuilderProtocol.read_line(vector["body"])

      assert :memory in BuilderProtocol.classes()
      statuses = Map.new(BuilderProtocol.classes(), &{&1, BuilderProtocol.status(&1)})
      assert statuses.memory == 507
      assert statuses |> Map.values() |> Enum.uniq() |> length() == map_size(statuses)

      # The kill a bound ends a build with is a signal; without the class it
      # would read as this.
      assert {:ok, killed} = BuilderProtocol.encode_refusal({:failed, {:signal, "SIGKILL"}})

      assert {:ok, {:refusal, {:failed, {:signal, "SIGKILL"}}}} =
               BuilderProtocol.read_line(killed)

      assert {:ok, bounded} = BuilderProtocol.encode_refusal({:memory, limit})
      assert {:ok, {:refusal, {:memory, ^limit}}} = BuilderProtocol.read_line(bounded)
      refute Jason.decode!(bounded)["class"] == Jason.decode!(killed)["class"]

      assert BuilderProtocol.describe_refusal({:memory, limit}) =~
               "memory bound of #{limit} bytes"

      # A reason of another class's shape never reads under this one, nor
      # this one's under another.
      for {class, reason} <- [
            {"memory", %{"signal" => "SIGKILL"}},
            {"memory", %{"status" => 137}},
            {"memory", %{"budget_ms" => 270_000}},
            {"memory", %{"limit_bytes" => 0}},
            {"memory", %{"limit_bytes" => -1}},
            {"memory", %{"limit_bytes" => 1.5}},
            {"memory", %{"limit_bytes" => nil}},
            {"memory", %{"cause" => "cap"}},
            {"memory", %{"cause" => "machine", "limit_bytes" => limit}},
            {"memory", "1073741824"},
            {"failed", %{"limit_bytes" => limit}},
            {"timeout", %{"limit_bytes" => limit}}
          ] do
        body =
          Jason.encode!(%{
            "version" => BuilderProtocol.version(),
            "type" => "refusal",
            "class" => class,
            "reason" => reason
          })

        assert {:error, {:invalid_field, "reason"}} = BuilderProtocol.read_line(body),
               "#{class} read #{inspect(reason)}"
      end
    end

    test "a read error maps to a refusal: another version to protocol_mismatch, anything else to malformed" do
      assert BuilderProtocol.refusal_for({:version, 1}) == {:protocol_mismatch, 2, 1}
      assert BuilderProtocol.refusal_for({:version, nil}) == {:protocol_mismatch, 2, nil}
      assert BuilderProtocol.refusal_for({:version, "2"}) == {:protocol_mismatch, 2, nil}
      assert BuilderProtocol.refusal_for({:version, 0}) == {:protocol_mismatch, 2, nil}

      for error <- [
            :not_json,
            {:unknown_field, "x"},
            {:missing_field, "sources"},
            {:invalid_field, "sources[1].path"},
            {:unpaired, :rust, :tincture},
            {:too_large, :sources, 2, 1},
            {:too_large, :request, 2, 1},
            {:too_large, :line, 2, 1},
            {:too_many, :outputs, 2, 1},
            {:duplicate_path, "a"},
            {:unsafe_path, "../a"},
            {:too_large, :chunk, 2, 1},
            {:out_of_order, 3, 2},
            {:path_revisited, "a"},
            {:unsent, "a"},
            {:unnamed, "a"},
            {:size_mismatch, "a"},
            {:digest_mismatch, "a"}
          ] do
        assert {:malformed, sentence} = BuilderProtocol.refusal_for(error)
        assert sentence == BuilderProtocol.describe(error)
        assert {:ok, line} = BuilderProtocol.encode_refusal({:malformed, sentence})
        assert {:ok, {:refusal, {:malformed, ^sentence}}} = BuilderProtocol.read_line(line)
      end

      assert BuilderProtocol.describe({:unpaired, :rust, :tincture}) ==
               "a tincture is not built from rust"
    end
  end

  describe "authentication" do
    @backends %MacEnvelope{
      prefix: "cyfr-locus/v1/backends",
      kind: "request",
      fields: [ts: :integer, nonce: :string]
    }

    test "a header for the backends service, or under its key, never verifies as builds" do
      body = @vectors["request"]["body"]

      backends_key =
        MacEnvelope.derive(unhex(@vectors["backends_key_hex"]), "cyfr-locus/v1/backends")

      {:ok, as_backends} = MacEnvelope.header(@backends, request_key(), auth(), body)
      {:ok, by_backends} = MacEnvelope.header(@backends, backends_key, auth(), body)
      {:ok, by_backends_as_builds} = BuilderProtocol.request_header(backends_key, auth(), body)

      for header <- [as_backends, by_backends, by_backends_as_builds] do
        assert {:error, :bad_mac} =
                 BuilderProtocol.verify_request(request_key(), header, body, @now)

        assert {:error, :bad_mac} =
                 BuilderProtocol.verify_request_header(request_key(), header, @now)
      end

      # The service key itself signs nothing: only the key derived over the label does.
      {:ok, underived} = BuilderProtocol.request_header(key(), auth(), body)

      assert {:error, :bad_mac} =
               BuilderProtocol.verify_request(request_key(), underived, body, @now)
    end

    test "refuses in order: malformed, then the window, then the MAC" do
      body = @vectors["request"]["body"]
      {:ok, forged} = BuilderProtocol.request_header(key(), auth(), body)

      assert {:error, :malformed} = BuilderProtocol.verify_request(request_key(), nil, body, @now)

      assert {:error, :malformed} =
               BuilderProtocol.verify_request(request_key(), "v1", body, @now)

      assert {:error, :outside_window} =
               BuilderProtocol.verify_request(request_key(), forged, body, @now + 60_000)

      assert {:error, :bad_mac} =
               BuilderProtocol.verify_request(request_key(), forged, body, @now)

      {:ok, header} = BuilderProtocol.request_header(request_key(), auth(), body)
      assert {:ok, _} = BuilderProtocol.verify_request(request_key(), header, body, @now + 30_000)
      assert {:ok, _} = BuilderProtocol.verify_request(request_key(), header, body, @now - 30_000)

      assert {:error, :outside_window} =
               BuilderProtocol.verify_request(request_key(), header, body, @now + 30_001)
    end

    test "a request header refuses an invalid field by name" do
      body = @vectors["request"]["body"]

      assert {:error, {:invalid_field, :nonce}} =
               BuilderProtocol.request_header(request_key(), %{ts: @now, nonce: "n 1"}, body)

      assert {:error, {:invalid_field, :ts}} =
               BuilderProtocol.request_header(request_key(), %{ts: -1, nonce: "n_1"}, body)
    end
  end

  describe "operations" do
    test "every route reads back to its operation, and nothing else is a route" do
      for {operation, route} <- BuilderProtocol.routes() do
        assert BuilderProtocol.route(operation) == route
        assert {:ok, ^operation} = BuilderProtocol.operation(route)
        assert String.starts_with?(route, "/locus/v1/builds/")
      end

      assert Map.keys(BuilderProtocol.routes()) |> Enum.sort() == [:build, :health]
      assert :error = BuilderProtocol.operation("/locus/v1/builds/")
      assert :error = BuilderProtocol.operation("/build")
      assert_raise FunctionClauseError, fn -> BuilderProtocol.route(:backends) end
    end

    test "the release is this build's version" do
      assert BuilderProtocol.release() == Prima.Version.current()
    end
  end

  test "the athanor in the vectors is the one the request names" do
    assert request().athanor_id == @athanor
  end
end
