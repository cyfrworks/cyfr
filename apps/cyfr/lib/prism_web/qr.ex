# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.QR do
  @moduledoc """
  A QR code for a short text, as ISO/IEC 18004 builds one: byte mode,
  error correction level M, the smallest of versions 1 to 10 that holds
  the text (at most 213 bytes), and the mask the standard's four penalty
  rules score lowest. The system layer draws a pairing link with it
  (`svg/2`); nothing else is encoded, so nothing here needs the other
  modes, levels or versions.

  `encode/1` answers the symbol as rows of modules, `true` for dark,
  without the quiet zone; `svg/2` draws it with the four-module quiet
  zone the standard requires.
  """

  import Bitwise

  # Level M, per version: error correction codewords per block, and the
  # blocks as `{count, data codewords each}`.
  @blocks %{
    1 => {10, [{1, 16}]},
    2 => {16, [{1, 28}]},
    3 => {26, [{1, 44}]},
    4 => {18, [{2, 32}]},
    5 => {24, [{2, 43}]},
    6 => {16, [{4, 27}]},
    7 => {18, [{4, 31}]},
    8 => {22, [{2, 38}, {2, 39}]},
    9 => {22, [{3, 36}, {2, 37}]},
    10 => {26, [{4, 43}, {1, 44}]}
  }

  # The rows and columns of alignment pattern centres, per version.
  @alignment %{
    1 => [],
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

  # Level M's two format bits, and the mask the format bits are XORed with.
  @level_m 0b00
  @format_mask 0b101010000010010

  # The byte-mode indicator.
  @byte_mode 0b0100

  @typedoc "The modules of a symbol, row by row, `true` dark."
  @type matrix :: [[boolean()]]

  @doc "The versions this encoder draws."
  @spec versions() :: Range.t()
  def versions, do: 1..10

  @doc "The most bytes `version` holds in byte mode at level M."
  @spec capacity(1..10) :: non_neg_integer()
  def capacity(version) when version in 1..10 do
    div(data_codewords(version) * 8 - 4 - count_bits(version), 8)
  end

  @doc """
  The symbol for `text`: `{:ok, %{version:, mask:, modules:}}`, or
  `{:error, :too_long}` for more bytes than version 10 holds.
  """
  @spec encode(binary()) ::
          {:ok, %{version: 1..10, mask: 0..7, modules: matrix()}} | {:error, :too_long}
  def encode(text) when is_binary(text) do
    case Enum.find(versions(), &(capacity(&1) >= byte_size(text))) do
      nil ->
        {:error, :too_long}

      version ->
        codewords = text |> data_codewords(version) |> interleave(version)
        {base, function} = base(version)
        placed = place(base, function, codewords, size(version))

        {mask, modules} =
          0..7
          |> Enum.map(fn mask -> {mask, finish(placed, function, version, mask)} end)
          |> Enum.min_by(fn {_mask, modules} -> penalty(modules) end)

        {:ok, %{version: version, mask: mask, modules: to_rows(modules, size(version))}}
    end
  end

  @doc """
  `text` as an SVG image: dark modules on a light ground, with the quiet
  zone. `opts`: `:label`, the image's accessible name (default "QR
  code"), and `:class`.
  """
  @spec svg(binary(), keyword()) :: {:ok, String.t()} | {:error, :too_long}
  def svg(text, opts \\ []) when is_binary(text) do
    with {:ok, %{modules: rows}} <- encode(text) do
      quiet = 4
      side = length(rows) + 2 * quiet

      path =
        for {row, y} <- Enum.with_index(rows),
            {true, x} <- Enum.with_index(row),
            into: "",
            do: "M#{x + quiet} #{y + quiet}h1v1h-1z"

      label = opts |> Keyword.get(:label, "QR code") |> escape()
      class = opts |> Keyword.get(:class, "") |> escape()

      {:ok,
       ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{side} #{side}" ) <>
         ~s(role="img" aria-label="#{label}" class="#{class}" shape-rendering="crispEdges">) <>
         ~s(<rect width="#{side}" height="#{side}" fill="#fff"/>) <>
         ~s(<path d="#{path}" fill="#000"/></svg>)}
    end
  end

  # ---------------------------------------------------------------------------
  # Data and error correction
  # ---------------------------------------------------------------------------

  @doc false
  # The data codewords of `text` in `version`: mode, count, the bytes, the
  # terminator, zero bits to a byte boundary, then the pad bytes.
  @spec data_codewords(binary(), 1..10) :: [byte()]
  def data_codewords(text, version) do
    capacity = data_codewords(version)
    count = count_bits(version)
    bits = <<@byte_mode::4, byte_size(text)::size(count), text::binary>>
    room = capacity * 8 - bit_size(bits)
    terminated = <<bits::bitstring, 0::size(min(4, room))>>
    padded = <<terminated::bitstring, 0::size(rem(8 - rem(bit_size(terminated), 8), 8))>>
    bytes = :binary.bin_to_list(padded)
    bytes ++ Enum.take(Stream.cycle([0xEC, 0x11]), capacity - length(bytes))
  end

  defp data_codewords(version) do
    {_ec, groups} = Map.fetch!(@blocks, version)
    Enum.reduce(groups, 0, fn {count, size}, sum -> sum + count * size end)
  end

  defp count_bits(version) when version < 10, do: 8
  defp count_bits(_version), do: 16

  # The final sequence: each block's data codewords taken column by column,
  # then each block's error correction codewords the same way.
  defp interleave(data, version) do
    {ec, groups} = Map.fetch!(@blocks, version)

    {blocks, []} =
      Enum.reduce(groups, {[], data}, fn {count, size}, {blocks, rest} ->
        Enum.reduce(1..count, {blocks, rest}, fn _n, {blocks, rest} ->
          {block, rest} = Enum.split(rest, size)
          {blocks ++ [block], rest}
        end)
      end)

    columns(blocks) ++ columns(Enum.map(blocks, &error_correction(&1, ec)))
  end

  defp columns(blocks) do
    longest = blocks |> Enum.map(&length/1) |> Enum.max()

    for i <- 0..(longest - 1), block <- blocks, i < length(block), do: Enum.at(block, i)
  end

  @doc false
  # The `count` Reed-Solomon codewords of `data` over GF(256), under the
  # field's polynomial x^8 + x^4 + x^3 + x^2 + 1.
  @spec error_correction([byte()], pos_integer()) :: [byte()]
  def error_correction(data, count) do
    generator = generator(count)

    data
    |> Enum.reduce(List.duplicate(0, count), fn byte, remainder ->
      [head | tail] = remainder
      factor = bxor(byte, head)
      shifted = tail ++ [0]

      Enum.zip_with(shifted, generator, fn r, g -> bxor(r, multiply(g, factor)) end)
    end)
  end

  # The generator's coefficients after its leading 1, highest degree first:
  # the product of (x - α^i) for i below `count`.
  defp generator(count) do
    Enum.reduce(0..(count - 1), [1], fn i, poly ->
      root = power(i)
      # poly × (x + α^i), coefficients highest degree first.
      Enum.zip_with(poly ++ [0], [0 | poly], fn a, b -> bxor(a, multiply(b, root)) end)
    end)
    |> tl()
  end

  defp power(0), do: 1

  defp power(n) do
    Enum.reduce(1..n, 1, fn _i, x ->
      x = x <<< 1
      if x >= 0x100, do: bxor(x, 0x11D), else: x
    end)
  end

  defp multiply(a, b), do: multiply(a, b, 0)

  defp multiply(_a, 0, product), do: product

  defp multiply(a, b, product) do
    product = if band(b, 1) == 1, do: bxor(product, a), else: product
    a = a <<< 1
    a = if a >= 0x100, do: bxor(a, 0x11D), else: a
    multiply(a, b >>> 1, product)
  end

  # ---------------------------------------------------------------------------
  # The symbol
  # ---------------------------------------------------------------------------

  defp size(version), do: 17 + 4 * version

  # The function patterns: the modules they draw, and every module they
  # (with the format and version areas) reserve, which data never takes.
  defp base(version) do
    size = size(version)
    last = size - 1

    finder =
      for {cx, cy} <- [{3, 3}, {last - 3, 3}, {3, last - 3}],
          dy <- -4..4,
          dx <- -4..4,
          x = cx + dx,
          y = cy + dy,
          x in 0..last and y in 0..last,
          into: %{} do
        ring = max(abs(dx), abs(dy))
        {{x, y}, ring not in [2, 4]}
      end

    timing =
      for i <- 8..(last - 8), coord <- [{i, 6}, {6, i}], into: %{} do
        {coord, rem(i, 2) == 0}
      end

    centres = Map.fetch!(@alignment, version)

    alignment =
      for cy <- centres,
          cx <- centres,
          not Map.has_key?(finder, {cx, cy}),
          dy <- -2..2,
          dx <- -2..2,
          into: %{} do
        {{cx + dx, cy + dy}, max(abs(dx), abs(dy)) != 1}
      end

    reserved =
      format_coords(size) ++ if(version >= 7, do: version_coords(size), else: [])

    drawn =
      %{}
      |> Map.merge(timing)
      |> Map.merge(alignment)
      |> Map.merge(finder)
      |> Map.put({8, size - 8}, true)

    function = drawn |> Map.keys() |> Enum.concat(reserved) |> MapSet.new()
    {drawn, function}
  end

  # The format information's modules, bit 0 first, for both copies.
  defp format_coords(size) do
    first =
      Enum.map(0..5, &{8, &1}) ++
        [{8, 7}, {8, 8}, {7, 8}] ++ Enum.map(9..14, &{14 - &1, 8})

    second = Enum.map(0..7, &{size - 1 - &1, 8}) ++ Enum.map(8..14, &{8, size - 15 + &1})
    first ++ second
  end

  # The version information's modules, bit 0 first, each bit in its two
  # places: the top-right block, then the bottom-left one.
  defp version_coords(size) do
    for i <- 0..17, a = size - 11 + rem(i, 3), b = div(i, 3), coord <- [{a, b}, {b, a}], do: coord
  end

  # The codewords' bits in the standard's zigzag: column pairs from the
  # right edge, skipping the vertical timing column, upward then downward,
  # into every module no function pattern reserves. Remainder bits stay
  # light.
  defp place(base, function, codewords, size) do
    bits = for byte <- codewords, i <- 7..0//-1, do: band(byte >>> i, 1) == 1
    rights = Enum.to_list((size - 1)..8//-2) ++ [5, 3, 1]

    order =
      for right <- rights,
          vert <- 0..(size - 1),
          j <- 0..1,
          x = right - j,
          y = if(band(right + 1, 2) == 0, do: size - 1 - vert, else: vert),
          not MapSet.member?(function, {x, y}),
          do: {x, y}

    {data, _remainder} = Enum.split(order, length(bits))
    Map.merge(base, Map.new(Enum.zip(data, bits)))
  end

  # The masked symbol with its format and version information drawn.
  defp finish(placed, function, version, mask) do
    size = size(version)

    masked =
      for y <- 0..(size - 1), x <- 0..(size - 1), into: %{} do
        dark = Map.get(placed, {x, y}, false)

        if MapSet.member?(function, {x, y}),
          do: {{x, y}, dark},
          else: {{x, y}, if(masked?(mask, x, y), do: not dark, else: dark)}
      end

    format = format_bits(mask)

    masked =
      size
      |> format_coords()
      |> Enum.with_index()
      |> Enum.reduce(masked, fn {coord, i}, acc ->
        Map.put(acc, coord, band(format >>> rem(i, 15), 1) == 1)
      end)
      |> Map.put({8, size - 8}, true)

    if version >= 7 do
      bits = version_bits(version)

      size
      |> version_coords()
      |> Enum.with_index()
      |> Enum.reduce(masked, fn {coord, i}, acc ->
        Map.put(acc, coord, band(bits >>> div(i, 2), 1) == 1)
      end)
    else
      masked
    end
  end

  defp masked?(0, x, y), do: rem(x + y, 2) == 0
  defp masked?(1, _x, y), do: rem(y, 2) == 0
  defp masked?(2, x, _y), do: rem(x, 3) == 0
  defp masked?(3, x, y), do: rem(x + y, 3) == 0
  defp masked?(4, x, y), do: rem(div(x, 3) + div(y, 2), 2) == 0
  defp masked?(5, x, y), do: rem(x * y, 2) + rem(x * y, 3) == 0
  defp masked?(6, x, y), do: rem(rem(x * y, 2) + rem(x * y, 3), 2) == 0
  defp masked?(7, x, y), do: rem(rem(x + y, 2) + rem(x * y, 3), 2) == 0

  @doc false
  # Level M's 15 format bits for `mask`: the five data bits, their
  # BCH(15,5) remainder under 0x537, XORed with the format mask.
  @spec format_bits(0..7) :: non_neg_integer()
  def format_bits(mask) when mask in 0..7 do
    data = @level_m <<< 3 ||| mask
    bxor(data <<< 10 ||| bch(data, 10, 0x537), @format_mask)
  end

  @doc false
  # The 18 version bits for `version`: six data bits and their BCH(18,6)
  # remainder under 0x1F25.
  @spec version_bits(7..10) :: non_neg_integer()
  def version_bits(version) when version in 7..10,
    do: version <<< 12 ||| bch(version, 12, 0x1F25)

  defp bch(data, degree, generator) do
    Enum.reduce(1..degree, data, fn _i, r ->
      bxor(r <<< 1, (r >>> (degree - 1)) * generator)
    end)
  end

  # ---------------------------------------------------------------------------
  # The penalty
  # ---------------------------------------------------------------------------

  @doc false
  # The standard's penalty for a masked symbol (ISO/IEC 18004, 7.8.3.1):
  # the sum of its four rules' scores (`penalties/1`).
  @spec penalty(map() | matrix()) :: non_neg_integer()
  def penalty(symbol) do
    %{runs: runs, blocks: blocks, finders: finders, balance: balance} = penalties(symbol)
    runs + blocks + finders + balance
  end

  @doc false
  # Each rule's score, for rows of modules (`true` dark) or a symbol's
  # module map:
  #
  #   * `runs` — each run of five or more modules of one colour in a row or
  #     column, 3 plus one for each module past five;
  #   * `blocks` — each 2×2 block of one colour, 3;
  #   * `finders` — each run in a row or column of exactly 1:1:3:1:1
  #     dark, light, dark, light, dark modules, bounded by light, with a
  #     light area at least four modules wide before or after it, 40; the
  #     quiet zone beyond the symbol's edge is light;
  #   * `balance` — 10 for each whole 5% the dark modules' share departs
  #     from half, beyond the first.
  @spec penalties(map() | matrix()) :: %{
          runs: non_neg_integer(),
          blocks: non_neg_integer(),
          finders: non_neg_integer(),
          balance: non_neg_integer()
        }
  def penalties(rows) when is_list(rows) do
    width = rows |> List.first([]) |> length()
    columns = for x <- 0..(width - 1)//1, do: Enum.map(rows, &Enum.at(&1, x))
    lines = rows ++ columns

    blocks =
      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [upper, lower] ->
        Enum.zip([upper, tl(upper), lower, tl(lower)])
        |> Enum.count(fn {a, b, c, d} -> a == b and a == c and a == d end)
      end)
      |> Enum.sum()

    total = Enum.sum(Enum.map(rows, &length/1))
    dark = rows |> List.flatten() |> Enum.count(& &1)
    k = div(abs(dark * 20 - total * 10) + total - 1, total) - 1

    %{
      runs: lines |> Enum.map(&runs/1) |> Enum.sum(),
      blocks: 3 * blocks,
      finders: 40 * (lines |> Enum.map(&finder_like/1) |> Enum.sum()),
      balance: 10 * max(k, 0)
    }
  end

  def penalties(modules) when is_map(modules) do
    size = modules |> map_size() |> :math.sqrt() |> round()
    modules |> to_rows(size) |> penalties()
  end

  defp runs(line) do
    line
    |> Enum.chunk_by(& &1)
    |> Enum.map(&length/1)
    |> Enum.filter(&(&1 >= 5))
    |> Enum.map(&(3 + &1 - 5))
    |> Enum.sum()
  end

  # Rule 3 on one line, by runs: a light run, then dark 1, light 1, dark 3,
  # light 1, dark 1 exactly, then a light run, where the light run before
  # or the one after is at least four modules wide. A run that reaches the
  # edge continues into the four-module quiet zone. Each such run counts
  # once.
  @quiet 4

  defp finder_like(line) do
    line
    |> Enum.chunk_by(& &1)
    |> Enum.map(&{hd(&1), length(&1)})
    |> quiet_zone()
    |> Enum.chunk_every(7, 1, :discard)
    |> Enum.count(fn
      [{false, before}, {true, 1}, {false, 1}, {true, 3}, {false, 1}, {true, 1}, {false, after_}] ->
        before >= 4 or after_ >= 4

      _other ->
        false
    end)
  end

  defp quiet_zone(runs) do
    runs = edge(runs)
    runs |> Enum.reverse() |> edge() |> Enum.reverse()
  end

  defp edge([{false, n} | rest]), do: [{false, n + @quiet} | rest]
  defp edge(runs), do: [{false, @quiet} | runs]

  defp to_rows(modules, size) do
    for y <- 0..(size - 1), do: for(x <- 0..(size - 1), do: Map.fetch!(modules, {x, y}))
  end

  defp escape(text),
    do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
