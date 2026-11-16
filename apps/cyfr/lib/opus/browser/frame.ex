# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Browser.Frame do
  @moduledoc """
  The browser driver's framing, the host's side (`Opus.Browser`): every
  message each way over the driver's terminal session is one frame, and
  `tests/fixtures/browser_frames.json` binds this module and the driver
  (`apps/locus/keeper/cmd/cyfr-browser`) to the same bytes.

  A frame is `0x1E`, `"B1"`, the body's length in bytes as 8 lowercase
  hex digits, the first 8 bytes of the body's SHA-256 as 16 lowercase hex
  digits, the body, and `0x0A`. The body is one JSON object, which holds
  no byte below `0x20`, so a `0x1E` never appears inside a body and a
  frame cut anywhere never reads as whole.

  `decode/2` drops every byte before a `0x1E`; skips a `0x1E` whose
  header does not read (a byte that is not a lowercase hex digit, a
  length of 0 or past the bound), whose claimed body holds a `0x1E` (the
  frame was cut), whose body's digest differs or that is not followed by
  `0x0A`, and takes up at the next `0x1E` after it; and holds an
  incomplete frame until more bytes come.
  """

  @start <<0x1E, "B1">>
  @header_bytes 27
  @max_to_host 131_072
  @max_to_driver 8_388_608
  @max_response 16_777_216
  @put_max_bytes 33_554_432
  @put_max_files 1_024
  @put_part_bytes 1_048_576

  @doc "The most bytes a body the driver sends may hold."
  @spec max_to_host() :: pos_integer()
  def max_to_host, do: @max_to_host

  @doc "The most bytes a body the host sends may hold."
  @spec max_to_driver() :: pos_integer()
  def max_to_driver, do: @max_to_driver

  @doc """
  The most bytes a response's text may hold, assembled from its chunks:
  the driver sends none longer, and the host takes no more of one.
  """
  @spec max_response() :: pos_integer()
  def max_response, do: @max_response

  @doc """
  The most bytes one put hands the driver, its files' together: the
  driver takes no more, and the host refuses a larger put before it
  writes any of it.
  """
  @spec put_max_bytes() :: pos_integer()
  def put_max_bytes, do: @put_max_bytes

  @doc "The most files one put hands the driver."
  @spec put_max_files() :: pos_integer()
  def put_max_files, do: @put_max_files

  @doc "The most of a put's bytes one `part` message carries, before base64."
  @spec put_part_bytes() :: pos_integer()
  def put_part_bytes, do: @put_part_bytes

  @doc "The frame of one message, its body `map` as JSON."
  @spec message(map()) :: binary()
  def message(map) when is_map(map), do: encode(Jason.encode!(map))

  @doc "The frame of one body, a JSON object's text."
  @spec encode(binary()) :: binary()
  def encode(body) when is_binary(body) do
    @start <>
      hex(byte_size(body), 8) <> Base.encode16(digest(body), case: :lower) <> body <> "\n"
  end

  @doc """
  The whole frames' bodies in `buffer`, in order, and the bytes still
  held waiting for more: an incomplete frame's, or nothing.
  """
  @spec decode(binary(), pos_integer()) :: {[binary()], binary()}
  def decode(buffer, max \\ @max_to_host) when is_binary(buffer),
    do: take(buffer, max, [])

  defp take(buffer, max, bodies) do
    case :binary.match(buffer, <<0x1E>>) do
      :nomatch ->
        {Enum.reverse(bodies), ""}

      {at, 1} ->
        frame = binary_part(buffer, at, byte_size(buffer) - at)

        case read(frame, max) do
          {:whole, body, rest} -> take(rest, max, [body | bodies])
          :waiting -> {Enum.reverse(bodies), frame}
          :skip -> take(binary_part(frame, 1, byte_size(frame) - 1), max, bodies)
        end
    end
  end

  # One frame at the head of `frame`, which starts with 0x1E.
  defp read(frame, _max) when byte_size(frame) < @header_bytes do
    if header_prefix?(frame), do: :waiting, else: :skip
  end

  defp read(<<@start, length::binary-size(8), digest::binary-size(16), rest::binary>>, max) do
    with {:ok, length} <- hex_value(length),
         true <- length in 1..max//1,
         true <- lower_hex?(digest) do
      body_of(rest, length, digest)
    else
      _malformed -> :skip
    end
  end

  defp read(_frame, _max), do: :skip

  defp body_of(rest, length, digest) do
    cond do
      byte_size(rest) <= length ->
        if String.contains?(rest, <<0x1E>>), do: :skip, else: :waiting

      true ->
        <<body::binary-size(^length), ending, after_frame::binary>> = rest

        if ending == ?\n and not String.contains?(body, <<0x1E>>) and
             Base.encode16(digest(body), case: :lower) == digest,
           do: {:whole, body, after_frame},
           else: :skip
    end
  end

  # The bytes of an incomplete header that could still be a frame's.
  defp header_prefix?(<<0x1E, rest::binary>>) do
    marked = min(2, byte_size(rest))
    <<marker::binary-size(^marked), hex::binary>> = rest
    binary_part("B1", 0, marked) == marker and lower_hex?(hex)
  end

  defp lower_hex?(text), do: text =~ ~r/\A[0-9a-f]*\z/

  defp hex_value(text) do
    if byte_size(text) == 8 and lower_hex?(text),
      do: {:ok, String.to_integer(text, 16)},
      else: :error
  end

  defp hex(value, width),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  defp digest(body), do: binary_part(:crypto.hash(:sha256, body), 0, 8)
end
