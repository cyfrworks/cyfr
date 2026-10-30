# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.RecoveryCodeTest do
  @moduledoc """
  A person's recovery code as data (`tests/fixtures/recovery_code.json`):
  each valid case's code composed from its identifier and secret, every
  case read to what the fixture says, and the alphabet it is spelled in.
  """
  use ExUnit.Case, async: true

  alias Prima.{Crockford, RecoveryCode}

  @vectors Path.expand("../../../../tests/fixtures/recovery_code.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp bytes(text) do
    {:ok, bytes} = Base.url_decode64(text, padding: false)
    bytes
  end

  test "the check's domain is the fixture's protocol" do
    assert RecoveryCode.protocol() == vectors()["protocol"]
  end

  test "each valid case's code is composed from its identifier and secret, 130 characters in 14 groups of 8" do
    for %{"name" => name, "identifier" => identifier, "secret" => secret, "code" => code} <-
          vectors()["valid"] do
      assert RecoveryCode.encode(identifier, bytes(secret)) == code, name
      assert code =~ ~r/\ACYFR(-[0-9A-HJKMNP-TV-Z]{8}){14}\z/, name
      assert String.length(code) == 130, name
    end
  end

  test "each valid case reads to its identifier and secret" do
    for %{"name" => name, "identifier" => identifier, "secret" => secret, "code" => code} <-
          vectors()["valid"] do
      assert RecoveryCode.decode(code) == {:ok, %{identifier: identifier, secret: bytes(secret)}},
             name
    end
  end

  test "each spelling reads as its code" do
    for %{"name" => name, "text" => text, "code" => code} <- vectors()["spellings"] do
      assert {:ok, read} = RecoveryCode.decode(code), name
      assert RecoveryCode.decode(text) == {:ok, read}, name
    end
  end

  test "each refused text is refused with its error" do
    for %{"name" => name, "text" => text, "error" => error} <- vectors()["refused"] do
      assert RecoveryCode.decode(text) == {:error, String.to_existing_atom(error)}, name
    end
  end

  test "what is not text is not a code" do
    for input <- [nil, 42, :code, ["CYFR"], %{}] do
      assert RecoveryCode.decode(input) == {:error, :not_a_code}
    end
  end

  test "encode/2 takes only a person identifier and a 32-byte secret" do
    %{"identifier" => identifier, "secret" => secret} = hd(vectors()["valid"])
    secret = bytes(secret)

    assert_raise ArgumentError, fn -> RecoveryCode.encode("per_short", secret) end
    assert_raise ArgumentError, fn -> RecoveryCode.encode(String.upcase(identifier), secret) end

    assert_raise FunctionClauseError, fn ->
      RecoveryCode.encode(identifier, binary_part(secret, 0, 31))
    end

    assert_raise FunctionClauseError, fn -> RecoveryCode.encode(identifier, secret <> <<0>>) end
  end

  describe "Prima.Crockford" do
    test "spells five bits a symbol, most significant first, in the one alphabet" do
      assert Crockford.alphabet() == "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
      assert Crockford.encode(<<>>) == ""
      assert Crockford.encode(<<0::5>>) == "0"
      assert Crockford.encode(<<31::5>>) == "Z"
      assert Crockford.encode(<<1::5, 2::5, 31::5>>) == "12Z"
      assert Crockford.encode(<<0b10000_01000::10>>) == "G8"

      for value <- 0..31 do
        assert Crockford.decode(Crockford.encode(<<value::5>>)) == {:ok, <<value::5>>}
      end
    end

    test "reads O as 0 and I and L as 1, and nothing else outside the alphabet" do
      assert Crockford.decode("OIL") == {:ok, <<0::5, 1::5, 1::5>>}
      assert Crockford.decode("") == {:ok, <<>>}

      for text <- ["U", "u", "a", "0-1", "0 1", "é", "*", "o", "i", "l"] do
        assert Crockford.decode(text) == :error, text
      end
    end

    test "round-trips bytes and takes only whole symbols" do
      bytes = :crypto.strong_rand_bytes(70)
      assert {:ok, ^bytes} = Crockford.decode(Crockford.encode(bytes))
      assert_raise FunctionClauseError, fn -> Crockford.encode(<<1, 2>>) end
    end
  end
end
