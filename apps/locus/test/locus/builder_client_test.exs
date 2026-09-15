# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderClientTest do
  @moduledoc """
  What the app node accepts back from the builder container.

  Treat the HTTP builder response as untrusted input. Validate WASM,
  output paths, and base64, and derive size and digest from decoded bytes.
  """
  use ExUnit.Case, async: true

  alias Locus.BuilderClient

  @wasm File.read!(Path.join(__DIR__, "../../../cyfr/test/support/test_wasm/math.wasm"))

  defp built(extra), do: Map.merge(%{"ok" => true}, extra)

  describe "decode_result/1" do
    test "derives the digest and size from the bytes, not from the claim" do
      {:ok, real} = Compendium.WasmValidator.validate(@wasm)

      assert {:ok, result} =
               BuilderClient.decode_result(
                 built(%{
                   "wasm_base64" => Base.encode64(@wasm),
                   "digest" => "sha256:" <> String.duplicate("f", 64),
                   "size" => 1,
                   "lockfile" => "version = 4\n"
                 })
               )

      assert result.wasm_bytes == @wasm
      assert result.digest == real.digest
      assert result.size == real.size
      refute result.digest == "sha256:" <> String.duplicate("f", 64)
      assert result.lockfile == "version = 4\n"
    end

    test "keeps no lock for a component build that answers without one" do
      assert {:ok, %{lockfile: nil}} =
               BuilderClient.decode_result(built(%{"wasm_base64" => Base.encode64(@wasm)}))
    end

    test "refuses a component build whose lock is not text, or past the source ceiling" do
      oversized = String.duplicate("x", Locus.Builder.max_source_bytes() + 1)

      for lockfile <- [42, oversized] do
        body = %{"wasm_base64" => Base.encode64(@wasm), "lockfile" => lockfile}

        assert {:error, {:builder_malformed_result, ["lockfile"]}} =
                 BuilderClient.decode_result(built(body))
      end
    end

    test "refuses bytes that are not a valid component" do
      assert {:error, {:builder_invalid_wasm, _}} =
               BuilderClient.decode_result(built(%{"wasm_base64" => Base.encode64("not wasm")}))
    end

    test "refuses an output path that would escape the unit" do
      for bad <- ["../../etc/passwd", "/abs/path", "a/../../b"] do
        assert {:error, {:builder_unsafe_path, ^bad, _}} =
                 BuilderClient.decode_result(
                   built(%{"output_files" => %{bad => Base.encode64("x")}})
                 ),
               "#{bad} was accepted as an output path"
      end
    end

    test "keeps ordinary output paths, digested as the file set registration digests" do
      assert {:ok, %{output_files: files, digest: digest, size: 9}} =
               BuilderClient.decode_result(
                 built(%{
                   "output_files" => %{"index.html" => Base.encode64("<p>hi</p>")},
                   "digest" => "sha256:" <> String.duplicate("f", 64)
                 })
               )

      assert files == %{"index.html" => "<p>hi</p>"}
      assert {^digest, 9} = Cyfr.Digest.file_set(files)
    end

    test "refuses malformed base64 instead of raising" do
      assert {:error, {:builder_invalid_base64, _}} =
               BuilderClient.decode_result(built(%{"wasm_base64" => "!!!not base64!!!"}))

      assert {:error, {:builder_invalid_base64, _}} =
               BuilderClient.decode_result(
                 built(%{"output_files" => %{"a.txt" => "!!!not base64!!!"}})
               )
    end

    test "refuses a body that carries no artifact at all" do
      assert {:error, {:builder_malformed_result, _}} = BuilderClient.decode_result(built(%{}))
    end
  end

  describe "handle_response/3" do
    @current %{"protocol" => Locus.BuilderProtocol.version(), "version" => "9.9.9"}
    defp ignore(_stage, _line), do: :ok

    test "an answer at this protocol is read; a refusal at capacity or of the build is the builder's" do
      body = Map.merge(@current, %{"ok" => true, "wasm_base64" => Base.encode64(@wasm)})
      assert {:ok, %{wasm_bytes: @wasm}} = BuilderClient.handle_response(200, body, &ignore/2)

      for status <- [422, 429] do
        body = Map.merge(@current, %{"ok" => false, "error" => "nope", "logs" => []})

        assert {:error, {:builder_failed, "nope"}} =
                 BuilderClient.handle_response(status, body, &ignore/2)
      end
    end

    test "an answer at another protocol, or without one, is a mismatch naming the builder's versions" do
      old_builder = %{"ok" => true, "wasm_base64" => Base.encode64(@wasm)}

      assert {:error, {:builder_protocol_mismatch, nil, nil}} =
               BuilderClient.handle_response(200, old_builder, &ignore/2)

      newer = %{"ok" => false, "error" => "…", "protocol" => 2, "version" => "1.0.0"}

      assert {:error, {:builder_protocol_mismatch, 2, "1.0.0"}} =
               BuilderClient.handle_response(409, newer, &ignore/2)
    end

    test "an unauthorized answer and a body that is not JSON keep their own meaning" do
      assert {:error, :builder_unauthorized} = BuilderClient.handle_response(401, %{}, &ignore/2)

      assert {:error, {:builder_unexpected_status, 502}} =
               BuilderClient.handle_response(502, %{}, &ignore/2)
    end
  end
end
