# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WireJsonTest do
  @moduledoc """
  The JSON and base64 every wire of the worker protocol is read and
  written in, as `tests/fixtures/wire_json.json` holds them: Jason, which
  each wire's reader and writer calls (`Jason.decode/1`, `Jason.encode/1`),
  and Elixir's `Base`. A change of either, or of the Elixir beneath them,
  that changes how a message reads turns a case here red, and the Go
  readers held to the same file with it.
  """
  use ExUnit.Case, async: true

  @vectors Path.expand("../../../../tests/fixtures/wire_json.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "every document reads as its value, an integer as an integer and a float as a float" do
    assert length(@vectors["reads"]) >= 20

    for %{"why" => why, "doc_b64" => doc, "value" => value} <- @vectors["reads"] do
      assert {:ok, read} = Jason.decode(Base.decode64!(doc)), why
      assert read === value, why
    end
  end

  test "an integer reads to the longest the vector names, and one character more is refused" do
    longest = @vectors["max_integer_chars"]
    assert {:ok, _} = Jason.decode(String.duplicate("9", longest))
    assert {:error, _} = Jason.decode(String.duplicate("9", longest + 1))
  end

  test "every refused document is refused" do
    assert length(@vectors["refused"]) >= 35

    for %{"why" => why, "doc_b64" => doc} <- @vectors["refused"] do
      assert {:error, %Jason.DecodeError{}} = Jason.decode(Base.decode64!(doc)), why
    end
  end

  test "every value is written as its bytes" do
    for %{"why" => why, "value" => value, "bytes_b64" => bytes} <- @vectors["writes"] do
      assert Jason.encode!(value) == Base.decode64!(bytes), why
    end
  end

  test "every base64 text reads as Base reads it, or is refused" do
    for {section, decode} <- [
          {"base64url", &Base.url_decode64(&1, padding: false)},
          {"base64", &Base.decode64/1}
        ],
        %{"text" => text, "bytes_hex" => bytes} <- @vectors[section] do
      case bytes do
        nil ->
          assert :error == decode.(text), "#{section} #{inspect(text)}"

        hex ->
          assert {:ok, Base.decode16!(hex, case: :lower)} == decode.(text),
                 "#{section} #{inspect(text)}"
      end
    end
  end
end
