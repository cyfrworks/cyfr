# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.QRTest do
  @moduledoc """
  The QR encoder against ISO/IEC 18004: the worked example's error
  correction codewords (and a second published example's), level M's
  format information for every mask, the version information of versions
  7 to 10, the fixed patterns, and the version each length selects. A
  reader written here from the standard, not from the encoder, takes each
  symbol back: it reads the format information, removes the mask, walks
  the codewords out, checks their error correction and decodes the bytes.
  """

  use ExUnit.Case, async: true

  import Bitwise

  alias PrismWeb.QR

  # ISO/IEC 18004's worked example: "01234567" as version 1-M.
  @iso_data [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11] ++
              [0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
  @iso_ec [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55]

  # "HELLO WORLD" in alphanumeric mode as version 1-M.
  @hello_data [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
  @hello_ec [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]

  # Level M's format information, masks 0 to 7.
  @format_m ~w(101010000010010 101000100100101 101111001111100 101101101001011
               100010111111001 100000011001110 100111110010111 100101010100000)

  # Version information, versions 7 to 10.
  @version_info %{
    7 => "000111110010010100",
    8 => "001000010110111100",
    9 => "001001101010011001",
    10 => "001010010011010011"
  }

  # Level M, per version: error correction codewords per block and the
  # blocks' data lengths, as the standard's table gives them.
  @blocks %{
    1 => {10, [16]},
    2 => {16, [28]},
    3 => {26, [44]},
    4 => {18, [32, 32]},
    5 => {24, [43, 43]},
    6 => {16, [27, 27, 27, 27]},
    7 => {18, [31, 31, 31, 31]},
    8 => {22, [38, 38, 39, 39]},
    9 => {22, [36, 36, 36, 37, 37]},
    10 => {26, [43, 43, 43, 43, 44]}
  }

  @alignment %{
    2 => [6, 18],
    3 => [6, 22],
    4 => [6, 26],
    5 => [6, 30],
    6 => [6, 34],
    7 => [6, 22, 38],
    8 => [6, 24, 42],
    9 => [6, 26, 46],
    10 => [6, 28, 50]
  }

  describe "error correction" do
    test "reproduces the standard's worked example" do
      assert QR.error_correction(@iso_data, 10) == @iso_ec
    end

    test "reproduces a second published example" do
      assert QR.error_correction(@hello_data, 10) == @hello_ec
    end
  end

  describe "format and version information" do
    test "level M's format information for each mask is the standard's table" do
      for {expected, mask} <- Enum.with_index(@format_m) do
        assert bits(QR.format_bits(mask), 15) == expected, "mask #{mask}"
      end
    end

    test "the version information of versions 7 to 10 is the standard's table" do
      for {version, expected} <- @version_info do
        assert bits(QR.version_bits(version), 18) == expected, "version #{version}"
      end
    end
  end

  describe "the version" do
    test "is the smallest that holds the text, up to version 10" do
      capacities = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213]
      assert Enum.map(QR.versions(), &QR.capacity/1) == capacities

      for {capacity, version} <- Enum.with_index(capacities, 1) do
        assert {:ok, %{version: ^version}} = QR.encode(String.duplicate("a", capacity))
      end

      for {capacity, version} <- capacities |> Enum.take(9) |> Enum.with_index(1) do
        next = version + 1
        assert {:ok, %{version: ^next}} = QR.encode(String.duplicate("a", capacity + 1))
      end

      assert QR.encode(String.duplicate("a", 214)) == {:error, :too_long}
    end
  end

  describe "the symbol" do
    test "draws the fixed patterns where the standard puts them" do
      for text <- [
            "a",
            "https://alice.example/pair#code=UjcQhGOiIAu_9xjWI7A-Fw",
            String.duplicate("z", 130),
            String.duplicate("q", 213)
          ] do
        {:ok, %{version: version, modules: rows}} = QR.encode(text)
        size = 17 + 4 * version
        assert length(rows) == size and Enum.all?(rows, &(length(&1) == size))
        at = fn x, y -> rows |> Enum.at(y) |> Enum.at(x) end

        # The three finder patterns and their light separators.
        for {ox, oy} <- [{0, 0}, {size - 7, 0}, {0, size - 7}], dy <- 0..6, dx <- 0..6 do
          ring = max(abs(dx - 3), abs(dy - 3))
          assert at.(ox + dx, oy + dy) == (ring != 2), "finder at #{ox + dx},#{oy + dy}"
        end

        for i <- 0..7 do
          refute at.(7, i) or at.(i, 7)
          refute at.(size - 8, i) or at.(size - 1 - i, 7)
          refute at.(7, size - 1 - i) or at.(i, size - 8)
        end

        # The timing patterns.
        for i <- 8..(size - 9) do
          assert at.(i, 6) == (rem(i, 2) == 0)
          assert at.(6, i) == (rem(i, 2) == 0)
        end

        # The dark module.
        assert at.(8, 4 * version + 9)

        # The alignment patterns, except where a finder sits.
        centres = Map.get(@alignment, version, [])

        for cy <- centres,
            cx <- centres,
            {cx, cy} not in [{6, 6}, {6, size - 7}, {size - 7, 6}],
            dy <- -2..2,
            dx <- -2..2 do
          assert at.(cx + dx, cy + dy) == (max(abs(dx), abs(dy)) != 1)
        end
      end
    end

    test "reads back as its text, whatever the length" do
      for text <- [
            "a",
            "https://alice.example/pair#code=UjcQhGOiIAu_9xjWI7A-Fw",
            "https://home.example:8443/pair#code=" <> String.duplicate("A", 22),
            String.duplicate("0123456789", 9),
            :crypto.strong_rand_bytes(150),
            String.duplicate("q", 213)
          ] do
        {:ok, %{version: version, mask: mask, modules: rows}} = QR.encode(text)
        assert read(rows) == {version, mask, text}
      end
    end

    test "rule 3 scores each exact 1:1:3:1:1 run with four light modules before or after, once" do
      line =
        bits_of(
          # At the edge, the quiet zone before it and four light after: one.
          # Its last dark run is two wide, not one: none.
          # Its first dark run is two wide: none.
          # Four light on both sides: one, not two.
          # Three light on each side: none.
          "1011101" <>
            "0000" <>
            "10111011" <>
            "0000" <>
            "11011101" <>
            "0000" <>
            "1011101" <>
            "0000" <>
            "11" <> "000" <> "1011101" <> "000" <> "11"
        )

      # Five identical rows: each column is one colour, so only the rows
      # score, two runs each.
      rows = List.duplicate(line, 5)
      assert QR.penalties(rows).finders == 5 * 2 * 40

      # The same runs in columns score the same.
      columns = for x <- 0..(length(line) - 1), do: List.duplicate(Enum.at(line, x), 5)
      assert QR.penalties(columns).finders == 5 * 2 * 40

      # A lone finder pattern in a quiet field.
      assert QR.penalties([bits_of("00001011101" <> "00000")]).finders == 40
      # Three light on each side, away from the edge: none.
      assert QR.penalties([bits_of("11000" <> "1011101" <> "00011")]).finders == 0
      # At the edge, three light run on into the quiet zone: one.
      assert QR.penalties([bits_of("000" <> "1011101" <> "00011")]).finders == 40
    end

    test "the mask is the one the penalty scores lowest" do
      {:ok, %{mask: chosen, modules: rows}} =
        QR.encode("https://alice.example/pair#code=UjcQhGOiIAu_9xjWI7A-Fw")

      scored = QR.penalty(rows)
      # Every other mask over the same codewords scores no lower.
      for mask <- 0..7, mask != chosen do
        assert QR.penalty(remask(rows, chosen, mask)) >= scored, "mask #{mask}"
      end
    end

    test "draws as an SVG with its quiet zone and its name" do
      {:ok, svg} = QR.svg("https://alice.example/pair#code=x", label: "Pair <a> device")
      {:ok, %{modules: rows}} = QR.encode("https://alice.example/pair#code=x")
      side = length(rows) + 8

      assert svg =~ ~s(viewBox="0 0 #{side} #{side}")
      assert svg =~ ~s(aria-label="Pair &lt;a&gt; device")
      assert svg =~ ~s(role="img")
      dark = rows |> List.flatten() |> Enum.count(& &1)
      assert length(Regex.scan(~r/h1v1h-1z/, svg)) == dark
      # The first dark module is the finder's corner, inside the quiet zone.
      assert svg =~ ~s(d="M4 4h1v1h-1z)
    end
  end

  # ---------------------------------------------------------------------------
  # A reader, from the standard
  # ---------------------------------------------------------------------------

  defp bits(value, width), do: value |> Integer.to_string(2) |> String.pad_leading(width, "0")

  defp bits_of(text), do: for(<<bit <- text>>, do: bit == ?1)

  defp read(rows) do
    size = length(rows)
    version = div(size - 17, 4)
    at = fn x, y -> rows |> Enum.at(y) |> Enum.at(x) end

    # The first copy of the format information, bit 14 first.
    coords =
      Enum.map(0..5, &{8, &1}) ++ [{8, 7}, {8, 8}, {7, 8}] ++ Enum.map(9..14, &{14 - &1, 8})

    format =
      coords
      |> Enum.with_index()
      |> Enum.reduce(0, fn {{x, y}, i}, acc -> if at.(x, y), do: acc ||| 1 <<< i, else: acc end)

    data = bxor(format, 0b101010000010010) >>> 10
    assert data >>> 3 == 0b00, "level M"
    mask = band(data, 0b111)

    # The second copy says the same.
    second =
      Enum.map(0..7, &{size - 1 - &1, 8}) ++ Enum.map(8..14, &{8, size - 15 + &1})

    assert second
           |> Enum.with_index()
           |> Enum.reduce(0, fn {{x, y}, i}, acc ->
             if at.(x, y), do: acc ||| 1 <<< i, else: acc
           end) == format

    reserved = reserved(version, size)

    stream =
      for right <- Enum.to_list((size - 1)..8//-2) ++ [5, 3, 1],
          vert <- 0..(size - 1),
          j <- 0..1,
          x = right - j,
          y = if(band(right + 1, 2) == 0, do: size - 1 - vert, else: vert),
          not MapSet.member?(reserved, {x, y}),
          do: if(masked?(mask, x, y), do: not at.(x, y), else: at.(x, y))

    {ec, lengths} = Map.fetch!(@blocks, version)
    total = Enum.sum(lengths) + ec * length(lengths)
    codewords = stream |> Enum.take(total * 8) |> Enum.chunk_every(8) |> Enum.map(&byte/1)

    # Undo the interleaving: data column by column, then error correction.
    {data_part, ec_part} = Enum.split(codewords, Enum.sum(lengths))
    blocks = deinterleave(data_part, lengths)
    ecs = deinterleave(ec_part, List.duplicate(ec, length(lengths)))

    for {block, check} <- Enum.zip(blocks, ecs),
        do: assert(QR.error_correction(block, ec) == check)

    bits = for byte <- List.flatten(blocks), into: <<>>, do: <<byte>>
    count = if version < 10, do: 8, else: 16
    <<0b0100::4, length::size(^count), rest::bitstring>> = bits
    <<text::binary-size(^length), _pad::bitstring>> = rest
    {version, mask, text}
  end

  defp byte(bits),
    do: Enum.reduce(bits, 0, fn bit, acc -> acc <<< 1 ||| if(bit, do: 1, else: 0) end)

  defp deinterleave(codewords, lengths) do
    longest = Enum.max(lengths)

    slots =
      for i <- 0..(longest - 1), {length, b} <- Enum.with_index(lengths), i < length, do: {b, i}

    filled = Enum.zip(slots, codewords)

    for b <- 0..(length(lengths) - 1) do
      for {{^b, _i}, value} <- filled, do: value
    end
  end

  # Every module a function pattern, the format information or the version
  # information takes.
  defp reserved(version, size) do
    finders =
      for {ox, oy} <- [{0, 0}, {size - 8, 0}, {0, size - 8}],
          dy <- 0..7,
          dx <- 0..7,
          do: {ox + dx, oy + dy}

    timing = for i <- 0..(size - 1), coord <- [{i, 6}, {6, i}], do: coord
    format = for i <- 0..8, coord <- [{8, i}, {i, 8}], do: coord
    format_far = for i <- 0..7, coord <- [{size - 1 - i, 8}, {8, size - 1 - i}], do: coord
    centres = Map.get(@alignment, version, [])

    alignment =
      for cy <- centres,
          cx <- centres,
          {cx, cy} not in [{6, 6}, {6, size - 7}, {size - 7, 6}],
          dy <- -2..2,
          dx <- -2..2,
          do: {cx + dx, cy + dy}

    version_info =
      if version >= 7,
        do: for(a <- (size - 11)..(size - 9), b <- 0..5, coord <- [{a, b}, {b, a}], do: coord),
        else: []

    MapSet.new(finders ++ timing ++ format ++ format_far ++ alignment ++ version_info)
  end

  defp masked?(0, x, y), do: rem(x + y, 2) == 0
  defp masked?(1, _x, y), do: rem(y, 2) == 0
  defp masked?(2, x, _y), do: rem(x, 3) == 0
  defp masked?(3, x, y), do: rem(x + y, 3) == 0
  defp masked?(4, x, y), do: rem(div(y, 2) + div(x, 3), 2) == 0
  defp masked?(5, x, y), do: rem(x * y, 2) + rem(x * y, 3) == 0
  defp masked?(6, x, y), do: rem(rem(x * y, 2) + rem(x * y, 3), 2) == 0
  defp masked?(7, x, y), do: rem(rem(x + y, 2) + rem(x * y, 3), 2) == 0

  # The same symbol under another mask, its format information rewritten.
  defp remask(rows, from, to) do
    size = length(rows)
    version = div(size - 17, 4)
    reserved = reserved(version, size)

    remasked =
      for {row, y} <- Enum.with_index(rows) do
        for {dark, x} <- Enum.with_index(row) do
          if MapSet.member?(reserved, {x, y}),
            do: dark,
            else: dark != masked?(from, x, y) != masked?(to, x, y)
        end
      end

    format = QR.format_bits(to)

    coords =
      (Enum.map(0..5, &{8, &1}) ++ [{8, 7}, {8, 8}, {7, 8}] ++ Enum.map(9..14, &{14 - &1, 8}))
      |> Enum.with_index()
      |> Enum.concat(
        (Enum.map(0..7, &{size - 1 - &1, 8}) ++ Enum.map(8..14, &{8, size - 15 + &1}))
        |> Enum.with_index()
      )

    Enum.reduce(coords, remasked, fn {{x, y}, i}, acc ->
      List.update_at(acc, y, &List.replace_at(&1, x, band(format >>> i, 1) == 1))
    end)
  end
end
