# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.JCS do
  @moduledoc """
  Canonical JSON (RFC 8785) over a deliberately restricted domain — the one
  canonicalizer behind every security digest in the system.

  Two structures that mean the same thing must hash the same, and two that
  differ must not. RFC 8785 gives that for JSON, but its number rules are
  the hard part of the spec and floats have no place in a digest input
  anyway: durations and digests are already strings, and every limit is an
  integer. So the canonical domain here is **strings, integers, booleans,
  arrays and string-keyed objects**, and nothing else.

  Everything outside it is a typed error rather than a coercion:

    * floats — `:float_not_permitted`; the value is ambiguous under any
      serializer, and admitting them drags RFC 8785's number formatting
      into a security path
    * `nil` — `:nil_not_permitted`; `%{"a" => nil}` and `%{}` would
      otherwise hash differently, so normalizers must drop absent fields
      instead of emitting null
    * atom keys, non-string keys, structs, out-of-range integers

  ## Object key ordering

  Keys sort by **UTF-16 code unit**, per RFC 8785 §3.2.3 — not by
  code point. The two orders disagree above the BMP: `"\\u{10000}"`
  encodes as the surrogate pair `D800 DC00`, so it sorts *before*
  `"\\uFFFD"` in JCS and *after* it by code point. Golden vectors pin
  this.

  ## Examples

      iex> Sanctum.JCS.encode(%{"b" => 1, "a" => [true, "x"]})
      {:ok, ~s({"a":[true,"x"],"b":1})}

      iex> Sanctum.JCS.encode(%{"n" => 1.5})
      {:error, {:invalid_value, ["n"], :float_not_permitted}}

      iex> {:ok, digest} = Sanctum.JCS.hash(%{"a" => 1})
      iex> String.starts_with?(digest, "sha256:")
      true

  """

  # Beyond 2^53 an integer is not representable exactly as an ECMAScript
  # number, so a JCS consumer could not round-trip it.
  @max_safe_integer 9_007_199_254_740_991

  @type value :: String.t() | integer() | boolean() | [value()] | %{String.t() => value()}
  @type path :: [String.t() | non_neg_integer()]
  @type reason ::
          :float_not_permitted
          | :nil_not_permitted
          | :integer_out_of_range
          | :non_string_key
          | :unsupported_type
  @type error :: {:invalid_value, path(), reason()}

  @doc """
  Canonicalize a term to its RFC 8785 serialization.

  The `path` in an error locates the offending value: object keys and
  array indices, outermost first.
  """
  @spec encode(value()) :: {:ok, binary()} | {:error, error()}
  def encode(term) do
    {:ok, term |> do_encode([]) |> IO.iodata_to_binary()}
  catch
    {:jcs, error} -> {:error, error}
  end

  @doc """
  Canonicalize and hash: `"sha256:" <> lowercase hex`, matching the digest
  convention used for component artifacts.
  """
  @spec hash(value()) :: {:ok, String.t()} | {:error, error()}
  def hash(term) do
    with {:ok, encoded} <- encode(term), do: {:ok, hash_binary(encoded)}
  end

  @doc """
  Hash an already-canonical binary. Exposed so callers that concatenate a
  canonical form with other material (a release digest binds an artifact
  digest to its manifest subset) hash it the same way.
  """
  @spec hash_binary(binary()) :: String.t()
  def hash_binary(binary) when is_binary(binary) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, binary), case: :lower)
  end

  # ============================================================================
  # Private: serialization
  # ============================================================================

  defp do_encode(value, path) when is_binary(value) do
    if String.valid?(value) do
      encode_string(value)
    else
      fail(path, :unsupported_type)
    end
  end

  defp do_encode(true, _path), do: "true"
  defp do_encode(false, _path), do: "false"

  defp do_encode(value, path) when is_integer(value) do
    if abs(value) > @max_safe_integer do
      fail(path, :integer_out_of_range)
    else
      Integer.to_string(value)
    end
  end

  defp do_encode(nil, path), do: fail(path, :nil_not_permitted)
  defp do_encode(value, path) when is_float(value), do: fail(path, :float_not_permitted)

  defp do_encode(value, path) when is_list(value) do
    inner =
      value
      |> Enum.with_index()
      |> Enum.map(fn {element, index} -> do_encode(element, path ++ [index]) end)
      |> Enum.intersperse(",")

    ["[", inner, "]"]
  end

  defp do_encode(value, path) when is_map(value) and not is_struct(value) do
    inner =
      value
      |> Enum.map(fn {key, member} -> {check_key(key, path), member} end)
      |> Enum.sort_by(fn {key, _} -> utf16_sort_key(key) end)
      |> Enum.map(fn {key, member} ->
        [encode_string(key), ":", do_encode(member, path ++ [key])]
      end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp do_encode(_value, path), do: fail(path, :unsupported_type)

  defp check_key(key, _path) when is_binary(key), do: key
  defp check_key(_key, path), do: fail(path, :non_string_key)

  # RFC 8785 §3.2.3: sort by UTF-16 code unit, which is byte order over the
  # big-endian UTF-16 encoding.
  defp utf16_sort_key(key), do: :unicode.characters_to_binary(key, :utf8, {:utf16, :big})

  # RFC 8785 §3.2.2.2: the seven two-character escapes, \u00xx (lowercase
  # hex) for the remaining C0 controls, and every other character — including
  # all non-ASCII — emitted literally as UTF-8.
  defp encode_string(string) do
    ["\"", string |> :binary.bin_to_list() |> escape_bytes([]) |> Enum.reverse(), "\""]
  end

  defp escape_bytes([], acc), do: acc
  defp escape_bytes([?" | rest], acc), do: escape_bytes(rest, ["\\\"" | acc])
  defp escape_bytes([?\\ | rest], acc), do: escape_bytes(rest, ["\\\\" | acc])
  defp escape_bytes([?\b | rest], acc), do: escape_bytes(rest, ["\\b" | acc])
  defp escape_bytes([?\f | rest], acc), do: escape_bytes(rest, ["\\f" | acc])
  defp escape_bytes([?\n | rest], acc), do: escape_bytes(rest, ["\\n" | acc])
  defp escape_bytes([?\r | rest], acc), do: escape_bytes(rest, ["\\r" | acc])
  defp escape_bytes([?\t | rest], acc), do: escape_bytes(rest, ["\\t" | acc])

  defp escape_bytes([byte | rest], acc) when byte < 0x20 do
    escape_bytes(rest, ["\\u00" <> Base.encode16(<<byte>>, case: :lower) | acc])
  end

  defp escape_bytes([byte | rest], acc), do: escape_bytes(rest, [<<byte>> | acc])

  defp fail(path, reason), do: throw({:jcs, {:invalid_value, path, reason}})
end
