# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Cidr do
  @moduledoc """
  Single source of truth for CIDR / IP-allowlist matching and for the
  address classes outbound requests are held to: cloud metadata and
  private/reserved ranges.

  Matches IPv4 and IPv6 CIDRs with family-specific prefix bounds; invalid input fails closed.

  `private_ip?/1` is the fixed SSRF range table — a different question from
  allowlist matching. `Prima.Network` blocks what it answers true for unless
  the caller's private policy admits the address, and blocks what
  `metadata?/1` answers true for whatever the policy. Both judge an IPv6
  address that embeds an IPv4 address (`embedded_ipv4/1`) by the address it
  embeds.

  Fail-closed: any unparseable IP/CIDR, an out-of-range or cross-family
  prefix, or a family mismatch yields no match (never a collapsed mask that
  would match everything).
  """

  import Bitwise

  # The address table. An address is a metadata address exactly when it
  # falls in a metadata row, or is an IPv6 address embedding (@embeddings)
  # an IPv4 address that falls in one, and a private address likewise with
  # the private rows. The island egress guards hold the same table:
  # `address_table/0` expands it, and `mix cyfr.gen.guard_table` writes it
  # into apps/locus/keeper/guard/cyfr-guard.sh.
  @metadata_rows [
    # link-local, where the clouds' IPv4 metadata services sit
    "169.254.0.0/16",
    # instance-metadata endpoints outside it: Alibaba Cloud, Oracle Cloud
    "100.100.100.200/32",
    "192.0.0.192/32",
    # IPv6 link-local, and AWS's IPv6 endpoint
    "fe80::/10",
    "fd00:ec2::254/128"
  ]

  @private_rows [
    # loopback
    "127.0.0.0/8",
    # RFC 1918
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    # link-local
    "169.254.0.0/16",
    # current network
    "0.0.0.0/8",
    # CGNAT (RFC 6598): internal service ranges on several clouds and
    # overlay networks
    "100.64.0.0/10",
    # IETF protocol assignments (RFC 6890)
    "192.0.0.0/24",
    # benchmarking (RFC 2544)
    "198.18.0.0/15",
    # multicast
    "224.0.0.0/4",
    # reserved, 255.255.255.255 broadcast among them
    "240.0.0.0/4",
    # IPv6 loopback and unspecified
    "::1/128",
    "::/128",
    # unique local
    "fc00::/7",
    # link-local
    "fe80::/10",
    # local-use IPv4/IPv6 translation (RFC 8215)
    "64:ff9b:1::/48",
    # multicast
    "ff00::/8"
  ]

  # The standard embeddings of an IPv4 address in an IPv6 one: the bits
  # an embedding fixes (a CIDR, or a value and its mask), the bit
  # offset of each octet of the IPv4 address from the least significant
  # bit, most significant octet first, and whether the octets are inverted.
  @embeddings [
    # IPv4-compatible ::/96 and IPv4-mapped ::ffff:0:0/96 (RFC 4291),
    # IPv4-translated ::ffff:0:0:0/96 (RFC 2765), NAT64 64:ff9b::/96
    # (RFC 6052): the low 32 bits
    {"::/96", [24, 16, 8, 0], false},
    {"::ffff:0:0/96", [24, 16, 8, 0], false},
    {"::ffff:0:0:0/96", [24, 16, 8, 0], false},
    {"64:ff9b::/96", [24, 16, 8, 0], false},
    # local-use NAT64 64:ff9b:1::/48 (RFC 8215): the address does not carry
    # its translator's prefix length, so each RFC 6052 placement a prefix
    # within the /48 can use, /48, /56, /64 and /96, skipping bits 64 to 71
    {"64:ff9b:1::/48", [72, 64, 48, 40], false},
    {"64:ff9b:1::/48", [64, 48, 40, 32], false},
    {"64:ff9b:1::/48", [48, 40, 32, 24], false},
    {"64:ff9b:1::/48", [24, 16, 8, 0], false},
    # 6to4 2002::/16 (RFC 3056): bits 16 to 47
    {"2002::/16", [104, 96, 88, 80], false},
    # Teredo 2001::/32 (RFC 4380): the server in bits 32 to 63 and the
    # client, inverted, in the low 32 bits
    {"2001::/32", [88, 80, 72, 64], false},
    {"2001::/32", [24, 16, 8, 0], true},
    # ISATAP (RFC 5214): an interface identifier 0:5efe or 200:5efe
    # followed by the IPv4 address, under any prefix
    {{"::5efe:0:0", "::ffff:ffff:0:0"}, [24, 16, 8, 0], false},
    {{"::200:5efe:0:0", "::ffff:ffff:0:0"}, [24, 16, 8, 0], false}
  ]

  # Each row and each embedding's fixed bits as {width, value, mask}
  # integers, parsed once here.
  to_integer = fn text ->
    {:ok, ip} = :inet.parse_address(String.to_charlist(text))
    {width, base} = if tuple_size(ip) == 4, do: {32, 256}, else: {128, 65_536}
    {width, ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 * base + &1))}
  end

  row_bits = fn
    {value, mask} ->
      {width, v} = to_integer.(value)
      {^width, m} = to_integer.(mask)
      if band(v, m) != v, do: raise(ArgumentError, "#{value} sets bits outside #{mask}")
      {width, v, m}

    cidr ->
      [address, length] = String.split(cidr, "/")
      {width, v} = to_integer.(address)
      length = String.to_integer(length)
      m = bsl(bsl(1, length) - 1, width - length)
      if band(v, m) != v, do: raise(ArgumentError, "#{cidr} sets bits outside its prefix")
      {width, v, m}
  end

  @metadata_bits Enum.map(@metadata_rows, row_bits)
  @private_bits Enum.map(@private_rows, row_bits)
  @embedding_bits for {fixed, octets, inverted} <- @embeddings,
                      do: {row_bits.(fixed), octets, inverted}

  @doc "Parse an IP string to an `:inet` address tuple."
  @spec parse_ip(String.t()) :: {:ok, :inet.ip_address()} | :error
  def parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  def parse_ip(_), do: :error

  @doc """
  Parse `"ip/prefix"`. The prefix is bound to the parsed address family
  (IPv4 → 0..32, IPv6 → 0..128); an out-of-range or cross-family prefix is
  rejected so it can never collapse the mask and fail OPEN.
  """
  @spec parse_cidr(String.t()) :: {:ok, {:inet.ip_address(), non_neg_integer()}} | :error
  def parse_cidr(cidr_string) when is_binary(cidr_string) do
    case String.split(cidr_string, "/") do
      [ip_part, prefix_part] ->
        with {:ok, network} <- parse_ip(ip_part),
             {prefix_len, ""} <- Integer.parse(prefix_part),
             max_prefix when max_prefix > 0 <- max_prefix_for(network),
             true <- prefix_len >= 0 and prefix_len <= max_prefix do
          {:ok, {network, prefix_len}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def parse_cidr(_), do: :error

  @doc """
  True when `ip` (an `:inet` tuple or a string) falls within `cidr_string`.

  An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) is matched against an IPv4
  CIDR by its embedded IPv4 form (preserves the prior policy-matcher
  behaviour and makes `Sanctum.ApiKey` consistent with it).
  """
  @spec ip_in_cidr?(:inet.ip_address() | String.t(), String.t()) :: boolean()
  def ip_in_cidr?(ip, cidr_string) when is_binary(cidr_string) do
    with {:ok, ip_tuple} <- coerce_ip(ip),
         {:ok, {network, prefix_len}} <- parse_cidr(cidr_string) do
      ip_in_network?(unwrap_v4_mapped(ip_tuple), network, prefix_len)
    else
      _ -> false
    end
  end

  def ip_in_cidr?(_, _), do: false

  @doc """
  True when `ip` matches `entry`, where `entry` is either a plain IP
  (exact match) or a CIDR (range match).
  """
  @spec match?(:inet.ip_address() | String.t(), String.t()) :: boolean()
  def match?(ip, entry) when is_binary(entry) do
    if String.contains?(entry, "/") do
      ip_in_cidr?(ip, entry)
    else
      case {coerce_ip(ip), parse_ip(entry)} do
        {{:ok, t}, {:ok, t}} -> true
        _ -> false
      end
    end
  end

  def match?(_, _), do: false

  @doc "Bitmask membership test for already-parsed tuples."
  @spec ip_in_network?(:inet.ip_address(), :inet.ip_address(), non_neg_integer()) :: boolean()
  def ip_in_network?(ip, network, prefix_len)
      when is_tuple(ip) and is_tuple(network) and is_integer(prefix_len) do
    bit_size =
      case tuple_size(ip) do
        4 -> 32
        8 -> 128
        _ -> 0
      end

    # Defense in depth: parse_cidr already family-bounds the prefix, but never
    # compute a mask from an out-of-range/invalid prefix or a family mismatch
    # (either would fail OPEN). No match in that case.
    if bit_size > 0 and prefix_len >= 0 and prefix_len <= bit_size and
         tuple_size(ip) == tuple_size(network) do
      mask = bnot(bsl(1, bit_size - prefix_len) - 1) &&& bsl(1, bit_size) - 1
      (ip_to_integer(ip) &&& mask) == (ip_to_integer(network) &&& mask)
    else
      false
    end
  end

  def ip_in_network?(_, _, _), do: false

  @doc """
  The IPv4 addresses an IPv6 address carries, one for each standard
  embedding it matches, in this order:

    * IPv4-compatible `::/96` and IPv4-mapped `::ffff:0:0/96` (RFC 4291),
      IPv4-translated `::ffff:0:0:0/96` (RFC 2765) and NAT64 `64:ff9b::/96`
      (RFC 6052) — the low 32 bits;
    * local-use NAT64 `64:ff9b:1::/48` (RFC 8215) — the address does not
      carry its translator's prefix length, so one address for each
      RFC 6052 placement a prefix within the /48 can use: /48, /56, /64 and
      /96;
    * 6to4 `2002::/16` (RFC 3056) — bits 16 to 47;
    * Teredo `2001::/32` (RFC 4380) — the server in bits 32 to 63 and the
      client, inverted, in the low 32 bits;
    * ISATAP (RFC 5214) — an interface identifier `0:5efe` or `200:5efe`
      followed by the IPv4 address, under any prefix, the other prefixes
      above included.

  Any other address, IPv4 included, carries none.
  """
  @spec embedded_ipv4(:inet.ip_address()) :: [:inet.ip4_address()]
  def embedded_ipv4({_, _, _, _, _, _, _, _} = ip) do
    bits = ip_to_integer(ip)

    for {{128, value, mask}, octets, inverted} <- @embedding_bits, band(bits, mask) == value do
      octets
      |> Enum.map(fn offset ->
        octet = bits |> bsr(offset) |> band(0xFF)
        if inverted, do: bxor(octet, 0xFF), else: octet
      end)
      |> List.to_tuple()
    end
  end

  def embedded_ipv4(_ip), do: []

  @doc """
  True for an address that can reach a cloud instance-metadata service:
  the link-local ranges IPv4 `169.254.0.0/16` and IPv6 `fe80::/10`, the
  metadata endpoints outside them (`100.100.100.200`, `192.0.0.192`,
  `fd00:ec2::254`), and any IPv6 address embedding one of those IPv4
  addresses (`embedded_ipv4/1`).
  """
  @spec metadata?(:inet.ip_address()) :: boolean()
  def metadata?(ip) when tuple_size(ip) in [4, 8], do: in_class?(ip, @metadata_bits)
  def metadata?(_), do: false

  @doc """
  True for an address in a private or reserved range: IPv4 loopback,
  RFC 1918, link-local, `0.0.0.0/8`, CGNAT `100.64.0.0/10`, `192.0.0.0/24`,
  `198.18.0.0/15`, multicast and `240.0.0.0/4`; IPv6 `::1`, `::`,
  `fc00::/7`, `fe80::/10`, `64:ff9b:1::/48` and multicast `ff00::/8`; and
  any IPv6 address embedding a private IPv4 address (`embedded_ipv4/1`).
  """
  @spec private_ip?(:inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def private_ip?(ip) when tuple_size(ip) in [4, 8], do: in_class?(ip, @private_bits)

  @doc """
  The address table both egress policies hold, by class: every range
  `metadata?/1` answers true in, and every range `private_ip?/1` answers
  true in, IPv4 rows first. The IPv6 rows include each embedding of each
  IPv4 row of the class (`embedded_ipv4/1`); a row another row of its class
  contains is left out. A row is `address/length`, or `address/mask` where
  the embedding's bits leave the mask discontiguous, as `iptables` and
  `ip6tables` take them: an address is in a class exactly when it falls in
  one of the class's rows. The island egress guards install this table
  (`mix cyfr.gen.guard_table`).
  """
  @spec address_table() :: %{metadata: [String.t()], private: [String.t()]}
  def address_table do
    %{metadata: class_table(@metadata_bits), private: class_table(@private_bits)}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp in_class?(ip, rows),
    do: in_rows?(ip, rows) or Enum.any?(embedded_ipv4(ip), &in_rows?(&1, rows))

  defp in_rows?(ip, rows) do
    width = if tuple_size(ip) == 4, do: 32, else: 128
    bits = ip_to_integer(ip)
    Enum.any?(rows, fn {w, value, mask} -> w == width and band(bits, mask) == value end)
  end

  defp class_table(rows) do
    embedded =
      for {{128, e_value, e_mask}, octets, inverted} <- @embedding_bits,
          {32, value, mask} <- rows do
        {128, bor(e_value, place(value, octets, inverted, mask)),
         bor(e_mask, place(mask, octets, false, mask))}
      end

    all = Enum.uniq(rows ++ embedded)

    all
    |> Enum.reject(fn row -> Enum.any?(all, &(&1 != row and contains?(&1, row))) end)
    |> Enum.sort_by(fn {width, _, _} -> width end)
    |> Enum.map(&format_row/1)
  end

  # The IPv4 bits `ipv4` (32 bits, its octets most significant first)
  # placed at the embedding's octet offsets, inverted where the embedding
  # inverts them, within the bits `mask` fixes.
  defp place(ipv4, octets, inverted, mask) do
    octets
    |> Enum.with_index()
    |> Enum.reduce(0, fn {offset, index}, acc ->
      shift = 24 - 8 * index
      octet = ipv4 |> bsr(shift) |> band(0xFF)
      fixed = mask |> bsr(shift) |> band(0xFF)
      octet = if inverted, do: band(bxor(octet, 0xFF), fixed), else: octet
      bor(acc, bsl(octet, offset))
    end)
  end

  defp contains?({width, outer_value, outer_mask}, {width, value, mask}),
    do: band(mask, outer_mask) == outer_mask and band(value, outer_mask) == outer_value

  defp contains?(_outer, _row), do: false

  defp format_row({width, value, mask}) do
    length = popcount(mask)

    if mask == bsl(bsl(1, length) - 1, width - length) do
      "#{address(width, value)}/#{length}"
    else
      "#{address(width, value)}/#{address(width, mask)}"
    end
  end

  defp address(32, bits), do: bits |> integer_to_ip(4, 8) |> :inet.ntoa() |> to_string()
  defp address(128, bits), do: bits |> integer_to_ip(8, 16) |> :inet.ntoa() |> to_string()

  defp integer_to_ip(bits, parts, size),
    do:
      for(i <- (parts - 1)..0//-1, do: bits |> bsr(i * size) |> band(bsl(1, size) - 1))
      |> List.to_tuple()

  defp popcount(0), do: 0
  defp popcount(bits), do: band(bits, 1) + popcount(bsr(bits, 1))

  defp coerce_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp coerce_ip(ip) when is_binary(ip), do: parse_ip(ip)
  defp coerce_ip(_), do: :error

  defp unwrap_v4_mapped({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: v4(hi, lo)

  defp unwrap_v4_mapped(ip), do: ip

  defp v4(hi, lo), do: {bsr(hi, 8), band(hi, 0xFF), bsr(lo, 8), band(lo, 0xFF)}

  defp max_prefix_for(ip) when is_tuple(ip) do
    case tuple_size(ip) do
      4 -> 32
      8 -> 128
      _ -> 0
    end
  end

  defp ip_to_integer({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) + bsl(b, 96) + bsl(c, 80) + bsl(d, 64) +
      bsl(e, 48) + bsl(f, 32) + bsl(g, 16) + h
  end
end
