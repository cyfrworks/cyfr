# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderClientTest do
  @moduledoc """
  What the app node accepts back from the builder container.

  The in-process path (`Locus.Builder`) validates the bytes it produced and
  derives the digest, size and exports from that validation. Over HTTP the
  builder is a separate trust domain — its answer is input, and it was being
  taken at its word: the digest and size as claimed, the WASM never validated,
  `output_files` keys handed straight to `Path.split/1`, and two `decode64!`
  calls plus a missing clause that turned a malformed body into a raise
  instead of a refusal.
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

    test "keeps ordinary output paths" do
      assert {:ok, %{output_files: files}} =
               BuilderClient.decode_result(
                 built(%{"output_files" => %{"index.html" => Base.encode64("<p>hi</p>")}})
               )

      assert files == %{"index.html" => "<p>hi</p>"}
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
