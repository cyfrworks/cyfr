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
                   "size" => 1
                 })
               )

      assert result.wasm_bytes == @wasm
      assert result.digest == real.digest
      assert result.size == real.size
      refute result.digest == "sha256:" <> String.duplicate("f", 64)
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
end
