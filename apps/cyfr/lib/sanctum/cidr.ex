# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Cidr do
  @moduledoc """
  Single source of truth for CIDR / IP-allowlist matching and link-local
  detection.

  Consolidates three previously-divergent hand-rolled implementations
  (`Sanctum.ApiKey`, the legacy policy matcher, `Cyfr.Network`) into one
  IPv4 + IPv6, prefix-family-bounded, fail-closed primitive. The previous
  divergence was security-relevant: the policy matcher was IPv4-only (an
  IPv6 CIDR allowlist entry silently never matched) and its link-local
  check omitted IPv6 `fe80::/10`.

  `Cyfr.Network` keeps its own private/reserved-range SSRF *policy*
  (`@private_ranges`) — a different question — and only delegates the
  link-local arithmetic here.

  Fail-closed: any unparseable IP/CIDR, an out-of-range or cross-family
  prefix, or a family mismatch yields no match (never a collapsed mask that
  would match everything).
  """

  import Bitwise

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
  True for link-local / cloud-metadata ranges: IPv4 `169.254.0.0/16`,
  IPv6 `fe80::/10`, and their IPv4-mapped-IPv6 forms.
  """
  @spec link_local?(:inet.ip_address()) :: boolean()
  def link_local?({169, 254, _, _}), do: true
  def link_local?({w1, _, _, _, _, _, _, _}) when w1 >= 0xFE80 and w1 <= 0xFEBF, do: true

  def link_local?({0, 0, 0, 0, 0, 0xFFFF, _ab, _cd} = ip),
    do: link_local?(unwrap_v4_mapped(ip))

  def link_local?(_), do: false

  # ============================================================================
  # Internal
  # ============================================================================

  defp coerce_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp coerce_ip(ip) when is_binary(ip), do: parse_ip(ip)
  defp coerce_ip(_), do: :error

  defp unwrap_v4_mapped({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {bsr(ab, 8), band(ab, 0xFF), bsr(cd, 8), band(cd, 0xFF)}

  defp unwrap_v4_mapped(ip), do: ip

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
