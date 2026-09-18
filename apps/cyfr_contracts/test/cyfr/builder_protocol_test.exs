# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BuilderProtocolTest do
  @moduledoc """
  The build wire reproduces every shared vector
  (`tests/fixtures/locus_builds.json`): the protocol's data, the request
  key derived over the service label, the request's canonical string, MAC
  and header, every line and refusal read to its fields and written back
  to its body, every invalid body refused with its error, and every
  rejected header refused with its reason. Beyond the vectors: a request
  is bounded on its declared size before any MAC work and on its encoded
  sources before any decoding; every refusal class round-trips; a header
  for another Locus service, or under its key, never verifies as builds;
  and header-first verification refuses exactly what the one-step
  verifier refuses.
  """
  use ExUnit.Case, async: true

  alias Cyfr.{BuilderProtocol, MacEnvelope}

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
      outputs: files(v["outputs"]),
      diagnostics: v["diagnostics"]
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

  defp synthesized(%{"files" => count, "bytes" => bytes}, :line) do
    zeros = :binary.copy(<<0>>, bytes)
    digest = Cyfr.Digest.sha256(zeros)

    @vectors["lines"]["tincture_result"]["body"]
    |> Jason.decode!()
    |> Map.put(
      "outputs",
      Enum.map(zero_files(count, bytes), fn {path, b64} ->
        %{"path" => path, "base64" => b64, "digest" => digest}
      end)
    )
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

      for text <- v["key_text"]["valid"],
          do: assert({:ok, k} = BuilderProtocol.decode_key(text)) && assert(k == key())

      for text <- v["key_text"]["invalid"],
          do: assert(:error = BuilderProtocol.decode_key(text), inspect(text))

      assert :error = BuilderProtocol.decode_key(nil)
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
               Cyfr.Digest.sha256_hex(v["body"])

      assert v["header"] =~ " body=#{Cyfr.Digest.sha256_hex(v["body"])} mac="
    end

    test "the request verifies under the request key, one-step and header-first" do
      v = @vectors["request"]
      auth = auth()
      hash = Cyfr.Digest.sha256_hex(v["body"])

      assert {:ok, ^auth} =
               BuilderProtocol.verify_request(request_key(), v["header"], v["body"], v["ts"])

      assert {:ok, ^auth, ^hash} =
               BuilderProtocol.verify_request_header(request_key(), v["header"], v["ts"])

      assert :ok = BuilderProtocol.verify_body(hash, v["body"])
      assert {:error, :bad_mac} = BuilderProtocol.verify_body(hash, v["body"] <> " ")
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
               BuilderProtocol.read_health_request(~s({"version":1,"op":"health"}))
    end

    test "every line reads to its fields and writes back to its body" do
      lines = @vectors["lines"]

      p = lines["progress"]
      stage = String.to_existing_atom(p["stage"])
      assert {:ok, {:progress, ^stage, message}} = BuilderProtocol.read_line(p["body"])
      assert message == p["message"]
      assert {:ok, p["body"]} == BuilderProtocol.encode_progress(stage, message)

      for name <- ["component_result", "tincture_result"] do
        result = result(name)
        assert {:ok, {:result, ^result}} = BuilderProtocol.read_line(lines[name]["body"])
        assert {:ok, lines[name]["body"]} == BuilderProtocol.encode_result(result)
      end

      component = result("component_result")
      assert Map.keys(component.outputs) |> Enum.sort() == ["Cargo.lock", "component.wasm"]
      assert component.outputs[BuilderProtocol.component_wasm()] == <<0, "asm", 1, 0, 0, 0>>

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
      for %{"class" => class, "reason" => reason, "diagnostics" => diagnostics, "body" => body} =
            v <-
            @vectors["lines"]["refusals"] do
        assert {:ok, {:refusal, refusal, ^diagnostics}} = BuilderProtocol.read_line(body), class
        assert Atom.to_string(elem(refusal, 0)) == class
        assert Jason.decode!(body)["reason"] == reason
        assert {:ok, ^body} = BuilderProtocol.encode_refusal(refusal, diagnostics)
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

    test "a line, a log and a sentence are bounded" do
      max_line = BuilderProtocol.max_line_bytes()
      max_log = BuilderProtocol.max_log_bytes()
      long = String.duplicate("a", max_line + 1)
      base = result("tincture_result")

      assert {:error, {:too_large, :line, _, ^max_line}} =
               BuilderProtocol.encode_progress(:output, long)

      assert {:ok, _} = BuilderProtocol.encode_progress(:output, String.duplicate("a", max_line))

      assert {:error, {:too_large, :line, _, ^max_line}} =
               BuilderProtocol.encode_result(%{base | diagnostics: [long]})

      # Each line counts with its newline, so a log of empty lines is bounded too.
      lines = List.duplicate("", max_log)
      assert {:ok, _} = BuilderProtocol.encode_result(%{base | diagnostics: lines})

      assert {:error, {:too_large, :diagnostics, _, ^max_log}} =
               BuilderProtocol.encode_result(%{base | diagnostics: ["" | lines]})

      assert {:error, {:invalid_field, "reason"}} =
               BuilderProtocol.encode_refusal({:unavailable, long}, [])

      assert {:error, {:invalid_field, "reason"}} =
               BuilderProtocol.encode_refusal({:malformed, ""}, [])
    end

    test "text fields must be UTF-8" do
      assert {:error, {:invalid_field, "message"}} =
               BuilderProtocol.encode_progress(:output, <<0xFF>>)

      assert {:error, {:invalid_field, "athanor_id"}} =
               BuilderProtocol.encode_request(%{request() | athanor_id: <<0xFF>>})
    end
  end

  describe "refusals" do
    test "every class round-trips with its typed reason" do
      refusals = [
        {:malformed, "sources is required"},
        {:unauthorized, :malformed},
        {:unauthorized, :outside_window},
        {:unauthorized, :bad_mac},
        {:unauthorized, :replayed},
        {:capacity, 16},
        {:timeout, 0},
        {:unavailable, "spawner"},
        {:failed, {:status, 0}},
        {:failed, {:status, -1}},
        {:failed, {:signal, "TERM"}},
        {:protocol_mismatch, 1, 3},
        {:protocol_mismatch, 2, nil}
      ]

      for refusal <- refusals do
        assert {:ok, line} = BuilderProtocol.encode_refusal(refusal, ["a line"])
        assert {:ok, {:refusal, ^refusal, ["a line"]}} = BuilderProtocol.read_line(line)
        assert is_binary(BuilderProtocol.describe_refusal(refusal))
        assert BuilderProtocol.status(refusal) in 400..599
      end

      assert Enum.sort(Enum.uniq(Enum.map(refusals, &elem(&1, 0)))) ==
               Enum.sort(BuilderProtocol.classes())
    end

    test "a read error maps to a refusal: another version to protocol_mismatch, anything else to malformed" do
      assert BuilderProtocol.refusal_for({:version, 2}) == {:protocol_mismatch, 1, 2}
      assert BuilderProtocol.refusal_for({:version, nil}) == {:protocol_mismatch, 1, nil}
      assert BuilderProtocol.refusal_for({:version, "1"}) == {:protocol_mismatch, 1, nil}
      assert BuilderProtocol.refusal_for({:version, 0}) == {:protocol_mismatch, 1, nil}

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
            {:digest_mismatch, "a"}
          ] do
        assert {:malformed, sentence} = BuilderProtocol.refusal_for(error)
        assert sentence == BuilderProtocol.describe(error)
        assert {:ok, line} = BuilderProtocol.encode_refusal({:malformed, sentence}, [])
        assert {:ok, {:refusal, {:malformed, ^sentence}, []}} = BuilderProtocol.read_line(line)
      end

      assert BuilderProtocol.describe({:unpaired, :rust, :tincture}) ==
               "a tincture is not built from rust"
    end
  end

  describe "authentication" do
    @backends %MacEnvelope{
      prefix: "cyfr-locus/v1/backends",
      kind: "request",
      fields: [ts: :integer, nonce: :string],
      body_hash_in_header: true
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

    test "the release is this application's version" do
      assert BuilderProtocol.release() == to_string(Application.spec(:cyfr_contracts, :vsn))
    end
  end

  test "the athanor in the vectors is the one the request names" do
    assert request().athanor_id == @athanor
  end
end
