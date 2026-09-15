# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Cidr do
  @moduledoc """
  Single source of truth for CIDR / IP-allowlist matching and for the
  address classes outbound requests are held to: cloud metadata and
  private/reserved ranges.

  Matches IPv4 and IPv6 CIDRs with family-specific prefix bounds; invalid input fails closed.

  `private_ip?/1` is the fixed SSRF range table — a different question from
  allowlist matching. `Cyfr.Network` blocks what it answers true for unless
  the caller's private policy admits the address, and blocks what
  `metadata?/1` answers true for whatever the policy. Both judge an IPv6
  address that embeds an IPv4 address (`embedded_ipv4/1`) by the address it
  embeds.

  Fail-closed: any unparseable IP/CIDR, an out-of-range or cross-family
  prefix, or a family mismatch yields no match (never a collapsed mask that
  would match everything).
  """

  import Bitwise

  # Instance-metadata endpoints outside the link-local ranges: Alibaba
  # Cloud, Oracle Cloud, and AWS's IPv6 endpoint.
  @metadata_addresses [
    {100, 100, 100, 200},
    {192, 0, 0, 192},
    {0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254}
  ]

  # Private/reserved IPv4 ranges (CIDR notation as {base, mask} tuples)
  @private_ranges [
    # 127.0.0.0/8 - loopback
    {bsl(127, 24), 0xFF000000},
    # 10.0.0.0/8 - private class A
    {bsl(10, 24), 0xFF000000},
    # 172.16.0.0/12 - private class B
    {bsl(172, 24) + bsl(16, 16), 0xFFF00000},
    # 192.168.0.0/16 - private class C
    {bsl(192, 24) + bsl(168, 16), 0xFFFF0000},
    # 169.254.0.0/16 - link-local / cloud metadata
    {bsl(169, 24) + bsl(254, 16), 0xFFFF0000},
    # 0.0.0.0/8 - current network
    {0, 0xFF000000},
    # 100.64.0.0/10 - CGNAT (RFC 6598); internal service ranges on several
    # clouds and overlay networks
    {bsl(100, 24) + bsl(64, 16), 0xFFC00000},
    # 192.0.0.0/24 - IETF protocol assignments (RFC 6890)
    {bsl(192, 24), 0xFFFFFF00},
    # 198.18.0.0/15 - benchmarking (RFC 2544)
    {bsl(198, 24) + bsl(18, 16), 0xFFFE0000},
    # 224.0.0.0/4 - multicast
    {bsl(224, 24), 0xF0000000},
    # 240.0.0.0/4 - reserved, includes 255.255.255.255 broadcast
    {bsl(240, 24), 0xF0000000}
  ]

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
  The IPv4 addresses an IPv6 address carries under a standard embedding:

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
      followed by the IPv4 address, under any prefix.

  Any other address, IPv4 included, carries none.
  """
  @spec embedded_ipv4(:inet.ip_address()) :: [:inet.ip4_address()]
  def embedded_ipv4({0, 0, 0, 0, 0, 0, hi, lo}), do: [v4(hi, lo)]
  def embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: [v4(hi, lo)]
  def embedded_ipv4({0, 0, 0, 0, 0xFFFF, 0, hi, lo}), do: [v4(hi, lo)]
  def embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: [v4(hi, lo)]

  def embedded_ipv4({0x64, 0xFF9B, 1, h3, h4, h5, h6, h7}) do
    [
      {bsr(h3, 8), band(h3, 0xFF), band(h4, 0xFF), bsr(h5, 8)},
      {band(h3, 0xFF), band(h4, 0xFF), bsr(h5, 8), band(h5, 0xFF)},
      {band(h4, 0xFF), bsr(h5, 8), band(h5, 0xFF), bsr(h6, 8)},
      v4(h6, h7)
    ]
  end

  def embedded_ipv4({0x2002, hi, lo, _, _, _, _, _}), do: [v4(hi, lo)]

  def embedded_ipv4({0x2001, 0, s_hi, s_lo, _, _, c_hi, c_lo}),
    do: [v4(s_hi, s_lo), v4(bxor(c_hi, 0xFFFF), bxor(c_lo, 0xFFFF))]

  def embedded_ipv4({_, _, _, _, isatap, 0x5EFE, hi, lo}) when isatap in [0, 0x200],
    do: [v4(hi, lo)]

  def embedded_ipv4(_ip), do: []

  @doc """
  True for an address that can reach a cloud instance-metadata service:
  the link-local ranges IPv4 `169.254.0.0/16` and IPv6 `fe80::/10`, the
  metadata endpoints outside them (`100.100.100.200`, `192.0.0.192`,
  `fd00:ec2::254`), and any IPv6 address embedding one of those IPv4
  addresses (`embedded_ipv4/1`).
  """
  @spec metadata?(:inet.ip_address()) :: boolean()
  def metadata?(ip) when ip in @metadata_addresses, do: true
  def metadata?({169, 254, _, _}), do: true
  def metadata?({_, _, _, _}), do: false
  def metadata?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true

  def metadata?({_, _, _, _, _, _, _, _} = ip),
    do: Enum.any?(embedded_ipv4(ip), &metadata?/1)

  def metadata?(_), do: false

  @doc """
  Check if an IP tuple is in a private/reserved range.
  """
  @spec private_ip?(:inet.ip4_address() | :inet.ip6_address()) :: boolean()
  def private_ip?({a, b, c, d}) do
    ip_int = bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

    Enum.any?(@private_ranges, fn {base, mask} ->
      band(ip_int, mask) == base
    end)
  end

  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  # IPv6 unspecified ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  # IPv6 unique local fc00::/7
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFC00 and w1 <= 0xFDFF, do: true

  # IPv6 link-local fe80::/10
  def private_ip?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true

  # Local-use IPv4/IPv6 translation space 64:ff9b:1::/48 (RFC 8215)
  def private_ip?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true

  # Any other IPv6 address is private when an IPv4 address it embeds is.
  def private_ip?({_, _, _, _, _, _, _, _} = ip),
    do: Enum.any?(embedded_ipv4(ip), &private_ip?/1)

  # ============================================================================
  # Internal
  # ============================================================================

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

  defp max_prefix_for(_), do: 0

  defp ip_to_integer({a, b, c, d}), do: bsl(a, 24) + bsl(b, 16) + bsl(c, 8) + d

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) + bsl(b, 96) + bsl(c, 80) + bsl(d, 64) +
      bsl(e, 48) + bsl(f, 32) + bsl(g, 16) + h
  end
end
