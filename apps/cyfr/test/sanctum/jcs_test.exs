# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.JCSTest do
  use ExUnit.Case, async: true

  alias Sanctum.JCS

  doctest Sanctum.JCS

  defp encode!(term) do
    {:ok, encoded} = JCS.encode(term)
    encoded
  end

  # ============================================================================
  # Primitives
  # ============================================================================

  describe "primitives" do
    test "strings, integers and booleans" do
      assert encode!("hello") == ~s("hello")
      assert encode!(0) == "0"
      assert encode!(-42) == "-42"
      assert encode!(true) == "true"
      assert encode!(false) == "false"
    end

    test "integers are exact up to 2^53 - 1 and rejected beyond" do
      max = 9_007_199_254_740_991

      assert encode!(max) == "9007199254740991"
      assert encode!(-max) == "-9007199254740991"
      assert {:error, {:invalid_value, [], :integer_out_of_range}} = JCS.encode(max + 1)
      assert {:error, {:invalid_value, [], :integer_out_of_range}} = JCS.encode(-max - 1)
    end
  end

  # ============================================================================
  # Rejections — the restricted domain
  # ============================================================================

  describe "restricted domain" do
    test "floats are never canonical" do
      assert {:error, {:invalid_value, [], :float_not_permitted}} = JCS.encode(1.5)
      assert {:error, {:invalid_value, ["a"], :float_not_permitted}} = JCS.encode(%{"a" => 0.1})

      assert {:error, {:invalid_value, ["a", 1], :float_not_permitted}} =
               JCS.encode(%{"a" => [1, 2.0]})
    end

    test "nil is rejected so absent and null cannot both be representable" do
      assert {:error, {:invalid_value, [], :nil_not_permitted}} = JCS.encode(nil)
      assert {:error, {:invalid_value, ["a"], :nil_not_permitted}} = JCS.encode(%{"a" => nil})
    end

    test "non-string keys, atoms, structs and invalid UTF-8 are rejected" do
      assert {:error, {:invalid_value, [], :non_string_key}} = JCS.encode(%{a: 1})
      assert {:error, {:invalid_value, [], :non_string_key}} = JCS.encode(%{1 => "x"})
      assert {:error, {:invalid_value, [], :unsupported_type}} = JCS.encode(:atom)
      assert {:error, {:invalid_value, [], :unsupported_type}} = JCS.encode({1, 2})
      assert {:error, {:invalid_value, [], :unsupported_type}} = JCS.encode(~D[2026-08-07])
      assert {:error, {:invalid_value, [], :unsupported_type}} = JCS.encode(<<0xFF, 0xFE>>)
    end

    test "error paths locate the offending value" do
      term = %{"outer" => %{"list" => [%{"deep" => 1.0}]}}

      assert {:error, {:invalid_value, ["outer", "list", 0, "deep"], :float_not_permitted}} =
               JCS.encode(term)
    end
  end

  # ============================================================================
  # Structure
  # ============================================================================

  describe "structure" do
    test "objects serialize with sorted keys and no whitespace" do
      assert encode!(%{"b" => 1, "a" => 2, "c" => 3}) == ~s({"a":2,"b":1,"c":3})
      assert encode!(%{}) == "{}"
    end

    test "arrays preserve order" do
      assert encode!([3, 1, 2]) == "[3,1,2]"
      assert encode!([]) == "[]"
      assert encode!([[1], [2, 3]]) == "[[1],[2,3]]"
    end

    test "insertion order never affects the encoding" do
      a = %{"z" => 1, "y" => 2, "x" => 3}
      b = %{"x" => 3, "y" => 2, "z" => 1}

      assert encode!(a) == encode!(b)
      assert JCS.hash(a) == JCS.hash(b)
    end

    test "nested objects sort at every level" do
      term = %{"b" => %{"d" => 1, "c" => 2}, "a" => [%{"f" => 1, "e" => 2}]}
      assert encode!(term) == ~s({"a":[{"e":2,"f":1}],"b":{"c":2,"d":1}})
    end
  end

  # ============================================================================
  # RFC 8785 golden vectors
  # ============================================================================

  describe "golden vectors" do
    test "string escaping: two-char escapes, \\u00xx controls, literal non-ASCII" do
      assert encode!("a\"b\\c") == ~s("a\\"b\\\\c")
      assert encode!("\b\f\n\r\t") == ~S("\b\f\n\r\t")
      # Remaining C0 controls take the lowercase \u00xx form. Only C0 —
      assert encode!(<<0x00, 0x1F>>) == "\"" <> "\\u0000" <> "\\u001f" <> "\""
      # Non-ASCII — including C1 controls like U+0080 — stays literal UTF-8.
      assert encode!(<<0xC2, 0x80>>) == "\"" <> <<0xC2, 0x80>> <> "\""
      assert encode!("é☃🙂") == ~s("é☃🙂")
      assert encode!("Ω") == ~s("Ω")
    end

    test "keys sort by UTF-16 code unit, not code point" do
      # RFC 8785 §3.2.3: the orders disagree above the BMP. U+10000 encodes
      # as the surrogate pair D800 DC00, so it sorts BEFORE U+FFFD in JCS —
      # the reverse of code-point order. This is the vector that catches a
      # naive Enum.sort/1.
      assert encode!(%{"\u{10000}" => 1, "�" => 2}) == ~s({"\u{10000}":1,"�":2})

      # A plain code-point sort would put U+FFFD first; assert we don't.
      refute encode!(%{"\u{10000}" => 1, "�" => 2}) ==
               ~s({"�":2,"\u{10000}":1})
    end

    test "the RFC 8785 appendix key set (non-float subset)" do
      term = %{
        "€" => "Euro Sign",
        "\r" => "Carriage Return",
        "\u{1f600}" => "Emoji: Grinning Face",
        "" => "Control",
        "ö" => "Latin Small Letter O With Diaeresis"
      }

      assert encode!(term) ==
               ~s({"\\r":"Carriage Return",) <>
                 ~s("":"Control",) <>
                 ~s("ö":"Latin Small Letter O With Diaeresis",) <>
                 ~s("€":"Euro Sign",) <>
                 ~s("\u{1f600}":"Emoji: Grinning Face"})
    end

    test "mixed structure vector" do
      term = %{
        "peach" => "This sorting order",
        "püree" => "is wrong according to French",
        "pumpkin" => "This sorting order is correct"
      }

      assert encode!(term) ==
               ~s({"peach":"This sorting order",) <>
                 ~s("pumpkin":"This sorting order is correct",) <>
                 ~s("püree":"is wrong according to French"})
    end
  end

  # ============================================================================
  # Hashing
  # ============================================================================

  describe "hash/1 and hash_binary/1" do
    test "hash matches the artifact digest convention" do
      {:ok, digest} = JCS.hash(%{"a" => 1})

      assert digest == JCS.hash_binary(~s({"a":1}))
      assert "sha256:" <> hex = digest
      assert String.length(hex) == 64
      assert hex == String.downcase(hex)
    end

    test "distinct canonical forms hash distinctly" do
      {:ok, a} = JCS.hash(%{"a" => 1})
      {:ok, b} = JCS.hash(%{"a" => 2})
      {:ok, c} = JCS.hash(%{"a" => "1"})

      assert a != b
      assert a != c
    end

    test "hash propagates encode errors" do
      assert {:error, {:invalid_value, ["a"], :float_not_permitted}} = JCS.hash(%{"a" => 1.0})
    end
  end

  # ============================================================================
  # The Phase 1 resolved-policy fixture, as a real-world vector
  # ============================================================================

  test "the resolved-policy golden fixture canonicalizes and is stable" do
    fixture =
      [__DIR__, "../support/fixtures/authority/resolved_policy_golden.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, encoded} = JCS.encode(fixture)
    # Canonical output re-parses to the same term and re-canonicalizes to
    # itself — the idempotence property every digest input relies on.
    assert Jason.decode!(encoded) == fixture
    assert {:ok, ^encoded} = JCS.encode(Jason.decode!(encoded))
    assert String.starts_with?(encoded, ~s({"canonical":"jcs-1","nodes":))
  end
end
